# Conductor 演示脚本

## 准备

- Server 与 Agent 使用相同的 `CONDUCTOR_AGENT_TOKEN`。
- Agent 主机已安装带 `libvpx`、`libopus` 的 `ffmpeg` 和 `ffplay`。
- Agent 主机允许屏幕采集、辅助控制、麦克风和扬声器访问。

## Release 包检查

解包前可先校验归档：

```sh
cd release
sha256sum -c conductor-<target>.tar.gz.sha256
cd ..
```

解包 `release/conductor-<target>.tar.gz` 后应至少包含：

- `bin/conductor-server`
- `bin/conductor-agent`
- `README.md`
- `RELEASE.txt`
- `SHA256SUMS`
- `docs/demo.md`
- `docs/plan.md`
- `scripts/smoke-release.sh`
- `source/`

正式演示前建议先在本机做一次 smoke test：

```sh
# 在解包后的 release 目录内执行
./scripts/smoke-release.sh .

# 或在源码仓库内指定 release 目录
./scripts/smoke-release.sh release/conductor-<target>
```

该脚本会先校验包内 `SHA256SUMS`，再临时启动 release 包内的 Server 和 Agent，自动检查健康接口、前端深层路由、登录、设备上线、远控会话、文件列表、聊天和会话关闭。

演示机安装 Chromium 时，可以追加浏览器级后台检查：

```sh
CONDUCTOR_SMOKE_BROWSER=1 ./scripts/smoke-release.sh .
```

该模式会使用 headless Chromium 登录后台，检查设备列表、设备详情、远控页和文件页主流程。

脚本默认使用 `127.0.0.1:18080`。如果端口被占用，可改用：

```sh
CONDUCTOR_SMOKE_PORT=18081 ./scripts/smoke-release.sh .
```

也可以手工执行同等检查。先启动 Server：

```sh
export CONDUCTOR_BIND='127.0.0.1:18080'
export CONDUCTOR_DB='/tmp/conductor-demo.sqlite3'
export CONDUCTOR_ADMIN_PASSWORD='admin123'
export CONDUCTOR_JWT_SECRET='demo-secret'
export CONDUCTOR_AGENT_TOKEN='demo-agent-token'
./bin/conductor-server
```

另开终端启动 Agent：

```sh
export CONDUCTOR_SERVER_URL='ws://127.0.0.1:18080/ws/agent'
export CONDUCTOR_AGENT_TOKEN='demo-agent-token'
export CONDUCTOR_AGENT_NAME='demo-agent'
./bin/conductor-agent
```

检查项：

- `GET /health` 返回 `{"ok":true}`。
- 浏览器打开 `/` 和 `/devices` 都能显示后台页面。
- 登录后设备列表出现 `demo-agent` 且状态为在线。
- 发起远控后会话从 `pending` 进入 `active`。
- 文件管理可以列出 Agent 用户目录。
- 聊天面板发送消息后 Agent CLI 能收到。
- 关闭会话后状态变为 `closed`。

## 启动

Server 主机：

```sh
export CONDUCTOR_ADMIN_PASSWORD='replace-with-a-strong-password'
export CONDUCTOR_JWT_SECRET='replace-with-a-random-secret'
export CONDUCTOR_AGENT_TOKEN='replace-with-a-shared-agent-token'
./bin/conductor-server
```

Agent 主机：

```sh
export CONDUCTOR_SERVER_URL='ws://SERVER_HOST:8080/ws/agent'
export CONDUCTOR_AGENT_TOKEN='replace-with-a-shared-agent-token'
./bin/conductor-agent
```

## 演示顺序

1. 浏览器打开 `http://SERVER_HOST:8080`，使用配置的管理员账号登录。
2. 在设备列表确认 Agent 在线，打开设备详情并发起远控。
3. 等待会话进入 `active`，确认远程屏幕和 WebRTC 状态正常。
4. 在远程画面内移动、点击、滚动并输入文字，确认 Agent 执行输入。
5. 打开聊天面板发送消息，在 Agent CLI 回复消息。
6. 打开文件管理，依次演示目录浏览、上传、下载、新建目录和删除。
7. 发起语音，确认 Agent 接受后进行双向通话，再演示静音和挂断。
8. 结束远控，确认页面显示关闭状态，Agent 停止画面和音频任务。
9. 打开审计页，确认登录、设备、会话和文件操作记录。

## 降级检查

- WebRTC 视频不可用时，页面应继续显示 WebSocket 截图帧。
- DataChannel 未就绪时，鼠标键盘事件应回退到 WebSocket。
- 麦克风或扬声器不可用时，远控画面、文件和聊天功能应继续工作。
- Agent 离线后，设备应在 30 秒内标记离线并关闭活动会话。
