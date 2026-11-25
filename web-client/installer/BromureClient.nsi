; Bromure Client for Windows — per-user installer (no admin), built with
; NSIS 3.08+ on Windows, macOS or Linux (scripts/installer-win.mjs does it):
;   makensis -DVERSION=1.2.3 -DARCH=x64   installer/BromureClient.nsi
;   makensis -DVERSION=1.2.3 -DARCH=arm64 installer/BromureClient.nsi
; It expects the packaged app in out/Bromure Client-win32-<arch>/, as
; `npm run package:win` lays it out. Signing: -DSIGN_SCRIPT=/abs/sign.sh signs
; the uninstaller before it's embedded and the setup once it's written.
;
; It registers ONLY the `bromure-client://` scheme — never `bromure://`, which
; belongs to Bromure itself. The device key and the server list live in
; %APPDATA%\Bromure Client and survive both an update and an uninstall.

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

!define APPNAME "Bromure Client"
!define EXE "Bromure Client.exe"
!define SCHEME "bromure-client"
; Build-time paths use "/" (makensis also runs on macOS/Linux).
!define APPDIR "../out/${APPNAME}-win32-${ARCH}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\BromureClient"

Name "${APPNAME}"
OutFile "../out/BromureClient-${VERSION}-${ARCH}-setup.exe"
; A fixed folder, no directory page: the uninstaller removes it recursively,
; so it must never be a folder the user picked that holds other things.
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
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

!define MUI_ICON "../build/icon.ico"
!define MUI_UNICON "../build/icon.ico"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME}"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; The app must not be running while its files are replaced or removed. Only
; the copy in $INSTDIR is ours to stop — but taskkill matches by image name,
; so this also closes a zip build of the client running from elsewhere.
!macro StopApp
  nsExec::Exec '"$SYSDIR\taskkill.exe" /IM "${EXE}" /F'
  Pop $0
  Sleep 1000
!macroend

Section "-${APPNAME}"
  SetShellVarContext current
  !insertmacro StopApp
  ; An update: the previous version's files go first (Electron's file set
  ; changes between versions). Only a folder that really is ours.
  ${If} ${FileExists} "$INSTDIR\${EXE}"
    RMDir /r "$INSTDIR"
  ${EndIf}

  SetOutPath "$INSTDIR"
  File /r "${APPDIR}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  ; The app stamps its AppUserModelID (io.bromure.client) on this shortcut at
  ; first launch (electron/main.ts) — NSIS can't write that property.
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXE}"

  ; bromure-client://enroll?… → the app (a second launch hands the link to
  ; the running one). The app writes the same key when it starts.
  WriteRegStr HKCU "Software\Classes\${SCHEME}" "" "URL:${APPNAME}"
  WriteRegStr HKCU "Software\Classes\${SCHEME}" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\${SCHEME}\shell\open\command" "" '"$INSTDIR\${EXE}" "%1"'

  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "Bromure"
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "https://bromure.io"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Function .onInit
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "${APPNAME} needs Windows 10 or later." /SD IDOK
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
FunctionEnd

; A silent install (an update) starts the app again; an interactive one offers
; it on the finish page.
Function .onInstSuccess
  ${If} ${Silent}
    Exec '"$INSTDIR\${EXE}"'
  ${EndIf}
FunctionEnd

Function un.onInit
  SetRegView 64
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  !insertmacro StopApp
  ; Recursive, so only when this really is the app's folder.
  ${If} ${FileExists} "$INSTDIR\${EXE}"
    RMDir /r "$INSTDIR"
  ${EndIf}
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  ; The scheme goes only if it still points at this install (another copy of
  ; the client may have taken it over since).
  ReadRegStr $0 HKCU "Software\Classes\${SCHEME}\shell\open\command" ""
  ${If} $0 == '"$INSTDIR\${EXE}" "%1"'
    DeleteRegKey HKCU "Software\Classes\${SCHEME}"
  ${EndIf}
  DeleteRegKey HKCU "${UNINSTKEY}"
SectionEnd
