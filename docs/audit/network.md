# 客户端网络、Core 与异步状态审计

审计基线：`5860a5ba2ab6001869586561fccb56309db6c3e1`。审计日期：2026-11-20。关联 [客户端 PR #2](https://github.com/xydadada/vps2vpn-client/pull/2)。服务端修改及原生平台修改分别见本次审计的其他章节。

本章记录确认的问题、修复依据、验证证据以及没有完成的覆盖。当前验证快照更新至 `f5140216` 的 CI；后续补充的锁文件、UI 和新增边界测试仍需以 PR 最新检查为准。代码位置以函数名为稳定定位，行号对应本章初次生成时的修复版本；后续格式化可能移动行号。完整逐文件台账见 [network-coverage.csv](network-coverage.csv)，不能把“执行过测试”视为“逐行人工审查过”。

## 1. 架构与跨仓库数据流

订阅链接进入 `ProfilesAction` → `Profile.update/saveFile` → Core 配置校验，再保存为 profile YAML。配置应用将小型 overlay 与原订阅的大型节点、规则集合在 Go 中合并，以分块 YAML 输出降低 Flutter 与 Go 同时保留整份大对象的内存开销。Go `vps2vpnEnhance` 补充智能 fallback 组、AI 组与规则。桌面通过私有 IPC 调用 Core；Android 通过 service/gobind 调用相同 Go 方法，并可能在 Flutter 进程不运行时重新读取 `config.yaml`。

会员查询和线路状态上报由 `lib/vps2vpn/panel.dart` 发起。订阅 URL 的 token 也是会员 API 凭据，因此 URL、TLS、重定向、重试和请求生命周期必须一起审查。健康探测使用 Core 的实际节点定义和延迟接口，报告目标是订阅所属主面板；探测节点可能来自其他服务器，不能将其他服务器的证书 pin 当成主面板信任。

系统代理接管另有进程扫描、端口选择及周期恢复状态。其异步操作必须尊重用户的开关、安全模式、暂停状态及已经结束的启动请求，避免一个旧任务在用户停止后重新修改系统。

## 2. 已确认问题及修复

### N01 — 高：会员 API 沿用 HTTP 订阅协议，默认自签名部署不能工作

**位置：** `lib/vps2vpn/panel.dart:vpsApiBase/_client/fetchMember/reportLine`（约 L22、L203、L303、L330）；`core/profile_base.go:handleGetProfileOutbounds/tlsFingerprintsOf`（约 L52、L71）；`core/protocol.go:ProfileOutbounds`。

服务端为拒绝自签名证书的普通订阅客户端提供 HTTP 订阅，但 `web.Handler.route` 对 `/s/<token>/api/*` 强制 TLS。旧客户端保留 HTTP scheme，收到服务端的隐藏式 404 后误判“订阅链接已更换”；线路报告也会失败。单纯升级 HTTPS 仍无法验证自签名证书，而沿用全局“关闭证书校验”又会泄露会员凭据。

修复将会员 API 固定为 HTTPS，并保留订阅的**有效端口**，包括 HTTP 默认或显式的 80 端口。现有 `profileOutbounds` 响应新增可选 `tls-fingerprints` 字段，按原始节点的 server host 返回 HY2/TUIC 已保存的有效 SHA-256 证书 pin，验证 hex 长度并去重。没有修改已生成的数据模型，也没有改变 RPC 方法名。

客户端只取与面板 host 完全匹配的 pin。存在 pin 时创建不加载系统根的独立 `SecurityContext`，在握手中核对目标 host、port 和叶证书 DER 的 SHA-256；没有 pin 时使用普通 PKI，并明确覆盖全局宽松证书回调为拒绝。禁用重定向，避免 token 随跳转转移。错误 pin 在 HTTP 请求发送之前失败。

**回归：** `TestHandleGetProfileOutboundsReturnsOnlyExplicitCertificatePins`；`panel_test.dart` 的 host 约束与端口测试；`panel_tls_test.dart` 使用真实本地 TLS，覆盖正确 pin 的 GET/POST、错误 pin、全局关闭校验时缺少 pin 和错误 pin 均拒绝。证书和私钥是 Dart SDK 的公开测试材料，来源和 Git blob 写在 fixtures README，不是生产凭据。

**边界：** 仅 REALITY 且自签名的订阅可能没有可复用的面板 pin，会安全失败；反向代理使用不同证书或节点与面板 host 不同，也不会误信任其他节点的 pin。后续可设计单独的面板 pin 元数据与安全导入渠道。本修复不解决原有 HTTP 初次订阅导入的信任引导问题；若初始订阅已被篡改，其节点凭据和 pin 都可能不可信。没有宣称这类导入具备端到端认证。

### N02 — 高：Android 独立重启/外部 controller 重载丢失已应用的智能与 AI 路由

**位置：** `core/profile_base.go:loadConfigWithBase/syncVpsEnhancement`（约 L139、L498）；`core/vps2vpn_smart.go:vpsEnhancement/vps2vpnEnhance`（约 L110、L121）。

旧流程先写 `config.yaml`，再只增强内存中的 raw config。首次连接正确，但 Android 服务独立重载时没有 Flutter 的 overlay 规则插入位置，会失去 AI 规则；外部 controller 重载也可能与先前应用的配置不一致。

现在增强函数返回仅包含变化位置的摘要：补充 fingerprint 的节点索引、被修改的 selector、新增组数和 AI 规则的插入范围。将这些变化映射回已有 YAML 节点后再执行原来的分块、临时文件加 rename 输出。没有把全部大型代理集合重新序列化到 Dart，也没有改成完整 raw config 二次编码。用户规则仍在 AI 规则之前。

**回归：** `TestLoadConfigWithBasePersistsSmartLinesForIndependentReload` 验证已保存组、REALITY fingerprint、用户规则顺序与独立重载后的有效规则一致，并验证关闭智能线路后重新应用基线不会保留生成组。

### N03 — 中：备用服务器被按协议交错排序，故障切换过早改变出口

**位置：** `core/vps2vpn_smart.go:vps2vpnEnhance`。

旧排序只特殊处理第一台服务器，其他服务器按协议 rank 交错。某备用服务器 UDP 不可用但 REALITY 可用时，可能先跳到另一台服务器的 UDP，产生本可避免的出口变化。

改为记录服务器第一次出现的次序，先按服务器排序，再在同一服务器内按协议优先级稳定排序。此修改改变故障切换的选择顺序，不宣称提升了实测吞吐。

**回归：** `TestVps2vpnEnhanceKeepsSecondaryServersTogether`。

### N04 — 中：智能组名称冲突、selector 列表类型处理破坏有效配置

**位置：** `core/vps2vpn_smart.go:vpsNameTaken/vps2vpnEnhance`（约 L86、L121）。

旧逻辑仅检查已有组名，不检查普通 proxy 名称；生成同名组会让整个配置解析失败。selector 只断言 `[]any`，遇到程序生成的 `[]string` 时会丢弃原成员。

现在统一检查节点和组名，碰撞时跳过相应增强；同时保留两种列表类型的原成员。生成组名仍为固定的“⚡ 智能线路”和“🤖 AI 专线”，没有重命名，Dart 的 exact-name 识别合同不变。占用智能组名称的特殊订阅安全降级，不自动生成智能组或发送其健康报告。

**回归：** `TestVps2vpnEnhancePreservesStringSliceSelector`、`TestVps2vpnEnhanceDoesNotShadowProxyNames`，包括真实 mihomo 配置解析。

### N05 — 高：YAML 别名环和共享 merge DAG 可耗尽栈、CPU 或输出空间

**位置：** `core/profile_base.go:mergeProfileBase/validateAliasGraph/mappingValueSeen/inlineAliases`（约 L167、L214、L301、L466）。

`yaml.Node` 解码保留别名图，直接绕过 go-yaml 对普通对象解码的 alias-ratio 遍历保护。原有递归 merge 查找与别名展开可能在自引用图上无限递归；深层重复 merge 图会对不存在的 key 产生指数遍历。移除 anchors 后的自定义 encoder 还可能将一个很小的有效 DAG 展开成巨大输出。

新增 visited/visiting 状态检查，拒绝环；每次 key 查找对已访问 merge 节点只访问一次。对包含别名的输入，用 memoized 图估算检查展开后的节点及标量负载，预算为 `max(16 MiB, 原图估算重量 × 16)`。16 MiB 是小型普通共享设置的宽限，不是所有配置的绝对大小上限；没有别名的大型配置不受该展开预算影响。先估算后输出，不是先生成巨大内容再拒绝。

**回归：** 根 merge 环、嵌套列表/映射环、overlay 环、合法共享 anchor、24 层共享 merge DAG 的缺失/存在 key 查询、24 层指数展开拒绝。

### N06 — 中：同一 rule-set 并发更新共享临时文件，可能互相覆盖或删除

**位置：** `core/rule_set.go:handleCompileRuleSet/writeRuleSetFile`（约 L43、L95）。

旧写入使用固定 `.tmp` 名称，两个 writer 会写同一个文件、相互 rename/remove。现在同名资源通过现有更新锁拒绝重复更新，并使用独立 `CreateTemp` 文件写入后 rename，错误路径清理自己的临时文件。保留既有 0644 权限，避免破坏特权 Core 与普通宿主之间的文件读取合同。

**回归：** 阻塞 HTTP fixture 证明重复更新只下载一次并返回 `resource_updating`；16 个并发 writer 验证最终是一个完整 payload 且没有残留临时文件。测试清理等待被阻塞的 worker 完成。

### N07 — 高：系统代理接管可越过用户开关、停止请求及暂停状态

**位置：** `lib/vps2vpn/takeover.dart:vpsBeforeConnect/_startGuard/VpsSystemProxy.isOurs/quitRivals`；`lib/providers/actions/setup.dart:_start`。

原实现对端口的模糊包含判断会把 78901 或带目标端口的外国 PAC 当成本应用；按 image 名称终止进程会扩大到未观察到的实例；await 前的开关检查无法阻止停止/切换后的旧任务继续改端口、代理或启动守护。

现在仅识别启用且 endpoint 完全一致的 loopback 普通代理，PAC 单独处理；按扫描到的 PID 终止。接管和守护的每次异步边界重新核对安全模式、接管开关、连接状态、当前启动请求与 provider 存活；守护防重入、尊重暂停，并在 dispose 时取消捕获的 timer。PAC 的实际服务端口不等于 mixed-port，因此不会再按 mixed-port 强行恢复 PAC。

**回归：** portable fake process runner、精确端口/PAC/禁用状态测试；没有运行真实 taskkill、系统代理修改或 TUN 接管。已经发给操作系统的原生命令无法撤回，保护的边界是阻止后续过时动作。

### N08 — 中：健康报告未确认即视为成功，周期刷新和 timer 生命周期不正确

**位置：** `lib/vps2vpn/panel.dart:VpsLineHealth/vpsMemberProvider/vpsStartLineWatch/_checkLines`（约 L361、L419、L453、L487）。

旧状态机发送一次报告就标记 down/up，临时网络失败会永久丢掉状态变化。长探测周期可能重叠；停止或切换订阅后仍会继续报告；关闭 keepAlive 并不会主动刷新仍被界面监听的 provider。全局健康 map 还会长期保留历史 token/host。

只有收到报告成功才 acknowledge，失败会在后续周期重试；尚未确认的故障不会发出虚假恢复。计数封顶。timer 防重入，在每个 await 后核对当前状态，使用当前 provider 的 Core。会员 provider 五分钟主动 invalidate。健康状态限定在 watcher 生命周期，订阅变化时创建新状态；旧的异步回调只能访问自己的状态对象，不会污染新订阅。

**回归：** threshold、失败重试、acknowledge、恢复和未确认故障测试。完整四分钟/五分钟 provider 调度尚未通过真实应用长时间运行验证。应用重启或 watcher 重启会重置本地确认记忆，服务端仍需依赖其已有报告时效机制。

### N09 — 中：会员请求缺少响应上限、代理认证和明确重定向策略

**位置：** `lib/vps2vpn/panel.dart:_client/_responseText/_send`（约 L203、L249、L264）。

现在响应声明长度及累计 bytes 都限制为 1 MiB，body 读取具有总超时，并在 finally 强制关闭客户端。直连失败后的本机代理回退支持已有 Basic 凭据，按第一个冒号拆分以保留密码中的冒号；只给配置的 loopback host/port 和 Basic challenge，最多尝试一次。所有重定向关闭，避免重定向到登录页或别处的 404 被误判为 token 失效。

**回归：** 本地 panel 大响应、redirect、固定 Content-Length 报告、代理 407 challenge 与含冒号密码。TLS 行为另见 N01。这里没有改变订阅下载器或其他资源下载器的全局策略。

### N10 — 中：配置验证失败后含凭据的临时 profile 残留

**位置：** `lib/models/profile.dart:ProfileExtension.saveFile`（约 L201）。

文件写入、校验、复制任一阶段异常时，旧实现会留下临时节点凭据。将完整流程放入 try/finally，保证清理临时文件；成功仍更新 lastUpdateDate。

**回归：** 校验返回错误、validator 抛异常、成功保存，验证临时文件被删除且失败不覆盖现有 profile。过时下载及本地编辑的发布所有权另由 N14 修复；清理和原子发布是两项不同的保证。

### N11 — 低：Windows 复制的 PowerShell 代理设置命令无效

**位置：** `lib/common/proxy.dart`。

将混合 cmd/PowerShell 的 `set $env:all_proxy=...` 修正为合法 PowerShell 环境变量赋值。保留 POSIX 形式。

**回归：** `test/common/proxy_test.dart`。

### N12 — 高：上游 controller 重建线程竞争，配置更新可乱序或遗留监听器

**位置：** 固定子模块 `5b453f80dbcee6b3ecfb0415bcace24a48c88707` 的 `hub/route/server.go:ReCreateServer/start/startTLS/startUnix/startPipe`。维护补丁：`tool/patches/clash-meta-controller-lifecycle.patch`；回归：`core/config_test.go`。

首轮 PR 的 race detector 已实际抓到 `httpServer` 在 L164/L183 的并发读写。即使 wrapper 的 `configMu` 串行调用，`ReCreateServer` 仍然异步创建四个启动 goroutine；下次配置可能先完成，旧配置后到，或 server ownership 读写竞争。仅 sleep 或取消 race 检查不能解决。

版本绑定补丁用同一 mutex 同步完成旧 listener 关闭、新 listener 绑定及 server 赋值，仅把 Serve 循环放到 goroutine。显式保存原始 listener，保证 Serve 尚未注册到 http.Server 时 Close 也能释放端口。测试连续 12 次在同一端口变更 secret，每次立即验证新 secret 可用、错误 secret 被拒绝，最后确认禁用后不能再连接。

补丁仅针对一个固定上游文件，原 Git blob 为 `b1659cd085d278193a94ed860e3bfd9a8721d95e`，修后为 `edae0d6beff38ebf3df994da317a4fac7d6944c1`。统一应用工具验证 gitlink、子模块 HEAD 及文件原/修 hash，允许幂等的已修状态，未知漂移应拒绝；构建与 CI 接入由平台章节记录。没有偷偷改变 gitlink。更新上游时必须重新审查或移除此补丁。


### N13 — 高：Android CoreLib 的重叠 start、stop、close 可完成到过时实例

**位置：** `lib/core/lib.dart:_enqueue/start/_start/stop/restart/close/startListener/stopListener/_send`；回归 `test/core/lib_test.dart`。

旧实现用一个共享 Completer 表示连接：两个尚未完成的 start 可重复完成它；stop 或 close 早于 service.init、共享状态同步、listener 启动完成时，迟到的任务可能重新启动已经关闭的实例。初始化中途异常可能遗漏 shutdown；shutdown 失败后若过早清除所有权，下一次操作也无法重试释放。等待旧连接 gate 的 RPC 还可能在新实例启动后误发给新连接。

修复用同一异步队列串行管理实例与 listener 命令，同时在用户发出 stop、restart、close 时立即推进 generation，让正在等待异步结果的旧 start 失效。相同 generation 的并发 start 合并；每个关键 await 后检查 generation，失败或取消的初始化由 finally 清理。shutdown 失败保留“仍需清理”的状态，后续 stop 或显式 close 可以重试。RPC 捕获自己的 gate，拒绝已关闭或被替换的 gate。

Android 的 service.start 返回“已接受命令”，不是“已经建立 TUN”；原生 run-intent 仲裁器会撤销旧 token。Dart 因此也记录本实例尚未确认 running 的 listener start：close 遇到这种未完成启动时，在队列内发 stop 后再 shutdown。**已经运行、或启动前就存在的 Android VPN 仍按既有设计 detach，不因关闭 Flutter UI 无条件停止。** 这一点与原生平台章节的权限请求/撤销回归配套。

**回归：** 同代 start 合并；stop/restart 与阻塞 init/sync 交错；close 后不能重新启动；失败 shutdown 与 close 可重试；旧 gate RPC 不发送；Core listener 回包或 native start 接受迟到时取消；已运行 VPN close 只 detach；接受但还未 running 的启动 close 会撤销。未将 fake service 测试等同于 Android 真机 TUN 验证。

### N14 — 高：过时订阅下载可覆盖新配置、恢复已删除行或撤销用户编辑

**位置：** `lib/models/profile.dart:update/saveFile`；`lib/providers/actions/profiles.dart:_claimProfileWrite/_updateProfile/saveProfileFile/updateMissingProfile/putProfile/deleteProfile`；`lib/providers/actions/setup.dart:_setupConfig`；`lib/views/profiles/edit.dart:_handleConfirm`。

原先动作层仅在下载后检查行是否存在，但模型已经复制 bytes 到正式配置文件；编辑 URL、删除、并发刷新或本地替换文件时，过时内容会先落盘。初始动作还会把调用者旧 snapshot put 回数据库，覆盖新 URL 或重建已删除行。Setup 对缺失文件的自动下载绕开了动作层检查，因此不能只修“手动刷新”入口。

现在同一 profile 的下载、缺失文件修复和本地编辑共享操作 token。每次发布检查 provider 存活、token、现存行、类型、URL 和 age key；用户 put/delete 取消旧操作。过时异常不再报告到新行；当前操作错误仍向调用者传播。成功只将本次内容元数据或编辑字段合并到最新行，保留下载期间更新的选择状态。

配置先在临时文件中校验，再复制到目标目录的独立 staging 文件；最终所有权检查和单次同步 metadata rename 在同一个 Dart 事件回合内完成。大文件写入与复制保持异步。staging 与目标位于同一文件系统，不预先删除目标；替换失败时旧文件仍在，finally 清理本次 staging 和校验文件。Windows 的替换语义依赖 Dart 的 MoveFileExW 实现，仍需真机占用/权限场景验证。

编辑 URL 立即保存新来源，再延迟刷新；延迟动作按 id 读取当前行。Setup 仅在文件缺失时使用相同动作路径，并关闭递归 reapply；等待结束后重新读取当前选中 profile，避免将已经切换或删除的旧行作为下一次 setup。

**回归：** `profile_file_test.dart` 覆盖校验错误/异常、取消、旧验证最后完成、目标替换失败及临时清理；`profile_update_test.dart` 的 13 个场景覆盖新 URL、删除、重叠下载、过时/当前异常、缺失文件修复与显式刷新交错、本地/远程互相取代、保留选择以及同 URL 编辑使旧请求失效；编辑页回归验证新 URL 在延迟刷新之前入库。网络采用受控 Dio adapter，保存与 CoreController 校验路径实际执行。

### N15 — 中：桌面连接等待超时后没有取消底层订阅

**位置：** `lib/core/desktop/transport.dart:waitUntilConnected`。

对 `firstWhere` 返回的 Future 加 timeout 只结束等待者，不会取消仍在监听的 StreamSubscription；长期不连接或不断重试会留下等待者，直到以后某个连接事件到来。

将 timeout 放在筛选后的 stream 上，再取 first。超时错误令 first 取消自己的上游订阅；普通连接和关闭语义保持。已有 `test/core/desktop/transport_test.dart` 覆盖连接、超时及断开路径；没有为这一机制额外加入只检查实现文字的测试。

### N16 — 中：订阅/会员时间和大数值可使界面异常或错误显示用量

**位置：** `lib/models/profile.dart:SubscriptionInfo.formHString/fromJson/expireDate/usage`；`lib/vps2vpn/panel.dart:VpsMember/VpsAiStatus`；共用边界函数及 UI 使用者见数据层和 UI 审计章节。

任意服务器或恢复数据中的 expire 值直接乘 1000 并构造 DateTime，可能溢出或超出显示支持的年份；上传和下载计数先用 int 相加也可能溢出。会员 numeric 转换对非有限 double 调用 toInt，以及将超大 quota 乘 GiB 后 round，都会使本来可显示的账户结果失败。

数据层共用 `unixSecondsOrZero`/`dateTimeFromUnixSeconds` 在转换前验证有限性、非负性以及最高 9999 年边界，非法输入视为未知。SubscriptionInfo 的 JSON、响应头和直接 getter 都使用该边界；生成文件由真实 build_runner 更新。用量先转 double 再求和。会员 byte counter 拒绝负数/NaN/Infinity，并界定在 int64 范围；`used` 返回有限 double，`quotaBytes` 同时保护 JSON 和直接构造场景，乘法溢出或非法配额返回已有的无有效配额状态。UI 使用 getter，无需重复 round 或未经验证的日期构造。

**回归：** 数据层 `audit_data_models_test.dart`、`panel_test.dart` 的非法时间输入以及 `member_bounds_test.dart` 的 NaN/±Infinity/负数、最大整数双计数、1e100 计数、1e308 quota、直接构造场景。设置页和账户展示的 widget 回归由相关 UI 章节记录。

### N17 — 高：实际依赖扫描发现 7 个可达符号级安全公告

**位置：** `core/go.mod`、`core/go.sum`。首次证据：CI dependency-audit job `136235432718`（已读取完整 job 日志，后续可点击验证记录见下表）。“符号可达”是 govulncheck 的保守静态结果，不等于已经复现了可利用攻击。

| 模块 | 原版本 → 选择版本 | 公告与依据 |
| --- | --- | --- |
| andybalholm/brotli | 1.1.1 → 1.2.7 | [GO-2026-6888](https://pkg.go.dev/vuln/GO-2026-6888)，恶意解压数据可拒绝服务；同时核对 Go vuln 数据库和上游修复版本，不夸大成 RCE |
| klauspost/compress | 1.17.9 → 1.20.2 | [GO-2026-6865](https://pkg.go.dev/vuln/GO-2026-6865)，fse/huff0 边界 panic；扫描 trace 涉及压缩相关接口 |
| golang.org/x/net | 0.59.0 → 0.62.0 | [GO-2026-6617](https://pkg.go.dev/vuln/GO-2026-6617)、[6612](https://pkg.go.dev/vuln/GO-2026-6612)、[6611](https://pkg.go.dev/vuln/GO-2026-6611)、[6610](https://pkg.go.dev/vuln/GO-2026-6610)、[6603](https://pkg.go.dev/vuln/GO-2026-6603)：HTTP/2 并发、流控、CPU/内存和转发边界；0.62 还覆盖较新的 HTML [6860](https://pkg.go.dev/vuln/GO-2026-6860)/[6866](https://pkg.go.dev/vuln/GO-2026-6866) |
| insomniacslk/dhcp | 2025-01-09 伪版本 → 2026-07-19 c76316d4aa82 | 后续仅 module-level 的 [GO-2026-6237](https://pkg.go.dev/vuln/GO-2026-6237)：IPv4 payload 不足 UDP 头时可能产生负长度；当前扫描未导入该受影响 package，仍选择已修版本 |
| golang.org/x/crypto | 0.57.0 → 0.58.0（resolver）→ 0.58.1-0.20261009181718-2f1f834330b2 | 后续仅 module-level 的 [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932)：openpgp 已不维护；上游将其拆出根模块，本程序扫描未导入它。此升级不是宣称修好了 OpenPGP 协议 |

x/net 的 HTTP/2 trace 包括 `updateListeners → listener.PatchInboundListeners → http2.Server.ServeConn` 及连接/transport 接口；Brotli/compress 的若干 trace 穿过 interface 和 Error 方法，不能据此把每一条都解释为某个外部输入的已证明利用路径。官方 OSV、修复 commit 及目标 go.mod 均已逐项检查，所需 Go 版本不高于当前 1.27.4。

第一轮三项升级在 `f5140216` 的真实 `go mod tidy` 工作树已通过 Core tests、vet、Android static、race；govulncheck 报 **0 符号漏洞、0 导入 package 漏洞、2 module-only 公告**。其实际 resolver diff 被逐行应用回固定基线，并校验输出 Git blob 与 CI 报出的 index 一致：go.mod `3d98ca16…`、go.sum `bb406d47…`。随后两项 module-only pin 已补交，新的 go.sum 和最终扫描仍需由后续 CI 生成及确认。没有改 mihomo gitlink，没有猜测或手编 h1 校验和。

### N18 — 中：Core stderr 按 OS 分片直接解码可抛出未处理异常

**位置：** `lib/core/desktop/launcher.dart:DirectCoreLauncher.start`；回归 `test/core/desktop/launcher_test.dart`。

OS 的 byte stream 分片不保证 UTF-8 字符完整，旧代码对每个 chunk 调用 utf8.decode。包含中文节点名或诊断的合法文本在字符中间分片时会 FormatException；坏字节也会变成未处理 stream callback 异常。

改用有状态 `Utf8Decoder(allowMalformed: true)` stream，跨 chunk 拼接多字节字符，非 UTF-8 诊断只显示替代字符。回归通过 fake process 的真实 launcher 路径发送“中”的分片和 0xff，验证日志以及仍可确认停止租约；没有启动真实 Core 或修改主机网络。

## 3. 已追踪并排除的疑似问题

### Hysteria2 的 insecure=1 不等于忽略服务器 pin

追踪 `core/share_link.go` → 固定子模块 `common/convert/converter.go`：`pinSHA256` 转换到 `fingerprint`。继而 `adapter/outbound/hysteria2.go` → `component/ca/config.go` → `component/ca/fingerprint.go`：设置自定义 VerifyConnection 并计算证书 SHA-256，不匹配报错。`InsecureSkipVerify` 是为接管 PKI 验证而设置，pin 验证仍执行。没有把现有安全行为误改成开放证书校验。

### Android detachFd 的正常失败路径没有确认泄漏

逐层检查 `core/lib.go`、`core/mobile/mobile.go`、`core/tun/tun.go` 以及固定 sing-tun v0.4.29 对传入 fd 的处理：解析/初始化前失败关闭原 fd，dup 后原 fd 由 defer 关闭；后续 listener 失败由 Close 关闭 duplicate。所用配置避免了传入 fd 交接前额外的未知校验分支。此结论是指定版本和调用路径的代码证据，不替代真机 fd/网络恢复测试。

### 对平台修复的独立复核

复核 PAC 请求槽位、绝对读取期限与 helper 失败清理时，额外发现写入 `write_all` 可因部分进度重置超时，以及 stderr 线程创建 panic 发生在 child 托管之前。已反馈并复核平台修订：读写共用绝对 deadline；逐次部分写重算剩余时间；child 在任何可失败的后续动作前托管；stderr 使用可返回错误的 Builder::spawn。平台章节提供其具体测试与最终 blob。另已全文独立复核补丁应用工具的固定 gitlink/HEAD、原/修 source hash、补丁本体 hash、目录锁和幂等测试；Dio 5.11.1 的 handleResponseStream 证实取消 token 会关闭响应并取消 source，即使声明超限 body 尚未被消费。WebDAV 的跨 origin PUT 拒绝、foreign 401 不采纳 Digest 状态，以及 Android SSID best-matching physical network 的主线程单选状态也完成独立复核。

## 4. 验证证据与限制

| 验证 | 已知结果 | 适用范围 |
| --- | --- | --- |
| 环境失联前 `CGO_ENABLED=0 go test .` | `ok core 5.984s` | 早期本地工作版本；不能代表后来通过 MCP 重建的最终版本 |
| 初始 PR head `a8746045` 的 Core tests | 成功 | [job 136220373713](https://github.com/xydadada/vps2vpn-client/actions/runs/44716274559/job/136220373713) |
| 同一 job 的 Go static checks / Android static checks | 两项成功 | 精确命令以 workflow/log 为准 |
| 同一 job 的 Core race checks | **失败** | 实际发现 N12；不是环境失败，不做忽略 |
| 首轮 Flutter tooling gate | 失败后修复入口 | Node 将目录当模块导致 MODULE_NOT_FOUND，后续由平台修正 |
| 第三轮 Flutter 编译 | 发现并修正本次重建的 callback cascade 编译错误 | panel TLS arrow callback 使后续 cascade 绑定到 bool；改为 block 后后续分析为零 error/零 warning。没有把未编译的测试记为通过 |
| `946c37c9` Go / race | 全部成功 | [job 136236398990](https://github.com/xydadada/vps2vpn-client/actions/runs/44720964478/job/136236398990)：Core 5.326s，race 6.726s；patch tooling/幂等应用/vet/Android static 同时成功 |
| `f5140216` 升级依赖后的 Core / race | 实际 resolver 工作树全部成功 | [job 136238759083](https://github.com/xydadada/vps2vpn-client/actions/runs/44721647657/job/136238759083)：Core 5.378s，race 6.633s；job 红色来自待回写的 lockfile diff，非测试失败 |
| `f5140216` Go 漏洞扫描 | 0 reachable symbols，0 imported packages；2 module-only | [job 136238758716](https://github.com/xydadada/vps2vpn-client/actions/runs/44721647657/job/136238758716)，后续两项 pin 已交；该 job 的 Rust 部分另有失败，不能写作整个依赖 gate 通过 |
| 完整 Flutter / Linux / Android 构建 | 尚未全部收敛 | 已有部分测试实际运行；字体规范、锁文件、平台构建依赖等由 PR CI 暴露后修复。Linux native hook 当前日志裁剪了底层错误，未证实根因前不写为仅缺 sum |
| 新增 TLS、alias budget、controller 顺序、Core 生命周期等后续测试 | 以 PR 最新独立 CI gates 为准 | 本章不能将尚未运行的测试写为通过 |

本地执行环境后来失联，无法继续运行 Flutter、格式化器或 shell。此后从固定基线重新获取源文件，通过 GitHub MCP 创建可审查 blobs，由 PR CI 进行真实构建与测试。后续审计报告的总体验证表应记录**最新提交**的 CI 结果，不能沿用早期测试成功作为最终证明。

没有在真实 Windows/macOS/Android 主机上修改代理、终止竞争 VPN、授予系统权限或建立 TUN。没有网络吞吐、移动网络切换、电池消耗或长时间稳定性的实测基准。fallback 顺序、预算和生命周期修复的收益是逻辑/复杂度/资源边界性质，没有凭空给出性能提升百分比。

## 5. 覆盖台账与未完成范围

本子任务已完整阅读全部 **44 个自有 Go 生产源文件**，包括 Android build-tag 文件、mobile wrapper、TUN、IPC、规则、探测和持久化路径；第三方模块不包含在这个数字中。台账现有 **53 个 Dart 生产源文件**完整阅读，其中 **lib/core 的 17 个自有 Dart 文件全部全文阅读**。另有明确标为重点片段、自动化加选读、生成文件及仅 inventory 的项目；19 个 Go 测试文件主要依赖自动化执行及片段检查。独立复核平台 owned 文件也单独注明来源，没有把获取过文件等同于逐行审查。准确逐文件状态在 CSV。

其他 Dart common/providers/models/database 文件中，仍有仅完成 inventory、没有由本子任务逐行深读的文件。其他审计者可能在平台或 UI 章节覆盖它们，但不能自动将这些文件计为本章完整人工审查。Generated 文件按 generator-owned 标记，不手工改生成内容。Go module lock 数据不是依赖全量漏洞审计。

第三方只选读了 Hysteria2 转换和证书验证、sing-tun fd 所有权、controller 生命周期等具体路径。没有宣称完整审计 mihomo、sing-tun 或 prism_ui。

## 6. 后续事项

1. **最终 CI 仍必须跟随最后提交。** 不能把 `f5140216` 的已解析工作树通过，写成后续所有 UI、依赖和新增边界测试已经验证；锁文件回写、格式化和 generator diff 都需收敛到提交内容。
2. **仅 REALITY 自签名面板、不同反向代理证书、首次 HTTP 信任引导**见 N01，安全失败仍是兼容性限制；需要安全的面板 pin 分发设计。
3. 规则更新和配置原子替换仍需 Windows 真机权限、杀毒软件占用及磁盘故障场景验证；Linux 文件与 loopback 测试不覆盖全部文件系统行为。
4. `pickPort` 的探测与最终 listener bind 之间仍有操作系统级 TOCTOU，应依赖最终 bind 错误处理。
5. 动态 timer 的切换、暂停/恢复、Wi-Fi/cellular/default network 改变及后台运行需要真实应用长时间验证。已有原生命令一旦发出不能撤回；本修复阻止后续过时动作并通过 token/队列收敛状态。
6. Dart YAML 展开、脚本和 MITM 资源的过时发布与路径边界、备份恢复等由数据层/平台章节继续覆盖，不能将本章的 profile 修复自动推广为所有资源都已处理。
7. 未进行真实吞吐、长时间负载、功耗或整条互联网故障切换 benchmark；没有给出未经测量的性能提升百分比。
