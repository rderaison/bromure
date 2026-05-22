# Parity audit 08 — App shell, state machine, Sessions / Welcome / Initialization / Settings

Scope: macOS `Sources/AgentCoding/BromureAC.swift` (3492 LOC) + `SetupViews.swift` + `EnrollmentSheet.swift` versus the Windows WPF shell.

Severity legend: **CRITICAL** (security/safety/data-loss), **HIGH** (feature absent that users rely on daily), **MEDIUM** (UX gap, but workaround exists), **LOW** (cosmetic / nice-to-have).

---

## 1. App lifecycle

### 1.1 CLI subcommand entry point
- **Feature**: `bromure-ac` is a `ParsableCommand` with `init`, `run`, `reset`, `mcp`, `enroll`, `unenroll`, `status` subcommands; default subcommand is `Run` (so double-click opens GUI, but headless `bromure-ac init` works).
- **macOS source**: BromureAC.swift:25-95, 3452-3475 (Reset), 56-95 (Init)
- **Windows status**: MISSING
- **Detail**: Windows has only a WPF `Application` with `StartupUri="Views/MainWindow.xaml"` (App.xaml:5). No CLI surface — no headless `init`, no `reset`, no `status`, no `enroll`/`unenroll` from terminal. Severity: **HIGH** (admin / CI workflows broken — e2e harness can drive via automation HTTP but humans cannot bake from a script).

### 1.2 Apple-internal flag stripping (`-AppleLanguages` etc.)
- **macOS source**: BromureAC.swift:41-51
- **Windows status**: N/A (Windows doesn't have this convention).

### 1.3 Single-instance enforcement
- **macOS source**: implicit via NSApplication (one process per .app launch).
- **Windows status**: MISSING. WPF App.OnStartup (App.xaml.cs:16-31) does nothing to prevent two `Bromure.AC.exe` from running side-by-side. Severity: **HIGH** — two processes will both bind the automation port (collision logged but tolerated, ShellViewModel.cs:339) and both will race the per-profile VHDX clone path (no file lock around `disk.vhdx` creation), risking corruption.

### 1.4 URL scheme / custom protocol handling
- **macOS**: Not implemented on either side, but the app is single-bundle-id `io.bromure.app` so registration would be trivial.
- **Windows status**: MISSING. No `URLAssociations` in `app.manifest`.

### 1.5 Login items / launch-on-startup
- **macOS**: Not implemented on either side.

### 1.6 Dock badge / status item / system tray
- **macOS source**: Activation policy `.regular` (BromureAC.swift:119). No dock badge customisation, no menu-bar status item.
- **Windows status**: OK — no tray icon on either side. Same baseline.

### 1.7 Exit-on-last-window
- **macOS source**: BromureAC.swift:793-798 — `applicationShouldTerminateAfterLastWindowClosed` returns `false`; the app stays alive until literally every window (picker + sessions + inspector) is gone. Closing one window doesn't quit.
- **Windows status**: DIFFERENT. WPF's default `ShutdownMode` is `OnLastWindowClose`. App.xaml does not override it, so closing the MainWindow terminates the process even if SessionWindow tabs are open. Severity: **HIGH** — losing a running VM unexpectedly because the user closed the picker.

### 1.8 Quit confirmation when VMs running
- **macOS source**: BromureAC.swift:802-820 — `applicationShouldTerminate` enumerates running VMs and prompts "Quit Bromure Agentic Coding? %d VM(s) currently running (%@) will shut down…".
- **Windows status**: MISSING. MainWindow.xaml.cs:14-21 disposes the (single) `ShellViewModel.Session` on `OnClosed`, but no confirmation, no enumeration of running sessions, no per-VM shutdown protocol. Severity: **HIGH** — silent termination of VMs.

### 1.9 Per-window close confirmation (`windowShouldClose`)
- **macOS source**: BromureAC.swift:832-929. Branches on `profile.closeAction` (`.suspend` / `.shutdown` / `.ask`) with two/three-button alerts. The `.ask` chooser offers "Suspend / Shut down / Cancel" with a detailed explanation.
- **Windows status**: MISSING. No close-action profile setting honoured at the View layer — `SessionViewModel.ShutdownAsync` always terminates, never suspends from the close button. `SaveStateAsync` exists (SessionViewModel.cs:380) but only `SessionWindow.xaml.cs` would route to it (not in this audit's read set; verified the model surface).  Severity: **HIGH** — suspend-by-default is the macOS UX promise.

### 1.10 Cancel rebuild confirmation
- **macOS source**: BromureAC.swift:840-861 — closing the main window during an in-flight base-image rebuild pops "Cancel base-image rebuild? Keep building / Cancel rebuild", and on confirm cancels the Task and renders back to picker/setup without closing the window.
- **Windows status**: MISSING. `ShellViewModel.StartAsync` exposes `_bakeCts` and `Cancel` (ShellViewModel.cs:619-627) but no window-close hook calls it; closing MainWindow during bake silently drops the task. Severity: **MEDIUM**.

### 1.11 Clean up on terminate (private ssh-agent)
- **macOS source**: BromureAC.swift:822-827 — `applicationWillTerminate` calls `mitmEngine?.privateAgent.terminate()`.
- **Windows status**: PARTIAL. App.OnExit (App.xaml.cs:33-37) saves settings but does not stop the automation server, MITM engine, or any leftover bromure-ses-* compute systems. Cleanup happens on next startup (`CleanupOrphanedVmsAsync`, ShellViewModel.cs:469-480). Severity: **MEDIUM**.

---

## 2. State machine

### 2.1 macOS implicit states (rendered by which contentView)
The Swift app does not declare an enum — state lives in:
- `imageManager.hasBaseImage` → renderSetup vs renderPicker (BromureAC.swift:579-591)
- `installTask != nil` → InitializingView (BromureAC.swift:1065-1124)
- `profileWindows[id]` populated → TabbedSessionWindow up
- `compromiseAlertActive` → modal alert state
- `BACEnrollmentStore.load() != nil` → enrolled / not-enrolled menu/UI variant
- `imageManager.baseImageNeedsUpdate` → soft nag alert on launch

Transitions:
- launch → renderSetup (no image) | renderPicker (image) | promptBaseImageUpdate (stale image)
- SetupView "Get Started" → startInit() → renderInitializing → on success renderPicker (resize) → openEditor if no profiles
- Rebuild Base Image… menu → confirm → startInit(force: true)
- mid-rebuild close → confirm → cancel + renderSetup/renderPicker
- profile launch → launch() → TabbedSessionWindow on top of main
- compromise event → pause VM → modal alert → shutdown / save / continue
- VM stopped (rebootRequested) → relaunchVM in place

### 2.2 Windows explicit `ShellPhase` enum
- **Windows status**: PARTIAL. `ShellPhase { Welcome, Initializing, Session }` (ShellViewModel.cs:19-24).
- **Detail**: Only three top-level phases. Missing equivalents for:
  - Compromise pause/modal (no CompromiseHandler wired — see audit 03/05).
  - Drift detection (no `baseImageVersionAtClone` diff prompt). macOS BromureAC.swift:2020-2041 prompts "Reset and launch / Launch as-is / Cancel" when the recorded base version != current. Severity: **HIGH**.
  - Compromised-profile boot refusal (`SessionDisk.isCompromised` gate). macOS BromureAC.swift:2011-2017 + confirmWipeAndProceed (2499-2554). Severity: **CRITICAL** — a compromised profile re-launches unimpeded on Windows.
  - Stale-image launch nag (`promptBaseImageUpdate`). macOS BromureAC.swift:1417-1431. Severity: **MEDIUM**.
  - Mid-bake cancellation prompt (see 1.10).

---

## 3. Pre-warm pool

### 3.1 macOS
- **Feature**: NO VM pool. macOS AC creates the VM cold on every launch (verified — no `VMPool`/`warmPool` references in `Sources/AgentCoding/`).
- **macOS source**: launch() in BromureAC.swift:1997-2388 does `UbuntuSandboxVM(...).prepare(); start()` directly.

### 3.2 Windows
- **Windows status**: DIFFERENT (less ambitious, by design). ShellViewModel.cs:49-53 + 142-143: explicitly `warmPoolProvider: () => null`. Comments say "No warm pool for AC — sessions cold-create on demand (sub-second on modern hardware, vs. the warm pool's habit of leaking child VHDXs that lock the parent)." Also reaps orphan warm-pool entries at startup (ShellViewModel.cs:469-480) in case earlier builds left some.
- **Detail**: Parity OK (both cold-start). The Windows code still carries plumbing (`WarmVm? warm`, SessionRowViewModel.cs:215-225, 263-273) that is dead code in this configuration. Severity: **LOW** (dead code cleanup).

---

## 4. Sessions list (profile picker)

### 4.1 macOS columns / fields per row (ProfilePickerView)
- Color dot (`profile.color.swiftUIColor.gradient`)
- Name + green "running" dot + red "compromised" octagon icon (ProfileViews.swift line ~240-247)
- Tool SF symbol + display name subtitle
- Right-side gear (edit) button
- Selected-row detail panel below the list (large "Open Session" button + all-tools / auth-mode / folders / SSH key / memory chips)

### 4.2 Windows columns
- Color dot (Ellipse) — OK
- Name + green running dot — OK
- **MISSING**: red compromised badge (SessionsView.xaml has no equivalent — paired with item 2.2/CRITICAL).
- Subtitle = `Tool · N folders` — PARTIAL (no SF-symbol equivalent; macOS uses Segoe Fluent? No — Windows just uses a TextBlock). Severity: **LOW**.
- Per-row launching ProgressBar — OK (extra polish vs macOS).
- Per-row gear button → Edit — OK.
- **MISSING**: detail panel below list (memory / tool icons / SSH key chip / folder count chips). SessionsView.xaml just shows a flat list. Severity: **MEDIUM**.

### 4.3 Context menu (right-click on row)
- **macOS source**: ProfileViews.swift:104-114 — Launch, Edit…, Duplicate, SSH public key… (when key present), Reset disk (destructive), Delete profile (destructive).
- **Windows status**: MISSING entirely. No `ContextMenu` on the ListBox.ItemTemplate Border. Severity: **HIGH** — Duplicate, Reset disk, SSH public key viewer all unreachable via right-click.

### 4.4 Keyboard shortcuts
- **macOS source**:
  - ⌘T / ⌘W / ⌘1-9 intercepted at app level for session tab management (BromureAC.swift:741-791).
  - ⇧⌘I → Trace Inspector (BromureAC.swift:228-234).
  - ⌘0 → Profile Manager (BromureAC.swift:223-227).
  - ⌘, → Preferences (BromureAC.swift:153-157).
  - ⌘H → Hide.
  - Standard Edit menu: ⌘Z/⇧⌘Z/⌘X/⌘C/⌘V/⌘A (BromureAC.swift:186-210).
- **Windows status**: MISSING all of them. MainWindow.xaml declares no KeyBindings; SessionsView.xaml has no shortcuts; no app-level event monitor. Severity: **HIGH** — Ctrl+T new tab, Ctrl+W close tab, Ctrl+1-9 switch tab, Ctrl+, settings all dead.

### 4.5 Multi-select
- **macOS**: ListView with default single-selection. Same on Windows.
- **Windows status**: OK.

### 4.6 Sort order
- **macOS**: BromureAC.swift uses `profiles` as ordered by `ProfileStore.loadAll()`. No explicit sort.
- **Windows status**: PARTIAL. `ProfilesViewModel.Reload` orders by Name (ProfilesViewModel.cs:74); `SessionsViewModel.Reload` does NOT sort (SessionsViewModel.cs:75 — uses store's natural order). Two different orderings between the Settings / Profiles pane vs the Sessions pane. Severity: **LOW**.

---

## 5. New session flow

### 5.1 macOS flow
- Picker shows existing profiles; click Launch (or detail-panel Open Session) → `launch(profile)` (BromureAC.swift:1997-2388).
- Compromise check (refuse + wipe-or-cancel).
- Drift check (recorded vs current base version → reset disk prompt).
- `store.touch(profile)` + populate MCP tokens + materialize kubeconfig + push token map to MITM engine + ssh-agent + AWS SSO resolve.
- TabbedSessionWindow created → VM prepared → start() → kitty spawned via the tab agent.

### 5.2 Windows flow
- Click row → `SessionRowViewModel.LaunchAsync` (SessionsViewModel.cs:236-322).
- Pulls warm VM if pool present (null in current build).
- `SessionViewModel.StartAsync` (SessionViewModel.cs:134-328): registers MITM proxy → builds env vars → mints MCP fakes → materialises kubeconfig → builds home overlay → starts HCS session → subscribes to guest title → adds tab via `Views.SessionWindow.AddTab`.
- **MISSING**: compromise gate (CRITICAL — see 2.2).
- **MISSING**: drift detection / version-bump prompt (HIGH — see 2.2).
- **MISSING**: SSO resolve loop with refresh task (audit 01 may cover deeper). macOS BromureAC.swift:2127-2175 starts `AWSSSOResolver.startRefreshLoop` per-profile.
- **MISSING**: ssh-agent host-side key load (`addKeyToHostAgent`, BromureAC.swift:3288-3333) — without this, the in-VM ssh client cannot sign through vsock-bridged agent. Severity: **HIGH**.
- **MISSING**: imported-SSH-key load with passphrase via SSH_ASKPASS (BromureAC.swift:3221-3278). Severity: **HIGH**.
- **MISSING**: NetworkHealer watch + repair prompt (BromureAC.swift:2395-2461). Severity: **MEDIUM**.
- **MISSING**: subscription-token & codex-token & shell-debug bridges (BromureAC.swift:2322-2346).

### 5.3 New-profile creation
- **macOS**: `openEditorWindow(editing: nil)` with template-derived draft + `nextDefaultProfileName()` walker (BromureAC.swift:1482-1490). Auto-opens editor when launching with zero profiles (BromureAC.swift:581, 1117).
- **Windows status**: PARTIAL. `SessionsViewModel.NewProfile` (SessionsViewModel.cs:93-106) creates from template, opens editor. Empty-state UI exists in SessionsView.xaml (lines 113-127). No `nextDefaultProfileName` collision avoidance — every new profile is just "New profile" (ProfilesViewModel.cs:112; SessionsViewModel uses `_store.NewFromTemplate()`). Severity: **LOW**.

---

## 6. Settings / Preferences pane

### 6.1 macOS surface
- "Preferences…" menu item (⌘,) → `openPreferencesAction` (BromureAC.swift:1359-1399) opens the TEMPLATE PROFILE EDITOR (`ProfileEditorView(profile: template, …)`).
- macOS has NO separate "Settings" pane with paths/CA/etc — every operational setting lives either inside the template profile, in `UserDefaults` (`automation.enabled`, `automation.port`, `automation.bindAddress`), or as menu items.
- Rebuild Base Image… → `rebuildBaseImageAction` (BromureAC.swift:1401-1410).
- Bromure → Preferences → Automation pane (ProfileViews.swift uses category `.automation`) — toggles `automation.enabled` UserDefault.
- Enrollment menu item (top-level App menu).
- Sparkle "Check for Updates…" (App menu, BromureAC.swift:1130-1146).

### 6.2 Windows SettingsView
- **Windows source**: SettingsView.xaml + SettingsViewModel.cs.
- **Sections**:
  - Storage paths (App data / Machine data / Base images) with Open buttons — NOT IN macOS (informational only).
  - Enrollment (status + Enroll… + Unenroll). macOS has this via menu + dedicated window.
  - Default profile (template) → "Edit template profile…" button. macOS routes via ⌘, instead.
  - Ubuntu base image (Build / rebuild + Delete). macOS routes via "Rebuild Base Image…" menu.
  - MITM root CA fingerprint (SHA-1 thumbprint) — NOT IN macOS UI.
  - Display mode dropdown (`DisplayMode.None / LocalSdl / LocalGtk`) — **STALE** (QEMU-era leftover; HCS path ignores this entirely).

### 6.3 Setting-by-setting parity

| macOS setting | Surface | Windows status |
|---|---|---|
| `automation.enabled` UserDefault | Preferences → Automation pane | **MISSING** — no UI; defaults off, never settable from app. Severity: **HIGH** (e2e and MCP clients depend on it). |
| `automation.port` | Preferences → Automation | **MISSING**. AutomationServer hard-codes (verify ShellViewModel.cs:208). |
| `automation.bindAddress` | Preferences → Automation | **MISSING**. |
| `BROMURE_AC_DEBUG` env | env var only | OK (env var only on both — BACDebug.swift:7-14). |
| `BROMURE_DEBUG_CLAUDE` env | env var only | DIFFERENT — macOS gates shell-agent shipping + ShellBridge on this; Windows has no equivalent path (search above showed 0 hits). Severity: **MEDIUM** (e2e shell exec). |
| App language (`AppleLanguages`) | OS-level pref | **MISSING** — Windows is English-only (and CLAUDE.md mentions README confirms this); macOS ships 8 lprojs (de/en/es/fr/ja/pt/zh-Hans/zh-Hant). Severity: **MEDIUM** (CRITICAL for international users). |
| Sparkle update channel | Sparkle | **MISSING** — no auto-updater on Windows. Severity: **HIGH**. |
| Base image version display | Storage chip in editor + rebuild prompt | PARTIAL — UbuntuBaseStatus shows size + mtime but not the `imageVersion` stamp. macOS uses `installedImageVersion` to detect drift. |
| Restart-required diff prompt | `restartRequiringChanges` (BromureAC.swift:1815-1867) | **MISSING** — Windows saves profile and live session keeps running with stale config. Severity: **HIGH**. |
| Credential Approvals menu | Window → Credential Approvals… (BromureAC.swift:1196-1220) | PARTIAL — Approvals pane exists in nav (NavigationItem) but no "revoke all" / per-row revoke shown explicitly (need to verify ApprovalsView.xaml — out of audit scope, but the menu is at least navigable). |
| Trace Inspector menu | Window → ⇧⌘I (BromureAC.swift:228-233) | OK as nav pane (no keyboard shortcut). Severity: **LOW**. |
| Profile Manager (⌘0) | Window menu | **MISSING** — Ctrl+0 isn't bound. |
| Enroll in bromure.io… | App menu (state-aware title) | DIFFERENT — Windows surfaces enrollment in Settings only, not as a top-level menu item. macOS auto-switches title between "Enroll in…" and "bromure.io Enrollment…" (BromureAC.swift:1154-1177). Severity: **LOW**. |

---

## 7. Initialization progress (Welcome → Bake)

### 7.1 macOS `InitProgressModel` (SetupViews.swift)
- `status`, `consoleLog`, `error`, `isRunning`, `progress` (0-1, monotonic).
- `expectedTotalLines = 7500`, `progressCeiling = 0.97`, `maxLines = 100` rolling buffer.
- `recordHostPhase` recognises "base image already at" / "base image ready" → bumps to 1.0.
- `appendLog` normalises CRLF/CR, trims trailing partial line.
- View: spinner + status pill + percent + linear ProgressView + collapsible console (DisclosureGroup, default collapsed) + Copy log button + Close on error.

### 7.2 Windows `InitProgressViewModel`
- Direct port of the above (InitProgressViewModel.cs).
- **DIFFERENCES**:
  - No `expectedTotalLines` / `progressCeiling` constants — progress is whatever `BumpProgress(p.Fraction)` provides. macOS has line-count-driven progress that smooths the bar when the host doesn't push explicit fractions. Severity: **LOW**.
  - No `recordHostPhase` recogniser. Severity: **LOW**.
  - No `linesSeen` counter logged at the end (used for tuning).
- View (InitializingView.xaml): Same shape (header, status card with %, expander). DIFFERENCES:
  - Expander `IsExpanded="True"` by default; macOS default is collapsed (SetupViews.swift:178). Severity: **LOW**.
  - No Copy-log button. macOS has one (SetupViews.swift:252-262). Severity: **LOW**.
  - Cancel binding points to `DataContext.CancelCommand` of the Window (= ShellViewModel.Cancel) — correct.

### 7.3 macOS phases shown (from setup.sh's progress messages)
- "Downloading Ubuntu cloud image…"
- "Extracting…"
- "Installing tools (apt)…"
- "Installing Node + Claude Code + Codex…"
- "Building kitty / xinitrc…"
- "Capturing kernel / initrd…"
- "Base image ready."

### 7.4 Windows phases
- "[" + stage + "] " + message — stages come from `VmBaker.BakeProgress.Stage` (kernel/disk/etc). Different naming, broadly equivalent. Severity: **LOW**.

### 7.5 Welcome view copy
- **macOS** (SetupViews.swift:131-165): "First-time setup downloads Ubuntu Server and installs Node.js, Claude Code, Codex, kitty, and the desktop chrome inside an isolated VM."
- **Windows** (WelcomeView.xaml): "First-time setup downloads a ~60 MB Alpine virt ISO, boots it inside a transient Hyper-V VM, and runs setup.sh — debootstraps Ubuntu Noble, installs kitty + the agent toolchain, captures the kernel and initrd. ~10–15 minutes."
- Both accurate to their own implementation. Severity: **OK**.

---

## 8. Bake overlay

### 8.1 macOS
- No separate "bake overlay" — bake IS the InitializingView, full-window. SetupView → renderInitializing.

### 8.2 Windows
- DIFFERENT — has both `InitializingView` (Phase=Initializing in shell) AND a separate modal `BakeOverlay.xaml` driven by `BakeOverlayViewModel` for re-bakes from Settings.
- **Detail**: BakeOverlayViewModel is currently null (ShellViewModel.cs:117-118 — `Baker = null; BakeOverlay = null`), so the overlay never fires. The `BuildUbuntuBaseAsync` command (SettingsViewModel.cs:124-147) falls back to printing CLI hints when `BakeOverlay` is null. Severity: **MEDIUM** — from the Settings pane, the user clicks "Build / rebuild" and gets a text instruction, not a UI flow. macOS routes "Rebuild Base Image…" through the same InitializingView; Windows should too once `Baker` is wired.

---

## 9. Menus / toolbars / app menu

### 9.1 macOS app menu
- **About %@** / Check for Updates… / Enroll in bromure.io… / Preferences… (⌘,) / Rebuild Base Image… / Hide / Hide Others / Show All / Quit.

### 9.2 macOS Edit menu
- Undo / Redo / Cut / Copy / Paste / Select All.

### 9.3 macOS Window menu
- Minimize / Close / Profile Manager (⌘0) / Trace Inspector… (⇧⌘I) / Credential Approvals….
- Auto-populated with session windows by AppKit.

### 9.4 Windows
- **MISSING ENTIRELY** — MainWindow.xaml has no `Menu`, no `WindowChrome`, no menu bar of any kind. Severity: **HIGH** for discoverability of:
  - About / version
  - Check for updates
  - Enrollment
  - Rebuild base
  - Trace Inspector (only reachable via sidebar)
  - Credential Approvals (only via sidebar)
  - Hide / Show All
  - Edit menu (Cut/Copy/Paste — WPF gets these for free via input bindings, so functionally OK; visually missing).

### 9.5 Toolbar / status bar
- **macOS**: TabbedSessionWindow has a per-window toolbar (audit 09 likely covers this).
- **Windows**: SessionsView has a custom bottom toolbar (+ / - / Launch / Stop). macOS picker has + / - in the bottom of the list and a separate detail panel. Layouts diverge, but functional parity for the buttons exists.

---

## 10. Notifications

- **macOS source**: No NSUserNotification posting found in the audit scope. Sparkle handles update-available natively. Compromise alert is modal NSAlert, not a notification.
- **Windows status**: MISSING (no Windows toast notifications wired). Severity: **LOW** — macOS doesn't really use them either.

---

## 11. About / preferences pane

- **macOS**: About is the standard `orderFrontStandardAboutPanel:` (BromureAC.swift:148). Preferences = template profile editor (BromureAC.swift:1359-1399).
- **Windows**: MISSING. No About dialog, no version display anywhere in the chrome (the sidebar shows "Agentic Coding (Windows preview)" but no version). Severity: **MEDIUM**.

---

## 12. Localization

- **macOS source**: 8 lprojs (de/en/es/fr/ja/pt/zh-Hans/zh-Hant) under `Sources/AgentCoding/*.lproj/Localizable.strings`. Every user-visible string goes through `NSLocalizedString(_:comment:)`.
- **Windows status**: MISSING (English-only per README). All user-facing strings hardcoded in XAML / C#. Severity: **HIGH** for international parity (CRITICAL if Windows port targets the same userbase).

---

## 13. Keyboard shortcuts cross-reference

| macOS | Windows expectation | Windows status |
|---|---|---|
| ⌘N (new profile) | Ctrl+N | MISSING |
| ⌘T (new tab) | Ctrl+T | MISSING (intercept logic exists in keyMonitor) |
| ⌘W (close tab/window) | Ctrl+W | MISSING |
| ⌘1-9 (switch tab) | Ctrl+1-9 | MISSING |
| ⌘0 (Profile Manager) | Ctrl+0 | MISSING |
| ⌘, (Preferences) | Ctrl+, | MISSING |
| ⌘Q (Quit) | Alt+F4 (default) | OK by OS convention |
| ⇧⌘I (Trace Inspector) | Ctrl+Shift+I | MISSING |
| ⌘H (Hide) | Win+D (system) | N/A |
| ⌘Z/⌘C/⌘V (Edit) | Ctrl+Z/C/V | OK (WPF default) |

Severity: **HIGH** in aggregate.

---

## 14. Trace inspector availability / launch path

- **macOS**: Menu item ⇧⌘I + per-session toolbar button calling `openTraceInspector(for:)` (BromureAC.swift:1328-1357). Window is independent NSWindow.
- **Windows**: Sidebar nav item "Trace inspector" (NavigationItem). Lives inside MainWindow grid; no separate window. Severity: **LOW** (functional).

---

## 15. Profile editor launch path

- **macOS**: Picker row "Edit…" context menu, ⌘0 → row → gear button (ProfileViews.swift), all route to `openEditorWindow(editing:)`. New profile: + button or `nextDefaultProfileName`. Preferences (⌘,) opens template editor.
- **Windows**: Gear icon per row (SessionsView.xaml:98-105) + + button. ProfileEditorWindow shown as child window with `Owner = MainWindow`. Template editor reachable from Settings → "Edit template profile…". Severity: OK functionally, missing context menu (see 4.3).

---

## 16. Automation enable/disable from UI

- **macOS**: ProfileEditorView has an Automation category that toggles `UserDefaults.standard.bool(forKey: "automation.enabled")` (ProfileViews.swift category `.automation`). `startAutomationServerIfNeeded` reads it at app launch. Tests/ac-e2e.mjs sets it before launching.
- **Windows status**: **MISSING UI**. AutomationServer is started unconditionally (ShellViewModel.cs:195 `StartAutomationServer();` in constructor). No toggle, no port/bind-address override, no opt-out. Severity: **HIGH** — security regression: macOS defaults OFF, Windows is always ON.

---

## 17. Subscription token swap sheet flow

- **macOS**: SubscriptionTokenSwapSheet (Sources/AgentCoding/SubscriptionTokenSwapSheet.swift) — sheet flow exists but is currently DISABLED in the engine wiring (BromureAC.swift:326-356 "TEMPORARILY DISABLED").
- **Windows status**: Both sides have the swap state model (`subscriptionTokenSwap`, `codexTokenSwap`) but Windows has no sheet view. Since macOS is also disabled, severity: **LOW** until re-enabled.

---

## Summary

### Gap counts
- **CRITICAL**: 2
- **HIGH**: 15
- **MEDIUM**: 8
- **LOW**: 11

### Top 5 most impactful gaps

1. **CRITICAL — Compromised-profile boot is unblocked on Windows.** macOS refuses to boot a profile marked compromised by the MITM detector until the user wipes disk+home (BromureAC.swift:2011-2017, 2499-2554, 2566-2650). Windows has no equivalent gate, no `SessionDisk.isCompromised` check before `SessionViewModel.StartAsync`, and no `MarkCompromised` / wipe handler. Audit-03 already flags the compromise pipeline as MISSING; the UI shell-level gap means even if detection lands, the next launch happily reboots into a known-bad VM.

2. **HIGH — No app menu at all.** No About, no Check for Updates, no menu-driven Enroll/Preferences/Rebuild/Trace/Approvals. Discoverability collapse: ~30% of macOS features are reachable only through menus.

3. **HIGH — Automation HTTP server is always-on with no UI toggle and no port/bind-address override.** macOS defaults OFF behind `automation.enabled` UserDefault; Windows starts it unconditionally in `ShellViewModel` ctor. Security regression + accidental port collisions.

4. **HIGH — No keyboard shortcuts.** ⌘T / ⌘W / ⌘1-9 / ⌘, / ⇧⌘I / ⌘0 / ⌘N all missing. The macOS interceptKey path (BromureAC.swift:741-791) is sophisticated; the Windows port has nothing equivalent.

5. **HIGH — Drift detection + restart-required prompts are absent.** macOS prompts on launch when base image version differs from `baseImageVersionAtClone` (BromureAC.swift:2020-2041), and prompts to restart running sessions when relevant profile fields changed (BromureAC.swift:1815-1897). Windows silently runs stale, leading to "settings didn't stick" confusion.

Other high-priority items: exit-on-last-window kills running VMs (1.7); no per-window suspend/shutdown chooser (1.9); no host ssh-agent key load on launch (5.2); imported-key passphrase loading missing; SSO refresh loop missing; localization missing; Sparkle/updater missing; new-profile name collision avoidance missing; profile picker context menu missing.
