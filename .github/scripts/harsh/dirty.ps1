# vps2vpn on a machine other VPN and proxy apps have already dirtied: their
# own TUN up with routes, WireGuard and OpenVPN adapters, ports taken, a
# system proxy and a WinHTTP proxy of their own. vps2vpn must work there,
# leave the others working, and leave the machine as it found it.
param([Parameter(Mandatory)][string]$Setup, [Parameter(Mandatory)][string]$Tools, [string]$Out = 'harsh')
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Tools = (Resolve-Path $Tools).Path
$PROXY = 2

function Expand-Tool($zip) {
  $to = Join-Path $script:work ([IO.Path]::GetFileNameWithoutExtension($zip))
  Expand-Archive (Join-Path $Tools $zip) $to -Force
  $to
}
function Find-Exe($root, $name) {
  Get-ChildItem $root -Recurse -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
}
function Start-Rival($what, $root, $name) {
  $file = Find-Exe $root $name
  if (-not $file) { Note "$what`: $name not found in its download"; return $null }
  $p = Start-Tracked $file.FullName $null
  Start-Sleep 3
  $p.Refresh()
  if ($p.HasExited) { Note "$what exited at once (code $($p.ExitCode))" } else { "started $what (pid $($p.Id))" }
  $p
}

try {
  Start-Upstream $Out
  "adapters before anything:"; Get-AdapterSummary

  # --- the mess ---
  $p = Start-Process (Join-Path $Tools 'verge-setup.exe') -ArgumentList '/S' -Wait -PassThru
  Check ($p.ExitCode -eq 0) "Clash Verge Rev installer exit code 0 (got $($p.ExitCode))"
  $verge = Get-ChildItem "$env:ProgramFiles\Clash Verge", "$env:LOCALAPPDATA\Clash Verge", "$env:LOCALAPPDATA\Programs\Clash Verge" -Filter 'clash-verge.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($verge) { Start-Tracked $verge.FullName $null | Out-Null }
  Start-Rival 'FlClash' (Expand-Tool 'flclash.zip') 'FlClash.exe' | Out-Null
  Start-Rival 'v2rayN' (Expand-Tool 'v2rayn.zip') 'v2rayN.exe' | Out-Null
  Start-Rival 'Hiddify' (Expand-Tool 'hiddify.zip') 'Hiddify.exe' | Out-Null
  Start-Rival 'NekoRay' (Expand-Tool 'nekoray.zip') 'nekoray.exe' | Out-Null
  Start-Rival 'Shadowsocks' (Expand-Tool 'shadowsocks.zip') 'Shadowsocks.exe' | Out-Null

  # sing-box with a TUN of its own, routes and all, going out directly; its
  # mixed port 7891 is the system proxy "another app" set.
  $singRoot = Expand-Tool 'sing-box.zip'
  $sing = Find-Exe $singRoot 'sing-box.exe'
  $singConfig = Join-Path $script:work 'sing-box-tun.json'
  @{
    log = @{ level = 'warn'; output = (Join-Path $Out 'sing-box.log') }
    inbounds = @(
      @{ type = 'tun'; tag = 'tun-in'; interface_name = 'other-tun'; address = @('172.18.0.1/30'); auto_route = $true; strict_route = $false; stack = 'system' },
      @{ type = 'mixed'; tag = 'mixed-in'; listen = '127.0.0.1'; listen_port = 7891 }
    )
    outbounds = @(@{ type = 'direct'; tag = 'direct' })
    route = @{ auto_detect_interface = $true }
  } | ConvertTo-Json -Depth 10 | Set-Content $singConfig -Encoding utf8
  $singProc = Start-Tracked $sing.FullName @('run', '-c', $singConfig)
  $otherTun = Wait-Until 30 { Get-NetAdapter -Name 'other-tun' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' }
  Check $otherTun "another app's TUN (sing-box) is up"

  $wg = "$env:ProgramFiles\WireGuard"
  if (Test-Path "$wg\wireguard.exe") {
    $key = (& "$wg\wg.exe" genkey).Trim()
    $peer = ((& "$wg\wg.exe" genkey).Trim() | & "$wg\wg.exe" pubkey).Trim()
    $conf = Join-Path $script:work 'wgci.conf'
    "[Interface]`nPrivateKey = $key`nAddress = 10.99.0.2/32`n`n[Peer]`nPublicKey = $peer`nAllowedIPs = 10.99.0.0/24`nEndpoint = 127.0.0.1:51820`n" | Set-Content $conf -Encoding ascii
    & "$wg\wireguard.exe" /installtunnelservice $conf
    Check (Wait-Until 30 { Get-NetAdapter -Name 'wgci' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' }) 'a WireGuard tunnel is up'
  } else { Note 'WireGuard is not installed' }
  if (-not (Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match 'TAP-Windows|OpenVPN|ovpn-dco')) { Note 'no OpenVPN adapter found' }

  $holder = Hold-Port 9090
  & netsh winhttp set proxy 127.0.0.1:7891 '<local>' | Out-Null
  $winhttp = Get-WinHttpProxy
  Set-WinInetProxy (1 -bor $PROXY) '127.0.0.1:7891' '<local>'
  Start-Sleep 10
  $othersBefore = @(Get-AdapterSummary | Where-Object { $_ -notmatch 'vps2vpn' })
  "adapters with the others up:"; $othersBefore
  $rivals = @(Get-Process clash-verge, verge-mihomo, FlClash, FlClashCore, v2rayN, xray, Hiddify, HiddifyCli, nekoray, nekobox_core, Shadowsocks, sing-box -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
  "other proxy apps running: $($rivals -join ', ')"
  $taken = @(foreach ($port in 7890, 7891, 7897, 9090) {
    $by = Get-ListenerName $port
    "port $port held by $by" | Out-Host
    if ($by) { $port }
  })
  Check ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl) -eq '204') 'baseline: the internet works through the other TUN'

  # --- vps2vpn, takeover off: next to all of them ---
  Install-App $Setup $Out
  Check (Import-FirstRun) 'subscription imported on first run'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true
  # The other apps are still starting and some of them set or clear the
  # system proxy themselves; what we must give back is what was there just
  # before vps2vpn connected.
  $p0 = Get-WinInetProxy
  Show-Proxy 'before vps2vpn, takeover off'
  $port = Start-App 'takeover off'
  Check ($port -notin $taken) "takeover off: kept off the taken ports $($taken -join ', ') (on $port)"
  Test-Through $port 'takeover off'
  Test-AppAlive 'takeover off'
  Check ((Get-WinInetProxy).Server -eq "127.0.0.1:$port") 'takeover off: the system proxy points at vps2vpn'
  Send-EndSession | Out-Null
  Start-Sleep 3
  $p = Get-WinInetProxy
  Show-Proxy 'after vps2vpn, takeover off'
  Check (($p.Flags -band $PROXY) -eq ($p0.Flags -band $PROXY) -and $p.Server -eq $p0.Server) "takeover off: the other app's system proxy came back (flags $($p0.Flags) -> $($p.Flags), $($p0.Server) -> $($p.Server))"
  Stop-App

  # TUN while the other TUN is up: no loop, and the other one still works after.
  Set-Mode $true $false
  Start-Process $script:exe | Out-Null
  $ours = Wait-Until 120 { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' -and $_.Name -ne 'other-tun' } }
  Check $ours 'tun: our adapter is up next to the other TUN'
  $core = Get-Process vps2vpnCore -ErrorAction SilentlyContinue | Select-Object -First 1
  $cpu0 = if ($core) { $core.TotalProcessorTime.TotalSeconds } else { 0 }
  # The request reaches the CI upstream, but the answer is not required: our
  # strict-route (on by default on Windows against the DNS leak) blocks DNS on
  # every other interface, the other TUN's own lookups included, so the
  # upstream's direct leg can fail. What matters next to another TUN: we carry
  # the request, do not loop or spin, and the other TUN works again after.
  $before = Get-UpstreamCount
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl
  Check (Wait-Until 5 { (Get-UpstreamCount) -gt $before }) 'tun next to the other TUN: vps2vpn carried the request'
  if ($code -ne '204') { Note "tun next to the other TUN: curl with no proxy got $code (two TUNs with strict-route; not required)" }
  Start-Sleep 20
  if ($core) { $core.Refresh(); $busy = $core.TotalProcessorTime.TotalSeconds - $cpu0; Check ($busy -lt 15) "tun next to the other TUN: the Core is not spinning ($([math]::Round($busy, 1)) s of CPU in about 25 s)" }
  Test-AppAlive 'tun next to the other TUN'
  Stop-App
  Check (Wait-Until 30 { -not (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'vps2vpn' }) }) 'tun: our adapter goes away when vps2vpn stops'
  Check ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl) -eq '204') 'after our TUN: the internet works through the other TUN again'
  Check (Get-NetAdapter -Name 'other-tun' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') "after our TUN: the other app's TUN is still up"
  Set-Mode $false $true

  # --- takeover on: the other proxy apps close; VPN clients and drivers stay ---
  Set-AppPrefs @{ takeover = $true }
  $port = Start-App 'takeover on'
  Start-Sleep 15
  $left = @(Get-Process clash-verge, verge-mihomo, FlClash, FlClashCore, v2rayN, Hiddify, nekoray, Shadowsocks, sing-box -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
  Check ($left.Count -eq 0) "takeover on: the other proxy apps closed (left: $($left -join ', '))"
  if (Test-Path "$wg\wireguard.exe") {
    Check (Get-NetAdapter -Name 'wgci' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') 'takeover on: the WireGuard tunnel was left alone'
  }
  $holder.Refresh()
  Check (-not $holder.HasExited) 'takeover on: the port 9090 holder was left alone'
  Test-Through $port 'takeover on'
  Send-EndSession | Out-Null
  Start-Sleep 3
  $p = Get-WinInetProxy
  Check (-not (($p.Flags -band $PROXY) -and $p.Server -eq '127.0.0.1:7891')) 'takeover on: the closed app''s dead proxy was not brought back'

  # --- leave nothing behind ---
  Uninstall-App
  Test-NothingLeft 'after uninstall'
  Check ((Get-WinHttpProxy) -eq $winhttp) 'the WinHTTP proxy is as the other app left it'
  $othersAfter = @(Get-AdapterSummary | Where-Object { $_ -notmatch 'vps2vpn|other-tun' })
  $missing = @($othersBefore | Where-Object { $_ -notmatch 'other-tun' } | Where-Object { $_ -notin $othersAfter })
  Check ($missing.Count -eq 0) "every other adapter is as it was ($($missing -join '; '))"
  Check ((& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl) -eq '204') 'direct internet works after uninstall'
} finally {
  if (Test-Path "$env:ProgramFiles\WireGuard\wireguard.exe") { & "$env:ProgramFiles\WireGuard\wireguard.exe" /uninstalltunnelservice wgci 2>$null }
  & netsh winhttp reset proxy | Out-Null
  Finish
}
