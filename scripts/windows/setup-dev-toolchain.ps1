# Bromure AC — Windows dev toolchain installer.
#
# Run order:
#   1. Open elevated PowerShell. Run scripts\windows\enable-hypervisor.ps1
#      (or the dism commands directly). Reboot.
#   2. After reboot, open a normal PowerShell window and run THIS script.
#   3. WSL Ubuntu opens in a new window for first-launch setup; once you
#      have a shell in it, run scripts\windows\setup-wsl.sh inside WSL.
#
# Every winget call uses argument-array splatting so paste/wrap quirks in
# different terminals can't turn `--flag` into a unary-operator parse error.

$ErrorActionPreference = "Stop"

# --- Core CLI tooling ---------------------------------------------------------

$packages = @(
    "Microsoft.DotNet.SDK.8",
    "Git.Git",
    "Microsoft.PowerShell",
    "Rustlang.Rustup",
    "SoftwareFreedomConservancy.QEMU",
    "JRSoftware.InnoSetup",
    "Microsoft.WindowsTerminal"
)

foreach ($pkg in $packages) {
    Write-Host ">>> Installing $pkg" -ForegroundColor Cyan
    $a = @(
        'install','-e',
        '--id', $pkg,
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )
    & winget @a
}

# --- Visual Studio 2022 Community + the workloads we need --------------------

$vsOverride = '--quiet --wait --norestart' `
    + ' --add Microsoft.VisualStudio.Workload.ManagedDesktop' `
    + ' --add Microsoft.VisualStudio.Workload.NativeDesktop' `
    + ' --add Microsoft.VisualStudio.ComponentGroup.WindowsAppSDK.Cs' `
    + ' --add Microsoft.VisualStudio.Component.Windows11SDK.22621'

$vsArgs = @(
    'install','-e',
    '--id', 'Microsoft.VisualStudio.2022.Community',
    '--source', 'winget',
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--override', $vsOverride
)
Write-Host ">>> Installing Visual Studio 2022 Community" -ForegroundColor Cyan
& winget @vsArgs

# --- Rust toolchain ----------------------------------------------------------

$rustup = "$env:USERPROFILE\.cargo\bin\rustup.exe"
& $rustup default stable
& $rustup target add x86_64-unknown-linux-musl

# --- WSL2 + Ubuntu 24.04 -----------------------------------------------------
# Opens a new window for first-launch username/password setup.

wsl --install -d Ubuntu-24.04

# --- Refresh PATH so freshly-installed tools are visible in this shell -------

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") `
    + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# --- Sanity check ------------------------------------------------------------

Write-Host "`n=== Versions ===" -ForegroundColor Green
dotnet --version
git --version
qemu-system-x86_64 --version | Select-Object -First 1
& $rustup --version
