# Building the Bromure AC QEMU bundle

The Windows port ships its own QEMU build because the `winget` package
(`SoftwareFreedomConservancy.QEMU`) compiles with `--disable-virtfs` and
no `vhost-user-fs` device. Without those, neither the bake-time nor the
runtime file shares (`/mnt/bromure-meta`, `/home/ubuntu`, project
folders) work — and that's exactly the macOS-port surface we're trying
to keep at parity.

## TL;DR

```pwsh
pwsh windows\scripts\build-qemu.ps1
```

Output: `windows\dist\qemu-bundle\` (gitignored).
First run takes ~30 minutes and ~5 GB disk; subsequent runs are skipped
unless you pass `-Force` or bump `QemuVersion`.

`QemuPaths.Resolve` already prefers `<install>\lib\qemu\qemu-system-x86_64.exe`,
so installer manifests just need to copy this bundle to that location.

## What the build script does

The PowerShell wrapper:

1. Locates an MSYS2 install. Tries `$env:MSYS2_PATH`, then `C:\msys64`,
   then `winget install MSYS2.MSYS2` if neither exists.
2. Dispatches into MSYS2's UCRT64 shell, which sets up the right
   toolchain prefix (`/ucrt64`).

The bash script (`build-qemu.sh`) under UCRT64:

1. `pacman -S --needed` the dep set (toolchain + glib + pixman + GTK +
   SDL + curl + spice + libslirp + …).
2. Clones upstream QEMU at the pinned tag (`v11.1.0` by default — bump
   the constant at the top of `build-qemu.sh`) into a temp build dir.
   No QEMU source goes into our git tree.
3. Configures with the flag set we need (default tag is **v11.0.0**;
   bump in `build-qemu.sh` once a newer release tag exists upstream):
   - `--target-list=x86_64-softmmu` (only x86_64 — saves build time)
   - **No** `--enable-virtfs` / `--enable-vhost-user-fs`. QEMU's meson
     refuses both on Windows hosts ("virtio-9p (virtfs) requires Linux
     or macOS or FreeBSD") because the 9p server uses Unix-only
     syscalls. vhost-user-fs is also Linux-host-only via virtiofsd-rs's
     AF_UNIX requirement. We can't get virtiofs/9p on a Windows host
     regardless of QEMU configure flags or which build we ship. The
     Windows runtime uses **per-launch ISO** for the small read-only
     metadata payload (API keys, dotfiles, .xinitrc) and **SMB** (the
     Windows host's built-in server, mounted via `cifs-utils` in the
     guest) for the larger bidirectional project-folder shares.
   - `--enable-tools` (`qemu-img`, used by `AlpineInstaller` for raw→qcow2)
   - `--enable-whpx` (Windows Hypervisor Platform host accelerator)
   - `--enable-gtk --enable-sdl` (both display backends — SDL crashes
     under RDP on some Windows hosts so we keep GTK as fallback)
   - `--enable-spice` (clipboard / vdagent; matches macOS install set)
4. Builds with `ninja`.
5. Stages the install into `windows\dist\qemu-bundle\` with the layout
   `QemuPaths.Resolve` expects:
   ```
   qemu-bundle/
     qemu-system-x86_64.exe
     qemu-img.exe
     *.dll                       (closure of dynamic deps from /ucrt64)
     share/
       edk2-x86_64-code.fd
       edk2-i386-vars.fd
       keymaps/
       …
     MANIFEST.txt                (qemu_version + build timestamp)
   ```
6. Walks `ldd` over each shipped `.exe` and copies every MSYS2-prefixed
   DLL into the bundle. System DLLs (`C:\Windows\System32\…`) stay where
   they are — Windows finds them at runtime regardless of bundle layout.

## Bumping QEMU

Two ways:

- One-shot rebuild against a different tag:
  `pwsh windows\scripts\build-qemu.ps1 -QemuVersion v11.2.0 -Force`
- Permanent bump: edit `QEMU_VERSION` at the top of `build-qemu.sh`,
  then rerun `build-qemu.ps1`.

Either way the upstream source is fetched fresh — we never carry a
QEMU fork. If a build breaks on a new tag, please leave a comment on
the line and roll back rather than patching upstream files.

## CI

The build is too slow + too dep-heavy for our regular CI matrix.
Recommended pattern: a **separate** GitHub Actions workflow on a
Windows runner that runs nightly + on-demand, uploads the bundle as an
artefact, and our installer workflow downloads the latest artefact at
package time. (Not wired yet; until it is, ship the bundle by running
the script locally on a build machine.)

## Why we don't ship `virtiofsd` here

`virtiofsd-rs` (the modern Rust daemon) is its own build. It pairs
with `--enable-vhost-user-fs` on the QEMU side. We'll ship a
`build-virtiofsd.ps1` in a follow-up.

For the AC bake (which just needs to mount `setup.sh` once,
read-only), the built-in `--enable-virtfs` 9p path is sufficient and
needs no daemon — that's what this bundle covers today.
