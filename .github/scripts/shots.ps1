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
  # Names in the shape the panel hands out, every line through the CI upstream.
  $lines = foreach ($server in 'JP', 'US', 'SG') {
    foreach ($protocol in 'Reality', 'Hysteria2') {
      "  - {name: '$server · $protocol', type: http, server: 127.0.0.1, port: $($script:upstreamPort)}"
    }
  }
  $names = ($lines | ForEach-Object { ($_ -split "'")[1] }) -join "', '"
  Write-Subscription 'sub.yaml' @"
mixed-port: 7890
mode: rule
proxies:
$($lines -join "`n")
proxy-groups:
  - {name: Proxy, type: select, proxies: ['$names']}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,Proxy
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
