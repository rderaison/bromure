; Bromure Sidecar for Windows — per-user installer (no admin).
;
; Build on Windows with Inno Setup 6.3+ (scripts/installer.ps1 does it):
;   ISCC.exe /DAppVersion=1.2.3 /DArch=x64   installer\BromureSidecar.iss
;   ISCC.exe /DAppVersion=1.2.3 /DArch=arm64 installer\BromureSidecar.iss
; It expects the binaries in dist\windows-amd64\ (or windows-arm64), as
; scripts/build.sh lays them out. Signing: add /DSign and define the sign
; tool on the command line, e.g.
;   /Ssigntool="signtool.exe sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p ... $f"
;
; Upgrades: the tray and the daemon are stopped before the files are
; replaced and started again after (silent updates included). The pane host
; runs from its own copy in %LOCALAPPDATA%\BromureSidecar\bin, so agents
; keep running through an update.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define DistDir "..\dist\windows-arm64"
  #define ArchAllowed "arm64"
#else
  #define DistDir "..\dist\windows-amd64"
  #define ArchAllowed "x64compatible"
#endif

[Setup]
AppId={{6F1E5C2A-8B3D-4E7A-9C1F-B5D2A0E4C7B9}
AppName=Bromure Sidecar
AppVersion={#AppVersion}
AppVerName=Bromure Sidecar {#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Bromure
AppPublisherURL=https://bromure.io
DefaultDirName={localappdata}\Programs\Bromure Sidecar
DefaultGroupName=Bromure Sidecar
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}
OutputDir=..\dist
OutputBaseFilename=BromureSidecar-{#AppVersion}-{#Arch}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dynamic
SetupIconFile=..\cmd\BromureSidecar\assets\app.ico
UninstallDisplayIcon={app}\BromureSidecar.exe
UninstallDisplayName=Bromure Sidecar
CloseApplications=no
RestartApplications=no
MinVersion=10.0.17763
#ifdef Sign
SignTool=signtool
SignedUninstaller=yes
#endif

[Files]
Source: "{#DistDir}\bromure-sidecar.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DistDir}\BromureSidecar.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Bromure Sidecar"; Filename: "{app}\BromureSidecar.exe"

[Registry]
; bromure-agent-host:// → the tray, which hands the link to the daemon.
Root: HKCU; Subkey: "Software\Classes\bromure-agent-host"; ValueType: string; ValueName: ""; ValueData: "URL:Bromure Sidecar"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\bromure-agent-host"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\bromure-agent-host\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\BromureSidecar.exe"" ""%1"""
; Start at login.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "BromureSidecar"; ValueData: """{app}\BromureSidecar.exe"""; Flags: uninsdeletevalue

[Tasks]
Name: "git"; Description: "Install Git for Windows (Git Bash) with winget — agents and Bromure AC's commands run under it"; Check: not GitInstalled
Name: "webview"; Description: "Install the Microsoft Edge WebView2 Runtime — Bromure Sidecar's window draws with it"; Check: not WebView2Installed

[Run]
Filename: "winget.exe"; Parameters: "install --id Git.Git -e --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity"; Tasks: git; StatusMsg: "Installing Git for Windows…"; Flags: runhidden waituntilterminated
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; Tasks: webview; StatusMsg: "Installing the WebView2 Runtime…"; Flags: waituntilterminated skipifdoesntexist
; Interactive installs: offer to start; silent ones (updates): start again.
Filename: "{app}\BromureSidecar.exe"; Description: "Start Bromure Sidecar"; Flags: nowait postinstall skipifsilent
Filename: "{app}\BromureSidecar.exe"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{app}\bromure-sidecar.exe"; Parameters: "ctl quit"; Flags: runhidden; RunOnceId: "StopDaemon"
Filename: "{sys}\taskkill.exe"; Parameters: "/IM BromureSidecar.exe /F"; Flags: runhidden; RunOnceId: "StopTray"

[Code]
function GitInstalled(): Boolean;
var
  P: String;
begin
  Result := RegQueryStringValue(HKLM, 'SOFTWARE\GitForWindows', 'InstallPath', P)
    or RegQueryStringValue(HKCU, 'SOFTWARE\GitForWindows', 'InstallPath', P)
    or FileExists(ExpandConstant('{commonpf}\Git\bin\bash.exe'))
    or FileExists(ExpandConstant('{localappdata}\Programs\Git\bin\bash.exe'));
end;

// The Evergreen runtime registers its version (pv) per machine or per user.
const
  WebView2Key = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function WebView2Installed(): Boolean;
var
  V, Key: String;
begin
  Key := WebView2Key;
  Result := (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\' + Key, 'pv', V) and (V <> '') and (V <> '0.0.0.0'))
    or (RegQueryStringValue(HKLM, 'SOFTWARE\' + Key, 'pv', V) and (V <> '') and (V <> '0.0.0.0'))
    or (RegQueryStringValue(HKCU, 'Software\' + Key, 'pv', V) and (V <> '') and (V <> '0.0.0.0'));
end;

// Before the files are replaced: the tray and the daemon go (the pane host
// and its agents stay), and the WebView2 bootstrapper is fetched if asked.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Exe: String;
begin
  Result := '';
  Exe := ExpandConstant('{app}\bromure-sidecar.exe');
  if FileExists(Exe) then
    Exec(Exe, 'ctl quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM BromureSidecar.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(1000);
  if WizardIsTaskSelected('webview') then begin
    try
      DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703', 'MicrosoftEdgeWebview2Setup.exe', '', nil);
    except
      Log('WebView2 bootstrapper download failed: ' + GetExceptionMessage);
    end;
  end;
end;

// Agents running in the pane host die when it is stopped: ask first.
function InitializeUninstall(): Boolean;
var
  Code: Integer;
  Exe: String;
begin
  Result := True;
  Exe := ExpandConstant('{app}\bromure-sidecar.exe');
  if FileExists(Exe) then begin
    Exec(Exe, 'ctl /sidecar/panehost-stop {"force":false}', '', SW_HIDE, ewWaitUntilTerminated, Code);
    if Code <> 0 then begin
      if MsgBox('Agents are still running in Bromure Sidecar. Uninstalling stops them. Continue?', mbConfirmation, MB_YESNO) = IDNO then begin
        Result := False;
        exit;
      end;
      Exec(Exe, 'ctl /sidecar/panehost-stop {"force":true}', '', SW_HIDE, ewWaitUntilTerminated, Code);
    end;
  end;
end;
