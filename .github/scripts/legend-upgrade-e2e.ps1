# A manual upgrade from a real old release, on a throwaway CI machine: the
# OLD setup (from GitHub) is set up the way a user of a panel-less provider
# had it, then the NEW setup is run silently over it, as a user running it by
# hand does. Settings, the picked node and the subscription must survive; the
# new version must not ask the takeover question again, show no warning or
# dialog, connect through the picked node, and find a newer release on its
# first update check. Never run this on a real PC.
param(
  [Parameter(Mandatory)][string]$Old,
  [Parameter(Mandatory)][string]$New,
  [Parameter(Mandatory)][string]$Tools,
  [string]$Out = 'legend'
)
. (Join-Path $PSScriptRoot 'harsh/lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

function VersionOf($setup) {
  if ((Split-Path $setup -Leaf) -match 'vps2vpn-(?:dev-)?v?(\d+\.\d+\.\d+)') { return $Matches[1] }
  throw "no version in $setup"
}
function Read-Config { (Get-Content $script:prefs -Raw | ConvertFrom-Json).'flutter.config' | ConvertFrom-Json }
function Read-Prefs { Get-Content $script:prefs -Raw | ConvertFrom-Json }
# Edit-AppConfig without its stored takeover answer, which is under test here.
function Edit-Config([scriptblock]$edit) {
  $d = Read-Prefs
  $c = $d.'flutter.config' | ConvertFrom-Json
  & $edit $c
  $d.'flutter.config' = ($c | ConvertTo-Json -Depth 50 -Compress)
  $d | ConvertTo-Json -Depth 50 -Compress | Set-Content $script:prefs -Encoding utf8
}
function Read-Db {
  $text = & python -I (Join-Path $PSScriptRoot 'legend_db.py') $db get
  if ($LASTEXITCODE -ne 0) { return $null }
  $text | ConvertFrom-Json
}
function Get-NodeCount { if (Test-Path $nodeLog) { @(Get-Content $nodeLog).Count } else { 0 } }
function Get-Trace($path) { if (Test-Path $path) { @(Get-Content $path -Encoding utf8) } else { @() } }

$oldVersion = VersionOf $Old
$newVersion = VersionOf $New
"manual upgrade $oldVersion -> $newVersion"
$db = Join-Path $script:appHome 'database.sqlite'
$uiTrace = Join-Path $Out 'ui-trace.txt'
$takeoverTrace = Join-Path $Out 'takeover-trace.txt'
$legendPort = 18001
$nodePort = 18081
$nodeLog = Join-Path $Out 'picked-node.log'
$group = '🚀 节点选择'
$picked = 'us 洛杉矶 · 5.0x'

try {
  Start-Upstream $Out
  # The picked node has an upstream of its own, so traffic through it shows.
  Start-Tracked 'python' @('-I', (Join-Path $script:work 'coexist_upstream.py'), $nodeLog, "$nodePort") | Out-Null
  # A provider without the vps2vpn panel: lowercase country codes, rates in
  # the names, TB-sized traffic in the header, no member API.
  $legendDir = Join-Path $script:work 'legend'
  New-Item -ItemType Directory -Force $legendDir | Out-Null
  $names = 'us 洛杉矶 · 5.0x', 'us 圣何塞 · 1x', 'jp 东京 · 1.0x', 'hk 香港 · 1x', 'sg 新加坡 · 0.5x', 'tw 台北 · 2.0x', 'kr 首尔 · 1.5x'
  $lines = foreach ($n in $names) {
    $port = if ($n -eq $picked) { $nodePort } else { $script:upstreamPort }
    "  - {name: '$n', type: http, server: 127.0.0.1, port: $port}"
  }
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText((Join-Path $legendDir 'sub.yaml'), @"
mixed-port: 7890
mode: rule
proxies:
$($lines -join "`n")
proxy-groups:
  - {name: $group, type: select, proxies: [♻️ 自动选择, '$($names -join "', '")']}
  - {name: ♻️ 自动选择, type: url-test, proxies: ['$($names -join "', '")'], url: 'https://www.gstatic.com/generate_204', interval: 300}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,$group
"@, $utf8)
  # What GitHub's releases API would say once a newer version is out.
  [IO.File]::WriteAllText((Join-Path $legendDir 'latest.json'), (@{
    tag_name = 'v9.9.9'; draft = $false; prerelease = $false
    html_url = 'https://github.com/xydadada/vps2vpn-client/releases/tag/v9.9.9'
    body = "- First point`n- Second point"; assets = @()
  } | ConvertTo-Json -Compress), $utf8)
  Copy-Item (Join-Path $PSScriptRoot 'legend_sub.py') $script:work
  Start-Tracked 'python' @('-I', (Join-Path $script:work 'legend_sub.py'), $legendDir, "$legendPort") | Out-Null
  Check (Wait-Until 20 { (Get-Listener $legendPort) -and (Get-Listener $nodePort) }) 'subscription host and picked node listen'
  $header = (& curl.exe -s -D - -o NUL "http://127.0.0.1:$legendPort/sub.yaml") -match '^Subscription-Userinfo'
  Check ([bool]$header) 'the subscription carries Subscription-Userinfo'

  # 1. The old release from GitHub, used for a while.
  Install-App $Old $Out
  Move-Item (Join-Path $Out 'install.log') (Join-Path $Out 'install-old.log') -Force
  $fileVersion = (Get-Item $script:exe).VersionInfo.FileVersion
  Check ("$fileVersion" -like "$oldVersion*") "old version installed: $fileVersion"
  Check (Import-FirstRun "http://127.0.0.1:$legendPort/sub.yaml") "$oldVersion imported the subscription"
  Edit-Config {
    param($c)
    $c.appSettingProps | Add-Member -Force locale 'en'
    $c.appSettingProps | Add-Member -Force autoRun $false
    $c.themeProps | Add-Member -Force themeMode 'dark'
    $c.patchClashConfig | Add-Member -Force mode 'global'
    if (-not $c.patchClashConfig.tun) { $c.patchClashConfig | Add-Member -Force tun ([pscustomobject]@{}) }
    if (-not $c.networkProps) { $c | Add-Member -Force networkProps ([pscustomobject]@{}) }
    $c.patchClashConfig.tun | Add-Member -Force enable $true
    $c.networkProps | Add-Member -Force systemProxy $false
  }
  $set = & python -I (Join-Path $PSScriptRoot 'legend_db.py') $db set $group $picked GLOBAL $group
  "old selection: $set"
  # The old version reads and rewrites all of it once.
  Start-Process $script:exe | Out-Null
  Start-Sleep 20
  Stop-App
  $before = Read-Config
  $beforeDb = Read-Db
  Check ($before.patchClashConfig.mode -eq 'global' -and $before.appSettingProps.locale -eq 'en') "$oldVersion kept the settings it was given"
  Check ($beforeDb.selected.$group -eq $picked) "$oldVersion kept the picked node"
  # Releases before the takeover question never wrote its answer.
  Check (-not (Read-Prefs).PSObject.Properties['flutter.vpsTakeoverAsked']) "$oldVersion has no takeover answer stored"

  # 2. The new setup, run silently over it.
  $p = Start-Process $New -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "`"/LOG=$(Join-Path $Out 'install-new.log')`"" -Wait -PassThru
  Check ($p.ExitCode -eq 0) "new installer exit code 0 (got $($p.ExitCode))"
  $fileVersion = (Get-Item $script:exe).VersionInfo.FileVersion
  Check ("$fileVersion" -like "$newVersion*") "new version installed: $fileVersion"
  Stop-App

  # 3. First start of the new version: everything carried over.
  $env:VPS2VPN_UI_TRACE = $uiTrace
  $env:VPS2VPN_TAKEOVER_TRACE = $takeoverTrace
  $env:VPS2VPN_RELEASE_FEED = "http://127.0.0.1:$legendPort/latest.json"
  $app = Start-Process $script:exe -PassThru
  Start-Sleep 20
  Check (-not $app.HasExited) "$newVersion keeps running after the upgrade"
  Stop-App
  $after = Read-Config
  $afterDb = Read-Db
  $prefsAfter = Read-Prefs
  Check ($after.appSettingProps.locale -eq 'en') "language kept (got '$($after.appSettingProps.locale)')"
  Check ($after.themeProps.themeMode -eq 'dark') "theme kept (got '$($after.themeProps.themeMode)')"
  Check ($after.patchClashConfig.mode -eq 'global') "proxy mode kept (got '$($after.patchClashConfig.mode)')"
  Check ($after.patchClashConfig.tun.enable -eq $true -and $after.networkProps.systemProxy -eq $false) 'takeover method kept: TUN, no system proxy'
  Check ($after.appSettingProps.takeover -ne $false) 'closing other apps on connect still on'
  Check ($afterDb.selected.$group -eq $picked) "picked node kept (got '$($afterDb.selected.$group)')"
  Check ("$($afterDb.traffic)" -match '"total":\s*2199023255552') "traffic from the header kept: $($afterDb.traffic)"
  Check ($prefsAfter.'flutter.vpsTakeoverAsked' -eq $true) 'the upgrade stored the takeover answer instead of asking'
  Check ((Get-ChildItem (Join-Path $script:appHome 'profiles') -File -Filter '*.yaml').Count -eq 1) 'one subscription file'

  # 4. Connect the way the user does, with another proxy app open.
  Edit-Config {
    param($c)
    $c.appSettingProps | Add-Member -Force autoRun $true
    # Global sends the CI upstream's own traffic into TUN; rule mode lets it out.
    $c.patchClashConfig | Add-Member -Force mode 'rule'
  }
  $root = Join-Path $script:work 'flclash'
  Expand-Archive (Join-Path $Tools 'flclash.zip') $root -Force
  $flclash = Get-ChildItem $root -Recurse -Filter 'FlClash.exe' | Select-Object -First 1
  if ($flclash) { Start-Tracked $flclash.FullName $null | Out-Null }
  Check (Wait-Until 20 { Get-Process FlClash -ErrorAction SilentlyContinue }) 'FlClash is open before connecting'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $port = Start-App "$newVersion connects" 90
  Check (Wait-Until 60 { -not (Get-Process FlClash, FlClashCore -ErrorAction SilentlyContinue) }) 'FlClash was closed on connect without a question'
  $trace = Get-Trace $takeoverTrace
  Check (@($trace -match 'before connect: act=true').Count -ge 1) 'takeover ran on connect'
  Check (@($trace -match 'answer remembered').Count -eq 0) 'nobody had to answer the takeover question'
  $seen = Get-NodeCount
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -x "http://127.0.0.1:$port" $script:probeUrl
  Check ($code -eq '204') "curl through port $port answers 204 (got $code)"
  Check (Wait-Until 5 { (Get-NodeCount) -gt $seen }) "the request went out through the picked node $picked"

  # 5. The first update check, 30 s after start, finds the newer release.
  $found = Wait-Until (150 - $clock.Elapsed.TotalSeconds) { @(Get-Trace $uiTrace) -match 'update available 9\.9\.9' }
  Check $found 'the first update check found 9.9.9'
  Test-AppAlive 'after the update check'
  Stop-App

  $ui = Get-Trace $uiTrace
  "ui trace:"; $ui | ForEach-Object { "  $_" }
  Check (@($ui -match ' dialog ').Count -eq 0) 'no dialog opened (no what''s new, no takeover question)'
  Check (@($ui -match ' banner (warning|error) ').Count -eq 0) 'no warning or error banner'
} finally {
  Copy-Item $script:prefs (Join-Path $Out 'shared_preferences.json') -ErrorAction SilentlyContinue
  Finish
}
