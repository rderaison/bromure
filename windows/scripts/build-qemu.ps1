# build-qemu.ps1 — produce a Bromure-AC-tailored QEMU bundle for Windows.
#
# Wraps the sibling build-qemu.sh: locates an MSYS2 install (offers to
# install via winget if missing), then dispatches the actual build into
# MSYS2's UCRT64 shell. The bash script does the real work; this is a
# friendly entry point.
#
# Usage (from PowerShell):
#   pwsh windows\scripts\build-qemu.ps1
#   pwsh windows\scripts\build-qemu.ps1 -QemuVersion v11.1.0
#
# Output: windows\dist\qemu-bundle\ — gitignored, checked-in by the
# installer step at ship time.
#
# Prerequisites:
#   * MSYS2 (auto-installed via winget if missing).
#   * ~5 GB disk for the build, ~30 minutes on a modern laptop.
#   * Internet to clone QEMU + pacman the dep set on first run.
[CmdletBinding()]
param(
    [string]$QemuVersion,
    [string]$OutputDir,
    [string]$BuildDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'windows\dist\qemu-bundle' }

function Write-Step($msg) { Write-Host "[build-qemu] $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# MSYS2 location. Common install path is C:\msys64. If MSYS2_PATH env
# var is set we take that. Last resort: winget install.
# ---------------------------------------------------------------------------
function Find-Msys2 {
    # PowerShell unwraps a single-element pipeline result into a
    # scalar, so an unguarded `$candidates[0]` indexes the string by
    # character ("C:\msys64" → "C"). Force array context with @(...)
    # so the first element survives intact.
    $candidates = @(@(
        $env:MSYS2_PATH,
        'C:\msys64',
        'C:\Program Files\msys64',
        "$env:LOCALAPPDATA\msys64"
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'usr\bin\bash.exe')) })
    if ($candidates.Count -gt 0) { return [string]$candidates[0] }
    return $null
}

$msys2 = Find-Msys2
if (-not $msys2) {
    Write-Step "MSYS2 not found. Installing via winget…"
    & winget install --id MSYS2.MSYS2 --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install MSYS2.MSYS2 failed (exit $LASTEXITCODE). Install MSYS2 from https://www.msys2.org/ and re-run."
    }
    $msys2 = Find-Msys2
    if (-not $msys2) { throw "MSYS2 still not found after winget install. Set MSYS2_PATH manually." }
}
Write-Step "MSYS2 at $msys2"

# Skip rebuild if the bundle already matches the requested version,
# unless -Force was passed.
$manifestPath = Join-Path $OutputDir 'MANIFEST.txt'
if ((Test-Path $manifestPath) -and -not $Force -and -not $QemuVersion) {
    $existing = (Get-Content $manifestPath | Where-Object { $_ -match '^qemu_version=' }) `
        -replace '^qemu_version=', ''
    Write-Step "Existing bundle is $existing. Pass -Force to rebuild."
    exit 0
}

# ---------------------------------------------------------------------------
# Forward to bash.exe under UCRT64. We translate the Windows paths to
# MSYS2 paths via cygpath (run through bash itself).
# ---------------------------------------------------------------------------
$bash = Join-Path $msys2 'usr\bin\bash.exe'
$shScript = Join-Path $ScriptDir 'build-qemu.sh'

$envSetup = @"
export MSYSTEM=UCRT64
source /etc/profile
"@

$envExports = @()
if ($QemuVersion) { $envExports += "export QEMU_VERSION='$QemuVersion'" }
if ($OutputDir)   { $envExports += "export OUTPUT_DIR=`"`$(cygpath -u '$OutputDir')`"" }
if ($BuildDir)    { $envExports += "export BUILD_DIR=`"`$(cygpath -u '$BuildDir')`"" }

$exportBlock = ($envExports -join "`n")
$shScriptUnix = "`$(cygpath -u '$shScript')"

$cmd = @"
$envSetup
$exportBlock
bash $shScriptUnix
"@

Write-Step "dispatching build into MSYS2 UCRT64 shell"
& $bash -lc $cmd
if ($LASTEXITCODE -ne 0) {
    throw "QEMU build failed (exit $LASTEXITCODE). Look above for the underlying error."
}

Write-Step "DONE. Bundle at $OutputDir"
Write-Step "Run BromureAC again — QemuPaths.Resolve picks up the bundle automatically."
