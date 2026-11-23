# vps2vpn 客户端交接文档

更新时间：2026-11-23。仓库：`xydadada/vps2vpn-client`，主分支 `vps2vpn`（上游 FlClash 的 `main` 不用来发布）。

## 1. 当前版本

| 项目 | 值 |
|---|---|
| 最新正式版（Latest） | **v1.0.25**，commit `e784eef90b3d040cfede8ec3aee84a099295ae79` |
| 上一版 | v1.0.24，commit `83f3a7be1d270529538a6484568270b790abe73b` |
| `vps2vpn` 分支头 | 在 v1.0.25 之后多了：安卓测试脚本修复、C-32（Linux 自启），下一版带上 |
| 安卓 | 第七轮在跑（运行 45092375494），预发布 `test-android-1.0.25`，见第 5 节 |

| 版本 | 内容 | 构建 | 升级测试 | 共存测试 | 源码检查 |
|---|---|---|---|---|---|
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
- 第七轮：运行 45092375494，代码 `c39238d0`（应用代码和 Windows 1.0.25 一样）。通过后把预发布转正，文件名 `vps2vpn-1.0.25-android-universal.apk`，带 `.sig` 和 `SHA256SUMS-android.txt`，告诉服务端填 `files.android`。如果模拟器还有失败，先看 artifact 里的截图和 `missed-*.xml`。

## 6. TUN 对照测试（C-17 用过的）

- `coexist.yaml` 的 TUN 阶段：应用配置改成开 TUN、关系统代理，检查 120 秒内 Core 以 SYSTEM 运行（Helper 拉起）、Helper 服务 Running、名字含 Wintun/Meta/vps2vpn 的网卡 Up，然后 `curl --noproxy '*'` 拿到 204 且上游代理日志看到这次请求。订阅规则里有 `PROCESS-NAME,python.exe,DIRECT`，否则 CI 上游代理自己的流量会被 TUN 绕回去。
- 基线：v1.0.23（运行 45037493461）通过；C-17 之后 1.0.24、1.0.25 都通过。以后改管道、Helper、TUN 相关代码时，TUN 阶段失败就说明改坏了。
- 不开 TUN 时 Core 以当前用户（CI 上是 runneradmin）运行，这是正常的；安装器不注册 Helper，只有用户打开 TUN 时应用才请求管理员权限注册。

## 7. 待办（按优先级）

1. **安卓正式 APK**：等第七轮结果（第 5 节）。
2. **下一版 1.0.26**：带上 C-32（Linux 自启识别 `Hidden=true`，只影响 Linux）和安卓脚本修复。不急，有新修复时一起发。
3. **C-12**（= C8-07 前半）：macOS 网络/唤醒监听是桩实现。CI 没有 macOS，也不发 macOS 版，暂缓。
4. Helper 按 PID 反查进程的 TOCTOU（C8-08 第 2 条）；安卓 StartTun/StopTun 监听状态竞争（C8-08 第 3 条，影响小）。
5. 清理：删掉第 3 节里标"可以删"的分支；清掉没用的 arb 文案。

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
