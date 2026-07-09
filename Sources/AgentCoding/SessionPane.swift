import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Pane host

/// The window currently displaying a `SessionPane`. A pane is host-agnostic —
/// it can live in the unified multi-VM window or a popped-out single-VM
/// window — so anything that genuinely needs the *window* (key/focus state,
/// running the close-action pipeline, window chrome) goes through this.
@MainActor
protocol SessionPaneHost: AnyObject {
    /// The NSWindow currently showing this pane, if any. nil while the pane is
    /// registered but not displayed (e.g. a background/headless session).
    var paneHostWindow: NSWindow? { get }
    /// The pane wants to go away — its last tab closed, or a relaunch failed.
    /// The host runs the profile's close-action pipeline (suspend / background
    /// / shutdown) for the pane's VM.
    func paneRequestsClose(_ pane: SessionPane)
    /// The pane's profile was edited live; the host re-applies window-level
    /// chrome (title, opacity backing) that the pane can't touch itself.
    func paneDidUpdateProfile(_ pane: SessionPane)
}

// MARK: - Session pane

/// The per-VM UI surface: the shared `VZVirtualMachineView`, its decorations,
/// the tab model, and all tab/shortcut logic for one running VM. Extracted out
/// of `TabbedSessionWindow` so a single window can host many of them side by
/// side (the unified source-list window) while a pane can also be popped out
/// into its own window — the pane is the unit of "one VM's tabs + framebuffer",
/// independent of which window draws it.
///
/// Each tab is a tmux *window* inside the one VM's single tmux session; tmux is
/// authoritative for the tab list (`applyTabList`), so there's no host-side
/// liveness guessing.
@MainActor
@Observable
final class SessionPane {
    /// The profile the running VM was launched with. `applyLiveProfileUpdates`
    /// rebinds this when the user saves the editor; everything in-flight
    /// (close action, MITM lookups keyed off `profile.id`, etc.) sees the new
    /// values without needing a restart.
    var profile: Profile
    let model = TabsModel()
    weak var acDelegate: ACAppDelegate?
    /// The window currently drawing this pane. Set by whichever host embeds
    /// `containerView`; cleared on detach.
    weak var host: SessionPaneHost?

    /// The pane's display: hosts the active tab's native terminal surface
    /// plus decorations (suspended tint, the window-opacity blend). A host
    /// window embeds *this* view.
    let containerView: NSView

    /// Red translucent overlay over the framebuffer while the VM is paused for
    /// a compromise alert. Built once, hidden by default.
    private let suspendedTintView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        // systemRed @ 35% alpha — unmistakably "frozen + tainted", still legible
        // underneath for forensics.
        v.layer?.backgroundColor = NSColor.systemRed
            .withAlphaComponent(0.35).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// The sandbox backing this VM, set by ACAppDelegate after the VM starts;
    /// nil while booting. The *canonical* owner is ACAppDelegate's
    /// `runningSessions` registry — this is a borrow that drops on detach while
    /// the registry keeps the VM alive (the persistent-agent model).
    var sandbox: UbuntuSandboxVM?

    /// What the close pipeline resolved from the profile's `closeAction` (`.ask`
    /// turned into a prompt). nil for a programmatic close (compromise /
    /// relaunch), which detaches the UI without touching the VM.
    var closeIntent: Profile.CloseAction?

    /// When true, the next `sandbox.onStopped` shouldn't tear the pane down —
    /// instead, a fresh VM is relaunched in place. Set by the Reboot action.
    var rebootRequested: Bool = false

    /// Has a populated tmux window list been seen yet this session. Until it
    /// has, an empty list means "tmux not up yet" (don't power off), not "all
    /// tabs closed".
    private var sawTabList = false

    // MARK: Boot overlay (animation + watchdog)

    /// The Ghost-in-the-Shell boot screen shown over the pane until the first
    /// roster lands. nil when not showing.
    private var bootOverlayHost: NSHostingView<BootAnimationView>?
    private let bootOverlayModel = BootOverlayModel()
    /// Deferred `showBootOverlay` — cancelled if the roster beats it (fast
    /// resume), so a quick reconnect never flashes the animation.
    private var bootOverlayShowItem: DispatchWorkItem?
    /// 30s watchdog — flips the overlay to its failure panel if no terminal
    /// shows up.
    private var bootWatchdogItem: DispatchWorkItem?
    private static let bootWatchdogSeconds: TimeInterval = 30

    /// Reset boot-detection when the same pane is reused for a fresh VM (a
    /// reboot relaunch). Without this the stale `sawTabList == true` makes the
    /// relaunched VM's early empty roster — published before its tmux is up —
    /// read as "all tabs closed" and power the fresh VM straight back off.
    func resetBootDetection() {
        sawTabList = false
        beginBootOverlay()   // reboot → show the dive screen again
    }

    /// Per-key timestamp of the last host-owned chord seen, feeding
    /// `acAutorepeatGuard`.
    private var lastShortcutAt: [String: Date] = [:]

    init(profile: Profile, acDelegate: ACAppDelegate) {
        self.profile = profile
        self.acDelegate = acDelegate

        let container = NSView()
        self.containerView = container
        model.accentHex = profile.color.hexInUI

        // The container carries the user's opacity on its own layer; the
        // terminal surface renders at full opacity and inherits the alpha
        // when composited. The backing matches the terminal's background
        // color so a moment with no surface mounted (VM reboot, pre-first-
        // attach) reads as an empty terminal — NOT a hole through to the
        // desktop, which is what a clear backing showed.
        container.wantsLayer = true
        let bgHex = profile.resolveStyle(against: .load()).backgroundHex
        container.layer?.backgroundColor = NSColor(Color(hex: bgHex)).cgColor
        // Tint overlay sits ABOVE the terminal surface. Hidden by default;
        // the compromise handler reveals it the moment the VM is paused.
        container.addSubview(suspendedTintView)
        NSLayoutConstraint.activate([
            suspendedTintView.topAnchor.constraint(equalTo: container.topAnchor),
            suspendedTintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            suspendedTintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            suspendedTintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let opacity = min(1.0, max(0.3, profile.windowOpacity))
        container.layer?.opacity = Float(opacity)

        // A freshly-created pane means a VM is booting — show the dive screen
        // until the guest's first roster proves the terminal is live.
        beginBootOverlay()
    }

    /// Show / hide the red tint overlay on the framebuffer. Called by the
    /// compromise handler around the pause + alert so the frozen frame visibly
    /// reads as "stopped, do not trust this".
    func setSuspendedTint(_ on: Bool) {
        suspendedTintView.isHidden = !on
    }

    // MARK: - Boot overlay

    /// Arm the boot screen. Deferred ~400ms so a fast resume (roster already
    /// coming) never flashes it; starts the watchdog when it actually shows.
    private func beginBootOverlay() {
        guard bootOverlayHost == nil, !sawTabList else { return }
        bootOverlayShowItem?.cancel()
        bootOverlayModel.workspaceName = profile.name
        bootOverlayModel.accentHex = accentForBoot(profile.color.hexInUI)
        bootOverlayModel.failed = false
        let item = DispatchWorkItem { [weak self] in self?.presentBootOverlay() }
        bootOverlayShowItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func presentBootOverlay() {
        guard bootOverlayHost == nil, !sawTabList else { return }
        let view = BootAnimationView(
            model: bootOverlayModel,
            onReset: { [weak self] in self?.acDelegate?.rebuildBaseImageAction(nil) },
            onKeepWaiting: { [weak self] in
                // Back to the dive HUD and re-arm the watchdog for another round.
                self?.bootOverlayModel.failed = false
                self?.armBootWatchdog()
            })
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        // Topmost — above the terminal surface AND the suspended tint.
        containerView.addSubview(host, positioned: .above, relativeTo: suspendedTintView)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: containerView.topAnchor),
            host.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        bootOverlayHost = host
        armBootWatchdog()
    }

    private func armBootWatchdog() {
        bootWatchdogItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Still booting after the timeout → surface the failure panel.
            guard let self, self.bootOverlayHost != nil, !self.sawTabList else { return }
            self.bootOverlayModel.failed = true
        }
        bootWatchdogItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bootWatchdogSeconds, execute: item)
    }

    /// The first live roster arrived (or the pane is going away): tear the boot
    /// screen down so the terminal underneath is visible.
    private func endBootOverlay() {
        bootOverlayShowItem?.cancel(); bootOverlayShowItem = nil
        bootWatchdogItem?.cancel(); bootWatchdogItem = nil
        guard let host = bootOverlayHost else { return }
        bootOverlayHost = nil
        // Brief fade so the terminal doesn't pop in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            host.animator().alphaValue = 0
        }, completionHandler: { host.removeFromSuperview() })
    }

    /// Boot-screen accent: fall back to the GITS cyan when the profile color is
    /// near-black/near-white and would read poorly over the dark rain.
    private func accentForBoot(_ hex: String) -> String {
        let c = NSColor(Color(hex: hex))
        guard let rgb = c.usingColorSpace(.sRGB) else { return "#38f9d7" }
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent
                + 0.114 * rgb.blueComponent
        return (lum < 0.12 || lum > 0.9) ? "#38f9d7" : hex
    }

    // MARK: Native terminal (the pane's display)

    /// Per-tab libghostty surfaces; created on first use.
    private(set) var terminalController: TerminalSessionController?
    /// The surface currently mounted (the active tab's).
    private var mountedTerminalView: TerminalSurfaceView?

    /// What a host should focus when this pane mounts.
    var preferredFirstResponder: NSView { mountedTerminalView ?? containerView }

    /// Mount (or swap to) the native surface for the active tab; unmount in
    /// framebuffer mode. The framebuffer keeps running *behind* the surface —
    /// both are views of the same tmux session, which is what makes the
    /// toggle safe to flip live. Falls back to the framebuffer silently if
    /// libghostty is unavailable.
    func updateNativeTerminalMount() {
        guard model.tabs.indices.contains(model.activeIndex) else { return }
        let windowIndex = model.tabs[model.activeIndex].index
        if terminalController == nil {
            terminalController = TerminalSessionController(profile: profile)
        }
        guard let view = terminalController?.view(forWindow: windowIndex) else { return }
        guard view !== mountedTerminalView else { return }
        mountedTerminalView?.removeFromSuperview()
        mountedTerminalView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view, positioned: .below, relativeTo: suspendedTintView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: containerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        containerView.window?.makeFirstResponder(view)
    }

    /// Tear down all native surfaces (VM stopping / pane closing).
    func retireNativeTerminals() {
        mountedTerminalView?.removeFromSuperview()
        mountedTerminalView = nil
        terminalController?.retireAll()
        terminalController = nil
        // A stop mid-boot: drop the dive screen + its watchdog, don't leak them.
        endBootOverlay()
    }

    /// Re-bind `profile` to a freshly-saved version and re-apply the pane-side
    /// state that depends on it (accent, opacity, terminal appearance). The
    /// host updates window-level chrome via `paneDidUpdateProfile`.
    func applyLiveProfileUpdates(_ newProfile: Profile) {
        profile = newProfile
        model.accentHex = newProfile.color.hexInUI
        let opacity = min(1.0, max(0.3, newProfile.windowOpacity))
        containerView.layer?.opacity = Float(opacity)
        let bgHex = newProfile.resolveStyle(against: .load()).backgroundHex
        containerView.layer?.backgroundColor = NSColor(Color(hex: bgHex)).cgColor
        terminalController?.applyProfile(newProfile)   // live appearance update
        updateNativeTerminalMount()
        host?.paneDidUpdateProfile(self)
    }

    /// Rebuild the tab bar from a saved-state snapshot on restore so pills show
    /// instantly. The resumed VM's tmux session still holds its windows, so the
    /// next roster tick (`applyTabList`) reconciles this to the truth.
    func rehydrateTabs(from state: SessionDisk.TabsState) {
        model.tabs = state.tabs.map { TabsModel.Tab(label: $0.label, id: $0.id) }
        model.activeIndex = max(0, min(state.activeIndex, model.tabs.count - 1))
    }

    /// Capture the current tab model into a snapshot for persistence.
    func snapshotTabs() -> SessionDisk.TabsState {
        SessionDisk.TabsState(
            tabs: model.tabs.map {
                SessionDisk.TabSnapshot(id: $0.id, label: $0.label)
            },
            activeIndex: model.activeIndex
        )
    }

    /// Select a tab → tmux select-window. tmux's window index equals the bar
    /// position, so the array index is the target. Highlight optimistically;
    /// the next roster tick confirms.
    /// Tab index (tmux window index) the user just selected locally, awaiting
    /// roster confirmation. While set, roster ticks snapshotted *before* our
    /// select-window landed don't yank the selection back — that reversal
    /// was a pill-highlight blip on the framebuffer path but a full
    /// view-swap flicker (B→A→B) on the native terminal path.
    private var pendingActiveIndex: (index: Int, at: Date)?

    func switchTo(index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        model.activeIndex = index
        // `index` is the model position; the guest wants the tmux window index,
        // which can differ once windows have been closed (gaps).
        // In native mode the select-window still goes to the guest so the
        // shared `bromure` session (framebuffer, CLI attaches) stays in
        // lockstep; the visible swap happens host-side.
        pendingActiveIndex = (model.tabs[index].index, Date())
        acDelegate?.requestSelectTab(index: model.tabs[index].index, in: self)
        updateNativeTerminalMount()
    }

    /// Close a tab → tmux kill-window. The roster removes the pill. Closing the
    /// last tab ends the session, so route through the profile's close-action
    /// pipeline.
    func closeTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        // `index` is the model position → map to the tmux window index.
        acDelegate?.requestCloseTab(index: model.tabs[index].index, in: self)
        if model.tabs.count <= 1 {
            host?.paneRequestsClose(self)
        }
    }

    /// Mirror the guest's tmux window list as the tab bar. tmux is
    /// authoritative, so there's no liveness guessing or reaping. Pill objects
    /// are reused by position so SwiftUI keeps stable row identity.
    func applyTabList(_ tabs: [GuestTab]) {
        // While a reboot is in flight, ignore roster churn entirely — the guest
        // is going down and coming back, and the host is driving a clean relaunch
        // (which resets this pane's boot-detection). Acting on the transient
        // empty rosters here is exactly what used to shut a rebooting VM down.
        if rebootRequested { return }
        guard !tabs.isEmpty else {
            // tmux is gone — the last window closed (or the VM is shutting
            // down). Only act once we've seen a populated list this session so
            // a still-booting VM (tmux not up yet) isn't powered off early.
            if sawTabList {
                retireNativeTerminals()
                acDelegate?.requestStopSession(profile.id, action: .shutdown)
            }
            return
        }
        // First live roster → the guest tmux is up and the terminal is
        // attaching. Retire the boot screen.
        if !sawTabList { endBootOverlay() }
        sawTabList = true
        if model.tabs.count > tabs.count {
            model.tabs.removeLast(model.tabs.count - tabs.count)
        }
        while model.tabs.count < tabs.count {
            let t = tabs[model.tabs.count]
            model.tabs.append(TabsModel.Tab(
                label: t.label, index: t.index, containerID: t.containerID,
                cwd: t.cwd, worktreeBranch: t.worktreeBranch,
                parentBranch: t.parentBranch, rootRepo: t.rootRepo,
                display: t.display, repoRoot: t.repoRoot))
        }
        for (i, t) in tabs.enumerated() {
            if model.tabs[i].label != t.label { model.tabs[i].label = t.label }
            if model.tabs[i].index != t.index { model.tabs[i].index = t.index }
            if model.tabs[i].containerID != t.containerID { model.tabs[i].containerID = t.containerID }
            if model.tabs[i].cwd != t.cwd { model.tabs[i].cwd = t.cwd }
            if model.tabs[i].worktreeBranch != t.worktreeBranch { model.tabs[i].worktreeBranch = t.worktreeBranch }
            if model.tabs[i].parentBranch != t.parentBranch { model.tabs[i].parentBranch = t.parentBranch }
            if model.tabs[i].rootRepo != t.rootRepo { model.tabs[i].rootRepo = t.rootRepo }
            if model.tabs[i].display != t.display { model.tabs[i].display = t.display }
            if model.tabs[i].repoRoot != t.repoRoot { model.tabs[i].repoRoot = t.repoRoot }
        }
        if let activePos = tabs.firstIndex(where: { $0.active }) {
            if let pending = pendingActiveIndex {
                if tabs[activePos].index == pending.index
                    || Date().timeIntervalSince(pending.at) > 3 {
                    // Confirmed (or the switch genuinely failed) — resume
                    // following the roster.
                    pendingActiveIndex = nil
                    if model.activeIndex != activePos { model.activeIndex = activePos }
                }
                // else: stale snapshot from before our select-window — hold.
            } else if model.activeIndex != activePos {
                model.activeIndex = activePos
            }
        }
        if model.activeIndex >= model.tabs.count {
            model.activeIndex = max(0, model.tabs.count - 1)
        }
        // Windows tmux no longer reports are gone for good — drop their
        // surfaces; then make sure the active tab has a live surface.
        terminalController?.retire(windowsNotIn: Set(tabs.map(\.index)))
        updateNativeTerminalMount()
    }

    /// Last per-container CPU/mem from `docker stats`, kept so a fresh container
    /// list (published more often than we may get stats) re-merges the numbers.
    private var dockerStats: [String: (cpu: String, mem: String)] = [:]

    /// Mirror the guest's container list, overlaying any known CPU/mem. Guarded
    /// so an unchanged list (republished every 2s) doesn't churn SwiftUI.
    func applyDockerList(_ containers: [DockerContainer]) {
        let merged = containers.map { c -> DockerContainer in
            var c = c
            // stats / arch come keyed by docker's SHORT id (12-char); the
            // container list uses the full id (--no-trunc), so look up by shortID.
            if let s = dockerStats[c.shortID] { c.cpuPerc = s.cpu; c.memUsage = s.mem }
            if let a = dockerArch[c.shortID] { c.arch = a }
            return c
        }
        if model.dockerContainers != merged { model.dockerContainers = merged }
    }

    /// Overlay live CPU/mem onto the current container list (dashboard-only).
    /// `docker stats` reports the SHORT id, so key everything by `prefix(12)`.
    func applyDockerStats(_ stats: [(id: String, cpu: String, mem: String)]) {
        dockerStats = Dictionary(stats.map { (String($0.id.prefix(12)), (cpu: $0.cpu, mem: $0.mem)) },
                                 uniquingKeysWith: { a, _ in a })
        var changed = false
        var list = model.dockerContainers
        for i in list.indices {
            let s = dockerStats[list[i].shortID]
            let cpu = s?.cpu ?? "", mem = s?.mem ?? ""
            if list[i].cpuPerc != cpu { list[i].cpuPerc = cpu; changed = true }
            if list[i].memUsage != mem { list[i].memUsage = mem; changed = true }
        }
        if changed { model.dockerContainers = list }
    }

    func applyVMStats(cpu: Double, memUsedKB: Int, memTotalKB: Int, load: Double,
                      diskUsedKB: Int, diskTotalKB: Int) {
        model.vmCPU = cpu
        model.vmMemUsedKB = memUsedKB
        model.vmMemTotalKB = memTotalKB
        model.vmLoad = load
        model.vmDiskUsedKB = diskUsedKB
        model.vmDiskTotalKB = diskTotalKB
    }

    func applyListeningPorts(_ ports: [ListeningPort]) {
        if model.vmListeningPorts != ports { model.vmListeningPorts = ports }
    }

    func applyDockerImages(_ images: [DockerImage]) {
        if model.dockerImages != images { model.dockerImages = images }
    }

    func applyDockerError(_ message: String) {
        model.dockerError = message
    }

    func applyDockerRunStatus(_ s: (state: String, image: String, done: Int, total: Int)) {
        let new = s.state.isEmpty
            ? nil
            : DockerRunStatus(state: s.state, image: s.image, done: s.done, total: s.total)
        if model.dockerRunStatus != new { model.dockerRunStatus = new }
    }

    func applyDockerBinfmt(_ arches: [String]) {
        if !model.binfmtProbed { model.binfmtProbed = true }
        if model.binfmtArches != arches { model.binfmtArches = arches }
    }

    /// Last per-container architecture, merged into the container list like stats.
    private var dockerArch: [String: String] = [:]
    func applyDockerArch(_ list: [(id: String, arch: String)]) {
        dockerArch = Dictionary(list.map { (String($0.id.prefix(12)), $0.arch) },
                                uniquingKeysWith: { a, _ in a })
        var changed = false
        var containers = model.dockerContainers
        for i in containers.indices {
            let a = dockerArch[containers[i].shortID] ?? ""
            if containers[i].arch != a { containers[i].arch = a; changed = true }
        }
        if changed { model.dockerContainers = containers }
    }

    /// Run a host-owned keychord by its bare key ("t"/"w"/"n"/"1"…"9").
    /// Single sink for every delivery route so the ⌘T action can't drift
    /// between paths. Returns true when the key matched (and the event, if
    /// any, should be consumed).
    @discardableResult
    func performACShortcut(_ key: String, isRepeat: Bool = false) -> Bool {
        let fire = !isRepeat && acAutorepeatGuard(key)
        switch key {
        case "t":
            if fire { acDelegate?.spawnNewTab(in: self) }
            return true
        case "w":
            if fire { closeTab(at: model.activeIndex) }
            return true
        case "n":
            if fire { acDelegate?.openProfileManagerAction(nil) }
            return true
        default:
            guard let n = Int(key), (1...9).contains(n),
                  model.tabs.indices.contains(n - 1) else { return false }
            if fire { switchTo(index: n - 1) }
            return true
        }
    }

    /// Leading-edge autorepeat filter for the guest-bounce path, which has no
    /// flag distinguishing a held chord from a deliberate re-press. X11 repeats
    /// a held chord ~every 40ms; a deliberate re-press is ≥~120ms apart, so an
    /// 80ms window passes real presses but swallows autorepeat. The timestamp is
    /// refreshed on every call so a held key keeps resetting the window and
    /// fires once.
    private func acAutorepeatGuard(_ key: String) -> Bool {
        let now = Date()
        defer { lastShortcutAt[key] = now }
        guard let prev = lastShortcutAt[key] else { return true }
        return now.timeIntervalSince(prev) >= 0.08
    }
}
