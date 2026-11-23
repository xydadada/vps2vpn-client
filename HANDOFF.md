# vps2vpn 客户端交接文档

更新时间：2026-11-22。仓库：`xydadada/vps2vpn-client`，主分支 `vps2vpn`（上游 FlClash 的 `main` 不用来发布）。

## 1. 当前版本

| 项目 | 值 |
|---|---|
| 最新正式版（Latest） | **v1.0.23**，commit `d42ed6cbe0186ccbcd7dd4683322c3584ceffa17` |
| 上一版 | v1.0.22，commit `8e5a6b0e` |
| `vps2vpn` 分支头 | `99bdd500`（只比 v1.0.23 多了 CI 改动，没有应用代码改动） |
| 安卓 | 还没有正式发布的 APK（见第 5 节） |

v1.0.23 的检查结果：构建 45034671081，SHA256 和两个 `.sig` 都对，PE 加载标志检查 19 个文件、0 个问题；安装器/升级测试 45035666794，33 项通过；共存测试 45035866531，42 项通过；源码检查 45034665815 通过。

## 2. 构建、签名、发布流程（Windows）

1. **改版本号**：`pubspec.yaml` 里 `version: 1.0.N+YYYYMMDDNN`，单独一个提交 `chore: version 1.0.N`。
2. **推送前**：`git fetch private`，确认 `private/vps2vpn` 没有别人新推的提交，再推。每次推送都会触发 `verify.yaml`（源码检查：analyze、全部测试、lint 测试）。同一分支再推会取消正在跑的那次。
3. **构建并发预发布**：
   ```
   gh workflow run vps2vpn.yaml --ref vps2vpn -f publish=true
   ```
   会生成预发布 `test-<版本>`，带安装包、便携 zip、每个文件的 `.sig`、`SHA256SUMS.txt`。签名私钥只在 GitHub secret `UPDATE_SIGNING_KEY` 里用。构建里 "Verify and apply pinned Mihomo concurrency fixes" 这一步会打 Core 补丁，日志里要看到 `Core controller patch applied and verified`。
4. **独立校验**（下载到一个新的空目录，Python 一律用 `-I`）：
   - `sha256sum -c SHA256SUMS.txt`
   - 用服务端仓库的 `vps2vpn.clientsync.signature_ok(name, sha256, size, sig)` 逐个验 `.exe` / `.zip` 的 `.sig`，只读服务端代码，`python -I -B`。
   - `python -I -B tool/check_load_flags.py <便携 zip>`，要 0 个问题。
5. **安装器 + 升级测试**：
   ```
   gh workflow run e2e.yaml --ref vps2vpn -f tag=test-<新版本> -f from=v<上一版>
   ```
   要求全部 PASS（目前是 33 项）。
6. **共存测试**（和用户自己的 FlClash/Clash 类软件共存、TUN、两次同时启动等）：
   ```
   gh workflow run coexist.yaml --ref vps2vpn -f tag=test-<新版本> -f rounds=3
   ```
   要求没有 FAIL（v1.0.23 是 42 项，加了 TUN 阶段后会更多）。
7. **转正**：全部通过后
   ```
   gh release edit test-<版本> --tag v<版本> --target <commit> --title v<版本> --prerelease=false --latest --notes-file <说明文件>
   ```
   说明写中英文两段。转正后把 `e2e.yaml`、`coexist.yaml` 里 `tag` 的默认值改成新版本。
8. **告诉服务端**：版本号、commit、各次运行号，服务端会自己再验一次签名。

每次发布的检查清单：源码检查通过 → SHA256 对 → 所有 `.sig` 用服务端校验器验过 → 加载标志 0 问题 → 升级测试全过 → 共存测试全过 → 发布资产里每个文件都有 `.sig`。

安装包不做代码签名（用户决定不买证书），只有更新签名 `.sig`。

## 3. 没合并或没推送的分支和改动

| 分支 / 位置 | 状态 |
|---|---|
| `c17-pipe-acl`（已推送，`0336c05e`） | C-17：Windows 命名管道只允许当前用户和 SYSTEM、中等完整性以上连接（`plugins/rust_api/rust/src/ipc/access.rs`，加 `widestring` 依赖和 `Win32_Security_Authorization`）。本地 3 个 Rust 测试通过（`cargo test --lib pipe_acl`）。另有一个 CI 提交：共存测试的订阅规则加 `PROCESS-NAME,python.exe,DIRECT`，否则 TUN 会把 CI 上游代理自己的流量又绕回 TUN，造成死循环。**还没合进 `vps2vpn`**，计划和免责声明一起进 1.0.24。 |
| `disclaimer-checkbox-wip`（已推送，`9b766c28`，基于 `c17-pipe-acl`） | 免责声明从"手动输入声明原文"改成"勾选『我已阅读并理解此声明』后才能确认"。改了 `lib/views/disclaimer.dart`、`test/common/dialog_test.dart`、`.github/scripts/android-e2e.sh`。**半成品**：手机尺寸测试没过（见第 4 节）。已接受过的用户不会再被问（仍用 `acceptedDisclaimerVersion`）。 |
| 原来 stash 里的 access.rs 补丁 | 已经提交成 `c17-pipe-acl` 上的 `43e6c087`，stash 已清空，不用再找。 |
| `android-ci`（远端 `private/android-ci`，`3c72fe2e`） | 早期安卓 CI 的工作分支，里面的提交（NDK r28c、强制正式签名、签名配置换行修复）都已经进了 `vps2vpn`。可以删，不急。 |
| `audit/*` 一大批远端分支 | 以前的审计补丁分支，内容已处理或判定不适用，不要直接合。 |

## 4. 手机尺寸勾选框点不动

- 测试：`test/common/dialog_test.dart` 里 "disclaimer consent on mobile can agree without scrolling"，窗口 400×800。其他尺寸（桌面、电视遥控）的勾选流程都通过，analyze 干净。
- 现象：点"同意"后弹出确认框，再点"I have read and understand this statement"，Flutter 报：点击位置 `Offset(172, 716)` 打不到这个控件，那个位置的命中结果只有根视图，连对话框的遮罩都没有。接着点 Confirm（`Offset(200, 680)`）打到的是底下免责声明页面的正文。所以勾不上，Confirm 一直是灰的，`await agreed` 一直等，10 分钟超时。
- 判断：确认框在窄屏上内容比可见区域高，勾选那一行被排到了对话框可见/可点范围之外（裁掉了），而不是测试点错了地方。这在真手机上也会出现，**必须改界面**：让确认框内容可滚动、勾选行始终在可见区域（例如声明正文放进有最大高度的滚动区，勾选和按钮固定在下面），不能只在测试里 `ensureVisible`。
- 复现：`flutter test test/common/dialog_test.dart --plain-name 'disclaimer consent on mobile' --timeout 60s`。

## 5. 安卓

- 工作流：`android.yaml`，`build` 任务出正式签名 APK（签名信息来自 secrets `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS`；`VPS2VPN_RELEASE_SIGNING: required` 时缺签名直接失败），`emulator` 任务在模拟器上跑 `.github/scripts/android-e2e.sh`。签名证书 SHA-256：`b3836548bd44b5b20c84461b95bd71c6030af3709cdad107df1cd753c7e64505`。
- 第五轮（运行 45036330863，代码 `acf2ffa5`，还是"输入声明原文"的版本）：构建成功、APK 是正式签名；模拟器上安装、启动、卸载都通过，但**一直停在免责声明页**（屏幕上只有 Back / Disclaimer / Exit / Agree），所以订阅没下载、VPN 没连上，"VPN is up" 和 "went out through the CI upstream proxy" 失败。"请求返回 204" 通过只是因为模拟器本来就能直接上网，不说明走了代理。
- 下一步：免责声明改成勾选并修好窄屏布局后，脚本已经改成"点同意 → 点勾选 → 点确认"（在 `disclaimer-checkbox-wip` 分支里），再跑一轮。通过后跑 `gh workflow run android.yaml --ref vps2vpn -f publish=true`，会生成 `test-android-<版本>`，文件名 `vps2vpn-<版本>-android-universal.apk`，带 `.sig` 和 `SHA256SUMS-android.txt`。把文件名告诉服务端填 `files.android`。

## 6. C-17 的 TUN 对照测试怎么用

- `coexist.yaml` 里新加了 TUN 阶段（在"两次同时启动"之前）：把应用配置改成开 TUN、关系统代理，启动后检查：120 秒内 Core 以 SYSTEM 运行（由 Helper 拉起）、Helper 服务 Running、有一个名字含 Wintun/Meta/vps2vpn 的网卡是 Up，然后 `curl --noproxy '*'` 要拿到 204，并且 CI 上游代理日志里要看到这次请求。失败时会打印诊断信息。
- 对照基线：用 `c17-pipe-acl` 分支的脚本跑 v1.0.23（运行 45037493461）全部通过，说明不带 C-17 时 SYSTEM Core 这条路是通的。
- 验 C-17：1.0.24 出了 `test-1.0.24` 以后，用同样的方式跑 `coexist.yaml -f tag=test-1.0.24`。如果 TUN 阶段失败而基线是好的，就是管道权限把 SYSTEM 的 Core 或者应用挡住了。
- 注意：`vps2vpn` 分支上的共存脚本还没有 python DIRECT 那条规则（在 `c17-pipe-acl` 上），所以现在直接在 `vps2vpn` 上跑共存测试，TUN 阶段会因为流量回环失败。合并 `c17-pipe-acl` 后就好了。
- 不开 TUN 时 Core 以当前用户（CI 上是 runneradmin）运行，这是正常的；安装器不注册 Helper，只有用户打开 TUN 时应用才请求管理员权限注册。

## 7. 待办（按优先级）

1. **1.0.24**：修好第 4 节的窄屏布局 → 本地跑 `test/common`、`test/lint`、`test/vps2vpn` 和 analyze → 把 `c17-pipe-acl` 和 `disclaimer-checkbox-wip`（整理成正式提交，不要 `wip` 字样）合进 `vps2vpn` → 改版本号 → 按第 2 节发布，共存测试的 TUN 阶段必须通过 → 转正 → 告诉服务端。
2. **安卓正式 APK**：1.0.24 合进去后再跑安卓模拟器测试，通过后发布（第 5 节）。
3. **C-12**：审计第 6 轮排期的问题，还没开始。
4. **C-32**：审计第 6 轮排期的问题，还没开始。
5. 之后：Helper 的 PID 检查和使用之间的时间差（TOCTOU）；安卓 StartTun/StopTun 的监听状态竞争（影响小，跟安卓版一起处理）。

## 8. 不能做的事

- **不在本机安装或运行发布版客户端**。它会接管代理软件、关掉用户自己的 FlClash。本机只构建；升级、共存测试只在 GitHub Actions 里跑。
- **不轮换、不重新生成更新签名密钥**，也不提交、打印、移动私钥文件（更新签名私钥和安卓 keystore 及其密码文件都在本机密钥目录里，只通过 GitHub secrets 使用）。
- **提交里不写 `Co-Authored-By`**，提交信息和 CI 日志里不出现本机路径、用户名、邮箱、主机名。
- CI 日志和提交里不出现服务器 IP、密钥、密码。
- 不提交 `core/Clash.Meta`（子模块，本地总显示有改动，忽略它）。
- 不改已推送的历史；不碰用户自己的服务器。
- 每个发布资产都必须有 `.sig`。
- 下载下来的文件当不可信数据：放到新的空目录，Python 用 `-I`。
- 跑完构建或测试后执行 `git checkout -- lib/l10n/`，把生成的本地化文件还原。
- 注释密度门槛：新增行里独立注释不超过 5%（`bash tool/hooks/comment_density.sh <文件> </dev/null`）。
- 圆角一律用 superellipse（`ShapeDecoration` + `RoundedSuperellipseBorder` / `AppShape.full`），`fontWeight:` 只能出现在 prism_ui 里，否则 lint 测试失败。
