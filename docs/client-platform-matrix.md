# 被控客户端平台验证矩阵

本文档记录 Linux、Windows、macOS 三端被控客户端的验证状态。它用于区分“脚本和 CI 已覆盖”与“真实平台已经跑过并留下证据”，避免客户端交付状态只停留在口头描述。

## 状态定义

| 状态 | 含义 |
| --- | --- |
| 已验证 | 在对应平台执行过命令，并有明确通过结果。 |
| 自动化覆盖 | CI 或脚本已具备验证步骤，但尚未拿到对应平台通过记录。 |
| 待真机验证 | 需要真实桌面、权限或设备能力，当前不能只靠构建证明。 |
| 不适用 | 该平台或阶段不需要验证。 |

## 当前总览

| 平台 | 构建产物 | 构建 | 归档校验 | GUI 启动 smoke | Client 拉起 Agent 注册 | 真实远控/输入/语音 |
| --- | --- | --- | --- | --- | --- | --- |
| Linux | `release/conductor-client-linux-x64.tar.gz` | 已验证 | 已验证 | 已验证 | 已验证 | 待真机回归 |
| Windows | `release/conductor-client-windows-x64.zip` | 自动化覆盖 | 自动化覆盖 | 自动化覆盖 | 自动化覆盖 | 待真机验证 |
| macOS | `release/conductor-client-macos.tar.gz` | 自动化覆盖 | 自动化覆盖 | 自动化覆盖 | 待真机验证 | 待真机验证 |

## Linux 验证记录

验证主机：

- OS：Ubuntu 24.04.2 LTS
- Flutter：`/home/flex/Code/flutter`，Flutter 3.44.4
- 最近验证：2026-06-28，commit `0d48fca`
- 目标：先在 Ubuntu 本机跑通 Flutter 客户端壳、bundle、归档、启动和 Agent 注册流程

已跑通命令：

```sh
/home/flex/Code/flutter/bin/flutter analyze
/home/flex/Code/flutter/bin/flutter test
./scripts/build-client.sh
./scripts/verify-client-archive.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-client-launch.sh linux release/conductor-client-linux-x64.tar.gz
./scripts/smoke-linux-client-e2e.sh release/conductor-client-linux-x64.tar.gz
```

覆盖能力：

- Flutter client 可编译。
- Linux bundle 内包含 `conductor_client`、`conductor-agent`、`data/`、`lib/`。
- GUI 入口可以启动且不会立刻崩溃。
- Client 可通过 `CONDUCTOR_CLIENT_AUTOSTART=1` 自动拉起包内 Agent。
- Agent 可注册到本地 smoke server，后台 API 能看到在线设备。

后续仍需补充：

- 在真实图形桌面中回归远控画面、输入注入、文件管理、聊天和双向语音。
- 记录不同桌面环境下的截图工具依赖，例如 Wayland/X11、`grim`、`gnome-screenshot`、ImageMagick `import`。

## Windows 验收记录模板

Windows 是当前核心目标。真实通过证据必须来自 Windows 10/11 x64 主机或 Windows CI runner。

环境要求：

- Rust stable MSVC toolchain。
- Visual Studio 2022，安装 `Desktop development with C++`。
- Flutter 3.44+，Windows desktop toolchain 通过 `flutter doctor -v`。
- PowerShell 5+ 或 PowerShell 7。

一键验收命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1
```

如果 CI 已先构建客户端包和 debug server，可运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1 -SkipClientBuild -SkipServerBuild
```

需要保留手工验收证据时，加上 `-EvidenceDir`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1 -EvidenceDir .\artifacts\windows-client-smoke
```

该命令必须完成以下步骤：

| 步骤 | 证明内容 |
| --- | --- |
| `Build Windows client package` | `scripts/build-client.ps1` 能构建 `conductor-agent.exe` 和 Flutter Windows 客户端。 |
| `Build web assets` | Server smoke 使用的内嵌 Web 静态资源可构建。 |
| `Build smoke server` | `target\debug\conductor-server.exe` 可构建。 |
| `Verify Windows client archive` | zip 内包含 `conductor_client.exe`、`conductor-agent.exe`、`flutter_windows.dll` 和 `data\flutter_assets`。 |
| `Smoke launch bundled Windows agent` | 包内 Agent 可启动，不会因为缺 DLL 或入口错误立刻崩溃。 |
| `Smoke register bundled Windows agent` | 包内 Agent 能连到本地 smoke server 并注册上线。 |
| `Smoke register through Windows client` | Flutter 客户端能自动拉起包内 Agent，Agent 能注册上线。 |
| `Smoke launch Windows client` | GUI 入口可启动，不会立刻退出。 |

CI 中的 `client-windows` job 会把上述 flow 的 transcript 和环境摘要上传为 `windows-client-smoke-evidence` artifact。判断 Windows 自动化是否真正通过时，需要同时确认：

- `client-windows` job 成功。
- `Verify Windows smoke evidence` 步骤成功。
- `windows-client-smoke-evidence/validation-summary.txt` 记录了 commit、runner、PowerShell、Rust 和 Flutter 版本。
- `windows-client-smoke-evidence/validation-summary.txt` 记录 `archive_sha256=<sha256>` 和 `result=passed`。
- `windows-client-smoke-evidence/smoke-windows-client-flow.log` 末尾出现 `Windows client flow smoke passed`。

记录通过结果时填写：

```text
日期：
机器/runner：
Windows 版本：
Flutter 版本：
Rust toolchain：
Visual Studio / MSVC 版本：
命令：
结果：
产物：
备注：
```

真实能力验收命令和人工检查：

1. 启动 Server，并设置非默认 `CONDUCTOR_AGENT_TOKEN`。
2. 运行 `release\conductor-client-windows-x64.zip` 解包后的 `conductor_client.exe`。
3. 填写 `http://<server-ip>:8080` 或 `<server-ip>:8080`，确认客户端转换为 `ws://<server-ip>:8080/ws/agent`。
4. 填写正确 Token 和容易识别的 Agent Name。
5. 点击 `Start Agent`，后台设备列表应出现该 Windows 终端。
6. 验证文件列表、聊天、远控会话创建、屏幕画面和鼠标键盘输入。
7. 如有失败，保留 Client 日志、Server 日志、Windows Defender/防火墙状态和 `flutter doctor -v` 输出。

## macOS 验收记录模板

macOS 当前纳入构建和基础启动 smoke，真实权限和设备能力后续在 macOS 真机验证。

环境要求：

- macOS 14 或更新版本。
- Xcode 和 command line tools。
- Rust stable。
- Flutter 3.44+，macOS desktop toolchain 通过 `flutter doctor -v`。
- `ffmpeg` 和 `ffplay`。

基础验收命令：

```sh
./scripts/build-client.sh
./scripts/verify-client-archive.sh macos release/conductor-client-macos.tar.gz
./scripts/smoke-client-launch.sh macos release/conductor-client-macos.tar.gz
```

记录通过结果时填写：

```text
日期：
机器/runner：
macOS 版本：
Flutter 版本：
Rust toolchain：
Xcode 版本：
命令：
结果：
产物：
备注：
```

真机权限检查：

| 权限 | 用途 | 期望 |
| --- | --- | --- |
| Screen Recording | 屏幕采集和远控画面 | Agent 可以获得真实屏幕帧。 |
| Accessibility | 鼠标键盘输入注入 | 远控输入能作用到本机桌面。 |
| Microphone | Agent 到浏览器语音回传 | 浏览器可以收到 macOS 麦克风音频。 |

后续需要确认：

- `.app` 可启动内置 `Contents/MacOS/conductor-agent`。
- macOS 设备可注册到 Server。
- 文件列表可打开并受 `CONDUCTOR_AGENT_ROOT` 限制。
- 授权后远控画面、输入和语音符合预期。

## CI 覆盖

工作流入口：

- `.github/workflows/build.yml`
- `.gitea/workflows/build.yml`

两份 workflow 应保持内容一致，可用以下命令检查：

```sh
cmp -s .github/workflows/build.yml .gitea/workflows/build.yml
```

CI job 覆盖：

| Job | Runner | 覆盖 |
| --- | --- | --- |
| `server-release` | `ubuntu-24.04` | Rust test、Web build、Linux server release 包。 |
| `client-linux` | `ubuntu-24.04` | Flutter analyze/test、Linux client build、归档校验、GUI smoke、client e2e 注册。 |
| `client-windows` | `windows-2022` | Windows client build、归档校验、Agent smoke、Agent e2e、Client e2e、GUI smoke。 |
| `client-macos` | `macos-14` | macOS client build、归档校验、`.app` GUI smoke。 |

自建 Gitea/Forgejo Actions 如果没有 Windows 或 macOS runner，只能证明配置存在，不能证明对应平台真正通过。
