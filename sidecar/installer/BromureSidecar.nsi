; Bromure Sidecar for Windows — per-user installer (no admin), built with
; NSIS 3.08+ on macOS or Linux (scripts/installer.sh does it):
;   makensis -DVERSION=1.2.3 -DARCH=x64   installer/BromureSidecar.nsi
;   makensis -DVERSION=1.2.3 -DARCH=arm64 installer/BromureSidecar.nsi
; It expects the binaries in dist/windows-amd64/ (or windows-arm64), as
; scripts/build.sh lays them out. Signing: -DSIGN_SCRIPT=/abs/esign.sh signs
; the uninstaller before it's embedded and the setup once it's written
; (!uninstfinalize / !finalize); the secrets stay in the environment.
;
; Silent (/S, what the updater runs): no extras are installed, the tray and
; the daemon are stopped before the files are replaced and started again
; after. The pane host runs from its own copy in
; %LOCALAPPDATA%\BromureSidecar\bin, so agents keep running through it.

Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef ARCH
  !define ARCH "x64"
!endif
; Build-time paths use "/" (makensis runs on macOS/Linux).
!if "${ARCH}" == "arm64"
  !define DISTDIR "../dist/windows-arm64"
!else
  !define DISTDIR "../dist/windows-amd64"
!endif

!define APPNAME "Bromure Sidecar"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\BromureSidecar"
; Releases up to 0.2.0 were Inno Setup installs (AppId {6F1E5C2A-…}) into the
; same folder; their entry and unins000.exe must not outlive the switch.
!define INNOKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F1E5C2A-8B3D-4E7A-9C1F-B5D2A0E4C7B9}_is1"
!define WEBVIEW2KEY "Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

Name "${APPNAME}"
OutFile "../dist/BromureSidecar-${VERSION}-${ARCH}.exe"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "${UNINSTKEY}" "InstallLocation"
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIFileVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "Bromure"
VIAddVersionKey "FileDescription" "${APPNAME} Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Bromure"

!ifdef SIGN_SCRIPT
  !uninstfinalize '"${SIGN_SCRIPT}" "%1"' = 0
  !finalize '"${SIGN_SCRIPT}" "%1"' = 0
!endif

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "Sections.nsh"

!define MUI_ICON "../cmd/BromureSidecar/assets/app.ico"
!define MUI_UNICON "../cmd/BromureSidecar/assets/app.ico"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_NODESC
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipComponents
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\BromureSidecar.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME}"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Retires an Inno Setup install of Sidecar without running its uninstaller
; (that would stop the pane host and the agents in it, and remove the URL
; scheme and the Run entry this installer writes): its own files go (the
; executables too, but only when they live outside $INSTDIR) and so does its
; uninstall entry. Install and uninstall both run it, so no entry is left
; behind that could later remove the NSIS install.
!macro RetireInno
  ReadRegStr $R0 HKCU "${INNOKEY}" "Inno Setup: App Path"
  ${If} $R0 != ""
    Delete "$R0\unins0*.exe"
    Delete "$R0\unins0*.dat"
    Delete "$R0\unins0*.msg"
    ${If} $R0 != $INSTDIR
      Delete "$R0\bromure-sidecar.exe"
      Delete "$R0\BromureSidecar.exe"
      RMDir "$R0"
    ${EndIf}
  ${EndIf}
  ; Its files may outlive the entry.
  Delete "$INSTDIR\unins0*.exe"
  Delete "$INSTDIR\unins0*.dat"
  Delete "$INSTDIR\unins0*.msg"
  DeleteRegKey HKCU "${INNOKEY}"
!macroend

Var GitMissing
Var WebView2Missing

Section "-${APPNAME}" SecMain
  SetShellVarContext current
  ; Before the files are replaced: the tray and the daemon go (the pane
  ; host and its agents stay).
  ${If} ${FileExists} "$INSTDIR\bromure-sidecar.exe"
    nsExec::Exec '"$INSTDIR\bromure-sidecar.exe" ctl quit'
    Pop $0
  ${EndIf}
  nsExec::Exec '"$SYSDIR\taskkill.exe" /IM BromureSidecar.exe /F'
  Pop $0
  Sleep 1000

  !insertmacro RetireInno

  SetOutPath "$INSTDIR"
  File "${DISTDIR}/bromure-sidecar.exe"
  File "${DISTDIR}/BromureSidecar.exe"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\BromureSidecar.exe"

  ; bromure-agent-host:// → the tray, which hands the link to the daemon.
  WriteRegStr HKCU "Software\Classes\bromure-agent-host" "" "URL:${APPNAME}"
  WriteRegStr HKCU "Software\Classes\bromure-agent-host" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\bromure-agent-host\shell\open\command" "" '"$INSTDIR\BromureSidecar.exe" "%1"'
  ; Start at login.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "BromureSidecar" '"$INSTDIR\BromureSidecar.exe"'

  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "Bromure"
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "https://bromure.io"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\BromureSidecar.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Section "Install Git for Windows (Git Bash) with winget — agents and Bromure AC's commands run under it" SecGit
  DetailPrint "Installing Git for Windows…"
  nsExec::ExecToLog 'winget.exe install --id Git.Git -e --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity'
  Pop $0
  DetailPrint "winget: $0"
SectionEnd

Section "Install the Microsoft Edge WebView2 Runtime — Bromure Sidecar's window draws with it" SecWebView2
  DetailPrint "Installing the WebView2 Runtime…"
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -Command "Invoke-WebRequest -UseBasicParsing -Uri https://go.microsoft.com/fwlink/p/?LinkId=2124703 -OutFile $\"$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe$\""'
  Pop $0
  ${If} ${FileExists} "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
    ExecWait '"$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $0
    DetailPrint "WebView2 bootstrapper: $0"
  ${Else}
    DetailPrint "WebView2 bootstrapper download failed"
  ${EndIf}
SectionEnd

Function .onInit
  InitPluginsDir
  ${IfNot} ${AtLeastBuild} 17763
    MessageBox MB_ICONSTOP "${APPNAME} needs Windows 10 version 1809 or later." /SD IDOK
    Abort
  ${EndIf}
!if "${ARCH}" == "arm64"
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_ICONSTOP "This is the ARM64 build of ${APPNAME}; download the x64 one for this PC." /SD IDOK
    Abort
  ${EndIf}
!else
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "${APPNAME} needs 64-bit Windows." /SD IDOK
    Abort
  ${EndIf}
!endif
  SetRegView 64

  ; Git: Git for Windows' registration or its usual bash.exe.
  StrCpy $GitMissing 1
  ReadRegStr $0 HKLM "SOFTWARE\GitForWindows" "InstallPath"
  ReadRegStr $1 HKCU "SOFTWARE\GitForWindows" "InstallPath"
  ${If} $0 != ""
  ${OrIf} $1 != ""
  ${OrIf} ${FileExists} "$PROGRAMFILES64\Git\bin\bash.exe"
  ${OrIf} ${FileExists} "$LOCALAPPDATA\Programs\Git\bin\bash.exe"
    StrCpy $GitMissing 0
  ${EndIf}

  ; WebView2: the Evergreen runtime registers its version (pv) per machine
  ; or per user.
  StrCpy $WebView2Missing 1
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\${WEBVIEW2KEY}" "pv"
  ReadRegStr $1 HKLM "SOFTWARE\${WEBVIEW2KEY}" "pv"
  ReadRegStr $2 HKCU "Software\${WEBVIEW2KEY}" "pv"
  ${If} $0 != ""
  ${AndIf} $0 != "0.0.0.0"
    StrCpy $WebView2Missing 0
  ${ElseIf} $1 != ""
  ${AndIf} $1 != "0.0.0.0"
    StrCpy $WebView2Missing 0
  ${ElseIf} $2 != ""
  ${AndIf} $2 != "0.0.0.0"
    StrCpy $WebView2Missing 0
  ${EndIf}

  ; Extras are offered only when missing, and never in a silent install
  ; (an update must not start installing other software).
  ${If} $GitMissing == 0
  ${OrIf} ${Silent}
    !insertmacro UnselectSection ${SecGit}
    SectionSetText ${SecGit} ""
  ${EndIf}
  ${If} $WebView2Missing == 0
  ${OrIf} ${Silent}
    !insertmacro UnselectSection ${SecWebView2}
    SectionSetText ${SecWebView2} ""
  ${EndIf}
FunctionEnd

; Nothing to choose: no components page.
Function SkipComponents
  ${If} $GitMissing == 0
  ${AndIf} $WebView2Missing == 0
    Abort
  ${EndIf}
FunctionEnd

; Silent installs (updates) start the tray again; interactive ones offer it
; on the finish page.
Function .onInstSuccess
  ${If} ${Silent}
    Exec '"$INSTDIR\BromureSidecar.exe"'
  ${EndIf}
FunctionEnd

; Agents running in the pane host die when it is stopped: ask first. The
; JSON's quotes are escaped so the Go side's argv parsing keeps them.
Function un.onInit
  SetRegView 64
  IfFileExists "$INSTDIR\bromure-sidecar.exe" 0 done
  nsExec::Exec '"$INSTDIR\bromure-sidecar.exe" ctl /sidecar/panehost-stop "{\"force\":false}"'
  Pop $0
  StrCmp $0 "0" done
  MessageBox MB_YESNO|MB_ICONQUESTION "Agents are still running in ${APPNAME}. Uninstalling stops them. Continue?" /SD IDYES IDYES force
  Abort
force:
  nsExec::Exec '"$INSTDIR\bromure-sidecar.exe" ctl /sidecar/panehost-stop "{\"force\":true}"'
  Pop $0
done:
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  ${If} ${FileExists} "$INSTDIR\bromure-sidecar.exe"
    nsExec::Exec '"$INSTDIR\bromure-sidecar.exe" ctl quit'
    Pop $0
  ${EndIf}
  nsExec::Exec '"$SYSDIR\taskkill.exe" /IM BromureSidecar.exe /F'
  Pop $0
  Sleep 1000
  Delete "$INSTDIR\bromure-sidecar.exe"
  Delete "$INSTDIR\BromureSidecar.exe"
  Delete "$INSTDIR\uninstall.exe"
  !insertmacro RetireInno
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  DeleteRegKey HKCU "Software\Classes\bromure-agent-host"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "BromureSidecar"
  DeleteRegKey HKCU "${UNINSTKEY}"
SectionEnd
