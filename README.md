# Conductor

集中式远程管理系统原型，包含 Rust Server、Rust Agent 和 React 管理后台。

## 项目结构

- `server/`：Axum API、管理员鉴权、SQLite 持久化、WebSocket 实时通道、内嵌前端静态资源。
- `agent/`：被控端命令行 Agent，负责注册、心跳、文件命令、聊天消息、本地 CLI 回复与审批交互、远控画面采集、WebRTC 屏幕视频与双向语音。
- `web/`：React + TypeScript + Tailwind CSS + Vite 管理后台。
- `docs/plan.md`：任务计划与验收标准。

## 当前实现状态

### 已完成

- 管理员登录与 JWT 鉴权
- Agent 注册、心跳、在线/离线状态
- 后台概览页、设备列表、设备详情、审计页
- 远控会话创建、会话互斥、自动清理、状态追踪
- 远控页实时画面帧展示，优先使用真实屏幕采集，失败时回退演示帧
- 鼠标/键盘控制事件从 Web 转发到 Agent 并执行真实输入注入
- 文件浏览、上传、下载、删除、新建目录
- 会话内双向文字沟通
- Agent 本地 CLI 聊天回复：支持 `/sessions`、`/use <session_id>`、`/reply <session_id> <text>`
- Agent 可选交互审批：支持远控请求接受/拒绝、语音请求接受/拒绝
- 双向语音控制面板、审批协议和 WebRTC 音频传输
- 浏览器侧 WebRTC 起始信令：会话进入 `active` 后自动发送 offer/ICE，并在远控页展示信令状态
- Agent 侧 WebRTC 应答信令：接收浏览器 offer、返回 answer，并回传本地 ICE candidate
- 远控控制通道：浏览器优先通过 WebRTC DataChannel 发送鼠标键盘事件，未就绪时回退到 WebSocket
- 浏览器侧媒体接收：声明接收远端视频/音频轨，有真实 MediaStream 时优先渲染，否则回退截图帧
- Agent WebRTC 屏幕视频：把实际 PNG 截图编码为 VP8 视频帧并发送到浏览器，当前为 1 FPS
- 浏览器语音发送：Agent 接受语音请求后，把浏览器麦克风轨挂载到 WebRTC 音频 sender；静音、挂断时及时移除
- Agent 语音播放：接收浏览器 Opus 音频轨，封装为 Ogg Opus 流并通过无界面 `ffplay` 播放
- Agent 语音回传：接受语音请求后通过 `ffmpeg` 采集麦克风并把 Opus 音频轨发送到浏览器
- 审计日志记录与查询

### 当前降级与运行依赖

- Agent 会优先尝试真实屏幕采集：Linux 依次尝试 `grim`、`gnome-screenshot`、`import`，macOS 使用 `screencapture`，Windows 使用 PowerShell 截图；当图形会话、截图工具或权限条件不满足时，回退到动态演示帧
- 真实鼠标键盘输入依赖本机图形会话与系统权限，无法建立输入连接时会保留日志告警
- Agent 音频采集和播放依赖系统音频设备、权限及 `ffmpeg`/`ffplay`，设备不可用时会记录告警
- WebRTC 屏幕视频编码依赖 Agent 所在机器提供带 `libvpx` 编码器的 `ffmpeg`；不可用时仍可通过 WebSocket 截图帧展示
- 浏览器与 Agent 已可交换 WebRTC offer/answer/ICE、屏幕与双向音频轨和 DataChannel 控制事件

这意味着当前版本已经可以完整演示“后台管理、终端在线、会话、文件、聊天、审计、控制链路”，但还不是最终的真实远控产品。

## 运行环境

- Rust stable
- Node.js 20+
- npm 10+
- `ffmpeg`（Agent WebRTC VP8 屏幕视频所需，必须包含 `libvpx` 编码器）和 `ffplay`（Agent 播放远端语音所需）

## 快速运行

### 1. 构建前端

```sh
cd web
npm install
npm run build
```

### 2. 启动 Server

在仓库根目录执行：

```sh
CONDUCTOR_ADMIN_PASSWORD=admin123 cargo run -p conductor-server
```

默认监听：

- Web/API：`http://127.0.0.1:8080`

默认管理员账号：

- 用户名：`admin`
- 密码：`admin123`，或 `CONDUCTOR_ADMIN_PASSWORD` 指定值

### 3. 启动 Agent

在仓库根目录执行：

```sh
CONDUCTOR_SERVER_URL=ws://127.0.0.1:8080/ws/agent cargo run -p conductor-agent
```

Agent 首次启动会生成并持久化 `device_id`，之后重启会复用同一个设备标识。

## 构建提交包

构建当前平台的前端、Server、Agent 和压缩提交包：

```sh
./scripts/build-release.sh
```

指定已安装 Rust 工具链及交叉编译器的目标平台：

```sh
./scripts/build-release.sh x86_64-unknown-linux-gnu
./scripts/build-release.sh x86_64-pc-windows-gnu
./scripts/build-release.sh x86_64-apple-darwin
```

产物位于 `release/conductor-<target>.tar.gz`。包内 `RELEASE.txt` 会记录 target、commit、构建时间和 smoke test 命令。解包后可以先运行 release smoke test：

```sh
tar -xzf release/conductor-<target>.tar.gz -C release/
cd release/conductor-<target>
./scripts/smoke-release.sh .
```

该检查会临时启动 release 包内的 Server 和 Agent，并自动验证健康接口、前端路由、登录、设备上线、远控会话、文件列表、聊天和会话关闭。默认使用 `127.0.0.1:18080`，端口被占用时可指定 `CONDUCTOR_SMOKE_PORT=18081 ./scripts/smoke-release.sh .`。完整比赛演示步骤见 `docs/demo.md`。

Agent 控制台聊天命令：

- `/help`
- `/sessions`
- `/use <session_id>`
- `/reply <session_id> <text>`
- 直接输入文本：发送到当前会话

开启交互审批后还支持：

- `/requests`
- `/session accept <session_id>`
- `/session reject <session_id> [reason]`
- `/voice accept <session_id>`
- `/voice reject <session_id> [reason]`

## 演示流程

1. 启动 Server。
2. 浏览器打开 `http://127.0.0.1:8080` 并登录。
3. 启动 Agent。
4. 在概览页或设备列表看到终端上线。
5. 进入设备详情页。
6. 点击“远程控制”进入会话页。
7. 观察远控页中的实时屏幕、会话状态、语音状态、输入/信令日志。
8. 在远控页聊天面板互发文字。
9. 使用“文件管理”浏览 Agent 用户目录，执行上传、下载、删除、新建目录。
10. 打开“审计”页确认登录、会话、设备上下线等记录已经落库。

## 主要页面

- `/`：控制台概览
- `/devices`：设备列表
- `/devices/:id`：设备详情
- `/sessions/:id`：远控/聊天/语音控制页
- `/devices/:id/files`：文件管理
- `/audit`：审计日志

## 环境变量

### Server

- `CONDUCTOR_BIND`：监听地址，默认 `127.0.0.1:8080`
- `CONDUCTOR_DB`：SQLite 数据库路径，默认 `data/conductor.sqlite3`
- `CONDUCTOR_JWT_SECRET`：JWT 密钥
- `CONDUCTOR_ADMIN_USERNAME`：管理员账号，默认 `admin`
- `CONDUCTOR_ADMIN_PASSWORD`：管理员密码，默认 `admin123`
- `CONDUCTOR_AGENT_TOKEN`：Agent WebSocket 共享接入令牌，生产环境必须修改默认值

### Agent

- `CONDUCTOR_SERVER_URL`：Agent WebSocket 地址，默认 `ws://127.0.0.1:8080/ws/agent`
- `CONDUCTOR_AGENT_TOKEN`：必须与 Server 的共享接入令牌一致，默认 `dev-agent-token-change-me`
- `CONDUCTOR_AGENT_NAME`：覆盖 Agent 上报主机名
- `CONDUCTOR_INTERACTIVE_APPROVAL`：设为 `1`/`true` 后，Agent 本地 CLI 需要显式接受或拒绝远控/语音请求
- `CONDUCTOR_AUDIO_INPUT`：覆盖 Agent 的 `ffmpeg` 音频输入设备；Linux 默认 `default`，macOS 默认 `:0`，Windows 默认 `default`

## 数据持久化

Server 使用 SQLite 保存：

- 管理员账号
- 设备信息
- 会话记录
- 聊天消息
- 审计日志

默认数据库文件位于：

- `data/conductor.sqlite3`

## 关键 API

- `POST /api/auth/login`
- `GET /api/me`
- `GET /api/overview`
- `GET /api/devices`
- `GET /api/devices/:id`
- `GET /api/sessions`
- `POST /api/sessions`
- `GET /api/sessions/:id`
- `POST /api/sessions/:id/close`
- `GET /api/sessions/:id/messages`
- `GET /api/audit-logs`
- `GET /api/devices/:id/files`
- `POST /api/devices/:id/files/upload`
- `GET /api/devices/:id/files/download`
- `DELETE /api/devices/:id/files`
- `POST /api/devices/:id/files/mkdir`

WebSocket：

- `/ws/admin`
- `/ws/agent`

## 当前限制

- 只支持单管理员模型
- Agent 当前默认把文件访问根目录限制在用户 Home
- 单个上传文件限制为 32 MiB，文件内容由 Server 中转
- WebRTC 屏幕视频当前为 1 FPS，且依赖系统截图工具和带 `libvpx` 的 `ffmpeg`
- 真实输入和双向语音依赖图形/音频会话、设备和系统权限
- 未提供 Windows/macOS/Linux 安装包与系统服务包装

## 与计划的对应关系

- P0：登录、Agent 在线、设备列表/详情、远控会话、WebRTC 屏幕画面、基础控制链路、README 已覆盖
- P1：文件管理、双向文字沟通、会话状态清理、审计日志 已覆盖
- P2：真实语音已覆盖；TURN、多管理员、安装包 尚未完成
