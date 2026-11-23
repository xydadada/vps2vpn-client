# Shared by the harsh-* checks: dot-source it. Never run any of this on a
# real PC: it installs apps, rewrites network settings and ends processes.
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS) { throw 'CI only: this installs apps and ends processes' }

$script:failures = [System.Collections.Generic.List[string]]::new()
$script:notes = [System.Collections.Generic.List[string]]::new()
$script:started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

function Check($ok, $what) {
  if ($ok) { "PASS  $what" } else { "FAIL  $what"; $script:failures.Add($what) }
}
function Note($what) { "NOTE  $what"; $script:notes.Add($what) }

function Finish {
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($p in $script:started) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
  Copy-AppLogs
  if ($script:notes.Count) { "`nnotes:"; $script:notes | ForEach-Object { "  $_" } }
  if ($script:failures.Count) { "`n$($script:failures.Count) check(s) failed:"; $script:failures; exit 1 }
  "`nall checks passed"
}

function Start-Tracked($file, $arguments, [switch]$Visible) {
  $style = if ($Visible) { 'Normal' } else { 'Hidden' }
  $p = if ($arguments) {
    Start-Process $file -ArgumentList $arguments -WindowStyle $style -PassThru
  } else {
    Start-Process $file -WindowStyle $style -PassThru
  }
  $script:started.Add($p)
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
function Hold-Port($port) {
  $p = Start-Tracked 'powershell' @('-NoProfile', '-Command',
    "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$port);`$l.Start();Start-Sleep 7200")
  Wait-Until 20 { Get-Listener $port } | Out-Null
  $p
}

# --- the CI upstream proxy and the subscription server, both on loopback ---
$script:work = Join-Path $env:RUNNER_TEMP 'harsh'
New-Item -ItemType Directory -Force $script:work | Out-Null
$script:upstreamPort = 18080
$script:subPort = 18000
$script:subDir = Join-Path $script:work 'sub'
$script:probeUrl = 'https://www.gstatic.com/generate_204'

function Start-Upstream($out) {
  $script:upstreamLog = Join-Path $out 'upstream.log'
  New-Item -ItemType Directory -Force $script:subDir | Out-Null
  Copy-Item (Join-Path $PSScriptRoot '..\coexist_upstream.py') $script:work
  Write-Subscription 'sub.yaml' @"
mixed-port: 7890
mode: rule
proxies:
  - {name: ci-upstream, type: http, server: 127.0.0.1, port: $($script:upstreamPort)}
proxy-groups:
  - {name: Proxy, type: select, proxies: [ci-upstream]}
rules:
  - PROCESS-NAME,python.exe,DIRECT
  - MATCH,Proxy
"@
  Start-Tracked 'python' @('-I', (Join-Path $script:work 'coexist_upstream.py'), $script:upstreamLog, "$($script:upstreamPort)") | Out-Null
  Start-Tracked 'python' @('-I', '-m', 'http.server', '--bind', '127.0.0.1', '--directory', $script:subDir, "$($script:subPort)") | Out-Null
  Check (Wait-Until 20 { (Get-Listener $script:upstreamPort) -and (Get-Listener $script:subPort) }) 'CI upstream proxy and subscription server listen'
}
function Write-Subscription($name, $text) {
  [System.IO.File]::WriteAllText((Join-Path $script:subDir $name), $text, [System.Text.UTF8Encoding]::new($false))
}
function Get-UpstreamCount {
  if (Test-Path $script:upstreamLog) { @(Get-Content $script:upstreamLog).Count } else { 0 }
}
function Test-Through($port, $what) {
  $before = Get-UpstreamCount
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -x "http://127.0.0.1:$port" $script:probeUrl
  $seen = Wait-Until 5 { (Get-UpstreamCount) -gt $before }
  Check ($code -eq '204') "$what`: curl through port $port answers 204 (got $code)"
  Check $seen "$what`: the request went out through the CI upstream proxy"
}
function Test-NoProxy($what) {
  $before = Get-UpstreamCount
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 --noproxy '*' $script:probeUrl
  $seen = Wait-Until 5 { (Get-UpstreamCount) -gt $before }
  Check ($code -eq '204') "$what`: curl with no proxy answers 204 (got $code)" | Out-Host
  $seen
}

# --- vps2vpn itself ---
$script:dir = Join-Path $env:ProgramFiles 'vps2vpn'
$script:exe = Join-Path $script:dir 'vps2vpn.exe'
$script:appHome = Join-Path $env:APPDATA 'vps2vpn\vps2vpn'
$script:prefs = Join-Path $script:appHome 'shared_preferences.json'
$script:appOut = $null

function Install-App($setup, $out) {
  $script:appOut = $out
  $p = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "`"/LOG=$(Join-Path $out 'install.log')`"" -Wait -PassThru
  Check ($p.ExitCode -eq 0) "vps2vpn installer exit code 0 (got $($p.ExitCode))"
}
function Import-FirstRun($url = "http://127.0.0.1:$($script:subPort)/sub.yaml") {
  $env:FLCLASH_ACCEPT_DISCLAIMER = '1'
  $env:VPS2VPN_IMPORT_URL = $url
  Start-Process $script:exe | Out-Null
  $profiles = Join-Path $script:appHome 'profiles'
  $ok = Wait-Until 60 { Get-ChildItem $profiles -File -Filter '*.yaml' -ErrorAction SilentlyContinue }
  # The file lands before the profile record; give the app time to save both.
  Start-Sleep 10
  Stop-App
  Remove-Item Env:VPS2VPN_IMPORT_URL
  $ok
}
function Edit-AppConfig([scriptblock]$edit) {
  $d = Get-Content $script:prefs -Raw | ConvertFrom-Json
  $c = $d.'flutter.config' | ConvertFrom-Json
  & $edit $c
  $d.'flutter.config' = ($c | ConvertTo-Json -Depth 50 -Compress)
  $d | ConvertTo-Json -Depth 50 -Compress | Set-Content $script:prefs -Encoding utf8
}
function Set-AppPrefs([hashtable]$settings) {
  Edit-AppConfig { param($c) foreach ($k in $settings.Keys) { $c.appSettingProps | Add-Member -Force $k $settings[$k] } }
}
function Set-Mode([bool]$tun, [bool]$systemProxy = (-not $tun)) {
  Edit-AppConfig {
    param($c)
    if (-not $c.patchClashConfig.tun) { $c.patchClashConfig | Add-Member -Force tun ([pscustomobject]@{}) }
    if (-not $c.networkProps) { $c | Add-Member -Force networkProps ([pscustomobject]@{}) }
    $c.patchClashConfig.tun | Add-Member -Force enable $tun
    $c.networkProps | Add-Member -Force systemProxy $systemProxy
  }
}
function Get-AppPort {
  $c = (Get-Content $script:prefs -Raw | ConvertFrom-Json).'flutter.config' | ConvertFrom-Json
  $port = $c.patchClashConfig.'mixed-port'
  if ($port) { [int]$port } else { 7890 }
}
function Stop-App {
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Wait-Until 15 { -not (Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue) } | Out-Null
}
function Start-App($what, $seconds = 60) {
  Start-Process $script:exe | Out-Null
  $up = Wait-Until $seconds { (Get-ListenerName (Get-AppPort)) -eq 'vps2vpnCore' }
  $port = Get-AppPort
  Check $up "$what`: vps2vpnCore listens on its mixed port $port" | Out-Host
  $port
}
function Test-AppAlive($what) {
  $app = Get-Process vps2vpn -ErrorAction SilentlyContinue | Select-Object -First 1
  Check ($app -and $app.Responding) "$what`: vps2vpn.exe is running and its window answers"
}
function Copy-AppLogs {
  if (-not $script:appOut) { return }
  $dest = Join-Path $script:appOut 'app'
  New-Item -ItemType Directory -Force $dest | Out-Null
  foreach ($d in @($script:appHome, (Join-Path $env:LOCALAPPDATA 'vps2vpn'))) {
    Get-ChildItem $d -Recurse -File -Include '*.log', '*.txt', 'config.yaml' -ErrorAction SilentlyContinue |
      Where-Object Length -lt 20MB | ForEach-Object { Copy-Item $_.FullName (Join-Path $dest "$($_.Directory.Name)-$($_.Name)") -ErrorAction SilentlyContinue }
  }
}
function Uninstall-App {
  Stop-App
  $un = Join-Path $script:dir 'unins000.exe'
  $u = Start-Process $un -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
  Wait-Until 30 { -not (Test-Path $script:exe) -and -not (Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue) } | Out-Null
  Check ($u.ExitCode -eq 0) "uninstaller exit code 0 (got $($u.ExitCode))"
}
function Test-NothingLeft($what) {
  Check (-not (Get-Process vps2vpn, vps2vpnCore, vps2vpnHelperService -ErrorAction SilentlyContinue)) "$what`: nothing of vps2vpn left running"
  Check (-not (Get-Service vps2vpnHelperService -ErrorAction SilentlyContinue)) "$what`: no Helper service left"
  Check (-not (Test-Path $script:exe)) "$what`: vps2vpn.exe removed"
  $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'vps2vpn' -or $_.Name -match 'vps2vpn' })
  $rules += @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object Program -match 'vps2vpn' | Get-NetFirewallRule -ErrorAction SilentlyContinue)
  Check ($rules.Count -eq 0) "$what`: no firewall rule left ($(($rules | ForEach-Object DisplayName) -join ', '))"
  $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vps2vpn' -or $_.InterfaceDescription -match 'vps2vpn' })
  Check ($adapters.Count -eq 0) "$what`: no vps2vpn network adapter left ($(($adapters | ForEach-Object Name) -join ', '))"
  $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
  $autorun = @($run.PSObject.Properties | Where-Object { "$($_.Value)" -match 'vps2vpn' })
  Check ($autorun.Count -eq 0) "$what`: no autostart entry left"
  $proxy = Get-WinInetProxy
  $dead = ($proxy.Flags -band 2) -and $proxy.Server -match '^127\.0\.0\.1:(\d+)$' -and -not (Get-Listener ([int]$Matches[1]))
  Check (-not $dead) "$what`: the system proxy does not point at a dead local port ($($proxy.Server), flags $($proxy.Flags))"
}

# --- WinINet per-connection proxy settings, the ones the app reads and writes ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CiWinInet {
  [StructLayout(LayoutKind.Sequential)]
  struct OptionList { public int Size; public IntPtr Connection; public int Count; public int Error; public IntPtr Options; }
  [StructLayout(LayoutKind.Explicit)]
  struct Option { [FieldOffset(0)] public int Kind; [FieldOffset(8)] public int Number; [FieldOffset(8)] public IntPtr Text; }
  [DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
  [DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool InternetQueryOption(IntPtr h, int option, IntPtr buffer, ref int length);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr mem);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr w, int msg, IntPtr wp, IntPtr lp);

  static IntPtr Pack(Option[] options, out IntPtr list) {
    int size = Marshal.SizeOf(typeof(Option));
    IntPtr array = Marshal.AllocHGlobal(size * options.Length);
    for (int i = 0; i < options.Length; i++) Marshal.StructureToPtr(options[i], array + i * size, false);
    var l = new OptionList { Size = Marshal.SizeOf(typeof(OptionList)), Connection = IntPtr.Zero, Count = options.Length, Options = array };
    list = Marshal.AllocHGlobal(l.Size);
    Marshal.StructureToPtr(l, list, false);
    return array;
  }

  public static bool Set(int flags, string server, string bypass, string pac) {
    var texts = new[] { Marshal.StringToHGlobalUni(server ?? ""), Marshal.StringToHGlobalUni(bypass ?? ""), Marshal.StringToHGlobalUni(pac ?? "") };
    var options = new[] {
      new Option { Kind = 1, Number = flags },
      new Option { Kind = 2, Text = texts[0] },
      new Option { Kind = 3, Text = texts[1] },
      new Option { Kind = 4, Text = texts[2] },
    };
    IntPtr list;
    IntPtr array = Pack(options, out list);
    bool ok = InternetSetOption(IntPtr.Zero, 75, list, Marshal.SizeOf(typeof(OptionList)));
    InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);
    InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
    foreach (var t in texts) Marshal.FreeHGlobal(t);
    Marshal.FreeHGlobal(array);
    Marshal.FreeHGlobal(list);
    return ok;
  }

  public static string[] Query() {
    var options = new[] { new Option { Kind = 1 }, new Option { Kind = 2 }, new Option { Kind = 3 }, new Option { Kind = 4 } };
    IntPtr list;
    IntPtr array = Pack(options, out list);
    int length = Marshal.SizeOf(typeof(OptionList));
    var result = new string[4];
    if (InternetQueryOption(IntPtr.Zero, 75, list, ref length)) {
      int size = Marshal.SizeOf(typeof(Option));
      for (int i = 0; i < 4; i++) {
        var o = (Option)Marshal.PtrToStructure(array + i * size, typeof(Option));
        if (i == 0) { result[0] = o.Number.ToString(); continue; }
        result[i] = o.Text == IntPtr.Zero ? "" : Marshal.PtrToStringUni(o.Text);
        if (o.Text != IntPtr.Zero) GlobalFree(o.Text);
      }
    }
    Marshal.FreeHGlobal(array);
    Marshal.FreeHGlobal(list);
    return result;
  }

  public static bool EndSession() {
    IntPtr w = FindWindow("vps2vpnSystemProxySession", null);
    if (w == IntPtr.Zero) return false;
    SendMessage(w, 0x16, new IntPtr(1), IntPtr.Zero);
    return true;
  }
}
'@

function Get-WinInetProxy {
  $r = [CiWinInet]::Query()
  [pscustomobject]@{ Flags = [int]$r[0]; Server = $r[1]; Bypass = $r[2]; Pac = $r[3] }
}
function Set-WinInetProxy([int]$flags, $server = '', $bypass = '', $pac = '') {
  [void][CiWinInet]::Set($flags, $server, $bypass, $pac)
}
function Show-Proxy($what) {
  $p = Get-WinInetProxy
  "system proxy ($what): flags=$($p.Flags) server=$($p.Server) bypass=$($p.Bypass) pac=$($p.Pac)"
}
# What Windows does to the app at shutdown or sign-out: the app gives the
# system proxy back before it dies.
function Send-EndSession { [CiWinInet]::EndSession() }

function Get-WinHttpProxy { (& netsh winhttp show proxy | Out-String).Trim() }
function Get-AdapterSummary {
  Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "$($_.Name) [$($_.InterfaceDescription)] $($_.Status)" }
}
