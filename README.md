# Conductor

集中式远程管理系统原型，包含 Rust Server、Rust Agent 和 React 管理后台。

## 项目结构

- `server/`：Axum API、管理员鉴权、SQLite 持久化、WebSocket 实时通道、内嵌前端静态资源。
- `agent/`：被控端命令行 Agent，负责注册、心跳、文件命令、聊天消息、远控占位帧与语音占位消息。
- `web/`：React + TypeScript + Tailwind CSS + Vite 管理后台。
- `docs/plan.md`：任务计划与验收标准。

## 当前实现状态

### 已完成

- 管理员登录与 JWT 鉴权
- Agent 注册、心跳、在线/离线状态
- 后台概览页、设备列表、设备详情、审计页
- 远控会话创建、会话互斥、自动清理、状态追踪
- 远控页实时占位画面帧展示
- 鼠标/键盘控制事件从 Web 转发到 Agent 并执行真实输入注入
- 文件浏览、上传、下载、删除、新建目录
- 会话内双向文字沟通
- 语音沟通控制面板与占位协议
- 审计日志记录与查询

### 当前仍是占位/演示实现

- 屏幕画面不是系统真实桌面采集，而是 Agent 生成的动态演示帧
- 真实鼠标键盘输入依赖本机图形会话与系统权限，无法建立输入连接时会保留日志告警
- 语音沟通只完成 UI、权限检测、协议和状态流转，未接入真实音频采集/播放
- WebRTC 信令路径已预留，但未建立真实浏览器到 Agent 的媒体通道

这意味着当前版本已经可以完整演示“后台管理、终端在线、会话、文件、聊天、审计、控制链路”，但还不是最终的真实远控产品。

## 运行环境

- Rust stable
- Node.js 20+
- npm 10+

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

## 演示流程

1. 启动 Server。
2. 浏览器打开 `http://127.0.0.1:8080` 并登录。
3. 启动 Agent。
4. 在概览页或设备列表看到终端上线。
5. 进入设备详情页。
6. 点击“远程控制”进入会话页。
7. 观察远控页中的实时占位帧、会话状态、语音状态、输入/信令日志。
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

### Agent

- `CONDUCTOR_SERVER_URL`：Agent WebSocket 地址，默认 `ws://127.0.0.1:8080/ws/agent`
- `CONDUCTOR_AGENT_NAME`：覆盖 Agent 上报主机名

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
- 真实屏幕采集、真实输入注入、真实音频、真实 WebRTC 媒体链路尚未接入
- 未提供 Windows/macOS/Linux 安装包与系统服务包装

## 与计划的对应关系

- P0：登录、Agent 在线、设备列表/详情、远控会话、占位画面、基础控制链路、README 已覆盖
- P1：文件管理、双向文字沟通、会话状态清理、审计日志 已覆盖
- P2：真实语音、真实媒体、TURN、多管理员、安装包 尚未完成
