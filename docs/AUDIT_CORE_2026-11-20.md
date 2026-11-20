# 客户端 Core / IPC / Helper 审计记录（2026-11-20）

## 基线、范围与验证边界

审计基线是客户端提交 [5860a5ba2ab6001869586561fccb56309db6c3e1](https://github.com/xydadada/vps2vpn-client/commit/5860a5ba2ab6001869586561fccb56309db6c3e1)。本文负责 Core、桌面 IPC 和特权 Helper；应用层及服务端发现由总报告补充。本文列出的基线行号便于定位，实际修复以 PR 的完整 diff 为准。

工作先在隔离工作目录进行，公开子模块按已有 SHA 初始化，未修改子模块版本。Go 1.27.1 的官方二进制 SHA 已核验；Flutter 3.50.0 与 Rust 工具链亦已准备。执行环境随后报告 unavailable，命令服务恢复超时，导致后续本地测试及读取工作树中断。修复通过 GitHub MCP 重新读取基线源码，在内存中断言每处替换上下文唯一，再重建并提交。**下文的本地成功记录来自中断前实现；执行环境中断后没有在本地复跑，不能据此宣称最终 head 已通过。** 重建后的 GitHub Actions 实际结果单独记录在“首轮 GitHub Actions 与合并阻断”，后续修正仍须在其对应 head 复验。

没有运行真实 VPN、接管宿主网络、安装系统服务或修改默认分支。没有进行吞吐量、丢包、移动网络切换或跨操作系统设备实测，也不声称整个仓库所有文件已完成逐行审计。

## 已确认问题及处理状态

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

## 首轮 GitHub Actions 与合并阻断

[审计运行 44715931908](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908) 针对 PR head `89ab9f77c891a34ac19bdaafe500fa45a5f7bb8e`，checkout 的 PR 合并快照为 `9db79dd271af151f145629356e1854be04f31d93`。已观察到：

- [Linux Helper](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908/job/136219210165)：47 passed，0 failed。
- [Windows Helper](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908/job/136219210248)：普通模式 40 passed，windows-service 模式 43 passed，均无失败。
- [Linux native Rust](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908/job/136219209779)：126 passed，0 failed；包括 IPC 权限、帧边界、关闭与线程退出回归。
- [Core](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908/job/136219210188)：格式检查只报告 profile_base_test.go；race 全包运行暴露了下面两类失败。
- [Flutter](https://github.com/xydadada/vps2vpn-client/actions/runs/44715931908/job/136219210335)：SDK bootstrap 与 pub get 成功；analyze 的唯一 warning 是新增 account_test.dart 未使用的 Riverpod import，另有 6 条非阻断 info。全量 bundled 测试首轮报告 `+5096 ~6 -77`；随后 tool/test.dart 开始逐文件复跑失败项，但该 run 被后续提交取消，不能视作最终完整测试结论。失败涉及旧导航/仪表盘布局预期、kit.dart 字体约束及 4 项本地 panel HTTP 测试，已交应用层核查。新增 Core stderr 测试没有列入首轮失败清单。

持久化回归曾错误地在 ParseRawConfig 后假设 raw.ProxyGroup[0] 仍是主选择器。上游解析会原地拓扑排序，实际该位置是自动 fallback 组，报 `persisted selector members = [b a]`。这条断言现改为按名称查找主选择器 `g`；同时调整测试 fixture 排版以通过 gofmt。该修正针对测试对上游可变参数的错误假设，不是删除持久化断言。后续 CI 增加单独无 race 的全包测试，和 race 检查分别报告；两道门禁均保留。

### CC-11：外部控制器重建的数据竞争（已确认，未修复，阻止合并）

固定子模块 [5b453f8 的 hub/route/server.go](https://github.com/chen08209/Clash.Meta/blob/5b453f80dbcee6b3ecfb0415bcace24a48c88707/hub/route/server.go) 中，ReCreateServer（约 92 行）直接启动多个 goroutine。start（164 行读取、183 行写入 httpServer）对共享 server 指针没有同步；TLS、Unix 和 named pipe 同样使用自己的无锁全局指针。

实际 race 栈为：

```text
WARNING: DATA RACE
Write: mihomo/hub/route.start, server.go:183
Previous read: mihomo/hub/route.start, server.go:164
Both created by: route.ReCreateServer, server.go:93
Caller: core.patchController, config.go:312
Caller: core.updateConfig, config.go:234
Tests: TestUpdateConfigReplacesTheSecretTheProfileCarried (config_test.go:288)
       TestUpdateConfigServesTheControllerBehindTheSecretItWasGiven (config_test.go:308)
```

客户端的 configMu 只序列化外层调用，无法等待上游启动 goroutine 完成；hub.ApplyConfig 也调用此入口。快速修改外部控制器地址/密钥或连续重载存在启动顺序颠倒、旧 server 未被关闭、最新认证/监听意图未生效的风险。首轮运行在约 6 秒的测试阶段由 Go race detector 明确判定失败，不是网络测试偶发超时。

已检查当前依赖 fork 的 FlClash 分支，head 仍为上述 pin。也检查了 [MetaCubeX/mihomo Alpha](https://github.com/MetaCubeX/mihomo/blob/100ff73ae769c15562d6e174e88bf0da401ec4e2/hub/route/server.go) 与 [Meta 分支](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/hub/route/server.go)，两者仍有相同异步无锁逻辑，未找到可最小兼容升级取得的现成修复。依赖没有公开完成句柄或同步替换接口。仅在外层加 mutex、sleep、跳过测试或特判空 controller 都不能修复一般情形。

正确后续方案是在依赖里将每种 server 的关闭、监听创建、共享指针替换置于同一所有者下并保持更新顺序，待安装完成后再异步 Serve；补快速启停/换密钥回归并运行 race。若由本项目维护源码补丁，必须统一覆盖直接 go test、Makefile、Flutter setup hook、Android gomobile 和发布构建，校验所针对的源版本，避免只在 CI 临时打补丁。本 PR 保留失败的 race 门禁，**在该问题解决前不应合并**。

本文早先“本地验证记录”保留为中断时快照；以上 GitHub 结果是后续取得的新证据。当前测试修正及最终 head 是否通过以更新后的 run 为准，不能把旧 run 的成功项当成最终提交全绿。

## 设计决策与兼容性

增强组继续遵循原有协议排序、主服务器优先和用户规则优先策略，未凭经验修改探测间隔、失败计数或分流域名。新逻辑只修复命名冲突、表示类型与持久化一致性。已存在的智能组仍被视为订阅自身配置，重复执行不会再次添加。

YAML 增强采用变化记录更新原有节点，保留订阅中的未知字段及原有分片写入路径。重建实现进一步将“临时文件写入”与“替换 config.yaml”分开：写临时文件时释放节点，再语义解析，最后提交文件。这与中断前先解析再写文件的局部实现有所不同，属于仍需 CI 复跑的部分。现有配置失败时应用运行默认配置的行为没有在这里改变，不能把“保留旧磁盘文件”理解成“保持旧运行连接”。

规则集 claim 复用既有生命周期所有者，没有引入另一套长期状态表。对同一名称的并发请求返回明确错误，避免下载结果、分类结果及缓存文件静默交叉；不同名称仍可并行。

CC-09 的 Windows Helper 修改只改变失败路径上的所有权，保留现有 session 校验、固定 Core 路径、SHA256 检查、Windows 账户认证、消息限长以及 stop 重试流程。Rust 标准库明确说明 [Child 不会在 Drop 时杀死子进程](https://doc.rust-lang.org/std/process/struct.Child.html)，这是 CC-09 的根本原因。没有替换上游 IPC 库或放宽访问控制。

CI 使用与项目一致的 Go 1.27.1 / Flutter 3.50.0。当前环境中官方 Flutter archive 路径返回 404，而 3.50.0 tag 源码 bootstrap 可用，所以工作流通过该 tag 克隆。CI 设置 CI=true 与 analytics suppression 环境变量；只在临时检出中关闭 setup 的 Go 构建 hook，Go 由独立 job 完整验证，Rust native hook 保留。没有改动已锁定依赖或任何子模块 pin，也没有加入会因继承代码原有样式问题必然失败的全仓 Rust 格式门禁。

## 执行环境中断时的本地验证快照

| 检查 | 已观察结果 | 对最终重建提交的含义 |
| --- | --- | --- |
| Go 1.27.1：`CGO_ENABLED=0 go test -count=1 . -run 'TestVps2vpn\|TestLoadConfigWithBase\|TestProfileMergeRejects\|TestRejectedProfile'`，工作目录 core | 中断前通过，输出 `ok core 0.038s`。覆盖智能组、加载/独立重载、无效配置、循环 alias 等测试。 | 实际成功证据仅适用于中断前版本；重建代码及测试有人工重构，尤其临时文件提交顺序，必须复跑。 |
| Dart formatter：launcher.dart、transport.dart、launcher_test.dart | 中断前执行成功；当时依赖解析尚未完成，存在 package resolution 警告。 | 不等于 Dart 分析或测试通过；重建文件需要重新验证格式。 |
| 全量 Go 测试、go vet、race | 尚无完整成功结果；后续命令遇到路径/执行环境中断，不能记为已通过。 | 已加入独立 CI job，等待该提交的实际结果。 |
| Flutter analyze / test | 本分工没有取得运行结果，应用层其他记录由总报告独立说明。 | 新增完整 Flutter CI；不能以准备好 SDK 代替验证。 |
| Helper / rust_api cargo test、Windows 编译、Rust fmt | 工具链已准备，但没有可验证的完成结果。 | 新增 Linux/Windows Helper 与 Linux native 测试；Windows Job 故障注入仍需真实平台补充。 |
| Android / iOS / macOS / Windows 安装包、真实 TUN、吞吐量与网络恢复 | 未执行。 | PR 不能据此标记所有平台已验证。Android Go 静态检查覆盖有限，不能代替原生构建和设备测试。 |

本表保留执行环境中断时的验证快照；后续取得的真实 GitHub Actions 结果见上方“首轮 GitHub Actions 与合并阻断”。最终 PR 总报告应继续补充最终 head 对应的 run，不能把工作流存在当成通过。

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

补充完整阅读的自有 Go 子目录：`core/cmd/core/main.go`、`mobile/mobile.go`、`platform/limit.go`、`platform/procfs.go`、`timezone/timezone.go`、`timezone/timezone_android.go`、`tun/tun.go`。截至后续审查，自有 Go 生产源文件已全部阅读，外部 Clash.Meta 仍仅按关联机制审查。

另外已完整阅读：

- 桌面 Dart：`helper_client.dart`、`core_manifest.dart`、`rpc_client.dart`、`transport.dart`、`launcher.dart`、`launch_policy.dart`、`lifecycle.dart`、`process_probe.dart`，以及 `lib/core/spill.dart`。
- Helper：`src/main.rs`、`src/service/mod.rs`、`linux.rs`、`windows.rs`、`owner.rs`、`peer.rs`、`build.rs` 与 Cargo.toml。hub.rs 的生产部分（约前 900 行）完整阅读；后续测试按有关退出、stop 与 Job 路径审查，不宣称全部测试逐行阅读。
- Rust IPC：`ipc/mod.rs`、`access.rs`、`frame.rs`、`server.rs`、`outbox.rs`、`unsupported.rs`（含其中测试）；覆盖平台权限、帧边界、单 peer 交换、发送队列、关闭及线程生命周期。
- 回归相关：`vps2vpn_smart_test.go`、`profile_base_test.go`、`rule_set_test.go`、`test/core/desktop/launcher_test.dart`；transport 测试按相关路径审查。
- 构建及说明：两份原工作流、pubspec.yaml、Cargo.toml、Go module 定义、Makefile 的相关目标；AGENTS、项目/命令/规则说明与 core-platform、pre-commit-quality-review 技能；architecture 文档的生命周期、IPC、构建、Helper 部分。

未完成完整阅读的范围包括 Rust native 其余模块、原生 Android/iOS/macOS/Linux/Windows 全部平台代码、其余本地插件与大量继承 UI/工具代码。新增 CI 的构建测试并不扩展人工逐行审查的范围。

## 尚未验证或后续工作

1. 最终重建 head 的所有新增回归必须由 CI 运行，失败应修正后才考虑合并。特别关注 Windows Rust 编译、YAML alias/merge roundtrip 与 Dart 流事件行为。
2. 使用 Windows 故障注入验证 Job Object 绑定失败后进程确实退出；模拟 kill/try_wait 失败确认会保留所有权并允许重试。
3. 在大型订阅上测量峰值 RSS、加载时延与重载结果；当前修复保留流式 writer，尚无性能基准结果。
4. 继续审查未覆盖的平台/插件代码，尤其系统代理恢复、自动启动、特权 Helper 安装目录权限和升级时的可执行文件替换窗口。此处是待查范围，不把尚无充分证据的怀疑列作已确认漏洞。
5. 评估配置拒绝后的运行默认配置策略及产品提示。当前语义由原实现与 Dart 状态契约共同定义，需跨层修改和真实连接验证。
6. 无环但高度共享的 YAML alias 图、跨进程缓存写入、真实移动网络与 DNS/路由故障恢复，均不应因本次修复而被视为已经全面证明安全或可靠。

## 后续服务安装路径审计与修复

### CC-12：Linux 只检查直接父目录，未建立完整可信路径（高）

基线 services/helper/src/service/linux.rs:180-195 的 ensure_root_owned 只检查 Helper 文件及直接父目录。若 root 拥有的安装目录放在普通用户可写的更高层目录下，普通用户可在同一父目录中重命名该安装目录，再创建同名替代目录。检查叶文件的 owner/mode 不能阻止这种替换；systemd 下次按 ExecStart 路径启动时将运行替代内容。此处依赖的目录重命名权限见 [Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)。没有在用户宿主上执行提权复现或安装服务。

新增 install_path_linux.rs，从根目录开始按组件使用 openat(O_PATH | O_NOFOLLOW | O_CLOEXEC)，在打开下一级前检查当前实际 inode。所有祖先都必须为 root 拥有且不可由组或其他用户写入；中间节点必须是目录，最终节点必须是普通文件，链接及父目录穿越被拒绝。安装过程中保留句柄；同时在 VerifiedCore::open 使用相同检查，补上 Linux hash 检查后按路径 spawn 之间原有的可写 Core 文件替换风险。

未来 systemd 启动仍按路径执行，安全保证依赖于所有已检查祖先和叶文件均不可被非特权账户修改；不声称能防御已具有 root 权限的修改者。O_PATH 也避免把 FIFO 等非普通叶节点当作可读文件打开而阻塞。Linux 回归使用隔离临时目录和真实 openat/fstat，测试只读完整链、上层可写目录、可写叶文件、不同 owner、文件/目录符号链接及路径穿越；没有启动系统服务。

### CC-13：Windows 可把用户可写位置的 Helper 注册为 LocalSystem 服务（高）

基线 services/helper/src/service/windows.rs:147-168 直接取 current_exe 并注册为 AutoStart，account_name 为 None；该值对应 LocalSystem（[CreateServiceW 官方定义](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-createservicew)）。Dart 的 lib/common/system.dart:333-335 可以从应用随附的 helperPath 发起安装；只有 Inno Setup 默认管理员安装的文件布局受安装器保护，Helper 自注册入口本身没有检查当前目录和文件的权限。若从用户可写的解压目录批准注册，之后该用户可替换服务文件，取得下一次服务启动的权限。Core 的 SHA256 不能保护 Helper 本身。

新增 install_path_windows.rs 读取每层现存路径的实际句柄 owner 和 DACL（[GetSecurityInfo](https://learn.microsoft.com/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)），拒绝链接/reparse point 和远程/遍历路径。owner 仅接受 SYSTEM、Administrators、TrustedInstaller；对可修改现存路径的普通 SID ACE 失败关闭，并展开 generic rights。检查覆盖叶文件写内容、所有层的属性写入/删除/改 owner/DACL，以及目录的删除子对象权限；属性写入可能授权设置 reparse point（[MS-FSA 定义](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fsa/4aeefef8-92c3-4abc-af7a-a610caf8a165)），不能仅检查文件内容写入。直接安装目录还禁止普通用户新建文件/目录，避免在二进制旁植入加载内容。

较高祖先中的 FILE_ADD_SUBDIRECTORY 单独不视为替换现有路径的权限，因此默认 C:\ 根目录允许普通用户创建自己的子目录不会被误报。继承专用 ACE 不适用于当前对象；未知 ACE 类型不猜测为安全。此策略保守拒绝无法证明安全的自定义 ACL，错误提示要求使用 Windows 安装器安装到受保护目录；并在删除现有服务之前完成校验。VerifiedCore::open 同样校验 Core 文件及祖先；现有 SHA256 校验和打开句柄期间的 Windows 写入/删除共享限制仍保留。

Windows 回归用系统 API 从 SDDL 构造真实安全描述符，覆盖受保护安装布局、普通用户 owner、空/缺失 DACL、generic/具体写权限、删除子项、继承专用 ACE、未知 allow ACE，以及“祖先只准创建子目录”与“叶文件可写”的区别。另只读校验 runner 的 System32\svchost.exe，以检查默认系统目录布局；不执行该文件、不修改 ACL、不注册服务。上述新增测试必须以包含本补丁的 CI 结果为准，尚无本地执行记录。

### 后续验证与补充覆盖

[运行 44717191763 的 Core job](https://github.com/xydadada/vps2vpn-client/actions/runs/44717191763/job/136223613324) 对 head 1fcf0397345324d34f2a8162c59ab6b14dbba3eb 已完成：make core-check 成功；普通全包测试输出 “ok core 5.419s”；race 唯一失败仍为 CC-11 的 TestUpdateConfigServesTheControllerBehindTheSecretItWasGiven，输出 “FAIL core 5.784s”。这证明此前持久化测试断言与 gofmt 修正已通过；并不消除上游 race，也不等于后续服务路径补丁已被验证。

补充完整阅读了 lib/core 全部自有生产文件，lib/common/{launch,system,function,future,constant,print}.dart，Rust launch 下 mod/entries/linux/macos/windows 及 api/launch.rs，Windows Inno 安装脚本；再次沿原生 IPC access/frame/server/outbox 到 Dart transport/lifecycle 及 Go server/dial 追踪权限、帧界限和关闭路径。上述范围以外仍遵循前述未覆盖清单。

曾怀疑 interface.dart RPC 参数日志泄漏；完整追到 handleWatch 后确认该路径同时受 kDebugMode 与 const watchExecution=false 限制，当前代码不可达，因此撤回该候选，没有把它列为已修漏洞，也没有添加无法触发的虚假回归。

原生 IPC 复核没有新增已证实缺陷：Unix 连接同时限制 socket mode 与 peer UID，帧在分配前校验 64 MiB 上限，outbox 对待发送字节实施预算并在断开清空，关闭由 select 取消 receive/transmit。Windows 跨账户 named pipe 的实际访问和设备电源暂停仍需要平台专项测试，不能以源代码检查断言所有故障情形均已验证。

### CC-14：Linux 自动启动把可执行路径当作未转义的 Exec 命令（中）

基线 plugins/rust_api/rust/src/launch/linux.rs:18-28 直接写 Exec={executable}；lib/common/launch.dart 传入真实 Platform.resolvedExecutable。包含空格、引号、反斜杠、美元符、反引号或百分号的合法安装路径可能被拆成参数或误当 field code，导致登录后无法启动。包含换行的值还会破坏 desktop 文件的键边界。这一缺陷由调用链和格式要求确认，未在桌面会话执行自动登录复现。

修改按 [freedesktop Exec 规则](https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html) 先构造完整双引号参数，再按 [desktop string 规则](https://specifications.freedesktop.org/desktop-entry/latest/value-types.html) 转义值；字面百分号写为 %%；换行、回车、Tab 保持为值内的转义序列，display name 同样处理。规范禁止的等号路径、空路径和不能表示的控制字符返回失败，不覆盖此前条目。

旧 isEnabled 仅判断文件存在，会把坏的旧 Exec 当成已启用，使升级无法自动修复。现在读取本应用 Desktop Entry 的 Exec，兼容旧版可用的简单未引用路径和新版转义形式；错误命令或明确禁用的条目返回 false，让现有 updateStatus(true) 重写。文件位置及按 id 命名不变，禁用操作仍可以删除旧的坏条目，不要求路径先通过编码。

新增回归覆盖双层转义、空格/引号/反斜杠/美元符/反引号/百分号、换行键边界、旧条目迁移、禁用和重复 Exec、无效输入保留旧文件。Linux 专项测试使用项目已有 glib-sys 的真实 GKeyFile 与 g_shell_parse_argv 解析器验证只产生一个可执行参数；不启动该命令、不修改真实自动启动目录。百分号断言明确位于 field-code 展开之前，不声称该测试运行了桌面会话。等待包含本提交的 native CI 验证。

Windows Run 字符串未引用的候选尚未完成实际解析兼容性验证，因此没有把它列为确认问题，也未修改其行为。
