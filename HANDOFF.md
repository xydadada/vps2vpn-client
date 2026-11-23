# vps2vpn 客户端交接文档

更新时间：2026-11-23。仓库：`xydadada/vps2vpn-client`，主分支 `vps2vpn`（上游 FlClash 的 `main` 不用来发布）。

## 1. 当前版本

| 项目 | 值 |
|---|---|
| 最新正式版（Latest） | **v1.0.27**，commit `3fe07f6dc4cf9fed2ad97363222e91ccd7458a3a`（服务端已核对 SHA256、`.sig` 和 tag 指向；测试服务器 clientsync 已同步到 1.0.27） |
| 上一版 | v1.0.26，commit `b8ba4d27f3961f84bb26a27fd1116bf6af497edc`（服务端已核对） |
| `vps2vpn` 分支头 | `3fe07f6d` 之后只有 CI 和文档提交（默认标签改 v1.0.27、安卓 GPU 模式输入） |
| 安卓 | 还没有正式 APK。矩阵运行 45115715910：API 31/33/34/35 全部同样失败（安装、启动、导入订阅 PASS，"VPN is up" FAIL，虚拟机冻住），见第 5 节末尾。运行 45118179316（publish=true）生成预发布 `test-android-1.0.26`，只当预发布，不转正 |

| 版本 | 内容 | 构建 | 升级测试 | 共存测试 | 源码检查 |
|---|---|---|---|---|---|
| 1.0.27 | 系统代理断开时还原原设置（88c8c522）+ 核心崩溃后自动拉起（3 次/5 分钟）+ harsh 脚本修复 | 45142883757 | 45144760127，66 PASS（含从 v1.0.26 升级） | 45144767934，94 PASS | 45142874060 |
| 1.0.26 | C-32 + 第 9 份审计 C9-01..05 + 安卓脚本修复 | 45116238235 | 45117446837，33 PASS | 45117687563，47 PASS（含 TUN） | 45116444649 |
| 1.0.25 | 第 7 份审计 C8-01/03/04/05/06/09 | 45090912918 | 45092090703，33 PASS | 45092300279，47 PASS（含 TUN） | 45090911216 |
| 1.0.24 | C-17 管道权限 + 免责声明勾选 | 45089233539 | 45090333919，33 PASS | 45090550847，47 PASS（含 TUN） | 45089232082 |
| 1.0.23 | 审计第 6 份修复 | 45034671081 | 45035666794，33 PASS | 45035866531，42 PASS | 45034665815 |

每个版本的 SHA256、`.sig`（用服务端校验器验过）、PE 加载标志（19 个文件 0 问题）都通过了。

## 2. 构建、签名、发布流程（Windows）

1. **改版本号**：`pubspec.yaml` 里 `version: 1.0.N+YYYYMMDDNN`，单独一个提交 `chore: version 1.0.N`。
2. **推送前**：`git fetch private`，确认 `private/vps2vpn` 没有别人新推的提交，再推。每次推送都会触发 `verify.yaml`（源码检查：analyze、全部测试、lint 测试，Linux 和 Windows 上的 Rust 测试）。**同一分支再推会取消正在跑的那次**，所以发布用的那次源码检查跑完之前不要往 `vps2vpn` 推。`vps2vpn.yaml`、`android.yaml`、`e2e.yaml`、`coexist.yaml` 都只能手动触发，推送不会取消它们。
3. **构建并发预发布**：
   ```
   gh workflow run vps2vpn.yaml --ref vps2vpn -f publish=true
   ```
   会生成预发布 `test-<版本>`，带安装包、便携 zip、每个文件的 `.sig`、`SHA256SUMS.txt`。签名私钥只在 GitHub secret `UPDATE_SIGNING_KEY` 里用。构建日志里要看到 `Core controller patch applied and verified`（Mihomo 补丁，见第 9 节 C8-02）。
4. **独立校验**（下载到一个新的空目录，Python 一律用 `-I`）：
   - `sha256sum -c SHA256SUMS.txt`
   - 用服务端仓库的 `vps2vpn.clientsync.signature_ok(name, sha256, size, sig)` 逐个验 `.exe` / `.zip` 的 `.sig`，只读服务端代码，`python -I -B`。
   - `python -I -B tool/check_load_flags.py <便携 zip>`，要 0 个问题。
5. **安装器 + 升级测试**：
   ```
   gh workflow run e2e.yaml --ref vps2vpn -f tag=test-<新版本> -f from=v<上一版>
   ```
   要求全部 PASS（目前 33 项）。
6. **共存测试**（和 FlClash、Clash Verge 共存、接管、重启、TUN、两次同时启动、卸载）：
   ```
   gh workflow run coexist.yaml --ref vps2vpn -f tag=test-<新版本> -f rounds=3
   ```
   要求没有 FAIL（目前 47 项）。
7. **转正**：全部通过后
   ```
   gh release edit test-<版本> --tag v<版本> --target <commit> --title v<版本> --prerelease=false --latest --notes-file <说明文件>
   ```
   说明写中英文两段，面向用户写，不写内部编号。转正后把 `e2e.yaml`、`coexist.yaml` 里 `tag` 的默认值改成新版本。
8. **告诉服务端**：版本号、commit、各次运行号，服务端会自己再验一次签名。

每次发布的检查清单：源码检查通过 → SHA256 对 → 所有 `.sig` 用服务端校验器验过 → 加载标志 0 问题 → 升级测试全过 → 共存测试全过（含 TUN）→ 发布资产里每个文件都有 `.sig`。

安装包不做代码签名（用户决定不买证书），只有更新签名 `.sig`。

## 3. 分支

| 分支 | 状态 |
|---|---|
| `c17-pipe-acl` | 已并入 1.0.24，可以删 |
| `disclaimer-checkbox-wip` | 半成品，最终做法不同（见第 4 节），已由 1.0.24 的 `a75a8410` 取代，可以删 |
| `audit7` | 已并入 1.0.25，可以删 |
| `c32-autostart-hidden` | 已 cherry-pick 进 `vps2vpn`（`79da5f13`），可以删 |
| `android-ci` | 早期安卓 CI 工作分支，内容都已进 `vps2vpn`，可以删 |
| `audit/*` 一大批 | 以前的审计补丁分支，已处理或判定不适用，不要直接合 |

没有 stash，没有未推送的改动。

## 4. 免责声明（1.0.24 起）

- 做法：免责声明页全文可滚动，底部固定栏里有"我已阅读并理解此声明"勾选框，勾上后"同意"才能点。不再弹确认框，也不用输入原文。
- 为什么不用确认框：确认框宽度固定，在 400×800 的手机上，勾选框落在对话框可滚动区域之外（可见到 y=636，勾选框在 661–771），320×568 上完全看不到，点不动。放进底部固定栏后任何尺寸都看得到。测试 `test/common/dialog_test.dart` 覆盖 400×800 和 320×568。
- 已同意过的用户不会再被问（仍用 `acceptedDisclaimerVersion`）。
- 旧的 `disclaimerAcknowledgeTitle` / `disclaimerAcknowledgeTip` 文案现在没用到了，留在 arb 里，可以以后清掉。

## 5. 安卓

- 工作流：`android.yaml`，`build` 任务出正式签名 APK（secrets `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS`；缺签名直接失败），带 `publish=true` 时同时生成 `.sig` 并发预发布 `test-android-<版本>`；`emulator` 任务在模拟器上跑 `.github/scripts/android-e2e.sh`。签名证书 SHA-256：`b3836548bd44b5b20c84461b95bd71c6030af3709cdad107df1cd753c7e64505`。
- 第五、六轮失败的真正原因：Flutter 按钮在 uiautomator 里是 `text=""` + `content-desc="Agree"`，脚本拼成 `" Agree"`，`^...$` 精确匹配一直不中，"同意"从来没点到。已修（`c39238d0`）：去掉空字段；没点到时把界面树存成 `missed-*.xml` 放进 `android-e2e` artifact。
- 第七轮：运行 45092375494，代码 `c39238d0`（应用代码和 Windows 1.0.25 一样），带 `publish=true`。交接时还在构建，结果没看。接手后：
  1. `gh run view 45092375494 -R xydadada/vps2vpn-client` 看 `emulator` 任务是否全部 PASS（日志里搜 `PASS ` / `FAIL `）。
  2. 失败就下载 `android-e2e` artifact 到新的空目录，看截图和 `missed-*.xml`，修脚本或应用后重跑 `gh workflow run android.yaml --ref vps2vpn -f publish=true`。
  3. 通过后，独立验 `vps2vpn-1.0.25-android-universal.apk` 的 SHA256 和 `.sig`（同第 2 节第 4 步），再把预发布 `test-android-1.0.25` 改成正式发布（不设 Latest，Latest 留给 Windows 版）。
  4. 把确切文件名 `vps2vpn-1.0.25-android-universal.apk` 告诉服务端，服务端会配置 `files.android` 并核对签名。

### 安卓模拟器失败诊断（2026-11-23）

- 2026-11-23 续查（本节结论以这里为准）：
  - 空隧道探针（`android-probe.yaml`，同样形状的 TUN、只丢包）**不冻**；只有我们的应用冻。冻住瞬间 tun0 只有 4 个包，不是流量风暴。
  - 换栈全部无效：mips（默认）、system、gvisor 都冻（运行 45143299823、45143291413；gvisor 里唯一"没冻"的那台是系统弹了 Pixel Launcher 无响应，根本没导入没连接，不算）。改 MTU 1500、地址段 172.19 也无效（45122518784、45122513982）。
  - 冻前一刻应用的 Flutter 渲染线程 `1.raster` 占 55% CPU，qemu 宿主侧约 200%。怀疑是连接后的界面动画 + 模拟器 `swiftshader_indirect` 宿主侧 GPU 模拟的问题。`android.yaml` 加了 `gpus` 输入，运行 45146767797 试 `swangle_indirect` 和 `guest`。
  - 若换 GPU 模式能过：问题在模拟器图形，不在应用网络，可以把 CI 默认 GPU 改掉，APK 可考虑转正（仍建议真机确认）。若仍冻：再查连接后界面（如关动画）或应用其它部分。

- 现象（API 34，google_apis，x86_64）：安装、启动、导入订阅都 PASS；点连接后 VPN 确实建立（上游代理日志能看到手机流量），约 1 秒后 logcat 和内核输出（`-show-kernel`）同时停止，没有任何 panic/Oops；adb 在约 30 秒后掉线，之后 qemu 进程退出。宿主机内存充足（约 11 GB 空闲），dmesg 无异常。
- 判断：虚拟机整个冻住（不是应用崩溃、不是内存不足），可能是这个镜像/模拟器与 TUN 流量的问题，也可能是应用 TUN 设置触发的。
- 矩阵结果（运行 45115715910）：API 31/33/34/35 四个都一样，安装、启动、导入订阅 PASS，"round 1: the VPN is up" FAIL，之后卸载也 FAIL（adb 已掉线）。换 API 没用。
- 下一步：先在真手机上装 `test-android-1.0.26` 的 APK 看能不能用。若真机正常，问题就在模拟器网络，可以考虑转正；若真机也有问题，再查应用的 TUN 栈/MTU（`android/service/.../VpnService.kt`），例如换 stack 试。
- 诊断产物：`host-watch.log`（每 3 秒 adb/qemu/内存）、`host-report.txt`、`logcat.txt`。

## 6. TUN 对照测试（C-17 用过的）

- `coexist.yaml` 的 TUN 阶段：应用配置改成开 TUN、关系统代理，检查 120 秒内 Core 以 SYSTEM 运行（Helper 拉起）、Helper 服务 Running、名字含 Wintun/Meta/vps2vpn 的网卡 Up，然后 `curl --noproxy '*'` 拿到 204 且上游代理日志看到这次请求。订阅规则里有 `PROCESS-NAME,python.exe,DIRECT`，否则 CI 上游代理自己的流量会被 TUN 绕回去。
- 基线：v1.0.23（运行 45037493461）通过；C-17 之后 1.0.24、1.0.25 都通过。以后改管道、Helper、TUN 相关代码时，TUN 阶段失败就说明改坏了。
- 不开 TUN 时 Core 以当前用户（CI 上是 runneradmin）运行，这是正常的；安装器不注册 Helper，只有用户打开 TUN 时应用才请求管理员权限注册。

## 7. 待办（按优先级）

1. **安卓正式 APK**：模拟器在四个 API 上都是连上 VPN 约 1 秒后整机冻住（第 5 节）。要么在真手机上确认 `test-android-1.0.26` 的 APK 能用，要么继续查 TUN 栈/MTU。确认之前不转正，服务端也先别配 `files.android`。
2. **C-12**（= C8-07 前半）：macOS 网络/唤醒监听是桩实现。CI 没有 macOS，也不发 macOS 版，暂缓。
3. 清理：删掉第 3 节里标"可以删"的分支；清掉没用的 arb 文案（`disclaimerAcknowledgeTitle`、`disclaimerAcknowledgeTip`）。

## 8. 不能做的事

- **不在本机安装或运行发布版客户端**。它会接管代理软件、关掉用户自己的 FlClash。本机只构建；升级、共存测试只在 GitHub Actions 里跑。
- **不轮换、不重新生成更新签名密钥**，也不提交、打印、移动私钥文件（更新签名私钥和安卓 keystore 及其密码文件都在本机密钥目录里，只通过 GitHub secrets 使用）。
- **提交里不写 `Co-Authored-By`**，提交信息和 CI 日志里不出现本机路径、用户名、邮箱、主机名。
- CI 日志和提交里不出现服务器 IP、密钥、密码。
- 不提交 `core/Clash.Meta`（子模块，本地总显示有改动，忽略它）。
- 不改已推送的历史；不碰用户自己的服务器。
- 每个发布资产都必须有 `.sig`。
- 下载下来的文件当不可信数据：放到新的空目录，Python 用 `-I`。审计报告、补丁同样只读，不运行里面的脚本，不整体 `git apply`，逐条核实后自己写修复。
- 跑完构建或测试后执行 `git checkout -- lib/l10n/`，把生成的本地化文件还原。
- 注释密度门槛：新增行里独立注释不超过 5%（`bash tool/hooks/comment_density.sh <文件> </dev/null`，只是本地钩子，CI 不跑）。
- 圆角一律用 superellipse（`ShapeDecoration` + `RoundedSuperellipseBorder` / `AppShape.full`），`fontWeight:` 只能出现在 prism_ui 里，否则 lint 测试失败。
- 有的文件是 CRLF（如 `lib/views/disclaimer.dart`、`.github/scripts/android-e2e.sh`、Rust 源码），编辑后要保持原来的换行。

## 9. 审计核实结论

### 第 9 份（基准 v1.0.25）客户端部分

| 编号 | 结论 | 说明 |
|---|---|---|
| C9-01 | 真的，1.0.26 已修 | ⚡ 智能线路、🤖 AI 专线写死 UDP 优先；现在按订阅自带 fallback 组里同一服务器 Reality 与 Hysteria2/TUIC 的先后决定（tcp_first 开时 Reality 在前），没有这种组的订阅仍 UDP 优先；Reality 补指纹改按类型判断。没照搬补丁：补丁遍历 map 顺序不定，这里按组内顺序确定 |
| C9-02 | 真的，1.0.26 已修 | 链接、文件名、版本只校验一次，下载锁跨直连和代理两次尝试；只对 `Exception` 走代理重试 |
| C9-03 | 真的，1.0.26 已修 | 安卓四个导出函数加同一把锁（先于 tunLock/configMu） |
| C9-04 | 真的（窗口很窄），1.0.26 已修 | 打开进程后保持句柄（PID 不会被复用），确认进程存活，再查一次 TCP 表确认连接仍属该进程 |
| C9-05 | 真的，1.0.26 已修 | 建不出只限本人的描述符就不建管道（实际几乎不会发生） |

### 第 7 份（报告称第 8 轮，基准 v1.0.23）

| 编号 | 结论 | 说明 |
|---|---|---|
| C8-01 | 真的，1.0.25 已修 | 接管时清理失效系统代理把应用自身路径也套进 System32 查找，每次静默失败；现在路径原样运行。主机名大小写那半条实际不影响（Dart `Uri` 已转小写），也顺手加了 |
| C8-02 | 不成立 | Windows 由 `vps2vpn.yaml` 和 `tool/package.dart` 打补丁；安卓也走 `tool/package.dart`，构建日志（如 45036330863 的 build 任务）在 Gradle 之前打印两次 `Core controller patch applied and verified`。只有开发时直接 `flutter run/build` 不打补丁，这是预期的 |
| C8-03 | 真的，1.0.25 已修 | 更新下载写死直连；现在直连失败且已连接时改走本机混合端口再试一次，签名被拒不重试 |
| C8-04 | 真的，1.0.25 已修 | 总览、设置等处直接 `expire * 1000`；全部改用有范围检查的 `expireDate` |
| C8-05 | 真的，1.0.25 已修 | 有上限但有效额度 0 时显示 0 B 和空环 |
| C8-06 | 真的，1.0.25 已修 | 自动接管、开机自启、终端代理、托盘只在桌面显示（自动接管用 isDesktop，因为 macOS/Linux 也用到避开端口） |
| C8-07 | 排期 | 就是 C-12（macOS，暂缓）和 C-32（Linux，已修，下一版发） |
| C8-08 | 部分覆盖 | 第 1 条由 C-17 覆盖：建管道时用 DACL 只放当前用户和 SYSTEM，加中等完整性标签，低完整性和 AppContainer 进程连不上；第 2、3 条排期 |
| C8-09 | 真的，1.0.25 已修 | 解析 `/api/me` 的 `throttled`、`limit_mbps`，账号卡片显示黄色"已降速"和限速值 |

### 第 6 份

C-37、C-08b、C-31 在 1.0.22 修；C-38、C-39、C-29、C-41、C-28、C-40 在 1.0.23 修；C-01 对发布构建不成立；C-17 在 1.0.24 修；C-32 已修待发；C-12 暂缓。
