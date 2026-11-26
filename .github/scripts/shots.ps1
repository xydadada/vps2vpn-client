# Installs a vps2vpn build and lets it photograph its own pages
# (lib/vps2vpn/screenshots.dart): empty, ready and connected, light and dark,
# Chinese and English, three window sizes. CI only.
param([Parameter(Mandatory)][string]$Setup, [string]$Out = 'shots')
. (Join-Path $PSScriptRoot 'harsh/lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$pics = Join-Path $Out 'pages'

try {
  Start-Upstream $Out
  # The panel's shape (Chinese group names, Hysteria2, VLESS REALITY and TUIC
  # lines, a per-server fallback, a x2 server), each line served by an inbound
  # of the app's own Core that sends it straight out. Test keys, loopback only.
  $uuid = '6f3b2c1e-8d4a-4b7e-9c2f-1a5e7d9b3c40'
  $reality = "servername: www.microsoft.com, client-fingerprint: chrome, reality-opts: {public-key: 9Rx_b6KSKRiopPHxSmB0N5Q2tQb0eX2ICnP_2f3XVVE, short-id: 5a1f}"
  $servers = @(
    @{ label = '日本'; base = 24410 },
    @{ label = '美国 ×2'; base = 24420 },
    @{ label = '新加坡'; base = 24430 }
  )
  $proxies = @(); $listeners = @(); $fallbacks = @(); $lines = @(); $labels = @()
  foreach ($s in $servers) {
    $hy2, $vless, $tuic = $s.base, ($s.base + 1), ($s.base + 2)
    $names = "$($s.label) Hysteria2", "$($s.label) Reality", "$($s.label) TUIC"
    $proxies += "  - {name: '$($names[0])', type: hysteria2, server: 127.0.0.1, port: $hy2, password: shots, sni: localhost, skip-cert-verify: true, alpn: [h3]}"
    $proxies += "  - {name: '$($names[1])', type: vless, server: 127.0.0.1, port: $vless, uuid: $uuid, network: tcp, udp: true, tls: true, $reality}"
    $proxies += "  - {name: '$($names[2])', type: tuic, server: 127.0.0.1, port: $tuic, uuid: $uuid, password: shots, sni: localhost, skip-cert-verify: true, alpn: [h3]}"
    $listeners += "  - {name: in-$hy2, type: hysteria2, listen: 127.0.0.1, port: $hy2, proxy: DIRECT, users: {shots: shots}, alpn: [h3]}"
    $listeners += "  - {name: in-$vless, type: vless, listen: 127.0.0.1, port: $vless, proxy: DIRECT, users: [{username: shots, uuid: $uuid}], reality-config: {dest: 'www.microsoft.com:443', private-key: OPjIAFeak2MQLqOlnr_JxtXRQ5hNPeR-7npvsRoXRns, short-id: [5a1f], server-names: [www.microsoft.com]}}"
    $listeners += "  - {name: in-$tuic, type: tuic, listen: 127.0.0.1, port: $tuic, proxy: DIRECT, users: {$($uuid): shots}, alpn: [h3]}"
    $fallbacks += "  - {name: '$($s.label)', type: fallback, proxies: ['$($names -join "', '")'], url: 'https://www.gstatic.com/generate_204', interval: 300, lazy: true}"
    $lines += $names; $labels += $s.label
  }
  $all = "'" + ($lines -join "', '") + "'"
  $each = "'" + ($labels -join "', '") + "'"
  Write-Subscription 'sub.yaml' @"
mixed-port: 7890
mode: rule
proxies:
$($proxies -join "`n")
listeners:
$($listeners -join "`n")
proxy-groups:
  - {name: 节点选择, type: select, proxies: [自动选择, $each, $all]}
  - {name: 自动选择, type: url-test, proxies: [$each], url: 'https://www.gstatic.com/generate_204', interval: 300, lazy: true, tolerance: 80}
$($fallbacks -join "`n")
  - {name: AI服务, type: select, proxies: [$each, 节点选择, $all]}
  - {name: 国内服务, type: select, proxies: [DIRECT, 节点选择]}
  - {name: 漏网之鱼, type: select, proxies: [节点选择, DIRECT]}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,漏网之鱼
"@
  # A third-party panel's names: lower-case codes, cities, rates as "5.0x".
  $legend = 'us 洛杉矶 · 5.0x', 'us 圣何塞 · 1x', 'jp 东京 · 1.0x', 'hk 香港 · 1x', 'sg 新加坡 · 0.5x', 'tw 台北 · 2.0x', 'kr 首尔 · 1.5x'
  $legendLines = foreach ($n in $legend) { "  - {name: '$n', type: http, server: 127.0.0.1, port: $($script:upstreamPort)}" }
  Write-Subscription 'legend.yaml' @"
mixed-port: 7890
mode: rule
proxies:
$($legendLines -join "`n")
proxy-groups:
  - {name: 🚀 节点选择, type: select, proxies: [♻️ 自动选择, '$($legend -join "', '")']}
  - {name: ♻️ 自动选择, type: url-test, proxies: ['$($legend -join "', '")'], url: 'https://www.gstatic.com/generate_204', interval: 300}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,🚀 节点选择
"@
  Install-App $Setup $Out
  $env:FLCLASH_ACCEPT_DISCLAIMER = '1'
  $env:VPS2VPN_SHOT_DIR = $pics
  $env:VPS2VPN_SHOT_SUB = "http://127.0.0.1:$($script:subPort)/sub.yaml"
  $app = Start-Process $script:exe -PassThru
  Check ($app.WaitForExit(15 * 60 * 1000)) 'vps2vpn photographed its pages and quit within 15 minutes'
  $count = @(Get-ChildItem $pics -Filter '*.png' -ErrorAction SilentlyContinue).Count
  Check ($count -ge 60) "pages photographed: $count"
  if (Test-Path (Join-Path $pics 'shots.log')) { Get-Content (Join-Path $pics 'shots.log') | Select-Object -Last 15 }
} finally {
  Stop-App
  Finish
}
