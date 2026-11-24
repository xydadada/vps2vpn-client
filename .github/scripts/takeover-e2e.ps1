# End-to-end check of the RELEASE installer on a throwaway CI machine:
# install -> first run -> plant a fake rival proxy app and hold port 7890 ->
# start with auto-run -> the takeover must close the rival and move the port
# -> screenshot -> uninstall must leave nothing running or installed.
# Never run this on a real PC: it installs the app and ends processes.
param([Parameter(Mandatory)][string]$Setup, [string]$Out = 'e2e')

$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS) { throw 'CI only: this installs vps2vpn and ends processes' }
New-Item -ItemType Directory -Force $Out | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()
function Check($ok, $what) {
  if ($ok) { "PASS  $what" } else { "FAIL  $what"; $failures.Add($what) }
}

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  public struct RECT { public int L, T, R, B; }
}
"@
function Shot($proc, $name) {
  $proc.Refresh()
  $h = $proc.MainWindowHandle
  if ($h -eq [IntPtr]::Zero) { "no window for $name"; return }
  $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
  $bmp = New-Object System.Drawing.Bitmap ([Math]::Max(1, $r.R - $r.L)), ([Math]::Max(1, $r.B - $r.T))
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $dc = $g.GetHdc()
      try {
        [W]::PrintWindow($h, $dc, 2) | Out-Null
      } finally {
        $g.ReleaseHdc($dc)
      }
    } finally {
      $g.Dispose()
    }
    $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $bmp.Dispose()
  }
  "screenshot $name.png"
}

$rival = $null
$holder = $null
try {
  # 1. Install silently.
  $dir = Join-Path $env:ProgramFiles 'vps2vpn'
  $installLog = Join-Path $Out 'install.log'
  $p = Start-Process $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "`"/LOG=$installLog`"" -Wait -PassThru
  Check ($p.ExitCode -eq 0) "installer exit code 0 (got $($p.ExitCode))"
  $exe = Join-Path $dir 'vps2vpn.exe'
  Check (Test-Path $exe) 'vps2vpn.exe installed'
  foreach ($f in 'vps2vpnCore.exe', 'vps2vpnHelperService.exe', 'data\legal\LICENSE.txt', 'data\legal\NOTICE.txt') {
    Check (Test-Path (Join-Path $dir $f)) "$f installed"
  }
  Check (-not (Get-ChildItem $dir -Recurse -Filter '*flclash*' -ErrorAction SilentlyContinue)) 'no FlClash-named file installed'

  # A real user accepts the disclaimer once; the app reads this variable to do
  # the same unattended (bootstrap.dart, _isDisclaimerAcceptedByEnvironment).
  $env:FLCLASH_ACCEPT_DISCLAIMER = '1'

  # 2. First run creates the settings; then close it.
  $app = Start-Process $exe -PassThru
  Start-Sleep 20
  Shot $app 'first-run'
  $prefs = Join-Path $env:APPDATA 'vps2vpn\vps2vpn\shared_preferences.json'
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 3
  Check (Test-Path $prefs) 'settings file created on first run'

  # 3. Turn on auto-run, plant a rival proxy app and hold the mixed port.
  $d = Get-Content $prefs -Raw | ConvertFrom-Json
  $c = $d.'flutter.config' | ConvertFrom-Json
  $c.appSettingProps | Add-Member -Force autoRun $true
  $c.appSettingProps | Add-Member -Force takeover $true
  $c.appSettingProps | Add-Member -Force acceptedDisclaimerVersion 1
  $port = 7890
  if ($c.patchClashConfig -and $c.patchClashConfig.'mixed-port') { $port = [int]$c.patchClashConfig.'mixed-port' }
  $d.'flutter.config' = ($c | ConvertTo-Json -Depth 50 -Compress)
  # Connect asks once before closing other apps; nobody answers in CI.
  $d | Add-Member -Force 'flutter.vpsTakeoverAsked' $true
  $d | ConvertTo-Json -Depth 50 -Compress | Set-Content $prefs -Encoding utf8
  "mixed port before: $port"

  $rivalDir = Join-Path $env:RUNNER_TEMP 'rival'
  New-Item -ItemType Directory -Force $rivalDir | Out-Null
  Copy-Item "$env:SystemRoot\System32\PING.EXE" "$rivalDir\verge-mihomo.exe"
  $rival = Start-Process "$rivalDir\verge-mihomo.exe" -ArgumentList '-n', '100000', '127.0.0.1' -WindowStyle Hidden -PassThru
  Start-Sleep 1
  Check (-not $rival.HasExited) 'fake Clash Verge core is running'

  # The holder runs as its own process so the takeover cannot see it as a rival.
  $holder = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command',
    "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any,$port);`$l.Start();Start-Sleep 600"
  $holderReady = $false
  for ($i = 0; $i -lt 30; $i++) {
    $holder.Refresh()
    if ($holder.HasExited) { break }
    if (Get-NetTCPConnection -LocalPort $port -State Listen -OwningProcess $holder.Id -ErrorAction SilentlyContinue) {
      $holderReady = $true
      break
    }
    Start-Sleep -Milliseconds 500
  }
  $holder.Refresh()
  Check (-not $holder.HasExited -and $holderReady) "port holder is listening on port $port"

  # 4. Start: auto-run connects, which runs the takeover first.
  $app = Start-Process $exe -PassThru
  Start-Sleep 30
  Shot $app 'after-takeover'
  $rival.Refresh()
  Check $rival.HasExited 'takeover closed the fake Clash Verge core'
  Check (-not $holder.HasExited) 'the port holder was left alone'

  $after = (Get-Content $prefs -Raw | ConvertFrom-Json).'flutter.config' | ConvertFrom-Json
  $newPort = $after.patchClashConfig.'mixed-port'
  "mixed port after: $newPort"
  "after run: autoRun=$($after.appSettingProps.autoRun) takeover=$($after.appSettingProps.takeover) disclaimer=$($after.appSettingProps.acceptedDisclaimerVersion)"
  "vps2vpn processes: $((Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')"
  Check ($newPort -and [int]$newPort -ne $port -and [int]$newPort -ge 17890 -and [int]$newPort -lt 17990) "moved off the taken port $port (now $newPort)"
  $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  "system proxy: enable=$($reg.ProxyEnable) server=$($reg.ProxyServer)"
  $ownedProxy = "$($reg.ProxyServer)"
  $portPattern = ':' + [regex]::Escape("$newPort") + '(?:$|;)'
  $proxyWasEnabled = ($reg.ProxyEnable -eq 1 -and $newPort -and $ownedProxy -match $portPattern)
  Check $proxyWasEnabled "system proxy enabled on port $newPort before uninstall"

  # 5. Uninstall. Ending the app by force leaves our system proxy behind, as a
  # crash would; the uninstaller must clear it or the PC loses the internet.
  # FlClash's data must survive: plant a stand-in for it.
  $flclashData = Join-Path $env:APPDATA 'com.follow\clash'
  New-Item -ItemType Directory -Force $flclashData | Out-Null
  Set-Content (Join-Path $flclashData 'marker.txt') 'FlClash data'
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force
  Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep 2
  $un = Join-Path $dir 'unins000.exe'
  Check (Test-Path $un) 'uninstaller present'
  if (Test-Path $un) {
    $u = Start-Process $un -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
      $stillInstalled = Test-Path $exe
      $stillRunning = [bool](Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue)
      $serviceExists = [bool](Get-Service vps2vpnHelperService -ErrorAction SilentlyContinue)
      if (-not $stillInstalled -and -not $stillRunning -and -not $serviceExists) {
        break
      }
      Start-Sleep -Milliseconds 500
    }
    Check ($u.ExitCode -eq 0) "uninstaller exit code 0 (got $($u.ExitCode))"
    Check (-not (Test-Path $exe)) 'vps2vpn.exe removed'
  }
  Check (-not (Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue)) 'nothing of vps2vpn left running'
  Check (-not (Get-Service vps2vpnHelperService -ErrorAction SilentlyContinue)) 'helper service unregistered'
  $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  "system proxy after uninstall: enable=$($reg.ProxyEnable) server=$($reg.ProxyServer)"
  Check ($proxyWasEnabled -and -not ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -eq $ownedProxy)) 'uninstall cleared the observed system proxy'
  Check (Test-Path (Join-Path $flclashData 'marker.txt')) "FlClash's data left untouched"
} finally {
  if ($rival -and -not $rival.HasExited) {
    Stop-Process -Id $rival.Id -Force -ErrorAction SilentlyContinue
  }
  if ($holder -and -not $holder.HasExited) {
    Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
  }
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { "`n$($failures.Count) check(s) failed:"; $failures; exit 1 }
"`nall checks passed"
