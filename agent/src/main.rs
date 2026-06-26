use std::{
    collections::HashSet,
    path::{Component, Path, PathBuf},
    time::Duration,
};

use anyhow::{anyhow, Context};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, Utc};
use directories::{BaseDirs, ProjectDirs};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sysinfo::System;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info, warn};
use uuid::Uuid;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone)]
struct Config {
    server_url: String,
    device_id: String,
    root_dir: PathBuf,
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cfg = Config::load().await?;
    info!(
        "agent device_id={} root={}",
        cfg.device_id,
        cfg.root_dir.display()
    );
    loop {
        if let Err(err) = run_agent(cfg.clone()).await {
            warn!("agent connection failed: {err}");
        }
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

impl Config {
    async fn load() -> anyhow::Result<Self> {
        let server_url = std::env::var("CONDUCTOR_SERVER_URL")
            .unwrap_or_else(|_| "ws://127.0.0.1:8080/ws/agent".to_string());
        let dirs = ProjectDirs::from("dev", "conductor", "agent")
            .ok_or_else(|| anyhow!("cannot resolve project config directory"))?;
        tokio::fs::create_dir_all(dirs.config_dir()).await?;
        let id_path = dirs.config_dir().join("device_id");
        let device_id = match tokio::fs::read_to_string(&id_path).await {
            Ok(id) if Uuid::parse_str(id.trim()).is_ok() => id.trim().to_string(),
            Ok(_) | Err(_) => {
                let id = Uuid::new_v4().to_string();
                tokio::fs::write(&id_path, &id).await?;
                id
            }
        };
        let root_dir = BaseDirs::new()
            .and_then(|d| Some(d.home_dir().to_path_buf()))
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        Ok(Self {
            server_url,
            device_id,
            root_dir,
        })
    }
}

async fn run_agent(cfg: Config) -> anyhow::Result<()> {
    let (ws, _) = connect_async(&cfg.server_url)
        .await
        .with_context(|| format!("connect {}", cfg.server_url))?;
    let (mut write, mut read) = ws.split();
    send_json(
        &mut write,
        &AgentToServer::AgentRegister(registration(&cfg)),
    )
    .await?;
    let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
    let mut frame_tick = tokio::time::interval(Duration::from_millis(1000));
    let mut active_sessions = HashSet::<String>::new();
    let mut frame_no = 0_u64;

    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                send_json(&mut write, &AgentToServer::AgentHeartbeat { device_id: cfg.device_id.clone() }).await?;
            }
            _ = frame_tick.tick() => {
                for session_id in active_sessions.clone() {
                    frame_no = frame_no.saturating_add(1);
                    send_json(&mut write, &AgentToServer::ScreenFrame(make_demo_frame(&cfg, &session_id, frame_no))).await?;
                }
            }
            msg = read.next() => {
                let Some(msg) = msg else { return Err(anyhow!("server closed websocket")); };
                let msg = msg?;
                let Message::Text(text) = msg else { continue };
                match serde_json::from_str::<ServerToAgent>(&text) {
                    Ok(ServerToAgent::FileCommand(cmd)) => {
                        let result = handle_file_command(&cfg, cmd).await;
                        send_json(&mut write, &AgentToServer::FileResult(result)).await?;
                    }
                    Ok(ServerToAgent::ChatMessage(msg)) => {
                        println!("[chat][{}][admin] {}", msg.session_id, msg.text);
                        let reply = ChatPayload {
                            message_id: Uuid::new_v4().to_string(),
                            session_id: msg.session_id,
                            device_id: cfg.device_id.clone(),
                            sender: "agent".into(),
                            text: "Agent received: message shown in console".into(),
                            created_at: Utc::now(),
                        };
                        send_json(&mut write, &AgentToServer::ChatMessage(reply)).await?;
                    }
                    Ok(ServerToAgent::ControlEvent(event)) => {
                        info!(
                            "control event session={} kind={} x={:?} y={:?} key={:?} button={:?}",
                            event.session_id, event.kind, event.x, event.y, event.key, event.button
                        );
                    }
                    Ok(ServerToAgent::RemoteControlRequest { session_id }) => {
                        info!("remote control requested: {session_id}");
                        active_sessions.insert(session_id.clone());
                        send_json(&mut write, &AgentToServer::SessionAccept { session_id: session_id.clone() }).await?;
                        send_json(&mut write, &AgentToServer::ScreenFrame(make_demo_frame(&cfg, &session_id, frame_no))).await?;
                        send_json(&mut write, &AgentToServer::WebrtcOffer {
                            session_id: session_id.clone(),
                            sdp: "placeholder-offer: screen capture and WebRTC transport are reserved for the next implementation pass".into(),
                        }).await?;
                    }
                    Ok(ServerToAgent::SessionClose { session_id }) => {
                        info!("session closed by server: {session_id}");
                        active_sessions.remove(&session_id);
                    }
                    Ok(ServerToAgent::WebrtcOffer { session_id, sdp }) => {
                        info!("received admin offer for session {session_id}: {} bytes", sdp.len());
                    }
                    Ok(ServerToAgent::WebrtcAnswer { session_id, sdp }) => {
                        info!("received admin answer for session {session_id}: {} bytes", sdp.len());
                    }
                    Ok(ServerToAgent::WebrtcIceCandidate { session_id, candidate }) => {
                        info!("received ICE candidate for session {session_id}: {candidate}");
                    }
                    Ok(ServerToAgent::VoiceRequest { session_id }) => {
                        info!("voice requested for session {session_id}; accepting placeholder voice channel");
                        send_json(&mut write, &AgentToServer::VoiceAccept { session_id }).await?;
                    }
                    Ok(ServerToAgent::VoiceMute { session_id, muted }) => {
                        info!("voice mute changed for session {session_id}: {muted}");
                    }
                    Ok(ServerToAgent::VoiceHangup { session_id }) => {
                        info!("voice hangup for session {session_id}");
                        send_json(&mut write, &AgentToServer::VoiceHangup { session_id }).await?;
                    }
                    Err(err) => {
                        error!("invalid server message: {err}");
                        send_json(&mut write, &AgentToServer::Error { message: err.to_string() }).await?;
                    }
                }
            }
        }
    }
}

fn make_demo_frame(cfg: &Config, session_id: &str, frame_no: u64) -> ScreenFramePayload {
    let now = Utc::now();
    let registration = registration(cfg);
    let pulse = 30 + (frame_no % 70);
    let svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
<defs>
  <linearGradient id="bg" x1="0" x2="1" y1="0" y2="1">
    <stop offset="0" stop-color="#111817"/>
    <stop offset="1" stop-color="#22312d"/>
  </linearGradient>
  <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
    <path d="M 48 0 L 0 0 0 48" fill="none" stroke="#ffffff" stroke-opacity=".08" stroke-width="1"/>
  </pattern>
</defs>
<rect width="1280" height="720" fill="url(#bg)"/>
<rect width="1280" height="720" fill="url(#grid)"/>
<rect x="64" y="64" width="1152" height="592" rx="10" fill="#f8faf7" fill-opacity=".92"/>
<rect x="96" y="106" width="{pulse}" height="10" fill="#0b7a75"/>
<text x="96" y="174" font-family="monospace" font-size="34" fill="#101418">Conductor Agent Screen</text>
<text x="96" y="232" font-family="monospace" font-size="22" fill="#38413d">Host: {host}</text>
<text x="96" y="272" font-family="monospace" font-size="22" fill="#38413d">OS: {os}</text>
<text x="96" y="312" font-family="monospace" font-size="22" fill="#38413d">User: {user}</text>
<text x="96" y="352" font-family="monospace" font-size="22" fill="#38413d">Session: {session}</text>
<text x="96" y="424" font-family="monospace" font-size="48" fill="#0b7a75">Frame #{frame}</text>
<text x="96" y="480" font-family="monospace" font-size="20" fill="#6b746f">Captured at {time}</text>
<circle cx="1080" cy="170" r="{pulse}" fill="#ad7c2c" fill-opacity=".22"/>
<circle cx="1080" cy="170" r="18" fill="#0b7a75"/>
</svg>"##,
        pulse = pulse,
        host = escape_xml(&registration.hostname),
        os = escape_xml(&registration.os),
        user = escape_xml(&registration.username),
        session = escape_xml(session_id),
        frame = frame_no,
        time = escape_xml(&now.to_rfc3339()),
    );
    ScreenFramePayload {
        session_id: session_id.to_string(),
        width: 1280,
        height: 720,
        image_data_url: format!("data:image/svg+xml;base64,{}", B64.encode(svg.as_bytes())),
        captured_at: now,
    }
}

fn escape_xml(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

async fn send_json<S: Serialize>(
    write: &mut futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        Message,
    >,
    value: &S,
) -> anyhow::Result<()> {
    write
        .send(Message::Text(serde_json::to_string(value)?))
        .await?;
    Ok(())
}

fn registration(cfg: &Config) -> DeviceRegistration {
    let mut sys = System::new_all();
    sys.refresh_all();
    DeviceRegistration {
        device_id: cfg.device_id.clone(),
        hostname: std::env::var("CONDUCTOR_AGENT_NAME")
            .ok()
            .or_else(|| hostname::get().ok().and_then(|v| v.into_string().ok()))
            .unwrap_or_else(|| "unknown-host".into()),
        os: System::long_os_version().unwrap_or_else(|| std::env::consts::OS.into()),
        arch: std::env::consts::ARCH.into(),
        username: std::env::var("USER")
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_else(|_| "unknown".into()),
        agent_version: VERSION.into(),
        local_ip: local_ip_address::local_ip()
            .map(|ip| ip.to_string())
            .unwrap_or_else(|_| "127.0.0.1".into()),
    }
}

async fn handle_file_command(cfg: &Config, cmd: FileCommandPayload) -> FileResultPayload {
    match handle_file_command_inner(cfg, &cmd).await {
        Ok(mut ok) => {
            ok.request_id = cmd.request_id;
            ok
        }
        Err(err) => FileResultPayload {
            request_id: cmd.request_id,
            ok: false,
            error: Some(err.to_string()),
            entries: None,
            content_base64: None,
        },
    }
}

async fn handle_file_command_inner(
    cfg: &Config,
    cmd: &FileCommandPayload,
) -> anyhow::Result<FileResultPayload> {
    let path = safe_path(&cfg.root_dir, &cmd.path)?;
    match cmd.command.as_str() {
        "list" => {
            let mut entries = Vec::new();
            let mut rd = tokio::fs::read_dir(&path).await?;
            while let Some(entry) = rd.next_entry().await? {
                let meta = entry.metadata().await?;
                let full = entry.path();
                let rel = full.strip_prefix(&cfg.root_dir).unwrap_or(&full);
                entries.push(FileEntry {
                    name: entry.file_name().to_string_lossy().to_string(),
                    path: rel.to_string_lossy().replace('\\', "/"),
                    is_dir: meta.is_dir(),
                    size: meta.len(),
                    modified: meta
                        .modified()
                        .ok()
                        .map(DateTime::<Utc>::from)
                        .map(|dt| dt.to_rfc3339()),
                });
            }
            entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
            Ok(file_ok().entries(entries))
        }
        "download" => {
            let bytes = tokio::fs::read(&path).await?;
            Ok(file_ok().content_base64(B64.encode(bytes)))
        }
        "upload" => {
            let name = cmd
                .name
                .as_deref()
                .ok_or_else(|| anyhow!("file name is required"))?;
            if name.contains('/') || name.contains('\\') || name.contains("..") {
                return Err(anyhow!("invalid file name"));
            }
            tokio::fs::create_dir_all(&path).await?;
            let bytes = B64.decode(cmd.content_base64.as_deref().unwrap_or_default())?;
            tokio::fs::write(path.join(name), bytes).await?;
            Ok(file_ok())
        }
        "delete" => {
            let meta = tokio::fs::metadata(&path).await?;
            if meta.is_dir() {
                tokio::fs::remove_dir_all(&path).await?;
            } else {
                tokio::fs::remove_file(&path).await?;
            }
            Ok(file_ok())
        }
        "mkdir" => {
            let name = cmd
                .name
                .as_deref()
                .ok_or_else(|| anyhow!("directory name is required"))?;
            if name.contains('/') || name.contains('\\') || name.contains("..") {
                return Err(anyhow!("invalid directory name"));
            }
            tokio::fs::create_dir_all(path.join(name)).await?;
            Ok(file_ok())
        }
        other => Err(anyhow!("unknown file command: {other}")),
    }
}

fn safe_path(root: &Path, input: &str) -> anyhow::Result<PathBuf> {
    let input = input
        .trim()
        .trim_start_matches('/')
        .trim_start_matches('\\');
    let mut out = root.to_path_buf();
    for component in Path::new(input).components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::CurDir => {}
            _ => return Err(anyhow!("path traversal is not allowed")),
        }
    }
    Ok(out)
}

fn file_ok() -> FileResultPayload {
    FileResultPayload {
        request_id: String::new(),
        ok: true,
        error: None,
        entries: None,
        content_base64: None,
    }
}

trait FileResultExt {
    fn entries(self, entries: Vec<FileEntry>) -> Self;
    fn content_base64(self, content: String) -> Self;
}

impl FileResultExt for FileResultPayload {
    fn entries(mut self, entries: Vec<FileEntry>) -> Self {
        self.entries = Some(entries);
        self
    }

    fn content_base64(mut self, content: String) -> Self {
        self.content_base64 = Some(content);
        self
    }
}
