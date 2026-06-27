# Conductor 演示脚本

## 准备

- Server 与 Agent 使用相同的 `CONDUCTOR_AGENT_TOKEN`。
- Agent 主机已安装带 `libvpx`、`libopus` 的 `ffmpeg` 和 `ffplay`。
- Agent 主机允许屏幕采集、辅助控制、麦克风和扬声器访问。

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
