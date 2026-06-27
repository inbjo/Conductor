use std::{
    collections::{HashMap, HashSet},
    path::{Component, Path, PathBuf},
    time::Duration,
};

use anyhow::{anyhow, Context};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, Utc};
use directories::{BaseDirs, ProjectDirs};
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sysinfo::System;
use tokio::process::Command;
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
    let mut session_frames = HashMap::<String, (u32, u32)>::new();
    let mut input = InputController::new();
    let mut frame_no = 0_u64;

    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                send_json(&mut write, &AgentToServer::AgentHeartbeat { device_id: cfg.device_id.clone() }).await?;
            }
            _ = frame_tick.tick() => {
                for session_id in active_sessions.clone() {
                    frame_no = frame_no.saturating_add(1);
                    let frame = capture_screen_frame(&cfg, &session_id, frame_no).await;
                    session_frames.insert(session_id.clone(), (frame.width, frame.height));
                    send_json(&mut write, &AgentToServer::ScreenFrame(frame)).await?;
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
                        if let Err(err) = input.apply(&event, session_frames.get(&event.session_id).copied()) {
                            warn!(
                                "control event failed session={} kind={}: {err}",
                                event.session_id, event.kind
                            );
                        }
                    }
                    Ok(ServerToAgent::RemoteControlRequest { session_id }) => {
                        info!("remote control requested: {session_id}");
                        active_sessions.insert(session_id.clone());
                        send_json(&mut write, &AgentToServer::SessionAccept { session_id: session_id.clone() }).await?;
                        let frame = capture_screen_frame(&cfg, &session_id, frame_no).await;
                        session_frames.insert(session_id.clone(), (frame.width, frame.height));
                        send_json(&mut write, &AgentToServer::ScreenFrame(frame)).await?;
                        send_json(&mut write, &AgentToServer::WebrtcOffer {
                            session_id: session_id.clone(),
                            sdp: "placeholder-offer: screen capture and WebRTC transport are reserved for the next implementation pass".into(),
                        }).await?;
                    }
                    Ok(ServerToAgent::SessionClose { session_id }) => {
                        info!("session closed by server: {session_id}");
                        active_sessions.remove(&session_id);
                        session_frames.remove(&session_id);
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

async fn capture_screen_frame(cfg: &Config, session_id: &str, frame_no: u64) -> ScreenFramePayload {
    match tokio::time::timeout(Duration::from_secs(3), capture_real_frame(session_id)).await {
        Ok(Ok(frame)) => frame,
        Ok(Err(err)) => {
            warn!("real screen capture failed, using demo frame: {err}");
            make_demo_frame(cfg, session_id, frame_no)
        }
        Err(_) => {
            warn!("real screen capture timed out, using demo frame");
            make_demo_frame(cfg, session_id, frame_no)
        }
    }
}

async fn capture_real_frame(session_id: &str) -> anyhow::Result<ScreenFramePayload> {
    let capture = capture_real_frame_bytes().await?;
    let (width, height) = parse_png_dimensions(&capture.bytes).unwrap_or((1280, 720));
    info!(
        "screen captured via {}: {}x{} {} bytes",
        capture.backend,
        width,
        height,
        capture.bytes.len()
    );
    Ok(ScreenFramePayload {
        session_id: session_id.to_string(),
        width,
        height,
        image_data_url: format!("data:image/png;base64,{}", B64.encode(&capture.bytes)),
        captured_at: Utc::now(),
    })
}

fn parse_png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 24 || &bytes[0..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    Some((width, height))
}

struct FrameCapture {
    backend: &'static str,
    bytes: Vec<u8>,
}

async fn capture_real_frame_bytes() -> anyhow::Result<FrameCapture> {
    let mut errors = Vec::new();

    #[cfg(target_os = "linux")]
    {
        for backend in [
            CaptureBackend::Stdout {
                name: "grim",
                program: "grim",
                args: &["-c", "-t", "png", "-"],
            },
            CaptureBackend::File {
                name: "gnome-screenshot",
                program: "gnome-screenshot",
                args: &["-f", "{output}"],
            },
            CaptureBackend::File {
                name: "import",
                program: "import",
                args: &["-window", "root", "{output}"],
            },
        ] {
            match capture_with_backend(backend).await {
                Ok(frame) => return Ok(frame),
                Err(err) => errors.push(format!("{}: {err}", backend.name())),
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let backend = CaptureBackend::File {
            name: "screencapture",
            program: "screencapture",
            args: &["-x", "-t", "png", "{output}"],
        };
        match capture_with_backend(backend).await {
            Ok(frame) => return Ok(frame),
            Err(err) => errors.push(format!("{}: {err}", backend.name())),
        }
    }

    #[cfg(target_os = "windows")]
    {
        let backend = CaptureBackend::File {
            name: "powershell",
            program: "powershell",
            args: &[
                "-NoProfile",
                "-Command",
                "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen; $bitmap=New-Object System.Drawing.Bitmap $bounds.Width,$bounds.Height; $graphics=[System.Drawing.Graphics]::FromImage($bitmap); $graphics.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bitmap.Size); $bitmap.Save('{output}', [System.Drawing.Imaging.ImageFormat]::Png); $graphics.Dispose(); $bitmap.Dispose();",
            ],
        };
        match capture_with_backend(backend).await {
            Ok(frame) => return Ok(frame),
            Err(err) => errors.push(format!("{}: {err}", backend.name())),
        }
    }

    Err(anyhow!(
        "no screen capture backend succeeded{}",
        if errors.is_empty() {
            String::new()
        } else {
            format!(": {}", errors.join("; "))
        }
    ))
}

#[derive(Clone, Copy)]
enum CaptureBackend {
    Stdout {
        name: &'static str,
        program: &'static str,
        args: &'static [&'static str],
    },
    File {
        name: &'static str,
        program: &'static str,
        args: &'static [&'static str],
    },
}

impl CaptureBackend {
    fn name(&self) -> &'static str {
        match self {
            Self::Stdout { name, .. } | Self::File { name, .. } => name,
        }
    }
}

async fn capture_with_backend(backend: CaptureBackend) -> anyhow::Result<FrameCapture> {
    match backend {
        CaptureBackend::Stdout {
            name,
            program,
            args,
        } => capture_command_stdout(name, program, args).await,
        CaptureBackend::File {
            name,
            program,
            args,
        } => capture_command_file(name, program, args).await,
    }
}

async fn capture_command_stdout(
    backend: &'static str,
    program: &'static str,
    args: &'static [&'static str],
) -> anyhow::Result<FrameCapture> {
    let output = Command::new(program)
        .args(args)
        .output()
        .await
        .with_context(|| format!("run {program}"))?;
    ensure_command_success(backend, &output.status, &output.stderr)?;
    if !looks_like_png(&output.stdout) {
        return Err(anyhow!("command did not output a PNG stream"));
    }
    Ok(FrameCapture {
        backend,
        bytes: output.stdout,
    })
}

async fn capture_command_file(
    backend: &'static str,
    program: &'static str,
    args: &'static [&'static str],
) -> anyhow::Result<FrameCapture> {
    let output_path = temp_capture_path(backend);
    let resolved_args = resolve_capture_args(args, &output_path);
    let output = Command::new(program)
        .args(&resolved_args)
        .output()
        .await
        .with_context(|| format!("run {program}"))?;
    ensure_command_success(backend, &output.status, &output.stderr)?;
    let bytes = tokio::fs::read(&output_path)
        .await
        .with_context(|| format!("read capture file {}", output_path.display()))?;
    let _ = tokio::fs::remove_file(&output_path).await;
    if !looks_like_png(&bytes) {
        return Err(anyhow!("capture file is not a PNG"));
    }
    Ok(FrameCapture { backend, bytes })
}

fn ensure_command_success(
    backend: &str,
    status: &std::process::ExitStatus,
    stderr: &[u8],
) -> anyhow::Result<()> {
    if status.success() {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(stderr).trim().to_string();
    if detail.is_empty() {
        Err(anyhow!("{backend} exited with status {status}"))
    } else {
        Err(anyhow!("{backend} failed: {detail}"))
    }
}

fn resolve_capture_args(args: &[&str], output_path: &Path) -> Vec<String> {
    let output = output_path.to_string_lossy();
    args.iter()
        .map(|arg| arg.replace("{output}", output.as_ref()))
        .collect()
}

fn temp_capture_path(backend: &str) -> PathBuf {
    std::env::temp_dir().join(format!("conductor-{}-{}.png", backend, Uuid::new_v4()))
}

fn looks_like_png(bytes: &[u8]) -> bool {
    bytes.len() >= 8 && &bytes[0..8] == b"\x89PNG\r\n\x1a\n"
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

struct InputController {
    enigo: Option<Enigo>,
}

impl InputController {
    fn new() -> Self {
        Self { enigo: None }
    }

    fn apply(
        &mut self,
        event: &ControlEventPayload,
        frame_size: Option<(u32, u32)>,
    ) -> anyhow::Result<()> {
        let enigo = self.enigo()?;
        match event.kind.as_str() {
            "mouse_move" => {
                let (x, y) = normalized_position(event, frame_size)?;
                enigo.move_mouse(x, y, Coordinate::Abs)?;
            }
            "mouse_click" => {
                let (x, y) = normalized_position(event, frame_size)?;
                enigo.move_mouse(x, y, Coordinate::Abs)?;
                enigo.button(
                    button_from_event(event.button.as_deref())?,
                    Direction::Click,
                )?;
            }
            "mouse_wheel" => {
                let dy = event.delta_y.unwrap_or_default().round() as i32;
                let dx = event.delta_x.unwrap_or_default().round() as i32;
                if dy != 0 {
                    enigo.scroll(dy, Axis::Vertical)?;
                }
                if dx != 0 {
                    enigo.scroll(dx, Axis::Horizontal)?;
                }
            }
            "key_down" => {
                if let Some(text) = event.key.as_deref() {
                    send_key(enigo, text)?;
                }
            }
            other => return Err(anyhow!("unsupported control event: {other}")),
        }
        Ok(())
    }

    fn enigo(&mut self) -> anyhow::Result<&mut Enigo> {
        if self.enigo.is_none() {
            self.enigo = Some(Enigo::new(&Settings::default())?);
        }
        Ok(self.enigo.as_mut().expect("enigo initialized"))
    }
}

fn normalized_position(
    event: &ControlEventPayload,
    frame_size: Option<(u32, u32)>,
) -> anyhow::Result<(i32, i32)> {
    let (width, height) =
        frame_size.ok_or_else(|| anyhow!("screen size is not available for session"))?;
    let x = event.x.ok_or_else(|| anyhow!("mouse x is required"))?;
    let y = event.y.ok_or_else(|| anyhow!("mouse y is required"))?;
    let width = width.max(1);
    let height = height.max(1);
    let x = (x.clamp(0.0, 1.0) * (width.saturating_sub(1) as f32)).round() as i32;
    let y = (y.clamp(0.0, 1.0) * (height.saturating_sub(1) as f32)).round() as i32;
    Ok((x, y))
}

fn button_from_event(button: Option<&str>) -> anyhow::Result<Button> {
    match button.unwrap_or("left").to_ascii_lowercase().as_str() {
        "left" => Ok(Button::Left),
        "right" => Ok(Button::Right),
        "middle" => Ok(Button::Middle),
        other => Err(anyhow!("unsupported mouse button: {other}")),
    }
}

fn send_key(enigo: &mut Enigo, key: &str) -> anyhow::Result<()> {
    if let Some(named) = named_key(key) {
        enigo.key(named, Direction::Click)?;
        return Ok(());
    }
    let mut chars = key.chars();
    match (chars.next(), chars.next()) {
        (Some(ch), None) => {
            enigo.key(Key::Unicode(ch), Direction::Click)?;
            Ok(())
        }
        _ => Err(anyhow!("unsupported key: {key}")),
    }
}

fn named_key(key: &str) -> Option<Key> {
    match key {
        "Enter" => Some(Key::Return),
        "Backspace" => Some(Key::Backspace),
        "Tab" => Some(Key::Tab),
        "Escape" => Some(Key::Escape),
        "Delete" => Some(Key::Delete),
        "ArrowUp" => Some(Key::UpArrow),
        "ArrowDown" => Some(Key::DownArrow),
        "ArrowLeft" => Some(Key::LeftArrow),
        "ArrowRight" => Some(Key::RightArrow),
        "Home" => Some(Key::Home),
        "End" => Some(Key::End),
        "PageUp" => Some(Key::PageUp),
        "PageDown" => Some(Key::PageDown),
        " " => Some(Key::Space),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalized_position_clamps_to_frame_bounds() {
        let event = ControlEventPayload {
            session_id: "s".into(),
            kind: "mouse_move".into(),
            x: Some(1.4),
            y: Some(-0.3),
            button: None,
            key: None,
            delta_x: None,
            delta_y: None,
            created_at: Utc::now(),
        };
        assert_eq!(
            normalized_position(&event, Some((1920, 1080))).unwrap(),
            (1919, 0)
        );
    }

    #[test]
    fn button_mapping_supports_common_buttons() {
        assert!(matches!(
            button_from_event(Some("left")).unwrap(),
            Button::Left
        ));
        assert!(matches!(
            button_from_event(Some("right")).unwrap(),
            Button::Right
        ));
        assert!(matches!(
            button_from_event(Some("middle")).unwrap(),
            Button::Middle
        ));
    }

    #[test]
    fn named_key_maps_navigation_and_editing_keys() {
        assert!(matches!(named_key("Enter"), Some(Key::Return)));
        assert!(matches!(named_key("Backspace"), Some(Key::Backspace)));
        assert!(matches!(named_key("ArrowLeft"), Some(Key::LeftArrow)));
        assert!(matches!(named_key(" "), Some(Key::Space)));
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
