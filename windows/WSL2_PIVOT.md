# WSL2 pivot — spike findings + architecture

The QEMU+WHPX implementation works (preserved at commit `86be3d1`) but
hits a series of Windows-host walls (no virtiofs, no vsock, ~2× slower
than VZ). This doc records the spike that validated WSL2 as the
replacement and sketches the integration plan.

## Pillars validated

| Capability | QEMU port | WSL2 |
|---|---|---|
| Filesystem host↔guest | sshfs over slirp NAT (~tens of MB/s, requires MSYS2 sshd) | native 9p, **~300 MB/s** sustained, zero plumbing |
| Host TCP listener reachable from guest | needs Windows Firewall rule + bridge IP | works on `127.0.0.1` directly (mirrored mode) |
| Per-session filesystem isolation | qcow2 overlay | `wsl --import` per session |
| Per-session process tree | full VM | own namespace (shared kernel) |
| Hypervisor perf | WHPX (~½ VZ) | Hyper-V with Linux guest tuned by Microsoft |
| Display | reparent QEMU GTK toplevel (fragile SetParent) | WSLg → real Windows HWND (cleaner) |
| Vsock | unavailable | irrelevant (TCP loopback works) |

Spike scripts and outputs are in this conversation; no checked-in
benchmark harness yet (TODO).

## Required configuration

`~/.wslconfig`:

```
[wsl2]
networkingMode=mirrored
```

Mirrored mode makes WSL share the Windows network stack: WSL's
`127.0.0.1` IS Windows's `127.0.0.1`, no firewall rules, no NAT.
Required for the MITM proxy plumbing to work without elevation.

## Architecture (target)

```
┌──────────────────── Windows host ─────────────────────┐
│                                                       │
│   BromureAC.exe (WPF)                                 │
│     ┌───────────────────────────────────────────┐    │
│     │ MainWindow                                │    │
│     │   ┌──────────┬──────────┬──────────┐    │    │
│     │   │ tab A    │ tab B    │ tab C    │    │    │
│     │   │ (kitty)  │ (kitty)  │ (kitty)  │    │    │
│     │   └────┬─────┴────┬─────┴────┬─────┘    │    │
│     │        │ HwndHost │          │           │    │
│     │   SetParent each WSLg HWND   │           │    │
│     └────────┼──────────┼──────────┼───────────┘    │
│              │          │          │                 │
│   HttpMitmProxy (Bromure.AC.Mitm)                    │
│     127.0.0.1:18443 ◄── tab A's HTTPS_PROXY          │
│     127.0.0.1:18444 ◄── tab B's HTTPS_PROXY          │
│     127.0.0.1:18445 ◄── tab C's HTTPS_PROXY          │
│   Token swap on the fly via SessionTokenPlan         │
│                                                       │
└────┬────────────┬────────────┬───────────────────────┘
     │            │            │
     ▼            ▼            ▼
┌─────────┐  ┌─────────┐  ┌─────────┐
│ wsl     │  │ wsl     │  │ wsl     │
│ distro  │  │ distro  │  │ distro  │
│ tab-a   │  │ tab-b   │  │ tab-c   │
│         │  │         │  │         │
│ kitty + │  │ kitty + │  │ kitty + │
│ claude  │  │ codex   │  │ claude  │
│         │  │         │  │         │
│ HTTPS_  │  │ HTTPS_  │  │ HTTPS_  │
│ PROXY=  │  │ PROXY=  │  │ PROXY=  │
│ :18443  │  │ :18444  │  │ :18445  │
└─────────┘  └─────────┘  └─────────┘

           Shared Linux kernel (WSL2 utility VM)
        Shared Windows network stack (mirrored mode)
```

### Key design decisions

**One distro per tab.** Each kitty tab gets its own `wsl --import`'d
distro from the sealed `bromure-base.tar.gz`. Per-tab filesystem +
process-tree isolation; shared kernel. User explicitly endorsed this
("shared kernel is actually better, lower overhead").

**Proxy attribution by destination port.** With mirrored networking
all distros share `127.0.0.1`, so source-IP attribution is impossible.
We bind one `HttpMitmProxy` instance per tab on a unique loopback
port and set `HTTPS_PROXY=http://127.0.0.1:<port>` in that tab's
distro env. Token swap stays per-tab clean.

**Cert injection at bake time.** Bromure CA root cert lands in
`/usr/local/share/ca-certificates/bromure.crt` during the bake;
`update-ca-certificates` runs once. Same as the QEMU port.

**Profile dotfiles via `\\wsl$\<distro>\home\<user>\`**. We can write
directly to the distro's home dir from Windows (now that 9p is
bidirectional), or keep using `SessionHomeArchive` USTAR and
`tar -xf` inside the distro on first boot. The former is simpler and
removes one step.

**Display embed.** WSLg renders Linux GUI windows as Windows HWNDs
owned by `msrdc.exe` / `wslhost.exe`. We `SetParent` them into our
`HwndHost` (same approach as QEMU's GTK toplevel, but the foreign
windows are RDP-RAIL — needs verification but should work).

## Lifecycle measurements (from spike)

| Operation | Time |
|---|---|
| `wsl --export Ubuntu-24.04` (1 GB) | 91s — one-time bake |
| `wsl --import` from a 1 GB tar.gz | 13s — per cold tab |
| `wsl --terminate` then first command | 2.8s — warm tab |
| `wsl --unregister` | <1s |

For "click new tab → kitty visible" to feel snappy (<2s), keep a
warm pool of pre-imported distros. Same VMPool pattern macOS uses
(`Sources/SandboxEngine/VMPool.swift`).

## Code carryover from the QEMU port (commit 86be3d1)

**Ports unchanged:** `Bromure.AC.Core` (Profile, ProfileStore,
ProfileEnvExports, KittyConfigBuilder, SessionHomeBuilder,
KubeconfigEntry, …), `Bromure.AC.Mitm` entirely (HttpMitmProxy,
TokenSwapper, OAuthRotationRewriter, AwsResigner, BromureCa, …),
`Bromure.AC` WPF UI shell + ViewModels, `Bromure.Cloud`,
`Bromure.Platform`, `Bromure.AC.Mitm.*`, `setup.sh` (becomes a
chroot script, no Alpine driver), `SessionHomeArchive` (still
useful for tarballing the home dir).

**Replaced:** `Bromure.SandboxEngine.Qemu/*` →
`Bromure.SandboxEngine.Wsl/*`. `QemuSupervisor` → `WslDistro`.
`QemuCommandBuilder` → `WslLaunchOptions`. `QemuPaths` → trivial
(wsl.exe is on PATH). `AlpineInstaller` → `RootfsBaker`
(debootstrap-in-chroot). `QemuKeyboard` → unnecessary (kitty in
WSLg gets keyboard naturally). `FolderShareServer` (sshd) → gone.
`SessionMetadataIso` → optional; we can write directly to the
distro home.

**Deleted:** custom QEMU build pipeline (`scripts/build-qemu.*`),
`Bromure.AC.Display.QemuWindowHost` (replaced by `WslWindowHost`),
`Bromure.SandboxEngine.Vsock/*`.

## Open items

- Validate WSLg HWND embed via SetParent (probably works, needs a real
  test once we have kitty installed)
- Bake script: take the existing `setup.sh`, strip the
  Alpine-installer-driving bits, run it under `debootstrap | chroot`
  to produce `bromure-base.tar.gz`. Same package set.
- Pool of pre-imported distros for snappy tab open
- Per-tab source-port attribution if we want to also identify
  individual processes within a tab (future)
