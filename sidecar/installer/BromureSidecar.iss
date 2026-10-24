; Bromure Sidecar for Windows — per-user installer (no admin).
; Build on Windows with Inno Setup 6:
;   ISCC.exe /DAppVersion=1.2.3 /DArch=x64 installer\BromureSidecar.iss
; It expects the binaries in dist\windows-amd64\ (or windows-arm64 with
; /DArch=arm64), as scripts/build.sh lays them out.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define DistDir "..\dist\windows-arm64"
#else
  #define DistDir "..\dist\windows-amd64"
#endif

[Setup]
AppId={{6F1E5C2A-8B3D-4E7A-9C1F-B5D2A0E4C7B9}
AppName=Bromure Sidecar
AppVersion={#AppVersion}
AppPublisher=Bromure
DefaultDirName={localappdata}\Programs\Bromure Sidecar
DefaultGroupName=Bromure Sidecar
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed={#Arch}compatible
ArchitecturesInstallIn64BitMode={#Arch}compatible
OutputDir=..\dist
OutputBaseFilename=BromureSidecar-{#AppVersion}-{#Arch}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\cmd\BromureSidecar\assets\app.ico
UninstallDisplayIcon={app}\BromureSidecar.exe
CloseApplications=no
MinVersion=10.0.17763

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
Name: "git"; Description: "Install Git for Windows (Git Bash) with winget — needed to run agents and Bromure AC's commands"; Check: not GitInstalled

[Run]
Filename: "winget.exe"; Parameters: "install --id Git.Git -e --scope user --accept-source-agreements --accept-package-agreements"; Tasks: git; StatusMsg: "Installing Git for Windows…"; Flags: runhidden waituntilterminated
Filename: "{app}\BromureSidecar.exe"; Description: "Start Bromure Sidecar"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the tray and the daemon (the pane host goes last, below).
Filename: "{app}\bromure-sidecar.exe"; Parameters: "ctl quit"; Flags: runhidden; RunOnceId: "StopDaemon"
Filename: "taskkill.exe"; Parameters: "/IM BromureSidecar.exe /F"; Flags: runhidden; RunOnceId: "StopTray"

[Code]
function GitInstalled(): Boolean;
var
  P: String;
begin
  Result := RegQueryStringValue(HKLM, 'SOFTWARE\GitForWindows', 'InstallPath', P)
    or RegQueryStringValue(HKCU, 'SOFTWARE\GitForWindows', 'InstallPath', P)
    or FileExists(ExpandConstant('{pf}\Git\bin\bash.exe'))
    or FileExists(ExpandConstant('{localappdata}\Programs\Git\bin\bash.exe'));
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
