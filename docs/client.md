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

客户端界面字段对应 Agent 环境变量：

| 界面字段 | Agent 环境变量 | 说明 |
| --- | --- | --- |
| `Server WebSocket URL` | `CONDUCTOR_SERVER_URL` | 必须指向 Server 的 `/ws/agent` |
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

- `Server WebSocket URL`：例如 `ws://127.0.0.1:8080/ws/agent`
- `Agent Token`：必须与 Server 的 `CONDUCTOR_AGENT_TOKEN` 一致
- `Agent Name`：可选，便于后台识别
- `File Root`：可选，限制文件管理根目录

点击 `Start Agent` 后，后台设备列表应出现该终端。

Linux 已验证命令：

```sh
/home/flex/Code/flutter/bin/flutter analyze
/home/flex/Code/flutter/bin/flutter test
./scripts/build-client.sh
timeout 5s client/build/linux/x64/release/bundle/conductor_client
```

`timeout` 返回 `124` 是预期，表示 GUI 进程被测试命令主动结束；只要没有动态库缺失或 GTK 初始化错误，说明 bundle 可加载。

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

脚本会先运行 `flutter doctor -v`，再构建 Rust Agent 和 Flutter Windows 客户端，最后生成可分发 zip。

如果 Flutter 不在默认位置，指定：

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

运行 `conductor_client.exe`，填写 Server 地址和 Token，点击 `Start Agent`。后台设备列表出现该 Windows 终端后，再进入远控页验证屏幕、输入、文件和聊天流程。

Windows 首次跑通建议：

1. 在 Server 机器启动 `conductor-server`，确认 Windows 能访问 `http://<server-ip>:8080`。
2. Windows 客户端填写 `ws://<server-ip>:8080/ws/agent`。
3. Token 与 Server 的 `CONDUCTOR_AGENT_TOKEN` 保持一致。
4. `Agent Name` 填写容易识别的名称，例如 `win-client-01`。
5. 点击 `Start Agent`，确认日志没有鉴权失败或连接失败。
6. 后台设备列表出现 `win-client-01` 后，再验证文件列表和远控会话。
7. 如果开启了 `Require local approval`，在 `Agent Command` 中发送 `/requests` 查看会话 ID，再发送 `/session accept <session_id>`。

Windows 常见失败点：

- Flutter doctor 的 Windows toolchain 未通过：安装 Visual Studio 2022 C++ workload。
- Server 地址写成 `http://`：Agent WebSocket 必须使用 `ws://` 或 `wss://`。
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

macOS 已纳入 CI 构建目标，真实屏幕、输入、语音能力仍需真机验证。
