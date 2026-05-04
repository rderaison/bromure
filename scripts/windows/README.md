# Windows dev environment setup

Provisions a Windows 11 Pro dev box for the Bromure AC port (QEMU + WHPX
hypervisor, .NET 8 + WinUI 3 host, Rust for guest agents). See
`WIN32_AC_PLAN.md` at the repo root for the full plan.

## Run order

1. **Enable the hypervisor.** Open elevated PowerShell, run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\enable-hypervisor.ps1
   ```

   Reboots when it finishes.

2. **Install the toolchain.** After the reboot, open a normal (non-elevated)
   PowerShell window and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup-dev-toolchain.ps1
   ```

   Installs .NET 8, Git, Rust, QEMU, Inno Setup, Visual Studio 2022
   Community with the WinUI 3 / C++ / Win11 SDK workloads, and WSL2 +
   Ubuntu 24.04. The first time WSL launches, it opens a new window and
   prompts for a Linux username and password.

3. **Set up the WSL side.** Once you have a shell inside Ubuntu, copy
   `setup-wsl.sh` into your WSL home directory and run it:

   ```bash
   bash setup-wsl.sh
   ```

   Installs `cloud-image-utils`, `qemu-utils`, Rust with the
   `x86_64-unknown-linux-musl` target, and the bits we need for building
   the guest qcow2 image.

## Smoke test

After all three steps, this should boot an Ubuntu kernel under WHPX. From
regular PowerShell on the Windows side:

```powershell
curl.exe -L -o ubuntu.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img convert -O qcow2 ubuntu.img ubuntu.qcow2
qemu-img resize ubuntu.qcow2 +10G
qemu-system-x86_64 -accel whpx -m 4096 -smp 4 -drive file=ubuntu.qcow2,if=virtio -nographic
```

A kernel banner followed by an `(initramfs)` or login prompt means the
toolchain is good. Ctrl-A then X to exit QEMU.

## Troubleshooting

- **`Enable-WindowsOptionalFeature: Class not registered`** — that's why
  step 1 uses `dism.exe` instead of the PowerShell cmdlet. If you see
  this elsewhere, switch to `dism /online /enable-feature ...`.
- **`winget` cert error (`0x8a15005e`)** — App Installer's pinned cert is
  stale. Run `winget source reset --force; winget source update`. If it
  persists, `winget source remove msstore` (we don't need it). Worst
  case, reinstall App Installer from the [winget-cli releases page](https://github.com/microsoft/winget-cli/releases).
- **PowerShell `Missing expression after unary operator '--'`** — your
  terminal split a long line on paste. Run the `.ps1` files directly
  instead of pasting their contents. The scripts use argument-array
  splatting throughout to avoid this anyway.
