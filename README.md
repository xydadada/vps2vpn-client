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

> 安装包暂未做代码签名，Windows 可能提示“未知发布者”。点“更多信息 → 仍要运行”即可。

## 怎么用

1. 打开 vps2vpn，粘贴你的订阅链接（服务器管理员给你的，形如 `https://你的服务器/s/xxxx`）。
2. 点中间的大按钮连接。
3. 完成。默认就是最省心的设置，不需要改任何东西。

## 功能

- **简洁模式（默认）**：只有 概览 / 节点 / 检测 / 设置 四个页面，深色和浅色两套主题，宽窗口侧边栏、窄窗口底部导航。
- **高级模式**：设置里一个开关，打开后能看到完整的 Clash 功能（规则、连接、日志、配置等）。
- **智能线路**：同一台服务器的多种协议（REALITY / Hysteria2 / TUIC）优先互相切换，某个协议被限制时自动换，出口 IP 不变；整台服务器不可用时才换服务器。
- **AI 专线**：Claude、ChatGPT、Gemini 等固定走主服务器，避免频繁换 IP 被风控。订阅自带规则时以订阅为准。
- **一键接管**：连接时自动关闭其他代理软件（Clash 系列、v2rayN 等），端口被占自动换，清理失效的系统代理。设置里可以关掉。
- **账户信息**：设置页显示已用流量、到期时间、停用原因；订阅链接被更换时会提醒你。
- **服务器视角**：检测页显示服务器自己打开 AI 网站的结果，一眼看出是网络问题还是服务器 IP 被封。
- **线路故障自动上报**：连接后每 4 分钟悄悄测一次，连续失败才告诉管理员，恢复后再报一次。
- **自动更新**：启动后和每 6 小时向面板检查一次新版本（设置里“检查更新”可关）。安装版会在后台下载、校验发布签名，然后一键“安装并重启”；便携版保留手动下载。签名不对或版本不新的安装包一律拒绝。
- **干净卸载**：卸载时清掉残留的系统代理，只删除 vps2vpn 自己的数据，不碰其他软件。

## 配套服务端

vps2vpn 客户端搭配 [vps2vpn 服务端](https://github.com/xydadada/vps2vpn) 使用最好（一键部署、成员管理、流量统计、AI 可用性检测）。普通的 Clash / mihomo 订阅也能直接用，只是没有账户卡片等面板功能。

## 常见问题

**和 FlClash 有什么关系？**
vps2vpn 基于开源项目 [FlClash](https://github.com/chen08209/FlClash) 修改，界面和功能针对“自己的 VPS”重新设计。程序名、数据目录、端口都和 FlClash 分开，可以同时安装。

**为什么连接时把我的其他代理软件关了？**
两个代理软件同时抢系统代理会互相打架，表现为“已连接但上不了网”。这是“一键接管”功能，在 设置 里可以关闭。

**虚拟网卡模式弹出管理员授权？**
虚拟网卡（TUN）需要管理员权限，首次使用会弹 UAC。拒绝的话会自动退回系统代理模式。

## 从源码构建

需要 Flutter 3.50、Go 1.27、Rust 和 Inno Setup 6。

```bash
git clone --recurse-submodules https://github.com/xydadada/vps2vpn-client.git
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

- **Simple by default.** Four pages (Overview, Nodes, Check, Settings), dark and light themes. Advanced mode brings back every Clash page.
- **Smart line.** Fails over between the protocols of one server first (REALITY, Hysteria2, TUIC), so your exit IP stays the same. It moves to another server only when the whole server is down.
- **AI line.** Claude, ChatGPT and Gemini stay pinned to the main server.
- **Takeover.** On connect it closes other proxy apps, moves off busy ports and clears stale system proxies. You can turn this off in Settings.
- **Panel features** (with the [vps2vpn server](https://github.com/xydadada/vps2vpn)):
  - account usage and expiry
  - the server's own view of the AI sites
  - automatic line-failure reports
  - updates: the installed app downloads a newer version in the background, checks its release signature and installs it with one tap ("Install & restart")
- **Clean uninstall.** It clears its system proxy and removes only its own data.

Download the installer from [Releases](https://github.com/xydadada/vps2vpn-client/releases/latest). The project is licensed under GPL-3.0.
