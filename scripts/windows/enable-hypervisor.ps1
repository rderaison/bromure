# Bromure AC — enable the Windows features QEMU+WHPX needs.
# Run from elevated PowerShell. Reboots when done.
#
# Uses dism.exe directly rather than Enable-WindowsOptionalFeature because
# the cmdlet sometimes errors with "Class not registered" under PowerShell 7
# or 32-bit PowerShell. dism.exe works in any shell.

$ErrorActionPreference = "Stop"

Write-Host ">>> Enabling HypervisorPlatform" -ForegroundColor Cyan
dism /online /enable-feature /featurename:HypervisorPlatform /all /norestart

Write-Host ">>> Enabling VirtualMachinePlatform" -ForegroundColor Cyan
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

Write-Host "`nWindows features enabled. A reboot is required." -ForegroundColor Green
Restart-Computer -Confirm
