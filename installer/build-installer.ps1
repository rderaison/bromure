# installer/build-installer.ps1 — orchestrates the Inno Setup compile.
#
# Run order:
#   1. Build the host self-contained: dotnet publish ..\windows\Bromure.AC -c Release ...
#   2. Stage QEMU + OVMF under ..\dist\qemu\ (script copies from C:\Program Files\qemu)
#   3. Stage guest agents under ..\dist\guest-agents\ (cross-compiled in WSL)
#   4. Compile the .iss with /DAppMode=Stub (default) or Full
#
# Usage:
#   .\build-installer.ps1                 # stub installer
#   .\build-installer.ps1 -Mode Full      # bundles base.qcow2 too
#
# Output:
#   ..\dist\installer\BromureAC-Setup-Stub.exe (~200 MB)
#   ..\dist\installer\BromureAC-Setup-Full.exe (~1.7 GB) when Mode=Full

param(
    [ValidateSet('Stub', 'Full')]
    [string]$Mode = 'Stub'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'

Write-Host ">>> Mode: $Mode" -ForegroundColor Cyan

# --- 1. Stage QEMU + OVMF ---------------------------------------------------
$qemuSrc = 'C:\Program Files\qemu'
$qemuDst = Join-Path $dist 'qemu'
if (-not (Test-Path $qemuSrc)) {
    throw "QEMU not found at $qemuSrc — run scripts\windows\setup-dev-toolchain.ps1 first."
}
Write-Host ">>> Staging QEMU from $qemuSrc"
New-Item -ItemType Directory -Force -Path $qemuDst | Out-Null
Copy-Item "$qemuSrc\*" $qemuDst -Recurse -Force

# --- 2. Stage guest agents (cross-built in WSL) -----------------------------
$agentsDst = Join-Path $dist 'guest-agents'
New-Item -ItemType Directory -Force -Path $agentsDst | Out-Null
$wslPath = "\\wsl.localhost\Ubuntu-24.04\home\$env:USERNAME\bromure\guest\target\x86_64-unknown-linux-musl\release"
if (Test-Path $wslPath) {
    foreach ($name in 'fb-agent', 'clip-agent') {
        $src = Join-Path $wslPath $name
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $agentsDst $name) -Force
            Write-Host "  staged $name"
        } else {
            Write-Warning "$name not built — run guest/build.sh inside WSL first"
        }
    }
} else {
    Write-Warning "WSL path $wslPath not found; staging empty agents/ dir."
    New-Item -ItemType File -Path (Join-Path $agentsDst '.placeholder') -Force | Out-Null
}

# --- 3. Build the host (self-contained) -----------------------------------
$winRoot = Join-Path $root 'windows'
$hostProj = Join-Path $winRoot 'Bromure.AC\Bromure.AC.csproj'
if (-not (Test-Path $hostProj)) {
    Write-Warning "Bromure.AC.csproj not present yet — installer will lack the host EXE."
    Write-Warning "Skipping dotnet publish; installer will compile the qemu/agents/etc payload only."
} else {
    Write-Host ">>> Publishing host (self-contained)"
    & dotnet publish $hostProj -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
}

# --- 4. Compile installer ---------------------------------------------------
$iscc = $null
foreach ($p in @(
    "$env:ProgramFiles (x86)\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)) {
    if (Test-Path $p) { $iscc = $p; break }
}
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup)."
}

Write-Host ">>> Compiling .iss in $Mode mode"
$iss = Join-Path $PSScriptRoot 'BromureAC.iss'
& $iscc /DAppMode=$Mode $iss

Write-Host
Write-Host "=== Output ===" -ForegroundColor Green
Get-ChildItem (Join-Path $dist 'installer') -Filter "BromureAC-Setup-*.exe" |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { '  {0}  ({1:N0} bytes)' -f $_.FullName, $_.Length }
