# Builds the Windows installers from dist\ (scripts/build.sh first).
#   scripts\installer.ps1 -Version 1.2.3 [-Arch x64,arm64]
# Signing: set SIGN_CERT (a .pfx) and SIGN_PASS, with signtool on the
# PATH (Windows SDK); unsigned otherwise (SmartScreen warns on first run).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string[]]$Arch = @("x64", "arm64")
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 isn't installed (winget install --id JRSoftware.InnoSetup -e --scope user)" }

$signArgs = @()
if ($env:SIGN_CERT) {
    $signtool = (Get-Command signtool.exe -ErrorAction Stop).Source
    # The executables first (they're what SmartScreen and the tray check),
    # then the installer and its uninstaller through Inno's SignTool.
    Get-ChildItem "$root\dist\windows-*\*.exe" | ForEach-Object {
        & $signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f "$env:SIGN_CERT" /p "$env:SIGN_PASS" $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "signing $($_.Name) failed" }
    }
    $signArgs = @("/DSign", "/Ssigntool=`"$signtool`" sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f `"$env:SIGN_CERT`" /p `"$env:SIGN_PASS`" `$f")
} else {
    Write-Warning "unsigned build (no SIGN_CERT): SmartScreen will warn on first run"
}
foreach ($a in $Arch) {
    & $iscc "/DAppVersion=$Version" "/DArch=$a" @signArgs "$root\installer\BromureSidecar.iss"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed for $a" }
}
Get-ChildItem "$root\dist\BromureSidecar-$Version-*.exe" | ForEach-Object {
    $h = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower()
    "$h  $($_.Name)"
} | Set-Content -Encoding ascii "$root\dist\installers-SHA256SUMS"
Get-Content "$root\dist\installers-SHA256SUMS"

# The update feed the Sidecar's updater reads (internal/updater): this
# version and, per architecture, the versioned installer's URL and SHA-256.
# Published as latest.json beside the installers.
$feedBase = if ($env:FEED_BASE) { $env:FEED_BASE } else { "https://dl.bromure.io/releases-sidecar-windows" }
$entry = {
    param($a)
    $f = "$root\dist\BromureSidecar-$Version-$a.exe"
    if (Test-Path $f) {
        @{ url = "$feedBase/BromureSidecar-$Version-$a.exe"; sha256 = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() }
    }
}
$x64 = & $entry "x64"
$arm = & $entry "arm64"
$feed = [ordered]@{ version = $Version }
if ($x64) { $feed.url = $x64.url; $feed.sha256 = $x64.sha256 }
if ($arm) { $feed.arm64 = $arm }
$feed | ConvertTo-Json | Set-Content -Encoding utf8NoBOM "$root\dist\latest-$Version.json"
Write-Host "feed: dist\latest-$Version.json"
