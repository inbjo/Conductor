针对比赛任务，由于时间紧任务重，我打算选用 Flutter UI + WebRTC + Rust 服务端（信令与房间管理）现代且高性能的架构。利用现有的开源生态（如 Flutter 的 flutter_webrtc，Rust 的 tokio、warp/axum 或 tungstenite），可以尽量减少开发工作量。

我已克隆业界开源最好的rustdesk项目在本地 @/home/flex/Code/Rust/remote 可以参考该项目的设计思想和实现方式。

Flutter 客户端 负责UI 交互、视频流渲染、设备控制，可使用开源库：flutter_webrtc, web_socket_channel, flutter_riverpod (状态管理) 代码放在client文件夹管理。

Rust 服务端负责WebSocket 信令转发、房间/ID 撮合
可以使用开源库，axum (Web 框架), tokio (异步运行时), tower-http (跨域与网络处理) 代码放在server文件夹管理。

## 现在需要你帮我输出一份完善的开发计划，写入到docs/plan.md

文档要求：

- 1.写清楚技术架构和实现方案
- 2.需要详细拆分开任务，每个任务需要明确任务目标，实现细节，验收标准，以及边界用例测试。
- 3.不要重复造轮子，尽量使用开源成熟的依赖库。

codex resume 019f0448-dfcf-7c41-ad61-ebf3aedfbdca
