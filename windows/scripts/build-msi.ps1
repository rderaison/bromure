# build-msi.ps1 — package Bromure Agentic Coding into a redistributable
# Windows MSI.
#
# Steps:
#   1. dotnet publish the WPF app in Release / win-x64, framework-dependent
#      by default (smaller artifact). Use -SelfContained to bundle the
#      .NET runtime — required for installs onto stock Windows boxes
#      that don't have .NET 8 Desktop runtime installed.
#   2. Copy the bundled openssh\ tree into the publish output. The WPF
#      project already has it as a Content item, so dotnet publish
#      handles it — this is a sanity check.
#   3. Invoke `wix build` against installer\BromureAC.wxs with the
#      publish directory as the StagingDir. WiX 5's <Files Include="..."/>
#      directive walks the whole tree and produces one component per
#      file with deterministic GUIDs.
#   4. Output: windows\dist\BromureAC-<version>.msi
#
# Prerequisites:
#   * .NET 8 SDK
#   * wix tool (`dotnet tool install --global wix --version 5.0.2`)
#     — WiX 7 requires an OSMF EULA acceptance; we pin to 5.x.
#
# Usage:
#   pwsh windows\scripts\build-msi.ps1
#   pwsh windows\scripts\build-msi.ps1 -SelfContained
#   pwsh windows\scripts\build-msi.ps1 -Version 0.2.0

[CmdletBinding()]
param(
    # Bumping this drives MSI MajorUpgrade — Windows uninstalls the
    # old version and installs the new automatically. UpgradeCode in
    # the .wxs stays constant for the product lifetime.
    [string]$Version = "0.1.0",
    # Bundle the .NET 8 runtime in the publish output so the MSI
    # installs cleanly onto stock Windows machines (no separate
    # runtime download). Bigger artifact (~80 MB → ~150 MB).
    [switch]$SelfContained,
    # Clean intermediates before building. Recommended after sln
    # restructures or version bumps; default off so iterative dev
    # is fast.
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$publishDir = Join-Path $root "dist\publish"
$distDir = Join-Path $root "dist"
$wixSrc = Join-Path $root "installer\BromureAC.wxs"
$msiOut = Join-Path $distDir "BromureAC-$Version.msi"

Write-Host "[build-msi] root           : $root"
Write-Host "[build-msi] version        : $Version"
Write-Host "[build-msi] self-contained : $SelfContained"
Write-Host "[build-msi] publish dir    : $publishDir"
Write-Host "[build-msi] msi out        : $msiOut"
Write-Host ""

# 0. Tooling sanity.
$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    Write-Error "wix tool not found. Install with: dotnet tool install --global wix --version 5.0.2"
    exit 1
}
$wixVersion = (& wix --version) -split '\+' | Select-Object -First 1
Write-Host "[build-msi] wix tool       : $wixVersion"

# 1. Clean previous build outputs if requested.
if ($Clean) {
    Write-Host "[build-msi] cleaning $distDir"
    if (Test-Path $distDir) { Remove-Item -Recurse -Force $distDir }
}
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

# 2. Publish the WPF app. PublishProfile would be tidier long-term,
# but a single dotnet publish line keeps the script readable.
$csproj = Join-Path $root "Bromure.AC\Bromure.AC.csproj"
$publishArgs = @(
    "publish"
    $csproj
    "-c", "Release"
    "-r", "win-x64"
    "-o", $publishDir
    "--nologo"
    "-p:Version=$Version"
)
if ($SelfContained) {
    $publishArgs += @("--self-contained", "true", "-p:PublishSingleFile=false")
} else {
    $publishArgs += @("--self-contained", "false")
}
Write-Host "[build-msi] dotnet $($publishArgs -join ' ')"
& dotnet $publishArgs
if ($LASTEXITCODE -ne 0) { Write-Error "dotnet publish failed (exit $LASTEXITCODE)"; exit 1 }

# 3. Sanity-check the publish output.
$mainExe = Join-Path $publishDir "BromureAC.exe"
if (-not (Test-Path $mainExe)) {
    Write-Error "Publish output missing BromureAC.exe at $mainExe"
    exit 1
}
$opensshDir = Join-Path $publishDir "openssh"
if (Test-Path $opensshDir) {
    $sshCount = (Get-ChildItem $opensshDir -File).Count
    Write-Host "[build-msi] openssh\        : $sshCount file(s) bundled"
} else {
    Write-Warning "openssh\ not in publish output — ssh-add bundle is missing. Check the .csproj <Content> globs."
}
$publishSizeMb = [math]::Round((Get-ChildItem -Recurse $publishDir | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "[build-msi] publish size   : $publishSizeMb MB"

# 4. Invoke WiX. The trailing backslash on StagingDir matters — WiX's
# <Files Include="$(StagingDir)**"/> joins with no separator.
$stagingDirArg = "StagingDir=$publishDir\"
# IconSource lives in the project tree, not the publish output —
# .ico assets aren't part of dotnet publish output for WPF.
$iconArg = "IconSource=" + (Join-Path $root "Bromure.AC\BromureAC.ico")
Write-Host "[build-msi] wix build -arch x64 -d `"$stagingDirArg`" -d `"$iconArg`" -out `"$msiOut`" `"$wixSrc`""
& wix build -arch x64 -d "$stagingDirArg" -d "$iconArg" -out $msiOut $wixSrc
if ($LASTEXITCODE -ne 0) { Write-Error "wix build failed (exit $LASTEXITCODE)"; exit 1 }

if (-not (Test-Path $msiOut)) {
    Write-Error "wix build claimed success but $msiOut doesn't exist"
    exit 1
}

$msiSizeMb = [math]::Round((Get-Item $msiOut).Length / 1MB, 1)
Write-Host ""
Write-Host "[build-msi] DONE."
Write-Host "[build-msi] $msiOut ($msiSizeMb MB)"
