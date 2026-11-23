# The system proxy someone else set survives vps2vpn: a company proxy, another
# app's live local proxy or PAC, and a change made while vps2vpn is connected
# all come back as they were. A dead local proxy is not brought back.
param([Parameter(Mandatory)][string]$Setup, [string]$Out = 'harsh')
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$PROXY = 2
$PAC = 4

try {
  Start-Upstream $Out
  & netsh winhttp set proxy 127.0.0.1:3128 'localhost;<local>' | Out-Null
  $winhttp = Get-WinHttpProxy
  Install-App $Setup $Out
  Check (Import-FirstRun) 'subscription imported on first run'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true
  $other = Hold-Port 10808

  $cases = @(
    @{ name = 'company proxy'; flags = 1 -bor $PROXY; server = 'proxy.corp.example:8080'; bypass = '<local>;*.corp.example'; pac = ''; expect = 'same' },
    @{ name = "another app's live local proxy"; flags = 1 -bor $PROXY; server = '127.0.0.1:10808'; bypass = '<local>'; pac = ''; expect = 'same' },
    @{ name = "another app's live PAC"; flags = 1 -bor $PAC; server = ''; bypass = ''; pac = 'http://127.0.0.1:10808/pac/proxy.js'; expect = 'same' },
    @{ name = 'a dead local proxy'; flags = 1 -bor $PROXY; server = '127.0.0.1:10899'; bypass = ''; pac = ''; expect = 'direct' },
    @{ name = 'no proxy'; flags = 1; server = ''; bypass = ''; pac = ''; expect = 'direct' }
  )
  foreach ($c in $cases) {
    Stop-App
    Set-WinInetProxy $c.flags $c.server $c.bypass $c.pac
    Show-Proxy "before, $($c.name)"
    $port = Start-App $c.name
    $ours = Wait-Until 20 { $p = Get-WinInetProxy; ($p.Flags -band $PROXY) -and $p.Server -eq "127.0.0.1:$port" }
    Check $ours "$($c.name): vps2vpn points the system proxy at port $port"
    Test-Through $port $c.name
    Check (Send-EndSession) "$($c.name): found the app's session window"
    Start-Sleep 3
    $after = Get-WinInetProxy
    Show-Proxy "after, $($c.name)"
    if ($c.expect -eq 'same') {
      $back = $after.Flags -eq $c.flags -and $after.Server -eq $c.server -and $after.Pac -eq $c.pac
      Check $back "$($c.name): given back as it was (flags $($c.flags) -> $($after.Flags))"
    } else {
      Check (($after.Flags -band ($PROXY -bor $PAC)) -eq 0) "$($c.name): left direct, not pointing at a dead port"
    }
  }

  # Someone else changes the proxy while vps2vpn is connected: that one stays.
  Stop-App
  Set-WinInetProxy 1
  $port = Start-App 'changed while connected'
  Wait-Until 20 { (Get-WinInetProxy).Server -eq "127.0.0.1:$port" } | Out-Null
  Set-WinInetProxy (1 -bor $PROXY) '127.0.0.1:10808' '<local>'
  Send-EndSession | Out-Null
  Start-Sleep 3
  $after = Get-WinInetProxy
  Show-Proxy 'after, changed while connected'
  Check (($after.Flags -band $PROXY) -and $after.Server -eq '127.0.0.1:10808') "changed while connected: the other app's proxy was left in place"

  Check ((Get-WinHttpProxy) -eq $winhttp) 'the WinHTTP proxy was never touched'
  Stop-App
  Set-WinInetProxy 1
  Uninstall-App
  Test-NothingLeft 'after uninstall'
} finally {
  & netsh winhttp reset proxy | Out-Null
  Finish
}
