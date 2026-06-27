# 被控客户端开发规划

本文档描述 `client/` Flutter 桌面壳和 `conductor-agent` Rust 核心的后续开发路线。当前目标是先跑通三端构建链路，Ubuntu 本机优先验证 Linux，Windows 作为核心交付目标，macOS 先纳入构建，真实权限和设备能力后续在真机验证。

## 1. 客户端边界

被控客户端由两层组成：

- `client/`：Flutter 桌面壳，负责图形化配置、启动/停止 Agent、展示日志、发送本地审批命令。
- `agent/`：Rust 被控核心，负责注册、心跳、文件管理、远控会话、屏幕采集、输入注入、WebRTC、聊天、语音和本地审批。

Flutter 客户端不重写远控能力。它只把用户输入转换为 `conductor-agent` 的环境变量，并把内置 Agent 作为子进程运行。

## 2. 当前基线

已经完成：

- Linux、Windows、macOS Flutter desktop 工程目录。
- Linux/macOS `scripts/build-client.sh` 构建脚本。
- Windows `scripts/build-client.ps1` 构建脚本。
- 客户端 release 归档校验脚本。
- GitHub Actions 和 Gitea/Forgejo Actions 兼容 workflow。
- RustDesk 风格的主界面/Settings 页分离：主界面只保留状态、启动/停止、命令输入和日志；Server URL、Agent Token、Agent Name、文件根目录、音频输入和本地审批开关都在 Settings 页配置。
- Flutter 客户端 URL 规范化：支持裸地址、HTTP/HTTPS 和自定义 WebSocket 路径。
- Linux/macOS `scripts/build-client.sh` 和 Windows `scripts/build-client.ps1` 支持通过构建参数写入客户端默认配置；未传参数时使用内置默认值，运行后仍可在 Settings 页修改。
- Linux 本机 Flutter analyze、test、bundle 构建和 archive 校验。

当前平台状态：

| 平台 | 状态 | 下一步 |
| --- | --- | --- |
| Linux | Ubuntu 本机已跑通构建和基础启动 | 做真实桌面远控、文件、聊天、语音回归 |
| Windows | 构建脚本和 CI 任务已就绪 | 在 Windows 主机或 runner 上构建、运行、验收 |
| macOS | 构建、归档校验、GUI 启动和 client e2e 自动化已就绪 | 在 macOS runner/真机上验证 `.app`、权限和真实能力 |

## 3. P0：跑通三端客户端构建

目标是每个平台都能产出可分发包，包内包含 Flutter 客户端和对应平台的 `conductor-agent`。

验收标准：

- Linux：`release/conductor-client-linux-x64.tar.gz` 包含 `conductor_client`、`conductor-agent`、Flutter `data/` 和 Linux runtime。
- Windows：`release/conductor-client-windows-x64.zip` 包含 `conductor_client.exe`、`conductor-agent.exe`、Flutter DLL 和 `data/`。
- macOS：`release/conductor-client-macos.tar.gz` 包含 `conductor_client.app` 和 `Contents/MacOS/conductor-agent`。
- 三端 CI workflow 中都有构建、归档校验和 artifact 上传步骤。

当前缺口：

- Windows 需要真实 Windows 环境执行 `scripts/validate-windows-client.ps1`。该脚本会统一调用构建、归档校验、Agent 启动 smoke、Agent E2E、客户端 E2E、GUI 入口 smoke 和 evidence 校验；分步脚本只作为排错入口。
- macOS 需要真实 macOS 环境执行 `scripts/build-client.sh`、`scripts/verify-client-archive.sh macos ...`、`scripts/smoke-client-launch.sh macos ...` 和 `scripts/smoke-macos-client-e2e.sh ...`。
- 自建 Gitea/Forgejo Actions 需要配置 `windows-2022` 和 `macos-14` 对应 runner，否则只能验证 workflow 配置，不能产出平台包。

## 4. P1：跑通 Windows 首次连接流程

Windows 是核心客户端目标。优先验证的不是边界能力，而是端到端流程稳定。

Windows 首次验收步骤：

1. 在 Server 机器启动 `conductor-server`，设置非默认 `CONDUCTOR_AGENT_TOKEN`。
2. 在 Windows 主机运行 `scripts/validate-windows-client.ps1` 完成构建、归档校验、基础 smoke 和 evidence 校验；如需保留证据，传入 `-EvidenceDir .\artifacts\windows-client-smoke`。
3. 解压或直接运行 `client\build\windows\x64\runner\Release\conductor_client.exe`。
4. 打开 Settings 页，填写 `http://<server-ip>:8080` 或 `<server-ip>:8080`，确认客户端自动转换为 `ws://<server-ip>:8080/ws/agent`；也可以在构建时通过 `-ServerUrl` 写入默认值。
5. 在 Settings 页填写正确 Token 和 `Agent Name=win-client-01`；也可以在构建时通过 `-AgentToken`、`-AgentName`、`-AgentRoot`、`-AudioInput`、`-InteractiveApproval` 写入默认值。
6. 点击 `Start Agent`，确认日志没有鉴权失败、WebSocket 连接失败或 agent binary 缺失。
7. 管理后台设备列表出现 `win-client-01`。
8. 验证文件列表、聊天、远控会话创建和关闭。

Windows 后续增强：

- 增加 Windows 端本地运行截图和输入注入的明确诊断日志。
- 记录 Windows Defender、防火墙、Visual C++ runtime 缺失等常见失败点。
- 如果需要后台常驻，再设计服务模式；当前先保持前台 Flutter 壳，便于演示和排错。

## 5. P2：真实能力和权限矩阵

三端基础流程跑通后，再补真实远控能力矩阵。

需要记录：

- OS 版本和桌面环境。
- 是否能真实截图。
- 是否能注入鼠标键盘。
- 文件根目录限制是否生效。
- WebRTC 屏幕视频是否可用。
- 浏览器到 Agent 语音播放是否可用。
- Agent 到浏览器麦克风回传是否可用。
- 降级原因是否能在日志中看懂。

平台验证状态和真机记录模板维护在 `docs/client-platform-matrix.md`，每次 Windows/macOS runner 或真机验证后都应更新该矩阵，避免口头状态漂移。

## 6. P3：Agent 工程化拆分

当前 `agent/src/main.rs` 承载了协议、传输、媒体、文件、输入、审批和 CLI 状态。三端跑通后，再做模块拆分，避免在交付前扩大风险。

建议拆分边界：

- `config`：环境变量、设备 ID、目录、运行模式。
- `protocol`：Agent/Server 消息、文件、聊天、控制、信令类型。
- `transport`：WebSocket 连接、鉴权 URL、发送队列、重连。
- `session`：远控会话状态、审批、关闭、资源释放。
- `screen`：屏幕采集接口、平台实现、回退帧。
- `input`：鼠标键盘事件归一化和平台注入。
- `file_ops`：路径校验、文件命令执行。
- `rtc`：PeerConnection、视频轨、音频轨、DataChannel。
- `audio`：采集、播放、静音、设备参数。
- `console`：本地 CLI 和交互审批。

拆分原则：

- 不在三端首轮验证前重写协议或媒体链路。
- 优先移动代码和补测试，避免同时改变行为。
- server、agent、web 中重复的协议类型后续可提取到 workspace 共享 crate。

## 7. 自动化验证清单

Ubuntu 本机每次客户端改动后至少运行：

```sh
cargo test
/home/flex/Code/flutter/bin/flutter analyze
/home/flex/Code/flutter/bin/flutter test
./scripts/build-client.sh
./scripts/verify-client-archive.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-client-launch.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-linux-client-e2e.sh release/conductor-client-linux-x64.tar.gz
```

Windows runner 或真机运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-windows-client.ps1
```

macOS runner 或真机运行：

```sh
./scripts/build-client.sh
./scripts/verify-client-archive.sh macos release/conductor-client-macos.tar.gz
./scripts/smoke-client-launch.sh macos release/conductor-client-macos.tar.gz
./scripts/smoke-macos-client-e2e.sh release/conductor-client-macos.tar.gz
```
