<div align="center">

<img src="assets/images/icon.png" alt="vps2vpn" width="88">

# vps2vpn 客户端

把你自己的 VPS 变成一条好用的私人 VPN。打开、连接，就这么简单。

**简体中文** · [English](#english)

[![Release](https://img.shields.io/github/v/release/xydadada/vps2vpn-client?style=flat-square&label=release)](https://github.com/xydadada/vps2vpn-client/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square)

[下载](#下载) · [功能](#功能) · [常见问题](#常见问题) · [从源码构建](#从源码构建)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/vps2vpn/home-dark.png">
    <img alt="vps2vpn 主界面" src="snapshots/vps2vpn/home-light.png" width="88%">
  </picture>
</p>

## 下载

到 [Releases](https://github.com/xydadada/vps2vpn-client/releases/latest) 下载 `vps2vpn-<版本>-windows-amd64-setup.exe`，双击安装即可（Windows 10 / 11，64 位）。

> 安装包目前没有 Windows Authenticode 代码签名，Windows 可能提示“未知发布者”。请从本仓库的 Releases 获取安装包。应用内更新另行验证发布文件的 Ed25519 签名，这与 Windows 的发布者认证是两回事。

## 怎么用

1. 打开 vps2vpn，粘贴订阅链接。可以用 [vps2vpn 服务端](https://github.com/xydadada/vps2vpn) 提供的订阅，也可以用其他机场的 Clash / mihomo 订阅。
2. 点首页的大电源按钮连接。
3. 完成。默认就是最省心的设置，不需要改任何东西。

## 功能

- **简洁模式（默认）**：概览 / 节点 / 检测 / Claude / 设置 五个页面，深色和浅色两套主题，宽窗口侧边栏、窄窗口底部导航。
- **高级模式**：设置里一个开关，打开后能看到完整的 Clash 功能（规则、连接、日志、配置等）。
- **智能线路**：同一台服务器的多种协议（REALITY / Hysteria2 / TUIC）优先互相切换，某个协议被限制时自动换，出口 IP 不变；整台服务器不可用时才换服务器。
- **AI 专线**：Claude、ChatGPT、Gemini 等固定走主服务器，避免频繁换 IP 被风控。订阅自带规则时以订阅为准。
- **一键接管（Windows）**：连接时列出检测到的其他代理软件（Clash 系列、v2rayN 等），经你确认后关闭；可以记住选择，也可以在设置里更改。客户端会避开被占用的本机代理端口，并处理失效的系统代理。
- **账户信息**：设置页显示已用流量、到期时间、停用原因；订阅链接被更换时会提醒你。
- **服务器视角**：检测页显示服务器自己打开 AI 网站的结果，一眼看出是网络问题还是服务器 IP 被封。
- **线路故障自动上报**：连接后每 4 分钟悄悄测一次，连续失败才告诉管理员，恢复后再报一次。
- **自动更新**：启动后检查新版本，每次检查完成后间隔 6 小时再查，检查失败则间隔 30 分钟重试。优先查询 GitHub Releases，配套面板提供镜像；没有订阅也能检查更新。设置里的“自动检查更新”可关闭定时检查。Windows 安装版会在后台下载、校验发布签名，然后提供“安装并重启”；便携版收到提示后手动下载。签名不对或版本不新的安装包一律拒绝。
- **干净卸载**：卸载时清掉残留的系统代理，只删除 vps2vpn 自己的数据，不碰其他软件。

## 配套服务端

vps2vpn 客户端搭配 [vps2vpn 服务端](https://github.com/xydadada/vps2vpn) 使用最好（一键部署、成员管理、流量统计、AI 可用性检测）。普通的 Clash / mihomo 订阅也能直接用，只是没有账户卡片等面板功能。

## 常见问题

**和 FlClash 有什么关系？**
vps2vpn 基于开源项目 [FlClash](https://github.com/chen08209/FlClash) 修改，界面和功能针对“自己的 VPS”重新设计。程序名、数据目录、端口都和 FlClash 分开，可以同时安装。

**连接时会关闭其他代理软件吗？**
Windows 上的“一键接管”会先列出要关闭的软件，请你选择“退出并连接”或“不退出，直接连接”。勾选“记住我的选择”后，下次按该选择处理；也可以在 设置 → 连接时自动接管 中更改。关闭接管后，客户端仍会避开被占用的本机监听端口。其他代理软件继续运行时，仍可能互相争用系统代理。

**虚拟网卡模式弹出管理员授权？**
虚拟网卡（TUN）需要管理员权限，首次使用可能弹出 UAC。默认简洁界面收到授权失败结果时，会关闭 TUN 并启用系统代理；高级模式或上游界面不会自动启用系统代理。授权过程发生异常或其他启动步骤失败时，也不能保证自动切换，请按错误提示处理。

## 从源码构建

在 Windows 构建主机上准备 Flutter 3.50.0、Go 1.27.4、通过 rustup 安装的 Rust（项目固定为 1.99.0）和 Inno Setup 6。完整工具链与验证命令见[开发命令](.agents/commands.md)。

```bash
git clone --branch vps2vpn --recurse-submodules https://github.com/xydadada/vps2vpn-client.git
cd vps2vpn-client
flutter pub get
dart tool/package.dart windows --env stable
```

安装包输出在 `dist/`。只跑测试：`flutter test test/vps2vpn`。

## 许可与致谢

本项目以 [GPL-3.0](LICENSE) 发布。

- [FlClash](https://github.com/chen08209/FlClash)，作者 chen08209，GPL-3.0
- [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo)，GPL-3.0

第三方许可全文随安装包附在 `data\legal` 目录。

---

## English

**vps2vpn** turns your own VPS into a simple private VPN. It is a Windows client built on [FlClash](https://github.com/chen08209/FlClash) and the [mihomo](https://github.com/MetaCubeX/mihomo) core.

### Download and use

Download `vps2vpn-<version>-windows-amd64-setup.exe` from [Releases](https://github.com/xydadada/vps2vpn-client/releases/latest) for 64-bit Windows 10 or 11.

> The installer currently has no Windows Authenticode code signature, so Windows may show “Unknown publisher.” Get it from this repository's Releases. In-app updates separately verify an Ed25519 release-file signature; that is distinct from Windows publisher authentication.

1. Open vps2vpn and paste a subscription link from the [vps2vpn server](https://github.com/xydadada/vps2vpn) or another Clash / mihomo subscription provider.
2. Click the large Connect button.
3. The default settings are ready to use.

### Features

- **Simple by default.** Five pages (Overview, Nodes, Check, Claude, Settings), dark and light themes, a sidebar in wide windows and bottom navigation in narrow ones.
- **Advanced mode.** Turn it on in Settings to show the full Clash pages, including rules, connections, logs and profiles.
- **Smart line.** Fails over between the protocols of one server first (REALITY, Hysteria2, TUIC), so your exit IP stays the same. It moves to another server only when the whole server is down.
- **AI line.** Claude, ChatGPT and Gemini stay pinned to the main server. A subscription's own routing rules take precedence when present.
- **Takeover on Windows.** On connect it lists other proxy apps it detects and asks before closing them. You can remember the choice and change it in Settings. The client also moves off busy local proxy ports and handles stale system proxies.
- **Panel features** (with the [vps2vpn server](https://github.com/xydadada/vps2vpn)):
  - account usage, expiry and suspension reasons in Settings, with a notice when the subscription link changes
  - the server's own view of AI sites on the Check page
  - line checks every four minutes while connected, reporting repeated failures and recovery to the administrator
- **Automatic updates.** The app checks after startup, then schedules the next check six hours after completion, or 30 minutes after a failed check. GitHub Releases is checked first, with the panel as a mirror; updates work with any subscription or none. Turn off “Check for updates automatically” in Settings to disable scheduled checks. An installed Windows copy downloads a newer version in the background, verifies its release signature and offers “Install & restart.” A portable copy prompts you to download manually. Invalid signatures and versions that are not newer are refused.
- **Clean uninstall.** It clears its system proxy and removes only its own data.

Ordinary Clash / mihomo subscriptions work directly; panel-specific features such as the account card require the companion server.

### Frequently asked questions

**How does this relate to FlClash?**
vps2vpn is a fork of FlClash, with an interface and features designed around your own VPS. Its application name, data directory and ports are separate, so both can be installed.

**Will connecting close my other proxy apps?**
On Windows, Takeover lists the apps and offers “Quit and connect” or “Connect anyway.” If you choose to remember the answer, later connections follow it. Change this under Settings → Take over on Connect. Turning Takeover off still lets the client avoid a busy local listening port; other running proxy apps may still compete for the system proxy.

**Why does TUN ask for administrator permission?**
TUN needs administrator rights and may show a UAC prompt on first use. In the default simple interface, a failed authorization result disables TUN and enables the system proxy. Advanced mode and the upstream interface do not automatically enable the system proxy. Exceptions during authorization or failures elsewhere in startup do not guarantee an automatic switch; follow the reported error.

### Build from source

Use a Windows build host with Flutter 3.50.0, Go 1.27.4, Rust installed through rustup (pinned to 1.99.0 by this project), and Inno Setup 6. See the [development commands](.agents/commands.md) for the complete toolchain and validation steps.

```bash
git clone --branch vps2vpn --recurse-submodules https://github.com/xydadada/vps2vpn-client.git
cd vps2vpn-client
flutter pub get
dart tool/package.dart windows --env stable
```

Packages land in `dist/`. Run the client tests with `flutter test test/vps2vpn`.

The project is licensed under [GPL-3.0](LICENSE). Third-party license texts ship under `data\legal` in the installed app.
