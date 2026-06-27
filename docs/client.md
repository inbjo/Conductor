# 被控客户端开发与运行

`client/` 是 Flutter 桌面被控客户端壳，当前用于启动和监控现有 Rust `conductor-agent`。真实远控、文件、聊天、语音能力仍由 `conductor-agent` 提供；Flutter 客户端负责图形化配置、启动/停止 Agent、展示日志。

完整开发环境搭建见 `docs/build.md`。本文聚焦被控客户端自身的行为、构建产物和验收方式。

## 设计边界

- Linux：已在 Ubuntu 上完成 Flutter 客户端构建，bundle 中会携带 `conductor-agent`。
- Windows：优先目标平台，需要在 Windows 主机上构建 Flutter Windows 客户端和 Rust `conductor-agent.exe`。
- macOS：纳入构建目标，bundle 中会携带 `conductor-agent`；权限和真实设备能力后续在 macOS 真机验证。

客户端启动时会按顺序寻找 Agent：

1. `CONDUCTOR_CLIENT_AGENT_BIN` 指定的路径。
2. 客户端可执行文件同目录下的 `conductor-agent` 或 `conductor-agent.exe`。
3. 仓库开发环境里的 `target/debug/` 或 `target/release/`。

配置会保存到：

- Linux/macOS：`~/.conductor-client/settings.json`
- Windows：`%USERPROFILE%\.conductor-client\settings.json`

Settings 页字段对应 Agent 环境变量：

| Settings 字段 | Agent 环境变量 | 说明 |
| --- | --- | --- |
| `Server URL` | `CONDUCTOR_SERVER_URL` | Server 地址，客户端会自动补全为 Agent WebSocket 地址 |
| `Agent Token` | `CONDUCTOR_AGENT_TOKEN` | 必须与 Server 一致 |
| `Agent Name` | `CONDUCTOR_AGENT_NAME` | 可选，后台展示用 |
| `File Root` | `CONDUCTOR_AGENT_ROOT` | 可选，限制文件管理根目录 |
| `Audio Input` | `CONDUCTOR_AUDIO_INPUT` | 可选，覆盖 ffmpeg 音频输入 |
| `Require local approval` | `CONDUCTOR_INTERACTIVE_APPROVAL` | 开启后远控/语音需要本地接受 |

Flutter 客户端会把 `Agent Command` 输入框内容写入 `conductor-agent` 标准输入。开启 `Require local approval` 后，可在日志面板顶部发送：

- `/requests`：查看待处理远控/语音请求。
- `/session accept <session_id>`：接受远控请求。
- `/session reject <session_id> [reason]`：拒绝远控请求。
- `/voice accept <session_id>`：接受语音请求。
- `/voice reject <session_id> [reason]`：拒绝语音请求。

日志面板也提供 `/help`、`/sessions`、`/requests` 快捷按钮，便于演示时快速查询状态。

## Linux 构建

Flutter SDK 默认位于：

```sh
/home/flex/Code/flutter
```

Ubuntu 需要安装 Linux desktop 构建依赖：

```sh
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

如果系统 apt 源只启用了 `noble`，没有 `noble-updates`/`noble-security`，安装 `clang` 或 `libgtk-3-dev` 可能出现版本冲突。需要先恢复标准 Ubuntu updates/security 源。

构建客户端 bundle：

```sh
./scripts/build-client.sh
```

输出目录：

```sh
client/build/linux/x64/release/bundle
```

分发归档：

```sh
release/conductor-client-linux-x64.tar.gz
```

其中应包含：

- `conductor_client`
- `conductor-agent`
- `lib/`
- `data/`

运行：

```sh
client/build/linux/x64/release/bundle/conductor_client
```

在界面中确认：

- `Server URL`：在 Settings 页配置，例如 `ws://127.0.0.1:8080/ws/agent`，也可以填写 `http://127.0.0.1:8080` 或 `127.0.0.1:8080`，客户端会自动规范化。
- `Agent Token`：必须与 Server 的 `CONDUCTOR_AGENT_TOKEN` 一致
- `Agent Name`：可选，便于后台识别
- `File Root`：可选，限制文件管理根目录

点击 `Start Agent` 后，后台设备列表应出现该终端。

主界面只显示运行状态、启动/停止入口和日志；Server URL、Agent Token、Agent Name、文件根目录、音频输入和本地审批开关都在 Settings 页配置。构建脚本也可写入这些默认值：

```sh
./scripts/build-client.sh --server-url ws://server:8080/ws/agent --agent-token token
```

手动触发 GitHub/Gitea Actions 的 `workflow_dispatch` 时，也可以填写 `client_server_url`、`client_agent_token`、`client_agent_name`、`client_agent_root`、`client_audio_input` 和 `client_interactive_approval`，CI 会把这些值作为三端客户端的构建默认配置。

Linux 已验证命令：

```sh
/home/flex/Code/flutter/bin/flutter analyze
/home/flex/Code/flutter/bin/flutter test
FLUTTER_BIN=/home/flex/Code/flutter/bin/flutter ./scripts/validate-linux-client.sh
```

`validate-linux-client.sh` 会构建客户端包、构建 Web 静态资源和 smoke server、校验 release tar.gz、启动 `conductor_client` GUI 入口 smoke，再启动 Flutter 客户端并通过 `CONDUCTOR_CLIENT_AUTOSTART=1` 自动拉起包内 Agent，最后确认设备上线。无图形会话时需要安装 `xvfb`，脚本会自动使用 `xvfb-run`。脚本会写出 `artifacts/linux-client-smoke/validation-summary.txt`、`smoke-linux-client-flow.log` 和 `logs/client-e2e/` 原始 server/client 日志，CI 会上传为 `linux-client-smoke-evidence`。

## Windows 构建

Windows 主机需要：

- Flutter SDK，建议放在 `%USERPROFILE%\Code\flutter`
- Rust stable MSVC toolchain
- Visual Studio 2022，安装 `Desktop development with C++`

先检查：

```powershell
flutter doctor -v
cargo --version
```

构建 Windows 客户端 bundle：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

脚本会先启用 Flutter Windows desktop、运行 `flutter doctor -v`，再构建 Rust Agent 和 Flutter Windows 客户端，最后生成可分发 zip。

构建时默认配置参数：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 `
  -ServerUrl "ws://server:8080/ws/agent" `
  -AgentToken "token" `
  -AgentName "windows-client-01" `
  -AgentRoot "$env:USERPROFILE" `
  -AudioInput "default" `
  -InteractiveApproval "false"
```

Windows 构建脚本会优先使用 `FLUTTER_BIN`，未设置时查找 `PATH` 中的 `flutter`，最后回退到 `%USERPROFILE%\Code\flutter\bin\flutter.bat`。如果 Flutter 不在这些位置，指定：

```powershell
$env:FLUTTER_BIN = "D:\tools\flutter\bin\flutter.bat"
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

输出目录：

```powershell
client\build\windows\x64\runner\Release
```

分发归档：

```powershell
release\conductor-client-windows-x64.zip
```

其中应包含：

- `conductor_client.exe`
- `conductor-agent.exe`
- Flutter 运行时 DLL 和 data 目录

校验 zip 结构、完整 smoke 流程和 evidence：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-windows-client.ps1
```

`validate-windows-client.ps1` 会调用 `smoke-windows-client-flow.ps1` 和 `verify-windows-smoke-evidence.ps1`，依次构建客户端包、构建 Web 静态资源和 smoke server、校验 zip、启动包内 Agent、验证包内 Agent 注册、验证 Flutter 客户端自动拉起 Agent 并注册、做 GUI 入口启动 smoke，最后校验证据目录。

如果已经构建过包和 `target\debug\conductor-server.exe`，可以加 `-SkipClientBuild -SkipServerBuild` 只重复校验和 smoke。

需要保留验收证据时，可以指定输出目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-windows-client.ps1 -EvidenceDir .\artifacts\windows-client-smoke
```

脚本会写出 `validation-summary.txt`、`smoke-windows-client-flow.log` 和 `logs/` 下的原始 e2e 日志，用于记录 runner/工具链版本、完整 smoke 输出和 server/client/agent 运行细节。

也可以分开执行 smoke 和证据校验：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1 -EvidenceDir .\artifacts\windows-client-smoke
powershell -ExecutionPolicy Bypass -File .\scripts\verify-windows-smoke-evidence.ps1 -EvidenceDir .\artifacts\windows-client-smoke
```

校验脚本会确认工具链字段不是 `not found`、`result=passed`、transcript 包含成功标记和 `Agent config log observed` 配置传递标记，并要求 `logs/agent-e2e/`、`logs/client-e2e/` 原始日志存在且包含 Agent 配置日志；归档仍存在时会复算 `archive_sha256`。
Linux/Windows 归档校验会确认 Flutter runtime 数据文件 `data/icudtl.dat` 和 `data/flutter_assets` 下的关键 manifest 存在。Linux/macOS 归档校验还会确认客户端主程序和包内 `conductor-agent` 保留可执行位；macOS 归档还会确认 `.app` 的 `Info.plist` 包含麦克风权限说明，并检查 `App.framework`、`FlutterMacOS.framework` 和 `App.framework/Resources/flutter_assets` 下的关键 manifest。
所有 Windows smoke evidence 都必须记录 commit。CI 中会额外传入 `-RequireCiFields -ExpectedCommit $env:GITHUB_SHA`，要求 evidence 中存在 runner OS 和 runner arch，并确认 evidence 的 commit 与当前 workflow commit 一致；手工真机验收会用 `git rev-parse HEAD` 记录 commit，但默认不要求 runner OS/arch 这些 CI 专属字段。

分步排错时可分别运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-client-archive.ps1 -ArchivePath .\release\conductor-client-windows-x64.zip
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-agent-launch.ps1 -ArchivePath .\release\conductor-client-windows-x64.zip
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-agent-e2e.ps1 -ArchivePath .\release\conductor-client-windows-x64.zip
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-e2e.ps1 -ArchivePath .\release\conductor-client-windows-x64.zip
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-client-launch.ps1 -ArchivePath .\release\conductor-client-windows-x64.zip
```

Agent smoke 会解压 zip，从解包目录启动 `conductor-agent.exe`，确认它可以进入连接/重连循环且不会立刻崩溃。Agent E2E smoke 会启动本地 `conductor-server.exe`，再启动包内 Agent，通过 `/api/devices` 确认设备上线，并检查 `agent config` 日志证明环境配置已被读取。Client E2E smoke 会启动 `conductor_client.exe`，通过 `CONDUCTOR_CLIENT_AUTOSTART=1` 让 Flutter 壳自动启动包内 Agent，并确认设备上线，同时通过 `CONDUCTOR_CLIENT_AUTOCOMMANDS=/diagnostics` 验证客户端可以向 Agent stdin 发送本地诊断命令。Client launch smoke 会启动 `conductor_client.exe`，等待数秒确认 GUI 入口没有立刻退出，然后主动结束进程。它们用于发现缺 DLL、入口程序无法启动、归档目录错误、客户端无法拉起 Agent 或 Agent 无法注册到 Server。

客户端启动 Agent 后，可在主界面的 `Agent Command` 输入 `/diagnostics`。Agent 会输出平台、文件根目录、本地审批状态、音频输入、屏幕捕获后端和 `ffmpeg`/`ffplay` 依赖探测结果，便于 Windows/macOS 真机定位权限或缺依赖问题。

自动化 smoke 可用的客户端环境变量：

- `CONDUCTOR_CLIENT_AUTOSTART=1`：客户端启动后自动调用 `Start Agent`。
- `CONDUCTOR_CLIENT_AGENT_BIN`：覆盖客户端要启动的 Agent 路径。
- `CONDUCTOR_CLIENT_SETTINGS_FILE`：覆盖 Settings JSON 保存路径，smoke/CI 中用于隔离用户配置。
- `CONDUCTOR_CLIENT_AUTOCOMMANDS`：客户端启动 Agent 后自动发送的命令，支持换行或分号分隔；CI 用 `/diagnostics` 验证 stdin 命令链路。
- `CONDUCTOR_SERVER_URL`、`CONDUCTOR_AGENT_TOKEN`、`CONDUCTOR_AGENT_NAME`、`CONDUCTOR_AGENT_ROOT`：预填客户端表单，并传给 Agent。

运行 `conductor_client.exe`，在 Settings 页确认 Server 地址、Token、Agent Name、文件根目录、音频输入和本地审批开关后，点击 `Start Agent`。后台设备列表出现该 Windows 终端后，再进入远控页验证屏幕、输入、文件和聊天流程。上述配置也可以通过 `scripts/build-client.ps1` 的构建参数写入默认值。

Windows 首次跑通建议：

1. 在 Server 机器启动 `conductor-server`，确认 Windows 能访问 `http://<server-ip>:8080`。
2. Windows 客户端在 Settings 页填写 `ws://<server-ip>:8080/ws/agent`；也可以填写 `http://<server-ip>:8080` 或 `<server-ip>:8080`，客户端会自动转换。
3. Settings 页中的 Token 与 Server 的 `CONDUCTOR_AGENT_TOKEN` 保持一致。
4. Settings 页中的 `Agent Name` 填写容易识别的名称，例如 `win-client-01`。
5. 点击 `Start Agent`，确认日志没有鉴权失败或连接失败。
6. 后台设备列表出现 `win-client-01` 后，再验证文件列表和远控会话。
7. 如果开启了 `Require local approval`，在 `Agent Command` 中发送 `/requests` 查看会话 ID，再发送 `/session accept <session_id>`。

运行 `smoke-windows-agent-e2e.ps1` 或 `smoke-windows-client-e2e.ps1` 前需要先有 `target\debug\conductor-server.exe`。CI 会先构建 Web 静态资源，再执行 `cargo build -p conductor-server`。

Windows 常见失败点：

- Flutter doctor 的 Windows toolchain 未通过：安装 Visual Studio 2022 C++ workload。
- Server 地址无法连接：先确认浏览器能访问 `http://<server-ip>:8080`，客户端会自动把 HTTP/裸地址转换成 `/ws/agent` WebSocket 地址。
- Windows 防火墙拦截 Server 端口：先用浏览器访问后台确认连通性。
- bundle 中没有 `conductor-agent.exe`：重新执行 `scripts/build-client.ps1`，或手动复制到 `conductor_client.exe` 同目录。

## macOS 构建

macOS 主机执行：

```sh
./scripts/build-client.sh
```

输出应用：

```sh
client/build/macos/Build/Products/Release/conductor_client.app
```

分发归档：

```sh
release/conductor-client-macos.tar.gz
```

脚本会把 `conductor-agent` 放入：

```sh
conductor_client.app/Contents/MacOS/conductor-agent
```

运行前需要根据系统提示授予：

- 屏幕录制权限
- 辅助功能权限
- 麦克风权限

当前 macOS `.app` 关闭 App Sandbox，用于优先跑通演示流程：启动内置 `conductor-agent`、连接 Server、访问文件根目录并调用屏幕/输入/音频能力。正式签名分发需要后续重新收敛权限模型。

macOS 已纳入 CI 构建目标，真实屏幕、输入、语音能力仍需真机验证。

归档结构、启动 smoke、Client e2e 和 evidence：

```sh
./scripts/validate-macos-client.sh
```

`validate-macos-client.sh` 会构建客户端包、构建 Web 静态资源和 smoke server、校验 tar.gz、启动 `.app` GUI 入口 smoke，再通过 `CONDUCTOR_CLIENT_AUTOSTART=1` 启动 `.app` 内的 Flutter 客户端，验证客户端能自动拉起包内 `conductor-agent`、传递运行配置并注册到本地 smoke server。脚本会写出 `artifacts/macos-client-smoke/validation-summary.txt`、`smoke-macos-client-flow.log` 和 `logs/client-e2e/` 原始 server/client 日志，CI 会上传为 `macos-client-smoke-evidence`。
