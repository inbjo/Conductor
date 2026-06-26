# Conductor

集中式远程管理系统原型，包含 Rust Server、Rust Agent 和 React 管理后台。

## 模块

- `server/`：Axum API、WebSocket 信令、SQLite 管理数据、内嵌 Web 静态资源。
- `agent/`：被控端命令行 Agent，注册设备、心跳、处理文件/聊天/会话命令。
- `web/`：React + TypeScript + Tailwind CSS + Vite 管理控制台。

## 快速运行

```sh
cd web
npm install
npm run build

cd ../server
CONDUCTOR_ADMIN_PASSWORD=admin123 cargo run
```

浏览器打开 `http://127.0.0.1:8080`，默认账号为 `admin`，密码来自 `CONDUCTOR_ADMIN_PASSWORD`，未设置时为 `admin123`。

启动 Agent：

```sh
cd agent
CONDUCTOR_SERVER_URL=ws://127.0.0.1:8080/ws/agent cargo run
```

## 演示流程

1. 启动 Server 并登录后台。
2. 启动 Agent，设备列表会出现在线终端。
3. 进入设备详情，发起远控会话。
4. 在远控页查看信令状态、发送聊天消息。
5. 打开文件管理，浏览 Agent 用户目录，执行新建目录、上传、下载、删除。

## 环境变量

Server:

- `CONDUCTOR_BIND`：监听地址，默认 `127.0.0.1:8080`。
- `CONDUCTOR_DB`：SQLite 文件，默认 `data/conductor.sqlite3`。
- `CONDUCTOR_JWT_SECRET`：JWT 密钥，默认开发密钥。
- `CONDUCTOR_ADMIN_USERNAME`：管理员账号，默认 `admin`。
- `CONDUCTOR_ADMIN_PASSWORD`：管理员初始密码，默认 `admin123`。

Agent:

- `CONDUCTOR_SERVER_URL`：Agent WebSocket 地址，默认 `ws://127.0.0.1:8080/ws/agent`。
- `CONDUCTOR_AGENT_NAME`：覆盖主机名显示。
