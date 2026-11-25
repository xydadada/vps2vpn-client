# vps2vpn next to the real FlClash and Clash Verge Rev, with traffic through a
# CI-local upstream proxy. Never run this on a real PC: it installs apps and
# ends processes.
param(
  [Parameter(Mandatory)][string]$Setup,
  [Parameter(Mandatory)][string]$FlClashZip,
  [Parameter(Mandatory)][string]$VergeSetup,
  [string]$Out = 'coexist',
  [int]$Rounds = 3
)

$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS) { throw 'CI only: this installs apps and ends processes' }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$failures = [System.Collections.Generic.List[string]]::new()
function Check($ok, $what) {
  if ($ok) { "PASS  $what" } else { "FAIL  $what"; $failures.Add($what) }
}

$work = Join-Path $env:RUNNER_TEMP 'coexist'
New-Item -ItemType Directory -Force $work | Out-Null
$upstreamPort = 18080
$subPort = 18000
$upstreamLog = Join-Path $Out 'upstream.log'
$probeUrl = 'https://www.gstatic.com/generate_204'
$inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

function Start-Tracked($file, $arguments) {
  $p = if ($arguments) {
    Start-Process $file -ArgumentList $arguments -WindowStyle Hidden -PassThru
  } else {
    Start-Process $file -WindowStyle Hidden -PassThru
  }
  $started.Add($p)
  $p
}

function Wait-Until($seconds, [scriptblock]$condition) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $condition) { return $true }
    Start-Sleep -Milliseconds 500
  }
  [bool](& $condition)
}

function Get-Listener($port) {
  Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-ListenerName($port) {
  $l = Get-Listener $port
  if (-not $l) { return $null }
  (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).Name
}

function Get-UpstreamCount {
  if (Test-Path $upstreamLog) { @(Get-Content $upstreamLog).Count } else { 0 }
}

function Test-Through($port, $what) {
  $before = Get-UpstreamCount
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -x "http://127.0.0.1:$port" $probeUrl
  $seen = Wait-Until 5 { (Get-UpstreamCount) -gt $before }
  Check ($code -eq '204') "$what`: curl through port $port answers 204 (got $code)"
  Check $seen "$what`: the request went out through the CI upstream proxy"
  if (-not $seen) { Show-Route }
}

function Show-Route {
  "route: upstream listening=$([bool](Get-Listener $upstreamPort)) lines=$(Get-UpstreamCount)"
  Get-Content $upstreamLog -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { "route: upstream saw $_" }
  $home_ = Join-Path $env:APPDATA 'vps2vpn\vps2vpn'
  Get-ChildItem (Join-Path $home_ 'profiles') -File -ErrorAction SilentlyContinue |
    ForEach-Object { "route: profile $($_.Name) $($_.Length) bytes" }
  $running = Join-Path $home_ 'config.yaml'
  if (Test-Path $running) {
    $text = Get-Content $running -Raw
    "route: running config $($text.Length) bytes, ci-upstream=$($text.Contains('ci-upstream')) MATCH=$($text.Contains('MATCH'))"
    Select-String $running -Pattern '^\s*-?\s*(mode|mixed-port|allow-lan|bind-address):' |
      ForEach-Object { "route: $($_.Line.Trim())" }
    Select-String $running -Pattern 'MATCH|ci-upstream' | Select-Object -First 6 |
      ForEach-Object { "route: $($_.Line.Trim())" }
  } else {
    'route: no running config'
  }
}

$prefs = Join-Path $env:APPDATA 'vps2vpn\vps2vpn\shared_preferences.json'
function Set-AppPrefs([hashtable]$settings) {
  $d = Get-Content $prefs -Raw | ConvertFrom-Json
  $c = $d.'flutter.config' | ConvertFrom-Json
  foreach ($k in $settings.Keys) { $c.appSettingProps | Add-Member -Force $k $settings[$k] }
  $d.'flutter.config' = ($c | ConvertTo-Json -Depth 50 -Compress)
  # Connect asks once before closing other apps; nobody answers in CI.
  $d | Add-Member -Force 'flutter.vpsTakeoverAsked' $true
  $d | ConvertTo-Json -Depth 50 -Compress | Set-Content $prefs -Encoding utf8
}
function Edit-AppConfig([scriptblock]$edit) {
  $d = Get-Content $prefs -Raw | ConvertFrom-Json
  $c = $d.'flutter.config' | ConvertFrom-Json
  & $edit $c
  $d.'flutter.config' = ($c | ConvertTo-Json -Depth 50 -Compress)
  $d | ConvertTo-Json -Depth 50 -Compress | Set-Content $prefs -Encoding utf8
}
function Set-Takeover([bool]$tun) {
  Edit-AppConfig {
    param($c)
    if (-not $c.patchClashConfig.tun) { $c.patchClashConfig | Add-Member -Force tun ([pscustomobject]@{}) }
    if (-not $c.networkProps) { $c | Add-Member -Force networkProps ([pscustomobject]@{}) }
    $c.patchClashConfig.tun | Add-Member -Force enable $tun
    $c.networkProps | Add-Member -Force systemProxy (-not $tun)
  }
}
function Get-AppPort {
  $c = (Get-Content $prefs -Raw | ConvertFrom-Json).'flutter.config' | ConvertFrom-Json
  $port = $c.patchClashConfig.'mixed-port'
  if ($port) { [int]$port } else { 7890 }
}

$dir = Join-Path $env:ProgramFiles 'vps2vpn'
$exe = Join-Path $dir 'vps2vpn.exe'
function Stop-App {
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Wait-Until 15 { -not (Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue) } | Out-Null
}
function Start-App($what) {
  Start-Process $exe | Out-Null
  $up = Wait-Until 60 { (Get-ListenerName (Get-AppPort)) -eq 'vps2vpnCore' }
  $port = Get-AppPort
  Check $up "$what`: vps2vpnCore listens on its mixed port $port" | Out-Host
  $port
}

try {
  # Upstream proxy and subscription server, both on loopback only.
  Copy-Item (Join-Path $PSScriptRoot 'coexist_upstream.py') $work
  $subDir = Join-Path $work 'sub'
  New-Item -ItemType Directory -Force $subDir | Out-Null
  @"
mixed-port: 7890
mode: rule
proxies:
  - {name: ci-upstream, type: http, server: 127.0.0.1, port: $upstreamPort}
proxy-groups:
  - {name: Proxy, type: select, proxies: [ci-upstream]}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,Proxy
"@ | Set-Content (Join-Path $subDir 'sub.yaml') -Encoding utf8
  Start-Tracked 'python' @('-I', (Join-Path $work 'coexist_upstream.py'), $upstreamLog, "$upstreamPort") | Out-Null
  Start-Tracked 'python' @('-I', '-m', 'http.server', '--bind', '127.0.0.1', '--directory', $subDir, "$subPort") | Out-Null
  Check (Wait-Until 20 { (Get-Listener $upstreamPort) -and (Get-Listener $subPort) }) 'CI upstream proxy and subscription server listen'
  Test-Through $upstreamPort 'baseline'

  $p = Start-Process $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "`"/LOG=$(Join-Path $Out 'install.log')`"" -Wait -PassThru
  Check ($p.ExitCode -eq 0) "vps2vpn installer exit code 0 (got $($p.ExitCode))"

  $p = Start-Process $VergeSetup -ArgumentList '/S' -Wait -PassThru
  Check ($p.ExitCode -eq 0) "Clash Verge Rev installer exit code 0 (got $($p.ExitCode))"
  $verge = Get-ChildItem "$env:ProgramFiles\Clash Verge", "$env:LOCALAPPDATA\Clash Verge", "$env:LOCALAPPDATA\Programs\Clash Verge" -Filter 'clash-verge.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  Check ([bool]$verge) 'clash-verge.exe installed'
  $flclashDir = Join-Path $work 'FlClash'
  Expand-Archive $FlClashZip $flclashDir -Force
  $flclash = Get-ChildItem $flclashDir -Recurse -Filter 'FlClash.exe' | Select-Object -First 1
  Check ([bool]$flclash) 'FlClash.exe unpacked'

  # A process the takeover must never touch, and holders for the common ports.
  Copy-Item "$env:SystemRoot\System32\PING.EXE" (Join-Path $work 'innocent-tool.exe')
  $decoy = Start-Tracked (Join-Path $work 'innocent-tool.exe') @('-n', '100000', '127.0.0.1')

  if ($verge) { Start-Tracked $verge.FullName $null | Out-Null }
  if ($flclash) {
    Start-Tracked $flclash.FullName $null | Out-Null
    Start-Tracked $flclash.FullName $null | Out-Null
  }
  Wait-Until 45 { Get-Listener 7897 } | Out-Null
  $holders = @()
  foreach ($port in 7890, 7897) {
    $owner = Get-ListenerName $port
    if ($owner) { "port $port held by $owner" } else {
      $holders += Start-Tracked 'powershell' @('-NoProfile', '-Command',
        "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$port);`$l.Start();Start-Sleep 1800")
      Check (Wait-Until 20 { Get-Listener $port }) "port $port held by a stand-in"
    }
  }
  $rivalNames = 'clash-verge', 'verge-mihomo', 'FlClash', 'FlClashCore'
  $rivalsBefore = @(Get-Process $rivalNames -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
  "rivals running: $($rivalsBefore -join ', ')"
  Check ($rivalsBefore -contains 'clash-verge') 'Clash Verge Rev is running'
  Check ($rivalsBefore -contains 'FlClash') 'FlClash is running'

  # First run imports the subscription through the app's own test hook.
  $env:FLCLASH_ACCEPT_DISCLAIMER = '1'
  $env:VPS2VPN_IMPORT_URL = "http://127.0.0.1:$subPort/sub.yaml"
  Start-Process $exe | Out-Null
  $profiles = Join-Path $env:APPDATA 'vps2vpn\vps2vpn\profiles'
  Check (Wait-Until 60 { Get-ChildItem $profiles -File -Filter '*.yaml' -ErrorAction SilentlyContinue }) 'subscription imported on first run'
  # The file lands before the profile record; give the app time to save both.
  Start-Sleep 10
  Stop-App
  Remove-Item Env:VPS2VPN_IMPORT_URL
  Check (Test-Path $prefs) 'settings file created on first run'

  # A: takeover off. vps2vpn has to work next to the others.
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  $port = Start-App 'takeover off'
  Check ($port -ne 7890 -and $port -ne 7897) "takeover off: avoided the taken ports (on $port)"
  Test-Through $port 'takeover off'
  $still = @(Get-Process clash-verge, FlClash -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
  Check ($still -contains 'clash-verge' -and $still -contains 'FlClash') "takeover off: FlClash and Clash Verge left running ($($still -join ', '))"
  Stop-App

  # B: takeover on (the default). The other proxy apps close; nothing else does.
  Set-AppPrefs @{ takeover = $true }
  $port = Start-App 'takeover on'
  Check (Wait-Until 30 { -not (Get-Process $rivalNames -ErrorAction SilentlyContinue) }) "takeover on: FlClash and Clash Verge closed (left: $((Get-Process $rivalNames -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '))"
  $decoy.Refresh()
  Check (-not $decoy.HasExited) 'takeover on: an unrelated process was left alone'
  foreach ($h in $holders) { $h.Refresh(); Check (-not $h.HasExited) "takeover on: port holder $($h.Id) was left alone" }
  Test-Through $port 'takeover on'
  $owner = (Get-Process vps2vpnCore -IncludeUserName -ErrorAction SilentlyContinue | Select-Object -First 1).UserName
  "route: the Core runs as $owner" | Out-Host
  $reg = Get-ItemProperty $inetKey
  "system proxy: enable=$($reg.ProxyEnable) server=$($reg.ProxyServer)"
  Check ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -match ":$port(?:$|;)") "takeover on: system proxy points at port $port"

  for ($i = 1; $i -le $Rounds; $i++) {
    Stop-App
    $port = Start-App "restart $i"
    Test-Through $port "restart $i"
  }

  # TUN: the Helper, registered on first use, runs the Core as SYSTEM. That
  # Core must still reach the app's pipe, and traffic needs no proxy setting.
  Stop-App
  Set-Takeover $true
  Start-Process $exe | Out-Null
  $sys = Wait-Until 120 { Get-Process vps2vpnCore -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match 'SYSTEM' }
  Check $sys 'tun: the Helper runs the Core as SYSTEM'
  Check ((Get-Service vps2vpnHelperService -ErrorAction SilentlyContinue).Status -eq 'Running') 'tun: the Helper service runs'
  $adapter = Wait-Until 60 { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' } }
  Check $adapter 'tun: the virtual adapter is up'
  $before = Get-UpstreamCount
  $clock = [Diagnostics.Stopwatch]::StartNew()
  do {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $probeUrl
    if ($code -ne '204') { Start-Sleep 1 }
  } while ($code -ne '204' -and $clock.Elapsed.TotalSeconds -lt 15)
  if ($clock.Elapsed.TotalSeconds -ge 1) { "INFO  tun: the first request through the adapter answered after $([int]$clock.Elapsed.TotalSeconds)s" }
  $seen = Wait-Until 5 { (Get-UpstreamCount) -gt $before }
  Check ($code -eq '204') "tun: curl with no proxy answers 204 (got $code)"
  Check $seen 'tun: the request went out through the CI upstream proxy'
  if (-not ($sys -and $adapter -and $seen)) {
    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { "route: adapter $($_.Name) [$($_.InterfaceDescription)] $($_.Status)" } | Out-Host
    Show-Route | Out-Host
  }
  Stop-App
  Set-Takeover $false

  # Two launches at once: one instance stays and works.
  Stop-App
  Start-Process $exe | Out-Null
  Start-Process $exe | Out-Null
  Check (Wait-Until 60 { (Get-ListenerName (Get-AppPort)) -eq 'vps2vpnCore' }) 'double launch: the Core comes up'
  Start-Sleep 10
  $apps = @(Get-Process vps2vpn -ErrorAction SilentlyContinue)
  Check ($apps.Count -eq 1) "double launch: one vps2vpn.exe left (got $($apps.Count))"
  Test-Through (Get-AppPort) 'double launch'
  $ownedProxy = "$((Get-ItemProperty $inetKey).ProxyServer)"

  # Uninstall with the app ended by force, as after a crash.
  Stop-App
  $un = Join-Path $dir 'unins000.exe'
  $u = Start-Process $un -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
  Wait-Until 30 { -not (Test-Path $exe) -and -not (Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue) } | Out-Null
  Check ($u.ExitCode -eq 0) "uninstaller exit code 0 (got $($u.ExitCode))"
  Check (-not (Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue)) 'nothing of vps2vpn left running'
  $reg = Get-ItemProperty $inetKey
  "system proxy after uninstall: enable=$($reg.ProxyEnable) server=$($reg.ProxyServer)"
  Check (-not ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -eq $ownedProxy)) 'uninstall cleared the system proxy'
  $decoy.Refresh()
  Check (-not $decoy.HasExited) 'the unrelated process survived the whole run'
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 $probeUrl
  Check ($code -eq '204') "direct internet works after uninstall (got $code)"
} finally {
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($p in $started) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
}

if ($failures.Count) { "`n$($failures.Count) check(s) failed:"; $failures; exit 1 }
"`nall checks passed"
