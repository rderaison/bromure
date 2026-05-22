# 10 — Image Manager / Session Disk / Session Window / VM Lifecycle

Audit of `UbuntuImageManager.swift` (631 LOC), `UbuntuSandboxVM.swift`
(492 LOC), `SessionDisk.swift` (905 LOC), `SessionWindow.swift`
(821 LOC), and the image/alert/window code paths inside
`BromureAC.swift` against the in-flight Windows HCS port.

The Windows port is mid-pivot to direct HCS + VHDX differencing
clones. Files of record on disk today:

- `windows/Bromure.SandboxEngine/Hcs/VmBaker.cs`            (the bake)
- `windows/Bromure.SandboxEngine/Hcs/HcsVm.cs`              (compute system)
- `windows/Bromure.SandboxEngine/Hcs/HcsSession.cs`         (per-session)
- `windows/Bromure.SandboxEngine/Hcs/VhdxDisk.cs`           (CoW clone)
- `windows/Bromure.SandboxEngine/Hcs/WarmVmPool.cs`         (warm pool)
- `windows/Bromure.SandboxEngine/Image/ImageManager.cs`     (downloads)
- `windows/Bromure.AC/Views/SessionWindow.xaml{,.cs}`
- `windows/Bromure.AC/Display/HcsSessionWindowHost.cs`      (mstsc embed — UNUSED)
- `windows/Bromure.AC/Display/VncClient.cs`                 (RFB client — actual transport)
- `windows/Bromure.AC/Display/VncControl.cs`
- `windows/Bromure.AC/Display/GuestCommand.cs`              (host→guest cmd over hvsocket)
- `windows/Bromure.AC/Display/GuestEventServer.cs`          (guest→host events)
- `windows/Bromure.AC/ViewModels/SessionViewModel.cs`
- `windows/Bromure.AC/ViewModels/SessionsViewModel.cs`

Severities:
- **MISSING**:  no equivalent on Windows, behavior not present
- **PARTIAL**:  partial implementation, materially incomplete
- **DIFFERENT**: implemented but with behavior the user will notice
- **IN-PROGRESS**: actively being ported as part of HCS pivot
- **OK**:       behavioral parity

---

## 0. THE IMAGE-VERSIONING ALERT (user's headline example)

### 0.1 Bumpable `imageVersion` constant on the image manager

- **macOS source**: `Sources/AgentCoding/UbuntuImageManager.swift:22-45`
  — `public static let imageVersion = "100"` plus a long policy comment
  ("**NEVER bump this without explicit user approval**"). Bumping
  invalidates every cached profile disk on next launch.
- **Windows status**: **MISSING**.
  `Bromure.SandboxEngine/Image/ImageManager.cs` only exposes static
  `ImageDescriptor`s with pinned SHA-256 + byte sizes (Alpine virt
  ISO at v3.20.3). `VmBaker.cs` has `AlpineRelease="3.22.3"` /
  `AlpineMajor="3.22"` constants and `OutputBaseFileName="bromure-base.vhdx"`,
  but **no bumpable base-image version stamp**, no "this build of the
  app expects image vN" indicator, nothing analogous to `imageVersion = "100"`.
- **Detail**: The macOS image manager writes the `imageVersion`
  string into `base.version` on every successful build
  (`UbuntuImageManager.swift:84,203`). On Windows the only persisted
  signal is the parent VHDX's mtime — `VhdxDisk.CreateChildSync` at
  `VhdxDisk.cs:65-72` uses `File.GetLastWriteTimeUtc(ParentPath) > childTime`
  to detect a rebake and recreate the child. No semantic version, no
  user-facing string ("v100"), no policy of approval before bumping.

### 0.2 Profile-side recorded version at clone time

- **macOS source**: `Sources/AgentCoding/BromureAC.swift:2357-2363` —
  after `ensureDiskExists()` cloned the disk for the first time, the
  app stamps `profile.baseImageVersionAtClone = currentBaseVersion`
  into the profile JSON and re-saves. The profile model itself has
  `var baseImageVersionAtClone: String?` (Profile.swift:870-876;
  noted as MISSING in audit 01-profile-model.md).
- **Windows status**: **MISSING** — confirmed redundantly with the
  profile-model audit. `Profile` records (Bromure.AC.Core/Model/Profile.cs)
  have no `BaseImageVersionAtClone` field. The Windows session boot
  path (`SessionsViewModel.cs:236-322`) and `SessionViewModel.StartAsync`
  (`SessionViewModel.cs:134-328`) never compare any stored version
  against a current one.

### 0.3 "Base image updated since this profile was created" alert

- **macOS source**: `Sources/AgentCoding/BromureAC.swift:2019-2041`.
  In `launch(_:)`, after the compromise check, BEFORE booting the
  VM, the code computes `currentBaseVersion = readCurrentBaseVersion()`
  (reads `base.version` stamp file) and compares against
  `profile.baseImageVersionAtClone`. If they differ AND the profile
  disk exists, an `NSAlert` pops with:
  - **Title**: "Base image updated since this profile was created."
  - **Body**: "This profile is on base v\(recorded); the current base
    is v\(current). Reset the profile disk to pick up the new base?
    (Resetting wipes anything you've installed inside the VM. Your
    project folder is untouched.)"
  - **Buttons**: `"Reset and launch"` / `"Launch as-is"` / `"Cancel"`
  - **Outcomes**:
    - Reset → `try? store.resetDisk(for: profile)` (deletes child disk
      → `ensureDiskExists` clones a fresh one from the new base)
      → launch continues, eventually re-stamping `baseImageVersionAtClone`
      to `current`.
    - Launch as-is → falls through, profile keeps running on the
      stale clone whose parent UniqueId still matches the old base.
    - Cancel → `return` (no boot).
- **Windows status**: **MISSING**. There is no comparison, no alert,
  no three-way choice. `VhdxDisk.cs:65-72` *silently* deletes and
  recreates the child VHDX when the parent mtime is newer:
  ```csharp
  var parentTime = File.GetLastWriteTimeUtc(ParentPath);
  var childTime  = File.GetLastWriteTimeUtc(Path);
  if (parentTime > childTime)
  {
      try { File.Delete(Path); }
      catch (IOException) { /* fall through */ }
  }
  ```
  The user has **no choice** — a rebake silently wipes every
  profile's stateful child. This is materially worse than macOS:
  on macOS the user can pick "Launch as-is" and keep an installed
  toolchain inside the VM; on Windows the rebake is a forced
  data-loss event.
- **Impact**: This is the user's flagship example. **Top-1
  parity gap of this audit.** Two product behaviors are wrong on
  Windows:
  1. Silent disk wipe instead of a three-button alert.
  2. No way to "Launch as-is" — the user can't keep an older
     working VM after a rebake.

### 0.4 Non-blocking nag: "Base image update available"

- **macOS source**: `BromureAC.swift:1412-1431` `promptBaseImageUpdate()`.
  Triggered at app launch from `BromureAC.swift:584-588` when
  `imageManager.baseImageNeedsUpdate` is true (stale stamp).
  Title: "Base image update available"; body cites installed vs.
  shipped versions; buttons: "Rebuild Now" / "Later".
- **Windows status**: **MISSING**. App-launch flow in
  `ShellViewModel.cs:540-616` only branches on `artefacts.AllExist()`
  — if all three files (`bromure-base.vhdx` + kernel + initrd) are
  on disk, the session phase opens immediately. No staleness check.

### 0.5 Explicit "Rebuild Base Image…" menu action with confirm

- **macOS source**: `BromureAC.swift:159-163` (menu wire-up) and
  `:1401-1410` (`rebuildBaseImageAction`). NSAlert confirms with
  body: "Re-runs the full Ubuntu installer (~5–10 min) using the
  current setup.sh. Existing profiles' disks aren't touched — on
  next launch each one's drift prompt will offer to reset to the
  new base." Choice: "Rebuild" / "Cancel".
- **Windows status**: **PARTIAL**. `SettingsViewModel.BuildUbuntuBaseAsync`
  (`SettingsViewModel.cs:123-147`) drives `BakeOverlay.RunCommand`,
  which is the QEMU+Alpine legacy baker (see comment block); the
  in-process HCS bake driver is reachable via the welcome flow
  (`ShellViewModel.cs:564-616`) but not via an explicit "Rebuild"
  Settings command. There is no confirmation alert with the macOS
  copy explaining the per-profile drift-prompt follow-up; the
  current Settings command runs the legacy QEMU path unconditionally
  if BakeOverlay is wired.

### 0.6 Mid-rebuild cancel confirmation

- **macOS source**: `BromureAC.swift:833-853`. While a rebuild is in
  flight and the user closes the setup window, NSAlert: "Cancel
  base-image rebuild?" / "The image will be left in an incomplete
  state. You'll need to re-run the rebuild before launching new
  sessions." Buttons: "Cancel rebuild" / "Keep building".
- **Windows status**: **MISSING**. `ShellViewModel.Cancel()` at
  `:619-627` silently cancels the bake CTS — no warning, no
  consequence summary.

---

## 1. UbuntuImageManager parity

### 1.1 Source URL + checksum verification of bootstrap installer

- **macOS source**: `UbuntuImageManager.swift:230-281` —
  Alpine netboot tarball + matching `.sha256` from
  `dl-cdn.alpinelinux.org`, 64-hex-char SHA-256 check, atomic move,
  fallback delete on mismatch.
- **Windows status**: **OK** for the Alpine ISO download path
  (`ImageManager.cs:107-186` does SHA-256 verify via
  `ImageDescriptor.ExpectedSha256` pinned in `AlpineVirt`).
  `VmBaker.EnsureAlpineIsoAsync` (`VmBaker.cs:591-630`) does **not**
  verify SHA-256 — it trusts the URL's TLS chain. Lighter than the
  macOS path; acceptable but worth flagging.

### 1.2 Multi-step staged build with atomic promotion

- **macOS source**: `UbuntuImageManager.swift:157-225` — partial paths
  (`base.img.partial`, `efivars.partial`), Alpine netboot → install
  on raw disk → EFI vars → atomic rename of all three live files +
  write version stamp. On failure, partial scratch is always
  removed; if there was no prior working image, the live files are
  wiped to avoid the next launch satisfying `hasBaseImage` with
  fragments.
- **Windows status**: **PARTIAL**. `VmBaker.cs:142-289` does
  `bake-stage-<id>/` staging directory, `MoveWithRetry` (handles
  vmwp.exe holding handles), and reaping of orphan VMs.
  **No version stamp written.** No equivalent of the "is the
  prior image complete?" snapshot for failure cleanup — the legacy
  path on bake-failure with no prior image leaves `bromure-base.vhdx`
  potentially present (the move-target). Less paranoid than macOS.

### 1.3 Memory + CPU for installer

- **macOS source**: `UbuntuImageManager.swift:54-55`: `installerCPUs=4`,
  `installerMemoryBytes=4 GB`.
- **Windows status**: **OK** — `VmBaker.cs:533-535` `New-VM
  -MemoryStartupBytes 4GB`, `Set-VMProcessor -Count 4`.

### 1.4 Network MTU clamp during install

- **macOS source**: `UbuntuImageManager.swift:421-427` — installer
  reads `VMConfig.resolvedNICMTU()` and clamps the in-installer
  interface to that MTU before any download (VPN-friendly).
- **Windows status**: **MISSING**. `VmBaker.DriveAlpineAsync` brings
  up static IP on a NetNat subnet but doesn't clamp MTU. With
  GlobalProtect / Cisco AnyConnect on the host's physical link, the
  bake `apt-get install` can blackhole mid-download with no error
  message — exactly the failure mode the macOS clamp prevents.

### 1.5 Display scale → kitty font scaling

- **macOS source**: `UbuntuImageManager.swift:551-557` reads
  `NSScreen.main.backingScaleFactor` and passes it to setup.sh.
- **Windows status**: **PARTIAL**. `VmBaker.cs:372-377` hard-codes
  scale = 2: "Display scale = 2: matches macOS retina, matches our
  Xvnc -geometry 2560x1600 default". Per-host high-DPI detection is
  comment'd as "Lower-DPI users get a downscale via WPF (slightly
  fuzzier but readable)". Quality regression on 1×/non-retina
  Windows machines.

### 1.6 Macos system + user font shares to installer (cosmetic parity)

- **macOS source**: `UbuntuImageManager.swift:333-349`. Mounts
  `/System/Library/Fonts` + `/Library/Fonts` via virtiofs read-only
  so the installer can `cp -a` them into the VM. End state: kitty
  inside the VM renders with the same fonts the user has on macOS.
- **Windows status**: **MISSING**. No Windows-fonts share during
  bake. The VM ships with whatever Ubuntu/noble's apt installs.

### 1.7 Idempotent skip + force flag

- **macOS source**: `UbuntuImageManager.swift:128-143`. `force=true`
  rebuilds into partials even when `hasBaseImage && !needsUpdate`.
- **Windows status**: **PARTIAL** — `VmBaker.BakeAsync` is always a
  full rebake; there's no `if cached, return` short-circuit (caller
  is expected to check artefacts via `BakeArtefacts.AllExist()`).
  Conceptually equivalent given the orchestration; functionally OK.

### 1.8 Installer console log (host stderr + caller callback)

- **macOS source**: `UbuntuImageManager.swift:373-388` tees guest
  serial bytes to host stderr + an in-memory `ConsoleBuffer` + the
  caller's `output` callback (drives the GUI install-console view).
- **Windows status**: **OK** — `VmBaker.cs:222-235` plus
  `NamedPipeSerialDriver` (referenced; not read here) tees console
  bytes into `console.log` + the BakeProgress stream, with the
  ShellViewModel's `Progress.AppendLog` path forwarding to the UI.

### 1.9 Hard timeout

- **macOS source**: `UbuntuImageManager.swift:399-402,464` —
  45-minute ceiling raced against the driver.
- **Windows status**: **OK** — `VmBaker.BakeTimeout = 45 min`
  (`VmBaker.cs:76`).

### 1.10 Force-stop the installer if poweroff hangs

- **macOS source**: `UbuntuImageManager.swift:447-457` — 30-second
  grace; force-stops if Alpine OpenRC takes longer.
- **Windows status**: **PARTIAL**. `VmBaker.WaitForVmStoppedAsync`
  (`VmBaker.cs:561-589`) polls `Get-VM` state with a 2-minute
  timeout. On timeout, throws — the `finally` block at `:267-286`
  then issues `Stop-VM -TurnOff -Force` + `Remove-VM`. Same end
  state but the macOS path differentiates "took >30s, will progress
  reports tell the user" — Windows logs at "Waiting for VM
  power-off…" and then either succeeds or throws "did not power off"
  with no in-progress status.

---

## 2. UbuntuSandboxVM parity (per-session VM)

### 2.1 RAM size per profile

- **macOS source**: `UbuntuSandboxVM.swift:96-98` — `memGB = sessionDisk?.profile.memoryGB ?? 8`.
- **Windows status**: **MISSING**. `HcsSessionConfig.MemoryMB`
  defaults to 2048 (`HcsSession.cs:732`), `HcsVmConfig.MemoryMB`
  defaults to 2048 (`HcsVm.cs:356`). `SessionViewModel.StartAsync`
  doesn't read profile memory at all when building
  `HcsSessionConfig`. Profile lacks a `MemoryGB` field (see audit
  01-profile-model.md).

### 2.2 CPU count

- **macOS source**: `UbuntuSandboxVM.swift:60-61` — `runtimeCPUs=4`.
- **Windows status**: **OK** — `HcsVmConfig.CpuCount=4` default,
  matches.

### 2.3 Networking: NAT vs. Bridged with fallback

- **macOS source**: `UbuntuSandboxVM.swift:118-134` — reads
  `profile.networkMode` (`.nat` / `.bridged`). Bridged falls back to
  NAT when the chosen `bridgedInterfaceID` isn't enumerated.
- **Windows status**: **MISSING**. `HcsSessionConfig.UseNetworkAdapter`
  is a bool (defaults true). `NetworkSwitchName` defaults to
  `"Default Switch"`. No profile-driven NAT/Bridged toggle; no
  bridged-interface enumeration.

### 2.4 Per-profile persistent MAC address

- **macOS source**: `UbuntuSandboxVM.swift:140-149` — `MACBindings`
  stores `profileID → MAC` JSON map. Without this, VZ `restoreMachineStateFrom`
  rejects a config whose MAC differs from the saved RAM snapshot's.
- **Windows status**: **MISSING**. `HcsSession.cs:242` generates a
  fresh random MAC per session via `HcnApi.RandomMacAddress()`.
  Hibernate-resume relies on `RestoreState.SavedStateFilePath`
  (`HcsVm.cs:572-577`); the mac will differ across runs. Unclear
  whether HCS validates this — but the macOS save/restore contract
  is broken by the equivalent omission here.

### 2.5 Per-profile persistent machine identifier

- **macOS source**: `UbuntuSandboxVM.swift:474-490`
  `persistentMachineIdentifier(for:)` — loads or mints + persists a
  `VZGenericMachineIdentifier` into `machine-identifier.bin`. Without
  this, every `prepare()` gets a fresh ID and `restoreMachineStateFrom`
  fails with VZ Code 12.
- **Windows status**: **MISSING**. HCS picks the compute system
  RuntimeId per-create — no per-profile persistence. Suspend/resume
  on Windows uses `SavedStateFilePath` which encodes its own VM
  identity, so the failure mode differs, but the equivalent
  per-profile machine-identity concept is absent.

### 2.6 Graphics + input devices

- **macOS source**: `UbuntuSandboxVM.swift:154-159` — virtio-gpu
  with a 1920×1200 scanout, USB keyboard, USB pointing device.
- **Windows status**: **DIFFERENT**. No virtual GPU device — the
  display is rendered by **weston-rdp / Xvnc** inside the guest and
  surfaced to the host via VNC over a TCP socket on the guest's NAT
  IP (or, fallback, via mstsc reparenting in `HcsSessionWindowHost.cs`
  — currently unused). Keyboard/mouse events flow through the RFB
  message stream, not via emulated USB HID.

### 2.7 Spice agent / shared clipboard

- **macOS source**: `UbuntuSandboxVM.swift:179-186` — `VZSpiceAgentPortAttachment`
  with `sharesClipboard = true`. VZ syncs NSPasteboard ↔ guest
  selection automatically.
- **Windows status**: **DIFFERENT**. Implemented via RFB
  `ServerCutText` / `ClientCutText` in `VncControl.cs:89-107,194-220`.
  Host-side `System.Windows.Clipboard.SetText`/`GetText` on focus
  events. Behavior approximates macOS but: (a) text-only (Spice on
  macOS is also text-typically but is a richer pipe), (b) "push on
  focus" cadence — host changes while the VM has focus aren't
  reflected until the user re-focuses (the comment at
  `VncControl.cs:89-94` acknowledges this).

### 2.8 Outbox poll (URL relay, tab roster, IP, tab titles)

- **macOS source**: `UbuntuSandboxVM.swift:352-433`. Polls
  `outboxDirectory` every 500 ms for:
  - `ip.txt` (rewritten every 5s, drives `onIPUpdate`)
  - `url-*.txt` (URL open relay → `NSWorkspace.shared.open`)
  - `title-<uuid>.txt` (per-tab foreground process)
  - `tabs-alive.txt` (per-tick UUID roster, drives reconciliation)
  - `closed-<uuid>.txt` (tab exit notification)
- **Windows status**: **PARTIAL/DIFFERENT**. Equivalent functions
  are split across `GuestEventServer.cs` (per-tab title push over
  AF_HYPERV port 9224, overlay-fetch on 9225) and the missing pieces:
  - Per-tab title: **OK** (`GuestEventServer.SubscribeTab`).
  - URL open relay: **MISSING**. No `url-*.txt` listener.
  - VM IP report: **MISSING** as a guest-driven channel.
    `HcsSession.GuestIpAddress` is set once at boot from the host's
    ARP cache (`HcsSession.cs:620-665`) — not a 5-second refresh.
  - `tabs-alive.txt` reconciliation: **MISSING**. The Windows tab
    strip has no orphan-pill reaper; if a kitty dies silently inside
    the VM, the pill stays until the user closes it.
  - `closed-<uuid>.txt`: **MISSING**. There is no guest→host channel
    that fires when a kitty exits.

### 2.9 Resume timekeeping fix

- **macOS source**: `UbuntuSandboxVM.swift:296-303`. On restore,
  touches `.resume-signal` in the meta share — the guest's systemd
  `bromure-resume.path` unit fires `rdate -n -s pool.ntp.org` to
  fix clock skew.
- **Windows status**: **MISSING**. `HcsSession.cs` resume path
  (`:144-167,314-318`) doesn't push any resume marker; clock skew
  after a long suspend will likely show in journal timestamps.

---

## 3. SessionDisk parity (per-profile state)

### 3.1 CoW clone of the base disk

- **macOS source**: `SessionDisk.swift:266-282` — `clonefile()` (APFS
  CoW); falls back to `copyItem` on non-APFS.
- **Windows status**: **OK**. `VhdxDisk.CreateChildAsync`
  (`VhdxDisk.cs:49-136`) creates a VHDX differencing child via
  `VirtDiskApi.CreateVirtualDisk` with the parent path. The
  comment at `VhdxDisk.cs:13-19` calls this "the actual macOS-APFS-CoW
  analogue" — accurate.

### 3.2 Track "cloned-this-launch" to stamp the profile

- **macOS source**: `SessionDisk.swift:231` `didCloneOnLastEnsure` +
  `BromureAC.swift:2357-2363` writes `baseImageVersionAtClone` only
  when the flag is set.
- **Windows status**: **MISSING** — see 0.2/0.3. `VhdxDisk` always
  silently rebuilds on parent-mtime drift.

### 3.3 Compromise marker + wipe

- **macOS source**: `SessionDisk.swift:104-154`. `compromised.flag`
  file in the profile dir; `isCompromised`, `markCompromised`,
  `clearCompromised`, and `wipeForCompromise()` (wipes disk + home +
  vm.state + tabs + meta + outbox; preserves profile.json + ssh).
  Static lookup `isCompromised(profile:store:)` for picker badging.
- **Windows status**: **MISSING**. Audit 03-token-swap.md notes the
  compromise-detector wiring exists in `Bromure.AC.Mitm.Swap.CompromiseDetector`,
  but there is no per-profile `compromised.flag`, no boot-time
  refusal, no wipe path, no picker badge.

### 3.4 Saved RAM state file (suspend/resume)

- **macOS source**: `SessionDisk.swift:95-100` — `vm.state` lives in
  the profile dir; `hasSavedState` checks existence. Drop on full
  shutdown via `clearSavedState()` (also drops `tabs.json`).
- **Windows status**: **OK**. `HcsSession.SavedStateFilePath` +
  `SessionViewModel.SaveStateAsync` writes `saved-state.bin` to
  `_sessionRoot`. Tabs.json is written/cleared in lockstep
  (`SessionWindow.xaml.cs:81-147`). `HcsSession.cs:144-167` also
  invalidates a stale save when the parent VHDX is newer — good.

### 3.5 Tab snapshot persistence

- **macOS source**: `SessionDisk.swift:161-196`. `TabsState` /
  `TabSnapshot` Codable, JSON write/read at `tabs.json`. Stale tab
  state without matching `vm.state` is documented as not consumed.
- **Windows status**: **OK**. `TabRoster` / `TabRosterEntry` in
  `SessionWindow.xaml.cs:550-559`. JSON write on hibernate
  (`:108-135`); restore at `:201-221`. The "spawn-kitty on cold
  boot vs. don't spawn on resume" logic at `:185-199` mirrors the
  macOS distinction.

### 3.6 Shared folders → guest mount mapping with de-duplication

- **macOS source**: `SessionDisk.swift:236-260`. Caps at 8 folders to
  match the base image's pre-allocated fstab slots; de-dups
  basenames ("src" + "src" → "src" + "src-2"). Writes `shares.txt`
  for xinitrc to consume.
- **Windows status**: **PARTIAL**. `HcsSession.cs:212-219` iterates
  `_cfg.SharedFolderPaths`, uses `SafeBasename` for the share tag,
  de-dups via `seenShareTags`. **No 8-share cap** (any number of
  shares are attached); **no `shares.txt`** equivalent — the guest
  mounts via the bromure-overlay-apply systemd unit reading 9p
  metadata, not the shares.txt convention. Functional parity but
  guest setup is divergent.

### 3.7 Metadata share: api_key.env + proxy.env + ssh keys + tons of small files

- **macOS source**: `SessionDisk.swift:302-635`. Massive — assembles
  `api_key.env` (with fake tokens via `tokenPlan`), `proxy.env`
  (HTTPS_PROXY + per-language CA bundle envs), CA cert, the
  bridge.py script + keyboard/scroll/aws-creds/claude-token/
  codex-token/shell agent scripts, ssh keys, welcome.txt,
  shares.txt, hostname.txt, display_scale.txt, tz, mtu,
  natural_scroll, key_repeat, mcp/claude.json, mcp/codex.toml.
  forRestore=false wipes the share; forRestore=true preserves the
  directory inode.
- **Windows status**: **PARTIAL**. `SessionHomeBuilder` is referenced
  from `SessionViewModel.cs:225-227` but is part of `Bromure.AC.Core`
  (not the SandboxEngine). 9p shares stage `homeFiles` directly into
  `/home/bromure/` via the overlay-apply guest unit. From audit-3
  (token-swap) we have the proxy env vars set in `SessionViewModel.cs:191-196`.
  **Missing:**
  - hostname.txt
  - display_scale.txt (hardcoded 2 in bake; see 1.5)
  - tz (host timezone)
  - mtu (no clamp)
  - natural_scroll
  - key_repeat (delay/rate from host)
  - keyboard/scroll/AWS/claude-token/codex-token/shell agent scripts
  - resume-signal mechanism
  - forRestore inode preservation logic (the 9p share is per-session,
    so the failure mode the macOS comment describes — "guest's
    in-flight kitty wrapper subshell stops seeing the host's writes"
    — doesn't apply the same way; nonetheless, no documented design
    for resume-time share preservation)

### 3.8 Outbox writable dir (mode 0777)

- **macOS source**: `SessionDisk.swift:818-838`. World-writable so the
  guest's `ubuntu` user can write (host UID 501 ↔ guest UID 1000).
- **Windows status**: **DIFFERENT**. The "outbox" concept is folded
  into the overlay share (`HcsSession.cs:211` —
  `OutboxDirectory = overlayDir`). Writes from the guest land here
  via 9p. No explicit world-writable POSIX flag (9p server handles
  UID mapping differently than virtiofs).

### 3.9 Welcome message

- **macOS source**: `SessionDisk.swift:840-890`. Multi-tool listing,
  shared folders, git HTTPS hosts, manual fakes, per-tool getting-started.
- **Windows status**: **MISSING**. No welcome.txt or equivalent
  intro printed at first session login.

---

## 4. SessionWindow parity (the chrome)

### 4.1 Custom title bar with tabs in caption + window controls

- **macOS source**: `SessionWindow.swift:217-243`. Uses
  `NSToolbar.style = .unified` and a `TabsToolbarDelegate` that
  renders a SwiftUI capsule-tabs bar. Tab list, "+" button, IP chip,
  shared-folders popover, reboot, trace inspector, streaming
  indicator.
- **Windows status**: **PARTIAL**. `SessionWindow.xaml` uses
  `WindowChrome` with `CaptionHeight=38`, tab strip + "+" button in
  the caption area, custom min/max/close buttons. **Missing toolbar
  items**:
  - IP chip / click-to-copy
  - Streaming indicator (red dot when enrolled + non-private)
  - Shared folders popover (button + popover listing host paths,
    click to open in Explorer)
  - Reboot button (with soft/hard confirmation dialog)
  - Trace inspector button
  - Profile color accent on the active tab outline — Windows uses
    a 2-px underline (`SessionWindow.xaml.cs:451-456`) which is OK
    but doesn't match the macOS capsule.

### 4.2 Window opacity per profile

- **macOS source**: `SessionWindow.swift:210-216,265-280`. Reads
  `profile.windowOpacity`, applies to the container layer.
- **Windows status**: **MISSING**. No opacity field on the Profile
  model (see audit 01); window is always opaque.

### 4.3 Live profile updates without restart

- **macOS source**: `SessionWindow.swift:253-280` `applyLiveProfileUpdates`.
  Re-binds title, accent, opacity in-flight.
- **Windows status**: **MISSING**. No equivalent on `SessionWindow`.

### 4.4 ⌘T / ⌘W / ⌘1-9 keyboard shortcuts

- **macOS source**: `SessionWindow.swift:415-455`. Handles via
  `sendEvent` + `performKeyEquivalent` to win the race against the
  VZ view's keyDown forwarding.
- **Windows status**: **PARTIAL**. `SessionWindow.xaml.cs:48-53`
  registers Ctrl+T / Ctrl+W via `InputBindings`. **Ctrl+1..9 missing**.
  The "win before the VNC control captures input" concern is
  architecturally different (RFB is dialed by VncControl), but
  there's no documented test of the race.

### 4.5 Suspended/investigation red tint overlay

- **macOS source**: `SessionWindow.swift:76-89,245-251`. Red 35% alpha
  view over the framebuffer; toggled by the compromise handler when
  the VM is paused mid-leak.
- **Windows status**: **MISSING**.

### 4.6 Animation behaviour `none` (crash workaround)

- **macOS source**: `SessionWindow.swift:201`. Defended via long
  comment about `_NSWindowTransformAnimation` autorelease over-release.
- **Windows status**: **N/A** (different framework; WPF doesn't have
  the equivalent crash).

### 4.7 Tab close → empty → window close → shutdown vs. suspend

- **macOS source**: `SessionWindow.swift:337-378`. Last-tab cascade
  forces `pendingCloseAction = .shutdown` regardless of profile
  closeAction (suspending an empty X session is wasteful).
- **Windows status**: **OK**. `SessionWindow.xaml.cs:255-278`
  `_lastTabCascade = true` → `Close()` → `OnClosing` routes to
  `ShutdownAsync` instead of `SaveStateAsync`. Behavior parity.

### 4.8 Tab roster reconciliation against guest "alive" report

- **macOS source**: `SessionWindow.swift:380-405`
  `reconcileTabRoster(alive:)` with grace window protecting freshly
  appended pills.
- **Windows status**: **MISSING** — see 2.8.

### 4.9 Tab placeholder when 0 sessions (no VM-running content)

- **Windows status**: When VNC has no host endpoint, a fallback
  `TextBlock` "VM is running but no display transport is available."
  is shown (`SessionWindow.xaml.cs:316-326`). macOS doesn't need
  this — VZ always has a framebuffer; the divergence reflects
  Windows' indirect display.

### 4.10 Drag-and-drop

- **macOS source**: VZVirtualMachineView handles drag-and-drop into
  the guest natively (not explicitly opt-in here but implied).
- **Windows status**: **MISSING**. `VncControl` has no DragOver /
  Drop handler. Files dropped on the window don't propagate.

### 4.11 Dock badge / taskbar overlay

- **macOS source**: Not explicit in SessionWindow.swift but the
  AC delegate uses `NSApp.activate` and standard dock-icon behavior.
- **Windows status**: **MISSING**. No `TaskbarItemInfo` /
  `OverlayIcon` for session count / streaming indicator.

### 4.12 App menu integration

- **macOS source**: `BromureAC.swift:159-163` — "Rebuild Base Image…"
  in the app menu, plus the standard NSApplication menu shape.
- **Windows status**: **MISSING**. WPF main menu in the shell
  doesn't expose rebuild / preferences via menu bar (it's in
  Settings tabs).

---

## 5. VM lifecycle hooks

### 5.1 Pre-boot prepare

- **macOS source**: `UbuntuSandboxVM.prepare()` (`:79-249`) — builds
  full `VZVirtualMachineConfiguration` synchronously before any
  start.
- **Windows status**: **OK** with split. `HcsVm.CreateAsync` builds
  the schema + creates the compute system but doesn't start. Same
  shape; HCS calls it "Create".

### 5.2 Post-boot

- **macOS source**: No explicit hook, but `startOutboxPolling()` runs
  immediately after `vm.start()` (`UbuntuSandboxVM:251-257`).
- **Windows status**: **PARTIAL**. `HcsSession.WaitForBootSignalAsync`
  (`:456-510`) waits for the in-guest hvsock listener to accept;
  `SessionViewModel.StartAsync` subscribes to title events after.
  Approximate parity.

### 5.3 Suspend

- **macOS source**: `UbuntuSandboxVM.suspend()` (`:310-326`). Pause
  → remove prior save → `saveMachineStateTo` → mark stopped. Plus
  `saveAlreadyPausedState()` for the compromise path where the VM
  is already paused.
- **Windows status**: **PARTIAL**. `HcsVm.SaveSync` (`HcsVm.cs:173-216`)
  pauses then saves to file. Equivalent of `saveAlreadyPausedState`
  is missing — the comment in `SaveSync` says "HCS rejects Save
  directly from Running" so it always pauses first; there's no
  separate "save without pausing again" entry. Since there's no
  Windows compromise detector that pauses first, this is moot for
  now but will be needed when 3.3 lands.

### 5.4 Resume

- **macOS source**: `UbuntuSandboxVM.restore()` (`:282-304`) —
  `restoreMachineStateFrom` → `resume` → resume signal.
- **Windows status**: **PARTIAL**. `HcsVm.ResumeAsync`
  (`HcsVm.cs:221-236`) + `HcsSession.StartAsync` with `resumeFromState`
  branch (`HcsSession.cs:144-167,314-326`). **Missing**: resume
  signal / time-sync trigger (see 2.9).

### 5.5 Shutdown (clean poweroff vs. force)

- **macOS source**: Implicit via delegate `guestDidStop` cleanup
  (`UbuntuSandboxVM:452-460`).
- **Windows status**: **OK**. `HcsVm.TerminateAsync` for hard stop,
  `HcsVm.DestroyAsync` for terminate + close handle + revoke ACL.

### 5.6 Force kill (for stuck VMs)

- **macOS source**: `vm.stop(completionHandler:)`.
- **Windows status**: **OK** — `HcsVm.TerminateAsync` is the
  hard-stop primitive (no graceful shutdown attempt).

### 5.7 MAC pool release on stop

- **macOS source**: `UbuntuSandboxVM.releaseMACToPool` (`:462-467`).
- **Windows status**: **N/A** — Windows uses HCN endpoints with
  random MACs, no pool. But see 2.4 — a per-profile fixed MAC is
  still missing.

---

## 6. VM Pool / Warm pre-creation

### 6.1 Pre-create one VM ahead

- **macOS source**: VMPool.swift (referenced by header comment in
  `WarmVmPool.cs:1`) — same channel pattern, "one warm VM at a
  time" model.
- **Windows status**: **OK**. `WarmVmPool.cs` implements
  bounded(1) channel, top-loop, `AcquireAsync` with timeout,
  orphan cleanup at startup. `SessionRowViewModel.LaunchAsync`
  (`SessionsViewModel.cs:236-272`) acquires with a 250 ms timeout
  and falls back to a cold create. Direct parity with macOS.

### 6.2 Cold-start vs. warm-start timing

- **macOS source**: Not measured in source but the comment in
  WarmVmPool says "sub-second cold start".
- **Windows status**: Not measured in source. The phase log in
  `HcsSession.cs:114-118` captures it as `Phase("vhdx-clone", ...)`
  etc. — measurement infrastructure exists.

### 6.3 Auto-suspend on idle

- **macOS source**: Not found in SessionWindow/UbuntuSandboxVM. The
  user-driven "X clicked" → suspend path exists; idle-detected
  suspend doesn't.
- **Windows status**: **MISSING** (matches macOS).

---

## 7. Container/distro update flow (rebake-and-migrate UX)

### 7.1 Per-profile migration prompt at next launch

- See 0.3 in detail. This is the central missing flow.

### 7.2 Notification at app launch when image is stale

- See 0.4. Missing.

### 7.3 "Rebuild" Settings command with confirmation

- See 0.5. Partial — exists but the legacy QEMU+Alpine path is the
  one wired into Settings; the in-process HCS bake driver is only
  reachable through the welcome (cold-start) flow.

---

## 8. Composition with HCS pivot status

The Windows port is **IN-PROGRESS** on the HCS pivot itself (the
`memory/bromure_windows_hcs_pivot.md` thread is the active
direction). Items that block the alert flow:

1. **`base.version` stamp file**: needs to be a first-class artefact
   of `VmBaker.MoveArtefacts` (alongside `bromure-base.vhdx`,
   `vmlinuz`, `initrd.img`). One-line constant + one-line write.
2. **`BakeArtefacts.Version`**: extend the record so consumers can
   read the current version without re-opening the stamp file.
3. **`Profile.BaseImageVersionAtClone`**: cross-listed in audit
   01-profile-model.md as a profile-schema gap. The migration UI
   can't work without it.
4. **`SessionsViewModel.LaunchAsync`**: insert the version-comparison
   block before `await sv.StartAsync()`. Three-button MessageBox with
   the same copy as the macOS NSAlert. "Reset" → delete the child
   VHDX (which `VhdxDisk.CreateChildAsync` will then re-clone);
   "Launch as-is" → set a flag that suppresses the
   `VhdxDisk.cs:65-72` parent-mtime force-rebuild for this launch.
5. **`VhdxDisk.CreateChildSync`**: change the parent-mtime check so
   it only deletes the child when the caller explicitly opts in
   (currently silent). This is the single biggest behavioral fix.

---

## Tally

- **MISSING**: 24
  - Image versioning alert (3-button reset/launch/cancel) — #1
  - Non-blocking stale-image nag
  - Per-profile `baseImageVersionAtClone` stamp + comparison
  - macOS-style "rebuild" menu/Settings action with confirm copy
  - Mid-rebuild cancel confirmation
  - MTU clamp during bake
  - Host fonts shared into installer (cosmetic)
  - Profile-driven RAM size
  - Profile-driven NAT/Bridged network mode
  - Per-profile persistent MAC
  - Per-profile machine identifier
  - URL open relay outbox listener
  - 5-second IP refresh push
  - `tabs-alive.txt` reconciliation
  - `closed-<uuid>.txt` exit signal
  - Resume-signal clock skew fix
  - Compromise flag, wipe, picker badge
  - hostname.txt / display_scale.txt / tz / mtu /
    natural_scroll / key_repeat / agent scripts in meta share
  - Welcome.txt
  - Window opacity from profile
  - Live profile updates without restart
  - Ctrl+1..9 tab-switch shortcuts
  - Suspended/investigation red tint overlay
  - Drag-and-drop into the guest
  - Taskbar overlay / dock badge
  - Toolbar items: IP chip, streaming indicator, shared-folders
    popover, reboot button, trace inspector button
- **PARTIAL**: 8 (staged build promotion, "Rebuild" Settings
  command, image manager checksum on bake, force-stop poweroff,
  prepareMetadataShare contents, post-boot wait, shared-folder cap,
  resume save logic)
- **DIFFERENT**: 4 (display backend RDP/VNC vs. VZ scanout, clipboard
  via RFB, outbox dir model, share staging vs. virtiofs)
- **OK**: 8 (CoW clone, saved-state file, tab snapshot persistence,
  warm pool, installer CPU/memory, idempotent skip, installer
  console log, hard timeout, shutdown destroy)
- **IN-PROGRESS**: HCS pivot itself
