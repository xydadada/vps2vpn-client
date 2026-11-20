# 客户端 Core / IPC / Helper 审计记录（2026-11-20）

## 基线、范围与验证边界

审计基线是客户端提交 [5860a5ba2ab6001869586561fccb56309db6c3e1](https://github.com/xydadada/vps2vpn-client/commit/5860a5ba2ab6001869586561fccb56309db6c3e1)。本文负责 Core、桌面 IPC 和特权 Helper；应用层及服务端发现由总报告补充。本文列出的基线行号便于定位，实际修复以 PR 的完整 diff 为准。

工作先在隔离工作目录进行，公开子模块按已有 SHA 初始化，未修改子模块版本。Go 1.27.1 的官方二进制 SHA 已核验；Flutter 3.50.0 与 Rust 工具链亦已准备。执行环境随后报告 unavailable，命令服务恢复超时，导致后续本地测试及读取工作树中断。修复通过 GitHub MCP 重新读取基线源码，在内存中断言每处替换上下文唯一，再重建并提交。**下文的本地成功记录来自中断前实现；重建后的提交尚未重新执行测试，不能据此宣称最终 head 已通过。** 新增 PR 工作流用于复验最终提交。

没有运行真实 VPN、接管宿主网络、安装系统服务或修改默认分支。没有进行吞吐量、丢包、移动网络切换或跨操作系统设备实测，也不声称整个仓库所有文件已完成逐行审计。

## 已确认问题与修复

| 编号 | 级别 | 基线位置 | 原因与影响 | 实际修复与回归 |
| --- | --- | --- | --- | --- |
| CC-01 | 高 | `core/vps2vpn_smart.go:77,130` | 重名检查只看组名，不看真实代理节点。订阅包含名为“⚡ 智能线路”或“🤖 AI 专线”的节点时，增强代码创建同名组，导致语义解析失败；调用方会转入无代理的默认配置。 | 在统一出站命名空间内检查节点与组。碰撞时保留订阅，跳过相应自动组。新增两种名称碰撞回归，要求增强后仍能 ParseRawConfig。 |
| CC-02 | 中 | `core/vps2vpn_smart.go:159` | 选择器成员仅断言为 `[]any`；合法的 `[]string` 被视为空，原成员全部丢失。 | 保留两种字符串列表表示；未知类型不做破坏性改写。新增 typed selector 成员顺序回归。 |
| CC-03 | 中 | `core/profile_base.go:101-123` | config.yaml 在智能组、AI 规则和 REALITY 默认指纹加入前写入。Android 独立后台启动或外部控制器重载文件时，与当前运行配置不一致。 | 增强操作返回最小变更记录，将相同修改施加到 YAML 节点。持久化智能组、选择器首选、AI 规则插入位置和指纹。回归直接使用上游 UnmarshalRawConfig + ParseRawConfig 读取磁盘文件，避免再次经过增强逻辑掩盖错误；覆盖普通与继承顶层 YAML。 |
| CC-04 | 中 | `core/profile_base.go:110` | 无效出站引用等语义错误在 config.yaml 被替换后才发现，丢失上次有效配置。 | 先写独立临时文件，完成语义解析后再原子重命名；失败清理临时文件并保留旧文件。保留原有分片流式编码，先释放 YAML 树再进行语义解析，避免把整个大配置重复序列化。回归检查错误规则不会改变已有配置字节。 |
| CC-05 | 高 | `core/profile_base.go:126,183` | YAML merge key 在解码前被自有递归函数遍历；`&root {<<: *root}` 可令 mappingValue 无界递归，最终触发 Go 致命栈耗尽。常规 recover 无法可靠兜底。 | 在 profile/overlay 的任何递归遍历前，用节点访问状态检测别名环，返回带行号错误。新增自引用 merge、递归列表、间接环，分别覆盖 profile 与 overlay。检查对节点图线性运行；不宣称覆盖所有非循环 alias 膨胀形态。 |
| CC-06 | 中 | `core/rule_set.go:43,90` | 同名编译可并发下载、写 source 与 mrs；固定 `.tmp` 互相删除/重命名，可能报错或让 source/mrs 来自不同请求。 | 同名编译沿用既有 update claim 所有者，冲突返回 rule_set_updating；文件写入采用 CreateTemp 独立随机文件与原子重命名，并恢复目录所有权调度。新增 32 个同时写入的完整文件检查、同名下载阻塞期间第二次编译拒绝回归；保留原符号链接防护测试。不同进程或其他 provider 写入的跨所有者原子性不在此修复保证范围内。 |
| CC-07 | 中 | `lib/core/desktop/launcher.dart:41` | stderr 按操作系统字节块逐块 utf8.decode；一个中文字符跨块时，合法日志也会抛 FormatException；损坏字节同样触发未处理异常。 | 使用流式 Utf8Decoder 并允许替换损坏字节。新增拆开中文首字节并注入 0xff 的日志回归。 |
| CC-08 | 中 | `lib/core/desktop/transport.dart:267` | 在 firstWhere 生成的 Future 外设置 timeout，仅结束等待 Future；底层广播流订阅仍保留，重复启动超时积累等待器直到未来事件到来。 | 在筛选后的 Stream 设置 timeout，再以 first 消费；错误完成会取消订阅。使用原有 transport/lifecycle 测试验证正常连接语义；没有宣称完成专门的订阅计数实测。 |
| CC-09 | 高 | `services/helper/src/service/hub.rs:124,503` | 子进程已经 spawn 后，Windows Job Object 创建/绑定失败使 adopt 提前返回。Rust Child drop 不终止子进程，Helper 丢失特权 Core 的所有权，可能遗留运行进程及 TUN。 | adopt 失败时同时返回仍持有 Child 的 ManagedCore；立即使用现有退出确认流程回收。回收失败仍保留 ManagedCore，并返回 coreStopFailed，供后续 stop 重试；只在确认退出后释放所有权。现有退出/Job 生命周期测试纳入 Windows CI；尚未进行 Windows 内核绑定失败的故障注入。 |
| CC-10 | 中 | `.github/workflows/` | 原有构建及 E2E 工作流均仅支持手动触发，PR 没有自动核心/应用测试门禁。 | 新增 pull_request 和 workflow_dispatch 审计工作流：Go fmt/vet/Android vet、race 全包测试、Flutter analyze/全量测试、Helper Linux/Windows 与 windows-service 编译测试、Rust native 测试及脚本回归。权限限定 contents:read；不发布、不部署、不合并。 |

## 设计决策与兼容性

增强组继续遵循原有协议排序、主服务器优先和用户规则优先策略，未凭经验修改探测间隔、失败计数或分流域名。新逻辑只修复命名冲突、表示类型与持久化一致性。已存在的智能组仍被视为订阅自身配置，重复执行不会再次添加。

YAML 增强采用变化记录更新原有节点，保留订阅中的未知字段及原有分片写入路径。重建实现进一步将“临时文件写入”与“替换 config.yaml”分开：写临时文件时释放节点，再语义解析，最后提交文件。这与中断前先解析再写文件的局部实现有所不同，属于仍需 CI 复跑的部分。现有配置失败时应用运行默认配置的行为没有在这里改变，不能把“保留旧磁盘文件”理解成“保持旧运行连接”。

规则集 claim 复用既有生命周期所有者，没有引入另一套长期状态表。对同一名称的并发请求返回明确错误，避免下载结果、分类结果及缓存文件静默交叉；不同名称仍可并行。

Windows Helper 只改变失败路径上的所有权，保留现有 session 校验、固定 Core 路径、SHA256 检查、Windows 账户认证、消息限长以及 stop 重试流程。Rust 标准库明确说明 [Child 不会在 Drop 时杀死子进程](https://doc.rust-lang.org/std/process/struct.Child.html)，这是 CC-09 的根本原因。没有替换上游 IPC 库或放宽访问控制。

CI 使用与项目一致的 Go 1.27.1 / Flutter 3.50.0。当前环境中官方 Flutter archive 路径返回 404，而 3.50.0 tag 源码 bootstrap 可用，所以工作流通过该 tag 克隆。CI 设置 CI=true 与 analytics suppression 环境变量；只在临时检出中关闭 setup 的 Go 构建 hook，Go 由独立 job 完整验证，Rust native hook 保留。没有改动已锁定依赖或任何子模块 pin，也没有加入会因继承代码原有样式问题必然失败的全仓 Rust 格式门禁。

## 验证记录

| 检查 | 已观察结果 | 对最终重建提交的含义 |
| --- | --- | --- |
| Go 1.27.1：`CGO_ENABLED=0 go test -count=1 . -run 'TestVps2vpn\|TestLoadConfigWithBase\|TestProfileMergeRejects\|TestRejectedProfile'`，工作目录 core | 中断前通过，输出 `ok core 0.038s`。覆盖智能组、加载/独立重载、无效配置、循环 alias 等测试。 | 实际成功证据仅适用于中断前版本；重建代码及测试有人工重构，尤其临时文件提交顺序，必须复跑。 |
| Dart formatter：launcher.dart、transport.dart、launcher_test.dart | 中断前执行成功；当时依赖解析尚未完成，存在 package resolution 警告。 | 不等于 Dart 分析或测试通过；重建文件需要重新验证格式。 |
| 全量 Go 测试、go vet、race | 尚无完整成功结果；后续命令遇到路径/执行环境中断，不能记为已通过。 | 已加入独立 CI job，等待该提交的实际结果。 |
| Flutter analyze / test | 本分工没有取得运行结果，应用层其他记录由总报告独立说明。 | 新增完整 Flutter CI；不能以准备好 SDK 代替验证。 |
| Helper / rust_api cargo test、Windows 编译、Rust fmt | 工具链已准备，但没有可验证的完成结果。 | 新增 Linux/Windows Helper 与 Linux native 测试；Windows Job 故障注入仍需真实平台补充。 |
| Android / iOS / macOS / Windows 安装包、真实 TUN、吞吐量与网络恢复 | 未执行。 | PR 不能据此标记所有平台已验证。Android Go 静态检查覆盖有限，不能代替原生构建和设备测试。 |

当前验证状态是审计提交创建时的快照；最终 PR 总报告应补充真实 Actions run URL、最终 head 和任何失败原因。工作流存在不代表检查已经运行或通过。

## 实际阅读覆盖

以下项目自身 Core 顶层生产文件已完整阅读。上游 Clash.Meta 仅为理解接口按需查看，没有声称重新审计其整个代码库。

- `core/certificate.go`
- `core/config.go`
- `core/connection.go`
- `core/delay.go`
- `core/dial_pipe.go`
- `core/dial_socket.go`
- `core/dns_query.go`
- `core/exit.go`
- `core/filter.go`
- `core/geo.go`
- `core/hooks.go`
- `core/lib.go`
- `core/lifecycle.go`
- `core/log.go`
- `core/message.go`
- `core/method.go`
- `core/outbound_ip.go`
- `core/ownership_other.go`
- `core/ownership_unix.go`
- `core/probe.go`
- `core/profile_base.go`
- `core/protect.go`
- `core/protocol.go`
- `core/provider.go`
- `core/proxy.go`
- `core/region.go`
- `core/request_traffic.go`
- `core/route.go`
- `core/rule_set.go`
- `core/server.go`
- `core/service_check.go`
- `core/service_rules.go`
- `core/share_link.go`
- `core/short_id.go`
- `core/slots.go`
- `core/spill.go`
- `core/vps2vpn_smart.go`

另外已完整阅读：

- 桌面 Dart：`helper_client.dart`、`core_manifest.dart`、`rpc_client.dart`、`transport.dart`、`launcher.dart`、`launch_policy.dart`、`lifecycle.dart`、`process_probe.dart`，以及 `lib/core/spill.dart`。
- Helper：`src/main.rs`、`src/service/mod.rs`、`linux.rs`、`windows.rs`、`owner.rs`、`peer.rs`、`build.rs` 与 Cargo.toml。hub.rs 的生产部分（约前 900 行）完整阅读；后续测试按有关退出、stop 与 Job 路径审查，不宣称全部测试逐行阅读。
- Rust IPC：`ipc/mod.rs`、`access.rs`、`frame.rs`；该范围包括平台权限策略和帧长检查，server/outbox 的完整审查尚未完成。
- 回归相关：`vps2vpn_smart_test.go`、`profile_base_test.go`、`rule_set_test.go`、`test/core/desktop/launcher_test.dart`；transport 测试按相关路径审查。
- 构建及说明：两份原工作流、pubspec.yaml、Cargo.toml、Go module 定义、Makefile 的相关目标；AGENTS、项目/命令/规则说明与 core-platform、pre-commit-quality-review 技能；architecture 文档的生命周期、IPC、构建、Helper 部分。

未完成完整阅读的范围包括 Core 下 mobile/platform/timezone/tun/cmd 子目录、部分 lib/core facade/model、Rust native 其余模块、原生 Android/iOS/macOS/Linux/Windows 全部平台代码、其余本地插件与大量继承 UI/工具代码。新增 CI 的构建测试并不扩展人工逐行审查的范围。

## 尚未验证或后续工作

1. 最终重建 head 的所有新增回归必须由 CI 运行，失败应修正后才考虑合并。特别关注 Windows Rust 编译、YAML alias/merge roundtrip 与 Dart 流事件行为。
2. 使用 Windows 故障注入验证 Job Object 绑定失败后进程确实退出；模拟 kill/try_wait 失败确认会保留所有权并允许重试。
3. 在大型订阅上测量峰值 RSS、加载时延与重载结果；当前修复保留流式 writer，尚无性能基准结果。
4. 继续审查未覆盖的平台/插件代码，尤其系统代理恢复、自动启动、特权 Helper 安装目录权限和升级时的可执行文件替换窗口。此处是待查范围，不把尚无充分证据的怀疑列作已确认漏洞。
5. 评估配置拒绝后的运行默认配置策略及产品提示。当前语义由原实现与 Dart 状态契约共同定义，需跨层修改和真实连接验证。
6. 无环但高度共享的 YAML alias 图、跨进程缓存写入、真实移动网络与 DNS/路由故障恢复，均不应因本次修复而被视为已经全面证明安全或可靠。
