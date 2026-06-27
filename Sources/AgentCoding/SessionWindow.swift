import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Tabs model

/// Observable model backing a TabbedSessionWindow. Each tab represents a
/// separate kitty process inside the SAME VM — switching tabs just
/// raises that tab's kitty window via the outbox-driven guest agent.
@MainActor
@Observable
final class TabsModel {
    @MainActor
    @Observable
    final class Tab: Identifiable {
        let id: UUID
        // @Observable makes per-property changes drive SwiftUI redraws,
        // so updating `label` from the title-poll path live-refreshes
        // the pill without us having to replace the array slot.
        var label: String
        init(label: String, id: UUID = UUID()) {
            self.label = label
            self.id = id
        }
    }

    var tabs: [Tab] = []
    var activeIndex: Int = 0
    var accentHex: String = "#3B82F6"
    /// Most recent VM IP reported by the guest's xinitrc loop. Surfaced
    /// in the toolbar; click to copy.
    var ipAddress: String?
    /// Drives the red toolbar indicator. True when the Mac is enrolled
    /// with bromure.io AND this session's profile is NOT in private
    /// mode — i.e. session metadata is being shipped upstream.
    /// ACAppDelegate.refreshStreamingState() pushes updates here.
    var streamingActive: Bool = false

    /// True when ≥2 providers have a usable credential — gates whether the
    /// title-bar lightning toggle can be engaged (it's always shown).
    var fusionConfigurable: Bool = false
    /// Runtime on/off for Fusion this session. Only meaningful when
    /// `fusionConfigurable`. Flipped by the lightning toggle; mirrored into
    /// the MITM engine so the proxy hot path sees the change.
    var fusionEngaged: Bool = false

    /// Local-inference engine status for this session's title-bar badge.
    /// nil = no local model (cloud session), so the badge is hidden.
    var engineStatus: EngineStatus?
    enum EngineStatus: Equatable {
        case starting(String)   // provisioning / loading the model
        case ready(String)      // serving (model label)
        case failed(String)
    }

    var activeTab: Tab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }
}

// MARK: - Window

/// One window per profile, holding multiple kitty *processes inside the
/// same VM* as macOS-native tabs in the unified titlebar. The shared
/// VZVirtualMachineView is the contentView; tab clicks are forwarded to
/// the in-VM agent (via the bromure-outbox channel) which raises the
/// matching kitty window.
@MainActor
final class TabbedSessionWindow: NSWindow {
    /// The profile the running VM was launched with. `applyLiveProfileUpdates`
    /// rebinds this when the user saves the editor; everything in-flight
    /// (close action, MITM lookups keyed off `profile.id`, etc.) sees the
    /// new values without needing a restart.
    var profile: Profile
    let model = TabsModel()
    weak var acDelegate: ACAppDelegate?
    private var toolbarChromeDelegate: TabsToolbarDelegate?

    /// The single shared VM display — all kittys for this window render
    /// into this view because they all live in the same X session.
    let vmView: VZVirtualMachineView

    /// Wraps `vmView` so we can toggle decorations (currently the
    /// investigation-mode red frame and the suspended-VM tint) without
    /// touching the VZ view's own layer — see the long comment in
    /// `init` about why we don't poke VZVirtualMachineView's layer
    /// directly.
    private let vmContainer: NSView

    /// Red translucent overlay sat on top of the VZ framebuffer while
    /// the VM is paused for a compromise alert. Built once, hidden by
    /// default; the compromise handler toggles its visibility.
    private let suspendedTintView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        // Apple's systemRed in 35% alpha — visible enough that the
        // user can't miss "the framebuffer is frozen and tinted",
        // light enough that the underlying console output is still
        // legible for forensics.
        v.layer?.backgroundColor = NSColor.systemRed
            .withAlphaComponent(0.35).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// The single sandbox backing this whole window, set by ACAppDelegate
    /// after the VM starts; nil while booting. The *canonical* owner is
    /// ACAppDelegate's `runningSessions` registry (keyed by profile id) — this
    /// is just a per-window borrow, so when the window closes/detaches its ref
    /// drops but the registry keeps the VM alive (the persistent-agent model).
    var sandbox: UbuntuSandboxVM?

    /// Keyboard-layout bridge that ferries macOS layout changes into
    /// the guest's setxkbmap. Owned by the window so its observer
    /// lifetime matches the VM session. nil when no socket device is
    /// available yet.
    var keyboardBridge: KeyboardBridge?

    /// What `windowShouldClose` resolved from the profile's `closeAction`
    /// (with `.ask` turned into a prompt). Read by `windowWillClose` to act on
    /// the VM without re-prompting. nil for a programmatic close (compromise /
    /// relaunch) — that path detaches the window UI without touching the VM.
    var closeIntent: Profile.CloseAction?

    /// When true, the next `sandbox.onStopped` shouldn't close the
    /// window — instead, relaunch a fresh VM in the same window. Set
    /// by the toolbar's Reboot action; cleared inside the relaunch
    /// path. Distinguishes user-requested reboot from a real shutdown.
    var rebootRequested: Bool = false

    init(profile: Profile, acDelegate: ACAppDelegate) {
        self.profile = profile
        self.acDelegate = acDelegate

        let view = VZVirtualMachineView()
        // capturesSystemKeys = false means macOS handles ⌘Tab, ⌘H,
        // ⌘Space, ⌘Q etc. at the WindowServer level instead of
        // routing them to the guest. We lose F-key forwarding into
        // the VM, but agent-coding workflows almost never use F-keys
        // and ⌘Tab is constant — that trade-off is the right one.
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        self.vmView = view

        // Container has to exist before super.init so the stored
        // property is non-nil. The constraints + child view hookup
        // happen after super.init below.
        self.vmContainer = NSView()

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = profile.name
        titleVisibility = .hidden
        titlebarAppearsTransparent = false
        toolbarStyle = .unified
        model.accentHex = profile.color.hexInUI

        // Wrap the VZ view in a plain NSView container (created above
        // pre-super.init). We apply the user's opacity to the
        // *container's* layer, not the VZ view itself — touching
        // VZVirtualMachineView's own wantsLayer / layer.opacity has
        // been observed to crash AppKit's window transform animator
        // (see the animationBehavior comment below). The container
        // takes the layer alpha cleanly; the VZ framebuffer renders
        // into the container at full opacity and inherits the alpha
        // when composited. The titlebar paints separately via the
        // window chrome and is unaffected.
        let container = vmContainer
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
        // Tint overlay sits ABOVE the VZ view so it composites on top
        // of whatever the framebuffer is showing. Hidden by default;
        // the compromise handler reveals it the moment the VM is
        // paused so the frozen frame visibly reads as "stopped, do
        // not trust this".
        container.addSubview(suspendedTintView)
        NSLayoutConstraint.activate([
            suspendedTintView.topAnchor.constraint(equalTo: container.topAnchor),
            suspendedTintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            suspendedTintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            suspendedTintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = container

        // Disable AppKit's default window animations. AppKit's
        // _NSWindowTransformAnimation has been observed to over-release
        // its block ivar inside the autorelease pool drain when the
        // contentView is a layer-hosted VZVirtualMachineView (crash:
        // `objc_release` from `-[NSConcretePointerArray dealloc]` on
        // the main thread during `CA::Context::commit_transaction`).
        // Disabling the implicit animation skips that animator path
        // entirely. The browser sets the same flag for the same reason.
        animationBehavior = .none

        // Apply the requested opacity to the wrapper layer, not the
        // window's alphaValue — that way only the framebuffer area
        // (below the toolbar) blends with whatever's behind, and the
        // titlebar / toolbar stays fully opaque. The window must
        // still be non-opaque + clear-background for the alpha to
        // actually composite against the desktop instead of an opaque
        // window backing.
        let opacity = min(1.0, max(0.3, profile.windowOpacity))
        container.layer?.opacity = Float(opacity)
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
        }

        let delegate = TabsToolbarDelegate(
            model: model,
            sharedFolderPaths: profile.folderPaths,
            onSelect: { [weak self] in self?.switchTo(index: $0) },
            onClose:  { [weak self] in self?.closeTab(at: $0) },
            onNew:    { [weak self] in
                guard let self else { return }
                self.acDelegate?.spawnNewTab(in: self)
            },
            onInspectTrace: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openTraceInspector(for: self.profile)
            },
            onReboot: { [weak self] in
                guard let self else { return }
                self.acDelegate?.requestReboot(for: self)
            },
            onFiles: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openFileBrowser(for: self)
            },
            onEditProfile: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openEditorWindow(editing: self.profile)
            },
            onToggleFusion: { [weak self] engaged in
                guard let self else { return }
                self.acDelegate?.setFusionEngaged(engaged, for: self.profile)
            })
        toolbarChromeDelegate = delegate

        let bar = NSToolbar(identifier: "io.bromure.ac.tabs")
        bar.delegate = delegate
        bar.displayMode = .iconOnly
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        bar.autosavesConfiguration = false
        self.toolbar = bar
    }

    /// Show / hide the red tint overlay on the framebuffer. Called
    /// by the compromise handler around the pause + alert window so
    /// the user sees the frame is frozen and tainted, not just
    /// happens-to-be-still.
    func setSuspendedTint(_ on: Bool) {
        suspendedTintView.isHidden = !on
    }

    /// Re-bind `profile` to a freshly-saved version and re-apply the
    /// host-side window state that depends on it. Call this whenever
    /// the user saves the profile editor while a session is open —
    /// settings that don't affect the booted VM (window title /
    /// tint / opacity, accent color, close-on-quit behaviour, comments)
    /// pick up the change without a restart. Settings baked into the
    /// VM image (memory, network, kitty font, gitconfig, env vars,
    /// shared folders, …) are out of reach here; the caller is
    /// responsible for prompting the user to restart for those.
    func applyLiveProfileUpdates(_ newProfile: Profile) {
        profile = newProfile

        title = newProfile.name
        model.accentHex = newProfile.color.hexInUI

        let opacity = min(1.0, max(0.3, newProfile.windowOpacity))
        vmContainer.layer?.opacity = Float(opacity)
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
        } else {
            // Restore the standard opaque chrome so the framebuffer
            // doesn't keep blending with the desktop after the user
            // dialled opacity back to 1.0.
            isOpaque = true
            backgroundColor = nil
        }
    }

    /// Has a populated tmux window list been seen yet this session. Until it
    /// has, an empty list means "tmux not up yet" (don't power off), not "all
    /// tabs closed".
    private var sawTabList = false

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
    /// position (base-index 0 + renumber-windows on), so the array index is the
    /// target. Highlight optimistically; the next roster tick confirms.
    func switchTo(index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        model.activeIndex = index
        acDelegate?.requestSelectTab(index: index, in: self)
    }

    /// Close a tab → tmux kill-window. The roster removes the pill. Closing the
    /// last tab ends the session, so route through the profile's close-action
    /// pipeline (suspend / background / shutdown).
    func closeTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        acDelegate?.requestCloseTab(index: index, in: self)
        if model.tabs.count <= 1 {
            performClose(nil)
        }
    }

    /// Mirror the guest's tmux window list as the tab bar. This is the WHOLE
    /// tab model now — tmux is authoritative, so there's no liveness guessing,
    /// grace periods, or reaping. Pill objects are reused by position so
    /// SwiftUI keeps stable row identity (no flicker).
    func applyTabList(_ tabs: [(index: Int, active: Bool, label: String)]) {
        if rebootRequested { return }
        guard !tabs.isEmpty else {
            // tmux is gone — the last window was closed (or the VM is shutting
            // down). Only act once we've seen a populated list this session, so
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
            model.tabs.append(TabsModel.Tab(label: tabs[model.tabs.count].label))
        }
        for (i, t) in tabs.enumerated() where model.tabs[i].label != t.label {
            model.tabs[i].label = t.label
        }
        if let activePos = tabs.firstIndex(where: { $0.active }), model.activeIndex != activePos {
            model.activeIndex = activePos
        }
        if model.activeIndex >= model.tabs.count {
            model.activeIndex = max(0, model.tabs.count - 1)
        }
    }

    /// Per-key timestamp of the last host-owned chord *seen* — whether it
    /// fired or was suppressed — feeding `acAutorepeatGuard`. Cross-path
    /// duplicates are handled structurally by `vmHasKeyboardFocus` gating, not
    /// here; this only collapses a single path's autorepeat.
    private var lastShortcutAt: [String: Date] = [:]

    /// True when this window is key AND the embedded VZ view holds keyboard
    /// focus — i.e. a keystroke is being delivered into the guest. In that
    /// state host-owned chords (⌘T/⌘W/⌘N/⌘1-9) must NOT be acted on by the
    /// host key monitor / `sendEvent`: the chord reaches the guest, Openbox
    /// grabs it, and the bounce (`UbuntuSandboxVM.onShortcut` →
    /// `performACShortcut`) runs the action. Acting in BOTH places double-
    /// processes one press — e.g. ⌘T spawning two kittys that then race on X
    /// startup (one bails with a BadWindow), or ⌘W closing two tabs. When a
    /// native control holds focus instead, the chord never reaches the guest,
    /// so this is false and the monitor/sendEvent path is the one that acts.
    var vmHasKeyboardFocus: Bool {
        guard isKeyWindow, let fr = firstResponder as? NSView else { return false }
        return fr === vmView || fr.isDescendant(of: vmView)
    }

    /// Run a host-owned keychord by its bare key ("t" / "w" / "n" / "1"…"9").
    /// Single sink shared by BOTH routes that can deliver one:
    ///   • the host key monitor / `sendEvent` (when a native control in the
    ///     session window holds focus), and
    ///   • the guest bounce via `UbuntuSandboxVM.onShortcut` (when the VM
    ///     holds focus and Openbox grabbed the chord).
    /// Funnelling them through one method is what stops the ⌘T action from
    /// drifting between paths. Returns true when the key matched (and the
    /// event, if any, should be consumed).
    @discardableResult
    func performACShortcut(_ key: String, isRepeat: Bool = false) -> Bool {
        // `isRepeat` is only known on the native NSEvent path; the guest bounce
        // can't carry it, so `acAutorepeatGuard` is the backstop there. Either
        // way the chord is still *consumed* (we return true for an owned key) —
        // only the action is gated, so a suppressed repeat never leaks to the
        // guest's kitty.
        let fire = !isRepeat && acAutorepeatGuard(key)
        switch key {
        case "t":
            if fire { acDelegate?.spawnNewTab(in: self) }
            return true
        case "w":
            if fire { closeTab(at: model.activeIndex) }
            return true
        case "n":
            // ⌘N → profile picker / "new session".
            if fire { acDelegate?.openProfileManagerAction(nil) }
            return true
        default:
            guard let n = Int(key), (1...9).contains(n),
                  model.tabs.indices.contains(n - 1) else { return false }
            if fire { switchTo(index: n - 1) }
            return true
        }
    }

    /// Leading-edge autorepeat filter for the guest-bounce path, which — unlike
    /// the native NSEvent path's `isARepeat` — has no flag distinguishing a
    /// held chord from a deliberate re-press. X11 repeats a held chord ~every
    /// 40ms; a deliberate re-press is ≥~120ms apart, so an 80ms window passes
    /// real presses but swallows autorepeat. The per-key timestamp is refreshed
    /// on EVERY call — including suppressed ones — so a held key keeps resetting
    /// the window and fires once, rather than re-firing every 80ms.
    private func acAutorepeatGuard(_ key: String) -> Bool {
        let now = Date()
        defer { lastShortcutAt[key] = now }
        guard let prev = lastShortcutAt[key] else { return true }
        return now.timeIntervalSince(prev) >= 0.08
    }

    /// ⌘T / ⌘W / ⌘1-9 / ⌘N dispatch for `sendEvent`, `performKeyEquivalent`
    /// and the app delegate's NSEvent monitor (the native-focus path; the VM-
    /// focus path comes through the guest bounce → `performACShortcut`).
    /// Returns true when the shortcut matched and the event should be consumed.
    ///
    /// The relaxed-modifier mask matches ACAppDelegate.interceptKey:
    /// capsLock / numericPad / help / function leak in unrelated bits
    /// that a strict `== [.command]` would reject, which made ⌘T / ⌘W
    /// appear intermittent in the past.
    func handleACShortcut(_ event: NSEvent) -> Bool {
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(userMods)
        guard mods == [.command] else { return false }
        // VM has focus → the chord reaches the guest and comes back via the
        // bounce. Don't also act here (return false → fall through to the VZ
        // view). See `vmHasKeyboardFocus`.
        if vmHasKeyboardFocus { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return performACShortcut(chars, isRepeat: event.isARepeat)
    }

    /// Last-resort intercept for ⌘T / ⌘W / ⌘1-9. NSWindow.sendEvent
    /// runs before performKeyEquivalent and before the responder chain
    /// dispatches keyDown to the VZ view, so this catches the event
    /// even in focus states where the app-level NSEvent monitor failed
    /// to fire (observed when VZVirtualMachineView has just captured
    /// input — the keystroke reaches the window but bypasses earlier
    /// hooks). Without this, ⌘T sometimes leaked through to the guest's
    /// kitty (which maps super+t → new_tab inside the terminal) and
    /// the user saw "Cmd-T did nothing" until they clicked the titlebar
    /// to break VZ's capture state.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleACShortcut(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleACShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Toolbar delegate

private let tabsToolbarItemID = NSToolbarItem.Identifier("io.bromure.ac.tabsItem")

@MainActor
final class TabsToolbarDelegate: NSObject, NSToolbarDelegate {
    let model: TabsModel
    let sharedFolderPaths: [String]
    let onSelect: (Int) -> Void
    let onClose:  (Int) -> Void
    let onNew:    () -> Void
    let onInspectTrace: () -> Void
    let onReboot: () -> Void
    let onFiles:  () -> Void
    let onEditProfile: () -> Void
    let onToggleFusion: (Bool) -> Void

    init(model: TabsModel,
         sharedFolderPaths: [String],
         onSelect: @escaping (Int) -> Void,
         onClose:  @escaping (Int) -> Void,
         onNew:    @escaping () -> Void,
         onInspectTrace: @escaping () -> Void,
         onReboot: @escaping () -> Void,
         onFiles:  @escaping () -> Void,
         onEditProfile: @escaping () -> Void,
         onToggleFusion: @escaping (Bool) -> Void) {
        self.model = model
        self.sharedFolderPaths = sharedFolderPaths
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNew = onNew
        self.onInspectTrace = onInspectTrace
        self.onReboot = onReboot
        self.onFiles = onFiles
        self.onEditProfile = onEditProfile
        self.onToggleFusion = onToggleFusion
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsToolbarItemID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsToolbarItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard id == tabsToolbarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let host = FlexibleHostingView(rootView: TabsBar(
            model: model,
            sharedFolderPaths: sharedFolderPaths,
            onSelect: onSelect,
            onClose:  onClose,
            onNew:    onNew,
            onInspectTrace: onInspectTrace,
            onReboot: onReboot,
            onFiles:  onFiles,
            onEditProfile: onEditProfile,
            onToggleFusion: onToggleFusion
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        item.visibilityPriority = .high
        item.label = ""
        item.paletteLabel = "Tabs"
        return item
    }
}

/// NSHostingView that hides its width from AppKit so NSToolbar doesn't
/// size the toolbar item to the SwiftUI content's intrinsic width.
final class FlexibleHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        return NSSize(width: NSView.noIntrinsicMetric, height: inner.height)
    }
}

// MARK: - Tab bar SwiftUI (capsule layout, browser-style)

private struct TabsBar: View {
    let model: TabsModel
    let sharedFolderPaths: [String]
    let onSelect: (Int) -> Void
    let onClose:  (Int) -> Void
    let onNew:    () -> Void
    let onInspectTrace: () -> Void
    let onReboot: () -> Void
    let onFiles:  () -> Void
    let onEditProfile: () -> Void
    let onToggleFusion: (Bool) -> Void

    @State private var foldersPopoverShown = false

    var body: some View {
        HStack(spacing: 6) {
            // Outer capsule pill containing the tab strip — matches the
            // browser's "outer grey capsule" idiom.
            HStack(spacing: 4) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { idx, tab in
                    TabCapsule(
                        label: tab.label,
                        isActive: idx == model.activeIndex,
                        accentHex: model.accentHex,
                        onSelect: { onSelect(idx) },
                        onClose:  { onClose(idx) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))

            Button(action: onNew) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New tab (⌘T)")

            Spacer(minLength: 8)

            // Red recording-style dot when the proxy is shipping
            // session metadata to bromure.io. Mirrors Bromure Web's
            // managed-mode indicator. Hidden in private mode, hidden
            // when the Mac isn't enrolled. The decision lives in
            // ACAppDelegate.refreshStreamingState() so this view
            // just renders the latest flag.
            if model.streamingActive {
                StreamingIndicator()
            }

            // Local-inference engine status (warming / ready / failed).
            if let status = model.engineStatus {
                EngineStatusBadge(status: status)
            }

            // Fusion toggle — ALWAYS present. Three states:
            //   • not configurable (<2 usable models): hollow bolt, disabled;
            //   • configurable + disengaged: filled bolt, dark grey;
            //   • engaged: filled bolt, yellow.
            Button {
                guard model.fusionConfigurable else { return }
                model.fusionEngaged.toggle()
                onToggleFusion(model.fusionEngaged)
            } label: {
                Image(systemName: model.fusionConfigurable ? "bolt.fill" : "bolt")
                    .foregroundStyle(
                        !model.fusionConfigurable ? Color.secondary
                            : (model.fusionEngaged ? Color.yellow : Color(nsColor: .darkGray)))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!model.fusionConfigurable)
            .help(!model.fusionConfigurable
                ? NSLocalizedString("To enable Fusion you need to have at least two models enabled.",
                                    comment: "Fusion toggle tooltip, not configurable")
                : (model.fusionEngaged
                    ? NSLocalizedString("Fusion engaged — answers are synthesized across your selected models. Click to disengage.",
                                        comment: "Fusion toggle tooltip, engaged")
                    : NSLocalizedString("Fusion available — disengaged. Click to engage multi-model synthesis.",
                                        comment: "Fusion toggle tooltip, disengaged")))

            if let ip = model.ipAddress {
                IPChip(ip: ip)
            } else {
                Text("…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Waiting for VM to report its IP")
            }

            // Shared folders — only present when the profile actually
            // mounts something into the VM. Click reveals a popover
            // listing each host folder; click a row to open in Finder.
            if !sharedFolderPaths.isEmpty {
                Button {
                    foldersPopoverShown.toggle()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Shared folders mounted in the VM", comment: ""))
                .popover(isPresented: $foldersPopoverShown, arrowEdge: .bottom) {
                    SharedFoldersList(paths: sharedFolderPaths)
                }
            }

            // File browser — Finder-like panel over the guest's
            // /home/ubuntu (and shared folders), for dragging files in
            // and out of the VM.
            Button(action: onFiles) {
                Image(systemName: "externaldrive")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Browse files in the VM (drag to copy in/out)",
                                     comment: ""))

            // Reboot — opens a confirm dialog (soft via `sudo reboot`
            // inside the guest, hard via `vm.stop()` on the host).
            Button(action: onReboot) {
                Image(systemName: "arrow.clockwise.circle")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Reboot the VM", comment: ""))

            // Trace inspector — opens the global window pre-filtered
            // to this profile. Mirrors the browser's per-window
            // inspector affordance.
            Button(action: onInspectTrace) {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Inspect this profile's session trace (⇧⌘I)", comment: ""))

            // Settings — opens the profile editor for the running VM's
            // profile. Edits to host-side settings apply live; settings
            // baked into the VM image prompt for a restart on save.
            Button(action: onEditProfile) {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Edit this profile's settings", comment: ""))
        }
    }
}

/// Popover content listing the host paths the VM has mounted via
/// virtiofs. Each row opens the folder in Finder when clicked.
private struct SharedFoldersList: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString("Shared folders", comment: ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
            VStack(spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    SharedFolderRow(path: path)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320)
    }
}

private struct SharedFolderRow: View {
    let path: String
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(abbreviated(path))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.gray.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path)
    }

    private func abbreviated(_ p: String) -> String {
        (p as NSString).abbreviatingWithTildeInPath
    }
}

/// Red dot signalling the proxy is streaming session metadata to
/// bromure.io for this profile. Pulses gently so it doesn't blend
/// into the toolbar background. Tooltip explains the why.
/// Title-bar badge for the local inference engine: a spinner while it warms
/// up (provisioning / loading the model), a green chip once serving, or an
/// orange warning if it failed to start.
private struct EngineStatusBadge: View {
    let status: TabsModel.EngineStatus
    var body: some View {
        switch status {
        case .starting(let detail):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Image(systemName: "cpu").foregroundStyle(.secondary)
            }
            .help(detail)
        case .ready(let model):
            Image(systemName: "cpu.fill")
                .foregroundStyle(.green)
                .help(String(format: NSLocalizedString("Local model ready — serving %@.", comment: ""), model))
        case .failed(let msg):
            Image(systemName: "cpu")
                .foregroundStyle(.orange)
                .help(String(format: NSLocalizedString("Local engine failed to start: %@", comment: ""), msg))
        }
    }
}

private struct StreamingIndicator: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 1.0 : 0.55)
            .shadow(color: .red.opacity(0.6), radius: pulse ? 3 : 0)
            .help(NSLocalizedString(
                "Session metadata is being sent to bromure.io. Toggle the profile's Private Mode to stop streaming.",
                comment: "BAC streaming indicator tooltip"))
            .padding(.horizontal, 4)
            .accessibilityLabel(NSLocalizedString(
                "Streaming to bromure.io", comment: "BAC streaming indicator a11y"))
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse.toggle()
            } }
    }
}

/// Small monospace pill showing the VM's IPv4. Click to copy.
private struct IPChip: View {
    let ip: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "network")
                    .font(.system(size: 10))
                Text(copied ? "Copied" : ip)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.gray.opacity(0.15)))
        }
        .buttonStyle(.borderless)
        .help("VM IP — click to copy")
    }
}

private struct TabCapsule: View {
    let label: String
    let isActive: Bool
    let accentHex: String
    let onSelect: () -> Void
    let onClose:  () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .lineLimit(1)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(hovering ? Color.gray.opacity(0.2) : .clear, in: Circle())
            }
            .buttonStyle(.borderless)
            .opacity(isActive || hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                isActive
                ? Color(nsColor: .textBackgroundColor)
                : (hovering ? Color.gray.opacity(0.10) : .clear)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isActive ? Color(hex: accentHex).opacity(0.55) : .clear,
                lineWidth: 1.5
            )
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Helpers

extension ProfileColor {
    /// Hex form for use in the AppKit/SwiftUI mix.
    var hexInUI: String {
        switch self {
        case .blue:   "#3B82F6"
        case .red:    "#EF4444"
        case .green:  "#22C55E"
        case .orange: "#F97316"
        case .purple: "#A855F7"
        case .pink:   "#EC4899"
        case .teal:   "#14B8A6"
        case .gray:   "#6B7280"
        }
    }
}
