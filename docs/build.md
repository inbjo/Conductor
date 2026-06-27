# 构建与开发环境说明

本文档用于从一台新机器搭建 Conductor 开发/构建环境，并说明 Linux、Windows、macOS 三端被控客户端的构建方式。

## 1. 组件关系

仓库包含四个主要组件：

- `server/`：Rust Server，提供 API、WebSocket、管理员鉴权、SQLite 持久化和内嵌 Web 静态资源。
- `web/`：React 管理后台，构建后输出到 `web/dist`，由 Server 内嵌。
- `agent/`：Rust 被控端核心，负责注册、心跳、文件、远控、输入、聊天、WebRTC 和语音。
- `client/`：Flutter 桌面被控客户端壳，负责图形化配置、启动/停止 `conductor-agent`、展示日志。

当前客户端策略：

- Linux 先跑通：Flutter 客户端 bundle 内携带 Linux `conductor-agent`。
- Windows 是核心目标：需要在 Windows 主机上构建 `conductor_client.exe` 和 `conductor-agent.exe`。
- macOS 纳入构建目标：CI 会生成 `.app` 归档；真实权限和设备能力后续在 macOS 真机验证。

## 2. 通用依赖

所有开发机器都需要：

- Git
- Rust stable
- Node.js 20+
- npm 10+
- Flutter 3.44+

可选但建议安装：

- `ffmpeg`：Agent WebRTC VP8 屏幕视频编码。
- `ffplay`：Agent 播放浏览器侧语音。
- Chromium/Chrome：浏览器级 smoke test。

检查命令：

```sh
git --version
rustc --version
cargo --version
node --version
npm --version
flutter --version
```

本机 Flutter SDK 当前位于：

```sh
/home/flex/Code/flutter
```

如果 Flutter 不在 `PATH`，Linux/macOS 可以临时设置：

```sh
export PATH="$HOME/Code/flutter/bin:$PATH"
```

Windows PowerShell 可以设置：

```powershell
$env:Path = "$env:USERPROFILE\Code\flutter\bin;$env:Path"
```

## 3. Ubuntu/Linux 开发环境

已验证环境：

- Ubuntu 24.04.2 LTS
- Flutter 3.44.4
- Rust stable

安装基础依赖：

```sh
sudo apt-get update
sudo apt-get install -y build-essential pkg-config curl git
sudo apt-get install -y clang cmake ninja-build libgtk-3-dev
sudo apt-get install -y ffmpeg
```

Flutter Linux desktop 构建依赖说明：

- `clang` 提供 `clang++`，Flutter Linux build 会显式使用它。
- `cmake` 和 `ninja-build` 负责 native runner 构建。
- `libgtk-3-dev` 提供 GTK 3 headers 和 `gtk+-3.0.pc`。

如果安装 `clang` 或 `libgtk-3-dev` 时出现版本冲突，先检查 Ubuntu 标准更新源是否启用：

```sh
cat /etc/apt/sources.list.d/ubuntu.sources
apt-cache policy libgtk-3-dev clang
```

Ubuntu 24.04 通常需要同时启用：

- `noble`
- `noble-updates`
- `noble-security`

启用后重新执行：

```sh
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build libgtk-3-dev
```

检查 Flutter Linux 环境：

```sh
/home/flex/Code/flutter/bin/flutter doctor -v
```

Linux toolchain 应显示通过。Android toolchain 对当前桌面客户端不是必需项。

## 4. Windows 开发环境

Windows 主机需要：

- Windows 10/11 x64
- Git for Windows
- Rust stable MSVC toolchain
- Visual Studio 2022，勾选 `Desktop development with C++`
- Flutter 3.44+，建议放在 `%USERPROFILE%\Code\flutter`
- PowerShell 5+ 或 PowerShell 7+

安装 Rust：

```powershell
winget install Rustlang.Rustup
rustup default stable
```

确认是 MSVC toolchain：

```powershell
rustup show
```

应看到类似：

```text
stable-x86_64-pc-windows-msvc
```

安装 Flutter：

```powershell
git clone https://github.com/flutter/flutter.git $env:USERPROFILE\Code\flutter -b stable
$env:Path = "$env:USERPROFILE\Code\flutter\bin;$env:Path"
flutter doctor -v
```

Windows desktop 构建项必须通过；如果未通过，通常是 Visual Studio C++ workload 缺失。

## 5. macOS 开发环境

macOS 构建主机需要：

- Xcode
- Xcode command line tools
- Rust stable
- Flutter 3.44+
- `ffmpeg`

基础检查：

```sh
xcode-select --install
flutter doctor -v
cargo --version
```

macOS 真实远控还需要用户授权：

- Screen Recording
- Accessibility
- Microphone

当前 macOS Flutter 客户端按演示工具形态构建，`Runner` entitlements 关闭 App Sandbox，以便启动内置 `conductor-agent`、建立网络连接并访问本机文件/音频能力。后续如需 App Store 或企业签名分发，需要重新设计 helper、entitlements 和权限申请流程。

macOS 当前已纳入构建流程；屏幕、输入、语音真实能力仍需要真机权限验证。

## 6. 获取依赖

前端依赖：

```sh
cd web
npm ci
cd ..
```

Flutter 依赖：

```sh
cd client
/home/flex/Code/flutter/bin/flutter pub get
cd ..
```

Rust 依赖由 Cargo 自动解析：

```sh
cargo fetch
```

## 7. 本地开发运行

### 7.1 构建 Web

```sh
cd web
npm run build
cd ..
```

### 7.2 启动 Server

```sh
CONDUCTOR_ADMIN_PASSWORD=admin123 \
CONDUCTOR_AGENT_TOKEN=dev-agent-token-change-me \
cargo run -p conductor-server
```

默认地址：

```text
http://127.0.0.1:8080
```

### 7.3 启动 Rust Agent

```sh
CONDUCTOR_SERVER_URL=ws://127.0.0.1:8080/ws/agent \
CONDUCTOR_AGENT_TOKEN=dev-agent-token-change-me \
CONDUCTOR_AGENT_NAME=linux-dev-agent \
cargo run -p conductor-agent
```

### 7.4 启动 Flutter Client

开发模式：

```sh
cd client
/home/flex/Code/flutter/bin/flutter run -d linux
```

在界面里填写：

- `Server WebSocket URL`：`ws://127.0.0.1:8080/ws/agent`，也可填写 `http://127.0.0.1:8080` 或 `127.0.0.1:8080`，客户端会自动规范化。
- `Agent Token`：`dev-agent-token-change-me`
- `Agent Name`：例如 `linux-client-agent`
- `File Root`：可留空，默认用户 home

点击 `Start Agent` 后，管理后台设备列表应出现该终端。

## 8. 构建 Linux 被控客户端 bundle

推荐使用脚本：

```sh
./scripts/build-client.sh
```

脚本会执行：

1. `cargo build --release -p conductor-agent`
2. `flutter build linux --release`
3. 将 `target/release/conductor-agent` 复制到 Flutter bundle 同目录
4. 生成 `release/conductor-client-linux-x64.tar.gz`

输出目录：

```sh
client/build/linux/x64/release/bundle
```

应包含：

```text
conductor_client
conductor-agent
data/
lib/
```

分发归档：

```sh
release/conductor-client-linux-x64.tar.gz
```

运行：

```sh
client/build/linux/x64/release/bundle/conductor_client
```

非交互启动检查：

```sh
timeout 5s client/build/linux/x64/release/bundle/conductor_client
```

返回 `124` 表示进程被 `timeout` 主动结束；只要没有动态库缺失或 GTK 初始化错误，说明二进制可加载。

## 9. 构建 Windows 被控客户端 bundle

必须在 Windows 主机执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

如果 Flutter 不在默认位置：

```powershell
$env:FLUTTER_BIN = "D:\tools\flutter\bin\flutter.bat"
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

脚本会执行：

1. 检查 `cargo`、`git` 和 `flutter doctor -v`
2. `cargo build --release -p conductor-agent`
3. `flutter build windows --release`
4. 将 `target\release\conductor-agent.exe` 复制到 Flutter bundle 同目录
5. 生成 `release\conductor-client-windows-x64.zip`

输出目录：

```powershell
client\build\windows\x64\runner\Release
```

应包含：

```text
conductor_client.exe
conductor-agent.exe
data\
flutter_windows.dll
```

分发归档：

```powershell
release\conductor-client-windows-x64.zip
```

运行：

```powershell
.\client\build\windows\x64\runner\Release\conductor_client.exe
```

Windows 验收优先级：

1. Client 能启动。
2. 点击 `Start Agent` 后后台出现 Windows 设备。
3. 文件列表可打开。
4. 远控会话可创建并进入 active。
5. 屏幕、输入、聊天逐项验证。

## 10. 构建 macOS 被控客户端 bundle

必须在 macOS 主机执行：

```sh
./scripts/build-client.sh
```

脚本会执行：

1. `cargo build --release -p conductor-agent`
2. `flutter build macos --release`
3. 将 `target/release/conductor-agent` 复制到 `conductor_client.app/Contents/MacOS/`
4. 生成 `release/conductor-client-macos.tar.gz`

输出应用：

```sh
client/build/macos/Build/Products/Release/conductor_client.app
```

分发归档：

```sh
release/conductor-client-macos.tar.gz
```

运行前需要根据系统提示授予权限：

- Screen Recording
- Accessibility
- Microphone

当前 `.app` 是非沙箱演示包，目的是优先跑通被控端流程。

首次跑通优先确认：

1. Client 能启动。
2. 点击 `Start Agent` 后后台出现 macOS 设备。
3. 文件列表可打开。
4. 远控会话可创建。
5. 屏幕、输入、语音在授权后逐项验证。

## 11. 构建 Server release 包

Linux release 包：

```sh
./scripts/build-release.sh
```

指定 target：

```sh
./scripts/build-release.sh x86_64-unknown-linux-gnu
```

输出：

```text
release/conductor-<target>.tar.gz
release/conductor-<target>.tar.gz.sha256
```

注意：`build-release.sh` 当前会拒绝 tracked dirty worktree。构建正式提交包前需要先提交或暂存 tracked 改动。

## 12. GitHub/Gitea Actions 构建

仓库提供两份内容一致的 Actions workflow：

- `.github/workflows/build.yml`：GitHub Actions 使用。
- `.gitea/workflows/build.yml`：Gitea/Forgejo Actions 兼容入口，适配 `git.sina.dev` 这类自建 Git 服务。

触发方式：

- push 到 `master` 或 `main`
- pull request
- 手动 `workflow_dispatch`

CI 会构建并上传四类 artifact：

| Job | Runner | 产物 |
| --- | --- | --- |
| `server-release` | `ubuntu-24.04` | `conductor-server-linux-x64` |
| `client-linux` | `ubuntu-24.04` | `conductor-client-linux-x64` |
| `client-windows` | `windows-2022` | `conductor-client-windows-x64` |
| `client-macos` | `macos-14` | `conductor-client-macos` |

产物文件：

- `release/conductor-x86_64-unknown-linux-gnu.tar.gz`
- `release/conductor-x86_64-unknown-linux-gnu.tar.gz.sha256`
- `release/conductor-client-linux-x64.tar.gz`
- `release/conductor-client-windows-x64.zip`
- `release/conductor-client-macos.tar.gz`

CI 构建流程：

- 服务端：安装 Rust/Node，执行 `scripts/build-release.sh x86_64-unknown-linux-gnu`。
- Linux 客户端：安装 GTK/clang 依赖，执行 `scripts/build-client.sh`，校验归档并做客户端启动/e2e smoke。
- Windows 客户端：安装 Rust/Flutter，执行 `scripts/build-client.ps1`；脚本会启用 Flutter Windows desktop。
- macOS 客户端：安装 Rust/Flutter，执行 `scripts/build-client.sh`，校验归档并做 `.app` 启动 smoke。

注意：Windows 和 macOS 任务需要 CI 平台提供对应系统 runner。自建 Gitea/Forgejo Actions 如果没有 `windows-2022` 或 `macos-14` runner，只会创建任务配置，不能真正产出对应平台包。

## 13. 验证命令

Rust：

```sh
cargo test
cargo build -p conductor-agent
```

Web：

```sh
npm --prefix web ci
npm --prefix web run build
```

Flutter client：

```sh
/home/flex/Code/flutter/bin/flutter analyze
/home/flex/Code/flutter/bin/flutter test
./scripts/build-client.sh
./scripts/verify-client-archive.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-client-launch.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-linux-client-e2e.sh release/conductor-client-linux-x64.tar.gz
```

Release smoke test：

```sh
cd release
sha256sum -c conductor-<target>.tar.gz.sha256
cd ..
tar -xzf release/conductor-<target>.tar.gz -C release/
cd release/conductor-<target>
./scripts/smoke-release.sh .
```

浏览器级检查：

```sh
CONDUCTOR_SMOKE_BROWSER=1 ./scripts/smoke-release.sh .
```

## 14. 常见问题

### Flutter 找不到 SDK

Linux/macOS：

```sh
export FLUTTER_BIN="$HOME/Code/flutter/bin/flutter"
./scripts/build-client.sh
```

Windows：

```powershell
$env:FLUTTER_BIN = "$env:USERPROFILE\Code\flutter\bin\flutter.bat"
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1
```

### Linux 报 `clang++ is required`

安装：

```sh
sudo apt-get install -y clang
```

检查：

```sh
which clang++
clang++ --version
```

### Linux 报 `gtk+-3.0` not found

安装：

```sh
sudo apt-get install -y libgtk-3-dev pkg-config
```

检查：

```sh
pkg-config --modversion gtk+-3.0
```

### Client 启动后找不到 Agent

确认 bundle 同目录存在：

- Linux/macOS：`conductor-agent`
- Windows：`conductor-agent.exe`

也可以通过环境变量指定：

```sh
CONDUCTOR_CLIENT_AGENT_BIN=/absolute/path/to/conductor-agent \
client/build/linux/x64/release/bundle/conductor_client
```

Windows：

```powershell
$env:CONDUCTOR_CLIENT_AGENT_BIN = "C:\path\to\conductor-agent.exe"
.\client\build\windows\x64\runner\Release\conductor_client.exe
```

### 后台看不到设备

检查：

- Server 是否启动。
- Client 中的 `Server WebSocket URL` 是否指向正确 Server。客户端会自动把 `http://host:port` 或 `host:port` 转成 `ws://host:port/ws/agent`。
- Client 中的 Agent Token 是否等于 Server 的 `CONDUCTOR_AGENT_TOKEN`。
- Agent 日志是否出现连接失败或鉴权失败。

### Windows 构建失败找不到 C++ 工具链

打开 Visual Studio Installer，安装：

- `Desktop development with C++`
- Windows 10/11 SDK
- MSVC v143 build tools

然后重新打开 PowerShell，再执行：

```powershell
flutter doctor -v
```
