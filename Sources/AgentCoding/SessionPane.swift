import AppKit
import SandboxEngine
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import Virtualization

/// How a session pane presents the running agent: the raw libghostty terminal,
/// or the beautified chat-style transcript (Claude Code / Codex desktop look).
enum SessionViewMode { case terminal, beautified }

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
        knownWindowIndices = nil
        model.rosterLive = false
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
        bootOverlayModel.failureKind = .watchdog
        bootOverlayModel.failureDetail = nil
        bootOverlayModel.statusText = nil
        bootOverlayModel.progress = nil
        let item = DispatchWorkItem { [weak self] in self?.presentBootOverlay() }
        bootOverlayShowItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func presentBootOverlay() {
        guard bootOverlayHost == nil, !sawTabList else { return }
        let profileID = profile.id
        let view = BootAnimationView(
            model: bootOverlayModel,
            // NOT rebuildBaseImageAction: that downloads/rebuilds the shared
            // base image (network, ~5–10 min) and leaves this workspace's
            // broken disk exactly as it was. Resetting the workspace's own
            // disk re-clones from the base image already on disk — offline,
            // instant, and the thing that actually unwedges the boot.
            onReset: { [weak self] in
                self?.acDelegate?.resetSystemDiskAfterBootFailure(profileID)
            },
            onKeepWaiting: { [weak self] in
                // Back to the dive HUD and re-arm the watchdog for another round.
                self?.bootOverlayModel.failed = false
                self?.armBootWatchdog()
            },
            onRepairDisk: { [weak self] in
                self?.acDelegate?.repairSystemDiskAction(profileID)
            },
            onResetDisk: { [weak self] in
                self?.acDelegate?.resetSystemDiskAfterBootFailure(profileID)
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

    /// Status line + optional determinate progress (0…1) on the dive
    /// screen — the home-storage migration's surface. Each update re-arms
    /// the watchdog: a multi-minute home copy is *progress*, not a hang,
    /// and must not flip the overlay to "dive failed" mid-copy.
    func updateBootStatus(_ text: String?, progress: Double?) {
        bootOverlayModel.statusText = text
        bootOverlayModel.progress = progress
        if text != nil { armBootWatchdog() }
    }

    /// The serial console showed the boot dying on filesystem errors: flip the
    /// overlay to the disk-failure panel immediately (no point waiting out the
    /// watchdog — the emergency shell never recovers on its own). Presents the
    /// overlay right away if the 400ms defer hasn't fired yet.
    func showFilesystemFailure(detail: String) {
        guard !sawTabList else { return }
        if bootOverlayHost == nil {
            bootOverlayShowItem?.cancel()
            presentBootOverlay()
        }
        bootOverlayModel.failureKind = .filesystem
        bootOverlayModel.failureDetail = detail
        bootOverlayModel.failed = true
    }

    /// Back to the dive HUD (with a status line) while a repair/reset remedy
    /// runs — the pane stays on the boot screen through the relaunch.
    func showBootRemedyProgress(_ text: String) {
        bootOverlayModel.failed = false
        bootOverlayModel.failureKind = .watchdog
        bootOverlayModel.failureDetail = nil
        updateBootStatus(text, progress: nil)
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

    /// Optional beautified transcript view (the "looks like Claude Code / Codex
    /// desktop" mode). When active it replaces the terminal surface in the
    /// container; the tmux session keeps running behind it, so flipping is
    /// lossless. `beautifiedModel` drives the live poll + composer.
    private(set) var viewMode: SessionViewMode =
        UserDefaults.standard.bool(forKey: "ui.beautifiedTranscript") ? .beautified : .terminal
    /// Pins the pane to the raw terminal: the beautified transcript is never
    /// mounted and `setViewMode(.beautified)` is ignored. Set for the
    /// "Register with …" throwaway VM, whose interactive OAuth login (the
    /// sign-in URL, the CLI's prompts) the beautified view would hide. Flips
    /// only this pane — the app-global default is left untouched.
    var beautifierLocked = false {
        didSet {
            guard beautifierLocked, viewMode != .terminal else { return }
            viewMode = .terminal   // deliberately no UserDefaults write
            updateNativeTerminalMount()
        }
    }
    private var mountedBeautifiedHost: NSHostingView<BeautifiedSessionView>?
    private var beautifiedModel: BeautifiedSessionModel?
    /// tmux window indices known to host a coding agent regardless of what
    /// their title says yet — a task's worktree tab is an agent tab by
    /// construction, but its OSC title only names the agent once the agent
    /// is past its startup prompts (folder trust, login). Lets the
    /// beautified view mount from the first frame, where those prompts are
    /// surfaced as cards instead of a raw TUI.
    var agentWindows: Set<Int> = []
    /// A session is on stage (sessions-first): the pane is its chat, full
    /// stop — the beautified view mounts whatever the tab's foreground
    /// program says yet (a new session's tab runs a plain shell for its
    /// first seconds, which used to leave the raw terminal mounted). The
    /// terminal is the Linux button's business, never this pane's while a
    /// session is shown.
    var sessionOnStage = false {
        didSet { if sessionOnStage != oldValue { updateNativeTerminalMount() } }
    }
    /// Opening messages to echo into the beautified view of a window the
    /// moment it mounts (keyed by tmux window index; consumed once) — a
    /// session started with a message shows it, with the thinking cue, before
    /// the agent has written a word.
    var beautifiedSeeds: [Int: String] = [:]
    /// Which agent a window runs (by tmux window index), told by whoever
    /// started it — the "/" palette's catalog before the tab's title says.
    var agentHints: [Int: String] = [:]
    /// Per window: where the chat's transcript reads are copied (the
    /// session's local cache), set by the window before the tab is shown.
    var transcriptSinks: [Int: (Data) -> Void] = [:]

    /// Debug hook: the beautified view's transcript history — how much of
    /// the file it holds, whether earlier conversation is fetchable — and
    /// `{do: earlier}` fetches it (the "Load earlier conversation" button).
    func debugTranscriptHistory(_ what: String) async -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        if what == "earlier" { await m.loadEarlier() }
        return m.debugHistoryState()
    }
    /// Debug: the AppKit tree under the beautified host — every scroll
    /// view's document frame and clip bounds, to see where the transcript
    /// is scrolled when the stage looks blank.
    func debugBeautifiedViewTree() -> [String: Any] {
        guard let host = mountedBeautifiedHost else { return ["error": "no beautified view on stage"] }
        var lines: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.frame
            var line = String(repeating: "  ", count: depth)
                + "\(type(of: v)) \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
            if v.isHidden { line += " hidden" }
            if let sv = v as? NSScrollView {
                let b = sv.contentView.bounds
                let d = sv.documentView?.frame ?? .zero
                line += " [clip \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height)) doc \(Int(d.width))x\(Int(d.height))]"
            }
            lines.append(line)
            if depth < 14 { for c in v.subviews { walk(c, depth + 1) } }
        }
        walk(host, 0)
        return ["hostFrame": "\(host.frame)", "tree": lines]
    }
    /// Debug: scroll the transcript's AppKit clip to `y` (0 = top), as a
    /// person reading history would, and report the clip after.
    func debugBeautifiedScroll(y: CGFloat) -> [String: Any] {
        guard let host = mountedBeautifiedHost else { return ["error": "no beautified view on stage"] }
        func find(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView, "\(type(of: sv))".hasPrefix("HostingScrollView") { return sv }
            for c in v.subviews { if let f = find(c) { return f } }
            return nil
        }
        guard let sv = find(host) else { return ["error": "no transcript scroll view"] }
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        let b = sv.contentView.bounds
        return ["clipY": b.origin.y, "clipH": b.height, "docH": sv.documentView?.frame.height ?? 0]
    }
    func debugTranscriptHistoryState() -> [String: Any] {
        beautifiedModel?.debugHistoryState() ?? ["error": "no beautified view on stage"]
    }
    /// Debug hook: send what's in the chat composer (the Return key).
    func debugSendComposer() -> Bool {
        guard let m = beautifiedModel else { return false }
        m.send()
        return true
    }
    /// Debug: type into the composer the way a person does — through the
    /// field editor AppKit attaches to the focused text field — so layout
    /// trouble that only shows while editing can be reproduced headlessly.
    /// Focuses the field first when it isn't; appends at the end.
    func debugTypeComposer(_ text: String) -> [String: Any] {
        guard let host = mountedBeautifiedHost else { return ["error": "no beautified view on stage"] }
        guard let editor = Self.composerTextView(in: host) else { return ["error": "no composer in the beautified view"] }
        if host.window?.firstResponder !== editor { host.window?.makeFirstResponder(editor) }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
        return debugComposerGeometry()
    }
    /// Debug: the composer's text view against its wrap width — a container
    /// that no longer matches the view is the stale-layout tell.
    func debugComposerGeometry() -> [String: Any] {
        guard let host = mountedBeautifiedHost else { return ["error": "no beautified view on stage"] }
        guard let editor = Self.composerTextView(in: host) else { return ["error": "no composer in the beautified view"] }
        return [
            "ok": true,
            "hostWidth": host.bounds.width,
            "editorWidth": editor.bounds.width,
            "editorHeight": editor.enclosingScrollView?.bounds.height ?? editor.bounds.height,
            "containerWidth": editor.textContainer?.containerSize.width ?? -1,
            "usedWidth": editor.layoutManager.flatMap { lm in
                editor.textContainer.map { lm.usedRect(for: $0).width } } ?? -1,
            "editing": host.window?.firstResponder === editor,
            "textLength": (editor.string as NSString).length,
        ]
    }
    /// Debug: attach a host file to the composer, as a drop on the window would.
    func debugDropFile(_ hostPath: String) -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        let url = URL(fileURLWithPath: (hostPath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return ["error": "unreadable: \(hostPath)"] }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        m.drop([DroppedFile(name: url.lastPathComponent, data: data, isImage: isImage)])
        return ["ok": true, "pending": m.pendingAttachments.count, "bytes": data.count, "image": isImage]
    }
    /// Debug: the chat's command card — its state, or fold/dismiss it.
    func debugCommandCard(_ action: String) -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        switch action {
        case "dismiss": m.dismissCommandOutput()
        case "toggle":  m.toggleLiveCommand()
        default: break
        }
        guard let out = m.commandOutput else { return ["ok": true, "card": false] }
        return ["ok": true, "card": true, "command": out.command, "live": out.live,
                "menu": out.menu, "settled": out.settled, "lines": out.lines.count]
    }
    /// Debug: the drop images the chat holds, by guest path.
    func debugDropImages() -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        return ["ok": true, "images": m.imagesByPath.mapValues { $0.count }]
    }
    /// Debug: press one of the composer's routed keys (return, option-return,
    /// escape, up, down, tab) — the same path a keystroke takes.
    func debugComposerKey(_ name: String) -> [String: Any] {
        guard let host = mountedBeautifiedHost else { return ["error": "no beautified view on stage"] }
        guard let editor = Self.composerTextView(in: host) else { return ["error": "no composer in the beautified view"] }
        let selector: Selector
        switch name {
        case "return":        selector = #selector(NSResponder.insertNewline(_:))
        case "option-return": selector = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        case "escape":        selector = #selector(NSResponder.cancelOperation(_:))
        case "up":            selector = #selector(NSResponder.moveUp(_:))
        case "down":          selector = #selector(NSResponder.moveDown(_:))
        case "tab":           selector = #selector(NSResponder.insertTab(_:))
        default: return ["error": "unknown key \(name)"]
        }
        if host.window?.firstResponder !== editor { host.window?.makeFirstResponder(editor) }
        editor.doCommand(by: selector)
        return ["ok": true, "text": editor.string]
    }
    private static func composerTextView(in view: NSView) -> ComposerNSTextView? {
        if let t = view as? ComposerNSTextView { return t }
        for sub in view.subviews { if let t = composerTextView(in: sub) { return t } }
        return nil
    }
    /// Debug: press the sign-in card's button (a host-run sign-in).
    func debugStartSignIn() -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        guard m.signInProvider != nil else { return ["error": "no account for \(m.agentKind ?? "?")"] }
        m.startHostSignIn()
        return ["ok": true, "prompt": m.prompt?.kind == .login, "status": m.hostSignInStatus ?? ""]
    }
    /// Debug: the sign-in card's state.
    func debugSignInState() -> [String: Any] {
        guard let m = beautifiedModel else { return ["error": "no beautified view on stage"] }
        return ["prompt": m.prompt.map { "\($0.kind)" } ?? "", "failure": m.failure?.detail ?? "",
                "status": m.hostSignInStatus ?? "", "agent": m.agentKind ?? ""]
    }
    /// The tmux window index the mounted beautified host is currently showing.
    /// The model re-targets whichever tab is active, so when the active tab
    /// changes to a *different* index we rebuild the host (reusing it would show
    /// the previous tab's transcript until the next poll); an unchanged index
    /// keeps re-mounts idempotent so roster ticks don't churn the live view.
    private var beautifiedTabIndex: Int?

    /// What a host should focus when this pane mounts.
    var preferredFirstResponder: NSView {
        mountedBeautifiedHost ?? mountedTerminalView ?? containerView
    }

    /// Flip between the raw terminal and the beautified transcript view, live.
    /// Remembers the choice app-globally as the default for subsequent panes.
    /// `persist: false` flips this pane only — the tasks-first "under the hood"
    /// toggle uses it so peeking at the terminal doesn't change the default.
    func setViewMode(_ mode: SessionViewMode, persist: Bool = true) {
        guard mode != viewMode else { return }
        if beautifierLocked, mode == .beautified { return }   // registration VM: terminal only
        viewMode = mode
        if persist {
            UserDefaults.standard.set(mode == .beautified, forKey: "ui.beautifiedTranscript")
        }
        updateNativeTerminalMount()
    }

    /// Mount (or swap to) the native surface for the active tab; unmount in
    /// framebuffer mode. The framebuffer keeps running *behind* the surface —
    /// both are views of the same tmux session, which is what makes the
    /// toggle safe to flip live. Falls back to the framebuffer silently if
    /// libghostty is unavailable.
    func updateNativeTerminalMount() {
        guard model.tabs.indices.contains(model.activeIndex) else { return }
        // Beautified mode only applies to a tab that's actually running a coding
        // agent — a plain shell (or any non-agent) tab has no transcript to
        // show, so it stays the raw terminal even while the mode is toggled on.
        // The active tab's foreground program (its tmux label) is the same
        // signal the sidebar badges agent tabs with.
        let activeTab = model.tabs[model.activeIndex]
        let activeIsAgent = BromureIcons.agentKind(forLabel: activeTab.shownLabel) != nil
            || agentWindows.contains(activeTab.index)
        if sessionOnStage && !beautifierLocked { mountBeautified(); return }
        if viewMode == .beautified && activeIsAgent { mountBeautified(); return }
        unmountBeautified()
        // Restore the profile's window translucency for the terminal.
        containerView.layer?.opacity = Float(min(1.0, max(0.3, profile.windowOpacity)))
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
        unmountBeautified()
        // A stop mid-boot: drop the dive screen + its watchdog, don't leak them.
        endBootOverlay()
    }

    /// A beautified chat for the agent in tmux window `windowIndex`, wired
    /// the way the pane's own is (seeds, transcript sink, inline terminal,
    /// delegations, sign-in, slash commands) — not started. The pane mounts
    /// one for its active tab; a room's grid builds one per session with a
    /// provider pinned to that session's window.
    func makeBeautifiedModel(windowIndex: Int, provider: BeautifiedTranscriptProvider) -> BeautifiedSessionModel {
        let m = BeautifiedSessionModel(provider: provider)
        if let seed = beautifiedSeeds.removeValue(forKey: windowIndex) { m.seedOpening(seed) }
        m.transcriptSink = transcriptSinks[windowIndex]
        // The tab's own terminal surface, for an interactive slash command
        // shown inline in the chat (same tmux client the Linux view uses).
        m.inlineTerminal = { [weak self] in
            guard let self else { return nil }
            if self.terminalController == nil {
                self.terminalController = TerminalSessionController(profile: self.profile)
            }
            return self.terminalController?.view(forWindow: windowIndex)
        }
        m.inlineTerminalSession = { [weak self] in
            self?.terminalController?.tmuxSessionName(forWindow: windowIndex)
        }
        // Delegations this session is part of, for the panel above the
        // composer; the user can answer a delegate's question for the agent.
        m.delegationStore = acDelegate?.delegationStore
        m.sessionStore = acDelegate?.agentSessionStore
        m.currentSession = { [weak self] in
            guard let self, let d = self.acDelegate else { return nil }
            return d.agentSessionStore.session(profileID: self.profile.id, windowIndex: windowIndex)
        }
        m.openSession = { [weak self] id in
            self?.acDelegate?.ensureUnifiedWindow().selectSession(id)
        }
        m.workspaceName = { [weak self] pid in self?.acDelegate?.profile(for: pid)?.name ?? "" }
        m.peerMentions = { [weak self] in
            guard let self, let d = self.acDelegate else { return [] }
            let me = d.agentSessionStore.session(profileID: self.profile.id, windowIndex: windowIndex)?.id
            return d.peerMentions(forWorkspace: self.profile.id, excluding: me)
        }
        m.assignNickname = { [weak self] id, nick in
            self?.acDelegate?.agentSessionStore.setNickname(id, nick)
        }
        // Requests this session made to sessions on other hosts — their
        // records live there; the panel shows them next to the local ones.
        m.remoteDelegations = { [weak self] in
            guard let self, let d = self.acDelegate,
                  let s = d.agentSessionStore.session(profileID: self.profile.id, windowIndex: windowIndex)
            else { return [] }
            return d.delegationEngine.delegationsAsParent(s.id).compactMap { pair in pair.1.map { (pair.0, $0) } }
        }
        m.answerDelegation = { [weak self] delegationID, askID, text in
            guard let engine = self?.acDelegate?.delegationEngine else { return }
            Task { _ = try? await engine.post(delegationID, from: .user, kind: .answer, text: text, answering: askID) }
        }
        let tab = model.tabs.first { $0.index == windowIndex } ?? model.tabs[model.activeIndex]
        // Which agent's commands: the session's own tool, else the tab's
        // label, else the workspace's main agent — the palette always has
        // something to show (the label reads "bash" for agents under an
        // interpreter, and a tab opened by hand carries no session hint).
        m.loadSlashCommands(
            agent: agentHints[windowIndex] ?? BromureIcons.agentKind(forLabel: tab.shownLabel)
                ?? profile.tool.rawValue,
            cwd: tab.cwd)
        // Sign-in on the host: a throwaway machine does the OAuth and the
        // credential never enters this workspace; the agent then restarts
        // on the stand-in key. The sidebar hears about a sign-in screen too.
        m.hostSignIn = { [weak self] provider, events in
            guard let self, let delegate = self.acDelegate else { return }
            delegate.beginProxySignIn(provider: provider, profileID: self.profile.id,
                                      windowIndex: windowIndex, events: events)
        }
        m.relaunchAfterSignIn = { [weak self, weak m] in
            guard let self, let delegate = self.acDelegate, let provider = m?.signInProvider else { return }
            delegate.applyRegisteredSubscription(provider: provider, profileID: self.profile.id)
            if let s = delegate.agentSessionStore.session(profileID: self.profile.id, windowIndex: windowIndex) {
                delegate.agentSessionEngine.relaunchAfterSignIn(s.id)
            }
        }
        m.loginPromptChanged = { [weak self] needs in
            guard let self, let delegate = self.acDelegate,
                  let s = delegate.agentSessionStore.session(profileID: self.profile.id, windowIndex: windowIndex)
            else { return }
            delegate.agentSessionStore.setNeedsSignIn(s.id, needs)
        }
        m.openProviderSettings = { [weak self] in
            guard let self else { return }
            self.acDelegate?.sidebarEditProfile(self.profile.id)
        }
        return m
    }

    /// Mount (or keep) the beautified transcript view, unmounting the terminal
    /// surface (tmux keeps running behind it). Idempotent while the active tab is
    /// unchanged (the live poll keeps that view current); a switch to a different
    /// tab rebuilds it so the transcript matches the tab on screen.
    private func mountBeautified() {
        let windowIndex = model.tabs[model.activeIndex].index
        // Idempotent for the frequent in-place re-mounts (roster ticks) that
        // don't change the tab: keep the live host + model so the poll stays
        // current. A *different* tab must rebuild — the shared model re-targets
        // the active tab, so reusing the old host would show the previous tab's
        // transcript until the next poll (a stale/blank flash the user had to
        // toggle away). `remountForSelection` clears the index so a pane that
        // was swapped out of the display slot always rebuilds too (a detached-
        // then-reattached SwiftUI host comes back blank).
        if mountedBeautifiedHost != nil, beautifiedTabIndex == windowIndex { return }
        unmountBeautified()
        mountedTerminalView?.removeFromSuperview()
        mountedTerminalView = nil
        containerView.layer?.opacity = 1   // opaque chat surface, never dimmed
        let m = makeBeautifiedModel(windowIndex: windowIndex, provider: LocalTranscriptProvider(pane: self))
        beautifiedModel = m
        beautifiedTabIndex = windowIndex
        m.start()
        let host = NSHostingView(rootView: BeautifiedSessionView(model: m))
        host.translatesAutoresizingMaskIntoConstraints = false
        mountedBeautifiedHost = host
        containerView.addSubview(host, positioned: .below, relativeTo: suspendedTintView)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: containerView.topAnchor),
            host.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        containerView.window?.makeFirstResponder(host)
    }

    /// E2E/doc-shot hook: put text in the mounted beautified composer (to
    /// render the "/" palette, say). No-op without a beautified view.
    func debugSetComposer(_ text: String) -> Bool {
        guard let m = beautifiedModel else { return false }
        m.composerText = text
        return true
    }

    private func unmountBeautified() {
        beautifiedModel?.stop()
        beautifiedModel = nil
        beautifiedTabIndex = nil
        mountedBeautifiedHost?.removeFromSuperview()
        mountedBeautifiedHost = nil
    }

    /// Called by the host when this pane (re)enters the shared display slot.
    /// `UnifiedSessionWindow.mountSelected` detaches a pane's `containerView`
    /// while another pane is shown and re-attaches it on return; a beautified
    /// `NSHostingView` doesn't survive that round-trip — its SwiftUI ScrollView
    /// comes back blank (the same symptom the toggle worked around) — so drop it
    /// and let `updateNativeTerminalMount` build a fresh one. Cheap and a no-op
    /// for the terminal surface, which survives re-attach fine.
    func remountForSelection() {
        unmountBeautified()
        updateNativeTerminalMount()
    }

    /// Re-bind `profile` to a freshly-saved version and re-apply the pane-side
    /// state that depends on it (accent, opacity, terminal appearance). The
    /// host updates window-level chrome via `paneDidUpdateProfile`.
    func applyLiveProfileUpdates(_ newProfile: Profile) {
        profile = newProfile
        model.accentHex = newProfile.color.hexInUI
        // Beautified mode is always opaque (a chat surface); only the terminal
        // honors the profile's window translucency.
        let opacity = viewMode == .beautified ? 1.0 : min(1.0, max(0.3, newProfile.windowOpacity))
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
        // Labels only, every pill at index 0: a picture, not a roster. The
        // session store must not bind to (or adopt) these — it did once, and
        // every pill became a session at window 0 (see reconcile).
        model.rosterLive = false
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
            knownWindowIndices = nil
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
        model.rosterLive = true
        // Windows that weren't in the last live roster were created since
        // (an agent tab, a worktree, a plain terminal) — the grid's auto-fill
        // wants them. The first roster after a boot is the baseline, not
        // news; container tabs aren't tmux windows the grid can show.
        let indices = Set(tabs.map(\.index))
        let created: [GuestTab] = knownWindowIndices.map { known in
            tabs.filter { !known.contains($0.index) && $0.containerID == nil }
        } ?? []
        knownWindowIndices = indices
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
        if !created.isEmpty, let onNewTerminals {
            let fresh = Set(created.map(\.index))
            onNewTerminals(model.tabs.filter { fresh.contains($0.index) })
        }
    }

    /// The tmux window indices of the last live roster; nil until one has
    /// landed since the last boot, so the windows a boot restores don't
    /// count as created.
    private var knownWindowIndices: Set<Int>?
    /// Terminals created since the previous roster (model tabs, so their
    /// labels are the shown ones). The window feeds the grid's auto-fill.
    var onNewTerminals: (([TabsModel.Tab]) -> Void)?

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

    func applyDockerVolumes(_ volumes: [DockerVolume]) {
        if model.dockerVolumes != volumes { model.dockerVolumes = volumes }
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

    /// Run a host-owned keychord by its bare key ("t"/"w"/"n"/"d"/"1"…"9").
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
        case "d":
            if fire { acDelegate?.addActiveTerminalToGrid(in: self) }
            return true
        case "n":
            if fire { acDelegate?.openProfileManagerAction(nil) }
            return true
        default:
            // ⌘1–9 follow the SIDEBAR's row numbers (tree order, container
            // tabs excluded) so the chord labels next to the rows stay true.
            guard let n = Int(key), (1...9).contains(n) else { return false }
            let ordered = worktreeDisplayOrdered(model.tabs)
                .filter { $0.tab.containerID == nil }
            guard ordered.indices.contains(n - 1) else { return false }
            if fire { switchTo(index: ordered[n - 1].idx) }
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
