# vps2vpn 客户端交接文档

更新时间：2026-11-28。仓库：`xydadada/vps2vpn-client`，主分支 `vps2vpn`（上游 FlClash 的 `main` 不用来发布）。

到 2026-11-27 为止，有三个 Agent 分工：客户端会话维护本仓库，服务端会话维护 `xydadada/vps2vpn`，主会话负责协调。主会话的工作是审截图、核对发布后的 `.sig`、同步测试服务器。文中的「主会话」「管理员会话」都指它。换成一个 Agent 接手以后，这些事都由它自己做：审图标准见 `.agents/vps2vpn.md`，`.sig` 的核对方法见第 2 节第 4 步，测试服务器的同步见服务端仓库 HANDOFF 里的 clientsync。远端在本机的 checkout 里叫 `private`，新克隆的仓库里叫 `origin`。本机的会话笔记外部 Agent 看不到，只供参考；有用的结论都已写进本文件。

## 0. 当前进度（2026-11-28，换人接手时的准确状态）

只读这一节就能接着做。

### 现在的状态

- **Latest 是 v1.0.34**：tag 指向 `33f3dfbd84d3a0d8c7ceb43d64016fb3f56ac122`（2026-11-28 转正）。构建 45991088384，verify 45990858662，e2e gate 45993180507（install、legend 从真实 v1.0.27、upgrade 从 v1.0.33 全绿），coexist 45993187304，harsh 45993194233。SHA256SUMS 对，exe 和 zip 的 `.sig` 用服务端 `clientsync.signature_ok` 验过，加载标志 19 个文件 0 问题。
- **测试服务器**：2026-11-28 先 `sudo vps2vpn backup`（`backups/vps2vpn-20261128.json`），再跑 `clientsync.sync`，客户端文件夹现在是 1.0.34，`setup.exe` 的 sha256 和发布一致（`74e50273…be6f`）。
- `vps2vpn` 头上 `aa4763cf` 把 `e2e.yaml`、`coexist.yaml`、`harsh.yaml` 的默认 `tag` 改成了 v1.0.34。
- 用户叫停时 1.0.35 **没有发**，版本号也没改。

### 1.0.35 已写好、还没合的分支

`p1-1035`（基于 `aa4763cf`，已推到 `private`）。每个提交都带测试，本地 `flutter analyze` 干净，`flutter test` 只在 CI 跑，**这个分支的 verify 还没跑完过**（run 46145663556 停在 `816dd9a7`，之后又推了两个提交）。接手后先看最新一次 verify：

| 提交 | 内容 | 对应 |
|---|---|---|
| `12de9cb6` | 安全模式构建跳过 runner 启动时清理残留代理（CMake 从 `DART_DEFINES` 读 `SAFE_MODE=true`） | #101，替代 #172 |
| `75b99893` | Test Lab 摘要和截屏标签里，XML 转义过的订阅链接也遮住；verify 的 dart job 跑 `.github/testlab/summary_test.py` | 替代 #157 |
| `11bdc9a3` | 反馈里遮住带引号的密码、链接里的账号密码、Authorization 头 | 替代 #105 |
| `c05d39aa` | 坏掉的偏好设置只记 `FormatException(原因)`，不记内容 | 替代 #108 |
| `5a06f3c0` | MITM 资源下载失败的日志不写链接 | 替代 #135 |
| `1bb6c9eb` | 出口 IP 探测拒绝更多保留 IPv6 段（3fff::/20、100::/64、100:0:0:1::/64、5f00::/16） | 替代 #90 |
| `a733b9a5` | Protobuf 长度接近 2^63 时当成二进制，不再崩 | 替代 #133 |
| `816dd9a7` | 所有 YAML 读取共用一个转换，超过 100 万个值或 256 层就拒绝（别名炸弹） | #137 |
| `cc249bf5` | 备份超过恢复上限（2000 个文件或 256 MB）时不写，提示原因；新增文案 `backupTooLarge` | 替代 #109 |
| `2dcd54bd` | **P0**：点「安装」时在 isolate 里重读安装包和 `.sig`，对同一份字节算 SHA256 和大小再验 Ed25519；链接、文件夹、改过的文件都拒绝并删掉；`.sig` 先写 `.sig.part` 再改名 | 替代 #167；#168 的原生交接部分没做 |

另有 `wip-110-text-cap`（一个提交）：脚本、图标集、模块的文本下载限 32 MiB，超限报 `DownloadTooLargeException`。**没进 CI**，对应 #110。

### 接下来（按顺序）

1. 等 `p1-1035` 的 verify 变绿（挂了先修）。`2dcd54bd` 只在失败时弹一个对话框，不改界面，不用截图。
2. 合进 `vps2vpn`（快进），等 verify 绿；单独提交 `chore: version 1.0.35`；按第 2 节发：`vps2vpn.yaml` → `e2e.yaml`（gate 含 legend）→ `coexist.yaml` → `harsh.yaml` → 自己验 SHA256、`.sig`、加载标志 → 转 Latest → 改工作流默认 tag → 测试服务器先 backup 再 `clientsync.sync`（命令：`sudo PYTHONPATH=/usr/local/lib/vps2vpn/app /usr/bin/python3 -c "from vps2vpn import clientsync, db; print(clientsync.sync(db.settings()))"`）。
3. 关 PR 和 issue：#172 #157 #105 #108 #135 #90 #133 #109 #167 写明替代它的提交后关闭；#101 #137 修好后关；#168 留着（原生交接边界）。没处理的不要关。
4. 剩下的待办按优先级见 [.agents/triage-1.0.35.md](.agents/triage-1.0.35.md)（P1 → P2 → P3）。P1 里还没做的：#92 + C10-01（崩溃后恢复系统代理快照，同时仍清掉指向本机死端口的残留代理）；B/C 包的心跳 `ok:true`、导入出错释放忙碌状态；#159 发布前源码校验和 `--enforce-lockfile`；#110（见上面的 wip 分支）；#158 分享链接；#91 #164/#174（安卓签名指纹）。2026-11-28 之后新增的 #173（只做调研）和 #175（failover 旧动作）还没看。
5. 服务端审计带来的两项客户端工作，**等服务端那边做完再做**：R-13 的客户端部分（防抖、延迟切回、换服务器时提示），以及「显示的延迟不是 ping」的文案。
6. #150（私下报告漏洞）是仓库设置，由用户决定。#74、#75 来自外部贡献者，先核实再回复。

### 分拣全文（与 `.agents/triage-1.0.35.md` 相同）

#### P1：1.0.35 必做（安全、隐私、发布可信）

| 来源 | 内容 | 处理 |
|---|---|---|
| #92 | Windows 崩溃后丢失连接前的 WinINet 快照 | 把快照持久化到磁盘，重启后按快照恢复。和 C10-01（清理死端口残留代理）合并考虑：没有快照时仍要清掉指向本机死端口的代理，不能直接变成 no-op（B/C 包的“无快照即不动”与此冲突，不照搬） |
| #101 | SAFE_MODE 下 runner 在 Flutter 初始化前就调用 `flclash_clear_stale_proxy` | `windows/runner/main.cpp` 的 `ClearStaleProxyInBackground()` 在安全模式下跳过 |
| B/C | 安装前复验：isolate 里流式 SHA256 加 Ed25519，拒绝符号链接和非普通文件 | 重写进 `update_file.dart`，点「安装」时再验一次磁盘上的字节。不动公钥和签名语句 |
| B/C | `.sig` 先写临时文件再改名 | 同上 |
| B/C | 心跳回复必须有 `ok:true` 和布尔 `revoked` | `devices.dart`，畸形 200 不再恢复设备 |
| B/C | 导入或剪贴板出错后释放忙碌状态，保留输入，不把含 token 的原始异常放到界面 | `clipboard_import.dart`、`panel.dart` |
| B/C | Windows/Android 发布先过源码校验；`pub get --enforce-lockfile` | workflow 修改 |
| #157 | Test Lab 诊断里对 XML 转义过的订阅链接也脱敏 | 必做（订阅链接不得进日志） |
| #105 #108 #135 | 反馈里遮住引号内的密码和认证头；坏配置内容不进日志；MITM 下载日志不写私有 URL | 隐私，重写并加测试 |
| #91 #90 #133 #137 #109 #110 | 分享链接不悄悄改 TLS 策略；探测排除非公网 IPv6；Protobuf 长度溢出；YAML 别名展开上限；备份恢复上限；脚本和图标下载限长 | 输入边界，逐个核对后重写 |

#### P2：简洁模式正确性（1.0.35 尽量做，做不完顺延）

- 设备和订阅：#104 #113 #114 #115 #116 #117 #98，以及 B/C 的“UUID 并发首次创建合并”“过期 scope 取消连接”。
- 诊断和反馈：#96 #97 #99 #118（长状态标签不出卡片，要先截图核对）。
- 生命周期：#102 #106 #131。#123（Android 生命周期串行化）风险大，需要真机，放到 Test Lab 配额恢复后再做。
- 界面：B/C 的“减少动态效果”和“大字号布局”。按现有外观改，要遵守帧预算并补截图，不重画首页。
- #93：macOS/Linux 断开时恢复连接前的设置。与 #92 同一类，等 #92 做完后再做。
- #130 #144 #149：迟到的写入覆盖新数据。核对后再定。

#### P3：上游高级模式、编辑器、文档（不阻塞 1.0.35）

#89 #94 #95 #107 #111 #112 #119 #120 #121 #124 #125 #132 #134 #136 #138–#143 #145–#147 #151–#153 #156；文档类 #100 #126 #127 #128 #148 #154 #155；issue #122 #129。
#152 改了 Test Lab driver 的权限，合并前要确认没有放宽到不需要的范围。

#### 不采纳

- B 包的 `tool/restore_source_assets.py` 和 `source_assets.json`：字体已经在仓库里，不需要。
- `SOURCE_REVIEW.md`、`docs/review-2026-11-26.md`：内容并进 HANDOFF，不另开文件。
- 发布前缀 `rs-` 和 `dev-`：先确认这些前缀真的存在再处理，不按包里的说法直接改。
- #150（私下报告漏洞的渠道）：交给用户决定。

### 合并的规矩

- 一次合一个：分支上 `git fetch private && git rebase private/vps2vpn`，推分支（`--force-with-lease`），等分支 verify 绿，`git push private <分支>:vps2vpn` 快进，等 `vps2vpn` verify 绿再合下一个。
- 动到界面的改动要用 `screenshots.yaml` 拍改前改后（中英、深浅、宽、默认、最窄、legend 形状），外观以 1.0.27 为准（`.agents/vps2vpn.md`）。

## 1. 当前版本

| 项目 | 值 |
|---|---|
| 最新正式版（Latest） | **v1.0.34**，commit `33f3dfbd84d3a0d8c7ceb43d64016fb3f56ac122`（2026-11-28 转正；节点页、对话框、检测页、设置页的细节和文案统一；gate、coexist、harsh 全绿，测试服务器已同步，见第 0 节） |
| 上一版 | v1.0.32，commit `3439ae243eb79de536a9bacabc6f9ca29bc8d083`（修 1.0.31 背景雪花噪点）。v1.0.31 因背景雪花已撤回为预发布 |
| `vps2vpn` 分支头 | 不在这里记，以 `git log private/vps2vpn` 为准。下一版 1.0.34 正在合分支（第 0 节） |
| 安卓 | 还没有正式 APK，服务端 `files.android` 仍未配置。模拟器上连上 VPN 约 1 秒后整机冻住（第 5 节）。真机测试结果见第 5 节"Firebase Test Lab"。预发布 `test-android-1.0.26` 只当预发布，不转正 |

**English summary.** Latest client is v1.0.34; section 0 has its runs and where 1.0.35 stopped (branch p1-1035). Before that, v1.0.33 (the Home title holds the exit country while the smart line settles, narrow pages end above the floating tab bar, the title bar and the wide sidebar's top edge blend into the backdrop; upgrade test from v1.0.32 66 PASS, coexist 94 PASS, harsh 309 PASS with no FAIL, background roughness 2.8; the server still has to re-check SHA256 and `.sig`). v1.0.32 fixed the background static of 1.0.31. v1.0.31 was pulled back to a prerelease because the page background was covered in static (grain pixels not premultiplied); 1.0.32 fixes that and `screenshots.yaml` now fails when the background outside the cards is rough. 1.0.29 and 1.0.30 were never released on their own: harsh dirty caught a takeover regression in 1.0.30 (a bare core on the system proxy port could be spared when the takeover read the system proxy after ours was on), and the fix shipped in 1.0.31 with the smart line by billing rate, node status, config_version refetch, expiry days, local-network checks, feedback and device management. Android has no release: the emulator freezes about a second after connecting; real phones are tested through Firebase Test Lab (`android-testlab.yaml`, secret `TESTLAB_SUB_URL`); see section 5. `files.android` on the server is still unset. The test server's details are only in the local file `C:\Users\<user>\.claude\CLAUDE.md` on the user's PC (test-server section), never in this repo.

| 版本 | 内容 | 构建 | 升级测试 | 共存测试 | 源码检查 |
|---|---|---|---|---|---|
| 1.0.32 | 1.0.31 的全部改动 + 背景颗粒按预乘像素生成（1.0.31 背景满屏雪花）；截图背景粗糙度深色 2.8、浅色 2.8（上限 6） | 45590862883 | 45593469152，66 PASS（含从 v1.0.28 升级） | 45593475198，94 PASS；harsh 45593487887 全部通过；截图 45593495191 | 45584491830 |
| 1.0.31 | 1.0.29/1.0.30 的全部改动 + 节点状态、config_version、到期日、本机网络判断、一键反馈、设备管理、takeover 修复（被替换的系统代理端口存盘） | 45577426961 | 45579327115，66 PASS（含从 v1.0.28 升级） | 45579336511，94 PASS；harsh 45579344370 全部通过 | 45575835875 |
| 1.0.28 | "另一个 VPN 开着"提醒 + harsh 脚本修复（chaos、soak 的网卡选择；users 第二账户只停自己的进程） | 45166822301 | 45334152519，66 PASS（含从 v1.0.27 升级） | 45168676856，94 PASS | 45166802653 |
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
   会生成预发布 `test-<版本>`（同名的 `test-*` 预发布会被这次替换掉；同名的不是预发布就停下，`v*` 正式版任何时候都不能删），带安装包、便携 zip、每个文件的 `.sig`、`SHA256SUMS.txt`。签名私钥只在 GitHub secret `UPDATE_SIGNING_KEY` 里用。构建日志里要看到 `Core controller patch applied and verified`（Mihomo 补丁，见第 9 节 C8-02）。
4. **独立校验**（下载到一个新的空目录，Python 一律用 `-I`）：
   - `sha256sum -c SHA256SUMS.txt`
   - 用服务端仓库的 `vps2vpn.clientsync.signature_ok(name, sha256, size, sig)` 逐个验 `.exe` / `.zip` 的 `.sig`，只读服务端代码，`python -I -B`。
   - `python -I -B tool/check_load_flags.py <便携 zip>`，要 0 个问题。
5. **安装器、legend 升级、应用内升级（`e2e.yaml`，最后的 gate）**：
   ```
   gh workflow run e2e.yaml --ref vps2vpn -f tag=test-<新版本>
   ```
   - `from` 默认 `latest`：从当前 Latest 走应用内更新升级到新版本。
   - `legend` 默认 `v1.0.27`：从真实的 v1.0.27 手动运行新安装包升级，订阅用 legend 形状的数据，并确认测试用的假发布永远不会被当成可安装的版本。用户还在用 1.0.27，这一项不能跳过。
   - `gate` 这个 job 要求 install（`e2e`）、`legend`、`upgrade` 三个都跑过并且成功。任何一个被跳过都算失败。gate 不绿不能转正。
   - 以前的升级测试（`-f from=v<上一版>`）现在就是这里的 `upgrade`。

6. **共存测试**（和 FlClash、Clash Verge 共存、接管、重启、TUN、两次同时启动、卸载）：
   ```
   gh workflow run coexist.yaml --ref vps2vpn -f tag=test-<新版本> -f rounds=3
   ```
   要求没有 FAIL（1.0.27 时 94 项）。之后再跑一遍 `harsh.yaml`（第 6a 节）。
7. **转正**：gate 全绿、共存和 harsh 都通过后
   ```
   gh release edit test-<版本> --tag v<版本> --target <commit> --title v<版本> --prerelease=false --latest --notes-file <说明文件>
   ```
   说明写中英文两段，面向用户写，不写内部编号。转正后把 `e2e.yaml`、`coexist.yaml` 里 `tag` 的默认值改成新版本。
8. **告诉服务端**：版本号、commit、各次运行号，服务端会自己再验一次签名。

每次发布的检查清单：源码检查通过 → SHA256 对 → 所有 `.sig` 用服务端校验器验过 → 加载标志 0 问题 → 升级测试全过 → 共存测试全过（含 TUN）→ 发布资产里每个文件都有 `.sig`。

安装包不做代码签名（用户决定不买证书），只有更新签名 `.sig`。

## 3. 分支

1.0.34 的页面分支（2026-11-27）。每页截图由 `screenshots.yaml` 生成，审图要求见 `.agents/vps2vpn.md`。

| 分支 | 内容 | 状态 |
|---|---|---|
| `ui-home` | 首页细节、速度曲线 | 已合入 |
| `ui-dialogs` | 对话框写明按钮的动作；错误提示放在页面标题下面；设备被移除后电源键变灰，提示「复制求助信息」 | 审过，已 rebase，等重拍确认后合 |
| `ui-nodes` | 节点卡片、倍率写法、分组超过两行改成横向滚动、英文节点名 | 审过，已修 lint，等重拍确认后合 |
| `ui-check` | 检测卡标题只写问题数，每个问题各占一行；结果胶囊用完整宽度 | 审过，可合 |
| `ui-settings` | 设置页：版本放到「关于」，二维码放进图标，一行一个图标 | 审过，已 rebase 到 ui-check，等 verify |
| `copy-fixes` | 剩下的文案：点击、「」引号 | 待 rebase（会和 ui-nodes 在 `servers.dart`、`home.dart` 冲突） |
| `upgrade-legend` | `e2e.yaml` 的 gate、legend 升级测试、`test-*` 预发布的替换规则 | 已 rebase，1.0.34 发布前合 |

`audit-shots`、`design-tokens`，以及 `c17-pipe-acl`、`disclaimer-checkbox-wip`、`audit7`、`c32-autostart-hidden`、`cpr*`、`pr*` 这些旧分支，内容已经并入或者判定不用，可以删。`audit/*` 不要直接合。

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

### Firebase Test Lab 真机测试（2026-11-23）

- 工作流：`android-testlab.yaml`（只能手动触发）。输入 `tag`（默认 `test-android-1.0.26`，从这个预发布下载 `*-android-universal.apk`）、`devices`（默认空：只编译驱动、列出真机型号，不占额度；要跑真机就明确写，例如 `-f devices='model=SC-51E,version=36;model=CPH2449,version=34'`，即 Galaxy S24 和 OnePlus 11）。注意 `gh workflow run -f devices=` 传空值会被 gh 丢掉，所以默认值必须是空。
- 登录方式：无密钥，用 Workload Identity。仓库变量 `GCP_WIF_PROVIDER`、`GCP_TESTLAB_SA`、`GCP_PROJECT_ID`（项目名在仓库变量里；工作流第一步把它遮掉，日志里不出现）。
- 订阅：secret `TESTLAB_SUB_URL`，是测试服务器上专门开的 testlab 测试账户（不是任何用户的真实账户），十六进制编码后传给手机，日志里不打印。测试做完后管理员会话会停用这个账户；以后要再测，请管理员重新开一个并更新这个 secret。
- 驱动：`.github/testlab/`，一个独立的 UiAutomator 测试 APK（`ConnectTest.java`）：同意免责声明 → 用 `vps2vpn://install-config?url=` 导入订阅 → 点连接 → 等 VPN 建立 → 60 秒内每 10 秒请求一次 generate_204 → 确认出口 IP 变了 → 断开。每一步用 `PASS  ...` 报告。
- 运行：`gh workflow run android-testlab.yaml -R xydadada/vps2vpn-client --ref vps2vpn`。结果在 Firebase 控制台和运行的 `testlab` artifact 里。
- 最后一次结果：运行 45149599952（2026-11-23，APK 来自 `test-android-1.0.26`）。**两台真机都失败**：`CPH2449-34`（OnePlus 11）和 `SC-51E-36`（Galaxy S24）都是"1 test cases failed"。GitHub 日志只有这张汇总表，看不到失败在哪一步（免责声明、导入、连接、上网还是断开）。详细结果（每一步的 `PASS` 行、logcat、录屏）在 Firebase 控制台项目 `vps2vpn-testlab` 的 Test Lab 历史 `vps2vpn-android` 里，原始文件在 Test Lab 的 GCS 结果桶里。
- 2026-11-23 已改（e2f64151 起）：
  1. 测试失败时整个运行显示失败（`set -o pipefail`）。
  2. "What each phone saw" 一步把每台手机的结果从 GCS 拷到运行器上，用 `.github/testlab/summary.py` 只挑出步骤行（`PASS`/`NOTE`）、失败原因和崩溃相关 logcat 行，遮掉订阅链接、它的主机和所有 IP 后打印并上传 `summary-*.txt`；原始结果不出 GCS。
  3. 关了录屏（`--no-record-video`），订阅链接不会出现在视频里。
  4. 驱动：导入确认框改为可选（模拟器上就没有）；按钮匹配 content-desc 的第一行；每个关键步骤前记录屏幕上的文字（`NOTE`），失败信息里也带上（同样脱敏）。
- 运行 45165449899 是误触发（当时默认值还是两台真机，`-f devices=` 被丢掉），GitHub 上已取消，但 Google 侧的矩阵可能跑完了，占了当天的真机额度；testlab 账户已停用，测试会在导入后失败，没有意义，不用看。

### 安卓模拟器失败诊断（2026-11-23）

- GPU 模式也排除了：运行 45146767797 用 `swangle_indirect` 和 `guest` 两种，都更早就失败（应用首次启动后就不在运行），不比默认的 `swiftshader_indirect` 好。CI 默认保持 `swiftshader_indirect`。至此网络栈、MTU、地址段、GPU 模式都排除了，模拟器这条路不再继续。
- 2026-11-23 续查：
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

## 6a. Windows 严苛测试（`harsh.yaml`）

- TUN 刚建好时的请求（2026-11-25 结论）：1.0.29 的 coexist 和 harsh chaos 各有一次"TUN 下 curl 拿到 000"，都发生在虚拟网卡刚 Up 之后（chaos 网卡 Up 后 0.4 秒内立刻失败，coexist 17 秒后失败、没到 20 秒超时，像 DNS 没解析出来），稍后再测都通，所以是网卡起来了但路由和 DNS 还没真正生效的那一两秒，不是外部网络抖动，真实用户点连接后马上开网页也会失败一次。1.0.30 起 TUN 模式下首页要等一次不走代理的请求真正通了才报"已连接"（`lib/vps2vpn/tun_ready.dart`，最多等 15 秒）；`Test-NoProxy`（harsh）和 coexist 的 TUN 检查改成 15 秒内重试，通了但超过 1 秒的记一条 NOTE/INFO 写明等了几秒，一直不通照样 FAIL。
- 只能手动触发：`gh workflow run harsh.yaml --ref vps2vpn -f tag=v<版本> -f scenarios='["dirty"]'`（`scenarios` 留默认就是全部）。`proxy-restore` 在 windows-2022 上总会顺带跑。脚本在 `.github/scripts/harsh/`，公共函数在 `lib.ps1`（`Check` 记 PASS/FAIL，`Note` 只记录不算失败）。
- 场景：
  - `proxy-restore`：断开、关机或注销时，把系统代理还原成连接前的样子（公司代理、别的软件的活代理或 PAC 原样还回；死端口不还；连接中被别人改过就不动）。
  - `dirty`：装着、开着一堆别的代理软件（Clash Verge、FlClash、v2rayN、Hiddify、Shadowsocks、sing-box 带自己的 TUN、WireGuard），检查接管关/开两种情况下的端口、系统代理、TUN 并存，以及卸载后不留东西。
  - `chaos`：断网、丢包、延迟、磁盘快满、Core 被杀等情况下不死、能恢复。
  - `users`：管理员装好后，第二个普通账户（名字带中文和空格）用不了管理员的 Helper 和 Core 管道，自己能独立运行。
  - `soak`（长时间运行）、`protocols`（多种协议）。
- 2026-11-23 修的 4 个测试脚本问题（都不是应用的毛病）：
  1. `dirty` 把 7890 硬当成"被占用的端口"，实际那次没人占 7890。改成只检查真被占用的端口。（顺带修了一个变量重名，它让 9090 占用进程那一项出错。）
  2. `chaos` 计算磁盘空余时 `[math]::Max(0, …)` 选了 Int32 重载，28 GB 溢出。改成 `[long]`。
  3. `users` 把组名 `BUILTIN\Users` 按空字符串拆分，找不到 Users 组。改成按反斜杠拆。
  4. `users` 用 `Start-Process -Credential` 启动的程序继承了 runneradmin 的环境变量，所以第二个账户的数据跑到了管理员目录下。现在子进程先从自己加载的用户配置里取 APPDATA、LOCALAPPDATA、USERPROFILE、TEMP。
- 两个 TUN 同时开（`dirty` 里 sing-box 的 TUN 加我们的 TUN）：不带代理的 curl 有时拿不到 204。原因是我们在 Windows 上默认开 strict-route（防 DNS 泄露），它会挡住别的网卡上的 DNS，包括 sing-box 自己的查询。真正要求的几条都过：请求经过了我们的 Core，不死循环，Core 不空转，界面不卡，我们停了以后对方的 TUN 恢复正常。所以这一条只记 NOTE，不算失败。
- `dirty` 的"另一个软件的系统代理还回来了"现在和我们连接前那一刻的状态比较，并打印前后的值（别的软件启动时自己也会改系统代理）。
- 结果：`dirty` 运行 45150648196 在 2022 和 2025 上全过，`chaos`、`proxy-restore`、`soak`、`protocols` 之前也都过了。`users` 的最后结果见第 7 节第 3 条。

## 7. 待办（按优先级）

1. **1.0.34**：合完第 3 节的分支，按第 2 节发布。发布后告诉服务端 tag 和运行号，服务端再核对 `.sig` 并同步测试服务器。
2. **1.0.35：外部审查（2026-11-27 分拣）**。来源是客户端 PR #89–#157、14 个 issue，以及两个离线补丁包。做法：在当前代码上逐条重写并补测试，PR 不直接合并，做完后关闭 PR，并写明对应的提交。
   - **必做（安全、隐私、发布可信）**：
     - #92：Windows 崩溃后丢失连接前的 WinINet 快照。把快照存到磁盘，重启后按快照恢复。没有快照时，仍要清掉指向本机死端口的代理（C10-01）。补丁包里「没有快照就什么都不做」的写法和这一点冲突，不照搬。
     - #101：SAFE_MODE 下，runner 在 Flutter 初始化之前就清理系统代理（`windows/runner/main.cpp` 的 `ClearStaleProxyInBackground`）。安全模式下跳过这一步。
     - 安装前再验一次：在 isolate 里流式计算 SHA256 并验 Ed25519，拒绝符号链接和非普通文件。`.sig` 先写临时文件再改名。公钥和签名语句不动。
     - 心跳回复必须带 `ok: true` 和布尔值 `revoked`，否则不算正常回复。
     - 导入或剪贴板出错后释放忙碌状态并保留输入，界面上不显示含 token 的原始异常。
     - Windows 和 Android 发布前先过源码检查；`flutter pub get --enforce-lockfile`。
     - #157：Test Lab 诊断里对 XML 转义过的订阅链接也做脱敏。
     - 隐私：#105、#108、#135。
     - 输入边界：#90、#91、#109、#110、#133、#137。
   - **尽量做（简洁模式的正确性）**：
     - 设备和订阅：#98、#104、#113–#117。
     - 诊断和反馈：#96、#97、#99、#118。
     - 生命周期：#102、#106、#131。
     - 迟到的写入覆盖新数据：#130、#144、#149。
     - macOS/Linux 断开时恢复原设置：#93，在 #92 之后做。
     - 减少动态效果、大字号布局：照现在的外观改，补截图。
     - #123（Android 生命周期）需要真机，等 Test Lab 再做。
   - **不阻塞 1.0.35**：上游高级模式、编辑器、备份和文档类的 PR（#89、#94、#95、#100、#107、#111、#112、#119–#121、#124–#128、#132、#134、#136、#138–#143、#145–#148、#151–#156），以及 issue #122、#129。#152 放宽了 Test Lab 驱动的权限，合并前先确认范围。
   - **不采纳**：补丁包里的字体恢复工具（字体已经在仓库里）和单独的审查记录文件。发布前缀 `rs-`、`dev-` 先确认确实存在再处理。
   - **用户决定**：#150（开启私密漏洞报告，属于仓库设置）。
3. **安卓正式 APK（暂停，2026-11-23 用户定）**：模拟器上连上 VPN 约 1 秒后整机冻住（第 5 节）。真机测试走 Firebase Test Lab，Test Lab 的配额恢复后还欠一次真机运行。testlab 测试账号要请管理员会话开启，并更新 secret `TESTLAB_SUB_URL`（这个值不能出现在日志里）。真机全部通过之前，APK 不转正，服务端也先不配 `files.android`。
4. **`users` 场景**：还剩「第二个账户有自己的端口」，看 `users.ps1` 的端口归属诊断结果再判断。
5. **C-12**：macOS 网络监听和唤醒监听是桩实现。不发 macOS 版，暂缓。
6. **功能计划**：见 `ROADMAP.md`。界面打磨见 `DESIGN.md`，以它顶部的说明为准：外观以 1.0.27 为准，只抠细节。
7. **清理**：删掉第 3 节里标了可以删的分支；清掉不用的 arb 文案（`disclaimerAcknowledgeTitle`、`disclaimerAcknowledgeTip`）。

## 8. 不能做的事

- **不在本机安装或运行发布版客户端**。它会接管代理软件、关掉用户自己的 FlClash。本机只构建；升级、共存测试只在 GitHub Actions 里跑。
- **不轮换、不重新生成更新签名密钥**，也不提交、打印、移动私钥文件（更新签名私钥和安卓 keystore 及其密码文件都在本机密钥目录里，只通过 GitHub secrets 使用）。
- **提交里不写 `Co-Authored-By`**，提交信息和 CI 日志里不出现本机路径、用户名、邮箱、主机名。
- CI 日志和提交里不出现服务器 IP、密钥、密码。
- 不提交 `core/Clash.Meta`（子模块，本地总显示有改动，忽略它）。
- 不改已推送的历史；不碰用户自己的正式服务器。测试只能用唯一那台测试服务器，地址和密钥只写在用户电脑上的本地文件 `C:\Users\<user>\.claude\CLAUDE.md`（测试服务器一节；本机文件，外部 Agent 看不到）里，仓库里一律不写；改它之前先 `sudo vps2vpn backup` 并告诉管理员会话。
- 不关闭、不改动用户电脑上的 FlClash 和系统代理（用户靠它上网）。
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

## 10. 耦合自查表（客户端与服务端，2026-11-24）

用户原话："有的人用的不是这个服务端，有的人用的就是"，"你这完全就是把两个死死地绑定在一起"。

归类说明：
- **客户端自己的**：不依赖我们的服务端，任何订阅、甚至没有订阅都要能用。
- **服务端增强**：有我们的面板时更好，没有时退回通用做法，不报错、不留空白、不误导。
- **仅 vps2vpn**：只对我们的订阅有意义，别的情况下整块不出现。

"是不是我们的订阅"怎么判断：链接形如 `/s/<token>` **并且** 本地订阅文件第一行是服务端写的 `# vps2vpn …`，或者面板确实回了会员信息（`panel.dart` 的 `vpsProfileFromPanel`、`vpsPanelAnswer`，07df53db 起）。只看链接形状会把别家同形状的链接当成我们的。

| 功能（代码位置） | 归类 | 我们的订阅 | 别家订阅 / 普通 Clash | 没订阅或本地文件 | 处理 |
|---|---|---|---|---|---|
| 客户端更新（`auto_update.dart`，设置页"版本与更新"卡） | 客户端自己的 | 先查 GitHub Releases，面板 `client` 字段作镜像，取验签通过的最高版本 | 只查 GitHub | 只查 GitHub | 已修 409b27a5：卡片一直显示当前版本、上次检查时间、结果和"检查更新"；失败写明原因，30 分钟后重试；b806b5d1：失败后一连上就 20 秒内重查 |
| 更新签名校验（`update_signing.dart`） | 客户端自己的 | 公钥内置 | 同左 | 同左 | 不依赖服务端 |
| 设置页账户卡（`account.dart` `VpsAccountCard`） | 仅 vps2vpn | 用量、到期、降速、会员中心按钮 | 不显示；额度和到期在订阅卡上（来自订阅头） | 不显示 | 07df53db：形似我们链接的别家订阅不再显示"服务不可用"或"链接已更换" |
| 首页账户状态（`home.dart` 359、`shell.dart` 245：停用、超额、链接已更换） | 仅 vps2vpn | 红色状态和处理办法 | 不出现 | 不出现 | 07df53db：之前别家 `/s/<token>` 链接会被判成"订阅链接已更换"，首页变红 |
| 首页剩余流量、到期磁贴（`home.dart` 980 起） | 服务端增强 | 面板实时数据 | 订阅头 `Subscription-Userinfo` | 不显示这两块 | 本来就对，作为参照写法 |
| 首页订阅公告（`subscription_notice.dart`） | 客户端自己的 | 订阅头 `Announce` | 同左 | 不显示 | 通用；和面板实时数据的矛盾见 LOGIC_REVIEW 第 4 条 |
| 检测页"服务器视角"（`account.dart` `VpsServerAiCard`） | 仅 vps2vpn | 显示服务器自己看到的 AI 网站结果 | 隐藏 | 隐藏 | 没数据整块不画 |
| Claude 检测（`claude_check.dart`） | 客户端自己的 | 按 Core 规则问 claude.ai、api.anthropic.com 的出口 | 同左 | 未连接时提示先连接 | 不看分组名；之前拿通用出口判断的问题已修 |
| AI 网站、网站测试、出口体检、网络诊断（`check.dart`、`site_test.dart`、`exit_check.dart`、`diagnose.dart`） | 客户端自己的 | 通用 | 通用 | 通用 | 不依赖服务端 |
| "智能线路""AI 专线"友好名（`home.dart` 85、`servers.dart`、`tray_menu.dart`） | 仅 vps2vpn（无害） | 显示成"智能线路""AI 专线"，不猜国旗 | 分组名原样显示 | 同左 | 只在分组名完全相同时生效 |
| 主分组（`home.dart` `mainGroup`） | 客户端自己的 | 第一个可见的 Selector | 同左 | 同左 | 不看名字 |
| 线路监控扫描（`panel.dart` `vpsCollectWatchedLines`） | 客户端自己的 | 有智能线路时扫它列出的每个组（C11-01） | 扫主分组 | — | 已修 C11-01 |
| 线路故障上报（`/api/report`，`vpsLineWatchProvider`） | 仅 vps2vpn | 上报 | 不扫、不报 | 不报 | 07df53db：形似我们链接的别家订阅也不再向它的主机发 `/api/report` |
| 面板证书 pin（`x-vps2vpn-pin`、订阅里的 pin） | 仅 vps2vpn | 只用于访问面板 | 不用 | 不用 | — |
| 剪贴板自动提示导入（`clipboard_import.dart`） | 客户端自己的 | 提示 | 提示（V2Board、SSPanel、订阅转换、`.yaml` 等形状） | — | 已修 03365648：之前只认我们的链接 |
| 会员中心地址导入（`vpsSubscriptionLink`） | 仅 vps2vpn | 会员中心地址换成订阅链接 | 原样导入 | — | — |
| 崩溃重启、接管、系统代理还原、开机自启 | 客户端自己的 | 通用 | 通用 | 通用 | 不依赖服务端 |
| 文案里的"管理员" | — | 按 `.agents/wording.md`，管理员 = 发链接的人 | 改掉了两处只在我们服务端成立的说法 | — | c08d1c1d：签名被拒不再让管理员往面板放 `.sig`；空首页不再说"管理员发给你的链接" |
| 第二期：一键反馈（`feedback.dart`）、设备管理（`devices.dart`）、节点状态（`node_status.dart`）、订阅变更（`config_version`，`stale_refresh.dart`） | 仅 vps2vpn | 1.0.31 起：面板 `/api/me` 的 `features.feedback`、`features.devices`、`features.node_status` 打开时才出现；`config_version` 变了就静默重拉订阅 | 反馈入口改成"复制诊断信息"，其余整块不显示，不报错 | 整块不显示 | 设备"移除"是软踢（只断开、标"已被账号主人移除"，不删订阅）；"踢掉其他所有设备"是服务端换新链接，本机先换上新链接再下载，失败可重试。流量排行还没做 |

## 11. 业务逻辑审查

表在仓库根目录 [`LOGIC_REVIEW.md`](LOGIC_REVIEW.md) 第六节（2026-11-24）。严重项跟 1.0.29 一起发，不严重的排进 1.0.30。
