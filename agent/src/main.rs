use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Component, Path, PathBuf},
    process::Command as StdCommand,
    sync::Arc,
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
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info, warn};
use uuid::Uuid;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::{RTCRtpCodecCapability, RTPCodecType};
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;
use webrtc::track::track_remote::TrackRemote;
use webrtc::{
    api::media_engine::{MIME_TYPE_OPUS, MIME_TYPE_VP8},
    media::Sample,
};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone)]
struct Config {
    server_url: String,
    agent_token: String,
    device_id: String,
    root_dir: PathBuf,
    interactive_approval: bool,
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

struct RtcSession {
    peer_connection: Arc<RTCPeerConnection>,
    video_track: Arc<TrackLocalStaticSample>,
    audio_track: Arc<TrackLocalStaticSample>,
}

struct AudioCaptureTask(JoinHandle<()>);

impl AudioCaptureTask {
    fn is_finished(&self) -> bool {
        self.0.is_finished()
    }
}

impl Drop for AudioCaptureTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::load().await?;
    let agent_name = non_empty_env("CONDUCTOR_AGENT_NAME").unwrap_or_else(|| "<hostname>".into());
    let audio_input = non_empty_env("CONDUCTOR_AUDIO_INPUT").unwrap_or_else(|| "default".into());
    info!(
        "agent config device_id={} server_url={} root={} agent_name={} audio_input={} interactive_approval={} token_present={}",
        cfg.device_id,
        cfg.server_url,
        cfg.root_dir.display(),
        agent_name,
        audio_input,
        cfg.interactive_approval,
        !cfg.agent_token.is_empty()
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
        let root_dir = configured_root_dir(std::env::var("CONDUCTOR_AGENT_ROOT").ok().as_deref())
            .or_else(|| BaseDirs::new().map(|d| d.home_dir().to_path_buf()))
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        Ok(Self {
            server_url,
            agent_token: std::env::var("CONDUCTOR_AGENT_TOKEN")
                .unwrap_or_else(|_| "dev-agent-token-change-me".to_string()),
            device_id,
            root_dir,
            interactive_approval: env_flag("CONDUCTOR_INTERACTIVE_APPROVAL"),
        })
    }
}

async fn run_agent(cfg: Config) -> anyhow::Result<()> {
    let connection_url = authenticated_server_url(&cfg.server_url, &cfg.agent_token)?;
    let (ws, _) = connect_async(&connection_url)
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
    let rtc_api = build_webrtc_api()?;
    let (rtc_tx, mut rtc_rx) = mpsc::unbounded_channel::<AgentToServer>();
    let (rtc_control_tx, mut rtc_control_rx) = mpsc::unbounded_channel::<ControlEventPayload>();
    let mut rtc_sessions = HashMap::<String, Arc<RtcSession>>::new();
    let mut voice_sessions = HashSet::<String>::new();
    let mut audio_capture_tasks = HashMap::<String, AudioCaptureTask>::new();
    let mut session_frames = HashMap::<String, (u32, u32)>::new();
    let mut input = InputController::new();
    let mut console = AgentConsole::new(
        cfg.device_id.clone(),
        cfg.root_dir.clone(),
        cfg.interactive_approval,
    );
    let mut stdin_lines = BufReader::new(tokio::io::stdin()).lines();
    let mut stdin_open = true;
    let mut frame_no = 0_u64;

    console.print_banner();

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
                    if let Some(rtc) = rtc_sessions.get(&session_id) {
                        if let Err(err) = send_screen_frame_to_rtc(&rtc.video_track, &frame).await {
                            warn!("rtc screen frame failed session={session_id}: {err}");
                        }
                    }
                    send_json(&mut write, &AgentToServer::ScreenFrame(frame)).await?;
                }
            }
            Some(rtc_msg) = rtc_rx.recv() => {
                send_json(&mut write, &rtc_msg).await?;
            }
            Some(control_event) = rtc_control_rx.recv() => {
                if let Err(err) = input.apply(&control_event, session_frames.get(&control_event.session_id).copied()) {
                    warn!(
                        "rtc control failed session={} kind={}: {err}",
                        control_event.session_id, control_event.kind
                    );
                }
            }
            line = stdin_lines.next_line(), if stdin_open => {
                match line {
                    Ok(Some(line)) => {
                        if let Some(action) = console.handle_stdin(&line) {
                            match action {
                                ConsoleAction::SendChat(outgoing) => {
                                    send_json(&mut write, &AgentToServer::ChatMessage(outgoing)).await?;
                                }
                                ConsoleAction::AcceptSession { session_id } => {
                                    active_sessions.insert(session_id.clone());
                                    console.mark_session_accepted(&session_id);
                                    send_json(&mut write, &AgentToServer::SessionAccept { session_id: session_id.clone() }).await?;
                                    let frame = capture_screen_frame(&cfg, &session_id, frame_no).await;
                                    session_frames.insert(session_id.clone(), (frame.width, frame.height));
                                    send_json(&mut write, &AgentToServer::ScreenFrame(frame)).await?;
                                }
                                ConsoleAction::RejectSession { session_id, reason } => {
                                    console.mark_session_rejected(&session_id);
                                    send_json(&mut write, &AgentToServer::SessionReject { session_id, reason }).await?;
                                }
                                ConsoleAction::AcceptVoice { session_id } => {
                                    console.mark_voice_resolved(&session_id);
                                    voice_sessions.insert(session_id.clone());
                                    start_audio_capture(
                                        &session_id,
                                        &rtc_sessions,
                                        &mut audio_capture_tasks,
                                    );
                                    send_json(&mut write, &AgentToServer::VoiceAccept { session_id }).await?;
                                }
                                ConsoleAction::RejectVoice { session_id, reason } => {
                                    console.mark_voice_resolved(&session_id);
                                    voice_sessions.remove(&session_id);
                                    stop_audio_capture(&session_id, &mut audio_capture_tasks);
                                    send_json(&mut write, &AgentToServer::VoiceReject { session_id, reason }).await?;
                                }
                            }
                        }
                    }
                    Ok(None) => {
                        stdin_open = false;
                        info!("agent stdin closed; local chat input disabled");
                    }
                    Err(err) => {
                        stdin_open = false;
                        warn!("read local stdin failed: {err}");
                    }
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
                        console.receive(msg);
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
                        console.track_session(&session_id);
                        if cfg.interactive_approval {
                            console.queue_session_request(&session_id);
                        } else {
                            active_sessions.insert(session_id.clone());
                            send_json(&mut write, &AgentToServer::SessionAccept { session_id: session_id.clone() }).await?;
                            let frame = capture_screen_frame(&cfg, &session_id, frame_no).await;
                            session_frames.insert(session_id.clone(), (frame.width, frame.height));
                            send_json(&mut write, &AgentToServer::ScreenFrame(frame)).await?;
                        }
                    }
                    Ok(ServerToAgent::SessionClose { session_id }) => {
                        info!("session closed by server: {session_id}");
                        active_sessions.remove(&session_id);
                        session_frames.remove(&session_id);
                        if let Some(rtc) = rtc_sessions.remove(&session_id) {
                            let _ = rtc.peer_connection.close().await;
                        }
                        voice_sessions.remove(&session_id);
                        stop_audio_capture(&session_id, &mut audio_capture_tasks);
                        console.close_session(&session_id);
                    }
                    Ok(ServerToAgent::WebrtcOffer { session_id, sdp }) => {
                        let rtc = ensure_rtc_session(
                            &rtc_api,
                            &mut rtc_sessions,
                            &session_id,
                            rtc_tx.clone(),
                            rtc_control_tx.clone(),
                        )
                        .await?;
                        if voice_sessions.contains(&session_id) {
                            start_audio_capture(
                                &session_id,
                                &rtc_sessions,
                                &mut audio_capture_tasks,
                            );
                        }
                        let answer_sdp = apply_browser_offer(&rtc.peer_connection, &sdp).await?;
                        send_json(&mut write, &AgentToServer::WebrtcAnswer {
                            session_id,
                            sdp: answer_sdp,
                        }).await?;
                    }
                    Ok(ServerToAgent::WebrtcAnswer { session_id, sdp }) => {
                        info!("received admin answer for session {session_id}: {} bytes", sdp.len());
                    }
                    Ok(ServerToAgent::WebrtcIceCandidate { session_id, candidate }) => {
                        let Some(rtc) = rtc_sessions.get(&session_id) else {
                            warn!("received ICE candidate for unknown rtc session {session_id}");
                            continue;
                        };
                        let candidate: RTCIceCandidateInit = serde_json::from_value(candidate)
                            .with_context(|| format!("invalid ICE candidate for session {session_id}"))?;
                        rtc.peer_connection.add_ice_candidate(candidate).await
                            .with_context(|| format!("add ICE candidate for session {session_id}"))?;
                    }
                    Ok(ServerToAgent::VoiceRequest { session_id }) => {
                        if cfg.interactive_approval {
                            console.queue_voice_request(&session_id);
                        } else {
                            info!("voice requested for session {session_id}; accepting voice channel");
                            voice_sessions.insert(session_id.clone());
                            start_audio_capture(
                                &session_id,
                                &rtc_sessions,
                                &mut audio_capture_tasks,
                            );
                            send_json(&mut write, &AgentToServer::VoiceAccept { session_id }).await?;
                        }
                    }
                    Ok(ServerToAgent::VoiceMute { session_id, muted }) => {
                        info!("voice mute changed for session {session_id}: {muted}");
                        if muted {
                            stop_audio_capture(&session_id, &mut audio_capture_tasks);
                        } else if voice_sessions.contains(&session_id) {
                            start_audio_capture(
                                &session_id,
                                &rtc_sessions,
                                &mut audio_capture_tasks,
                            );
                        }
                    }
                    Ok(ServerToAgent::VoiceHangup { session_id }) => {
                        info!("voice hangup for session {session_id}");
                        voice_sessions.remove(&session_id);
                        stop_audio_capture(&session_id, &mut audio_capture_tasks);
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

fn authenticated_server_url(server_url: &str, agent_token: &str) -> anyhow::Result<String> {
    let normalized = normalize_agent_server_url(server_url)?;
    let mut url = url::Url::parse(&normalized).context("invalid agent server URL")?;
    let existing = url
        .query_pairs()
        .filter(|(key, _)| key != "token")
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    url.set_query(None);
    {
        let mut query = url.query_pairs_mut();
        for (key, value) in existing {
            query.append_pair(&key, &value);
        }
        query.append_pair("token", agent_token);
    }
    Ok(url.into())
}

fn normalize_agent_server_url(server_url: &str) -> anyhow::Result<String> {
    let mut text = server_url.trim().to_string();
    if text.is_empty() {
        return Err(anyhow!("agent server URL is empty"));
    }
    if !text.contains("://") {
        text = format!("ws://{text}");
    }
    if let Some(rest) = text.strip_prefix("http://") {
        text = format!("ws://{rest}");
    } else if let Some(rest) = text.strip_prefix("https://") {
        text = format!("wss://{rest}");
    }

    let mut url = url::Url::parse(&text).context("invalid agent server URL")?;
    if url.scheme() != "ws" && url.scheme() != "wss" {
        return Err(anyhow!("agent server URL must use ws, wss, http, or https"));
    }
    if url.host_str().map(str::is_empty).unwrap_or(true) {
        return Err(anyhow!("agent server URL host is required"));
    }
    if url.path().is_empty() || url.path() == "/" {
        url.set_path("/ws/agent");
    }
    Ok(url.into())
}

fn build_webrtc_api() -> anyhow::Result<webrtc::api::API> {
    let mut media_engine = MediaEngine::default();
    media_engine
        .register_default_codecs()
        .context("register webrtc codecs")?;
    Ok(APIBuilder::new().with_media_engine(media_engine).build())
}

async fn ensure_rtc_session(
    api: &webrtc::api::API,
    sessions: &mut HashMap<String, Arc<RtcSession>>,
    session_id: &str,
    rtc_tx: mpsc::UnboundedSender<AgentToServer>,
    control_tx: mpsc::UnboundedSender<ControlEventPayload>,
) -> anyhow::Result<Arc<RtcSession>> {
    if let Some(pc) = sessions.get(session_id) {
        return Ok(Arc::clone(pc));
    }

    let pc = Arc::new(
        api.new_peer_connection(RTCConfiguration::default())
            .await
            .with_context(|| format!("create rtc peer connection for session {session_id}"))?,
    );

    let ice_session = session_id.to_string();
    let ice_tx = rtc_tx.clone();
    pc.on_ice_candidate(Box::new(move |candidate: Option<RTCIceCandidate>| {
        let ice_session = ice_session.clone();
        let ice_tx = ice_tx.clone();
        Box::pin(async move {
            let Some(candidate) = candidate else {
                return;
            };
            match candidate.to_json() {
                Ok(json) => {
                    let payload = serde_json::to_value(json).unwrap_or(Value::Null);
                    let _ = ice_tx.send(AgentToServer::WebrtcIceCandidate {
                        session_id: ice_session,
                        candidate: payload,
                    });
                }
                Err(err) => warn!("serialize local ICE candidate failed: {err}"),
            }
        })
    }));

    let data_session = session_id.to_string();
    pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
        let data_session = data_session.clone();
        let control_tx = control_tx.clone();
        Box::pin(async move {
            let label = dc.label().to_string();
            let open_label = label.clone();
            let open_session = data_session.clone();
            dc.on_open(Box::new(move || {
                let label = open_label.clone();
                let open_session = open_session.clone();
                Box::pin(async move {
                    info!(
                        "rtc data channel opened session={} label={}",
                        open_session, label
                    );
                })
            }));
            dc.on_message(Box::new(move |msg: DataChannelMessage| {
                let text = String::from_utf8_lossy(&msg.data).to_string();
                let data_session = data_session.clone();
                let control_tx = control_tx.clone();
                let channel_label = label.clone();
                Box::pin(async move {
                    if channel_label == "control" {
                        match serde_json::from_str::<ControlEventPayload>(&text) {
                            Ok(event) => {
                                let _ = control_tx.send(event);
                            }
                            Err(err) => warn!(
                                "invalid rtc control payload session={} err={} body={}",
                                data_session, err, text
                            ),
                        }
                    } else {
                        info!(
                            "rtc data message session={} label={} bytes={} text={}",
                            data_session,
                            channel_label,
                            msg.data.len(),
                            text
                        );
                    }
                })
            }));
        })
    }));

    let audio_session = session_id.to_string();
    pc.on_track(Box::new(move |track, _, _| {
        let audio_session = audio_session.clone();
        Box::pin(async move {
            if track.kind() != RTPCodecType::Audio {
                return;
            }
            let codec = track.codec().capability.mime_type;
            if !codec.eq_ignore_ascii_case("audio/opus") {
                warn!(
                    "unsupported rtc audio codec session={} codec={}",
                    audio_session, codec
                );
                return;
            }
            tokio::spawn(async move {
                if let Err(err) = play_remote_opus(track, &audio_session).await {
                    warn!("rtc audio playback failed session={audio_session}: {err}");
                }
            });
        })
    }));

    let video_track = Arc::new(TrackLocalStaticSample::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_VP8.to_owned(),
            ..Default::default()
        },
        "screen".to_string(),
        "conductor-agent".to_string(),
    ));
    let sender = pc
        .add_track(Arc::clone(&video_track) as Arc<dyn TrackLocal + Send + Sync>)
        .await
        .with_context(|| format!("add rtc screen track for session {session_id}"))?;
    tokio::spawn(async move { while sender.read_rtcp().await.is_ok() {} });

    let audio_track = Arc::new(TrackLocalStaticSample::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_OPUS.to_owned(),
            clock_rate: 48_000,
            channels: 2,
            ..Default::default()
        },
        "microphone".to_string(),
        "conductor-agent".to_string(),
    ));
    let audio_sender = pc
        .add_track(Arc::clone(&audio_track) as Arc<dyn TrackLocal + Send + Sync>)
        .await
        .with_context(|| format!("add rtc microphone track for session {session_id}"))?;
    tokio::spawn(async move { while audio_sender.read_rtcp().await.is_ok() {} });

    let rtc = Arc::new(RtcSession {
        peer_connection: pc,
        video_track,
        audio_track,
    });
    sessions.insert(session_id.to_string(), Arc::clone(&rtc));
    Ok(rtc)
}

async fn send_screen_frame_to_rtc(
    track: &TrackLocalStaticSample,
    frame: &ScreenFramePayload,
) -> anyhow::Result<()> {
    let png = frame
        .image_data_url
        .strip_prefix("data:image/png;base64,")
        .ok_or_else(|| anyhow!("screen frame is not PNG"))?;
    let png = B64.decode(png).context("decode screen frame PNG")?;
    let vp8 = encode_png_as_vp8(&png).await?;
    track
        .write_sample(&Sample {
            data: vp8.into(),
            duration: Duration::from_secs(1),
            ..Default::default()
        })
        .await
        .context("write VP8 screen sample")
}

async fn encode_png_as_vp8(png: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut child = Command::new("ffmpeg")
        .args([
            "-loglevel",
            "error",
            "-f",
            "image2pipe",
            "-vcodec",
            "png",
            "-i",
            "pipe:0",
            "-frames:v",
            "1",
            "-an",
            "-c:v",
            "libvpx",
            "-deadline",
            "realtime",
            "-cpu-used",
            "8",
            "-f",
            "ivf",
            "pipe:1",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("start ffmpeg VP8 encoder")?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("ffmpeg stdin unavailable"))?;
    stdin.write_all(png).await.context("write PNG to ffmpeg")?;
    drop(stdin);
    let output = child
        .wait_with_output()
        .await
        .context("wait for ffmpeg VP8 encoder")?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffmpeg VP8 encoder failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    parse_single_ivf_frame(&output.stdout)
}

fn parse_single_ivf_frame(ivf: &[u8]) -> anyhow::Result<Vec<u8>> {
    const IVF_HEADER_LEN: usize = 32;
    const FRAME_HEADER_LEN: usize = 12;
    if ivf.len() < IVF_HEADER_LEN + FRAME_HEADER_LEN || &ivf[..4] != b"DKIF" {
        return Err(anyhow!("invalid IVF stream"));
    }
    let size = u32::from_le_bytes(ivf[32..36].try_into().unwrap()) as usize;
    let start = IVF_HEADER_LEN + FRAME_HEADER_LEN;
    let end = start
        .checked_add(size)
        .filter(|end| *end <= ivf.len())
        .ok_or_else(|| anyhow!("truncated IVF frame"))?;
    Ok(ivf[start..end].to_vec())
}

async fn play_remote_opus(track: Arc<TrackRemote>, session_id: &str) -> anyhow::Result<()> {
    let mut child = Command::new("ffplay")
        .args([
            "-nodisp",
            "-autoexit",
            "-loglevel",
            "error",
            "-f",
            "ogg",
            "-i",
            "pipe:0",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("start ffplay for rtc audio")?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("ffplay stdin unavailable"))?;
    let serial = Uuid::new_v4().as_u128() as u32;
    stdin
        .write_all(&ogg_opus_headers(serial))
        .await
        .context("write Ogg Opus headers")?;
    let mut sequence = 2_u32;
    let mut first_timestamp = None;
    info!("rtc audio playback started session={session_id}");

    while let Ok((packet, _)) = track.read_rtp().await {
        if packet.payload.is_empty() {
            continue;
        }
        let origin = *first_timestamp.get_or_insert(packet.header.timestamp);
        let granule = packet.header.timestamp.wrapping_sub(origin) as u64 + 960;
        let page = build_ogg_page(serial, sequence, granule, 0, &packet.payload);
        stdin
            .write_all(&page)
            .await
            .context("write remote Opus packet")?;
        sequence = sequence.wrapping_add(1);
    }

    drop(stdin);
    let output = child.wait_with_output().await.context("wait for ffplay")?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffplay exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

fn start_audio_capture(
    session_id: &str,
    rtc_sessions: &HashMap<String, Arc<RtcSession>>,
    tasks: &mut HashMap<String, AudioCaptureTask>,
) {
    if tasks
        .get(session_id)
        .is_some_and(|task| !task.is_finished())
    {
        return;
    }
    tasks.remove(session_id);
    let Some(rtc) = rtc_sessions.get(session_id) else {
        info!("rtc microphone waiting for peer connection session={session_id}");
        return;
    };
    let track = Arc::clone(&rtc.audio_track);
    let task_session = session_id.to_string();
    let log_session = task_session.clone();
    let task = tokio::spawn(async move {
        if let Err(err) = capture_microphone_to_rtc(track, &task_session).await {
            warn!("rtc microphone capture failed session={task_session}: {err}");
        }
    });
    tasks.insert(log_session, AudioCaptureTask(task));
}

fn stop_audio_capture(session_id: &str, tasks: &mut HashMap<String, AudioCaptureTask>) {
    if tasks.remove(session_id).is_some() {
        info!("rtc microphone capture stopped session={session_id}");
    }
}

async fn capture_microphone_to_rtc(
    track: Arc<TrackLocalStaticSample>,
    session_id: &str,
) -> anyhow::Result<()> {
    let mut command = microphone_ffmpeg_command();
    let mut child = command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("start ffmpeg microphone capture")?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("ffmpeg microphone output unavailable"))?;
    let mut reader = OggPacketReader::new(stdout);
    info!("rtc microphone capture started session={session_id}");
    while let Some(packet) = reader.next_packet().await? {
        if packet.starts_with(b"OpusHead") || packet.starts_with(b"OpusTags") {
            continue;
        }
        track
            .write_sample(&Sample {
                data: packet.into(),
                duration: Duration::from_millis(20),
                ..Default::default()
            })
            .await
            .context("write microphone Opus sample")?;
    }
    let status = child.wait().await.context("wait for microphone ffmpeg")?;
    if !status.success() {
        return Err(anyhow!("microphone ffmpeg exited with {status}"));
    }
    Ok(())
}

fn microphone_ffmpeg_command() -> Command {
    let input = std::env::var("CONDUCTOR_AUDIO_INPUT").ok();
    let mut command = Command::new("ffmpeg");
    command.args(["-loglevel", "error"]);
    if cfg!(target_os = "linux") {
        command.args(["-f", "pulse", "-i", input.as_deref().unwrap_or("default")]);
    } else if cfg!(target_os = "macos") {
        command.args(["-f", "avfoundation", "-i", input.as_deref().unwrap_or(":0")]);
    } else if cfg!(target_os = "windows") {
        command.args([
            "-f",
            "dshow",
            "-i",
            &format!("audio={}", input.as_deref().unwrap_or("default")),
        ]);
    }
    command.args([
        "-vn",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-c:a",
        "libopus",
        "-application",
        "voip",
        "-frame_duration",
        "20",
        "-f",
        "ogg",
        "pipe:1",
    ]);
    command
}

struct OggPacketReader<R> {
    reader: R,
    partial: Vec<u8>,
    queued: VecDeque<Vec<u8>>,
}

impl<R: AsyncRead + Unpin> OggPacketReader<R> {
    fn new(reader: R) -> Self {
        Self {
            reader,
            partial: Vec::new(),
            queued: VecDeque::new(),
        }
    }

    async fn next_packet(&mut self) -> anyhow::Result<Option<Vec<u8>>> {
        loop {
            if let Some(packet) = self.queued.pop_front() {
                return Ok(Some(packet));
            }
            let mut header = [0_u8; 27];
            match self.reader.read_exact(&mut header).await {
                Ok(_) => {}
                Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
                Err(err) => return Err(err).context("read Ogg page header"),
            }
            if &header[..4] != b"OggS" || header[4] != 0 {
                return Err(anyhow!("invalid Ogg page from microphone encoder"));
            }
            let mut laces = vec![0_u8; header[26] as usize];
            self.reader
                .read_exact(&mut laces)
                .await
                .context("read Ogg segment table")?;
            let body_len = laces.iter().map(|lace| *lace as usize).sum();
            let mut body = vec![0_u8; body_len];
            self.reader
                .read_exact(&mut body)
                .await
                .context("read Ogg page body")?;
            let mut offset = 0;
            for lace in laces {
                let end = offset + lace as usize;
                self.partial.extend_from_slice(&body[offset..end]);
                offset = end;
                if lace < 255 {
                    self.queued.push_back(std::mem::take(&mut self.partial));
                }
            }
        }
    }
}

fn ogg_opus_headers(serial: u32) -> Vec<u8> {
    let mut opus_head = Vec::with_capacity(19);
    opus_head.extend_from_slice(b"OpusHead");
    opus_head.push(1);
    opus_head.push(2);
    opus_head.extend_from_slice(&0_u16.to_le_bytes());
    opus_head.extend_from_slice(&48_000_u32.to_le_bytes());
    opus_head.extend_from_slice(&0_i16.to_le_bytes());
    opus_head.push(0);

    let vendor = b"Conductor";
    let mut opus_tags = Vec::with_capacity(20 + vendor.len());
    opus_tags.extend_from_slice(b"OpusTags");
    opus_tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    opus_tags.extend_from_slice(vendor);
    opus_tags.extend_from_slice(&0_u32.to_le_bytes());

    let mut headers = build_ogg_page(serial, 0, 0, 2, &opus_head);
    headers.extend_from_slice(&build_ogg_page(serial, 1, 0, 0, &opus_tags));
    headers
}

fn build_ogg_page(
    serial: u32,
    sequence: u32,
    granule_position: u64,
    header_type: u8,
    packet: &[u8],
) -> Vec<u8> {
    let full_segments = packet.len() / 255;
    let needs_terminator = packet.len().is_multiple_of(255);
    let segment_count = full_segments + 1;
    assert!(segment_count <= u8::MAX as usize, "Ogg packet too large");

    let mut page = Vec::with_capacity(27 + segment_count + packet.len());
    page.extend_from_slice(b"OggS");
    page.push(0);
    page.push(header_type);
    page.extend_from_slice(&granule_position.to_le_bytes());
    page.extend_from_slice(&serial.to_le_bytes());
    page.extend_from_slice(&sequence.to_le_bytes());
    page.extend_from_slice(&0_u32.to_le_bytes());
    page.push(segment_count as u8);
    page.extend(std::iter::repeat_n(255, full_segments));
    if needs_terminator {
        page.push(0);
    } else {
        page.push((packet.len() % 255) as u8);
    }
    page.extend_from_slice(packet);
    let checksum = ogg_crc(&page);
    page[22..26].copy_from_slice(&checksum.to_le_bytes());
    page
}

fn ogg_crc(bytes: &[u8]) -> u32 {
    let mut crc = 0_u32;
    for byte in bytes {
        crc ^= (*byte as u32) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04c1_1db7
            } else {
                crc << 1
            };
        }
    }
    crc
}

async fn apply_browser_offer(pc: &RTCPeerConnection, sdp: &str) -> anyhow::Result<String> {
    let offer = RTCSessionDescription::offer(sdp.to_string()).context("parse remote offer sdp")?;
    pc.set_remote_description(offer)
        .await
        .context("set remote offer")?;

    let answer = pc.create_answer(None).await.context("create rtc answer")?;
    let mut gather_complete = pc.gathering_complete_promise().await;
    pc.set_local_description(answer)
        .await
        .context("set local answer")?;
    let _ = tokio::time::timeout(Duration::from_secs(3), gather_complete.recv()).await;
    let local = pc
        .local_description()
        .await
        .ok_or_else(|| anyhow!("missing local rtc answer"))?;
    Ok(local.sdp)
}

struct AgentConsole {
    device_id: String,
    root_dir: PathBuf,
    current_session: Option<String>,
    known_sessions: Vec<String>,
    interactive_approval: bool,
    pending_session_requests: Vec<String>,
    pending_voice_requests: Vec<String>,
}

impl AgentConsole {
    fn new(device_id: String, root_dir: PathBuf, interactive_approval: bool) -> Self {
        Self {
            device_id,
            root_dir,
            current_session: None,
            known_sessions: Vec::new(),
            interactive_approval,
            pending_session_requests: Vec::new(),
            pending_voice_requests: Vec::new(),
        }
    }

    fn print_banner(&self) {
        println!("Agent console ready.");
        println!("  /help                   查看聊天命令");
        println!("  /sessions               查看可回复的会话");
        println!("  /use <session_id>       切换当前会话");
        println!("  /reply <id> <text>      向指定会话发送回复");
        println!("  /diagnostics            输出本机依赖和权限排障信息");
        println!("  直接输入文本            发送到当前会话");
        if self.interactive_approval {
            println!("  /requests               查看待处理的远控/语音请求");
            println!("  /session accept <id>    接受远控请求");
            println!("  /session reject <id> [reason]");
            println!("  /voice accept <id>      接受语音请求");
            println!("  /voice reject <id> [reason]");
        }
    }

    fn receive(&mut self, msg: ChatPayload) {
        self.track_session(&msg.session_id);
        self.current_session = Some(msg.session_id.clone());
        println!();
        println!("[chat][{}][admin] {}", msg.session_id, msg.text);
        println!("当前会话 -> {}", msg.session_id);
        println!("输入回复内容发送，或使用 /reply <id> <text>");
    }

    fn track_session(&mut self, session_id: &str) {
        if self.known_sessions.iter().any(|id| id == session_id) {
            return;
        }
        self.known_sessions.push(session_id.to_string());
    }

    fn close_session(&mut self, session_id: &str) {
        self.known_sessions.retain(|id| id != session_id);
        self.pending_session_requests.retain(|id| id != session_id);
        self.pending_voice_requests.retain(|id| id != session_id);
        if self.current_session.as_deref() == Some(session_id) {
            self.current_session = self.known_sessions.last().cloned();
        }
        println!("[chat] session closed: {session_id}");
    }

    fn queue_session_request(&mut self, session_id: &str) {
        self.track_session(session_id);
        if !self
            .pending_session_requests
            .iter()
            .any(|id| id == session_id)
        {
            self.pending_session_requests.push(session_id.to_string());
        }
        println!("[session] remote control requested: {session_id}");
        println!(
            "[session] use /session accept {session_id} or /session reject {session_id} <reason>"
        );
    }

    fn queue_voice_request(&mut self, session_id: &str) {
        self.track_session(session_id);
        if !self
            .pending_voice_requests
            .iter()
            .any(|id| id == session_id)
        {
            self.pending_voice_requests.push(session_id.to_string());
        }
        println!("[voice] request received: {session_id}");
        println!("[voice] use /voice accept {session_id} or /voice reject {session_id} <reason>");
    }

    fn mark_session_accepted(&mut self, session_id: &str) {
        self.pending_session_requests.retain(|id| id != session_id);
        self.current_session = Some(session_id.to_string());
        println!("[session] accepted: {session_id}");
    }

    fn mark_session_rejected(&mut self, session_id: &str) {
        self.pending_session_requests.retain(|id| id != session_id);
        println!("[session] rejected: {session_id}");
    }

    fn mark_voice_resolved(&mut self, session_id: &str) {
        self.pending_voice_requests.retain(|id| id != session_id);
    }

    fn handle_stdin(&mut self, line: &str) -> Option<ConsoleAction> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        match parse_console_command(line, self.current_session.as_deref()) {
            ConsoleCommand::Help => {
                self.print_banner();
                None
            }
            ConsoleCommand::Sessions => {
                self.print_sessions();
                None
            }
            ConsoleCommand::Requests => {
                self.print_requests();
                None
            }
            ConsoleCommand::Diagnostics => {
                self.print_diagnostics();
                None
            }
            ConsoleCommand::Use { session_id } => {
                if self.known_sessions.iter().any(|id| id == &session_id) {
                    self.current_session = Some(session_id.clone());
                    println!("[chat] current session -> {session_id}");
                } else {
                    println!("[chat] unknown session: {session_id}");
                }
                None
            }
            ConsoleCommand::Send { session_id, text } => {
                self.track_session(&session_id);
                self.current_session = Some(session_id.clone());
                println!("[chat][{}][agent] {}", session_id, text);
                Some(ConsoleAction::SendChat(ChatPayload {
                    message_id: Uuid::new_v4().to_string(),
                    session_id,
                    device_id: self.device_id.clone(),
                    sender: "agent".into(),
                    text,
                    created_at: Utc::now(),
                }))
            }
            ConsoleCommand::AcceptSession { session_id } => {
                if self
                    .pending_session_requests
                    .iter()
                    .any(|id| id == &session_id)
                {
                    Some(ConsoleAction::AcceptSession { session_id })
                } else {
                    println!("[session] no pending request: {session_id}");
                    None
                }
            }
            ConsoleCommand::RejectSession { session_id, reason } => {
                if self
                    .pending_session_requests
                    .iter()
                    .any(|id| id == &session_id)
                {
                    Some(ConsoleAction::RejectSession { session_id, reason })
                } else {
                    println!("[session] no pending request: {session_id}");
                    None
                }
            }
            ConsoleCommand::AcceptVoice { session_id } => {
                if self
                    .pending_voice_requests
                    .iter()
                    .any(|id| id == &session_id)
                {
                    Some(ConsoleAction::AcceptVoice { session_id })
                } else {
                    println!("[voice] no pending request: {session_id}");
                    None
                }
            }
            ConsoleCommand::RejectVoice { session_id, reason } => {
                if self
                    .pending_voice_requests
                    .iter()
                    .any(|id| id == &session_id)
                {
                    Some(ConsoleAction::RejectVoice { session_id, reason })
                } else {
                    println!("[voice] no pending request: {session_id}");
                    None
                }
            }
            ConsoleCommand::Error(message) => {
                println!("[chat] {message}");
                None
            }
        }
    }

    fn print_sessions(&self) {
        if self.known_sessions.is_empty() {
            println!("[chat] no active sessions");
            return;
        }
        println!("[chat] sessions:");
        for session_id in &self.known_sessions {
            let marker = if self.current_session.as_deref() == Some(session_id.as_str()) {
                "*"
            } else {
                " "
            };
            println!("{} {}", marker, session_id);
        }
    }

    fn print_requests(&self) {
        if self.pending_session_requests.is_empty() && self.pending_voice_requests.is_empty() {
            println!("[requests] no pending requests");
            return;
        }
        if !self.pending_session_requests.is_empty() {
            println!("[requests] session:");
            for session_id in &self.pending_session_requests {
                println!("  - {session_id}");
            }
        }
        if !self.pending_voice_requests.is_empty() {
            println!("[requests] voice:");
            for session_id in &self.pending_voice_requests {
                println!("  - {session_id}");
            }
        }
    }

    fn print_diagnostics(&self) {
        for line in diagnostics_lines(&self.device_id, &self.root_dir, self.interactive_approval) {
            println!("{line}");
        }
    }
}

enum ConsoleAction {
    SendChat(ChatPayload),
    AcceptSession { session_id: String },
    RejectSession { session_id: String, reason: String },
    AcceptVoice { session_id: String },
    RejectVoice { session_id: String, reason: String },
}

enum ConsoleCommand {
    Help,
    Sessions,
    Requests,
    Diagnostics,
    Use { session_id: String },
    Send { session_id: String, text: String },
    AcceptSession { session_id: String },
    RejectSession { session_id: String, reason: String },
    AcceptVoice { session_id: String },
    RejectVoice { session_id: String, reason: String },
    Error(String),
}

fn parse_console_command(line: &str, current_session: Option<&str>) -> ConsoleCommand {
    let trimmed = line.trim();
    if trimmed.eq_ignore_ascii_case("/help") {
        return ConsoleCommand::Help;
    }
    if trimmed.eq_ignore_ascii_case("/sessions") {
        return ConsoleCommand::Sessions;
    }
    if trimmed.eq_ignore_ascii_case("/requests") {
        return ConsoleCommand::Requests;
    }
    if trimmed.eq_ignore_ascii_case("/diagnostics") {
        return ConsoleCommand::Diagnostics;
    }
    if let Some(rest) = trimmed.strip_prefix("/use ") {
        let session_id = rest.trim();
        return if session_id.is_empty() {
            ConsoleCommand::Error("usage: /use <session_id>".into())
        } else {
            ConsoleCommand::Use {
                session_id: session_id.to_string(),
            }
        };
    }
    if let Some(rest) = trimmed.strip_prefix("/reply ") {
        let mut parts = rest.trim().splitn(2, char::is_whitespace);
        let session_id = parts.next().unwrap_or("").trim();
        let text = parts.next().unwrap_or("").trim();
        return if session_id.is_empty() || text.is_empty() {
            ConsoleCommand::Error("usage: /reply <session_id> <text>".into())
        } else {
            ConsoleCommand::Send {
                session_id: session_id.to_string(),
                text: text.to_string(),
            }
        };
    }
    if let Some(rest) = trimmed.strip_prefix("/session ") {
        return parse_request_command(rest, "session");
    }
    if let Some(rest) = trimmed.strip_prefix("/voice ") {
        return parse_request_command(rest, "voice");
    }
    if let Some(session_id) = current_session.filter(|id| !id.trim().is_empty()) {
        return ConsoleCommand::Send {
            session_id: session_id.to_string(),
            text: trimmed.to_string(),
        };
    }
    ConsoleCommand::Error("no current session; use /sessions or /reply <session_id> <text>".into())
}

fn parse_request_command(rest: &str, kind: &str) -> ConsoleCommand {
    let mut parts = rest.trim().splitn(3, char::is_whitespace);
    let action = parts.next().unwrap_or("").trim();
    let session_id = parts.next().unwrap_or("").trim();
    let reason = parts.next().unwrap_or("").trim();
    match (kind, action, session_id.is_empty(), reason.is_empty()) {
        (_, "", _, _) => ConsoleCommand::Error(format!(
            "usage: /{kind} <accept|reject> <session_id> [reason]"
        )),
        (_, _, true, _) => ConsoleCommand::Error(format!(
            "usage: /{kind} <accept|reject> <session_id> [reason]"
        )),
        ("session", "accept", false, _) => ConsoleCommand::AcceptSession {
            session_id: session_id.to_string(),
        },
        ("session", "reject", false, true) => ConsoleCommand::RejectSession {
            session_id: session_id.to_string(),
            reason: "rejected by agent user".into(),
        },
        ("session", "reject", false, false) => ConsoleCommand::RejectSession {
            session_id: session_id.to_string(),
            reason: reason.to_string(),
        },
        ("voice", "accept", false, _) => ConsoleCommand::AcceptVoice {
            session_id: session_id.to_string(),
        },
        ("voice", "reject", false, true) => ConsoleCommand::RejectVoice {
            session_id: session_id.to_string(),
            reason: "voice request rejected by agent user".into(),
        },
        ("voice", "reject", false, false) => ConsoleCommand::RejectVoice {
            session_id: session_id.to_string(),
            reason: reason.to_string(),
        },
        _ => ConsoleCommand::Error(format!(
            "usage: /{kind} <accept|reject> <session_id> [reason]"
        )),
    }
}

fn diagnostics_lines(device_id: &str, root_dir: &Path, interactive_approval: bool) -> Vec<String> {
    let audio_input = non_empty_env("CONDUCTOR_AUDIO_INPUT").unwrap_or_else(|| "default".into());
    let mut lines = vec![
        "[diagnostics] conductor-agent".to_string(),
        format!("[diagnostics] version={VERSION}"),
        format!("[diagnostics] os={}", std::env::consts::OS),
        format!("[diagnostics] arch={}", std::env::consts::ARCH),
        format!("[diagnostics] device_id={device_id}"),
        format!("[diagnostics] root={}", root_dir.display()),
        format!("[diagnostics] audio_input={audio_input}"),
        format!("[diagnostics] interactive_approval={interactive_approval}"),
    ];

    lines.push("[diagnostics] screen capture backends:".to_string());
    for command in screen_capture_dependency_commands() {
        lines.push(format!(
            "[diagnostics]   {command}: {}",
            command_status(command)
        ));
    }

    lines.push("[diagnostics] audio dependencies:".to_string());
    for command in audio_dependency_commands() {
        lines.push(format!(
            "[diagnostics]   {command}: {}",
            command_status(command)
        ));
    }
    lines
}

fn screen_capture_dependency_commands() -> &'static [&'static str] {
    if cfg!(target_os = "linux") {
        &["grim", "gnome-screenshot", "import"]
    } else if cfg!(target_os = "macos") {
        &["screencapture"]
    } else if cfg!(target_os = "windows") {
        &["powershell"]
    } else {
        &[]
    }
}

fn audio_dependency_commands() -> &'static [&'static str] {
    &["ffmpeg", "ffplay"]
}

fn command_status(command: &str) -> &'static str {
    if command_available(command) {
        "found"
    } else {
        "missing"
    }
}

fn command_available(command: &str) -> bool {
    if cfg!(target_os = "windows") {
        StdCommand::new("where")
            .arg(command)
            .output()
            .is_ok_and(|output| output.status.success())
    } else {
        StdCommand::new("sh")
            .args(["-c", "command -v \"$1\" >/dev/null 2>&1", "sh", command])
            .output()
            .is_ok_and(|output| output.status.success())
    }
}

fn env_flag(name: &str) -> bool {
    flag_value(std::env::var(name).ok().as_deref())
}

fn flag_value(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim),
        Some("1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON")
    )
}

fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn configured_root_dir(value: Option<&str>) -> Option<PathBuf> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
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

    #[test]
    fn local_chat_command_uses_current_session_for_plain_text() {
        match parse_console_command("hello operator", Some("session-1")) {
            ConsoleCommand::Send { session_id, text } => {
                assert_eq!(session_id, "session-1");
                assert_eq!(text, "hello operator");
            }
            _ => panic!("expected send command"),
        }
    }

    #[test]
    fn local_chat_command_parses_reply_with_explicit_session() {
        match parse_console_command("/reply session-2  confirm reboot", None) {
            ConsoleCommand::Send { session_id, text } => {
                assert_eq!(session_id, "session-2");
                assert_eq!(text, "confirm reboot");
            }
            _ => panic!("expected explicit send command"),
        }
    }

    #[test]
    fn local_chat_command_requires_session_when_plain_text_used() {
        match parse_console_command("hello", None) {
            ConsoleCommand::Error(message) => {
                assert!(message.contains("no current session"));
            }
            _ => panic!("expected error"),
        }
    }

    #[test]
    fn console_command_parses_session_accept() {
        match parse_console_command("/session accept session-3", None) {
            ConsoleCommand::AcceptSession { session_id } => assert_eq!(session_id, "session-3"),
            _ => panic!("expected session accept command"),
        }
    }

    #[test]
    fn console_command_defaults_session_reject_reason() {
        match parse_console_command("/session reject session-4", None) {
            ConsoleCommand::RejectSession { session_id, reason } => {
                assert_eq!(session_id, "session-4");
                assert_eq!(reason, "rejected by agent user");
            }
            _ => panic!("expected session reject command"),
        }
    }

    #[test]
    fn console_command_parses_voice_reject_reason() {
        match parse_console_command("/voice reject session-5 microphone busy", None) {
            ConsoleCommand::RejectVoice { session_id, reason } => {
                assert_eq!(session_id, "session-5");
                assert_eq!(reason, "microphone busy");
            }
            _ => panic!("expected voice reject command"),
        }
    }

    #[test]
    fn console_command_parses_diagnostics() {
        assert!(matches!(
            parse_console_command("/diagnostics", None),
            ConsoleCommand::Diagnostics
        ));
        assert!(matches!(
            parse_console_command("/DIAGNOSTICS", None),
            ConsoleCommand::Diagnostics
        ));
    }

    #[test]
    fn diagnostics_include_platform_and_dependency_sections() {
        let lines = diagnostics_lines("device-1", Path::new("/tmp/root"), true);
        assert!(lines.iter().any(|line| line.contains("device_id=device-1")));
        assert!(lines.iter().any(|line| line.contains("root=/tmp/root")));
        assert!(lines.iter().any(|line| line.contains("os=")));
        assert!(lines
            .iter()
            .any(|line| line.contains("screen capture backends")));
        assert!(lines.iter().any(|line| line.contains("audio dependencies")));
        assert!(lines.iter().any(|line| line.contains("ffmpeg:")));
    }

    #[test]
    fn ivf_parser_extracts_first_encoded_frame() {
        let mut ivf = vec![0_u8; 44];
        ivf[..4].copy_from_slice(b"DKIF");
        ivf[32..36].copy_from_slice(&4_u32.to_le_bytes());
        ivf.extend_from_slice(&[1, 2, 3, 4]);
        assert_eq!(parse_single_ivf_frame(&ivf).unwrap(), [1, 2, 3, 4]);
    }

    #[test]
    fn ivf_parser_rejects_truncated_frame() {
        let mut ivf = vec![0_u8; 44];
        ivf[..4].copy_from_slice(b"DKIF");
        ivf[32..36].copy_from_slice(&8_u32.to_le_bytes());
        assert!(parse_single_ivf_frame(&ivf).is_err());
    }

    #[test]
    fn ogg_page_uses_terminating_lace_for_exact_segment() {
        let page = build_ogg_page(7, 2, 960, 0, &[0; 255]);
        assert_eq!(&page[..4], b"OggS");
        assert_eq!(page[26], 2);
        assert_eq!(&page[27..29], &[255, 0]);
    }

    #[test]
    fn ogg_page_contains_valid_checksum() {
        let mut page = build_ogg_page(7, 2, 960, 0, b"opus packet");
        let stored = u32::from_le_bytes(page[22..26].try_into().unwrap());
        page[22..26].fill(0);
        assert_eq!(stored, ogg_crc(&page));
    }

    #[test]
    fn opus_headers_include_identification_and_tags_pages() {
        let headers = ogg_opus_headers(42);
        assert_eq!(&headers[..4], b"OggS");
        assert!(headers.windows(8).any(|window| window == b"OpusHead"));
        assert!(headers.windows(8).any(|window| window == b"OpusTags"));
    }

    #[tokio::test]
    async fn ogg_packet_reader_extracts_opus_header_packets() {
        let mut reader = OggPacketReader::new(std::io::Cursor::new(ogg_opus_headers(42)));
        assert!(reader
            .next_packet()
            .await
            .unwrap()
            .unwrap()
            .starts_with(b"OpusHead"));
        assert!(reader
            .next_packet()
            .await
            .unwrap()
            .unwrap()
            .starts_with(b"OpusTags"));
        assert!(reader.next_packet().await.unwrap().is_none());
    }

    #[test]
    fn authenticated_url_preserves_options_and_replaces_token() {
        let url = authenticated_server_url(
            "ws://localhost:8080/ws/agent?mode=test&token=old",
            "new token",
        )
        .unwrap();
        let parsed = url::Url::parse(&url).unwrap();
        let query = parsed.query_pairs().collect::<HashMap<_, _>>();
        assert_eq!(query.get("mode").map(|value| value.as_ref()), Some("test"));
        assert_eq!(
            query.get("token").map(|value| value.as_ref()),
            Some("new token")
        );
    }

    #[test]
    fn agent_server_url_normalization_matches_client_inputs() {
        assert_eq!(
            normalize_agent_server_url("127.0.0.1:8080").unwrap(),
            "ws://127.0.0.1:8080/ws/agent"
        );
        assert_eq!(
            normalize_agent_server_url("http://example.test:8080").unwrap(),
            "ws://example.test:8080/ws/agent"
        );
        assert_eq!(
            normalize_agent_server_url("https://example.test").unwrap(),
            "wss://example.test/ws/agent"
        );
        assert_eq!(
            normalize_agent_server_url("wss://example.test/custom").unwrap(),
            "wss://example.test/custom"
        );
        assert_eq!(
            normalize_agent_server_url("http://example.test/?debug=1").unwrap(),
            "ws://example.test/ws/agent?debug=1"
        );
        assert!(normalize_agent_server_url("file:///tmp/conductor").is_err());
        assert!(normalize_agent_server_url("").is_err());
    }

    #[test]
    fn authenticated_url_normalizes_common_server_url_inputs() {
        let url = authenticated_server_url("https://example.test", "agent token").unwrap();
        let parsed = url::Url::parse(&url).unwrap();
        let query = parsed.query_pairs().collect::<HashMap<_, _>>();
        assert_eq!(parsed.scheme(), "wss");
        assert_eq!(parsed.host_str(), Some("example.test"));
        assert_eq!(parsed.path(), "/ws/agent");
        assert_eq!(
            query.get("token").map(|value| value.as_ref()),
            Some("agent token")
        );
    }

    #[test]
    fn flag_value_accepts_enabled_spellings_only() {
        for value in [
            Some("1"),
            Some("true"),
            Some("TRUE"),
            Some(" yes "),
            Some("ON"),
        ] {
            assert!(flag_value(value), "{value:?}");
        }
        for value in [
            None,
            Some(""),
            Some("0"),
            Some("false"),
            Some("no"),
            Some("random"),
        ] {
            assert!(!flag_value(value), "{value:?}");
        }
    }

    #[test]
    fn configured_root_dir_trims_blank_values() {
        assert_eq!(configured_root_dir(None), None);
        assert_eq!(configured_root_dir(Some("   ")), None);
        assert_eq!(
            configured_root_dir(Some("  /tmp/conductor-root  ")),
            Some(PathBuf::from("/tmp/conductor-root"))
        );
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
