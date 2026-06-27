use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc,
    },
    time::Duration,
};

use anyhow::Context;
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use async_trait::async_trait;
use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        DefaultBodyLimit, FromRequestParts, Multipart, Path, Query, State,
    },
    http::{header, request::Parts, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, TimeDelta, Utc};
use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use rust_embed::RustEmbed;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{sqlite::SqlitePoolOptions, FromRow, SqlitePool};
use tokio::sync::{broadcast, mpsc, oneshot};
use tower_http::{compression::CompressionLayer, cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info, warn};
use uuid::Uuid;

const MAX_UPLOAD_BYTES: usize = 32 * 1024 * 1024;
const MAX_UPLOAD_BODY_BYTES: usize = MAX_UPLOAD_BYTES + 1024 * 1024;

#[derive(RustEmbed)]
#[folder = "../web/dist"]
struct WebAssets;

#[derive(Clone)]
struct Config {
    bind: SocketAddr,
    db_path: String,
    jwt_secret: String,
    admin_username: String,
    admin_password: String,
    agent_token: String,
}

impl Config {
    fn from_env() -> anyhow::Result<Self> {
        let bind = std::env::var("CONDUCTOR_BIND")
            .unwrap_or_else(|_| "127.0.0.1:8080".to_string())
            .parse()
            .context("invalid CONDUCTOR_BIND")?;
        Ok(Self {
            bind,
            db_path: std::env::var("CONDUCTOR_DB")
                .unwrap_or_else(|_| "data/conductor.sqlite3".to_string()),
            jwt_secret: std::env::var("CONDUCTOR_JWT_SECRET")
                .unwrap_or_else(|_| "dev-secret-change-me".to_string()),
            admin_username: std::env::var("CONDUCTOR_ADMIN_USERNAME")
                .unwrap_or_else(|_| "admin".to_string()),
            admin_password: std::env::var("CONDUCTOR_ADMIN_PASSWORD")
                .unwrap_or_else(|_| "admin123".to_string()),
            agent_token: std::env::var("CONDUCTOR_AGENT_TOKEN")
                .unwrap_or_else(|_| "dev-agent-token-change-me".to_string()),
        })
    }
}

#[derive(Clone)]
struct AppState {
    cfg: Config,
    db: SqlitePool,
    agents: Arc<DashMap<String, AgentConnection>>,
    pending_files: Arc<DashMap<String, oneshot::Sender<FileResultPayload>>>,
    admin_events: broadcast::Sender<AdminEvent>,
}

#[derive(Clone)]
struct AgentConnection {
    tx: mpsc::UnboundedSender<ServerToAgent>,
    replacement: mpsc::UnboundedSender<()>,
    last_heartbeat: Arc<AtomicI64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
enum AgentToServer {
    AgentRegister(DeviceRegistration),
    AgentHeartbeat {
        device_id: String,
    },
    FileResult(FileResultPayload),
    ChatMessage(ChatPayload),
    ScreenFrame(ScreenFramePayload),
    SessionAccept {
        session_id: String,
    },
    SessionReject {
        session_id: String,
        reason: String,
    },
    WebrtcOffer {
        session_id: String,
        sdp: String,
    },
    WebrtcAnswer {
        session_id: String,
        sdp: String,
    },
    WebrtcIceCandidate {
        session_id: String,
        candidate: Value,
    },
    VoiceAccept {
        session_id: String,
    },
    VoiceReject {
        session_id: String,
        reason: String,
    },
    VoiceHangup {
        session_id: String,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerToAgent {
    FileCommand(FileCommandPayload),
    ChatMessage(ChatPayload),
    ControlEvent(ControlEventPayload),
    RemoteControlRequest {
        session_id: String,
    },
    SessionClose {
        session_id: String,
    },
    WebrtcOffer {
        session_id: String,
        sdp: String,
    },
    WebrtcAnswer {
        session_id: String,
        sdp: String,
    },
    WebrtcIceCandidate {
        session_id: String,
        candidate: Value,
    },
    VoiceRequest {
        session_id: String,
    },
    VoiceHangup {
        session_id: String,
    },
    VoiceMute {
        session_id: String,
        muted: bool,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
enum AdminToServer {
    ControlEvent(ControlEventPayload),
    WebrtcOffer {
        session_id: String,
        sdp: String,
    },
    WebrtcAnswer {
        session_id: String,
        sdp: String,
    },
    WebrtcIceCandidate {
        session_id: String,
        candidate: Value,
    },
    VoiceRequest {
        session_id: String,
    },
    VoiceHangup {
        session_id: String,
    },
    VoiceMute {
        session_id: String,
        muted: bool,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
enum AdminEvent {
    AgentStatusChanged {
        device_id: String,
        online: bool,
    },
    ChatMessage(ChatPayload),
    SessionStatus {
        session_id: String,
        status: String,
    },
    Signal {
        session_id: String,
        kind: String,
        payload: Value,
    },
    ScreenFrame(ScreenFramePayload),
    ControlAck(ControlEventPayload),
    VoiceStatus {
        session_id: String,
        status: String,
        muted: Option<bool>,
        reason: Option<String>,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct DeviceRegistration {
    device_id: String,
    hostname: String,
    os: String,
    arch: String,
    username: String,
    agent_version: String,
    local_ip: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct FileCommandPayload {
    request_id: String,
    command: String,
    path: String,
    name: Option<String>,
    content_base64: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct FileResultPayload {
    request_id: String,
    ok: bool,
    error: Option<String>,
    entries: Option<Vec<FileEntry>>,
    content_base64: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct FileEntry {
    name: String,
    path: String,
    is_dir: bool,
    size: u64,
    modified: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ChatPayload {
    message_id: String,
    session_id: String,
    device_id: String,
    sender: String,
    text: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ControlEventPayload {
    session_id: String,
    kind: String,
    x: Option<f32>,
    y: Option<f32>,
    button: Option<String>,
    key: Option<String>,
    delta_x: Option<f32>,
    delta_y: Option<f32>,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ScreenFramePayload {
    session_id: String,
    width: u32,
    height: u32,
    image_data_url: String,
    captured_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    exp: usize,
}

#[derive(Clone)]
struct AuthUser {
    username: String,
}

#[async_trait]
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let auth = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(ApiError::Unauthorized)?;
        let token = auth.strip_prefix("Bearer ").ok_or(ApiError::Unauthorized)?;
        let claims = decode::<Claims>(
            token,
            &DecodingKey::from_secret(state.cfg.jwt_secret.as_bytes()),
            &Validation::default(),
        )
        .map_err(|_| ApiError::Unauthorized)?
        .claims;
        Ok(Self {
            username: claims.sub,
        })
    }
}

#[derive(Debug, thiserror::Error)]
enum ApiError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("not found")]
    NotFound,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("device offline")]
    DeviceOffline,
    #[error("session already active for this device")]
    SessionBusy,
    #[error("internal error: {0}")]
    Internal(String),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self {
            ApiError::Unauthorized => StatusCode::UNAUTHORIZED,
            ApiError::NotFound => StatusCode::NOT_FOUND,
            ApiError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ApiError::DeviceOffline => StatusCode::CONFLICT,
            ApiError::SessionBusy => StatusCode::CONFLICT,
            ApiError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(json!({ "error": self.to_string() }))).into_response()
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Serialize, FromRow)]
struct DeviceRow {
    device_id: String,
    hostname: String,
    os: String,
    arch: String,
    username: String,
    agent_version: String,
    local_ip: String,
    online: i64,
    last_heartbeat: Option<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize, FromRow)]
struct SessionRow {
    session_id: String,
    device_id: String,
    status: String,
    created_at: String,
    closed_at: Option<String>,
}

#[derive(Serialize, FromRow)]
struct AuditLogRow {
    id: String,
    actor: String,
    action: String,
    target: String,
    detail: String,
    created_at: String,
}

#[derive(Serialize)]
struct OverviewResponse {
    total_devices: i64,
    online_devices: i64,
    active_sessions: i64,
    total_sessions: i64,
    audit_events: i64,
    recent_devices: Vec<DeviceRow>,
    recent_sessions: Vec<SessionRow>,
    recent_audit_logs: Vec<AuditLogRow>,
}

#[derive(Deserialize)]
struct CreateSessionRequest {
    device_id: String,
}

#[derive(Deserialize)]
struct PathQuery {
    path: Option<String>,
}

#[derive(Deserialize)]
struct AuditQuery {
    q: Option<String>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
struct SessionQuery {
    device_id: Option<String>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
struct MkdirRequest {
    path: String,
    name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChatRequest {
    text: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cfg = Config::from_env()?;
    if let Some(parent) = PathBuf::from(&cfg.db_path).parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let db = SqlitePoolOptions::new()
        .max_connections(5)
        .connect(&format!("sqlite://{}?mode=rwc", cfg.db_path))
        .await?;
    sqlx::migrate!("./migrations").run(&db).await?;
    seed_admin(&db, &cfg).await?;

    let (admin_events, _) = broadcast::channel(256);
    let state = AppState {
        cfg: cfg.clone(),
        db,
        agents: Arc::new(DashMap::new()),
        pending_files: Arc::new(DashMap::new()),
        admin_events,
    };

    let app = Router::new()
        .route("/health", get(|| async { Json(json!({ "ok": true })) }))
        .route("/api/auth/login", post(login))
        .route("/api/me", get(me))
        .route("/api/overview", get(overview))
        .route("/api/devices", get(list_devices))
        .route("/api/devices/:id", get(get_device))
        .route("/api/audit-logs", get(list_audit_logs))
        .route("/api/sessions", get(list_sessions).post(create_session))
        .route("/api/sessions/:id", get(get_session))
        .route("/api/sessions/:id/close", post(close_session))
        .route(
            "/api/sessions/:id/messages",
            get(list_messages).post(send_chat),
        )
        .route(
            "/api/devices/:id/files",
            get(list_files).delete(delete_file),
        )
        .route(
            "/api/devices/:id/files/upload",
            post(upload_file).layer(DefaultBodyLimit::max(MAX_UPLOAD_BODY_BYTES)),
        )
        .route("/api/devices/:id/files/download", get(download_file))
        .route("/api/devices/:id/files/mkdir", post(mkdir))
        .route("/ws/admin", get(ws_admin))
        .route("/ws/agent", get(ws_agent))
        .fallback(static_handler)
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state.clone());

    tokio::spawn(offline_sweeper(state));

    info!("server listening on http://{}", cfg.bind);
    let listener = tokio::net::TcpListener::bind(cfg.bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn seed_admin(db: &SqlitePool, cfg: &Config) -> anyhow::Result<()> {
    let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM admins WHERE username = ?")
        .bind(&cfg.admin_username)
        .fetch_optional(db)
        .await?;
    if exists.is_some() {
        return Ok(());
    }
    let salt = SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
    let hash = Argon2::default()
        .hash_password(cfg.admin_password.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
        .to_string();
    sqlx::query("INSERT INTO admins (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
        .bind(Uuid::new_v4().to_string())
        .bind(&cfg.admin_username)
        .bind(hash)
        .bind(Utc::now().to_rfc3339())
        .execute(db)
        .await?;
    Ok(())
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<Value>, ApiError> {
    if req.username.trim().is_empty() || req.password.is_empty() {
        return Err(ApiError::BadRequest(
            "username and password are required".into(),
        ));
    }
    let row: Option<(String,)> =
        sqlx::query_as("SELECT password_hash FROM admins WHERE username = ?")
            .bind(&req.username)
            .fetch_optional(&state.db)
            .await
            .map_err(db_err)?;
    let Some((hash,)) = row else {
        return Err(ApiError::Unauthorized);
    };
    let parsed = PasswordHash::new(&hash).map_err(|_| ApiError::Unauthorized)?;
    Argon2::default()
        .verify_password(req.password.as_bytes(), &parsed)
        .map_err(|_| ApiError::Unauthorized)?;
    let exp = Utc::now()
        .checked_add_signed(TimeDelta::hours(12))
        .unwrap()
        .timestamp() as usize;
    let username = req.username.clone();
    let token = encode(
        &Header::default(),
        &Claims {
            sub: username.clone(),
            exp,
        },
        &EncodingKey::from_secret(state.cfg.jwt_secret.as_bytes()),
    )
    .map_err(|e| ApiError::Internal(e.to_string()))?;
    audit(&state, &username, "auth_login", &username, "login success").await;
    Ok(Json(json!({ "token": token })))
}

async fn me(user: AuthUser) -> Json<Value> {
    Json(json!({ "username": user.username }))
}

async fn overview(
    _user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<OverviewResponse>, ApiError> {
    let (total_devices,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices")
        .fetch_one(&state.db)
        .await
        .map_err(db_err)?;
    let (online_devices,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices WHERE online = 1")
        .fetch_one(&state.db)
        .await
        .map_err(db_err)?;
    let (active_sessions,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM sessions WHERE status IN ('pending', 'active')")
            .fetch_one(&state.db)
            .await
            .map_err(db_err)?;
    let (total_sessions,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM sessions")
        .fetch_one(&state.db)
        .await
        .map_err(db_err)?;
    let (audit_events,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM audit_logs")
        .fetch_one(&state.db)
        .await
        .map_err(db_err)?;
    let recent_devices =
        sqlx::query_as::<_, DeviceRow>("SELECT * FROM devices ORDER BY updated_at DESC LIMIT 5")
            .fetch_all(&state.db)
            .await
            .map_err(db_err)?;
    let recent_sessions =
        sqlx::query_as::<_, SessionRow>("SELECT * FROM sessions ORDER BY created_at DESC LIMIT 5")
            .fetch_all(&state.db)
            .await
            .map_err(db_err)?;
    let recent_audit_logs = sqlx::query_as::<_, AuditLogRow>(
        "SELECT id, actor, action, target, detail, created_at FROM audit_logs ORDER BY created_at DESC LIMIT 5",
    )
    .fetch_all(&state.db)
    .await
    .map_err(db_err)?;
    Ok(Json(OverviewResponse {
        total_devices,
        online_devices,
        active_sessions,
        total_sessions,
        audit_events,
        recent_devices,
        recent_sessions,
        recent_audit_logs,
    }))
}

async fn list_devices(
    _user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<DeviceRow>>, ApiError> {
    let rows = sqlx::query_as::<_, DeviceRow>(
        "SELECT * FROM devices ORDER BY online DESC, updated_at DESC",
    )
    .fetch_all(&state.db)
    .await
    .map_err(db_err)?;
    Ok(Json(rows))
}

async fn get_device(
    _user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<DeviceRow>, ApiError> {
    let row = sqlx::query_as::<_, DeviceRow>("SELECT * FROM devices WHERE device_id = ?")
        .bind(id)
        .fetch_optional(&state.db)
        .await
        .map_err(db_err)?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(row))
}

async fn list_audit_logs(
    _user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<AuditQuery>,
) -> Result<Json<Vec<AuditLogRow>>, ApiError> {
    let limit = q.limit.unwrap_or(200).clamp(1, 500);
    let rows = if let Some(needle) = q.q.filter(|v| !v.trim().is_empty()) {
        let pattern = format!("%{}%", needle.trim());
        sqlx::query_as::<_, AuditLogRow>(
            "SELECT id, actor, action, target, detail, created_at FROM audit_logs
             WHERE actor LIKE ? OR action LIKE ? OR target LIKE ? OR detail LIKE ?
             ORDER BY created_at DESC LIMIT ?",
        )
        .bind(&pattern)
        .bind(&pattern)
        .bind(&pattern)
        .bind(&pattern)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(db_err)?
    } else {
        sqlx::query_as::<_, AuditLogRow>(
            "SELECT id, actor, action, target, detail, created_at FROM audit_logs
             ORDER BY created_at DESC LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(db_err)?
    };
    Ok(Json(rows))
}

async fn create_session(
    user: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateSessionRequest>,
) -> Result<Json<SessionRow>, ApiError> {
    let tx = state
        .agents
        .get(&req.device_id)
        .ok_or(ApiError::DeviceOffline)?
        .tx
        .clone();
    if active_session_for_device(&state.db, &req.device_id)
        .await?
        .is_some()
    {
        return Err(ApiError::SessionBusy);
    }
    let session_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    sqlx::query("INSERT INTO sessions (session_id, device_id, status, created_at) VALUES (?, ?, 'pending', ?)")
        .bind(&session_id)
        .bind(&req.device_id)
        .bind(&now)
        .execute(&state.db)
        .await
        .map_err(db_err)?;
    audit(
        &state,
        &user.username,
        "session_create",
        &req.device_id,
        &session_id,
    )
    .await;
    tx.send(ServerToAgent::RemoteControlRequest {
        session_id: session_id.clone(),
    })
    .map_err(|_| ApiError::DeviceOffline)?;
    let _ = state.admin_events.send(AdminEvent::SessionStatus {
        session_id: session_id.clone(),
        status: "pending".into(),
    });
    get_session_by_id(&state.db, &session_id).await.map(Json)
}

async fn list_sessions(
    _user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<SessionQuery>,
) -> Result<Json<Vec<SessionRow>>, ApiError> {
    let limit = q.limit.unwrap_or(100).clamp(1, 300);
    let rows = if let Some(device_id) = q.device_id.filter(|v| !v.trim().is_empty()) {
        sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions WHERE device_id = ? ORDER BY created_at DESC LIMIT ?",
        )
        .bind(device_id)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(db_err)?
    } else {
        sqlx::query_as::<_, SessionRow>("SELECT * FROM sessions ORDER BY created_at DESC LIMIT ?")
            .bind(limit)
            .fetch_all(&state.db)
            .await
            .map_err(db_err)?
    };
    Ok(Json(rows))
}

async fn get_session(
    _user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<SessionRow>, ApiError> {
    get_session_by_id(&state.db, &id).await.map(Json)
}

async fn close_session(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<SessionRow>, ApiError> {
    let session = get_session_by_id(&state.db, &id).await?;
    mark_session_closed(&state, &id, "closed").await?;
    if let Some(tx) = state.agents.get(&session.device_id) {
        let _ = tx.tx.send(ServerToAgent::SessionClose {
            session_id: id.clone(),
        });
    }
    audit(
        &state,
        &user.username,
        "session_close",
        &session.device_id,
        &id,
    )
    .await;
    get_session_by_id(&state.db, &id).await.map(Json)
}

async fn get_session_by_id(db: &SqlitePool, id: &str) -> Result<SessionRow, ApiError> {
    sqlx::query_as::<_, SessionRow>("SELECT * FROM sessions WHERE session_id = ?")
        .bind(id)
        .fetch_optional(db)
        .await
        .map_err(db_err)?
        .ok_or(ApiError::NotFound)
}

async fn active_session_for_device(
    db: &SqlitePool,
    device_id: &str,
) -> Result<Option<SessionRow>, ApiError> {
    sqlx::query_as::<_, SessionRow>(
        "SELECT * FROM sessions WHERE device_id = ? AND status IN ('pending', 'active') ORDER BY created_at DESC LIMIT 1",
    )
    .bind(device_id)
    .fetch_optional(db)
    .await
    .map_err(db_err)
}

async fn list_messages(
    _user: AuthUser,
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<Vec<ChatPayload>>, ApiError> {
    let rows = sqlx::query_as::<_, (String, String, String, String, String, String)>(
        "SELECT message_id, session_id, device_id, sender, text, created_at FROM chat_messages WHERE session_id = ? ORDER BY created_at ASC LIMIT 200",
    )
    .bind(session_id)
    .fetch_all(&state.db)
    .await
    .map_err(db_err)?;
    let messages = rows
        .into_iter()
        .filter_map(
            |(message_id, session_id, device_id, sender, text, created_at)| {
                DateTime::parse_from_rfc3339(&created_at)
                    .ok()
                    .map(|dt| ChatPayload {
                        message_id,
                        session_id,
                        device_id,
                        sender,
                        text,
                        created_at: dt.with_timezone(&Utc),
                    })
            },
        )
        .collect();
    Ok(Json(messages))
}

async fn send_chat(
    user: AuthUser,
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(req): Json<ChatRequest>,
) -> Result<Json<ChatPayload>, ApiError> {
    let session = get_session_by_id(&state.db, &session_id).await?;
    if !matches!(session.status.as_str(), "pending" | "active") {
        return Err(ApiError::BadRequest(format!(
            "session is not available for chat: {}",
            session.status
        )));
    }
    let text = req.text.trim();
    if text.is_empty() {
        return Err(ApiError::BadRequest("message text is required".into()));
    }
    if text.chars().count() > 2000 {
        return Err(ApiError::BadRequest("message is too long".into()));
    }
    let msg = ChatPayload {
        message_id: Uuid::new_v4().to_string(),
        session_id: session.session_id,
        device_id: session.device_id,
        sender: "admin".into(),
        text: text.to_string(),
        created_at: Utc::now(),
    };
    save_chat(&state, &msg).await?;
    if let Some(tx) = state.agents.get(&msg.device_id) {
        let _ = tx.tx.send(ServerToAgent::ChatMessage(msg.clone()));
    }
    audit(
        &state,
        &user.username,
        "chat_send",
        &msg.device_id,
        &msg.session_id,
    )
    .await;
    let _ = state
        .admin_events
        .send(AdminEvent::ChatMessage(msg.clone()));
    Ok(Json(msg))
}

async fn list_files(
    user: AuthUser,
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Query(q): Query<PathQuery>,
) -> Result<Json<FileResultPayload>, ApiError> {
    let path = q.path.unwrap_or_else(|| ".".into());
    let result = forward_file_command(
        &state,
        &device_id,
        "list",
        path.clone(),
        None,
        None,
    )
    .await?;
    audit(&state, &user.username, "file_list", &device_id, &path).await;
    Ok(Json(result))
}

async fn delete_file(
    user: AuthUser,
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Query(q): Query<PathQuery>,
) -> Result<Json<FileResultPayload>, ApiError> {
    let path = q
        .path
        .ok_or_else(|| ApiError::BadRequest("path is required".into()))?;
    let result =
        forward_file_command(&state, &device_id, "delete", path.clone(), None, None).await?;
    audit(&state, &user.username, "file_delete", &device_id, &path).await;
    Ok(Json(result))
}

async fn mkdir(
    user: AuthUser,
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Json(req): Json<MkdirRequest>,
) -> Result<Json<FileResultPayload>, ApiError> {
    let result = forward_file_command(
        &state,
        &device_id,
        "mkdir",
        req.path.clone(),
        Some(req.name.clone()),
        None,
    )
    .await?;
    audit(
        &state,
        &user.username,
        "file_mkdir",
        &device_id,
        &format!("{}/{}", req.path, req.name),
    )
    .await;
    Ok(Json(result))
}

async fn upload_file(
    user: AuthUser,
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<FileResultPayload>, ApiError> {
    let mut target_path = ".".to_string();
    let mut file_name = None;
    let mut content = None;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::BadRequest(e.to_string()))?
    {
        let name = field.name().unwrap_or_default().to_string();
        match name.as_str() {
            "path" => {
                target_path = field
                    .text()
                    .await
                    .map_err(|e| ApiError::BadRequest(e.to_string()))?
            }
            "file" => {
                file_name = field.file_name().map(|v| v.to_string());
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|e| ApiError::BadRequest(e.to_string()))?;
                if bytes.len() > MAX_UPLOAD_BYTES {
                    return Err(ApiError::BadRequest(
                        "file exceeds the 32 MiB upload limit".into(),
                    ));
                }
                content = Some(B64.encode(bytes));
            }
            _ => {}
        }
    }
    let result = forward_file_command(
        &state,
        &device_id,
        "upload",
        target_path.clone(),
        file_name.clone(),
        content,
    )
    .await?;
    audit(
        &state,
        &user.username,
        "file_upload",
        &device_id,
        file_name.as_deref().unwrap_or("file"),
    )
    .await;
    Ok(Json(result))
}

async fn download_file(
    user: AuthUser,
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Query(q): Query<PathQuery>,
) -> Result<Response, ApiError> {
    let path = q
        .path
        .ok_or_else(|| ApiError::BadRequest("path is required".into()))?;
    let result =
        forward_file_command(&state, &device_id, "download", path.clone(), None, None).await?;
    if !result.ok {
        return Err(ApiError::BadRequest(
            result.error.unwrap_or_else(|| "download failed".into()),
        ));
    }
    audit(&state, &user.username, "file_download", &device_id, &path).await;
    let bytes = B64
        .decode(result.content_base64.unwrap_or_default())
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let name = path.rsplit('/').next().unwrap_or("download.bin");
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&format!(
            "attachment; filename=\"{}\"",
            name.replace('"', "")
        ))
        .unwrap(),
    );
    Ok((headers, Body::from(bytes)).into_response())
}

async fn forward_file_command(
    state: &AppState,
    device_id: &str,
    command: &str,
    path: String,
    name: Option<String>,
    content_base64: Option<String>,
) -> Result<FileResultPayload, ApiError> {
    if path.contains("..") {
        return Err(ApiError::BadRequest("path traversal is not allowed".into()));
    }
    let tx = state
        .agents
        .get(device_id)
        .ok_or(ApiError::DeviceOffline)?
        .tx
        .clone();
    let request_id = Uuid::new_v4().to_string();
    let (reply_tx, reply_rx) = oneshot::channel();
    state.pending_files.insert(request_id.clone(), reply_tx);
    tx.send(ServerToAgent::FileCommand(FileCommandPayload {
        request_id: request_id.clone(),
        command: command.into(),
        path,
        name,
        content_base64,
    }))
    .map_err(|_| ApiError::DeviceOffline)?;
    match tokio::time::timeout(Duration::from_secs(20), reply_rx).await {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(_)) => Err(ApiError::Internal(
            "agent file response channel closed".into(),
        )),
        Err(_) => {
            state.pending_files.remove(&request_id);
            Err(ApiError::Internal("agent file operation timed out".into()))
        }
    }
}

async fn ws_admin(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Query(q): Query<std::collections::HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let token = q.get("token").ok_or(ApiError::Unauthorized)?;
    decode::<Claims>(
        token,
        &DecodingKey::from_secret(state.cfg.jwt_secret.as_bytes()),
        &Validation::default(),
    )
    .map_err(|_| ApiError::Unauthorized)?;
    Ok(ws.on_upgrade(move |socket| admin_socket(state, socket)))
}

async fn admin_socket(state: AppState, mut socket: WebSocket) {
    let mut rx = state.admin_events.subscribe();
    loop {
        tokio::select! {
            event = rx.recv() => {
                match event {
                    Ok(event) => {
                        if socket.send(Message::Text(serde_json::to_string(&event).unwrap())).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            next = socket.recv() => {
                match next {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(Message::Text(text))) => {
                        if let Err(err) = handle_admin_message(&state, &text).await {
                            let payload = json!({ "type": "error", "message": err.to_string() });
                            let _ = socket.send(Message::Text(payload.to_string())).await;
                        }
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) => break,
                }
            }
        }
    }
}

async fn handle_admin_message(state: &AppState, text: &str) -> Result<(), ApiError> {
    match serde_json::from_str::<AdminToServer>(text)
        .map_err(|e| ApiError::BadRequest(e.to_string()))?
    {
        AdminToServer::ControlEvent(event) => {
            let session = require_session_status(&state.db, &event.session_id, &["active"]).await?;
            let tx = state
                .agents
                .get(&session.device_id)
                .ok_or(ApiError::DeviceOffline)?
                .tx
                .clone();
            tx.send(ServerToAgent::ControlEvent(event.clone()))
                .map_err(|_| ApiError::DeviceOffline)?;
            let _ = state.admin_events.send(AdminEvent::ControlAck(event));
        }
        AdminToServer::WebrtcOffer { session_id, sdp } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| {
                ServerToAgent::WebrtcOffer { session_id, sdp }
            })
            .await?;
        }
        AdminToServer::WebrtcAnswer { session_id, sdp } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| {
                ServerToAgent::WebrtcAnswer { session_id, sdp }
            })
            .await?;
        }
        AdminToServer::WebrtcIceCandidate {
            session_id,
            candidate,
        } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| {
                ServerToAgent::WebrtcIceCandidate {
                    session_id,
                    candidate,
                }
            })
            .await?;
        }
        AdminToServer::VoiceRequest { session_id } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| {
                ServerToAgent::VoiceRequest { session_id }
            })
            .await?;
            voice_status(state, &session_id, "requesting", None, None).await;
        }
        AdminToServer::VoiceHangup { session_id } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| {
                ServerToAgent::VoiceHangup { session_id }
            })
            .await?;
            voice_status(state, &session_id, "hangup", None, None).await;
        }
        AdminToServer::VoiceMute { session_id, muted } => {
            require_session_status(&state.db, &session_id, &["active"]).await?;
            forward_signal_to_agent(state, &session_id, |session_id| ServerToAgent::VoiceMute {
                session_id,
                muted,
            })
            .await?;
            voice_status(state, &session_id, "muted", Some(muted), None).await;
        }
    }
    Ok(())
}

async fn require_session_status(
    db: &SqlitePool,
    session_id: &str,
    allowed: &[&str],
) -> Result<SessionRow, ApiError> {
    let session = get_session_by_id(db, session_id).await?;
    if allowed.iter().any(|status| *status == session.status) {
        return Ok(session);
    }
    Err(ApiError::BadRequest(format!(
        "session {} is not available for this operation (status={})",
        session_id, session.status
    )))
}

async fn forward_signal_to_agent<F>(
    state: &AppState,
    session_id: &str,
    make_msg: F,
) -> Result<(), ApiError>
where
    F: FnOnce(String) -> ServerToAgent,
{
    let session = get_session_by_id(&state.db, session_id).await?;
    let tx = state
        .agents
        .get(&session.device_id)
        .ok_or(ApiError::DeviceOffline)?
        .tx
        .clone();
    tx.send(make_msg(session_id.to_string()))
        .map_err(|_| ApiError::DeviceOffline)?;
    Ok(())
}

async fn ws_agent(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let token = q.get("token").ok_or(ApiError::Unauthorized)?;
    if !constant_time_eq(token.as_bytes(), state.cfg.agent_token.as_bytes()) {
        return Err(ApiError::Unauthorized);
    }
    Ok(ws.on_upgrade(move |socket| agent_socket(state, socket)))
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        difference |= left.get(index).copied().unwrap_or(0) as usize
            ^ right.get(index).copied().unwrap_or(0) as usize;
    }
    difference == 0
}

async fn agent_socket(state: AppState, socket: WebSocket) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerToAgent>();
    let (replacement_tx, mut replacement_rx) = mpsc::unbounded_channel::<()>();
    let mut device_id: Option<String> = None;

    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            match serde_json::to_string(&msg) {
                Ok(text) => {
                    if ws_tx.send(Message::Text(text)).await.is_err() {
                        break;
                    }
                }
                Err(e) => error!("failed to encode server message: {e}"),
            }
        }
    });

    loop {
        let next = tokio::select! {
            _ = replacement_rx.recv() => {
                info!("agent connection replaced by a newer connection");
                break;
            }
            next = ws_rx.next() => next,
        };
        let Some(Ok(msg)) = next else { break };
        let Message::Text(text) = msg else { continue };
        match serde_json::from_str::<AgentToServer>(&text) {
            Ok(AgentToServer::AgentRegister(reg)) => {
                device_id = Some(reg.device_id.clone());
                let connection = AgentConnection {
                    tx: tx.clone(),
                    replacement: replacement_tx.clone(),
                    last_heartbeat: Arc::new(AtomicI64::new(
                        Utc::now().timestamp(),
                    )),
                };
                install_agent_connection(&state.agents, reg.device_id.clone(), connection);
                if let Err(e) = upsert_device(&state, &reg).await {
                    error!("register device failed: {e}");
                }
                audit(
                    &state,
                    "system",
                    "device_online",
                    &reg.device_id,
                    &format!("{} {} {}", reg.hostname, reg.os, reg.local_ip),
                )
                .await;
                let _ = state.admin_events.send(AdminEvent::AgentStatusChanged {
                    device_id: reg.device_id,
                    online: true,
                });
            }
            Ok(AgentToServer::AgentHeartbeat { device_id: heartbeat_id }) => {
                let Some(registered_id) = device_id.as_deref() else {
                    warn!("ignored heartbeat before agent registration");
                    continue;
                };
                if heartbeat_id != registered_id {
                    warn!(
                        "ignored heartbeat with mismatched device id registered={} received={}",
                        registered_id, heartbeat_id
                    );
                    continue;
                }
                let current_connection = state
                    .agents
                    .get(registered_id)
                    .filter(|connection| connection.tx.same_channel(&tx));
                let Some(connection) = current_connection else {
                    warn!("ignored heartbeat from replaced agent connection: {registered_id}");
                    continue;
                };
                connection
                    .last_heartbeat
                    .store(Utc::now().timestamp(), Ordering::Relaxed);
                drop(connection);
                if let Err(e) = touch_device(&state, registered_id, true).await {
                    warn!("heartbeat update failed: {e}");
                }
            }
            Ok(AgentToServer::FileResult(result)) => {
                if let Some((_, reply)) = state.pending_files.remove(&result.request_id) {
                    let _ = reply.send(result);
                }
            }
            Ok(AgentToServer::ChatMessage(msg)) => {
                if save_chat(&state, &msg).await.is_ok() {
                    let _ = state.admin_events.send(AdminEvent::ChatMessage(msg));
                }
            }
            Ok(AgentToServer::ScreenFrame(frame)) => {
                let _ = state.admin_events.send(AdminEvent::ScreenFrame(frame));
            }
            Ok(AgentToServer::SessionAccept { session_id }) => {
                update_session_status(&state, &session_id, "active").await;
            }
            Ok(AgentToServer::SessionReject { session_id, reason }) => {
                update_session_status(&state, &session_id, "rejected").await;
                warn!("session rejected: {session_id}: {reason}");
            }
            Ok(AgentToServer::WebrtcOffer { session_id, sdp }) => {
                signal(&state, session_id, "offer", json!({ "sdp": sdp }))
            }
            Ok(AgentToServer::WebrtcAnswer { session_id, sdp }) => {
                signal(&state, session_id, "answer", json!({ "sdp": sdp }))
            }
            Ok(AgentToServer::WebrtcIceCandidate {
                session_id,
                candidate,
            }) => signal(&state, session_id, "ice_candidate", candidate),
            Ok(AgentToServer::VoiceAccept { session_id }) => {
                voice_status(&state, &session_id, "accepted", None, None).await;
            }
            Ok(AgentToServer::VoiceReject { session_id, reason }) => {
                voice_status(&state, &session_id, "rejected", None, Some(reason)).await;
            }
            Ok(AgentToServer::VoiceHangup { session_id }) => {
                voice_status(&state, &session_id, "hangup", None, None).await;
            }
            Ok(AgentToServer::Error { message }) => warn!("agent error: {message}"),
            Err(e) => warn!("invalid agent message: {e}"),
        }
    }

    if let Some(id) = device_id {
        if remove_current_agent_connection(&state.agents, &id, &tx) {
            let _ = touch_device(&state, &id, false).await;
            close_active_sessions_for_device(&state, &id, "agent_offline").await;
            audit(&state, "system", "device_offline", &id, "agent websocket disconnected").await;
            let _ = state.admin_events.send(AdminEvent::AgentStatusChanged {
                device_id: id,
                online: false,
            });
        }
    }
    writer.abort();
}

fn install_agent_connection(
    agents: &DashMap<String, AgentConnection>,
    device_id: String,
    connection: AgentConnection,
) {
    if let Some(old) = agents.insert(device_id, connection.clone()) {
        if !old.tx.same_channel(&connection.tx) {
            let _ = old.replacement.send(());
        }
    }
}

fn remove_current_agent_connection(
    agents: &DashMap<String, AgentConnection>,
    device_id: &str,
    sender: &mpsc::UnboundedSender<ServerToAgent>,
) -> bool {
    agents
        .remove_if(device_id, |_, current| current.tx.same_channel(sender))
        .is_some()
}

async fn upsert_device(state: &AppState, reg: &DeviceRegistration) -> Result<(), sqlx::Error> {
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO devices (device_id, hostname, os, arch, username, agent_version, local_ip, online, last_heartbeat, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET hostname=excluded.hostname, os=excluded.os, arch=excluded.arch, username=excluded.username,
         agent_version=excluded.agent_version, local_ip=excluded.local_ip, online=1, last_heartbeat=excluded.last_heartbeat, updated_at=excluded.updated_at",
    )
    .bind(&reg.device_id)
    .bind(&reg.hostname)
    .bind(&reg.os)
    .bind(&reg.arch)
    .bind(&reg.username)
    .bind(&reg.agent_version)
    .bind(&reg.local_ip)
    .bind(&now)
    .bind(&now)
    .bind(&now)
    .execute(&state.db)
    .await?;
    Ok(())
}

async fn touch_device(state: &AppState, device_id: &str, online: bool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE devices SET online = ?, last_heartbeat = ?, updated_at = ? WHERE device_id = ?",
    )
    .bind(if online { 1 } else { 0 })
    .bind(Utc::now().to_rfc3339())
    .bind(Utc::now().to_rfc3339())
    .bind(device_id)
    .execute(&state.db)
    .await?;
    Ok(())
}

async fn offline_sweeper(state: AppState) {
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    loop {
        tick.tick().await;
        let cutoff = Utc::now() - TimeDelta::seconds(30);
        let rows = sqlx::query_as::<_, (String, String)>(
            "SELECT device_id, last_heartbeat FROM devices WHERE online = 1",
        )
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();
        for (device_id, last) in rows {
            let stale = DateTime::parse_from_rfc3339(&last)
                .map(|dt| dt.with_timezone(&Utc) < cutoff)
                .unwrap_or(true);
            let has_fresh_connection = state
                .agents
                .get(&device_id)
                .map(|connection| {
                    connection.last_heartbeat.load(Ordering::Relaxed) >= cutoff.timestamp()
                })
                .unwrap_or(false);
            if stale && !has_fresh_connection {
                if let Some((_, connection)) = state.agents.remove_if(&device_id, |_, current| {
                    current.last_heartbeat.load(Ordering::Relaxed) < cutoff.timestamp()
                }) {
                    let _ = connection.replacement.send(());
                }
                let marked_offline = mark_device_offline_if_heartbeat(&state.db, &device_id, &last)
                    .await
                    .unwrap_or(false);
                if !marked_offline {
                    continue;
                }
                close_active_sessions_for_device(&state, &device_id, "heartbeat_timeout").await;
                audit(
                    &state,
                    "system",
                    "device_offline",
                    &device_id,
                    "agent heartbeat timed out",
                )
                .await;
                let _ = state.admin_events.send(AdminEvent::AgentStatusChanged {
                    device_id,
                    online: false,
                });
            }
        }
    }
}

async fn mark_device_offline_if_heartbeat(
    db: &SqlitePool,
    device_id: &str,
    expected_heartbeat: &str,
) -> Result<bool, sqlx::Error> {
    let now = Utc::now().to_rfc3339();
    let result = sqlx::query(
        "UPDATE devices SET online = 0, updated_at = ? WHERE device_id = ? AND online = 1 AND last_heartbeat = ?",
    )
    .bind(now)
    .bind(device_id)
    .bind(expected_heartbeat)
    .execute(db)
    .await?;
    Ok(result.rows_affected() == 1)
}

async fn update_session_status(state: &AppState, session_id: &str, status: &str) {
    match transition_pending_session(&state.db, session_id, status).await {
        Ok(true) => {}
        Ok(false) => {
            warn!("ignored late session transition session={session_id} target={status}");
            return;
        }
        Err(err) => {
            error!("session transition failed session={session_id} target={status}: {err}");
            return;
        }
    }
    audit(state, "system", "session_status", session_id, status).await;
    let _ = state.admin_events.send(AdminEvent::SessionStatus {
        session_id: session_id.into(),
        status: status.into(),
    });
}

async fn transition_pending_session(
    db: &SqlitePool,
    session_id: &str,
    status: &str,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "UPDATE sessions SET status = ? WHERE session_id = ? AND status = 'pending' AND closed_at IS NULL",
    )
    .bind(status)
    .bind(session_id)
    .execute(db)
    .await?;
    Ok(result.rows_affected() == 1)
}

async fn mark_session_closed(
    state: &AppState,
    session_id: &str,
    status: &str,
) -> Result<(), ApiError> {
    sqlx::query("UPDATE sessions SET status = ?, closed_at = ? WHERE session_id = ?")
        .bind(status)
        .bind(Utc::now().to_rfc3339())
        .bind(session_id)
        .execute(&state.db)
        .await
        .map_err(db_err)?;
    let _ = state.admin_events.send(AdminEvent::SessionStatus {
        session_id: session_id.into(),
        status: status.into(),
    });
    Ok(())
}

async fn close_active_sessions_for_device(state: &AppState, device_id: &str, status: &str) {
    let rows = sqlx::query_as::<_, (String,)>(
        "SELECT session_id FROM sessions WHERE device_id = ? AND status IN ('pending', 'active')",
    )
    .bind(device_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();
    for (session_id,) in rows {
        if mark_session_closed(state, &session_id, status)
            .await
            .is_ok()
        {
            audit(
                state,
                "system",
                "session_auto_close",
                &session_id,
                &format!("device={} reason={}", device_id, status),
            )
            .await;
            let _ = state.admin_events.send(AdminEvent::Signal {
                session_id,
                kind: "session_closed".into(),
                payload: json!({ "reason": status }),
            });
        }
    }
}

fn signal(state: &AppState, session_id: String, kind: &str, payload: Value) {
    let _ = state.admin_events.send(AdminEvent::Signal {
        session_id,
        kind: kind.into(),
        payload,
    });
}

async fn voice_status(
    state: &AppState,
    session_id: &str,
    status: &str,
    muted: Option<bool>,
    reason: Option<String>,
) {
    let detail = match (muted, reason.as_deref()) {
        (Some(muted), Some(reason)) => format!("muted={} reason={}", muted, reason),
        (Some(muted), None) => format!("muted={}", muted),
        (None, Some(reason)) => format!("reason={}", reason),
        (None, None) => status.to_string(),
    };
    audit(state, "system", "voice_status", session_id, &detail).await;
    let _ = state.admin_events.send(AdminEvent::VoiceStatus {
        session_id: session_id.into(),
        status: status.into(),
        muted,
        reason,
    });
}

async fn save_chat(state: &AppState, msg: &ChatPayload) -> Result<(), ApiError> {
    sqlx::query("INSERT OR IGNORE INTO chat_messages (message_id, session_id, device_id, sender, text, created_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(&msg.message_id)
        .bind(&msg.session_id)
        .bind(&msg.device_id)
        .bind(&msg.sender)
        .bind(&msg.text)
        .bind(msg.created_at.to_rfc3339())
        .execute(&state.db)
        .await
        .map_err(db_err)?;
    Ok(())
}

async fn audit(state: &AppState, actor: &str, action: &str, target: &str, detail: &str) {
    let _ = sqlx::query("INSERT INTO audit_logs (id, actor, action, target, detail, created_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(Uuid::new_v4().to_string())
        .bind(actor)
        .bind(action)
        .bind(target)
        .bind(detail)
        .bind(Utc::now().to_rfc3339())
        .execute(&state.db)
        .await;
}

async fn static_handler(uri: axum::http::Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    let asset_path = if path.is_empty() { "index.html" } else { path };
    if asset_path.starts_with("api/") || asset_path.starts_with("ws/") {
        return StatusCode::NOT_FOUND.into_response();
    }
    let file = WebAssets::get(asset_path).or_else(|| WebAssets::get("index.html"));
    match file {
        Some(content) => {
            let mime = mime_guess::from_path(asset_path).first_or_octet_stream();
            let mut headers = HeaderMap::new();
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_str(mime.as_ref()).unwrap(),
            );
            (headers, content.data.into_owned()).into_response()
        }
        None => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "web assets are missing; run `cd web && npm run build` before building server",
        )
            .into_response(),
    }
}

fn db_err(err: sqlx::Error) -> ApiError {
    error!("database error: {err}");
    ApiError::Internal(err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_agent_connection_replaces_old_without_being_removed_by_it() {
        let agents = DashMap::new();
        let (old_tx, _) = mpsc::unbounded_channel();
        let (old_replacement, mut old_replacement_rx) = mpsc::unbounded_channel();
        install_agent_connection(
            &agents,
            "device-1".into(),
            AgentConnection {
                tx: old_tx.clone(),
                replacement: old_replacement,
                last_heartbeat: Arc::new(AtomicI64::new(Utc::now().timestamp())),
            },
        );

        let (new_tx, _) = mpsc::unbounded_channel();
        let (new_replacement, _) = mpsc::unbounded_channel();
        install_agent_connection(
            &agents,
            "device-1".into(),
            AgentConnection {
                tx: new_tx.clone(),
                replacement: new_replacement,
                last_heartbeat: Arc::new(AtomicI64::new(Utc::now().timestamp())),
            },
        );

        assert_eq!(old_replacement_rx.try_recv(), Ok(()));
        assert!(!remove_current_agent_connection(
            &agents, "device-1", &old_tx
        ));
        assert!(agents.contains_key("device-1"));
        assert!(remove_current_agent_connection(
            &agents, "device-1", &new_tx
        ));
        assert!(!agents.contains_key("device-1"));
    }

    #[test]
    fn agent_token_comparison_rejects_missing_and_different_values() {
        assert!(constant_time_eq(b"agent-secret", b"agent-secret"));
        assert!(!constant_time_eq(b"agent-secret", b"agent-other"));
        assert!(!constant_time_eq(b"agent-secret", b""));
    }

    #[test]
    fn chat_request_does_not_accept_client_selected_device() {
        assert!(serde_json::from_str::<ChatRequest>(r#"{"text":"hello"}"#).is_ok());
        assert!(serde_json::from_str::<ChatRequest>(
            r#"{"device_id":"other-device","text":"hello"}"#
        )
        .is_err());
    }

    #[tokio::test]
    async fn closed_session_cannot_be_reactivated_by_late_accept() {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&db).await.unwrap();
        sqlx::query(
            "INSERT INTO devices (device_id, hostname, os, arch, username, agent_version, local_ip, online, created_at, updated_at) VALUES ('device-1', 'host', 'test', 'test', 'user', 'test', '127.0.0.1', 1, 'now', 'now')",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO sessions (session_id, device_id, status, created_at, closed_at) VALUES ('late', 'device-1', 'closed', 'now', 'now')",
        )
        .execute(&db)
        .await
        .unwrap();

        assert!(!transition_pending_session(&db, "late", "active")
            .await
            .unwrap());
        let (status,): (String,) =
            sqlx::query_as("SELECT status FROM sessions WHERE session_id = 'late'")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(status, "closed");
    }

    #[tokio::test]
    async fn offline_update_requires_the_observed_heartbeat() {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&db).await.unwrap();
        sqlx::query(
            "INSERT INTO devices (device_id, hostname, os, arch, username, agent_version, local_ip, online, last_heartbeat, created_at, updated_at) VALUES ('device-1', 'host', 'test', 'test', 'user', 'test', '127.0.0.1', 1, 'old-heartbeat', 'now', 'now')",
        )
        .execute(&db)
        .await
        .unwrap();

        assert!(!mark_device_offline_if_heartbeat(&db, "device-1", "new-heartbeat")
            .await
            .unwrap());
        assert!(mark_device_offline_if_heartbeat(&db, "device-1", "old-heartbeat")
            .await
            .unwrap());
    }
}
