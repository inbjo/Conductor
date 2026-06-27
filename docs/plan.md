# 集中式远程管理系统开发计划

## 1. 项目目标

本项目面向 AI-PK 大赛的“远程控制演示工具”题目，目标是在有限时间内做出一个可运行、可展示、可打包提交的集中式远程管理系统。

系统形态调整为：

- Rust 提供 Web 后台管理系统、API 服务、WebSocket 信令服务和被控端接入服务。
- React + Tailwind CSS + Vite 8 实现管理员 Web 控制台，并在构建时内嵌到 Rust 服务端二进制中。
- Windows、macOS、Linux 上安装被控端 Agent。
- 管理员通过浏览器登录后台，查看在线终端，并发起远程控制、文件操作、双向文字沟通和语音沟通。

首版重点不是做完整商业化产品，而是完成一个能够说清楚架构、能真实演示核心链路、交互完整的远程管理系统原型。

## 2. 总体架构

### 2.1 系统组成

```text
Conductor/
├── server/                 # Rust 后台服务
│   ├── src/
│   │   ├── main.rs
│   │   ├── config.rs
│   │   ├── auth.rs
│   │   ├── device.rs
│   │   ├── session.rs
│   │   ├── signaling.rs
│   │   ├── file_ops.rs
│   │   ├── chat.rs
│   │   └── web_embed.rs
│   └── Cargo.toml
├── agent/                  # Rust 被控端 Agent
│   ├── src/
│   │   ├── main.rs
│   │   ├── config.rs
│   │   ├── heartbeat.rs
│   │   ├── screen.rs
│   │   ├── input.rs
│   │   ├── file_ops.rs
│   │   ├── chat.rs
│   │   └── transport.rs
│   └── Cargo.toml
├── web/                    # React + Tailwind CSS + Vite 8 管理后台
│   ├── src/
│   │   ├── main.tsx
│   │   ├── app/
│   │   ├── pages/
│   │   ├── components/
│   │   ├── features/
│   │   └── lib/
│   ├── package.json
│   └── vite.config.ts
└── docs/
    ├── job.md
    ├── promts.md
    └── plan.md
```

### 2.2 运行拓扑

```text
管理员浏览器
  ├── HTTP/HTTPS 访问后台页面
  ├── REST API 查询设备、会话、文件列表
  ├── WebSocket 接收实时状态、聊天、控制信令
  └── WebRTC 接收远程画面、发送控制事件和语音

Rust Server
  ├── 内嵌 React 静态资源
  ├── 管理员登录与鉴权
  ├── 设备注册、在线状态、心跳
  ├── 远控会话创建与信令转发
  ├── 文件操作命令转发
  └── 文字消息转发与审计日志

Rust Agent
  ├── 启动后连接 Server 并注册设备
  ├── 上报主机名、系统类型、用户名、IP、版本
  ├── 接收远控请求并发起屏幕采集
  ├── 执行鼠标键盘输入
  ├── 执行授权范围内的文件操作
  └── 处理文字与语音沟通
```

## 3. 技术选型

### 3.1 Rust Server

推荐依赖：

- `axum`：HTTP API、WebSocket、静态资源服务。
- `tokio`：异步运行时。
- `tower-http`：CORS、Trace、Compression、静态文件能力。
- `serde` / `serde_json`：协议序列化。
- `sqlx` + `sqlite`：本地轻量数据库，用于后台管理数据持久化，减少部署复杂度。
- `rust-embed` 或 `include_dir`：把 `web/dist` 内嵌进二进制。
- `jsonwebtoken`：管理员登录后的 JWT。
- `argon2`：管理员密码哈希。
- `uuid`：设备 ID、会话 ID、消息 ID。
- `dashmap`：在线连接表。
- `tracing` / `tracing-subscriber`：日志。
- `anyhow` / `thiserror`：错误处理。

### 3.2 Rust Agent

推荐依赖：

- `tokio`：异步任务和网络。
- `tokio-tungstenite`：与 Server 建立 WebSocket 长连接。
- `serde` / `serde_json`：消息协议。
- `scrap`：跨平台屏幕采集，可参考 RustDesk `libs/scrap`。
- `enigo`：跨平台鼠标键盘控制，可参考 RustDesk `libs/enigo`。
- `cpal`：语音采集和播放。
- `opus` 或 WebRTC 音频能力：语音编码。
- `directories`：配置文件和数据目录。
- `sysinfo`：采集系统信息。
- `uuid`：生成并持久化设备 ID。

### 3.3 Web 管理后台

推荐依赖：

- `react`：后台 UI。
- `vite 8`：前端构建工具。
- `tailwindcss`：样式体系。
- `typescript`：前端类型约束。
- `react-router`：页面路由。
- `@tanstack/react-query`：API 请求和缓存。
- `zustand`：轻量全局状态。
- `lucide-react`：图标。
- `xterm` 可作为后续终端能力预留，不作为首版必需项。

### 3.4 WebRTC 与传输策略

远程控制、语音沟通建议使用 WebRTC：

- 视频：Agent 采集屏幕后推送给浏览器。
- 控制：浏览器通过 DataChannel 发送鼠标键盘事件。
- 语音：浏览器和 Agent 建立音频双向通道。
- 文件：首版可以走 Server 中转，保证演示稳定；进阶版再改为 WebRTC DataChannel 直传。

比赛时间紧，文件操作建议优先使用 Server 转发命令和文件流，不强制首版完全 P2P。这样浏览器、Server、Agent 三端链路更容易调试，也更符合“集中式远程管理系统”的管理视角。

## 4. 核心功能设计

### 4.1 管理员登录

功能目标：

- 管理员通过浏览器登录后台。
- 未登录不能访问设备列表和远控页面。

实现细节：

- 首版使用单管理员账号。
- 初始账号密码从环境变量或配置文件读取。
- 密码使用 Argon2 哈希后存储到 SQLite。
- 登录成功后返回 JWT。
- 前端把 JWT 保存在内存或 localStorage，并在 API 请求中携带 `Authorization: Bearer <token>`。

验收标准：

- 正确账号密码可以登录。
- 错误密码不能登录。
- 未登录访问 API 返回 401。
- 刷新页面后仍可保持登录状态。

边界用例测试：

- 空用户名、空密码。
- JWT 过期。
- 篡改 JWT。
- 连续登录失败时日志可追踪。

### 4.2 被控端 Agent 注册与心跳

功能目标：

- 被控端安装后自动注册到 Server。
- 管理员可以在 Web 后台看到在线和离线设备。

实现细节：

- Agent 首次启动生成 `device_id` 并持久化到本机配置目录。
- Agent 通过 WebSocket 连接 Server，发送 `agent_register` 消息。
- 注册信息包括：
  - `device_id`
  - `hostname`
  - `os`
  - `arch`
  - `username`
  - `agent_version`
  - `local_ip`
- Server 更新设备表和在线连接表。
- Agent 每 10 秒发送心跳。
- Server 超过 30 秒未收到心跳则标记离线。

验收标准：

- Agent 启动后 Web 后台能看到设备上线。
- Agent 关闭后设备在 30 秒内变为离线。
- 同一设备重启后仍使用原 `device_id`。
- Server 重启后 Agent 能自动重连。

边界用例测试：

- Server 不可达时 Agent 自动重试。
- 网络闪断后 Agent 恢复在线。
- 两个 Agent 使用相同 `device_id` 时后连接踢掉旧连接。
- Agent 配置文件损坏时重新生成并记录日志。

### 4.3 设备列表与设备详情

功能目标：

- 管理员在 Web 后台查看所有被控终端。
- 支持进入设备详情页发起远控、文件操作和沟通。

实现细节：

- 设备列表展示：
  - 在线状态
  - 主机名
  - 操作系统
  - 用户名
  - IP
  - Agent 版本
  - 最近心跳时间
- 设备详情展示：
  - 基础信息
  - 当前会话状态
  - 远控入口
  - 文件管理入口
  - 文字沟通入口
  - 语音沟通入口
- 使用 WebSocket 推送设备在线状态变化。

验收标准：

- 新设备上线后列表自动更新。
- 离线设备不能发起远控。
- 设备详情信息与 Agent 上报一致。
- 页面刷新后数据仍能正确加载。

边界用例测试：

- 没有任何设备时展示空状态。
- 设备数量较多时列表仍能搜索和滚动。
- 设备离线瞬间点击远控，应提示设备不可用。
- 设备字段为空时 UI 不错位。

### 4.4 远程控制会话

功能目标：

- 管理员在 Web 端发起远程控制。
- Agent 端采集屏幕，Web 端显示远程画面。
- 管理员可以发送鼠标键盘操作。

实现细节：

- Web 端点击“远程控制”后调用 `POST /api/sessions`。
- Server 创建 `session_id`，向目标 Agent 发送 `remote_control_request`。
- Agent 接受请求后进入远控状态。
- Web 与 Agent 通过 Server 交换 WebRTC offer、answer、ICE candidate。
- WebRTC 建立后：
  - Agent 推送屏幕视频流。
  - Web 通过 DataChannel 发送控制事件。
- 鼠标坐标采用归一化比例，Agent 根据当前屏幕尺寸还原。
- 键盘事件使用统一 key code 协议，Agent 映射到本机输入。

验收标准：

- Web 端可以看到 Agent 屏幕。
- Web 端点击远程画面，Agent 鼠标移动并点击。
- Web 端键盘输入，Agent 能收到字母、数字、回车、退格。
- 结束会话后 Agent 停止采集屏幕。

边界用例测试：

- Agent 离线时不能创建会话。
- WebRTC 建立失败时显示错误并允许重试。
- Agent 屏幕分辨率变化后坐标仍正确。
- 浏览器关闭页面后 Server 和 Agent 清理会话。
- 多个管理员同时控制同一设备时，首版只允许一个会话。

### 4.5 文件操作

功能目标：

- 管理员在 Web 后台浏览被控端文件。
- 支持上传、下载、删除、新建目录等基础文件操作。

实现细节：

- Web 端文件页通过 Server 向 Agent 发送文件命令。
- Agent 执行命令后返回结果。
- 首版支持：
  - 列目录
  - 下载文件
  - 上传文件
  - 删除文件
  - 新建目录
- Server 对文件流做中转，便于浏览器使用 HTTP 上传下载。
- Agent 限制默认根目录：
  - Windows：用户目录或桌面目录。
  - macOS/Linux：用户 Home 目录。
- 禁止路径穿越和访问敏感系统目录。

验收标准：

- Web 端能列出 Agent 指定目录文件。
- 能从 Agent 下载一个文件到浏览器。
- 能从浏览器上传一个文件到 Agent。
- 删除文件和新建目录操作有确认提示。

边界用例测试：

- 路径包含 `../` 时拒绝。
- 文件不存在时返回明确错误。
- 上传同名文件时提示覆盖或自动改名。
- 大文件传输中断时不显示成功。
- Agent 权限不足时 Web 显示权限错误。

### 4.6 双向文字沟通

功能目标：

- 管理员和被控端用户可以进行文字沟通。
- 便于远控前说明操作目的，远控中确认用户意图。

实现细节：

- Web 后台远控页面内置聊天面板。
- Agent 端需要提供一个轻量聊天窗口或系统托盘弹窗。
- 消息通过 Server WebSocket 转发。
- Server 可将消息记录到 SQLite，便于演示审计。
- 消息结构包含：
  - `message_id`
  - `session_id`
  - `from`
  - `to`
  - `text`
  - `created_at`

验收标准：

- Web 端发送文字，Agent 用户可看到。
- Agent 用户回复文字，Web 端可看到。
- 会话内消息按时间顺序展示。
- 断线重连后可以拉取最近消息。

边界用例测试：

- 空消息不能发送。
- 超长消息截断或拒绝。
- 网络断开时显示发送失败。
- 会话结束后不能继续发送消息。

### 4.7 双向语音沟通

功能目标：

- 管理员和被控端用户可以进行实时语音沟通。
- 作为远控协助场景的增强演示能力。

实现细节：

- Web 端使用浏览器 `getUserMedia` 获取麦克风。
- Agent 端使用 `cpal` 获取麦克风和播放音频。
- 优先通过 WebRTC 音频轨实现双向语音。
- Web 页面提供：
  - 开启语音
  - 静音
  - 挂断
  - 麦克风状态
- Agent 端提供接听/拒绝提示。
- 如果语音实现时间不足，保留 UI 与协议设计，首版优先完成文字沟通。

验收标准：

- Web 端开启语音后 Agent 能听到。
- Agent 端说话 Web 端能听到。
- 任意一端静音后对端不再收到声音。
- 挂断语音不影响远控会话。

边界用例测试：

- 浏览器拒绝麦克风权限。
- Agent 无可用音频设备。
- 网络抖动导致音频断续。
- 语音连接失败时远控画面仍保持。

## 5. API 与协议设计

### 5.1 REST API

```text
POST   /api/auth/login
GET    /api/me
GET    /api/devices
GET    /api/devices/:id
POST   /api/sessions
GET    /api/sessions/:id
POST   /api/sessions/:id/close
GET    /api/devices/:id/files?path=...
POST   /api/devices/:id/files/upload
GET    /api/devices/:id/files/download?path=...
DELETE /api/devices/:id/files?path=...
POST   /api/devices/:id/files/mkdir
GET    /api/sessions/:id/messages
```

### 5.2 WebSocket 通道

```text
/ws/admin    # Web 管理端实时通道
/ws/agent    # Agent 长连接通道
```

核心消息类型：

```text
agent_register
agent_heartbeat
agent_status_changed
session_create
session_accept
session_reject
session_close
webrtc_offer
webrtc_answer
webrtc_ice_candidate
control_event
file_command
file_result
chat_message
voice_request
voice_accept
voice_reject
error
```

### 5.3 数据库存储

服务端建议使用数据库，并且首版优先使用 SQLite。原因是本系统不是单纯的一次性远控 demo，而是集中式远程管理后台，需要保存管理员账号、设备资产、会话记录、聊天记录和审计日志。SQLite 不需要额外部署数据库服务，适合比赛演示、单机部署和后续打包。

数据库只负责“管理面持久化”，不参与实时媒体转发：

- 应该入库：管理员账号、设备信息、最近在线状态、会话元数据、聊天消息、操作审计。
- 不应该入库：屏幕视频帧、鼠标键盘实时事件、WebRTC SDP/ICE 长期记录、文件内容。
- 在线连接表、WebSocket sender、当前远控会话通道保存在内存中，Server 重启后由 Agent 自动重连恢复在线状态。

SQLite 表建议：

- `admins`：管理员账号。
- `devices`：设备信息和最近在线状态。
- `sessions`：远控会话。
- `chat_messages`：文字沟通记录。
- `audit_logs`：关键操作审计。

首版使用 `sqlx` migrations 初始化数据库，默认数据库文件可放在 `./data/conductor.sqlite3`，也允许通过环境变量配置路径。首版不做复杂多租户和权限模型，只保留单管理员和基础审计。

## 6. 前端页面规划

### 6.1 登录页

目标：

- 输入管理员账号密码。
- 登录成功进入设备列表。

验收：

- 登录失败有明确提示。
- 登录成功保存 token。

### 6.2 设备列表页

目标：

- 展示所有 Agent。
- 支持搜索、在线过滤、刷新。

验收：

- 在线状态实时变化。
- 点击设备进入详情。

### 6.3 设备详情页

目标：

- 查看设备基础信息。
- 提供远控、文件、聊天、语音入口。

验收：

- 离线设备操作按钮置灰。
- 在线设备可发起会话。

### 6.4 远程控制页

目标：

- 中间区域展示远程画面。
- 顶部展示连接状态和控制按钮。
- 侧边栏提供文字聊天、语音控制、文件快捷入口。

验收：

- 画面区域尺寸自适应。
- 鼠标键盘事件只在画面区域内捕获。
- 断开会话后返回设备详情。

### 6.5 文件管理页

目标：

- 类似文件管理器展示远端目录。
- 支持上传、下载、删除、新建目录。

验收：

- 路径导航清晰。
- 操作有进度和错误提示。

## 7. 构建与内嵌方案

### 7.1 前端构建

```sh
cd web
npm install
npm run build
```

构建产物输出到：

```text
web/dist/
```

### 7.2 Rust 内嵌静态资源

Server 使用 `rust-embed` 或 `include_dir` 将 `web/dist` 编译进二进制：

- 访问 `/` 返回 `index.html`。
- 访问 `/assets/*` 返回静态资源。
- React Router 页面刷新时统一 fallback 到 `index.html`。
- API 和 WebSocket 路径不走静态资源 fallback。

验收标准：

- 只运行一个 Rust server 二进制即可打开 Web 后台。
- 不需要单独部署 nginx。
- 前端刷新深层路由不 404。

边界用例测试：

- `web/dist` 不存在时构建失败并提示先构建前端。
- 静态资源 MIME 类型正确。
- `/api/*` 不被 fallback 到前端页面。

## 8. 开发任务拆分

### 任务 1：初始化工程

目标：

- 建立 `server/`、`agent/`、`web/` 三个子工程。

实现细节：

- `server` 使用 Rust + axum。
- `agent` 使用 Rust CLI 程序。
- `web` 使用 React + TypeScript + Tailwind CSS + Vite 8。
- 根目录补充 README，说明三个模块职责。

验收标准：

- Server 可以启动 `/health`。
- Agent 可以打印配置并尝试连接 Server。
- Web 可以启动开发服务器。

边界测试：

- 端口被占用。
- 配置缺失。
- 前端依赖未安装。

### 任务 2：Server 基础能力

目标：

- 实现登录、设备管理、WebSocket 接入、SQLite 存储。

实现细节：

- 建立配置加载。
- 建立数据库初始化。
- 实现 JWT 鉴权中间件。
- 实现 `/ws/admin` 和 `/ws/agent`。
- 维护在线 Agent 连接表。

验收标准：

- 管理员能登录。
- Agent 能注册上线。
- Web 能看到设备在线状态。

边界测试：

- 非法 token。
- Agent 重复连接。
- Server 重启后数据库保留设备记录。

### 任务 3：Agent 基础能力

目标：

- Agent 能跨平台运行并保持在线。

实现细节：

- 生成并保存 `device_id`。
- 读取 Server 地址和 token。
- 建立 WebSocket 长连接。
- 定时心跳。
- 上报系统信息。
- 断线自动重连。

验收标准：

- Windows、macOS、Linux 至少完成代码级兼容设计。
- 当前开发环境中 Agent 可连接 Server。
- 断开 Server 后 Agent 自动重试。

边界测试：

- 配置文件不存在。
- Server 地址错误。
- 网络中断。
- 权限不足。

### 任务 4：Web 管理后台

目标：

- 完成登录、设备列表、设备详情基础页面。

实现细节：

- 使用 React Router 管理路由。
- 使用 React Query 调用 API。
- 使用 Zustand 管理 WebSocket 状态。
- 使用 Tailwind CSS 完成后台布局。
- 设备列表支持搜索和在线过滤。

验收标准：

- 登录后进入设备列表。
- 设备上线/离线实时刷新。
- 可以进入设备详情页。

边界测试：

- API 401 自动回登录。
- WebSocket 断开提示重连。
- 设备为空展示空状态。

### 任务 5：远控会话

目标：

- 打通 Web 管理端到 Agent 的远程控制链路。

实现细节：

- Server 创建会话并转发 WebRTC 信令。
- Agent 采集屏幕并发送视频流。
- Web 端渲染远程画面。
- Web 端发送鼠标键盘控制事件。
- Agent 执行输入事件。

验收标准：

- Web 能看到 Agent 屏幕。
- 鼠标点击、移动、滚轮可用。
- 键盘输入常用按键可用。
- 会话关闭后释放资源。

边界测试：

- Agent 拒绝会话。
- WebRTC 失败重试。
- 浏览器关闭。
- 多管理员抢占同一设备。

### 任务 6：文件操作

目标：

- 实现远端文件浏览、上传、下载、删除、新建目录。

实现细节：

- Web 端文件管理器页面。
- Server 提供 HTTP 文件接口。
- Agent 执行本地文件操作。
- 文件流由 Server 中转。
- 路径做安全校验。

验收标准：

- 能浏览用户目录。
- 能上传下载文件。
- 能删除文件和新建目录。
- 错误信息清晰。

边界测试：

- 大文件中断。
- 路径穿越。
- 权限不足。
- 文件名包含中文和空格。

### 任务 7：文字沟通

目标：

- 实现管理员和被控端用户的双向文字消息。

实现细节：

- Web 端聊天面板。
- Agent 端弹窗或简易窗口。
- Server 转发并保存消息。

验收标准：

- 双方可以互发文字。
- 断线重连后能看到历史消息。
- 会话结束后聊天关闭。

边界测试：

- 空消息。
- 超长消息。
- 网络中断。

### 任务 8：语音沟通

目标：

- 实现或预留 Web 与 Agent 双向语音能力。

实现细节：

- Web 使用浏览器麦克风。
- Agent 使用 `cpal` 采集和播放。
- 优先通过 WebRTC 音频轨传输。
- UI 提供接听、静音、挂断。

验收标准：

- 双方能听到对方声音。
- 静音和挂断可用。
- 语音失败不影响远控。

边界测试：

- 麦克风权限拒绝。
- 无音频设备。
- 网络抖动。

### 任务 9：打包与提交

目标：

- 产出比赛提交物。

实现细节：

- 构建 `web/dist`。
- 构建 Linux 部署用的内嵌 Web Server 二进制。
- 构建当前 Linux 演示 Agent；Windows/macOS Agent 保留代码级兼容设计和后续验证入口。
- 编写运行说明和演示脚本。
- 打包源码、Linux 程序、文档、release manifest、校验和和 smoke test 脚本。

验收标准：

- 在 Linux 上运行 Server 二进制即可打开 Web 后台。
- Linux Agent 启动后能出现在设备列表。
- 可以完成远控、文件、文字沟通演示。
- 提交包包含源码、文档、`RELEASE.txt`、`SHA256SUMS` 和归档校验文件。

边界测试：

- Linux 新机器按文档可运行 smoke test。
- Server 地址变化后 Agent 可重新配置。
- 缺少前端构建产物时有明确说明。

## 9. 优先级与时间安排

### P0：必须完成

- Rust Server 启动和内嵌 Web 后台。
- 管理员登录。
- Agent 注册、心跳、在线状态。
- 设备列表和详情页。
- Web 发起远控会话。
- 屏幕画面展示。
- 鼠标键盘基础控制。
- README 和演示文档。

### P1：强烈建议完成

- 文件列表、上传、下载。
- 双向文字沟通。
- 会话状态清理。
- 操作审计日志。

### P2：有时间再完成

- 删除文件、新建目录。
- 双向语音沟通。
- TURN/NAT 穿透增强。
- 多管理员账号。
- Agent 安装包和系统服务。

若比赛时间不足，优先保证 P0 形成完整闭环，再补 P1。语音沟通技术深度高，但调试成本也高，可以作为架构设计和预留接口展示，不应影响远控主链路交付。

## 10. RustDesk 参考点

本项目可以参考本地 RustDesk 仓库 `/home/flex/Code/Rust/remote` 的设计思想：

- 屏幕采集参考 `libs/scrap`。
- 鼠标键盘控制参考 `libs/enigo`。
- 远控会话、输入、视频服务参考 `src/server` 下的模块划分。
- 文件传输和跨平台处理参考 `libs/hbb_common` 中的工具能力。
- 只借鉴成熟思路和可复用依赖，不直接复制大型项目复杂架构。

## 11. 最终演示流程

1. 启动 Rust Server。
2. 浏览器打开 Web 后台并登录。
3. 在 Linux 演示设备启动 Agent。
4. Web 后台设备列表看到 Agent 在线。
5. 点击设备进入详情。
6. 发起远程控制。
7. Web 页面显示 Agent 屏幕。
8. 管理员远程点击、输入，证明控制可用。
9. 打开文件管理，下载或上传一个文件。
10. 打开聊天面板，管理员和被控端互发文字。
11. 如时间允许，开启语音沟通演示。

## 12. 关键风险与降级方案

- WebRTC 调试风险高：如果浏览器到 Agent 的 WebRTC 视频链路遇到阻塞，优先在局域网演示，跨公网作为加分项。
- 语音沟通耗时高：优先完成文字沟通，语音作为 P2。
- 跨平台 Agent 难度高：当前提交物优先保证 Linux 完整可演示，代码结构预留 Windows/macOS/Linux 适配。
- 文件系统权限差异大：首版限定用户 Home 目录，避免访问系统敏感路径。
- 内嵌前端构建链路容易遗漏：Server 构建前明确要求先执行 `web` 构建，并在 README 写清楚。

## 13. 成功标准

项目完成后应满足：

- 一个 Linux Rust Server 二进制即可提供后台页面和 API。
- 一个 Linux Agent 程序即可接入后台并显示在线。
- 管理员通过浏览器完成远程控制演示。
- 管理员可以进行基本文件操作。
- 管理员和被控端用户可以进行文字沟通。
- 文档清晰说明架构、Linux 运行方式、演示流程、校验方式和后续扩展方向。
