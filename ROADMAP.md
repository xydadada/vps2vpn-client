# 功能计划：出口检测、Claude 检测和网络工具（2026-11-23 用户定）

这份文档记下用户 2026-11-23 定的新功能范围，换 Agent 时从这里接着做。
原则：**能用就行，不求严谨**；结果只写结论（哪里有问题），不写长篇解读。
（本文件在仓库根目录 `ROADMAP.md`；`docs/` 目录被 .gitignore 忽略，不要放那里。）
做完一项就在本文件里把它标成"已完成（版本号）"，并在 `HANDOFF.md` 第 7 节同步。

## 〇、界面（先于第一节）

- **订阅导入输入框**（2026-11-23 用户要求，UI 第一批）：首页（还没有订阅时）和设置页"导入订阅"都有一个输入框，可以粘贴或手动输入链接，点"导入"才导入。
  - 剪贴板只用来填框："从剪贴板粘贴"按钮或首页圆环按钮在框空着时把链接填进框里，**绝不自动导入**；
  - 输入不对时，原因直接写在框下面（空的、有空格或多个链接、不是 http(s) 开头、不是订阅链接）；
  - 框最多显示 4 行并自动换行，长链接完整可见、不截断；
  - 代码在 `lib/vps2vpn/clipboard_import.dart` 的 `VpsImportField`。
- **语言只留中文和英文**（UI 第二批）：选项只有"跟随系统 / 中文 / English"，其他系统语言显示英文；以前选了俄、日、西、法、韩语的用户升级后变成"跟随系统"。

## 一、要做的

### 1. 出口 IP 检测（放在现有"检测"页 `lib/vps2vpn/check.dart`）

> 进度（2026-11-24）：已写好，待发布——体检结论和"复制结果"、IP 类型（家宽 / 机房 / 被标记为代理）、IPv6 出口和泄漏、DNS（edns.ip-api.com）、时区和系统语言对比，代码在 `lib/vps2vpn/exit_check.dart`，连接后在"检测"页最上面显示。还没做：服务可用性扩充（要在 `core/service_check.go` 加探测、在 `assets/images/services/` 加图标）。

- **出口 IP**：分别显示 IPv4、IPv6 的出口地址、国家城市和运营商（ASN）。现有 `lib/common/service_probe.dart` 已经有 8 个查 IP 的源，接着用。
- **IP 质量 / 纯净度**：用免费、不用注册 key 的数据源，具体接口见第五节"借鉴的做法"。只显示结论，例如"机房 IP""家宽 IP""被标记为代理"。一个源失败就换下一个，全失败就显示"查不到"，不报错。
- **环境一致性**：把本机情况和出口国家对比，有问题的标红或标黄，没问题的标绿：
  - Windows 系统时区；
  - 系统显示语言、区域格式；
  - 输入法或键盘布局（可选）。
  规则从简：时区和出口国家对不上标红；语言对不上标黄（很多人本来就用中文系统）。
- **泄漏检测（简单做）**：
  - IPv6：本机有公网 IPv6，但 IPv6 的出口不是节点（直连出去了）→ 标红；
  - DNS：粗略判断就行，比如看解析是否走了核心的 DNS；
  - WebRTC 不做（要浏览器配合）。
- **服务可用性扩充**：现有 Claude、ChatGPT、Gemini、Google、GitHub、YouTube、Discord、Netflix、Disney+、Prime Video、Spotify、TikTok、Bilibili。可以加：
  - AI：Claude API（`api.anthropic.com`）、Perplexity、Grok、Copilot；
  - 其他：Instagram、X、PayPal、Steam。
- **体检报告**：页面最上面一行总结，只列有问题的项，例如"2 项有问题：时区和出口国家不一致；IPv6 直连"。全部正常就写"一切正常"。可以加一个"复制结果"按钮，复制时把 IP 的最后一段打码。

### 2. Claude 专项检测（简易模式侧边栏单独一项）

> 进度（2026-11-24）：已写好，待发布——侧边栏第 4 项"Claude"（`lib/vps2vpn/claude_check.dart`）：Claude 能否打开、出口地区、claude.ai 和 api.anthropic.com 的 Cloudflare 出口是否一致、终端代理是否指向本软件，再加上第 1 项的 IP 类型、IPv6、DNS、时区和语言。域名出口用 `cdn-cgi/trace` 比对，而不是读核心规则。

- 在简易模式导航（`lib/vps2vpn/simple_mode.dart` 的 `simpleNavigationItems`）加一项"Claude"。
- 内容：
  - Claude 能不能用（已有探测）；
  - 出口国家是不是 Claude 支持的地区；
  - 时区、语言和出口是否一致（复用第 1 项）；
  - IPv6 泄漏（复用第 1 项）；
  - 机房 IP 还是家宽（复用第 1 项）；
  - **Claude 相关域名是否都走同一个出口**：`claude.ai`、`api.anthropic.com`、`anthropic.com` 等。用核心的规则匹配查出每个域名会走哪个节点，不一致就标红。这是网页检测站做不到的；
  - 终端代理（Claude Code 用）有没有设好（复用"我的"页里的终端代理功能）。
- 措辞：叫"Claude 环境检查"，不说"防封"。Anthropic 没公开风控规则，我们只检查环境是否一致。

### 3. 网络工具

- **真实测速**：随便接一个测速服务，比如 Cloudflare 的 `speed.cloudflare.com/__down?bytes=` 和 `__up`，经由当前节点测下载、上传速度。只显示两个数字和一句结论。
- **规则测试**：输入一个网址或 IP，显示它会命中哪条规则、走哪个节点（直连 / 代理 / 拒绝）。用户在 (e) 那条里说过"不是很想搞"，但 (a) 里又要了，所以优先级放低，做之前跟用户再确认一次。
- **自定义延迟测试网址**：参考 Clash Verge，在节点页让用户自己选测延迟用的网址。预设几个（gstatic generate_204、Cloudflare、Apple captive），也能手动填。选择要保存下来。
- **流量排行（服务端开关）**：按应用列出实时流量，数据来自核心的连接列表。**只有服务端管理员打开开关后，客户端才显示这一页**，关了就看不到。
  - 服务端：面板设置里加一个开关，通过会员接口 `<sub>/api/`（`web.py` 返回 `quota_eff` 的那个接口）告诉客户端，比如 `"features": {"traffic_rank": true}`。这部分由服务端仓库做，服务端 HANDOFF 有对应待办。
  - 客户端：读这个字段决定显示与否；读不到（老服务端）时默认不显示。

## 二、可选（日常体验，有空再做）

- 托盘菜单直接切换节点和模式（UI 清单第一批里已经在改托盘）；
- 网速悬浮窗；
- 断线自动重连并弹通知；换 Wi-Fi 后自动重连；
- 断网保护（kill switch）：代理断开时不让裸连；
- 流量快用完、快到期时提醒；
- 按应用分流（比如"微信直连、浏览器走代理"）；
- "这个网站走代理 / 直连"输入框（自定义规则）。

## 三、不做的

- 浏览器指纹；
- WebRTC 泄漏；
- DNS 对比（国内外解析对比）；
- 路由追踪（traceroute / MTR，显示数据从你电脑到服务器经过哪些路由器）；
- 节点端口检测。

## 四、注意

- 公开仓库：代码、测试、CI 日志和截图里不能出现真实服务器 IP、订阅链接或 token。示例地址只用 192.0.2.x、198.51.100.x、203.0.113.x、2001:db8::。
- 第三方查询只在用户点"检测"时才发，结果缓存几分钟，不在后台定时查。
- 借鉴开源项目时只借思路，不抄代码。xykt/IPQuality 是 AGPL 许可证，lmc999/RegionRestrictionCheck、vernette/ipregion、jason5ng32/MyIP（MIT）可以参考它们的检测方法。
- 构建和测试只在 CI 跑，本机不装 release 版。每批改动附 CI 截图（UI 清单第 0 项）。

## 五、借鉴的做法（2026-11-23 读过源码，接口都实测过）

参考的项目：lmc999/RegionRestrictionCheck（流媒体/AI 解锁脚本）、xykt/IPQuality（IP 体检脚本）、jason5ng32/MyIP（ipcheck.ing，MIT）、clash-verge-rev。只借方法（查哪个网址、看哪个字段），不抄代码。

- **IP 质量（不用 key）**：
  - 首选 `http://ip-api.com/json/<ip>?fields=status,countryCode,isp,mobile,proxy,hosting`：`hosting=true` 表示机房 IP，`mobile=true` 表示手机网络，`proxy=true` 表示被标成代理。注意免费版只支持 HTTP（HTTPS 返回 403），每分钟 45 次。请求经节点发出，只带出口 IP，可以接受。
  - 备用 `https://proxycheck.io/v2/<ip>?vpn=1&risk=1&asn=1`：`proxy`（yes/no）、`type`（Business、Residential、Hosting、Wireless 等）、`risk`（0–100）。不用 key 时每天额度很少，只在点"检测"时查。
  - ipapi.is 不带 key 时已经不返回 `is_datacenter` 这类字段了，不要用。IPQuality 的风险分来自它作者自己的中转站（`ipinfo.check.place`，后面是付费 key），不要依赖。
- **Claude 实际看到的出口**：`https://claude.ai/cdn-cgi/trace` 和 `https://api.anthropic.com/cdn-cgi/trace` 都能访问，返回 Cloudflare 看到的 `ip=`、`loc=`（国家）、`colo=`。两个地址的 `ip` 不一样，就说明 Claude 的网页和 API 走了不同出口，标红。ChatGPT 同理：`https://chatgpt.com/cdn-cgi/trace`。MyIP 的"规则测试"用的就是这个办法。
- **Claude 能不能用**（RegionRestrictionCheck 的方法）：用浏览器 UA 请求 `https://claude.ai/` 并跟随跳转。最终网址还是 `https://claude.ai/` 表示可用；跳到 `https://www.anthropic.com/app-unavailable-in-region` 表示地区不支持。
- **ChatGPT**（同上）：`https://api.openai.com/compliance/cookie_requirements` 返回里有 `unsupported_country` 表示地区不支持；`https://ios.chat.openai.com/` 返回里有 `VPN` 表示被识别成 VPN。
- **Gemini**（同上）：`https://gemini.google.com` 页面里有 `45631641,null,true` 表示可用。
- **可以顺手加的检测**（同上，都是一个请求就能判断）：
  - Google 搜索要不要验证码：`https://www.google.com/search?q=curl` 返回里有 `unusual traffic from` 就说明 IP 被 Google 当成可疑；
  - Apple 地区：`https://gspe1-ssl.ls.apple.com/pep/gcc` 直接返回国家代码；
  - YouTube CDN：`https://redirector.googlevideo.com/report_mapping` 显示分配到哪个机房；
  - 其他：Google Play 地区、Steam 货币、维基百科能否编辑、Reddit。
- **DNS 泄漏（简单版）**：请求 `http://<随机串>.edns.ip-api.com/json`，返回里的 `dns.ip` 和 `dns.geo` 是替你查域名的那台 DNS 服务器。它在国内、而出口在国外 → 标黄。随机串用来避开缓存。
- **IPv6 泄漏**：现有的 IP 源里分别取 IPv4、IPv6 出口。有 IPv6 出口，但它的国家或运营商和 IPv4 出口不一样（说明 IPv6 没走节点）→ 标红。
- **真实测速**（MyIP 的方法）：下载用 `https://speed.cloudflare.com/__down?bytes=25000000`，上传向 `https://speed.cloudflare.com/__up` POST 数据，各测两三次取中间值。`https://speed.cloudflare.com/cdn-cgi/trace` 的 `colo=` 显示测速机房。MyIP 用 4×50MB 下载、4×15MB 上传，我们用小一点，省流量。
- **规则测试**：对用户输入的网址发一个请求，然后在核心的连接列表里找这个域名，读出它命中的规则和走的节点链。
- **自定义延迟测试网址**（clash-verge-rev 的做法）：
  - 设置里有一个全局"默认延迟测试网址"（`default_latency_test`）；
  - 节点页每个分组的标题栏有一个输入框，可以临时换成别的网址，留空就用全局的；
  - 另有一个"网站测试"页：用户自己添加网站（名字、图标、网址），一键测这些网站经当前节点的延迟。默认放 Apple、GitHub、Google、YouTube。

## 六、第二阶段功能（2026-11-23 用户说"都可以加上"）

第一节做完后接着做这些，按下面的顺序。它们是从 FlClash、clash-verge-rev、Mihomo Party、Hiddify、Karing、Surge/Stash 一类客户端和商业 VPN 里整理出来的。
- 标"需要服务端配合"的，先由服务端会话定接口（字段名写回本文件），客户端再接。服务端交接文档第 3 节有对应待办。
- 最后两项（WARP、抗封锁）改动大，动手前先写一段评估（要改什么、风险、工作量），给用户看过再做。
- 第二节"可选"里和这里重复的项（托盘、悬浮窗、断网保护等）以这里为准，一起做。

- **网络诊断向导**：一键分段检查"本机网络 → DNS → 节点 → 目标网站"，告诉用户断在哪一段，用大白话说怎么办。（它就是给普通人用的路由追踪。）
- **一键反馈**：把体检结果和最近的日志打包，IP 打码后发给服务端面板，管理员能直接看到。需要服务端配合。
- **设备管理**：在客户端里看自己账号有哪些设备在用，可以踢下线（服务端已有 `max_ips`）。需要服务端配合。
- **节点状态下发**：服务端标"维护中 / 拥堵"，客户端节点列表直接显示。需要服务端配合。
- **"最适合 AI 的节点"推荐**：结合 Claude、ChatGPT 检测结果，在节点列表里标出哪个节点能用 AI。
- **系统代理守护**：别的软件改了系统代理，自动改回来（clash-verge-rev 有）。
- **网站测试页**：见第五节，用户自己加网站测延迟。
- **托盘显示网速**、网速悬浮窗（Mihomo Party 有）。
- **轻量模式**：关窗口时连界面一起退出，只留核心，省内存（clash-verge-rev 有）。
- **按 Wi-Fi 自动切换**：连到家里的 Wi-Fi 自动断开或切直连，换成其他网络自动连上（Surge/Shadowrocket 有）。
- **本机流量统计图**：按天、按月看本机用了多少流量。
- **一键断开所有连接**：切换节点后旧连接还走老节点，这时用得上。
- **广告 / 恶意网站拦截**：一个开关，用现成的规则集。
- **二维码**：订阅链接生成二维码，方便手机扫码导入。
- **WARP 叠加出口**：机房 IP 被网站拒绝时，经 Cloudflare WARP 再出去（Hiddify、Karing 有）。改动大，要先评估。
- **抗封锁选项**：TLS 分片等（Hiddify 有）。主要是服务端协议的事，先记下。
