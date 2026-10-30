# amd64 guest image bake (QEMU/KVM) — prototype

A port of `UbuntuImageManager.createBaseImage` to QEMU, for an **amd64** guest.

| step | macOS (VZ) | here |
|---|---|---|
| installer kernel | Alpine 3.22.3 netboot **aarch64**, gzip Image pulled out of the PE (`extractRawKernel`) | Alpine 3.22.3 netboot **x86_64**, sha256-checked; the bzImage goes to `-kernel` as-is |
| DHCP/MTU shim | `InitrdShim` appends `/init.bromure` | the same script, appended as a second cpio |
| console | virtio-console `hvc0` on pipes | `ttyS0` on a unix-socket chardev, driven by `serial-driver.py` (same markers and timeouts as `runProvisioner`) |
| files in | virtiofs `setup` | virtiofsd `--readonly`, tag `setup`; plus tag `out` for the kernel/initrd |
| network | vmnet NAT + `AlpinePackageProxy` | QEMU user-mode NAT; `ALPINE_REPO_BASE` is the CDN over http (apk checks signatures) |
| guest script | `setup.sh` | the same `setup.sh`, staged by `stage-amd64.sh` with the arm64 lines rewritten (asserted) |
| artefacts | `base.img` (GRUB inside, EFI boot), `efivars.bin`, `base.version` | `base.img` (same layout, GRUB x86_64-efi inside), **`vmlinuz`, `initrd.img`, `cmdline`** for direct kernel boot, `kernel-release`, `base.version`, `bake.log` |

```bash
sudo -g kvm linux/bake/bake-amd64.sh [out-dir]       # default ~/.local/share/bromure-ac/image-amd64
sudo -g kvm linux/bake/boot-direct.sh <out-dir> q35 3       # times exec -> agentd's vsock dial to host :5800
sudo -g kvm linux/bake/boot-direct.sh <out-dir> microvm 3
```

`sudo -g kvm` is only needed until the vhost udev rule is installed. `imageVersion` is copied, not changed.

## arm64 assumptions found (not edited; proposals below)

Bake code (`Sources/AgentCoding/UbuntuImageManager.swift`):
- :106 `releasesBase = …/releases/aarch64`; :495 `alpine-netboot-…-aarch64.tar.gz`; :834 `modloop=…/releases/aarch64/…`
- :532-535, :1223-1258 `extractRawKernel` (arm64 PE + gzip; x86 needs nothing)
- :851 `console=hvc0`; :864 `arm64.nosme`
- VZ-only: `VZLinuxBootLoader`, `VZGenericPlatformConfiguration`, `VZEFIVariableStore` (:394, :1138), the virtio-console serial port; APFS `clonefile` (:1213, `+Remote.swift:217`)
- The prebuilt catalog (`dl.bromure.io/images/<v>/img-catalog.json`) has no arch field, so a download is arm64 by implication.

`Resources/vm-setup/setup.sh`:
- :32 `UBUNTU_MIRROR` default `ports.ubuntu.com/ubuntu-ports`, which has no amd64 packages (used again in sources.list at :152-154)
- :141 `debootstrap --arch=arm64`
- :360 `grub-efi-arm64 grub-efi-arm64-bin`
- :384 `GRUB_CMDLINE_LINUX="console=hvc0 … arm64.nosme"`
- :389-391 `grub-install --target=arm64-efi … --bootloader-id=BOOTAA64`
- Already portable: :558, :667 (`dpkg --print-architecture`), :576/:589 (glab), :614-615 (kubectl), :628-629 (doctl), :646-647 (awscli)
- `/dev/vda` hard-coded at :33-35; `postinstall.sh:29-31` too. This holds for virtio-blk on QEMU.

Guest agents:
- **`sentry-dist/src/bromure_sentry.c:68-69`: `#ifndef CONFIG_ARM64 #error`**, and arm64 `regs->regs[0..2]` at :1104, :1323, :1375, :1492, :2275-2280, :2347-2355. The x86_64 equivalents are `regs->di/si/dx/r10/r8/r9`. Its build is arm64-only too: `scripts/openshell-guest/sentry/build.sh:5,53-56` (`aarch64-linux-gnu-gcc`) and `Jenkinsfile.sentry:18,77,92,158,162`. **This is the only hard blocker.**
- `bromure_idmap.py:48-52`, `bromure_openshell.py` (:625-637, :755, :848-891): already handle x86_64.
- `bromure-agentd.py:107` HOST_CID 2 is the same on QEMU vhost-vsock.

Host-side labels that assume an arm64 guest: `SecurityTimeline.swift:480-483`, `PolicySteering.swift:436-440`, `DockerDashboard.swift:994-1002` (non-arm64 is shown as "emulated").

## Proposed changes (for the macOS session to land)

1. **setup.sh: derive the arch** instead of hard-coding it. The Alpine installer's `uname -m` maps `aarch64` to `arm64` and `x86_64` to `amd64`. From that:
   - `DEB_ARCH` drives `--arch=$DEB_ARCH`.
   - `grub-efi-$DEB_ARCH grub-efi-$DEB_ARCH-bin`.
   - `--target=$GRUB_TARGET` (`arm64-efi` or `x86_64-efi`) and `--bootloader-id=$BOOT_ID` (`BOOTAA64` or `BOOTX64`).
   - The mirror default comes from the arch: arm64 uses `ports.ubuntu.com/ubuntu-ports`, amd64 uses `archive.ubuntu.com/ubuntu`.
   - The GRUB cmdline: `console=hvc0 … arm64.nosme` on arm64. On amd64 it needs a console that exists on both VMMs. Proposal: `console=${GUEST_CONSOLE:-hvc0}`, and the Linux bake passes `ttyS0`. It could also list both (`console=ttyS0 console=hvc0`), since the last one listed becomes /dev/console.
2. **UbuntuImageManager: make the Alpine arch a parameter.** That covers the URLs at :106, :495 and :834. `extractRawKernel` becomes arm64-only, and `arm64.nosme` is added only on arm64. This is needed for the shared-core bake logic anyway.
3. **Image catalog: add an `arch` key** (or a per-arch path, `images/<v>/<arch>/`). Also publish `vmlinuz` and `initrd.img` next to `base.img.gz`, so Linux hosts can direct-boot a downloaded image.
4. **Sentry: per-arch syscall-argument accessors** (`regs_get_kernel_argument()` exists on both arm64 and x86_64 since 5.x). Also an amd64 job in `Jenkinsfile.sentry`.
5. Host labels: take the guest arch from the image metadata, not assume arm64.

## Results (lnx-ntv, 2026-10-30)

- Bake: Alpine boot to `localhost login:` takes 9 s. `setup.sh` runs in 203 s (debootstrap + chroot); the whole bake is about 3.6 min. Kernel: `6.8.0-147-generic` (linux-image-virtual).
- Direct kernel boot, from QEMU exec to bromure-agentd's first vsock connection to host :5800. Each VM has 2 vCPU, 2 GiB memfd RAM, a qcow2 overlay on the raw base, virtiofs `bromure-meta` + `bromure-outbox`, and a user-mode NIC.

| machine | run 1 | run 2 | run 3 | QEMU RSS |
|---|---|---|---|---|
| q35 | 3.20 s | 2.82 s | 3.28 s | 513–520 MiB |
| microvm (virtio-mmio) | 2.50 s | 2.42 s | 2.75 s | 515–539 MiB |

  (The spike's BIOS + GRUB boot of a cloud image took 5.0–6.6 s.)
- **Without a NIC, the time to :5800 is 122 s.** agentd's `task_apt_and_docker_proxy` restarts docker synchronously before `shell_agent_service` starts. docker.service waits for network-online, which times out at 120 s with no link. That will bite whenever the guest's link comes up late, for example while the L2 switch is not yet answering DHCP. Proposal: start the shell service before that task, or restart docker with `--no-block`.
- **setup.sh bug, not arch-specific:** `setup.sh:235` writes `BROMURE_PROXY=$ALPINE_REPO_BASE` for the chroot even when it is the plain CDN default, which `setup.sh:79` deliberately does not treat as a proxy. apt then uses dl-cdn.alpinelinux.org as a forward proxy and every fetch fails (Fastly "500 Domain Not Found"). On the Mac this happens whenever AlpinePackageProxy isn't up. The bake stages the same condition as :79 (see `stage-amd64.sh`).
