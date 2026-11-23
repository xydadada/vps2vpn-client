# vps2vpn after things go wrong: processes killed, the TUN adapter, the Helper
# service or its file gone, bad subscriptions, a dead line, no DNS, a small
# MTU, a skewed clock, loss and lag, a nearly full disk, Defender scanning,
# and no Explorer. Each must end working or with the app still answering.
param([Parameter(Mandatory)][string]$Setup, [string]$Tools = '', [string]$Out = 'harsh')
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$PROXY = 2

function Get-PhysicalAdapter {
  Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
}
function Reset-AppData {
  Stop-App
  Remove-Item $script:appHome -Recurse -Force -ErrorAction SilentlyContinue
}

try {
  Start-Upstream $Out
  Install-App $Setup $Out
  Check (Import-FirstRun) 'subscription imported on first run'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1; autoLaunch = $true }
  Set-Mode $false $true
  $port = Start-App 'start'
  Test-Through $port 'start'
  $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
  Check (@($run.PSObject.Properties | Where-Object { "$($_.Value)" -match 'vps2vpn' }).Count -gt 0) 'launch at startup: the Run entry is written'

  # The Core alone dies: the app brings it back.
  Get-Process vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force
  $back = Wait-Until 60 { (Get-ListenerName (Get-AppPort)) -eq 'vps2vpnCore' }
  Check $back 'core killed: the app starts it again'
  if ($back) { Test-Through (Get-AppPort) 'core killed' }
  Test-AppAlive 'core killed'

  # Everything dies, as at a crash: the next start repairs the system proxy.
  Stop-App
  $stale = Get-WinInetProxy
  "after the crash: $($stale.Server) flags $($stale.Flags)"
  $port = Start-App 'after a crash'
  Test-Through $port 'after a crash'
  Check ((Get-WinInetProxy).Server -eq "127.0.0.1:$port") 'after a crash: the system proxy points at the live port'

  # TUN, then pull the floor out: kill all, delete the adapter, stop the
  # Helper; then delete the Helper's file too.
  Stop-App
  Set-Mode $true $false
  Start-Process $script:exe | Out-Null
  $tun = Wait-Until 120 { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' } }
  Check $tun 'tun: the adapter is up'
  if ($tun) { Check (Test-NoProxy 'tun') 'tun: vps2vpn carried the request' }
  Stop-App
  Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'vps2vpn|Wintun|Meta' } | ForEach-Object { & pnputil /remove-device $_.InstanceId | Out-Null }
  Stop-Service vps2vpnHelperService -Force -ErrorAction SilentlyContinue
  Check ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl) -eq '204') 'tun torn down by force: the internet works without vps2vpn'
  Start-Process $script:exe | Out-Null
  $tun = Wait-Until 120 { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' } }
  Check $tun 'tun after the adapter and the Helper were gone: it comes back'
  if ($tun) { Check (Test-NoProxy 'tun repaired') 'tun repaired: vps2vpn carried the request' }
  Test-AppAlive 'tun repaired'
  Stop-App
  $helper = Get-ChildItem $script:dir -Recurse -Filter 'vps2vpnHelperService.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  Stop-Service vps2vpnHelperService -Force -ErrorAction SilentlyContinue
  if ($helper) { Rename-Item $helper.FullName "$($helper.Name).gone" }
  Start-Process $script:exe | Out-Null
  Start-Sleep 45
  Test-AppAlive 'tun with the Helper file deleted'
  $tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' }
  if ($tun) { Note 'tun with the Helper file deleted: TUN still came up' } else { Note 'tun with the Helper file deleted: no TUN (expected until a reinstall)' }
  Check ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl) -eq '204') 'tun with the Helper file deleted: the internet is not cut off'
  Stop-App
  if ($helper) { Rename-Item "$($helper.FullName).gone" $helper.Name }
  Set-Mode $false $true

  # Bad subscriptions on a fresh start: the app stays up and imports nothing.
  $bad = @{
    'empty.yaml' = ''
    'garbage.yaml' = (-join ((1..20000) | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 126) }))
    'html.yaml' = '<!doctype html><html><head><title>502 Bad Gateway</title></head><body><h1>502</h1></body></html>'
    'noproxies.yaml' = "mixed-port: 7890`nproxies: []`nrules:`n  - MATCH,DIRECT`n"
    'broken.yaml' = "proxies:`n  - {name: x, type: vless, server: [oops`n"
  }
  foreach ($name in $bad.Keys) { Write-Subscription $name $bad[$name] }
  $big = Join-Path $script:subDir 'huge.yaml'
  $f = [IO.File]::Create($big); $f.SetLength(60MB); $f.Close()
  foreach ($name in @($bad.Keys) + 'huge.yaml' + 'missing.yaml') {
    Reset-AppData
    $env:FLCLASH_ACCEPT_DISCLAIMER = '1'
    $env:VPS2VPN_IMPORT_URL = "http://127.0.0.1:$($script:subPort)/$name"
    Start-Process $script:exe | Out-Null
    Start-Sleep 25
    Remove-Item Env:VPS2VPN_IMPORT_URL
    Test-AppAlive "subscription $name"
    $imported = @(Get-ChildItem (Join-Path $script:appHome 'profiles') -File -ErrorAction SilentlyContinue | Where-Object Length -gt 0)
    Note "subscription $name`: $($imported.Count) profile file(s) kept"
  }
  Reset-AppData
  Check (Import-FirstRun) 'a good subscription still imports after the bad ones'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true

  # A line whose server port is shut: requests fail fast, the app stays up.
  Write-Subscription 'dead.yaml' "proxies:`n  - {name: dead, type: http, server: 127.0.0.1, port: 9}`nproxy-groups:`n  - {name: Proxy, type: select, proxies: [dead]}`nrules:`n  - MATCH,Proxy`n"
  Reset-AppData
  Check (Import-FirstRun "http://127.0.0.1:$($script:subPort)/dead.yaml") 'dead line: imported'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true
  $port = Start-App 'dead line'
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 30 -x "http://127.0.0.1:$port" $script:probeUrl
  $watch.Stop()
  Check ($code -ne '204' -and $watch.Elapsed.TotalSeconds -lt 25) "dead line: the request fails in $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s (got $code), not hanging"
  Test-AppAlive 'dead line'
  Reset-AppData
  Check (Import-FirstRun) 'back to the working line'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true

  # The network itself misbehaving.
  $nic = Get-PhysicalAdapter
  $dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses
  Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses 192.0.2.53
  Clear-DnsClientCache
  $port = Start-App 'no DNS' 90
  Test-AppAlive 'no DNS'
  Stop-App
  Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $dns
  Clear-DnsClientCache

  $mtu = (Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).NlMtu
  & netsh interface ipv4 set subinterface $nic.ifIndex mtu=1280 store=active | Out-Null
  $port = Start-App 'MTU 1280'
  Test-Through $port 'MTU 1280'
  Stop-App
  & netsh interface ipv4 set subinterface $nic.ifIndex mtu=$mtu store=active | Out-Null

  $skew = (Get-Date).AddDays(3).AddHours(5)
  Set-Date $skew | Out-Null
  $port = Start-App 'clock 3 days ahead'
  Test-Through $port 'clock 3 days ahead'
  Stop-App
  Set-Date (Get-Date).AddDays(-3).AddHours(-5) | Out-Null
  & w32tm /resync /force 2>$null | Out-Null

  $clumsy = if ($Tools) { Get-ChildItem $Tools -Recurse -Filter 'clumsy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($clumsy) {
    $c = Start-Tracked $clumsy.FullName @('--filter', "`"tcp.DstPort == $($script:upstreamPort) or tcp.SrcPort == $($script:upstreamPort)`"", '--lag', 'on', '--lag-time', '400', '--drop', 'on', '--drop-chance', '15', '--silent')
    Start-Sleep 5
    $c.Refresh()
    if ($c.HasExited) { Note "clumsy exited at once (code $($c.ExitCode)); loss and lag not tested" } else {
      $port = Start-App 'loss and lag'
      $ok = 0
      foreach ($i in 1..5) { if ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 30 -x "http://127.0.0.1:$port" $script:probeUrl) -eq '204') { $ok++ } }
      Check ($ok -ge 3) "loss and lag: $ok of 5 requests got through"
      Test-AppAlive 'loss and lag'
      Stop-App
      Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue
    }
  } else { Note 'clumsy not available; loss and lag not tested' }

  # The machine itself in a bad state.
  $free = (Get-PSDrive C).Free
  $filler = 'C:\ci-disk-filler.bin'
  $fill = [math]::Max([long]0, [long]$free - 150MB)  # [int]0 would pick the Int32 overload
  & fsutil file createnew $filler $fill | Out-Null
  "disk C: free now $([math]::Round((Get-PSDrive C).Free / 1MB)) MB"
  $port = Start-App 'disk nearly full'
  Test-Through $port 'disk nearly full'
  Test-AppAlive 'disk nearly full'
  Stop-App
  Remove-Item $filler -Force -ErrorAction SilentlyContinue

  try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch { Note "Defender real-time protection could not be turned on: $($_.Exception.Message)" }
  "Defender real-time protection on: $((Get-MpComputerStatus -ErrorAction SilentlyContinue).RealTimeProtectionEnabled)"
  $port = Start-App 'Defender scanning'
  Test-Through $port 'Defender scanning'
  Stop-App

  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  $port = Start-App 'no Explorer'
  Test-Through $port 'no Explorer'
  Test-AppAlive 'no Explorer'
  Start-Process explorer.exe
  Start-Sleep 5
  Test-AppAlive 'Explorer back'

  Uninstall-App
  Test-NothingLeft 'after uninstall'
} finally {
  Remove-Item 'C:\ci-disk-filler.bin' -Force -ErrorAction SilentlyContinue
  Finish
}
