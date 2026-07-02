import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Framebuffer view

/// `VZVirtualMachineView` that never lets a drag move the host window. The
/// unified / pop-out windows are `isMovableByWindowBackground` (so empty
/// toolbar areas drag the window), but `VZVirtualMachineView` defaults
/// `mouseDownCanMoveWindow` to `true` — which means a drag inside the
/// framebuffer would move the window instead of selecting text in the guest.
/// Returning `false` hands the drag to the VM (text selection, drag-to-select)
/// while the toolbar still drags. Only the titlebar/toolbar moves the window.
final class FramebufferView: VZVirtualMachineView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// When connected, the host owns the wheel: scroll deltas are routed to
    /// the guest's tmux scrollback instead of being injected as VZ wheel
    /// events (which kitty would turn into arrow keys — see `ScrollBridge`).
    weak var scrollBridge: ScrollBridge?

    override func scrollWheel(with event: NSEvent) {
        if let bridge = scrollBridge, bridge.isConnected {
            // Consume it: do NOT call super, so VZ never injects a wheel event
            // into the guest. That's what kills the arrow-keys-through-history
            // behavior. The guest scrolls tmux's history out-of-band instead.
            bridge.handleScroll(deltaY: event.scrollingDeltaY)
            return
        }
        super.scrollWheel(with: event)
    }
}

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

    /// The single shared VM display — every tmux window for this VM renders
    /// into this view because they all live in the same X session.
    let vmView: VZVirtualMachineView

    /// Wraps `vmView` so we can toggle decorations (the suspended-VM tint, the
    /// window-opacity blend) without touching the VZ view's own layer — poking
    /// VZVirtualMachineView's `wantsLayer`/`layer.opacity` has been observed to
    /// crash AppKit's window transform animator. A host embeds *this* view.
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

    /// Keyboard-layout bridge that ferries macOS layout changes into the
    /// guest's setxkbmap. nil when no socket device is available yet.
    var keyboardBridge: KeyboardBridge?

    /// Routes trackpad/wheel scroll to the guest's tmux scrollback. Held here
    /// so it outlives the call that creates it; also wired into the
    /// framebuffer view so its `scrollWheel` override can reach it.
    var scrollBridge: ScrollBridge? {
        didSet { (vmView as? FramebufferView)?.scrollBridge = scrollBridge }
    }

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

    /// Reset boot-detection when the same pane is reused for a fresh VM (a
    /// reboot relaunch). Without this the stale `sawTabList == true` makes the
    /// relaunched VM's early empty roster — published before its tmux is up —
    /// read as "all tabs closed" and power the fresh VM straight back off.
    func resetBootDetection() { sawTabList = false }

    /// Per-key timestamp of the last host-owned chord seen, feeding
    /// `acAutorepeatGuard`.
    private var lastShortcutAt: [String: Date] = [:]

    init(profile: Profile, acDelegate: ACAppDelegate) {
        self.profile = profile
        self.acDelegate = acDelegate

        let view = FramebufferView()
        // capturesSystemKeys = false → macOS handles ⌘Tab/⌘H/⌘Space/⌘Q at the
        // WindowServer level instead of routing them to the guest. We lose
        // F-key forwarding but agent-coding workflows almost never use them and
        // ⌘Tab is constant — the right trade-off.
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        self.vmView = view

        let container = NSView()
        self.containerView = container
        model.accentHex = profile.color.hexInUI

        // Wrap the VZ view in a plain NSView container. We apply the user's
        // opacity to the *container's* layer, not the VZ view itself — touching
        // VZVirtualMachineView's own layer.opacity has been observed to crash
        // AppKit's window transform animator. The container takes the layer
        // alpha cleanly; the framebuffer renders at full opacity and inherits
        // the alpha when composited.
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Tint overlay sits ABOVE the VZ view so it composites on top of the
        // framebuffer. Hidden by default; the compromise handler reveals it the
        // moment the VM is paused.
        container.addSubview(suspendedTintView)
        NSLayoutConstraint.activate([
            suspendedTintView.topAnchor.constraint(equalTo: container.topAnchor),
            suspendedTintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            suspendedTintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            suspendedTintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let opacity = min(1.0, max(0.3, profile.windowOpacity))
        container.layer?.opacity = Float(opacity)
    }

    /// Show / hide the red tint overlay on the framebuffer. Called by the
    /// compromise handler around the pause + alert so the frozen frame visibly
    /// reads as "stopped, do not trust this".
    func setSuspendedTint(_ on: Bool) {
        suspendedTintView.isHidden = !on
    }

    /// Re-bind `profile` to a freshly-saved version and re-apply the pane-side
    /// state that depends on it (accent, framebuffer opacity). The host updates
    /// window-level chrome via `paneDidUpdateProfile`.
    func applyLiveProfileUpdates(_ newProfile: Profile) {
        profile = newProfile
        model.accentHex = newProfile.color.hexInUI
        let opacity = min(1.0, max(0.3, newProfile.windowOpacity))
        containerView.layer?.opacity = Float(opacity)
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
    func switchTo(index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        model.activeIndex = index
        // `index` is the model position; the guest wants the tmux window index,
        // which can differ once windows have been closed (gaps).
        acDelegate?.requestSelectTab(index: model.tabs[index].index, in: self)
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
    func applyTabList(_ tabs: [(index: Int, active: Bool, label: String, containerID: String?)]) {
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
                acDelegate?.requestStopSession(profile.id, action: .shutdown)
            }
            return
        }
        sawTabList = true
        if model.tabs.count > tabs.count {
            model.tabs.removeLast(model.tabs.count - tabs.count)
        }
        while model.tabs.count < tabs.count {
            let t = tabs[model.tabs.count]
            model.tabs.append(TabsModel.Tab(label: t.label, index: t.index, containerID: t.containerID))
        }
        for (i, t) in tabs.enumerated() {
            if model.tabs[i].label != t.label { model.tabs[i].label = t.label }
            if model.tabs[i].index != t.index { model.tabs[i].index = t.index }
            if model.tabs[i].containerID != t.containerID { model.tabs[i].containerID = t.containerID }
        }
        if let activePos = tabs.firstIndex(where: { $0.active }), model.activeIndex != activePos {
            model.activeIndex = activePos
        }
        if model.activeIndex >= model.tabs.count {
            model.activeIndex = max(0, model.tabs.count - 1)
        }
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

    func applyVMStats(cpu: Double, memUsedKB: Int, memTotalKB: Int, load: Double) {
        model.vmCPU = cpu
        model.vmMemUsedKB = memUsedKB
        model.vmMemTotalKB = memTotalKB
        model.vmLoad = load
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

    /// True when the host window is key AND the embedded VZ view holds keyboard
    /// focus — i.e. a keystroke is being delivered into the guest. In that state
    /// host-owned chords (⌘T/⌘W/⌘N/⌘1-9) must NOT be acted on by the host key
    /// monitor / `sendEvent`: the chord reaches the guest, Openbox grabs it, and
    /// the bounce (`UbuntuSandboxVM.onShortcut` → `performACShortcut`) runs the
    /// action. Acting in BOTH places double-processes one press.
    var vmHasKeyboardFocus: Bool {
        guard let window = host?.paneHostWindow, window.isKeyWindow,
              let fr = window.firstResponder as? NSView else { return false }
        return fr === vmView || fr.isDescendant(of: vmView)
    }

    /// Run a host-owned keychord by its bare key ("t"/"w"/"n"/"1"…"9"). Single
    /// sink shared by BOTH delivery routes (native-focus key monitor and the
    /// guest bounce), so the ⌘T action can't drift between paths. Returns true
    /// when the key matched (and the event, if any, should be consumed).
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
