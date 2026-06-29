import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Docker

/// One running container reported by the guest's `docker ps` loop, mirrored into
/// `TabsModel.dockerContainers` and rendered as a sub-tree under the workspace's
/// tabs in the source-list.
public struct DockerContainer: Identifiable, Equatable {
    public let id: String       // full container id — used for `docker exec`
    public var name: String
    public var image: String
    public var status: String   // e.g. "Up 3 minutes" / "Exited (0) 2m ago"
    public var state: String    // "running", "exited", "paused", "created", …
    public var ports: String
    public var runningFor: String   // "2 hours ago" / "5 minutes ago"
    /// Filled from `docker stats` (gated, dashboard-only); "" when unknown.
    public var cpuPerc: String
    public var memUsage: String
    public var shortID: String { String(id.prefix(12)) }
    public var isRunning: Bool { state == "running" }
    /// CPU as a number (docker reports "12.34%"); nil while unknown.
    public var cpuValue: Double? { Double(cpuPerc.replacingOccurrences(of: "%", with: "")) }

    public init(id: String, name: String, image: String, status: String,
                state: String, ports: String, runningFor: String = "",
                cpuPerc: String = "", memUsage: String = "") {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.state = state
        self.ports = ports
        self.runningFor = runningFor
        self.cpuPerc = cpuPerc
        self.memUsage = memUsage
    }
}

/// One local docker image, from `docker images` — feeds the dashboard's Images
/// view and the new-container picker.
public struct DockerImage: Identifiable, Equatable {
    public let id: String           // image id (sha)
    public var repository: String   // "nginx" / "<none>"
    public var tag: String          // "latest" / "<none>"
    public var size: String         // "142MB"
    public var created: String      // "2 days ago"
    /// "repo:tag" — the ref you'd `docker run`; falls back to the id when untagged.
    public var ref: String {
        repository != "<none>" && tag != "<none>" ? "\(repository):\(tag)" : String(id.prefix(12))
    }

    public init(id: String, repository: String, tag: String, size: String, created: String) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.size = size
        self.created = created
    }
}

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
        /// The real tmux window index — used for select/close (windows can have
        /// gaps after closes, so position ≠ index).
        var index: Int
        /// Set when this tab is a `docker exec` attach window (tmux @container
        /// option); such tabs are nested under their container in the source-list
        /// instead of shown as a top-level tab.
        var containerID: String?
        init(label: String, index: Int = 0, containerID: String? = nil, id: UUID = UUID()) {
            self.label = label
            self.index = index
            self.containerID = containerID
            self.id = id
        }
    }

    var tabs: [Tab] = []
    var activeIndex: Int = 0

    /// All docker containers in this VM (running + stopped), refreshed ~every 2s
    /// from the guest. Drives the source-list Docker sub-tree and the dashboard.
    var dockerContainers: [DockerContainer] = []
    /// Local docker images — only refreshed while a dashboard is open (gated).
    var dockerImages: [DockerImage] = []
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

    /// True while the agent is actively calling the model (driven by the MITM
    /// proxy's conversation-request signal, auto-cleared a few seconds after the
    /// last call). Drives the animated "thinking" dots in the sidebar.
    var thinking: Bool = false

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

/// A standalone window hosting a *single* `SessionPane` — its VM's framebuffer
/// in the content area and that VM's tabs as a pill strip in the unified
/// titlebar. Used as the popped-out ("detach to its own window") host and by
/// the registration coordinator's headless scratch session. The unified
/// multi-VM window (`UnifiedSessionWindow`) hosts panes directly instead.
///
/// All the per-VM state and logic lives on `pane`; this class keeps its old
/// public surface as thin forwards so existing call sites are unchanged.
@MainActor
final class TabbedSessionWindow: NSWindow, SessionPaneHost {
    /// The one pane this window draws. Created in `init`; owns the VZ view, the
    /// tab model, and all tab/shortcut logic.
    let pane: SessionPane
    weak var acDelegate: ACAppDelegate?
    private var toolbarChromeDelegate: TabsToolbarDelegate?

    // MARK: Forwards to the pane (preserve the historical public API)

    var profile: Profile {
        get { pane.profile }
        set { pane.profile = newValue }
    }
    var model: TabsModel { pane.model }
    var vmView: VZVirtualMachineView { pane.vmView }
    var sandbox: UbuntuSandboxVM? {
        get { pane.sandbox }
        set { pane.sandbox = newValue }
    }
    var keyboardBridge: KeyboardBridge? {
        get { pane.keyboardBridge }
        set { pane.keyboardBridge = newValue }
    }
    var scrollBridge: ScrollBridge? {
        get { pane.scrollBridge }
        set { pane.scrollBridge = newValue }
    }
    var closeIntent: Profile.CloseAction? {
        get { pane.closeIntent }
        set { pane.closeIntent = newValue }
    }
    var rebootRequested: Bool {
        get { pane.rebootRequested }
        set { pane.rebootRequested = newValue }
    }
    var vmHasKeyboardFocus: Bool { pane.vmHasKeyboardFocus }

    func setSuspendedTint(_ on: Bool) { pane.setSuspendedTint(on) }
    func applyLiveProfileUpdates(_ newProfile: Profile) { pane.applyLiveProfileUpdates(newProfile) }
    func rehydrateTabs(from state: SessionDisk.TabsState) { pane.rehydrateTabs(from: state) }
    func snapshotTabs() -> SessionDisk.TabsState { pane.snapshotTabs() }
    func switchTo(index: Int) { pane.switchTo(index: index) }
    func closeTab(at index: Int) { pane.closeTab(at: index) }
    func applyTabList(_ tabs: [(index: Int, active: Bool, label: String, containerID: String?)]) { pane.applyTabList(tabs) }
    @discardableResult
    func performACShortcut(_ key: String, isRepeat: Bool = false) -> Bool {
        pane.performACShortcut(key, isRepeat: isRepeat)
    }

    /// When true, `windowWillClose` must NOT tear the VM down — the pane is
    /// being moved back into the unified window, not closed.
    var redocking = false

    convenience init(profile: Profile, acDelegate: ACAppDelegate) {
        self.init(adopting: SessionPane(profile: profile, acDelegate: acDelegate),
                  acDelegate: acDelegate)
    }

    /// Adopt an existing pane (pop-out): the pane keeps its VM + tab model; only
    /// its host window changes. The caller must have unmounted the pane's
    /// `containerView` from its previous superview first.
    init(adopting pane: SessionPane, acDelegate: ACAppDelegate) {
        self.pane = pane
        self.acDelegate = acDelegate
        let profile = pane.profile

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        pane.host = self
        title = profile.name
        titleVisibility = .hidden
        // Browser parity: transparent unified titlebar + movable-by-background
        // makes the toolbar's empty/pill-capsule areas drag the window.
        titlebarAppearsTransparent = true
        toolbarStyle = .unified
        isMovableByWindowBackground = true

        contentView = pane.containerView

        // Disable AppKit's default window animations. AppKit's
        // _NSWindowTransformAnimation has been observed to over-release its
        // block ivar inside the autorelease pool drain when the contentView is a
        // layer-hosted VZVirtualMachineView. Disabling the implicit animation
        // skips that animator path entirely.
        animationBehavior = .none

        applyOpacityChrome(for: profile)

        let delegate = TabsToolbarDelegate(
            model: pane.model,
            sharedFolderPaths: profile.folderPaths,
            onSelect: { [weak self] in self?.pane.switchTo(index: $0) },
            onClose:  { [weak self] in self?.pane.closeTab(at: $0) },
            onNew:    { [weak self] in
                guard let self else { return }
                self.acDelegate?.spawnNewTab(in: self.pane)
            },
            onInspectTrace: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openTraceInspector(for: self.pane.profile)
            },
            onReboot: { [weak self] in
                guard let self else { return }
                self.acDelegate?.requestReboot(for: self.pane)
            },
            onFiles: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openFileBrowser(for: self)
            },
            onEditProfile: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openEditorWindow(editing: self.pane.profile)
            },
            onToggleFusion: { [weak self] engaged in
                guard let self else { return }
                self.acDelegate?.setFusionEngaged(engaged, for: self.pane.profile)
            },
            onRedock: { [weak self] in
                guard let self else { return }
                self.acDelegate?.redockVM(self.pane.profile.id)
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

    /// Apply the profile's window opacity to the chrome. The framebuffer alpha
    /// itself lives on the pane's container layer; this only flips the window
    /// to non-opaque/clear so that alpha composites against the desktop rather
    /// than an opaque backing.
    private func applyOpacityChrome(for profile: Profile) {
        let opacity = min(1.0, max(0.3, profile.windowOpacity))
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
        } else {
            isOpaque = true
            backgroundColor = nil
        }
    }

    /// Hand the pane back so it can be re-mounted in the unified window. Unmounts
    /// the framebuffer container and detaches host ownership; the subsequent
    /// `close()` is guarded by `redocking` so the VM isn't torn down.
    func releasePaneForRedock() {
        redocking = true
        if pane.containerView.superview != nil { pane.containerView.removeFromSuperview() }
        if pane.host === self { pane.host = nil }
        contentView = NSView()
    }

    // MARK: - SessionPaneHost

    var paneHostWindow: NSWindow? { self }

    func paneRequestsClose(_ pane: SessionPane) {
        // Last-tab ⌘W / relaunch failure: defer to the regular performClose
        // pipeline so `windowShouldClose` reads the profile's `closeAction`.
        performClose(nil)
    }

    func paneDidUpdateProfile(_ pane: SessionPane) {
        title = pane.profile.name
        applyOpacityChrome(for: pane.profile)
    }

    // MARK: - Shortcut interception

    /// ⌘T / ⌘W / ⌘1-9 / ⌘N dispatch for `sendEvent`, `performKeyEquivalent` and
    /// the app delegate's NSEvent monitor (the native-focus path; the VM-focus
    /// path comes through the guest bounce → `pane.performACShortcut`). Returns
    /// true when the shortcut matched and the event should be consumed.
    func handleACShortcut(_ event: NSEvent) -> Bool {
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(userMods)
        guard mods == [.command] else { return false }
        // VM has focus → the chord reaches the guest and comes back via the
        // bounce. Don't also act here.
        if pane.vmHasKeyboardFocus { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return pane.performACShortcut(chars, isRepeat: event.isARepeat)
    }

    /// Last-resort intercept for ⌘T / ⌘W / ⌘1-9. NSWindow.sendEvent runs before
    /// performKeyEquivalent and before the responder chain dispatches keyDown to
    /// the VZ view, so this catches the event even in focus states where the
    /// app-level NSEvent monitor failed to fire.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        installOpaqueTitlebarBacking()
    }

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
    let onRedock: () -> Void

    init(model: TabsModel,
         sharedFolderPaths: [String],
         onSelect: @escaping (Int) -> Void,
         onClose:  @escaping (Int) -> Void,
         onNew:    @escaping () -> Void,
         onInspectTrace: @escaping () -> Void,
         onReboot: @escaping () -> Void,
         onFiles:  @escaping () -> Void,
         onEditProfile: @escaping () -> Void,
         onToggleFusion: @escaping (Bool) -> Void,
         onRedock: @escaping () -> Void) {
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
        self.onRedock = onRedock
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
            onToggleFusion: onToggleFusion,
            onRedock: onRedock
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
    let onRedock: () -> Void

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
            .help(NSLocalizedString("Inspect this workspace's session trace (⇧⌘I)", comment: ""))

            // Settings — opens the profile editor for the running VM's
            // profile. Edits to host-side settings apply live; settings
            // baked into the VM image prompt for a restart on save.
            Button(action: onEditProfile) {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Edit this workspace's settings", comment: ""))

            // Re-dock — fold this popped-out VM back into the unified window.
            Button(action: onRedock) {
                Image(systemName: "arrow.down.right.and.arrow.up.left.rectangle")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Move this VM back into the main window", comment: ""))
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
                "Session metadata is being sent to bromure.io. Toggle the workspace's Private Mode to stop streaming.",
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
