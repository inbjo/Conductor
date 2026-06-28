# 公网部署与 GitHub Actions 编译流程

本文档按当前公网测试域名 `https://conductor.moyu.ge` 编写。Flutter 被控客户端的内置默认 Server URL 已指向该域名；客户端保存 Settings 或启动 Agent 时会自动转换为 `wss://conductor.moyu.ge/ws/agent`。

## 1. 上传到 GitHub

可以把当前仓库上传到 GitHub。仓库已经包含 `.github/workflows/build.yml`，GitHub Actions 会直接识别。

首次上传示例：

```sh
git remote add github git@github.com:<owner>/<repo>.git
git push github master
```

如果 GitHub 仓库默认分支使用 `main`：

```sh
git push github master:main
```

在 GitHub 仓库页面进入 `Actions`，允许 workflow 运行。之后 push 到 `master` 或 `main`、创建 pull request、或手动 `workflow_dispatch` 都会触发构建。

## 2. GitHub Actions 编译流程

工作流文件：

```text
.github/workflows/build.yml
```

主要 job：

| Job | Runner | 作用 |
| --- | --- | --- |
| `static-checks` | `ubuntu-24.04` | Shell 脚本、workflow 镜像、合成 evidence、归档校验和 macOS metadata 检查 |
| `powershell-static-checks` | `windows-2022` | PowerShell 脚本解析和 Windows 合成校验 |
| `server-release` | `ubuntu-24.04` | 构建服务端 Linux release 包 |
| `client-linux` | `ubuntu-24.04` | 构建 Linux 被控客户端并运行 smoke |
| `client-windows` | `windows-2022` | 构建 Windows 被控客户端并运行 smoke |
| `client-macos` | `macos-14` | 构建 macOS 被控客户端并运行 smoke |
| `client-smoke-evidence` | `ubuntu-24.04` | 下载三端 smoke evidence 并统一校验 |

成功后在 workflow run 的 `Artifacts` 下载：

- `conductor-server-linux-x64`
- `conductor-client-linux-x64`
- `conductor-client-windows-x64`
- `conductor-client-macos`
- `client-smoke-evidence-verified`

手动运行 `Build` workflow 时，可填写这些输入作为三端客户端构建默认配置：

| 输入 | 建议值 |
| --- | --- |
| `client_server_url` | `https://conductor.moyu.ge` |
| `client_agent_token` | 与服务端 `CONDUCTOR_AGENT_TOKEN` 相同的强随机值 |
| `client_agent_name` | 可留空，运行时在 Settings 页填写 |
| `client_agent_root` | 可留空，运行时在 Settings 页填写 |
| `client_audio_input` | 可留空，运行时在 Settings 页填写 |
| `client_interactive_approval` | `false` 或 `true` |

不填写 `client_server_url` 时，当前源码内置默认值也是 `https://conductor.moyu.ge`。

## 3. 服务端部署准备

服务器建议：

- Ubuntu 22.04/24.04 x86_64
- 80/443 对公网开放
- 域名 `conductor.moyu.ge` 的 A/AAAA 记录指向服务器
- 安装 Nginx 或 Caddy 做 TLS 和 WebSocket 反向代理

创建目录和用户：

```sh
sudo useradd --system --create-home --home-dir /opt/conductor --shell /usr/sbin/nologin conductor
sudo mkdir -p /opt/conductor/bin /opt/conductor/data
sudo chown -R conductor:conductor /opt/conductor
```

从 GitHub Actions 下载 `conductor-server-linux-x64` artifact，得到：

```text
conductor-x86_64-unknown-linux-gnu.tar.gz
conductor-x86_64-unknown-linux-gnu.tar.gz.sha256
```

解包并安装：

```sh
sha256sum -c conductor-x86_64-unknown-linux-gnu.tar.gz.sha256
tar -xzf conductor-x86_64-unknown-linux-gnu.tar.gz
sudo install -m 0755 conductor-x86_64-unknown-linux-gnu/bin/conductor-server /opt/conductor/bin/conductor-server
sudo chown conductor:conductor /opt/conductor/bin/conductor-server
```

## 4. 服务端环境变量

生成生产密钥和 Agent Token：

```sh
openssl rand -hex 32
openssl rand -hex 32
```

创建环境文件：

```sh
sudo tee /etc/conductor.env >/dev/null <<'EOF'
CONDUCTOR_BIND=127.0.0.1:8080
CONDUCTOR_DB=/opt/conductor/data/conductor.sqlite3
CONDUCTOR_JWT_SECRET=replace-with-random-jwt-secret
CONDUCTOR_ADMIN_USERNAME=admin
CONDUCTOR_ADMIN_PASSWORD=replace-with-strong-admin-password
CONDUCTOR_AGENT_TOKEN=replace-with-random-agent-token
EOF
sudo chmod 600 /etc/conductor.env
sudo chown root:root /etc/conductor.env
```

`CONDUCTOR_AGENT_TOKEN` 必须和客户端 Settings 页中的 `Agent Token` 一致。公网测试不要使用默认 token。

## 5. systemd 服务

```sh
sudo tee /etc/systemd/system/conductor.service >/dev/null <<'EOF'
[Unit]
Description=Conductor server
After=network-online.target
Wants=network-online.target

[Service]
User=conductor
Group=conductor
EnvironmentFile=/etc/conductor.env
WorkingDirectory=/opt/conductor
ExecStart=/opt/conductor/bin/conductor-server
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/conductor/data

[Install]
WantedBy=multi-user.target
EOF
```

启动：

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now conductor
sudo systemctl status conductor
journalctl -u conductor -f
```

本机健康检查：

```sh
curl -fsS http://127.0.0.1:8080/health
```

## 6. Nginx 反向代理

安装 Nginx 和证书工具后，为 `conductor.moyu.ge` 申请证书。Nginx 站点示例：

```nginx
server {
    listen 80;
    server_name conductor.moyu.ge;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name conductor.moyu.ge;

    ssl_certificate /etc/letsencrypt/live/conductor.moyu.ge/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/conductor.moyu.ge/privkey.pem;

    client_max_body_size 40m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /ws/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

启用后检查：

```sh
sudo nginx -t
sudo systemctl reload nginx
curl -fsS https://conductor.moyu.ge/health
```

## 7. Caddy 反向代理可选方案

如果使用 Caddy，配置更短：

```caddyfile
conductor.moyu.ge {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy 会自动处理 HTTPS 和 WebSocket upgrade。

## 8. 客户端连接公网服务

客户端默认 Server URL 已经是：

```text
https://conductor.moyu.ge
```

启动客户端后进入 Settings：

- `Server URL`：保持 `https://conductor.moyu.ge`，保存或启动时会变成 `wss://conductor.moyu.ge/ws/agent`
- `Agent Token`：填写服务器 `/etc/conductor.env` 中的 `CONDUCTOR_AGENT_TOKEN`
- `Agent Name`：填写便于识别的名称，例如 `win-client-01`
- `File Root`：填写允许远程文件管理的目录
- `Audio Input`：按平台填写，或留空使用默认策略
- `Require local approval`：公网测试建议先开启，确认链路后再按需要关闭

也可以在 GitHub Actions 手动构建时把 Agent Token 烘入默认值，但公网测试不建议把真实 token 写入公开仓库或公开 artifact。

## 9. 部署后验证

浏览器访问：

```text
https://conductor.moyu.ge
```

登录账号：

- 用户名：`CONDUCTOR_ADMIN_USERNAME`
- 密码：`CONDUCTOR_ADMIN_PASSWORD`

验证顺序：

1. 打开 `/health`，确认返回 `{"ok":true}`。
2. 登录后台，确认页面能加载。
3. 在一台客户端机器启动 Flutter 被控客户端。
4. Settings 中填写正确 `Agent Token` 后点击 `Start Agent`。
5. 后台设备列表应出现该 Agent。
6. 进入设备详情，验证聊天、文件列表、远控会话。
7. 如 Agent 未上线，在客户端 `Agent Command` 输入 `/diagnostics` 并查看日志。

如果本机命令行 Agent 要连公网服务：

```sh
CONDUCTOR_SERVER_URL=https://conductor.moyu.ge \
CONDUCTOR_AGENT_TOKEN=<same-agent-token> \
CONDUCTOR_AGENT_NAME=linux-public-test \
cargo run -p conductor-agent
```

Agent 会把 HTTPS 地址规范化为 `wss://conductor.moyu.ge/ws/agent`。

## 10. 更新发布

每次合并到 GitHub 后：

1. 等待 `Build` workflow 成功。
2. 下载 `conductor-server-linux-x64`。
3. 在服务器校验 `.sha256` 并替换 `/opt/conductor/bin/conductor-server`。
4. 执行：

```sh
sudo systemctl restart conductor
sudo systemctl status conductor
curl -fsS https://conductor.moyu.ge/health
```

5. 下载需要的平台客户端 artifact，发给测试机器。

如果只改客户端默认配置，可以手动运行 `workflow_dispatch` 并填写 `client_server_url=https://conductor.moyu.ge` 重新生成三端客户端包。
