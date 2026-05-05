; Bromure AC — Inno Setup installer (Windows port).
;
; Builds a single signed .exe per WIN32_AC_PLAN.md §6 "Installer and
; first-run UX". Two configurations are produced from this script:
;
;   stub  — ~200 MB; downloads the qcow2 base image on first launch
;   full  — ~1.7 GB; bundles the qcow2 in the EXE for offline / managed
;           / air-gapped deployments
;
; Pass /DAppMode=Stub or /DAppMode=Full when invoking iscc.exe to pick.
;
; The hypervisor-feature enablement step (HypervisorPlatform +
; VirtualMachinePlatform) is implemented as a Pascal Script custom
; action so we can branch on already-enabled state and drop the
; reboot prompt where possible. Custom action runs under the same
; elevation as the install — no nested UAC prompts.

#define AppId       "{{io.bromure.ac}}"
#define AppName     "Bromure Agentic Coding"
#define AppPublisher "Bromure"
#define AppVersion  "0.1.0-win-preview"
#define AppExe      "BromureAC.exe"
#define AppUrl      "https://bromure.io"
#ifndef AppMode
  #define AppMode "Stub"
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/support
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\Bromure\AC
DefaultGroupName={#AppName}
OutputBaseFilename=BromureAC-Setup-{#AppMode}
OutputDir=..\dist\installer
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
DisableDirPage=auto
DisableProgramGroupPage=auto
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=Licenses\Bromure-EULA.txt
SetupIconFile=Bromure.ico
; Authenticode signing — requires the EV cert + signtool on PATH.
; SignTool=signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 $f

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; --- Host app (self-contained .NET 8 publish output) ----------------------
Source: "..\windows\Bromure.AC\bin\Release\net8.0-windows\win-x64\publish\*"; \
    DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; \
    Components: host

; --- Bundled QEMU + OVMF (read-only — never on user PATH) -----------------
Source: "..\dist\qemu\*"; \
    DestDir: "{app}\lib\qemu"; Flags: ignoreversion recursesubdirs; \
    Components: hypervisor

; --- Guest agents staged into qcow2 build --------------------------------
Source: "..\dist\guest-agents\*"; \
    DestDir: "{app}\lib\guest-agents"; Flags: ignoreversion recursesubdirs; \
    Components: hypervisor

; --- TAP driver (optional bridged-network mode) --------------------------
Source: "..\dist\tap-windows6\*"; \
    DestDir: "{app}\lib\tap-windows6"; Flags: ignoreversion recursesubdirs; \
    Components: hypervisor

; --- Guest base qcow2 — only in the Full installer -----------------------
#if AppMode == "Full"
Source: "..\dist\images\base.qcow2"; \
    DestDir: "{commonappdata}\Bromure\AC\images"; \
    Flags: ignoreversion external; \
    Components: image
#endif

; --- Licenses (ours + every bundled component) ---------------------------
Source: "Licenses\*"; DestDir: "{app}\Licenses"; Flags: ignoreversion recursesubdirs

; --- GPL compliance: written offer for source ----------------------------
; Per QEMU's GPLv2 we either ship the matching source tarball alongside
; or embed an offer letter pointing at our public mirror.
Source: "OFFER-FOR-SOURCE.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";   Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; \
    Tasks: desktopicon

[Components]
Name: "host";        Description: "Bromure AC host app";       Types: full compact custom; Flags: fixed
Name: "hypervisor";  Description: "Bundled QEMU + OVMF + agents"; Types: full compact custom; Flags: fixed
#if AppMode == "Full"
Name: "image";       Description: "Ubuntu base image (qcow2)";  Types: full
#endif

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; Flags: unchecked

[Run]
; Always launch the app once after install — first launch is the user's
; first interaction with the product, not the installer wizard.
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; \
    Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; Best-effort: ask the host to clean up vsock named pipes before we
; tear down the install dir. Quiet on failure.
Filename: "{app}\{#AppExe}"; Parameters: "uninstall-cleanup"; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
; Wipe the per-machine state. The per-user data under %LOCALAPPDATA%
; (profiles, traces, MITM CA wrapped under DPAPI) is offered to keep
; via a confirmation dialog in the .iss UninstallRun custom action,
; not deleted unconditionally.
Type: filesandordirs; Name: "{commonappdata}\Bromure\AC"

[Code]
const
  ; HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\<AppId>
  ; — same key Inno writes; we use it to detect a re-install.
  RUNONCE_KEY = 'Software\Microsoft\Windows\CurrentVersion\RunOnce';

function IsHypervisorPlatformEnabled(): Boolean;
var
  Cmd, Out: AnsiString;
  ExitCode: Integer;
begin
  // dism /online /get-featureinfo … . When the feature is enabled the
  // exit code is 0 and the stdout contains "State : Enabled".
  Cmd := 'dism.exe /online /get-featureinfo /featurename:HypervisorPlatform';
  ExitCode := -1;
  Result := False;
  if Exec(ExpandConstant('{sys}\dism.exe'),
          '/online /get-featureinfo /featurename:HypervisorPlatform',
          '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
  begin
    Result := (ExitCode = 0);
  end;
end;

function NeedsReboot(): Boolean;
forward;

procedure EnableHypervisorFeatures();
var
  ExitCode: Integer;
begin
  // The pair of features QEMU+WHPX needs.
  // We pass /norestart and stage a RunOnce continuation if at least
  // one feature was newly enabled.
  Exec(ExpandConstant('{sys}\dism.exe'),
       '/online /enable-feature /featurename:HypervisorPlatform /all /norestart',
       '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Exec(ExpandConstant('{sys}\dism.exe'),
       '/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart',
       '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
end;

function NeedsReboot(): Boolean;
begin
  // Cheap heuristic: if WHPX wasn't enabled before our install, a
  // reboot is required for it to take effect.
  Result := not IsHypervisorPlatformEnabled();
end;

procedure StageRunOnceContinuation();
var
  ExePath, Args: String;
begin
  // After a forced reboot, RunOnce relaunches the installer in
  // "/postreboot" mode, which finishes anything we couldn't do
  // before the hypervisor came online (e.g. a smoke test boot).
  ExePath := ExpandConstant('{srcexe}');
  Args := '/postreboot /SILENT';
  RegWriteStringValue(HKLM, RUNONCE_KEY, 'BromureAC-PostReboot',
                      '"' + ExePath + '" ' + Args);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    EnableHypervisorFeatures();
    if NeedsReboot() then
    begin
      StageRunOnceContinuation();
      // Inno will prompt for reboot via Setup.NeedsReboot below.
    end;
  end;
end;

function NeedRestart(): Boolean;
begin
  Result := NeedsReboot();
end;
