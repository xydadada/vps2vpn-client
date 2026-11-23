# vps2vpn Wording

The simple-mode pages, the tray and every message a user reads use one word per idea, in Chinese and in English.
Use this list when adding or changing user-facing text in `lib/vps2vpn/` or the tray.

| Idea | 中文 | English | Avoid |
|---|---|---|---|
| Start using the line | 连接 | Connect | 启动, Start |
| Stop using the line | 断开 | Disconnect | 暂停, 停止, Stop |
| While starting | 连接中… | Connecting… | |
| State when not in use | 未连接 | Not connected | Disconnected |
| The account holder who hands out links | 管理员 | owner | admin |
| The link the owner hands out | 订阅链接 | subscription link | 配置, config URL |
| One server of the subscription | 服务器 | server | |
| A protocol entry under a server | 节点 | node | |
| The automatic choice | 智能线路 | Smart line | Smart lines |
| The fixed exit for AI services | AI 专线 | AI line | |
| Routing modes | 规则模式 / 全局模式 | Rule mode / Global mode | 直连 (not offered in simple mode) |
| Ways to take over traffic | 系统代理 / 虚拟网卡 | System proxy / TUN | |
| A temporary hold by the server | 已暂停 | Paused | |

Errors say what happened and what to do next, in these words; the raw text stays behind a tap (`vpsPlainError` in
`lib/vps2vpn/plain_errors.dart`).
