# Porting Bromure Agentic Coding to Windows — Plan

**Scope.** This plan covers porting **Bromure Agentic Coding (`bromure-ac`)** to **Windows Pro / Enterprise / Education** as a v1. The Browser product (`bromure`, `Sources/Browser` + `Sources/BrowserBridges`) is explicitly out of scope here — see `WIN32_PLAN.md` for the original full-product plan, though note its directory references are stale.

**Why AC first.** Three reasons:

1. **Lower framebuffer demands.** The AC guest renders a kitty terminal, not a 60-fps WebGL/video Chromium. A modest screen-stream pipeline (e.g. 30 fps damage-rect updates over vsock) is acceptable; the Browser would not tolerate it.
2. **Smaller surface area.** AC has ~2 vsock bridges (`SubscriptionTokenBridge:8446`, `CodexTokenBridge:8447`) plus the Mitm engine. Browser has ~15 bridges (CDP, FilePicker, Webcam, FaceSwap, iCloudPasswords, Passkey, Phishing, Warp, Link, Tab, Gesture, CJK, Credential, MediaDevices, etc.) — none of which AC needs.
3. **No Apple-only auth dependencies.** AC has no iCloud Keychain SRP, no AS Authorization passkeys, no AppleScript-driven webcam pipeline. The macOS-specific surface is mostly Keychain (replaceable by Credential Manager) + the VZ stack.

Effectively, AC lets us prove out the host-side rewrite (hypervisor, ephemeral disk, vsock, framebuffer, file shares, clipboard, MITM proxy) on a target whose UX is mostly "a window with a terminal in it" — before tackling the Browser's heavier feature set.

**Target.** Windows 11 Pro / Enterprise / Education on x64 (primary) and ARM64 (secondary). **Windows Home is not a v1 goal** but should fall out for free since we use WHPX (available on all SKUs) — see §2. Validate on Pro/Enterprise/Education first, then add Home in v1.1.

---

## 1. Current AC Architecture (so we know what we're porting)

`Sources/AgentCoding/` (~18.3k LOC):

- **VM lifecycle.** `UbuntuSandboxVM.swift` (492 LOC) — VZ config: `VZEFIBootLoader`, `VZGenericPlatformConfiguration`, `VZVirtioBlockDevice`, `VZVirtioNetworkDevice` (NAT or bridged), `VZVirtioGraphicsDevice` (1920×1200 single scanout), USB keyboard/pointing, virtio-rng, virtio serial console, `VZSpiceAgentPortAttachment` for clipboard, virtiofs shares for `bromure-home` / `bromure-meta` / `bromure-outbox` + arbitrary user-mounted folders.
- **Image.** `UbuntuImageManager.swift` (631 LOC) — downloads + verifies an Ubuntu base image, cloud-init seeding, EFI vars store.
- **Ephemeral disk.** `SessionDisk.swift` (725 LOC) — APFS `clonefile(2)` (line 271) of base.img per session; meta dir + outbox dir provisioning; AWS creds bridging script.
- **Window/UI.** `SessionWindow.swift` (821 LOC, NSWindowController hosting `VZVirtualMachineView`), `ConversationView.swift` (1318 LOC, SwiftUI), `ProfileViews.swift` (3001 LOC), `TraceInspectorView.swift` (533 LOC), `SetupViews.swift`, `EnrollmentSheet.swift`, `CredentialApprovalsView.swift`, `SubscriptionTokenSwapSheet.swift`.
- **App entry.** `BromureAC.swift` (3267 LOC — app delegate, command parsing, state machine, window orchestration).
- **Vsock bridges.** `SubscriptionTokenBridge.swift` (port 8446, Anthropic Claude tokens), `CodexTokenBridge.swift` (port 8447, OpenAI tokens) — both wrap `VZVirtioSocketDevice` / `VZVirtioSocketListener`.
- **MITM proxy stack.** `Mitm/` — `MitmEngine`, `HTTPProxy`, `TLSServerStream`, `BromureCA`, `CertCache`, `AWSResigner`, `SigV4Signer`, `OAuthRotationRewriter`, `SubscriptionFakeMint`, `TokenSwap`, `SessionTokenPlan`, `RealtimeEventTap`, `ConsentBroker`, `CompromiseDetector`, `WebSocketTrace`, `HostAgentClient`, `SecretsVault`, `PassphraseKeychain`, `SSHAgent`, `PrivateSSHAgent`, `OpenSSHKeyFormat`, `CloudCredentials`, `AWSCredentialServer`, `TraceRecord`, `TraceStore`.
- **Cloud + integrations.** `CloudUploader`, `CloudEvents`, `CloudMTLSIdentity`, `LLMEventExtractor`, `AWSConfigParser`, `AWSSSOResolver`, `KubeconfigImport`, `DockerConfigImport`, `DefaultSSHKey`, `TerminalAppDefaults`.
- **Enrollment + subscription.** `Enrollment.swift`, `EnrollmentCLI.swift`, `SubscriptionTokenCoordinator` (700 LOC), `SubscriptionTokenSwapState`.
- **Profile.** `Profile.swift` (2985 LOC), `Profile.swift` config persistence.
- **Guest assets.** `Sources/AgentCoding/Resources/vm-setup/` (separate from `Sources/SandboxEngine/Resources/vm-setup/`) — Ubuntu-specific setup.

Shared from `Sources/SandboxEngine/`: `EphemeralDisk` (Browser path; AC uses `SessionDisk`), `MACAddressPool`, `TraceStore`, `ProgressEvent`, `SandboxError`, `InstallIdentity`, `ManagedProfile*`, `HostNetworkInfo`, `HostNetworkWatcher`, `VPNKeychain` (Browser-only), `NetworkFilter`/`NetworkHealer` (Browser-only).

Dependencies (from `Package.swift:30-46`): `swift-argument-parser`, `Sparkle`, `swift-certificates` (X509), `swift-crypto`, `_CryptoExtras`, `Yams`. **Crucially, AC does not depend on `BrowserBridges` or `onnxruntime`.** ONNX is browser-only (face-swap, phishing).

---

## 2. The Three Big Decisions

### 2.1 Hypervisor — QEMU + WHPX

We use **QEMU** as the VMM, accelerated by **WHPX** (Windows Hypervisor Platform — Microsoft's user-mode hypervisor API, available on Pro/Enterprise/Education **and Home** since Windows 10 1803). The host process spawns a bundled `qemu-system-x86_64` as a subprocess and controls it over a QMP socket.

Why this beats Hyper-V/HCS for our use case:

- **Guest unification with macOS VZ.** Both VZ and QEMU expose paravirtualized devices as standard virtio (virtio-blk, virtio-net, virtio-vsock, virtiofs/virtio-9p, virtio-gpu). Cloud-init and `setup.sh` need almost no hypervisor-specific branching.
- **Lighter host code.** Spawn a process and talk QMP — vs. P/Invoking into `computecore.dll` and managing HCS lifecycle from C#. Easier to debug, easier to onboard new contributors.
- **Linux port path.** Same QEMU command surface; swap WHPX → KVM. The Linux port becomes additive instead of a parallel rewrite.
- **Built-in features we'd otherwise build.** QEMU's `-fsdev local` serves host directories to the guest (no custom 9p server needed); qcow2 backing files are the equivalent of differencing VHDX; `-chardev` / `-device` plumbing handles clipboard and frame transport.
- **Windows Home falls in for free.** WHPX is on all SKUs. Not a v1 goal but free optionality for v1.1.

| | Mapping |
|---|---|
| `VZVirtualMachine` | `qemu-system-x86_64 -accel whpx -machine q35 ...` subprocess + QMP control socket |
| `VZEFIBootLoader` + `VZEFIVariableStore` | `-bios OVMF_CODE.fd` + per-session `-drive if=pflash,file=OVMF_VARS.fd` |
| `VZVirtioBlockDevice` | `-drive file=session.qcow2,if=virtio` (qcow2 with backing file = base image) |
| `VZVirtioNetworkDevice` (NAT) | `-netdev user -device virtio-net-pci` (built-in user-mode SLIRP) |
| `VZVirtioNetworkDevice` (bridged) | `-netdev tap` on an OpenVPN tap-windows6 adapter |
| `VZVirtioGraphicsDevice` | `-device virtio-gpu-pci` (software); `virtio-gpu-gl` with virgl deferred for Browser |
| `VZVirtioSocketDevice` + listener | `-device vhost-vsock-pci,guest-cid=N` with QEMU's user-mode vsock backend; host endpoint exposed as a Windows named pipe |
| `VZSpiceAgentPortAttachment` (clipboard) | Custom `clip-agent` over vsock |
| `VZVirtioFileSystemDevice` (virtiofs) | `-fsdev local,path=...,security_model=mapped-xattr -device virtio-9p-pci` (virtio-9p; virtiofsd on Windows is too immature) |
| `clonefile(2)` (APFS CoW) | `qemu-img create -f qcow2 -F qcow2 -b base.qcow2 session.qcow2` |
| `VZBridgedNetworkInterface` | TAP adapter picker in settings |

Hyper-V/HCS is documented as the **B-plan** if Phase-0 vsock validation fails (see §7).

**GPL compliance for bundled QEMU.** QEMU is GPLv2. We don't link it (subprocess only), so no copyleft contamination of our code. Obligations: ship the matching QEMU source tarball alongside (or a written offer in the installer) and include licenses under `Licenses\` in the install dir. Mechanical.

### 2.2 Language and UI — C#/.NET 8 + WinUI 3 (or WPF as fallback)

- **C#/.NET 8** for the host. Self-contained publish (`dotnet publish --self-contained -p:PublishSingleFile=true`) so users never need to install a .NET runtime. Reasons: mature WHPX-spawn-and-monitor surface via `System.Diagnostics.Process`, first-class Credential Manager / DPAPI / WebAuthn / Windows Hello bindings, mature crypto stack (BouncyCastle for anything `System.Security.Cryptography` lacks), excellent SDKs for the cloud uploader, `System.CommandLine` covers `swift-argument-parser` parity.
- **WinUI 3** is the target. Modern look, MVVM-friendly via `CommunityToolkit.Mvvm`. **Fallback: WPF** if WinUI 3 maturity bites — particularly for hosting a custom DirectX surface for the framebuffer (WPF's `D3DImage` is a known good path; WinUI 3's `SwapChainPanel` works but has more rough edges).
- **Skip Swift-on-Windows.** Foundation gaps + no UI bindings + we'd reinvent every shim ourselves.
- **Skip Electron/Tauri.** A Chromium runtime hosting a window of a VM that's running a terminal is absurd.

### 2.3 Host-side display embedding — guest frame-push agent over vsock

**Important framing:** this is *not* about whether X11 works under QEMU. X11 works perfectly — QEMU presents the same virtio-gpu device as VZ on macOS, so kitty (and eventually Chromium) renders unchanged inside the guest. The guest's X stack is identical to today's. **What's different is how the host embeds the guest's display in our app window.** macOS gives us `VZVirtualMachineView` for free; QEMU on Windows has no such embedded-rendering API.

Three options for the host embedding:

| Option | Pros | Cons |
|---|---|---|
| **QEMU's `-display sdl` / `-display gtk`** | Built in; just works | Spawns its own OS window; can't embed inside a WinUI 3 surface; doesn't scale to a future shared pipeline with macOS |
| **Custom vsock frame-push agent (`fb-agent`)** (recommended) | We control everything; ~30 fps damage-rect protocol is plenty for a terminal; reuses the same vsock plumbing as bridges; **same pipeline can replace `VZVirtualMachineView` on macOS later → one host renderer across both OSes**; scales to Browser by adding GPU-PV in the guest (see §6) without changing the host pipeline | We have to build it; first-frame latency from agent startup |
| **VNC server in guest** | Off-the-shelf; broad tooling | Exposes a TCP service even if bound to a vsock-tunneled loopback; redundant frame compression on top of an already-paravirtualized graphics device |

**Recommendation:** ship a small Rust agent (`fb-agent`) in the guest that grabs from the X server via XDamage and pushes damage-rect updates over vsock to a host-side D3D11 surface (WinUI 3 `SwapChainPanel` or WPF `D3DImage`). For AC's terminal-heavy workload, 30 fps is fine; for Browser, scale up to 60 fps and pair with virtio-gpu+virgl in the guest for hardware-accelerated rendering (see §6 "Scaling to Browser"). Keep the protocol simple: header + dirty-rect list + lz4/zstd-compressed pixel runs; optional NVENC/AMF H.264 encode for the Browser high-fps path.

This decision is **the single biggest UX risk** — gate phases on a Phase-0 spike that proves typing latency is acceptable (target ≤30 ms keystroke-to-glyph round-trip). The fb-agent path is also **the cheapest way to keep the guest unified across hypervisors**: only the *host* renderer changes per platform; the guest grows one systemd service.

---

## 3. Target Solution Layout

```
Bromure.AC/                         (WinUI 3 app — replaces Sources/AgentCoding)
  Views/                            (XAML pages: ConversationView, ProfileViews, TraceInspector, etc.)
  ViewModels/                       (CommunityToolkit.Mvvm-based)
  App.xaml + App.xaml.cs
Bromure.AC.Mitm/                    (class lib — replaces Sources/AgentCoding/Mitm)
  HttpProxy.cs
  TlsServerStream.cs
  BromureCa.cs
  AwsResigner.cs / SigV4Signer.cs
  OAuthRotationRewriter.cs
  ConsentBroker.cs / RealtimeEventTap.cs
  ...
Bromure.Cloud/                      (class lib — CloudUploader, CloudEvents, mTLS identity, LLMEventExtractor)
Bromure.SandboxEngine/              (class lib — VM lifecycle, vsock, ephemeral disk)
  Qemu/                             (process supervisor, QMP client, command-line builder)
  Vsock/                            (named-pipe ↔ guest-vsock bridge)
  Disk/                             (qcow2 backing-file overlays via qemu-img)
  FrameBuffer/                      (host endpoint of fb-agent protocol)
Bromure.Platform/                   (NEW — host abstractions)
  ISecretStore (DPAPI + Credential Manager)
  ISettingsStore (%LOCALAPPDATA% JSON)
  IAppUpdater (WinSparkle)
Bromure.Tests/                      (xUnit)
guest/fb-agent/                     (Rust — new guest binary; lives in Resources/vm-setup/)
guest/clip-agent/                   (Rust — vsock clipboard, replaces spice-vdagent)
Resources/vm-setup/                 (Ubuntu cloud-init seed; minimal divergence from VZ build)
Resources/qemu/                     (bundled qemu-system-x86_64 + OVMF + license docs)
installer/                          (Inno Setup script + first-run feature-enablement helpers)
build/                              (PowerShell + dotnet publish + signtool + Inno Setup compile)
```

Introduce `Bromure.Platform` so we can later port the Browser product behind the same seam without re-cracking the AC port. Don't over-design: only put behind interfaces what the Mitm engine and SandboxEngine actually call into.

---

## 4. What Stays, What Gets Abstracted, What Gets Rewritten

### Stays (reused with little or no change)

- **Wire formats.** `SubscriptionTokenBridge` framing on port 8446, `CodexTokenBridge` framing on port 8447 — port the C# client to QEMU's vsock named-pipe bridge with the same byte layout.
- **MITM TLS interception logic.** Algorithm-level: SigV4 re-signing, OAuth rotation, subscription fake-mint, session-token plan, consent broker decisions. The `swift-crypto` + `swift-certificates` calls map cleanly to `System.Security.Cryptography` + `BouncyCastle` for the niche bits (X509 cert minting at runtime via BC is well-trodden).
- **Trace SQLite schema.** `TraceStore` — port to `Microsoft.Data.Sqlite` with the same schema.
- **Cloud upload contract.** `CloudUploader`, `CloudEvents`, `CloudMTLSIdentity` — straight HTTP + mTLS port.
- **AWS / Kube / Docker config parsers.** `AWSConfigParser`, `AWSSSOResolver`, `KubeconfigImport`, `DockerConfigImport` — pure-text parsers; ports almost line-for-line. Use `YamlDotNet` to replace `Yams`.
- **Ubuntu guest base.** Ubuntu cloud-init image + most of the on-boot setup. **Caveats below.**
- **`bromure-aws-creds.py` and the rest of the guest-side scripts referenced from `bromure-meta`.** They run inside the guest, so they're hypervisor-agnostic.

### Abstracted behind `Bromure.Platform`

- **Secrets.** `PassphraseKeychain.swift` (`kSecClassGenericPassword`) → `ISecretStore` backed by Credential Manager (`CredWrite` / `CredRead` / `CredDelete`) for short tokens; DPAPI (`ProtectedData.Protect`) for larger blobs (e.g. cached MITM CA private key, refresh tokens).
- **Settings.** `UserDefaults` calls scattered through AC → `ISettingsStore` reading/writing JSON in `%LOCALAPPDATA%\Bromure\AC\settings.json`.
- **App support paths.** `~/Library/Application Support/Bromure/AC/` → `%LOCALAPPDATA%\Bromure\AC\`. Profiles in `%LOCALAPPDATA%\Bromure\AC\profiles\*.json` (same JSON shape).
- **Auto-update.** Sparkle → WinSparkle (same appcast XML). Single-source the appcast with macOS so we publish one release feed.

### Rewritten for Windows

- **`UbuntuSandboxVM.swift`.** Reimplemented as a QEMU process supervisor: build the command line, spawn `qemu-system-x86_64`, open the QMP socket, monitor lifecycle. Same shape as today — build a config, attach disk, network, graphics, vsock, file shares, clipboard, then start. Replace `VZVirtualMachineDelegate` callbacks with QMP event subscriptions.
- **`UbuntuImageManager.swift`.** Producer side: download Ubuntu ARM64+x64 cloud images, leave them as **qcow2** (no VHDX conversion needed — QEMU consumes qcow2 natively), generate cloud-init seed ISO, persist OVMF NVRAM as a separate file. Verification (signature/checksum) ports straight.
- **`SessionDisk.swift`.** Replace `clonefile(2)` (line 271) with `qemu-img create -f qcow2 -F qcow2 -b base.qcow2 session.qcow2` — qcow2 backing files give us CoW overlay semantics with the same instant-create cost as `clonefile`. The "meta" + "outbox" directory plumbing stays — only the share *transport* changes (see below).
- **File shares (`bromure-home`, `bromure-meta`, `bromure-outbox`, user shares).** Use QEMU's built-in virtio-9p server: `-fsdev local,id=home,path=...,security_model=mapped-xattr -device virtio-9p-pci,fsdev=home,mount_tag=bromure-home`. Guest mounts with `mount -t 9p -o trans=virtio,version=9p2000.L bromure-home /home/user`. **No custom 9p server to write** — QEMU already serves the host directory directly. virtiofs is the higher-throughput alternative but `virtiofsd` on Windows is too immature for v1; revisit if/when it stabilizes.
- **Clipboard (`VZSpiceAgentPortAttachment`).** Build a small guest agent (`clip-agent`) talking vsock to a host clipboard service. ~150 LOC in Rust. Keep the protocol minimal (text-only initially; image/HTML later if needed).
- **`SessionWindow.swift`.** WinUI 3 window. Custom `SwapChainPanel` (or WPF `D3DImage`) hosting the framebuffer surface fed by `fb-agent` (the guest's X11 stack itself is unchanged — see §6). The "red translucent overlay sat on top of the VZ framebuffer" idea (line 74 in current file) ports straight — just an overlay on the same panel.
- **`BromureAC.swift` (3267 LOC).** App delegate + lifecycle + command parsing + state machine. The state machine logic ports nearly 1:1 to C#; the entry surface (NSApplication delegate methods, AppleScript handlers) gets replaced by WinUI 3's `App.OnLaunched` + a named-pipe IPC channel for any "send this URL to running AC" handoff that today goes through `ScriptCommands.swift` / `BromureAC.sdef`.
- **`BromureAC.sdef` + `ScriptCommands.swift`.** AppleScript is macOS-only. Replace with a named-pipe RPC if we have any external automation surface today.
- **All 9 SwiftUI views.** Rebuild as XAML. The MVVM port is mechanical; the heaviest are `ProfileViews` (3001 LOC) and `ConversationView` (1318 LOC).
- **`SSHAgent.swift` + `PrivateSSHAgent.swift`.** OpenSSH agent forwarding. The wire protocol is unchanged; the host-side socket switches from `~/.bromure/agent.sock` (Unix domain socket) to a Windows named pipe (`\\.\pipe\bromure-ac-ssh-agent`) consumed by OpenSSH for Windows (which already supports named-pipe agent sockets via the `SSH_AUTH_SOCK` env var pointing at a pipe path). Or expose it on the guest side directly via vsock and skip the host agent entirely.
- **`build.sh`.** PowerShell script: `dotnet publish --self-contained -p:PublishSingleFile=true` → bundle QEMU + OVMF + qcow2 base image + guest agents → `iscc installer.iss` (Inno Setup) → `signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256` (Authenticode EV). Single signed `.exe` output. See §6 "Installer and first-run UX" for the contract the installer has to honor.

### Removed / N/A

- **`Mitm/PassphraseKeychain.swift`** — replaced by Credential Manager.
- **`Mitm/SecretsVault.swift`** — depends on review; if it wraps Keychain, it gets the same DPAPI/Credential Manager treatment.
- All `_silgen_name("clonefile")` / `<sys/clonefile.h>` references — gone.
- `Sources/HostServices/ClipboardBridge.swift` — replaced by the new clip-agent + host service.
- `Sources/SandboxEngine/CVmnet/` — Browser-only; AC doesn't need vmnet.
- `Sources/SandboxEngine/NetworkFilter.swift` / `NetworkHealer.swift` / `VPNKeychain.swift` / `IKEv2Bridge.swift` / `WireGuardBridge.swift` / `MTLSReloadBridge.swift` / `NetworkRefreshBridge.swift` — Browser-only; not on the AC critical path.
- `Sources/SandboxEngine/BaseImageManager.swift` — Browser/macOS-IPSW-only.

---

## 5. Phased Plan

### Phase 0 — Spikes (3 weeks, gating)

Gate the rest of the project on these working:

1. **QEMU+WHPX vsock round-trip.** Spawn `qemu-system-x86_64 -accel whpx -device vhost-vsock-pci,guest-cid=3 ...` from a C# console app, expose the host endpoint as a Windows named pipe, run an unmodified `claude-token-agent.py` in the guest that connects via `AF_VSOCK`. Round-trip a token swap. **Pass criterion:** wire format unchanged; latency < 50 ms p95. **This is the gate that decides QEMU vs. Hyper-V.** If it fails, fall back to either (a) Hyper-V/HCS + AF_HYPERV (B-plan) or (b) TCP-over-NAT-switch with bridge-level auth.
2. **qcow2 backing-file boot timing.** Pre-warm a session VM whose disk is a fresh qcow2 overlay off a 4 GB base. **Pass criterion:** ≤ 1.5 s from "create overlay" to "guest at login prompt" on a typical NVMe drive.
3. **Framebuffer + typing latency.** Build a throwaway `fb-agent` (Rust) that pushes 1920×1080 damage-rects over vsock to a WinUI 3 `SwapChainPanel`. Render kitty inside the guest, type rapidly. **Pass criterion:** keystroke-to-glyph ≤ 30 ms p95, no visible tearing at terminal repaint sizes.
4. **virtio-9p throughput.** Guest mounts a QEMU-served `-fsdev local` directory and reads/writes a 100 MB file. **Pass criterion:** correctness + ≥ 200 MB/s throughput.
5. **Installer end-to-end.** Build a throwaway Inno Setup installer that bundles a 1.5 GB payload, runs elevated, calls `Enable-WindowsOptionalFeature` for `HypervisorPlatform` + `VirtualMachinePlatform`, schedules a `RunOnce` continuation, reboots, and finishes installation post-reboot on a clean Win11 Pro VM. **Pass criterion:** zero manual steps, no leftover console windows, app launches successfully on first non-elevated run. (Order EV cert in parallel — 1–4 week lead time.)

Outcome: a written go/no-go on each. If (1), (3), (4), or (5) fail, we revisit the architecture before committing the rest of the budget.

### Phase 1 — Platform abstraction on macOS (2 weeks)

Land `ISecretStore`, `ISettingsStore`, `IEphemeralDisk`, `IVsockListener`, `IVsockConnection`, `IFileShare`, `IFrameBufferSink`, `IClipboardChannel` as Swift protocols in `Sources/SandboxEngine/Platform/` (or a new `BromurePlatform` target). Make the existing AC code call through them; the macOS implementation is a 1:1 wrap of today's calls. This is pure refactor on the existing CI; it's the only way to know the interfaces are right before C# starts implementing them. **Skip this and we guarantee drift between the two ports.**

### Phase 2 — Windows VM lifecycle + vsock + first bridge (3 weeks)

In `Bromure.SandboxEngine` (C#):

- QEMU process supervisor: command-line builder, spawn, QMP socket client, lifecycle events.
- `qemu-img create -f qcow2 -F qcow2 -b base.qcow2 session.qcow2` for ephemeral disks.
- Vsock named-pipe bridge: each guest-side `connect(VMADDR_CID_HOST, port)` lands on a Windows named pipe handler in our C# code.
- VM pool (pre-warm N, claim, replenish) — pure state machine, port from `VMPool.swift` directly.
- Port `SubscriptionTokenBridge` end-to-end. Headless test: start a VM, run `claude-token-agent.py`, swap a token, verify trace event.

No UI yet.

### Phase 3 — Shares, clipboard, MITM proxy (4 weeks)

- QEMU-served virtio-9p shares for `bromure-home` / `bromure-meta` / `bromure-outbox` plus user-mounted dirs (built-in to QEMU — no host-side server to write).
- `clip-agent` guest binary + host clipboard channel over vsock.
- Port `Mitm/HTTPProxy` + `TLSServerStream` + `BromureCA` + `CertCache`.
- Port `SigV4Signer` + `AWSResigner` + `OAuthRotationRewriter` + `SubscriptionFakeMint` + `TokenSwap`.
- Port `ConsentBroker` + `RealtimeEventTap` + `WebSocketTrace`.
- Port `TraceStore` (SQLite).
- Port `CodexTokenBridge` (mostly mechanical after `SubscriptionTokenBridge`).
- Headless validation: drive a full session (subscription token swap + AWS SigV4 re-sign + OAuth rotation + trace upload) without the UI.

### Phase 4 — WinUI shell + framebuffer (5 weeks)

- WinUI 3 app skeleton, `App.xaml`, navigation.
- Embedded framebuffer surface wired to `fb-agent`.
- Port the views in this order (smallest → largest, fastest feedback):
  1. `EnrollmentSheet` + `SetupViews` (~500 LOC combined)
  2. `CredentialApprovalsView` + `SubscriptionTokenSwapSheet` (~250 LOC)
  3. `TraceInspectorView` (533 LOC)
  4. `ConversationView` (1318 LOC)
  5. `ProfileViews` (3001 LOC) — the heaviest; structure as multiple XAML pages
- `BromureAC.swift` state machine ported to a top-level `AppShell` view-model.
- Localization: keep all 8 .lproj entries; Windows uses `.resw` resource files. Run an automated migration on the existing strings.

### Phase 5 — Cloud, enrollment, subscription, SSH agent, secrets (3 weeks)

- `CloudUploader` + `CloudMTLSIdentity` + `CloudEvents` + `LLMEventExtractor` ports (all HTTP + mTLS — straight C# port).
- `Enrollment` + `EnrollmentCLI` + `SubscriptionTokenCoordinator` (700 LOC) + `SubscriptionTokenSwapState`.
- `AWSConfigParser` + `AWSSSOResolver` + `KubeconfigImport` + `DockerConfigImport` + `DefaultSSHKey` + `TerminalAppDefaults` (each <300 LOC).
- `SSHAgent` + `PrivateSSHAgent` over a Windows named pipe.
- Credential Manager / DPAPI implementation of `ISecretStore`.

### Phase 6 — Installer, updates, signing, hardening (3 weeks)

- Production Inno Setup installer per the §6 contract: stub + full variants, EV-signed, RunOnce-resume around feature enablement, GPL/license bundling.
- Authenticode signing with the EV cert (ordered in Phase 0).
- WinSparkle integration (appcast shared with macOS).
- SmartScreen reputation: ship to a small internal ring first to accrue submissions before public release.
- BitLocker-aware install (don't bork on encrypted volumes).
- Dogfood for two weeks.

### Phase 7 — Release (2 weeks)

- E2E test rebuild (`Tests/AgentCodingTests` ports to xUnit).
- `Jenkinsfile.ac` Windows variant.
- Documentation (`BUILD_INSTRUCTIONS.md` Windows section, `README.md` install steps).
- Public release.

**Total: ~25 weeks for one engineer** (QEMU+Inno simplified Phase 2 by ~1 week vs. the earlier HCS plan; offset by an extra day in Phase 0 for the installer spike). With two engineers splitting after Phase 1 (one on backend/MITM, one on UI/framebuffer), **~15 calendar weeks to MVP**, then +4 weeks polish/release. Add the customary 30% buffer for unknowns.

---

## 6. Component-Specific Notes

### Ubuntu guest under QEMU+WHPX

The current AC guest is Ubuntu running X11 + xinitrc + kitty. **The X11 stack is unchanged.** QEMU exposes the guest as a standard set of virtio devices — same family VZ uses on macOS — so cloud-init, `setup.sh`, kernel modules, mount types, and every Python agent are essentially identical to the macOS build.

What changes (very small, all in cloud-init or `setup.sh`):

- **Kernel modules: nothing to do.** Both VZ and QEMU paravirtualize via virtio. udev loads `virtio_blk`, `virtio_net`, `virtio_console`, `virtio_pci`, `virtio_gpu`, `virtio_9p`, `virtio_vsock` on both. All in mainline.
- **Disk path.** `/dev/vda` (virtio-blk) on both. No change.
- **Shares.** Cloud-init mounts virtiofs tags `bromure-home` / `bromure-meta` / `bromure-outbox` on macOS. On Windows we use virtio-9p with the same mount tags: `mount -t 9p -o trans=virtio,version=9p2000.L bromure-home /mnt/bromure-home`. One conditional in cloud-init's `mounts` module — that's all the divergence.
- **Spice → clip-agent.** Drop `spice-vdagent`, install our vsock-based `clip-agent` as a systemd user service. Long-term `clip-agent` could replace spice on the macOS branch too — the protocol is ~150 LOC.
- **fb-agent.** Add it as a systemd service on the QEMU branch (no-op on macOS, where `VZVirtualMachineView` does the equivalent host-side). Captures from XDamage so we get cursor + composited output.
- **Resize.** `resize-watcher.sh` polls VZ's display config; on QEMU we drive `virtio-gpu` resize from the host via QMP `device_set_user_creatable_state` / `screendump` events, or a SIGWINCH-via-vsock signal.

X11, xinitrc, kitty (AC), Chromium (Browser later), and **every Python agent** are unchanged.

### Scaling to Browser later — GPU acceleration in the guest

For the eventual Browser port, software-rendered `virtio-gpu` will be a bottleneck (Chromium video / WebGL want hardware compositing). Two paths, both deferrable until Browser:

- **virtio-gpu + virgl** (QEMU-native): replace `-device virtio-gpu-pci` with `-device virtio-gpu-gl-pci` (QEMU's virgl-enabled GPU). Mesa's virgl renderer in the guest forwards GL calls to the host. On Windows this requires the host's QEMU build to be linked against ANGLE-on-D3D — Stefan Weil's MSYS2 builds don't ship this by default; we either build our own QEMU or wait for upstream Windows packaging to mature.
- **NVENC/AMF host encode**: keep `virtio-gpu` software-rendered in the guest, but the host `fb-agent` endpoint encodes the frame stream as H.264 using the host GPU's video encoder. Compositing is software in the guest, but transport/scaling is hardware on the host. Simpler than virgl-on-Windows, lower visual fidelity.

Either way, **the same host pipeline (`fb-agent` → `SwapChainPanel`) serves both AC and Browser**. No second display path. Defer the call until Browser; both options are additive.

### Networking

AC's macOS networking is `VZNATNetworkDeviceAttachment` (default) or `VZBridgedNetworkDeviceAttachment` (opt-in). Map:

- **NAT** → QEMU's built-in user-mode networking (`-netdev user`). Identical UX, no admin required, no virtual switch to configure.
- **Bridged** → QEMU TAP via OpenVPN's `tap-windows6` driver bundled in the installer. UX needs a "pick adapter" picker in settings (we already have one). TAP install is the only place we need driver signing / WHQL beyond Authenticode — `tap-windows6` is already WHQL-signed, so we just bundle it.

The MITM proxy is host-side, listening on a vsock port; guest routes outbound via that port. Architecture unchanged.

### Architecture (x64 vs ARM64)

Same as `WIN32_PLAN.md` §6: x64 primary, ARM64 secondary. Single .NET 8 solution cross-compiles. .NET 8 has good ARM64 codegen. Ubuntu cloud images exist for both.

### MITM CA private key storage

On macOS this lives in Keychain (`PassphraseKeychain`). On Windows, prefer **DPAPI** with `LocalMachine` scope rather than Credential Manager — the CA private key is large (RSA-3072+) and we want it bound to the device, not the user, so kiosk / shared-machine deployments work. Wrap it in DPAPI then store at `%PROGRAMDATA%\Bromure\AC\mitm-ca.bin`. Document the trust impact (BitLocker-on-by-default makes this materially safe; without BitLocker, anyone with admin can unwrap).

### Installer and first-run UX

**Hard requirement: the install experience must be one click.** The user double-clicks `BromureAC-Setup.exe`, accepts a single UAC prompt, optionally accepts one reboot, and lands on a working app. No "next, next, finish" wizard. No checkbox forest. No prerequisites the user has to install themselves.

**What ships in the installer:**

- The host app, published self-contained (`dotnet publish --self-contained -p:PublishSingleFile=true`). No separate .NET runtime install.
- The bundled QEMU binary (~30 MB) under `<install>\lib\qemu\` — never on the user's PATH; only invoked as a subprocess from our own code.
- OVMF firmware (UEFI) for the guest.
- The guest qcow2 base image. See "Stub vs. full installer" below.
- `tap-windows6` driver (WHQL-signed by OpenVPN) for the optional bridged-network mode.
- License files (ours + QEMU GPLv2 + tap-windows6 + .NET runtime + every other bundled component) under `<install>\Licenses\`.
- An offline copy of the matching QEMU source tarball, or a `OFFER-FOR-SOURCE.txt` pointing at our public mirror, for GPL compliance.

**What the installer does on first launch:**

1. UAC elevates immediately (manifested `requireAdministrator`).
2. Probes for `HypervisorPlatform` + `VirtualMachinePlatform`. If both already enabled (e.g., a WSL2 user), skip to step 5.
3. If either is missing, runs `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart` (+ same for `VirtualMachinePlatform`).
4. Stages a `RunOnce` continuation entry under `HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce` and prompts for reboot with a single clear sentence ("Windows needs to enable its built-in virtualization to run Bromure. Reboot now?"). On reboot, the RunOnce fires, completes file extraction, removes itself.
5. Finishes file copy, registers the Start Menu shortcut, drops a desktop icon (optional checkbox in advanced mode only).
6. Launches the app once, non-elevated, as the installing user. **First launch is the user's first interaction with the product — not the installer.**

**Stub vs. full installer.** Host + QEMU + OVMF together are ~200 MB. The guest qcow2 is ~1.5 GB compressed. Two strategies, both worth shipping:

- **Stub installer (~200 MB)** — public web download. On first run, downloads the qcow2 with a clean progress bar. Better perceived install time over broadband.
- **Full installer (~1.7 GB)** — single download, no network at first run. For offline / managed / air-gapped deployments.

Both ship from the same release process; the only difference is whether the qcow2 is bundled in the EXE payload or fetched on first run from our CDN.

**Installer technology: Inno Setup.** Reasons: fast to author (Pascal Script for the feature-enablement custom action), single signed EXE output, handles a 1.7 GB payload cleanly with LZMA2 compression, integrates with our existing release tooling. **Skip MSIX for v1** — packaged-app constraints around feature enablement, large payloads, and subprocess invocation make the experience worse, not better. Revisit MSIX for v2 once the install flow is well-understood and we know which capabilities we actually need. **Skip plain MSI** — Inno Setup gives us better defaults for a consumer install; reserve MSI for an enterprise SCCM/GPO variant later if customers ask.

**Idempotent first-run.** Detect if the hypervisor features were already enabled before our install (a WSL2 user). Detect if a deferred reboot is pending and skip the prompt. If the user reboots manually before answering our prompt, the RunOnce fires anyway and the install completes. The only state we persist between reboots is one registry key.

**Uninstall.** Cleanly removes everything in `%PROGRAMFILES%\Bromure\AC\`. Asks (default: "keep") whether to delete `%LOCALAPPDATA%\Bromure\AC\` (profiles, traces, MITM CA). **Does not** disable the Windows hypervisor features — they're shared with WSL2, Docker Desktop, and Windows Sandbox; touching them is not our call.

**Antivirus / SmartScreen friction.** EV-signed binary, dogfood ring before public launch (§ Phase 6) to seed SmartScreen reputation, AV-vendor allowlist outreach in parallel.

### Code signing

EV cert + HSM (~$400–700/yr). Order at Phase 0 start (1–4 week lead time); reputation builds during dogfood (Phase 6).

### Bundle ID / app identity

- macOS bundle ID: `io.bromure.ac` (or whatever `BromureAC.entitlements` reflects).
- Windows: `Bromure Agentic Coding` registered under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\io.bromure.ac`.

---

## 7. Risks and Open Questions

1. **vsock on QEMU+WHPX.** Phase 0 spike (1) is the gate that decides QEMU vs. Hyper-V. QEMU's user-mode virtio-vsock works on non-KVM accelerators in 8.x+ but is less battle-tested than the KVM path. **B-plan if it fails:** either swap the hypervisor to Hyper-V/HCS + AF_HYPERV (rewrite Phase 2's lifecycle code, ~1 extra week) or keep QEMU and tunnel bridges over TCP-on-the-NAT-switch (gives up vsock's address-space isolation but our trust model already relies on bridge-level auth, not network isolation).
2. **Host-side framebuffer pipeline.** Phase 0 spike (3) is the second-biggest gate — the guest X11 stack is unchanged but the host renderer is new. Mitigation: bridge to a windowed `qemu-system -display sdl` as a B-plan; uglier but works.
3. **Installer feature-enablement UX.** Phase 0 spike (5). The `Enable-WindowsOptionalFeature` + `RunOnce` + reboot dance has many failure modes (BitLocker pause, pending Windows updates, Group Policy blocking the feature). Test on a clean Win11 Pro VM and on a heavily-managed enterprise image before locking the design.
4. **EDR hostility.** Some enterprise EDRs flag QEMU and/or WHPX usage as suspicious. Validate with two or three large vendors before committing — this is shared with the Hyper-V path so the risk is roughly the same.
5. **MITM CA trust on Windows.** Programmatic install into `Cert:\LocalMachine\Root` requires admin. The installer is already elevated, so the first-run UX can drop the cert in step 5 of the install flow. Document an admin-led GPO route for managed deployments.
6. **Subscription tokens cross-platform.** Today subscription tokens enrolled on macOS sit in macOS Keychain. Spec the cross-device flow (re-enroll on Windows? sync via the existing managed-profile cloud channel?) before Phase 5.
7. **Yams → YamlDotNet semantic parity.** YAML edge cases (custom tags, anchors, multi-doc) sometimes drift between libraries. Diff a corpus of real configs in Phase 5.
8. **clip-agent on Wayland vs. X11.** AC currently uses X (xinitrc + kitty under X). Stay X11-only on the guest for v1; revisit if we move to Wayland.
9. **GPL audit.** Bundled QEMU is GPLv2; we don't link it, but a legal pass on our distribution flow (source mirroring, offer text, bundled license files, no contamination of host code) before public release is non-negotiable.

---

## 8. Effort Estimate

| Phase | Weeks (1 eng) | Critical path? |
|---|---|---|
| 0 — Spikes (incl. installer spike + EV cert order) | 3 | Yes |
| 1 — Platform abstraction (macOS) | 2 | Yes |
| 2 — QEMU lifecycle + vsock + 1 bridge | 3 | Yes |
| 3 — Shares, clipboard, MITM proxy | 4 | Yes |
| 4 — WinUI shell + framebuffer | 5 | Parallelizable with 3 |
| 5 — Cloud, enrollment, secrets | 3 | — |
| 6 — Installer, signing, updates, hardening | 3 | — |
| 7 — Release | 2 | — |
| **Total (1 engineer)** | **25 weeks** | |

With **two engineers** splitting after Phase 1 (backend track: 2→3→5; UI track: framebuffer prototype → 4 → 6), **~15 calendar weeks to MVP** + 4 weeks polish/release. Add 30% buffer for unknowns.

---

## 9. First Concrete Step

Start the Phase 0 spike repo today. One C# console app driving a bundled QEMU + one Ubuntu cloud image + one tiny `fb-agent` Rust binary + one throwaway Inno Setup script. Five pass/fail gates: vsock-on-QEMU+WHPX, qcow2 boot timing, fb-agent typing latency, virtio-9p throughput, end-to-end installer flow. Three-week deadline. If any gate fails, course-correct before committing the rest of the budget.

In parallel: order the EV cert + HSM (1–4 week lead time).

In parallel: order the EV cert and HSM. Six-week lead times are common.

---

## 10. What This Plan Does *Not* Cover

- **Browser product port.** See `WIN32_PLAN.md` for the original full-product plan, with the caveat that its directory structure, hypervisor choice, and Browser/AC split are all out of date. The QEMU+WHPX backend in this plan is intended to be reused by Browser as-is; Browser-side adds: `BrowserBridges` (CDP, FilePicker, Webcam, FaceSwap, iCloudPasswords, Passkey, Phishing, Warp, Link, Tab, Gesture, CJK, Credential, MediaDevices), `Sources/SandboxEngine/CVmnet`, `NetworkFilter`/`NetworkHealer`/`VPNKeychain`/`IKEv2Bridge`/`WireGuardBridge`/`MTLSReloadBridge`/`NetworkRefreshBridge`, ONNX models for face-swap and phishing, GPU acceleration in the guest (virgl or NVENC encode), and the much higher framebuffer fps target.
- **Linux port.** Free side benefit of the QEMU choice — same QEMU command surface, swap WHPX → KVM, swap the host UI (likely GTK4 or Qt6). Tracked separately; not v1 work.
- **Windows Home v1.1.** WHPX is on all SKUs, so Home should largely "just work" — but we won't ship it until we've validated the AC product on Pro/Enterprise/Education first.
- **Microsoft Store submission.** Optional follow-up. The MSIX repackaging would happen after the Inno Setup install flow is stable.
