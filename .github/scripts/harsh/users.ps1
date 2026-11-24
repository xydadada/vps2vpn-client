# vps2vpn for a standard (non-admin) account whose name and profile path hold
# Chinese and a space, running next to the admin who installed it; and that
# account must not drive the admin's Helper or open the admin's Core pipe.
param([Parameter(Mandatory)][string]$Setup, [string]$Out = 'harsh')
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

$userName = '测试 用户'
$shared = 'C:\Users\Public\harsh'
New-Item -ItemType Directory -Force $shared | Out-Null
& icacls $shared /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null

function Get-LocalGroupName($sid) {
  ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value.Split([char]92)[-1]  # [char]92 is the backslash in BUILTIN\Users
}

function Invoke-AsUser($credential, $script, $name, $seconds = 120) {
  $file = Join-Path $shared "$name.ps1"
  $result = Join-Path $shared "$name.json"
  Remove-Item $result -ErrorAction SilentlyContinue
  # Start-Process -Credential hands the child OUR environment, so APPDATA and
  # USERPROFILE would still name runneradmin's folders. Take the account's own
  # from its loaded profile before anything else runs.
  $lines = $script -split "`n", 2
  $prelude = @'
$env:USERPROFILE = [Environment]::GetFolderPath('UserProfile')
$env:HOMEDRIVE = Split-Path $env:USERPROFILE -Qualifier
$env:HOMEPATH = $env:USERPROFILE.Substring($env:HOMEDRIVE.Length)
$env:APPDATA = Join-Path $env:USERPROFILE 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
$env:TEMP = $env:TMP = Join-Path $env:LOCALAPPDATA 'Temp'
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
'@
  Set-Content $file ($lines[0] + "`n" + $prelude + "`n" + $lines[1]) -Encoding utf8
  $p = Start-Process pwsh -Credential $credential -LoadUserProfile -WorkingDirectory $shared -WindowStyle Hidden -PassThru `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file, $result
  if (-not $p.WaitForExit($seconds * 1000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if (Test-Path $result) { Get-Content $result -Raw | ConvertFrom-Json } else { $null }
}

try {
  Start-Upstream $Out
  Install-App $Setup $Out

  # The admin's own app with TUN: that registers the Helper for the admin.
  Check (Import-FirstRun) 'admin: subscription imported on first run'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $true $false
  Start-Process $script:exe | Out-Null
  Check (Wait-Until 120 { (Get-Service vps2vpnHelperService -ErrorAction SilentlyContinue).Status -eq 'Running' }) 'admin: the Helper service runs'
  $adminPort = Get-AppPort
  Check (Wait-Until 60 { Get-ListenerName $adminPort }) "admin: the Core listens on $adminPort"
  $adminCore = (Get-Listener $adminPort).OwningProcess
  $pipes = @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'FlClashCore_' })
  "admin Core pipes: $($pipes.Count)"

  # The standard account.
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  $password = (-join (1..20 | ForEach-Object { $chars | Get-Random })) + '!9a'
  $secure = ConvertTo-SecureString $password -AsPlainText -Force
  # ADSI, not New-LocalUser: in pwsh 7 the LocalAccounts cmdlets go through
  # Windows PowerShell compatibility, which split this name at its space.
  $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
  $account = $computer.Create('User', $userName)
  $account.SetPassword($password)
  $account.Put('UserFlags', 0x10000)  # password never expires
  $account.SetInfo()
  $usersGroup = Get-LocalGroupName 'S-1-5-32-545'
  ([ADSI]"WinNT://$env:COMPUTERNAME/$usersGroup,group").Add("WinNT://$env:COMPUTERNAME/$userName,user")
  $credential = [pscredential]::new("$env:COMPUTERNAME\$userName", $secure)
  $admins = ([ADSI]"WinNT://$env:COMPUTERNAME/$(Get-LocalGroupName 'S-1-5-32-544'),group").psbase.Invoke('Members') |
    ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) }
  Check ($admins -notcontains $userName) 'the second account is not an administrator'

  $probe = @"
param(`$result)
`$r = [ordered]@{ user = [Environment]::UserName; profile = `$env:USERPROFILE }
try {
  `$c = [System.Net.Sockets.TcpClient]::new()
  `$c.Connect('127.0.0.1', 47990)
  `$s = `$c.GetStream(); `$s.ReadTimeout = 5000
  `$req = [Text.Encoding]::ASCII.GetBytes("GET /ping HTTP/1.1``r``nHost: 127.0.0.1``r``nConnection: close``r``n``r``n")
  `$s.Write(`$req, 0, `$req.Length)
  `$buf = New-Object byte[] 4096; `$n = `$s.Read(`$buf, 0, 4096)
  `$r.helper = if (`$n -gt 0) { [Text.Encoding]::ASCII.GetString(`$buf, 0, `$n).Split("``n")[0].Trim() } else { 'closed' }
} catch { `$r.helper = 'refused: ' + `$_.Exception.InnerException.Message + `$_.Exception.Message }
`$r.pipes = @()
foreach (`$p in [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { `$_ -match 'FlClashCore_' }) {
  try {
    `$client = [IO.Pipes.NamedPipeClientStream]::new('.', (`$p -replace '^\\\\\.\\pipe\\', ''), [IO.Pipes.PipeDirection]::InOut)
    `$client.Connect(3000); `$client.Dispose(); `$r.pipes += 'opened'
  } catch { `$r.pipes += `$_.Exception.GetType().Name }
}
`$r | ConvertTo-Json | Set-Content `$result -Encoding utf8
"@
  $seen = Invoke-AsUser $credential $probe 'probe' 60
  Check ($seen -and $seen.user -eq $userName) "the second account runs as $userName (profile $($seen.profile))"
  if ($seen) {
    "helper from the second account: $($seen.helper)"
    Check ($seen.helper -notmatch ' 200') "the second account cannot use the admin's Helper ($($seen.helper))"
    "pipes from the second account: $($seen.pipes -join ', ')"
    Check (@($seen.pipes | Where-Object { $_ -eq 'opened' }).Count -eq 0) "the second account cannot open the admin's Core pipe ($($seen.pipes.Count) tried)"
  }

  # The second account runs vps2vpn itself, in proxy mode, beside the admin.
  $run = @"
param(`$result)
`$env:FLCLASH_ACCEPT_DISCLAIMER = '1'
`$env:VPS2VPN_IMPORT_URL = 'http://127.0.0.1:$($script:subPort)/sub.yaml'
`$app = Start-Process '$($script:exe)' -PassThru
Start-Sleep 40
`$home_ = Join-Path `$env:APPDATA 'vps2vpn\vps2vpn'
# Connect on the next start, as a user who set it to.
`$prefs = Join-Path `$home_ 'shared_preferences.json'
if (Test-Path `$prefs) {
  # Only this account's copies: the admin's are closed to a standard account.
  Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 3
  `$d = Get-Content `$prefs -Raw | ConvertFrom-Json
  `$c = `$d.'flutter.config' | ConvertFrom-Json
  `$c.appSettingProps | Add-Member -Force autoRun `$true
  `$d.'flutter.config' = (`$c | ConvertTo-Json -Depth 50 -Compress)
  `$d | ConvertTo-Json -Depth 50 -Compress | Set-Content `$prefs -Encoding utf8
  `$app = Start-Process '$($script:exe)' -PassThru
  Start-Sleep 45
}
`$r = [ordered]@{
  running = -not `$app.HasExited
  exitCode = if (`$app.HasExited) { `$app.ExitCode } else { `$null }
  home = `$home_
  files = @(Get-ChildItem `$home_ -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { `$_.FullName.Substring(`$home_.Length) })
  profiles = @(Get-ChildItem (Join-Path `$home_ 'profiles') -File -ErrorAction SilentlyContinue).Count
  prefs = Test-Path (Join-Path `$home_ 'shared_preferences.json')
}
`$r | ConvertTo-Json | Set-Content `$result -Encoding utf8
"@
  $app = Invoke-AsUser $credential $run 'run' 180
  Check ($app -and $app.running) 'second account: vps2vpn starts and keeps running'
  if ($app) {
    "second account home: $($app.home), exit code: $($app.exitCode)"
    "second account files: $($app.files -join ', ')"
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-3) } -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'vps2vpn' } | Select-Object -First 5 | ForEach-Object { "event $($_.Id) $($_.ProviderName): $($_.Message -replace '\s+', ' ')" }
    Check ($app.home -match [regex]::Escape($userName)) 'second account: its data lives under the path with Chinese and a space'
    Check ($app.profiles -gt 0) 'second account: the subscription imported'
  }
  # Who holds which port: the admin's Core must keep its own, the second one gets another.
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 7890..7899 -or $_.LocalPort -in 17890..17990 } |
    ForEach-Object { $o = Get-Process -Id $_.OwningProcess -IncludeUserName -ErrorAction SilentlyContinue; "listen $($_.LocalAddress):$($_.LocalPort) pid $($_.OwningProcess) $($o.Name) $($o.UserName)" }
  $theirs = @(Get-Process vps2vpnCore -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match ([regex]::Escape($userName)))
  Check ($theirs.Count -gt 0) 'second account: its own Core runs under its own account'
  if ($theirs) {
    $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $theirs[0].Id -ErrorAction SilentlyContinue | Where-Object LocalAddress -eq '127.0.0.1' | ForEach-Object LocalPort | Sort-Object -Unique)
    "second account Core listens on: $($ports -join ', ')"
    $mixed = $ports | Where-Object { $_ -ne $adminPort } | Select-Object -First 1
    Check ($mixed -and $mixed -ne $adminPort) "second account: a port of its own ($mixed, admin on $adminPort)"
    if ($mixed) { Test-Through $mixed 'second account' }
  }
  Check (@(Get-NetTCPConnection -State Listen -LocalPort $adminPort -OwningProcess $adminCore -ErrorAction SilentlyContinue).Count -gt 0) "admin: its own Core (pid $adminCore) still listens on $adminPort with the second account running"
  Test-AppAlive 'admin'

  Get-Process vps2vpn, vps2vpnCore -IncludeUserName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Uninstall-App
  Test-NothingLeft 'after uninstall'
} finally {
  Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match ([regex]::Escape($userName)) | Stop-Process -Force -ErrorAction SilentlyContinue
  try { ([ADSI]"WinNT://$env:COMPUTERNAME,computer").Delete('User', $userName) } catch {}
  Finish
}
