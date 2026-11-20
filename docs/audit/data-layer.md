# 客户端数据层、模型与脚本发布审计

审计日期：2026-11-20。基线：[`5860a5ba2ab6001869586561fccb56309db6c3e1`](https://github.com/xydadada/vps2vpn-client/tree/5860a5ba2ab6001869586561fccb56309db6c3e1)。本文件中的源码行号均指基线；完整修复以本 PR 的 Files changed / Git Diff 为准。

## 范围与数据流

全文阅读最初分配的26个common/database/models文件，共8423行；随后完整阅读94行datetime工具、45行脚本actions和400行脚本UI，合计29个项目文件、8962行。下面逐文件列出基线Git blob，避免将取回、枚举或测试经过的文件混同于逐行阅读。Profile下载/请求/TLS/MITM/备份传输由关联审计分工覆盖；这里按调用点追踪其与模型、恢复和脚本发布的契约。

偏好文件恢复Config，旧格式经过Migration进入Drift SQLite；备份恢复把多个关联表组合在同一事务中。用户设置和数据库记录形成代理/DNS/路由模型，经过JSON或YAML交给Go核心。订阅元数据经响应头、持久化JSON和Core三种入口到达UI。远端脚本则经过下载、文件发布、provider状态更新及配置重载。因此重点检查事务中的异常归属、失效响应的发布权限、跨语言解析一致性和非受信数值进入UI的边界。

## 已确认并修复

### D01 — 全空备份在覆盖模式下没有覆盖任何数据（中）

位置：`lib/database/database.dart:503–528`。原restore只要九个输入集合全部为空就返回，没有区分isOverride。用户明确选择全覆盖并恢复一个合法空备份时，旧账户配置、脚本、规则、分组等仍保留，界面看起来恢复成功但实际状态错误。

修复仅让兼容合并模式保留空输入早退；覆盖模式仍进入既有事务，清除全部九个备份表并执行关联清理。没有把缓存和不属于备份契约的表擅自纳入删除。内存DB回归分别验证九表全空覆盖、空兼容恢复不变，以及foreign_key_check无孤儿。

### D02 — 未等待的async批构造会脱离恢复事务并留下部分变更（高，输入/编码失败触发）

位置：`lib/database/database.dart:613–628`、`lib/database/scripts.dart:56–77`。TableInfoExt.setAll声明void async却没有await，调用者无法取得其Future；scripts.setAllWithBatch返回Future但restore的同步batch回调没有等待。遍历延迟Iterable、转换行或编码JSON时发生异常，会变成未观察到的异步错误；已经收集的删除/插入仍可能提交。

固定依赖Drift2.35.1的batch本身支持FutureOr回调，会等待外层async回调；因此没有把所有async batch回调都误判为问题，也保留了原本正确的ScriptsDao.putAll。真正修复是将只负责收集SQL的setAll和setAllWithBatch设为同步void，让异常回到batch/transaction的调用栈并触发回滚。

回归用实际NativeDatabase.memory、先产生一条有效记录再抛错的Iterable、不可JSON编码的代理定义检查整份备份/脚本替换不会部分提交；同时保留正常异步批插入的异常传播测试。没有改变schemaVersion或手改生成数据库代码。

### D03 — 默认172.2*绕过了大批公网地址（中）

位置：`lib/models/config.dart:13–31`。系统代理的绕过列表按通配符匹配，不按CIDR解释。原172.2*除了意图中的172.20–29，还匹配172.2.x.x和172.200–255.x.x等公网地址，使对应请求意外直连。原生系统代理接收该列表，和TUN里的正确172.16.0.0/12是两条不同路径。

修复把172.20.*至172.29.*逐项列出，保留172.16–19、30–31。反序列化仅迁移完全相等的旧默认列表（含Windows <local>变体）；用户自定义、删减或重排过的列表保留原样。回归遍历全部256个第二段、每段两个代表地址共512个边界；检查旧默认迁移、Windows项保留和自定义策略不被覆盖。该测试验证列表语义，不冒充在每个平台启动真实系统代理的验收。

### D04 — 订阅/面板时间越界可导致RangeError、溢出日期或截断显示（中）

位置：`lib/models/profile.dart:18–61`、`lib/models/core.dart:544–551`、`lib/common/datetime.dart:64–73`，以及订阅UI直接乘1000的调用点。响应头或备份里的expire可大到乘法溢出；某些值超过Dart DateTime范围，另一些虽可构造但年份超过四位，与show的固定substring不兼容。Core直接toInt还不能处理非有限数值。

新增unixSecondsOrZero和dateTimeFromUnixSeconds作为共同边界，先验证有限、正数和可显示UTC秒上界253402300799（9999-12-31），再转换/乘法。非法值使用已有0/空日期语义，不伪造一个有效到期时间。日期转成本地时区后再检查year<=9999，防止UTC年末在正时区越到10000年。普通日期不变。

Profile的headers/JSON/getter、Core provider元数据和面板时间入口统一使用该边界；订阅组件读取安全getter。Profile与panel及组件修改由本PR其他分工共同提交，不能只合入本报告列出的core.dart而漏掉它们。回归覆盖直接构造、JSON、响应头、Core、负数、NaN/Infinity、int64极值、9999边界和保留普通时间。

### D05 — 上传+下载在整数相加时先溢出，已满配额显示为0（低，显示可靠性）

位置：`lib/models/profile.dart:56–58`。原usage先做int加法再除以total；两个接近int64上限的字段先发生溢出，clamp把负数显示为0。修复先分别转为double后相加，继续保留原0–1范围。构造器和JSON各有maxint双字段回归。该元数据只影响客户端显示，不声称修复了服务端计费或实时限额。

### D06 — DNS引用检查和重命名对URL片段的解析顺序不一致（中）

位置：`lib/models/references.dart:35–85`。固定mihomo子模块5b453f80dbcee6b3ecfb0415bcace24a48c88707的parseNameServer使用url.Parse解码整个fragment，再按&分段、按第一个=解析参数，最后一个无=片段才是dialer。Dart查引用遵循该顺序，旧rename却先按原始&拆分。例1.1.1.1#Old%26ecs%3D1.2.3.4%2F24能识别Old，却无法随Old改名，留下旧DNS dialer引用。

修复让rename按同一解码顺序定位最后一个实际dialer；没有匹配时保留原字符串，重新输出时保护百分号、空格、逗号和分号，避免改变policy多服务器拆分。三个回归覆盖编码分隔符、只改最后裸参数及参数内容保留。没有据此宣称已复现DNS泄漏；确认的影响是改名后的引用失效。

另一个疑点已排除：proxyNamesInUse没有单独枚举emptyFallback，但现行校验只允许内建代理或已经出现在组成员里的data.namedProxies；合法非内建fallback已包含在组成员引用中，未作无收益修改。

### D07 — 旧脚本下载可覆盖新编辑/复活删除记录，直接写目标文件也不完整（高/中）

位置：`lib/models/common.dart:801–813`、`lib/providers/actions/scripts.dart:8–37`、`lib/views/config/scripts.dart:159–174`。原Script.save直接截断最终.js文件后写入；中断/写入失败可破坏旧内容。actions在await下载后直接put旧Script快照，删除、改URL或新一轮更新完成后，旧响应仍能恢复旧记录/内容，并在脚本被当前配置引用时触发重载。

修复：下载结果先写同文件系统的独立暂存目录，flush完成后重新检查发布权限，以同步rename把最后检查与发布放在同一个isolate轮次，不预删旧文件。actions为每个ID保存更新令牌；显式put/delete使旧令牌失效；发布需owner存活、记录存在、URL仍一致且令牌最新。普通刷新读取当前存储行，成功后只合并新的lastUpdateTime，保留最新label/order。过期响应/错误不影响后继操作，仍有效操作的失败继续抛给调用者。

URL编辑原来仅把copyWith(new URL)传入下载；它现在先保存用户明确的新URL，再刷新，与Profile编辑一致。下载失败保留新URL供重试，但旧脚本字节仍完好。新导入/本地保存仍可创建记录，没有把更新守卫误套成禁止创建。

九个受控Future回归经过实际Dio下载路径、模型保存与文件IO，验证最新URL/元数据、删除后不复活文件、改源/同源双刷新乱序、有效/失效错误、owner销毁、暂存后撤销和发布失败清理。该机制是单进程发布顺序保护，不是文件+数据库的跨进程/断电原子事务，也不声称验证了脚本内容的可信性。

### D08 — 设置页在离页后读取 WidgetRef，异步按钮错误未被收集（中）

位置：`lib/vps2vpn/mine.dart:28–58, 90–124, 388–396, 577–591`。剪贴板读取跨越 await 后未先检查 mounted，页面已经移除时仍会 setState/ref.read；刷新全部和单条订阅的 VoidCallback 丢弃失败 Future。设置页还重复使用未经保护的 expire×1000 和 int 上传+下载。

修复在读取剪贴板后先确认页面存活，使用已有 globalState.safeRun 接收剪贴板、刷新、文件导入及复制命令的异常。订阅卡使用共同 expireDate/usage 边界并以 double 求和显示流量。五项 widget 回归覆盖空/有效迟到 Clipboard 响应、平台拒绝读取、两个刷新入口和极端日期/流量；没有执行真实导入、系统代理或退出操作。

### D09 — YAML alias 图在转普通 Map/List 时指数复制（高，配置导入资源耗尽）

位置：`lib/common/yaml.dart:21–47`；live 调用为 `lib/providers/state/custom_import.dart:78–89`。固定 yaml3.1.4 已拒绝自引用集合，但合法非循环 alias 返回共享 YamlNode；项目转换器会在每次引用及每个 merge 源重新递归复制，几十层双引用的小文档便可产生指数级工作和内存。仅限制下载字节不能防止该展开。

修复先保留 YamlNode 图，以 identity 集合与迭代遍历计算唯一输入权重，再对含 alias 的 DAG 进行 memoized 展开估算。预算为 max(16 MiB, 唯一图估算体积×16)，饱和加法避免恶意图计数溢出；自身递归转换前限制深度256。没有给无 alias 大文档设固定条数/大小上限，普通 alias 仍产生独立副本，merge 优先级保持原样。权重是工程估算，不是 Dart VM 精确内存计量。

九项回归包含 list/merge 指数图、正常副本隔离、深链、上游循环拒绝、MITM格式检测与实际自定义配置导入错误映射，以及无 alias 超8MiB标量。上游扫描器本身及其他直接使用 loadYaml 的入口并未因此完成统一输入治理。MITM 启用受 rsFeature=false 限制，而自定义配置导入无需该开关。

### D10 — 持久化选项形成自环/双环时代理状态递归不终止（中）

位置：`lib/common/compute.dart:107–129`；`lib/providers/state/proxies.dart:224–252`。selectedMap 来自当前 Profile 的持久状态。Selector 已检查成员，但 URLTest/Fallback 在 now 尚空时会直接采用旧 selectedMap；非成员自选能让递归状态解析不断返回同一组。未知成员集合、异常组状态和很深的有效链也不能依赖 Core 的正常图校验来保证 Dart 调用栈安全。

修复使用迭代+visited，存在成员快照时确认下一跳归属。非法选择或环返回既有空 proxyName 约定，现行测速调度会跳过空目标；有效链仍保留最终节点、group 标记和对应 testUrl。沿用现有按列表缓存的组索引，每次沿链至多访问一个组一次，没有每层重建索引。四项回归覆盖 computed 旧选项、自环、双环和一万层有效链。

### D11 — Protobuf长度回绕与gRPC解压预算复用（中，当前MITM能力未启用）

位置：`lib/common/mitm_protobuf.dart:68–117,129–192`。原varint读到第十字节仍接受超过uint64的高位；长度即使仍为正数，bodyStart+length也可能回绕为负数并交给sublistView抛RangeError。gRPC累计计数只接纳成功解码的帧，超过上限后被丢弃的帧可让后续帧重复解压到8MiB边界。

修复限制第十字节有效位，先以剩余长度比较再相加；解压器返回实际已处理的输出字节，即使该帧最后失败/超限也消耗body预算。预算耗尽后不再为后续压缩帧创建解压器，而保留原始字节的hex及上限说明。合法uint64最大值、普通gRPC帧和trailer行为保留；截断模式仍可返回已完成字段。

新增四个整数/截断边界回归，并调整原有gzip测试：旧测试明确期望超限失败帧之后仍能重新解压小帧，现在按body累计预算显示后续压缩帧的原始内容。这是有意收紧解码工作边界，不能把它解释成公网VPN流量已完成MITM验收。rsFeature=false及Core stub的范围限制仍成立，也不声称对每种损坏zlib输入的CPU成本作了形式证明。

## 验证与限制

本分工目前新增48个专项case：test/database/audit_restore_test.dart 6项；test/models/audit_data_models_test.dart 8项；test/models/references_test.dart追加3项；test/providers/script_update_test.dart 9项；test/vps2vpn/mine_audit_test.dart 5项；test/common/audit_yaml_test.dart 9项；test/common/audit_compute_test.dart 4项；test/common/audit_protobuf_test.dart 4项，并修正一个既有gRPC预算测试的期望。已有相关测试也按PR CI运行。测试代码已上传MCP，执行结果应以本PR最后代码提交对应的Actions为准；编写报告时这批最新Dart代码尚待合并后的统一代码生成与CI，不把其他提交通过数算作本次验证。

建议在锁定依赖和真实代码生成后执行：

```sh
dart run build_runner build --delete-conflicting-outputs
flutter test test/database/audit_restore_test.dart test/models/audit_data_models_test.dart test/models/references_test.dart test/providers/script_update_test.dart test/vps2vpn/mine_audit_test.dart test/common/audit_yaml_test.dart test/common/audit_compute_test.dart test/common/audit_protobuf_test.dart test/common/mitm_body_test.dart
flutter test
flutter analyze
```

所有生成的freezed/json/Drift/Riverpod文件均由真实build_runner生成，未手工伪造生成输出。最终CI汇总应列具体head SHA、jobs及失败修复记录。受控下载adapter用于精确安排完成顺序，不是公网吞吐实验；系统代理绕过仍需Windows/macOS/Linux真实环境验收；Windows文件替换、正负时区、进程崩溃及并发备份恢复等系统组合未在此报告中宣称完成。

## 逐文件阅读证据

| 文件 | 基线行数 | 基线Git blob SHA | 阅读重点 |
| --- | ---: | --- | --- |
| `lib/common/app_data.dart` | 20 | `1b500da8b0dfc2520c5d931bbc38c0916d334d5e` | 清空偏好、关闭/删除数据库、配置目录；检查异常路径，未调用真实清空。 |
| `lib/common/migration.dart` | 253 | `ec61fb80837e870d900530634b7b0a15a4e578f1` | 旧偏好转为DB、迁移版本、枚举/格式兼容；确认空迁移默认isOverride=false，不把它误报为全库清空。 |
| `lib/common/preferences.dart` | 188 | `3c9d9728dc3a7798a2a420e8af807e8d4454e1de` | 配置读取、损坏配置报告、存储接口与默认值；保留已有异常恢复策略。 |
| `lib/common/preferences_store.dart` | 111 | `79ee0c88b4803ac144829b8d42363f3095416bd4` | 文件偏好的加载、串行写入、临时文件与内存副本；检查失败返回契约。 |
| `lib/common/cache.dart` | 49 | `2ccf9e6fbe5abaf2639f41755428d667aaa653d0` | 磁盘缓存命中/刷新、StreamController、失败处理；图标资源字节边界由主审修复。 |
| `lib/common/converter.dart` | 146 | `4d73be531b5cdfc610263554717f54d09b9569b6` | JSON/YAML转换、按字段恢复损坏数据、集合容错；未无证据改变兼容策略。 |
| `lib/common/yaml_writer.dart` | 223 | `6c1f091d3c9a4f5b7fd135cbc3853f0583c7c85f` | YAML标量、转义、多行、键与数组输出；不等同于第三方YAML解析器审计。 |
| `lib/common/input_entries.dart` | 313 | `015f30b8bbe2dea9f25e71cf916237633a5e2e2c` | UI输入拆分、映射/列表保留与序列化边界；不是持久化数据的统一安全校验。 |
| `lib/common/input_limits.dart` | 52 | `0dbfb6bcf676f104cf28a7bf445958d049b30ab2` | 长度、数字/策略名输入限制；仅UI层限制，不能替代模型边界。 |
| `lib/database/database.dart` | 721 | `c629c26d1ef59e4bd0ca4e592167ef62a2117876` | 模式1–26迁移、关联清理、事务恢复、批操作；D01/D02。 |
| `lib/database/clash_providers.dart` | 109 | `e8c947d7cb93038a54d36341493bd09724c4799a` | provider元数据、URL变更缓存键、排序与批恢复。 |
| `lib/database/custom_proxies.dart` | 86 | `fbe097ecb55e98bd2458ee5c72762d1aeb5892cd` | 原始代理映射、空选项、批更新与排序；公用setAll修复覆盖其异常传播。 |
| `lib/database/dialers.dart` | 122 | `730785ba985667d5b7943b436bfa2a85c435119f` | profile/proxy外键、级联删除、替换与改名；公用setAll修复覆盖preDelete分支。 |
| `lib/database/icons.dart` | 149 | `8ed2a458ea60f0eec850ecae6c5631b47707ffaa` | 图标记录/图标集、访问时刻、容量与淘汰；HTTP边界另见主审文档。 |
| `lib/database/ip_qualities.dart` | 50 | `acba917969b8af0ae78e7df3bfdd163024fee2cc` | IP质量缓存、时间窗口、未来/过期记录过滤。 |
| `lib/database/scripts.dart` | 102 | `48d53cf57820b4c1846640ac075e0a0a158177e3` | 脚本读写、批量替换与模型转换；D02。 |
| `lib/models/clash_config.dart` | 2429 | `2a8cad38bec7beb5123e56354423c7164579ca89` | 代理/分组/规则、DNS/TUN/NTP/MITM覆盖、旧格式迁移、配置生成；逐行阅读2429行，未声称逐个协议字段都做真核心动态验证。 |
| `lib/models/config.dart` | 629 | `a7ab4db88cf3b808c230f70fa814d809a4264922` | 默认系统代理绕过、平台默认、设置兼容和配置恢复；D03。 |
| `lib/models/core.dart` | 584 | `40990e6a3fba958e87a01049d089c25874b0ca06` | 核心JSON契约、有效VPN参数、状态/统计与provider订阅元数据；D04。 |
| `lib/models/app.dart` | 45 | `38813a39fdd1107f9f1e92cee5f96e01baf10edd` | 应用基础数据模型与序列化。 |
| `lib/models/common.dart` | 1087 | `f3c1ae1098612542a640e311151465ca2b32f582` | 连接/日志/DNS模型、WebDAV密码序列化、Script/图标/provider模型；脚本发布修复D07；密码混淆不当作加密边界。 |
| `lib/models/state.dart` | 269 | `ffb1b335ac64c31df12e9202d4a93b1f6ed7c149` | 应用状态默认值、选择/历史与派生状态。 |
| `lib/models/references.dart` | 356 | `e86839bc77cdfac94c92b68918208dd66d61c0d5` | 代理、规则集、DNS/NTP引用和重命名；固定上游对照确认D06。 |
| `lib/models/record_filter.dart` | 130 | `7553247397bc907b122b3704a9fba8007068dea3` | 过滤键、查询和分组状态；检查未知字段兼容。 |
| `lib/models/ip_quality.dart` | 37 | `43722e9f6ffd6d83d48a5ed7763cf4441002cb45` | 质量结果与缓存时间字段。 |
| `lib/models/capabilities.dart` | 163 | `a4fbbf50544a59773dd0a43dec30acb527b35e94` | 能力字段、版本兼容和默认行为；能力展示不是网络信任边界。 |
| `lib/common/datetime.dart` | 94 | `003fcaf89836b149ebcd47cd0ae6e547e552fc80` | 秒/毫秒范围、四位年份显示；新增共享时间入口D04。 |
| `lib/providers/actions/scripts.dart` | 45 | `1e1caa3b41585f69640eb2c10ce9fa9851c62e7e` | 下载、删除、编辑、状态发布与更新指示器；D07。 |
| `lib/views/config/scripts.dart` | 400 | `2a81395dbc0469831b4200e80d2051c1ff081c38` | 创建/导入/保存/URL编辑/删除全流程；URL编辑改为先保存显式意图，D07。 |

### 后续全文扩审（当前检查点）

下列文件按 PR head f514021658fcbefba75a5392b04f609db7b71cf4 完整读取。行数与 blob 指该检查点，不冒充基线；其中其他分工也完整检查的文件在总表应去重。此表目前 24 个文件、7271 行；后续新增阅读会继续补入。

| 文件 | 已读版本行数 | 已读Git blob SHA |
| --- | ---: | --- |
| `lib/vps2vpn/mine.dart` | 715 | `4bb07f12fbce06a98067dccf47fb99966e36810e` |
| `lib/common/num.dart` | 67 | `e78b97d70b1879b3cfeed64d06536c01c8bc06eb` |
| `lib/common/yaml.dart` | 48 | `8b7688578debe09662beb805990fd3634b87b40f` |
| `lib/common/compute.dart` | 163 | `c65f984b1cef92a636fdacfa50be25536e0613a7` |
| `lib/common/mitm_module.dart` | 3026 | `49611cec4c916936cf6a870b748e41ad37a6296f` |
| `lib/providers/mitm.dart` | 533 | `e215270c8fb66e1f62d201877c04a6cda78baac2` |
| `lib/providers/state/proxies.dart` | 275 | `79555c894ca81b65e3a15dab628cb3f3beb95c89` |
| `lib/providers/core.dart` | 7 | `16f730b3ec7185342a47772585e0d126d89dc0d9` |
| `lib/common/protocol.dart` | 111 | `4b6d8c2ad1cda5ee582c465c5afd5af1fa3a1fa9` |
| `lib/common/provider_reader.dart` | 3 | `efd13a21fb943500789e31bfc5fdd70d84e32ff6` |
| `lib/common/task_pool.dart` | 36 | `e87c8f51aaecf869ced8b47b625d41f5f3cf05a4` |
| `lib/common/lock.dart` | 48 | `9fccd0bff12ab2cf9bec892f3c7e3a33aaeac220` |
| `lib/common/javascript.dart` | 84 | `bb122dd9a810bfd89f9d71d1c12e8fc8da1e5f0d` |
| `lib/common/mitm_body.dart` | 309 | `f5da486c87ec040738b3f4a04c7f3efff449ed1c` |
| `lib/common/mitm_protobuf.dart` | 271 | `187917ccd379d37ae8cf79d83f1ed8f22e692f9f` |
| `lib/common/mitm_network.dart` | 282 | `8d48231429e2a947a86eb0c3346d0ce4b39e10b1` |
| `lib/common/mitm_requirement.dart` | 189 | `c1bc964daf418a6e23af41e61eba038b58d53e35` |
| `lib/common/app_ports.dart` | 48 | `bc6029bcecc2e9001109e91747342b2d9e53a1f0` |
| `lib/common/boot_guard.dart` | 106 | `dae7cb0c5bb484f725f8cd243b4f8b747eb33293` |
| `lib/common/boot_record.dart` | 224 | `66baeba5c508a7abc3da7f9be2a83e03f69856d1` |
| `lib/common/cidr.dart` | 186 | `715b7b14f499a13db0d7b99dc71c4844c3dc96ee` |
| `lib/common/function.dart` | 161 | `4e9cf51b47be1c0b9377b15e35e4c19170d83a5a` |
| `lib/common/future.dart` | 115 | `dda204940480eda05c4ce13c03d467e998a21352` |
| `lib/common/indexing.dart` | 264 | `72c052eb29caec7ef13e2039eb1ab641cb28a439` |

MITM module 全文覆盖了 Surge/Loon/Quantumult X/Stash 解析、参数替换、脚本/资源映射、rule provider、网络覆盖、requirement 和跨模块合并。其自身资源basename约束来自平台分工，继续保留；本次确认的深层展开问题在共同 YAML 边界修复。MITM export/trust、请求与WebDAV等由平台分工全文覆盖，此处不把仅取回的副本计作全文阅读。
### 交叉追踪与独立复核范围

- lib/models/profile.dart在本分工只阅读SubscriptionInfo及调用点，全文审阅归网络分工；lib/providers/state/custom.dart和actions/profiles.dart只追踪DNS/emptyFallback引用约束；lib/providers/database.dart只追踪Scripts状态写入契约。它们虽取回了完整内容，不能因此在本分工标全文阅读。
- 原有test/models/references_test.dart已全文阅读并新增回归。DAO coverage/generated_contract等大测试只读相关段，实际运行由统一CI完成。新增专项测试文件均全文编写复核；原有 test/common/compute_test.dart 与 test/common/mitm_body_test.dart 也已全文阅读。
- 独立全文复核主审新增lib/common/icon_file_service.dart（blob d6c752e487beffd150a93880bb7f001fe0c91a46）及修改后lib/widgets/icon.dart（blob e1b1742837e7c838ab6adb960c2226bb4cf1128b），未另改这两个文件。确认有限响应读取、截止时间、客户端关闭、旧缓存读取、缓存字节/条目数边界，不把单响应限制解释成全进程并行解码内存上界。
- 固定Drift/mihomo上游只阅读与异常/协议契约有关的实现，未审计整个第三方依赖。

## 未改动的边界与后续工作

现有decodeSalvaging、readable和部分JSON转换器选择保留可读字段、跳过不可读行。此策略可能隐藏损坏数据，但需要与恢复体验、日志、升级兼容共同设计，未把所有fallback都当作漏洞删除。损坏大集合逐项恢复的最坏复杂度、备份恢复过程中其他异步操作的整体撤销、平台系统代理的真实运行行为、跨进程文件/DB一致性等仍需要专项场景验证。WebDAV密码当前是可逆混淆，源码已明确它不是防同用户读取或逆向的安全边界；没有把它描述为安全加密。

## 依据

- [固定Drift2.35.1批回调与事务入口](https://github.com/simolus3/drift/blob/drift-2.35.1/drift/lib/src/runtime/api/connection_user.dart)
- [固定Drift批收集时同步遍历输入](https://github.com/simolus3/drift/blob/drift-2.35.1/drift/lib/src/runtime/api/batch.dart)
- [Drift事务语义](https://drift.simonbinder.eu/dart_api/transactions/)
- [Microsoft WinINet绕过列表与通配符](https://learn.microsoft.com/en-us/windows/win32/wininet/enabling-internet-functionality)
- [Dart DateTime有效范围](https://api.dart.dev/dart-core/DateTime-class.html)
- [固定mihomo DNS解析实现](https://github.com/chen08209/Clash.Meta/blob/5b453f80dbcee6b3ecfb0415bcace24a48c88707/config/config.go)

补充协议依据：[yaml3.1.4 Loader alias identity/循环拒绝](https://github.com/dart-lang/tools/blob/yaml-v3.1.4/pkgs/yaml/lib/src/loader.dart)、[YamlNode节点视图](https://github.com/dart-lang/tools/blob/yaml-v3.1.4/pkgs/yaml/lib/src/yaml_node.dart)、[Protobuf wire encoding](https://protobuf.dev/programming-guides/encoding/)、[Dart RawZLibFilter](https://api.dart.dev/dart-io/RawZLibFilter-class.html)。
