[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}

[Code]
const
  SYNCHRONIZE = $00100000;

function OpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function SetEnvironmentVariable(lpName, lpValue: String): BOOL;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

// The app passes /updatefrom=<pid> (windowsUpdateArguments in lib/common)
// and exits on its own, stopping the Core and clearing the system proxy.
function UpdatingAppPid: Integer;
begin
  Result := StrToIntDef(ExpandConstant('{param:updatefrom|0}'), 0);
end;

function IsAppUpdate: Boolean;
begin
  Result := UpdatingAppPid > 0;
end;

procedure WaitForUpdatingApp;
var
  Handle: THandle;
begin
  if not IsAppUpdate then
    Exit;
  Handle := OpenProcess(SYNCHRONIZE, False, UpdatingAppPid);
  if Handle <> 0 then
  begin
    WaitForSingleObject(Handle, 15000);
    CloseHandle(Handle);
  end;
end;

// FlClash and FlClash rs ship processes of the same names, so a name alone
// would also end the other installation's.
procedure KillProcesses;
var
  AppDir: String;
  PowerShellPath: String;
  ResultCode: Integer;
begin
  AppDir := AddBackslash(ExpandConstant('{app}'));
  if AppDir = '' then
    Exit;
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if SetEnvironmentVariable('VPS2VPN_APP_DIR', AppDir) then
  begin
    try
      Exec(PowerShellPath,
        // Win32_Process sees the path of SYSTEM processes (the Helper and the
        // Core it starts), which Get-Process leaves empty on PowerShell 5.1.
        '-NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process | ' +
        'Where-Object { @(''vps2vpn.exe'',''vps2vpnCore.exe'',''vps2vpnHelperService.exe'') -contains $_.Name -and $_.ExecutablePath -and ' +
        '$_.ExecutablePath.StartsWith($env:VPS2VPN_APP_DIR, [StringComparison]::OrdinalIgnoreCase) } | ' +
        'ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    finally
      SetEnvironmentVariable('VPS2VPN_APP_DIR', '');
    end;
  end;
end;

procedure UnregisterHelperService;
var
  HelperPath: String;
  ScPath: String;
  ResultCode: Integer;
  Unregistered: Boolean;
begin
  HelperPath := ExpandConstant('{app}\vps2vpnHelperService.exe');
  Unregistered := False;
  if FileExists(HelperPath) then
  begin
    if Exec(HelperPath, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      Unregistered := True;
  end;
  if not Unregistered then
  begin
    ScPath := ExpandConstant('{sys}\sc.exe');
    Exec(ScPath, 'stop vps2vpnHelperService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(ScPath, 'delete vps2vpnHelperService', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure ClearStaleProxy;
var
  AppPath: String;
  ResultCode: Integer;
begin
  AppPath := ExpandConstant('{app}\{{EXECUTABLE_NAME}}');
  if FileExists(AppPath) then
  begin
    Exec(AppPath, '--clear-stale-proxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

function PointsIntoApp(Value: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(Value)) > 0;
end;

// The value name is appName, which DISPLAY_NAME follows, and the schemes are
// protocolSchemes, both in lib/common.
procedure RemoveUserRegistrations;
var
  Schemes: TArrayOfString;
  Value: String;
  i: Integer;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{DISPLAY_NAME}}', Value) and PointsIntoApp(Value) then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{DISPLAY_NAME}}');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', '{{DISPLAY_NAME}}');
  end;

  Schemes := ['vps2vpn'];
  for i := 0 to GetArrayLength(Schemes)-1 do
  begin
    if RegQueryStringValue(HKCU, 'Software\Classes\' + Schemes[i] + '\shell\open\command', '', Value) and PointsIntoApp(Value) then
    begin
      RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\' + Schemes[i]);
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  WaitForUpdatingApp;
  UnregisterHelperService;
  KillProcesses;
  Result := '';
end;

// path_provider names these folders after CompanyName and ProductName in
// windows/runner/Runner.rc.
procedure RemoveUserData;
begin
  // vps2vpn's own folders only. com.follow\clash belongs to FlClash, which
  // may be installed next to us; never touch it.
  DelTree(ExpandConstant('{userappdata}\vps2vpn\vps2vpn'), True, True, True);
  DelTree(ExpandConstant('{localappdata}\vps2vpn\vps2vpn'), True, True, True);
  RemoveDir(ExpandConstant('{userappdata}\vps2vpn'));
  RemoveDir(ExpandConstant('{localappdata}\vps2vpn'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    UnregisterHelperService;
    KillProcesses;
    ClearStaleProxy;
  end
  else if CurUninstallStep = usPostUninstall then
  begin
    RemoveUserRegistrations;
    if not UninstallSilent and (MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES) then
    begin
      RemoveUserData;
    end;
  end;
end;

[Languages]
Name: "chineseSimplified"; MessagesFile: "{{CHINESE_SIMPLIFIED_MESSAGES}}"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
english.RemoveUserData=Also delete your profiles and settings?
chineseSimplified.RemoveUserData=同时删除配置和设置？

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
[Files]
Source: "{{SOURCE_DIR}}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

; vps2vpn:// links (the "open in vps2vpn" buttons on the member and deploy
; pages) must work before the app has ever run: the app registers the scheme
; for the current user only when it starts. HKA is HKLM here (admin install),
; so every user of the PC gets it, including when a standard user elevated
; with another account's password; the app's own HKCU entry, written to the
; same path, takes precedence once it runs. Keep it in step with
; url_command in plugins/rust_api/rust/src/launch/entries.rs.
[Registry]
Root: HKA; Subkey: "Software\Classes\vps2vpn"; ValueType: string; ValueName: ""; ValueData: "URL:vps2vpn"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\vps2vpn"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\vps2vpn\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{{EXECUTABLE_NAME}}"",0"
Root: HKA; Subkey: "Software\Classes\vps2vpn\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{{EXECUTABLE_NAME}}"" ""%1"""

[Icons]
Name: "{autoprograms}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\{{EXECUTABLE_NAME}}"; Parameters: "--clear-stale-proxy"; Flags: runasoriginaluser runhidden waituntilterminated
Filename: "{app}\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: runasoriginaluser nowait postinstall skipifsilent; Check: not IsAppUpdate
Filename: "{app}\{{EXECUTABLE_NAME}}"; Flags: runasoriginaluser nowait; Check: IsAppUpdate
