# 构建、打包、桌面入口与测试门禁补充审计

日期：2026-11-20。对应 [客户端 PR #2](https://github.com/xydadada/vps2vpn-client/pull/2)，关联 [服务端 PR #1](https://github.com/xydadada/vps2vpn/pull/1)。本次在原 PR 提交 `536aff4ac3e5859a5838009787c89c4fd1abe06c` 上继续工作，并整合默认分支 `e26f1418163735c04381836c79ef7a87e4463e12`（1.0.1）。

## 范围及证据边界

本报告覆盖实际通读的打包器、发布清单、测试调度器、插件检查脚本、CI 工作流、Windows/Linux 桌面入口、Inno 安装器和 macOS 核心文件复制配置。审查同时对照真实构建日志、调用方生成的文件名和各平台的文件/进程语义。生成代码通过项目生成器生成，不手改产物。子模块使用原固定提交；对核心的已确认竞态使用版本校验补丁，不把整个第三方项目称为逐行审计完成。

默认分支在审计期间另有更新。下表明确区分此次补充与新默认分支已经解决的重叠问题；合并时保留新版本号、按服务器线路报告、回归用例和原生修复。源代码阅读、检查工具通过、构建通过和真实系统行为是不同层级的证据。

## 问题清单及实际处理

| ID | 位置 | 原因、影响及修复 |
| --- | --- | --- |
| T01 | `tool/test.dart:_writeBundles` | 打包后的测试入口位于 `.dart_tool/test_bundles`，不在原 `test/` 配置的发现范围内，因此没有执行设置上游 UI 测试模式的 `testExecutable`。同一个用例单独运行和全套运行出现不同产品行为。现在在实际入口目录生成一个重新导出原 `flutter_test_config.dart` 的配置文件，共用原有初始化逻辑。 |
| T02 | `linux/CMakeLists.txt`、`macos/Runner.xcodeproj/project.pbxproj` | Native build hook 产物已经叫 `vps2vpnCore` / `vps2vpnHelperService`，安装和 macOS 复制阶段仍找 `FlClashCore` 等旧名字，导致构建或发布缺文件。修正文件引用、复制阶段、输入输出路径及安装路径；不把保留的上游 UI 名称当作要全局替换的字符串。 |
| T03 | `tool/src/package/manifest.dart` | 合并下载产物清单时直接把 `name` 拼成输入和输出路径。恶意或损坏清单可用 `../`、绝对路径、Windows 分隔符越出目标目录，也能覆盖清单自身；原逻辑只检查 SHA，没有检查声明大小。现在限制为安全单文件名，拒绝保留文件名、末尾点、大小写冲突和重复项；检查非负大小、标准 SHA-256 和实际大小。回归保留目录外哨兵文件，并覆盖两种路径分隔符、绝对路径、大小写、换行及有效 SHA/错误大小。 |
| T04 | `tool/src/package/linux.dart:rpmSpec/appImageDesktopEntry` | RPM 把图标设为 `4755`，错误授予执行及 setuid 位；改为 `0644`。Desktop Entry 的 Exec 使用 shell 环境赋值语法，桌面启动器不能按 shell 解释；新默认分支也修复了此项，整合时保留。Categories/Keywords 使用合法的分号结尾列表；已有 AppRun 继续负责库路径。使用真实生成的 `.desktop` 通过 `desktop-file-validate`。 |
| T05 | `windows/runner/utils.cpp:Utf8FromUtf16`、`windows/runner/flutter_window.cpp` | 无效 UTF-16 使 Win32 长度查询返回 0，原先无符号减 1 可变成约 4 GiB 分配。新默认分支已经增加返回值保护；本次进一步统一两次转换的含终止符长度，并检查完整转换长度。新增直接编译生产 `utils.cpp` 的 CTest，覆盖空指针、空串、孤立代理项、错误配对、中文、emoji 和长命令行。窗口控制器为空时的字体消息保护保留新默认分支修复。 |
| T06 | `windows/packaging/exe/inno_setup.iss:[Run]` | 安装器正常 UAC 提权后以 `runascurrentuser` 重启应用，应用继承管理员权限。两条启动路径改为 `runasoriginaluser`；新默认分支恰好也包含此修复，最终只保留一套实现。用户主动从已提升进程启动安装器时，Inno 无法恢复不存在的原始非提升令牌；不宣称解决这个系统边界。 |
| T07 | `.github/workflows/e2e.yaml`、`.github/scripts/takeover-e2e.ps1` | 手动输入 tag 直接内插进 PowerShell 源码，含引号的合法输入可能破坏命令。改为环境变量和独立参数，并检查下载退出码及恰好一个安装器。卸载验收原来只匹配两个固定端口，实际移到其他端口后可能假通过；现在先确认系统代理指向实际活动端口，再验收该端点清理。测试进程清理限制安装目录，并释放截图 GDI 资源。默认分支的“观察实际代理”修复与更严格端点校验已整合。 |
| T08 | `tool/check_plugins.sh` | 原来只发现 `test/*_test.dart`，`prism_ui` 的实际测试都在 `test/common`、`test/widgets`，会被输出为“no tests”并全部漏跑。改为递归发现，保留纯 Dart setup_hooks 的独立入口；临时测试项目验证平铺、嵌套和空目录的调度。完整插件用例交由真实 Flutter 执行，不把调度测试当成插件通过。 |
| T09 | `windows/CMakeLists.txt` | Debug Helper 复制前的 PowerShell 路径放进单引号字面量，工程路径包含单引号时语法错误，旧 Helper 仍占用目标 exe。现在在生成脚本前按 PowerShell 字面量规则转义路径，保持按完整文件路径筛选。 |
| T10 | `.github/workflows/audit-checks.yaml`、`verify.yaml` | 旧 PR 红灯包含真实编译失败、锁文件差异和代码生成漂移，不能仅凭 Go 单测宣称客户端完成。保留格式、锁文件、生成代码和分析差异门禁，增加 Windows C++ 边界测试及 Windows/macOS 完整 release 构建；Windows 包含安装、接管及卸载验收。合入的新 verify 工作流补齐证书 bundle 校验、同一核心补丁、Linux libsecret 依赖及纯测试的 setup hook 配置，保留所有原检查；仅限制 push 为默认分支以免一次 PR 更新再触发重复 push 检查。覆盖率上传遇到账号存储限制不会掩盖已执行测试结果。 |
| T11 | `plugins/rust_api/hook/libclang.dart`、`hook/build.dart`、Android CI | 真实 Android 构建提供的 NDK 27.3 编译器目录没有 bindgen 所需 libclang，尽管主机已安装该库，hook 仍直接失败。优先选 NDK 自带库；缺失时仅使用明确配置且存在的宿主 `LIBCLANG_PATH`，不替换 NDK 编译器、目标或 sysroot。CI 安装并定位宿主库；回归使用真实目录分别检查 NDK、后备和失败分支。 |

## 设计取舍

发布清单校验位于读取和写入边界，合并仍保留原有 SHA-256 校验和平台产物命名。它限制清单里的路径及一致性，并不提供对不可信发布者的签名认证，也不将整个多文件合并变成跨进程事务。

独立 Windows C++ 测试仅替代 Flutter 输出流同步的链接符号；UTF-16 转换执行真实 Win32 API 与生产实现。完整 Windows Flutter 构建另有门禁，因此不以这个小测试代替完整应用链接和运行验收。

CI 的生成/单元检查允许关闭 Go setup hook，保留需要的 Rust 桥；Linux、Windows、macOS release 和 Android APK 构建使用正常 native hooks。测试模式修改只发生在 CI 工作副本，提交的 `pubspec.yaml` 两项 `build_assets` 都保持 `true`。

## 已执行验证与接下来的证据位置

本地已实际执行：两套 Git hook 回归、PowerShell 解析、三个工作流 YAML 解析、AppImage Desktop Entry 验证、插件递归调度回归、diff 空白检查。具体 Flutter、Go、Rust、Android 及桌面结果统一记录在最终 [总报告](2026-11-20.md) 和 PR 描述中，并绑定对应提交/Actions run；本文件的测试方案不是通过声明。

当前 Linux 执行容器禁止部分 socket/netlink 系统调用，不能用本地编译或 mock 宣称真实 Windows 权限、macOS 授权、Android VPN/TUN、睡眠恢复和用户网络切换已经验收。远端隔离 runner 的安装验收也不能替代所有用户系统版本。

## 原始依据

- [Microsoft WideCharToMultiByte](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-widechartomultibyte)：错误返回 0，查询长度包含终止符的条件及无效 UTF-16 行为。
- [Desktop Entry Exec 规范](https://specifications.freedesktop.org/desktop-entry/1.4/exec-variables.html) 与 [完整规范](https://specifications.freedesktop.org/desktop-entry/latest-single/)：可执行文件及列表字段语法。
- [Inno Setup Run flags](https://jrsoftware.org/inno-setup/documentation/topic_runsection.htm)：当前/原始用户令牌的区别及从已提升进程启动时的边界。
- [GitHub runner images](https://github.com/actions/runner-images/blob/main/README.md)：使用仍受支持的 Windows 2022 与 macOS 15，未套用已退役的 macOS 14。
- [完整可审查 Git Diff](https://github.com/xydadada/vps2vpn-client/pull/2/files)。
