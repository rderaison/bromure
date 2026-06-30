import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Sidebar list model

/// Drives the unpeel-style source-list. One `VMEntry` per running VM hosted in
/// the unified window; each entry carries the pane's live `TabsModel` so the
/// nested tab rows update in place.
@MainActor
@Observable
final class SessionListModel {
    @MainActor
    @Observable
    final class VMEntry: Identifiable {
        let id: Profile.ID
        var name: String
        var accentHex: String
        /// The pane's tab model — shared by reference, so tab labels / active
        /// index / thinking state refresh the sidebar rows live.
        let model: TabsModel
        init(id: Profile.ID, name: String, accentHex: String, model: TabsModel) {
            self.id = id
            self.name = name
            self.accentHex = accentHex
            self.model = model
        }
    }

    /// Per-profile run state shown in the source list.
    enum RunState { case off, booting, running, suspended }

    /// One row per profile — running or not. Rebuilt wholesale by the
    /// delegate's `refreshSidebar()`; a running row pairs (by id) with a
    /// `VMEntry` that carries the live tab model for its nested tab rows.
    struct ProfileRow: Identifiable, Equatable {
        let id: Profile.ID
        var name: String
        var accentHex: String
        var state: RunState
        var compromised: Bool
    }

    /// Running, attached panes — carry live tab models.
    var entries: [VMEntry] = []
    /// Every profile, in display order — the source list's top level.
    var profileRows: [ProfileRow] = []
    var selectedID: Profile.ID?
    /// Set when a VM's Docker dashboard is the active stage surface — highlights
    /// that VM's Docker node in the source list.
    var dockerSelectedID: Profile.ID?
}

/// Coarse per-tab activity derived from the foreground program tmux reports as
/// the window label — honest signal from data we already have, no guest change.
enum TabActivity {
    case agent      // a coding agent is in the foreground
    case shell      // an idle shell / other program

    private static let agentBinaries: Set<String> = [
        "claude", "codex", "grok", "aider", "goose", "amp", "opencode",
        "gemini", "cursor", "llm", "ollama", "node", "python", "python3",
    ]

    init(label: String) {
        let head = label.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init) ?? ""
        self = Self.agentBinaries.contains(head) ? .agent : .shell
    }
}

extension NSWindow {
    /// Keep the titlebar opaque even when the window itself is non-opaque.
    ///
    /// Framebuffer transparency for translucent profiles needs `isOpaque = false`
    /// so the alpha composites against the desktop — but combined with a
    /// transparent titlebar (which we use for browser-style window dragging)
    /// that would make the titlebar see-through too. Injecting a solid backing as
    /// the rear-most subview of the titlebar container keeps the chrome solid
    /// while leaving only the framebuffer translucent. Idempotent.
    func installOpaqueTitlebarBacking() {
        guard let themeFrame = contentView?.superview,
              let titlebar = themeFrame.subviews.first(where: {
                  $0.className == "NSTitlebarContainerView"
              }) else { return }
        let id = NSUserInterfaceItemIdentifier("io.bromure.opaqueTitlebar")
        if titlebar.subviews.contains(where: { $0.identifier == id }) { return }
        let backing = NSView(frame: titlebar.bounds)
        backing.identifier = id
        backing.autoresizingMask = [.width, .height]
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        titlebar.addSubview(backing, positioned: .below, relativeTo: nil)
    }
}

// MARK: - Unified window

/// The shared, unpeel-style window: a left source-list of every running VM with
/// its tabs nested underneath, and a single framebuffer stage on the right
/// showing the selected tab's VM. Hosts many `SessionPane`s at once and is the
/// default home for sessions (popped-out VMs leave it for a `TabbedSessionWindow`).
@MainActor
final class UnifiedSessionWindow: NSWindow, SessionPaneHost {
    weak var acDelegate: ACAppDelegate?
    let listModel = SessionListModel()

    private var hostedPanes: [SessionPane] = []
    private(set) var selectedID: Profile.ID?

    /// Where the selected pane's framebuffer container is mounted.
    private let paneSlot: NSView
    /// The right-hand container holding the framebuffer. Its backing flips to
    /// clear for translucent profiles so the framebuffer blends to the desktop.
    private let stage = NSView()
    /// Shown when the selected profile has no mounted framebuffer — a Start
    /// card for an off/suspended profile, or a generic empty state.
    private var emptyStateHost: NSHostingView<EmptyStageView>!
    private var sidebarHost: NSHostingView<SessionSidebar>!
    /// The pane currently mounted in the stage, if any. Drives the empty state.
    private var mountedPane: SessionPane?

    /// Full-bleed overlay on top of the stage that shows the Docker dashboard
    /// for the selected VM. Hidden unless `dockerSelectedID` is set.
    private let dockerSlot = NSView()
    private var dockerHosting: NSHostingView<DockerDashboardView>?
    /// The VM whose Docker dashboard is currently shown (nil = none).
    private var dockerSelectedID: Profile.ID?
    private var toolbarDelegate: UnifiedToolbarDelegate?

    init(acDelegate: ACAppDelegate) {
        self.acDelegate = acDelegate
        self.paneSlot = NSView()

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Bromure"
        titleVisibility = .hidden
        // Browser parity for window dragging: a transparent unified titlebar +
        // movable-by-background means clicks on the toolbar's empty areas (the
        // grey capsule, gaps) drag the window, while the pills/buttons still
        // receive their own clicks. The framebuffer and sidebar consume their
        // own events, so they never initiate a drag.
        titlebarAppearsTransparent = true
        toolbarStyle = .unified
        isMovableByWindowBackground = true
        animationBehavior = .none

        // ---- Sidebar (left) ----
        let sidebar = SessionSidebar(
            model: listModel,
            onSelect:    { [weak self] id in self?.selectRow(id) },
            onSelectTab: { [weak self] id, idx in self?.selectTab(profileID: id, index: idx) },
            onNewTab:    { [weak self] id in self?.newTab(profileID: id) },
            onCloseTab:  { [weak self] id, idx in self?.closeTab(profileID: id, index: idx) },
            onSelectDocker: { [weak self] id in self?.showDockerDashboard(id) },
            onOpenContainer: { [weak self] id, cid in self?.showDockerDashboard(id, container: cid) },
            onDetachVM:  { [weak self] id in self?.acDelegate?.popOutVM(id) },
            onCloseVM:   { [weak self] id in self?.acDelegate?.closeVMFromSidebar(id) },
            onStart:     { [weak self] id in self?.acDelegate?.startProfile(id) },
            onShutdown:  { [weak self] id in self?.acDelegate?.shutdownProfile(id) },
            onSuspend:   { [weak self] id in self?.acDelegate?.suspendProfile(id) },
            onRestart:   { [weak self] id in self?.acDelegate?.restartProfile(id) },
            onEdit:      { [weak self] id in self?.acDelegate?.sidebarEditProfile(id) },
            onDuplicate: { [weak self] id in self?.acDelegate?.sidebarDuplicateProfile(id) },
            onReset:     { [weak self] id in self?.acDelegate?.sidebarResetProfile(id) },
            onDelete:    { [weak self] id in self?.acDelegate?.sidebarDeleteProfile(id) },
            onNewProfile: { [weak self] in self?.acDelegate?.openEditorWindow(editing: nil) })
        let sidebarHost = NSHostingView(rootView: sidebar)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        self.sidebarHost = sidebarHost

        // Empty stage — shows the selected off/suspended profile's Start card.
        self.emptyStateHost = NSHostingView(rootView: EmptyStageView(
            model: listModel,
            onStart: { [weak self] id in self?.acDelegate?.startProfile(id) }))

        // ---- Stage (right): just the framebuffer slot. The per-VM controls
        // live in the window toolbar now, so the framebuffer fills full height.
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        paneSlot.translatesAutoresizingMaskIntoConstraints = false
        emptyStateHost.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(paneSlot)
        stage.addSubview(emptyStateHost)
        // Docker dashboard overlay — added last so it sits above the framebuffer
        // and empty-state. Opaque background so it fully covers the VM behind it.
        dockerSlot.translatesAutoresizingMaskIntoConstraints = false
        dockerSlot.wantsLayer = true
        dockerSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dockerSlot.isHidden = true
        stage.addSubview(dockerSlot)
        NSLayoutConstraint.activate([
            paneSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            paneSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            paneSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            paneSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            emptyStateHost.topAnchor.constraint(equalTo: paneSlot.topAnchor),
            emptyStateHost.leadingAnchor.constraint(equalTo: paneSlot.leadingAnchor),
            emptyStateHost.trailingAnchor.constraint(equalTo: paneSlot.trailingAnchor),
            emptyStateHost.bottomAnchor.constraint(equalTo: paneSlot.bottomAnchor),
            dockerSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            dockerSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            dockerSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            dockerSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])

        // ---- Layout: fixed-width sidebar | divider | framebuffer stage ----
        // Plain Auto Layout (no NSSplitView) so the framebuffer deterministically
        // fills everything to the right of a fixed 264pt sidebar — Mail.app shape.
        let root = NSView()
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarHost)
        root.addSubview(divider)
        root.addSubview(stage)
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarHost.widthAnchor.constraint(equalToConstant: 264),

            divider.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            stage.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        contentView = root

        // ---- Window toolbar: per-selected-VM controls + IP ----
        let toolbarBar = UnifiedToolbarBar(
            model: listModel,
            onFiles:     { [weak self] id in self?.acDelegate?.openFileBrowserForUnified(id) },
            onReboot:    { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.requestReboot(for: p) } },
            onTrace:     { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.openTraceInspector(for: p.profile) } },
            onSettings:  { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.openEditorWindow(editing: p.profile) } },
            onDetach:    { [weak self] id in self?.acDelegate?.popOutVM(id) },
            onToggleFusion: { [weak self] id, on in if let p = self?.pane(id) { self?.acDelegate?.setFusionEngaged(on, for: p.profile) } })
        let tbDelegate = UnifiedToolbarDelegate(rootView: toolbarBar)
        self.toolbarDelegate = tbDelegate
        let bar = NSToolbar(identifier: "io.bromure.ac.unified")
        bar.delegate = tbDelegate
        bar.displayMode = .iconOnly
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        toolbarStyle = .unified
        self.toolbar = bar

        updateEmptyState()
    }

    // MARK: Hosting

    private func pane(_ id: Profile.ID) -> SessionPane? {
        hostedPanes.first { $0.profile.id == id }
    }

    /// Add a pane to the sidebar + select it. Idempotent on profile id.
    func addPane(_ pane: SessionPane, select selectIt: Bool = true) {
        if hostedPanes.contains(where: { $0.profile.id == pane.profile.id }) { return }
        pane.host = self
        hostedPanes.append(pane)
        listModel.entries.append(SessionListModel.VMEntry(
            id: pane.profile.id,
            name: pane.profile.name,
            accentHex: pane.profile.color.hexInUI,
            model: pane.model))
        acDelegate?.registerPane(pane)
        acDelegate?.refreshSidebar()
        if selectIt || selectedID == nil {
            select(profileID: pane.profile.id)
        }
        updateEmptyState()
    }

    /// Remove a profile's pane from the sidebar + stage. Does NOT touch the VM.
    func removePane(_ id: Profile.ID) {
        guard let idx = hostedPanes.firstIndex(where: { $0.profile.id == id }) else { return }
        if dockerSelectedID == id { clearDockerDashboard() }
        let pane = hostedPanes.remove(at: idx)
        if pane.containerView.superview === paneSlot { pane.containerView.removeFromSuperview() }
        if pane.host === self { pane.host = nil }
        listModel.entries.removeAll { $0.id == id }
        if selectedID == id {
            // Keep the just-removed profile selected (now showing its Start
            // card) rather than jumping to a neighbour — the row is still in
            // the list, just no longer running.
            mountSelected(nil)
        }
        acDelegate?.refreshSidebar()
        updateEmptyState()
    }

    var isHostingAnyPane: Bool { !hostedPanes.isEmpty }

    func hostsPane(for id: Profile.ID) -> Bool { pane(id) != nil }

    /// Select a VM: show its framebuffer in the stage and focus it.
    func select(profileID id: Profile.ID) {
        guard let pane = pane(id) else { return }
        selectedID = id
        listModel.selectedID = id
        mountSelected(pane)
    }

    /// Select any profile row — running or not. A running, attached profile
    /// mounts its framebuffer; a running-but-detached one reattaches; an
    /// off/suspended one shows its Start card in the stage.
    func selectRow(_ id: Profile.ID) {
        clearDockerDashboard()
        selectedID = id
        listModel.selectedID = id
        if let pane = pane(id) { mountSelected(pane); return }
        let state = listModel.profileRows.first { $0.id == id }?.state ?? .off
        switch state {
        case .running, .booting:
            acDelegate?.connectProfile(id)   // reattach a backgrounded VM
        case .off, .suspended:
            mountSelected(nil)               // Start card for this profile
        }
    }

    private func mountSelected(_ pane: SessionPane?) {
        for sub in paneSlot.subviews where sub !== emptyStateHost { sub.removeFromSuperview() }
        mountedPane = pane
        guard let pane else { applyOpacityChrome(for: nil); updateEmptyState(); return }
        let v = pane.containerView
        v.translatesAutoresizingMaskIntoConstraints = false
        paneSlot.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: paneSlot.topAnchor),
            v.bottomAnchor.constraint(equalTo: paneSlot.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: paneSlot.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: paneSlot.trailingAnchor),
        ])
        makeFirstResponder(pane.vmView)
        applyOpacityChrome(for: pane)
        updateEmptyState()
    }

    private func updateEmptyState() {
        // The empty/Start card shows whenever no framebuffer is mounted —
        // i.e. nothing selected, or the selected profile is off/suspended.
        emptyStateHost.isHidden = (mountedPane != nil)
    }

    // MARK: Docker dashboard overlay

    /// Show the Docker dashboard for a VM in the stage (over its framebuffer),
    /// and turn on the guest's expensive stats/images polling for the duration.
    func showDockerDashboard(_ id: Profile.ID, container: String? = nil) {
        guard let selPane = pane(id) else { return }
        if let prev = dockerSelectedID, prev != id, let p = pane(prev) {
            acDelegate?.setDockerWatch(false, in: p)   // hand off watch between VMs
        }
        if selectedID != id { select(profileID: id) }
        dockerSelectedID = id
        listModel.dockerSelectedID = id
        dockerHosting?.removeFromSuperview()
        let view = DockerDashboardView(
            model: selPane.model,
            accentHex: selPane.profile.color.hexInUI,
            onRun:    { [weak self] spec in
                guard let self, let p = self.pane(id) else { return }
                self.acDelegate?.requestDockerRun(spec: spec, in: p)
                // Interactive runs open a tmux tab — surface it by dropping the dashboard.
                if spec.interactive { self.clearDockerDashboard() }
            },
            onStart:  { [weak self] cid in if let p = self?.pane(id) { self?.acDelegate?.requestDockerStart(containerID: cid, in: p) } },
            onStop:   { [weak self] cid in if let p = self?.pane(id) { self?.acDelegate?.requestDockerStop(containerID: cid, in: p) } },
            onRemove: { [weak self] cid in if let p = self?.pane(id) { self?.acDelegate?.requestDockerRemove(containerID: cid, in: p) } },
            onAttach: { [weak self] cid, shell in self?.dockerAttach(profileID: id, containerID: cid, shell: shell) },
            onLogs:   { [weak self] cid in self?.dockerLogs(profileID: id, containerID: cid) },
            onInstallBinfmt: { [weak self] in if let p = self?.pane(id) { self?.acDelegate?.requestDockerBinfmtInstall(in: p) } },
            onUninstallBinfmt: { [weak self] in if let p = self?.pane(id) { self?.acDelegate?.requestDockerBinfmtUninstall(in: p) } },
            initialContainerID: container)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        dockerSlot.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: dockerSlot.topAnchor),
            host.bottomAnchor.constraint(equalTo: dockerSlot.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: dockerSlot.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: dockerSlot.trailingAnchor),
        ])
        dockerHosting = host
        acDelegate?.setDockerWatch(true, in: selPane)
        updateDockerOverlay()
        makeFirstResponder(host)
    }

    /// Tear down the dashboard overlay and stop the guest's gated polling.
    func clearDockerDashboard() {
        guard dockerSelectedID != nil else { return }
        if let id = dockerSelectedID, let p = pane(id) {
            acDelegate?.setDockerWatch(false, in: p)
        }
        dockerSelectedID = nil
        listModel.dockerSelectedID = nil
        dockerHosting?.removeFromSuperview()
        dockerHosting = nil
        updateDockerOverlay()
    }

    private func updateDockerOverlay() {
        dockerSlot.isHidden = (dockerSelectedID == nil)
    }

    /// Honour the selected profile's terminal-transparency setting. The pane's
    /// own container layer carries the alpha; here we flip the *window* to
    /// non-opaque and clear the *stage* backing so that alpha composites against
    /// the desktop — and ONLY the framebuffer: the sidebar/divider/titlebar stay
    /// opaque. Opaque profiles keep the solid black stage (nice during boot).
    private func applyOpacityChrome(for pane: SessionPane?) {
        let opacity = pane.map { min(1.0, max(0.3, $0.profile.windowOpacity)) } ?? 1.0
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
            stage.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            isOpaque = true
            backgroundColor = nil
            stage.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    // MARK: Tab actions (forward to the pane)

    func selectTab(profileID id: Profile.ID, index: Int) {
        clearDockerDashboard()
        if selectedID != id { select(profileID: id) }
        pane(id)?.switchTo(index: index)
    }
    func newTab(profileID id: Profile.ID) {
        clearDockerDashboard()
        if selectedID != id { select(profileID: id) }
        if let p = pane(id) { acDelegate?.spawnNewTab(in: p) }
    }
    func closeTab(profileID id: Profile.ID, index: Int) {
        pane(id)?.closeTab(at: index)
    }
    func dockerAttach(profileID id: Profile.ID, containerID: String, shell: String) {
        // The new shell becomes the active tmux window; surface it by dropping
        // the dashboard so the framebuffer is visible.
        clearDockerDashboard()
        if selectedID != id { select(profileID: id) }
        if let p = pane(id) {
            acDelegate?.requestDockerAttach(containerID: containerID, shell: shell, in: p)
        }
    }

    func dockerLogs(profileID id: Profile.ID, containerID: String) {
        // `docker logs -f` opens a tmux tab — surface it by dropping the dashboard.
        clearDockerDashboard()
        if selectedID != id { select(profileID: id) }
        if let p = pane(id) {
            acDelegate?.requestDockerLogs(containerID: containerID, in: p)
        }
    }

    // MARK: - SessionPaneHost

    var paneHostWindow: NSWindow? { self }

    func paneRequestsClose(_ pane: SessionPane) {
        // Last tab closed (or relaunch failure) → run the profile's close
        // pipeline for this VM, then drop the pane.
        acDelegate?.closeVMFromSidebar(pane.profile.id)
    }

    func paneDidUpdateProfile(_ pane: SessionPane) {
        if let entry = listModel.entries.first(where: { $0.id == pane.profile.id }) {
            entry.name = pane.profile.name
            entry.accentHex = pane.profile.color.hexInUI
        }
        // A live opacity change on the visible VM re-applies the window chrome.
        if pane.profile.id == selectedID { applyOpacityChrome(for: pane) }
    }

    // MARK: - Shortcut routing (selected pane)

    private func selectedPane() -> SessionPane? {
        guard let id = selectedID else { return hostedPanes.first }
        return pane(id) ?? hostedPanes.first
    }

    func handleACShortcut(_ event: NSEvent) -> Bool {
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.intersection(userMods) == [.command] else { return false }
        guard let pane = selectedPane() else { return false }
        if pane.vmHasKeyboardFocus { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return pane.performACShortcut(chars, isRepeat: event.isARepeat)
    }

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

// MARK: - Sidebar SwiftUI

private struct SessionSidebar: View {
    @Bindable var model: SessionListModel
    let onSelect: (Profile.ID) -> Void
    let onSelectTab: (Profile.ID, Int) -> Void
    let onNewTab: (Profile.ID) -> Void
    let onCloseTab: (Profile.ID, Int) -> Void
    /// Open the VM's Docker dashboard in the stage.
    let onSelectDocker: (Profile.ID) -> Void
    /// (profileID, containerID) — open the dashboard on this container's detail.
    let onOpenContainer: (Profile.ID, String) -> Void
    let onDetachVM: (Profile.ID) -> Void
    let onCloseVM: (Profile.ID) -> Void
    let onStart: (Profile.ID) -> Void
    let onShutdown: (Profile.ID) -> Void
    let onSuspend: (Profile.ID) -> Void
    let onRestart: (Profile.ID) -> Void
    let onEdit: (Profile.ID) -> Void
    let onDuplicate: (Profile.ID) -> Void
    let onReset: (Profile.ID) -> Void
    let onDelete: (Profile.ID) -> Void
    let onNewProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.profileRows) { row in
                        VMSection(
                            row: row,
                            entry: model.entries.first { $0.id == row.id },
                            isSelected: model.selectedID == row.id,
                            isDockerActive: model.dockerSelectedID == row.id,
                            onSelect: onSelect,
                            onSelectTab: onSelectTab,
                            onNewTab: onNewTab,
                            onCloseTab: onCloseTab,
                            onSelectDocker: onSelectDocker,
                            onOpenContainer: onOpenContainer,
                            onDetachVM: onDetachVM,
                            onCloseVM: onCloseVM,
                            onStart: onStart,
                            onShutdown: onShutdown,
                            onSuspend: onSuspend,
                            onRestart: onRestart,
                            onEdit: onEdit,
                            onDuplicate: onDuplicate,
                            onReset: onReset,
                            onDelete: onDelete)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider().opacity(0.5)
            PlusButton(onNewProfile: onNewProfile)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Solid (opaque) so the window's transparency for translucent profiles
        // only shows through the framebuffer, never the sidebar.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// "+" affordance at the bottom of the source list — creates a new profile.
private struct PlusButton: View {
    let onNewProfile: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onNewProfile) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.black.opacity(hovering ? 0.7 : 1.0))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .help("New workspace")
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

/// One profile row — its run state, controls, and (when running) nested tabs.
private struct VMSection: View {
    let row: SessionListModel.ProfileRow
    /// Live tab model when the VM is running AND attached; nil otherwise.
    var entry: SessionListModel.VMEntry?
    let isSelected: Bool
    /// True when this VM's Docker dashboard is the active stage surface.
    let isDockerActive: Bool
    let onSelect: (Profile.ID) -> Void
    let onSelectTab: (Profile.ID, Int) -> Void
    let onNewTab: (Profile.ID) -> Void
    let onCloseTab: (Profile.ID, Int) -> Void
    let onSelectDocker: (Profile.ID) -> Void
    let onOpenContainer: (Profile.ID, String) -> Void
    let onDetachVM: (Profile.ID) -> Void
    let onCloseVM: (Profile.ID) -> Void
    let onStart: (Profile.ID) -> Void
    let onShutdown: (Profile.ID) -> Void
    let onSuspend: (Profile.ID) -> Void
    let onRestart: (Profile.ID) -> Void
    let onEdit: (Profile.ID) -> Void
    let onDuplicate: (Profile.ID) -> Void
    let onReset: (Profile.ID) -> Void
    let onDelete: (Profile.ID) -> Void

    @State private var hovering = false

    private var isLive: Bool { row.state == .running || row.state == .booting }

    private var stateLabel: String? {
        switch row.state {
        case .off:       return "Off"
        case .booting:   return "Starting…"
        case .suspended: return "Suspended"
        case .running:   return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Profile header
            HStack(spacing: 8) {
                VMIcon(accentHex: row.accentHex, state: row.state)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(row.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        if row.compromised {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                    }
                    if let stateLabel {
                        Text(stateLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                if isLive && hovering {
                    IconButton(system: "rectangle.portrait.and.arrow.right", help: "Pop out to its own window") {
                        onDetachVM(row.id)
                    }
                    IconButton(system: "xmark", help: "Close this VM") {
                        onCloseVM(row.id)
                    }
                }
                if isLive {
                    IconButton(system: "plus", help: "New tab (⌘T)") { onNewTab(row.id) }
                }
                ControlMenu(row: row,
                            onStart: onStart, onShutdown: onShutdown, onSuspend: onSuspend, onRestart: onRestart,
                            onEdit: onEdit, onDuplicate: onDuplicate,
                            onReset: onReset, onDelete: onDelete)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color(hex: row.accentHex).opacity(0.16)
                                     : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: row.accentHex))
                        .frame(width: 3, height: 18)
                        .offset(x: -5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect(row.id) }

            // Nested rows for a running, attached VM: top-level tabs (attach
            // tabs are nested under their container instead), then the always-on
            // Docker node.
            if let entry {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entry.model.tabs.enumerated()), id: \.element.id) { idx, tab in
                        if tab.containerID == nil {
                            TabRow(
                                label: tab.label,
                                agentKind: BromureIcons.agentKind(forLabel: tab.label),
                                thinking: entry.model.thinking,
                                isActive: tab.id == entry.model.activeTab?.id && isSelected,
                                accentHex: row.accentHex,
                                chord: (isSelected && idx < 9) ? idx + 1 : nil,
                                onSelect: { onSelectTab(row.id, idx) },
                                onClose: { onCloseTab(row.id, idx) })
                        }
                    }
                    DockerSection(
                        model: entry.model,
                        accentHex: row.accentHex,
                        isSelected: isSelected,
                        isDockerActive: isDockerActive,
                        onOpen: { onSelectDocker(row.id) },
                        onOpenContainer: { cid in onOpenContainer(row.id, cid) },
                        onSelectTab: { idx in onSelectTab(row.id, idx) },
                        onCloseTab: { idx in onCloseTab(row.id, idx) })
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, 17)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 5)
        .onHover { hovering = $0 }
    }
}

/// State-aware "⋯" control menu for a profile row: start/stop/restart plus
/// edit / duplicate / reset / delete.
private struct ControlMenu: View {
    let row: SessionListModel.ProfileRow
    let onStart: (Profile.ID) -> Void
    let onShutdown: (Profile.ID) -> Void
    let onSuspend: (Profile.ID) -> Void
    let onRestart: (Profile.ID) -> Void
    let onEdit: (Profile.ID) -> Void
    let onDuplicate: (Profile.ID) -> Void
    let onReset: (Profile.ID) -> Void
    let onDelete: (Profile.ID) -> Void

    var body: some View {
        Menu {
            switch row.state {
            case .off:
                Button("Start") { onStart(row.id) }
            case .suspended:
                Button("Resume") { onStart(row.id) }
            case .running, .booting:
                Button("Shutdown") { onShutdown(row.id) }
                Button("Suspend") { onSuspend(row.id) }
                Button("Reboot") { onRestart(row.id) }
            }
            Divider()
            Button("Edit…") { onEdit(row.id) }
            Button("Duplicate") { onDuplicate(row.id) }
            Divider()
            Button("Reset disk", role: .destructive) { onReset(row.id) }
            Button("Delete workspace", role: .destructive) { onDelete(row.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The profile's tile with a run-state badge.
private struct VMIcon: View {
    let accentHex: String
    let state: SessionListModel.RunState
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: accentHex).opacity(state == .off ? 0.10 : 0.18))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: accentHex).opacity(state == .off ? 0.55 : 1)))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.4))
                    .opacity(state == .booting && pulse ? 0.4 : 1)
                    .offset(x: 3, y: 3)
            }
            .onAppear {
                if state == .booting {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
    }
    private var statusColor: Color {
        switch state {
        case .booting:   return .orange
        case .running:   return .green
        case .suspended: return .yellow
        case .off:       return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

private struct TabRow: View {
    let label: String
    let agentKind: String?
    let thinking: Bool
    let isActive: Bool
    let accentHex: String
    /// ⌘-number for this tab (1–9), or nil for tabs past 9 / unfocused VMs.
    let chord: Int?
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    private var isAgent: Bool { agentKind != nil }

    var body: some View {
        HStack(spacing: 8) {
            // Invisible gutter the width of the Docker node's chevron, so a tab's
            // icon lines up with the Docker icon (and any other chevroned node)
            // rather than sitting a chevron's-width to its left.
            Color.clear.frame(width: 10, height: 14)
            Group {
                if isAgent && thinking {
                    ThinkingDots(color: Color(hex: accentHex))
                } else if isAgent {
                    SVGIcon(name: "robot", fallbackSymbol: "sparkles", size: 13)
                        .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 14)

            Text(label.isEmpty ? "shell" : label)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer(minLength: 2)
            if hovering {
                IconButton(system: "xmark", help: "Close tab (⌘W)", size: 9) { onClose() }
            } else if let chord {
                ChordLabel(chord)
            }
        }
        // Matches the Docker node's leading (20) so, with the chevron gutter
        // above, the tab icon and the Docker icon align at the same x.
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Right-aligned ⌘-number affordance shown next to a tab, à la unpeel.
private struct ChordLabel: View {
    let n: Int
    init(_ n: Int) { self.n = n }
    var body: some View {
        Text("⌘\(n)")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }
}

/// The always-on "Docker" node under a workspace's tabs. The header opens the
/// dashboard (onOpen); the chevron expands a sub-tree of running containers,
/// each with its attach tabs nested underneath.
private struct DockerSection: View {
    let model: TabsModel
    let accentHex: String
    let isSelected: Bool
    let isDockerActive: Bool
    let onOpen: () -> Void
    /// containerID — open the dashboard on this container's detail.
    let onOpenContainer: (String) -> Void
    /// model position of a nested attach tab
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    @State private var expanded = true
    @State private var headerHover = false

    private var running: [DockerContainer] { model.dockerContainers.filter(\.isRunning) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture { expanded.toggle() }   // chevron toggles only
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#2496ED"))   // Docker blue
                    .frame(width: 16)
                Text("Docker")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDockerActive ? .primary : .secondary)
                    .lineLimit(1)
                Text("\(running.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 2)
            }
            .padding(.leading, 20)   // clear of the tree rule at x≈17
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDockerActive ? Color(hex: accentHex).opacity(0.14)
                                         : (headerHover ? Color.primary.opacity(0.04) : .clear)))
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }              // rest of header → dashboard
            .onHover { headerHover = $0 }

            if expanded {
                ForEach(running) { container in
                    DockerContainerRow(
                        container: container,
                        accentHex: accentHex,
                        isSelected: isSelected,
                        tabs: tabRows(for: container),
                        activeTabID: model.activeTab?.id,
                        onOpen: { onOpenContainer(container.id) },
                        onSelectTab: onSelectTab,
                        onCloseTab: onCloseTab)
                }
            }
        }
    }

    /// (model position, tab) for the attach tabs belonging to a container.
    private func tabRows(for c: DockerContainer) -> [(pos: Int, tab: TabsModel.Tab)] {
        // Attach tabs tag with the container id; interactive `docker run -it`
        // tabs tag with the container name (the id isn't known when launched).
        model.tabs.enumerated()
            .filter { $0.element.containerID == c.id || $0.element.containerID == c.name }
            .map { (pos: $0.offset, tab: $0.element) }
    }
}

/// One running container under the Docker node: a row that opens the attach
/// popover, plus its attach tabs nested underneath.
private struct DockerContainerRow: View {
    let container: DockerContainer
    let accentHex: String
    let isSelected: Bool
    let tabs: [(pos: Int, tab: TabsModel.Tab)]
    let activeTabID: UUID?
    /// Open the dashboard on this container's detail screen.
    let onOpen: () -> Void
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .frame(width: 18)
                Text(container.name.isEmpty ? container.shortID : container.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if hovering {
                    IconButton(system: "info.circle", help: "Details & attach", size: 10) { onOpen() }
                }
            }
            .padding(.leading, 34)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.04) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { hovering = $0 }

            ForEach(tabs, id: \.tab.id) { entry in
                DockerTabRow(
                    label: entry.tab.label,
                    isActive: entry.tab.id == activeTabID && isSelected,
                    accentHex: accentHex,
                    chord: (isSelected && entry.pos < 9) ? entry.pos + 1 : nil,
                    onSelect: { onSelectTab(entry.pos) },
                    onClose: { onCloseTab(entry.pos) })
            }
        }
    }
}

/// A `docker exec` attach tab, nested one level deeper than a container row.
private struct DockerTabRow: View {
    let label: String
    let isActive: Bool
    let accentHex: String
    let chord: Int?
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                .frame(width: 16)
            Text(label.isEmpty ? "shell" : label)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer(minLength: 2)
            if hovering {
                IconButton(system: "xmark", help: "Close tab (⌘W)", size: 8) { onClose() }
            } else if let chord {
                ChordLabel(chord)
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.08)
                               : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// unpeel-style staggered "typing" dots shown while the agent is working.
private struct ThinkingDots: View {
    var color: Color = .secondary
    @State private var anim = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .scaleEffect(anim ? 1.0 : 0.45)
                    .opacity(anim ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.16), value: anim)
            }
        }
        .onAppear { anim = true }
        .help("Working…")
    }
}

private struct IconButton: View {
    let system: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(hovering ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Window toolbar (per-selected-VM controls + IP)

private let unifiedToolbarItemID = NSToolbarItem.Identifier("io.bromure.ac.unified.controls")

@MainActor
final class UnifiedToolbarDelegate: NSObject, NSToolbarDelegate {
    private let rootView: UnifiedToolbarBar
    init(rootView: UnifiedToolbarBar) { self.rootView = rootView }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, unifiedToolbarItemID]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, unifiedToolbarItemID]
    }
    func toolbar(_ t: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == unifiedToolbarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let host = FlexibleHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        item.visibilityPriority = .high
        return item
    }
}

/// The toolbar's trailing control cluster for the selected VM.
struct UnifiedToolbarBar: View {
    @Bindable var model: SessionListModel
    let onFiles: (Profile.ID) -> Void
    let onReboot: (Profile.ID) -> Void
    let onTrace: (Profile.ID) -> Void
    let onSettings: (Profile.ID) -> Void
    let onDetach: (Profile.ID) -> Void
    let onToggleFusion: (Profile.ID, Bool) -> Void

    private var entry: SessionListModel.VMEntry? {
        model.entries.first { $0.id == model.selectedID }
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let entry {
                if let ip = entry.model.ipAddress { ToolbarIP(ip: ip) }
                if entry.model.streamingActive { StreamingDot() }
                if let status = entry.model.engineStatus { EngineBadge(status: status) }
                FusionToggle(model: entry.model) { on in onToggleFusion(entry.id, on) }
                HeaderIcon(system: "folder", help: "Browse files") { onFiles(entry.id) }
                HeaderIcon(system: "arrow.clockwise.circle", help: "Reboot the VM") { onReboot(entry.id) }
                HeaderIcon(system: "doc.text.magnifyingglass", help: "Inspect trace (⇧⌘I)") { onTrace(entry.id) }
                HeaderIcon(system: "gearshape", help: "Edit workspace") { onSettings(entry.id) }
                HeaderIcon(system: "rectangle.portrait.and.arrow.right", help: "Pop out to its own window") { onDetach(entry.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Monospace IP pill in the toolbar; click to copy.
private struct ToolbarIP: View {
    let ip: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "network").font(.system(size: 10))
                Text(copied ? "Copied" : ip).font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("VM IP — click to copy")
    }
}

private struct HeaderIcon: View {
    let system: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FusionToggle: View {
    @Bindable var model: TabsModel
    let onToggle: (Bool) -> Void
    var body: some View {
        Button {
            guard model.fusionConfigurable else { return }
            model.fusionEngaged.toggle()
            onToggle(model.fusionEngaged)
        } label: {
            Image(systemName: model.fusionConfigurable ? "bolt.fill" : "bolt")
                .font(.system(size: 13))
                .foregroundStyle(!model.fusionConfigurable ? Color.secondary
                    : (model.fusionEngaged ? .yellow : Color(nsColor: .darkGray)))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!model.fusionConfigurable)
        .help(model.fusionConfigurable
            ? (model.fusionEngaged ? "Fusion engaged — click to disengage" : "Fusion available — click to engage")
            : "Enable at least two models to use Fusion")
    }
}

private struct StreamingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle().fill(.red).frame(width: 8, height: 8)
            .opacity(pulse ? 1 : 0.5)
            .help("Session metadata is being sent to bromure.io")
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse.toggle() } }
    }
}

private struct EngineBadge: View {
    let status: TabsModel.EngineStatus
    var body: some View {
        switch status {
        case .starting(let d):
            HStack(spacing: 4) { ProgressView().controlSize(.small).scaleEffect(0.7); Image(systemName: "cpu").foregroundStyle(.secondary) }.help(d)
        case .ready(let m):
            Image(systemName: "cpu.fill").foregroundStyle(.green).help("Local model ready — \(m)")
        case .failed(let e):
            Image(systemName: "cpu").foregroundStyle(.orange).help("Local engine failed: \(e)")
        }
    }
}

private struct EmptyStageView: View {
    @Bindable var model: SessionListModel
    let onStart: (Profile.ID) -> Void

    private var selectedRow: SessionListModel.ProfileRow? {
        guard let id = model.selectedID else { return nil }
        return model.profileRows.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let row = selectedRow, row.state == .off || row.state == .suspended {
                VMIcon(accentHex: row.accentHex, state: row.state)
                    .scaleEffect(2.0)
                    .padding(.bottom, 10)
                Text(row.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(row.state == .suspended
                     ? "Suspended — pick up where you left off"
                     : "This workspace isn't running")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Button { onStart(row.id) } label: {
                    Label(row.state == .suspended ? "Resume" : "Start", systemImage: "play.fill")
                        .frame(width: 150)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: row.accentHex))
                .padding(.top, 4)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.white.opacity(0.5))
                Text(model.profileRows.isEmpty ? "No workspaces yet" : "No workspace selected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text(model.profileRows.isEmpty
                     ? "Click + to create one"
                     : "Select a workspace on the left")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }
}
