# Host↔Guest file sharing on Windows — what's actually possible

Investigation conducted 2026-05-04 in response to "use virtiofs on the Windows host like the user's tutorial said". TL;DR: **virtiofs on a Windows host is not currently achievable with mainline QEMU**, regardless of whether `WinFsp` is installed. The user's tutorial assumed a binary (`virtiofsd.exe`) and a QEMU device (`vhost-user-fs-pci`) that aren't actually available on Windows. The chosen alternative is per-launch ISO for the small read-only metadata payload, with a custom WinFsp-backed server as the long-term option for bidirectional project-folder shares.

This document exists so the next time someone reads "just use virtiofs" they don't waste another 4 hours rediscovering the same dead end.

## Layer 1: QEMU `--enable-virtfs` (built-in 9p server)

```meson
# qemu/meson.build:2345
have_virtfs = get_option('virtfs') \
    .require(host_os == 'linux' or host_os == 'darwin' or host_os == 'freebsd',
             error_message: 'virtio-9p (virtfs) requires Linux or macOS or FreeBSD')
```

Hard gate. The QEMU 9p server (`hw/9pfs/9p-local.c`) calls Unix-only syscalls (`fchroot`, `setresuid`, `xattr`, `getfsuid`). Patching out the meson gate causes compile errors elsewhere. **Verdict: closed.**

Sources:
- [QEMU v11.0.0 meson.build:2345](https://gitlab.com/qemu-project/qemu/-/blob/v11.0.0/meson.build#L2345)

## Layer 2: QEMU `vhost-user-fs-pci` (consumes external daemon)

```meson
# qemu/meson.build:227-230
have_vhost_user = get_option('vhost_user') \
  .disable_auto_if(host_os != 'linux') \
  .require(host_os != 'windows',
           error_message: 'vhost-user is not available on Windows').allowed()
```

vhost-user-fs-pci depends on vhost-user being available. The gate appears flippable on the surface — `<sys/un.h>` exists in mingw-w64 and Windows 10+ has native AF_UNIX. But:

- **vhost-user requires SCM_RIGHTS file-descriptor passing over AF_UNIX**. QEMU's `io/channel-socket.c` only emits the SCM_RIGHTS code in `#ifndef WIN32` blocks. The protocol fundamentally needs FD passing to share memory regions and event FDs between QEMU and the daemon.
- **Windows AF_UNIX does not support ancillary data** (`cmsg`). Microsoft's implementation is socket-only; no FD passing.

So even if the meson gate is removed, the wire protocol can't function. **Verdict: closed without a wholesale alternative transport (named pipes + DuplicateHandle), which would require non-trivial QEMU patches and matching daemon changes.**

Sources:
- [QEMU v11.0.0 meson.build:227-230](https://gitlab.com/qemu-project/qemu/-/blob/v11.0.0/meson.build#L227)
- [QEMU v11.0.0 io/channel-socket.c (SCM_RIGHTS guard)](https://gitlab.com/qemu-project/qemu/-/blob/v11.0.0/io/channel-socket.c#L425)

## Layer 3: virtiofsd / virtiofsd-rs daemon

The Rust-rewritten daemon is the only currently-maintained virtiofsd. Its README:

> "built only for x86_64 Linux-based systems" / depends on `seccomp(2)`, Linux capabilities, namespace isolation, `pivot_root(2)`, `chroot(2)`.

There is no official Windows port. **Verdict: closed.**

Sources:
- [virtiofsd-rs README — gitlab.com/virtio-fs/virtiofsd](https://gitlab.com/virtio-fs/virtiofsd)

## Layer 4: "virtiofsd.exe" tutorials online

Multiple blog posts and Stack Overflow answers tell users to "run `virtiofsd.exe`" on a Windows host. **None of them point at a real binary.** What exists in the `virtio-win` ISO is `virtiofs.exe` (no `d`), which is the Windows **guest** service that mounts a Linux-host virtiofs share inside a Windows VM — the opposite direction.

The confusion comes from the official `virtio-win` Knowledge Base assuming Linux host throughout, while community tutorials repeat the daemon name without checking that no Windows binary is published.

Sources confirming this (all describe Windows-as-guest):
- [virtio-fs Windows HowTo](https://virtio-fs.gitlab.io/howto-windows.html)
- [virtio-win/kvm-guest-drivers-windows wiki — Virtiofs](https://github.com/virtio-win/kvm-guest-drivers-windows/wiki/Virtiofs:-Shared-file-system)
- [virtio-win Knowledge Base — Virtiofs Quick start](https://virtio-win.github.io/Knowledge-Base/Virtiofs-qs.html)

## Layer 5: WinFsp on its own

WinFsp is a FUSE-equivalent filesystem framework for Windows (kernel-mode driver + user-space DLL + native C / FUSE2 / FUSE3 / .NET bindings). It ships only `MEMFS` as a sample filesystem. It is **a primitive, not a VM-host share**. Pairing it with a Linux guest requires building the entire wire (custom QEMU device + custom guest kernel module + custom protocol) on top.

License: GPLv3 with a Free Software exception, plus commercial dual-license. Using it in proprietary code requires the commercial license or imposes constraints.

Sources:
- [winfsp/winfsp on GitHub](https://github.com/winfsp/winfsp)

## What we're shipping instead

**Phase 1 (today):** per-launch ISO9660 mounted as IDE CD-ROM, auto-mounted in the guest by `bromure-meta-mount.service` (volume label `bromuremeta`). Read-only, refreshed each session start. Suits the small metadata payload (api_key.env, dotfiles, kubeconfig). Matches macOS path semantically — both mount at `/mnt/bromure-meta`.

Implementation: `windows/Bromure.SandboxEngine/Image/SessionMetadataIso.cs` + `CloudInitSeedBuilder.WriteFilesIso` + `QemuConfig.AuxIsoPath`.

**Phase 2 (later, if needed for project folders):** custom WinFsp-backed shared-fs daemon + matching guest agent, communicating over virtio-serial (no FD-passing concerns). Estimated 2-4 weeks of dev work. Starting point: WinFsp's FUSE3 API on the host, a small in-guest client speaking a private protocol over `/dev/virtio-ports/...`. Only worth the investment if SMB / read-only-ISO turns out to actually bottleneck the agentic-coding hot path (which it likely won't for AC; possibly will for Bromure Web's npm/git workloads).
