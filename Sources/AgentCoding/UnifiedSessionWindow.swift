import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

/// NSHostingView that never lets a mouse-down move the host window, so a
/// drag inside SwiftUI content (row drag-and-drop, selection) isn't stolen by
/// the window's `isMovableByWindowBackground`.
final class NonMovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Thin invisible strip over the sidebar divider that resizes the sidebar on
/// drag. Reports the proposed new width (mouse x in its superview's coords),
/// then fires `onResizeEnd` on mouse-up so the final width can be persisted
/// without writing every intermediate drag position.
final class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onResize?(sv.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        onResizeEnd?()
    }
}

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
    /// True when the Grid is the active stage surface.
    var gridSelected = false
    /// Set when an automation's editor is the active stage surface —
    /// highlights its row in the Automations section.
    var automationSelectedID: UUID?
    /// True when the automation kanban board is the active stage surface.
    var automationBoardSelected = false
    /// True when the coding-task kanban board is the active stage surface.
    var taskBoardSelected = false
    /// True when the sidebar is collapsed to the icon rail.
    var sidebarCollapsed = false
    /// True when the right-hand file-explorer pane is open. Drives the
    /// toolbar button tint and the pane's own context/polling.
    var filePaneOpen = false
    /// True when the agentic browser pane is open. Drives the toolbar tint.
    var browserPaneOpen = false
}

/// Right-click actions on a tab row. Handled by the window, which reads the
/// tab's worktree metadata and dispatches to the delegate (dialogs + guest
/// commands).
enum TabAction {
    case newWorktree        // any tab whose cwd is a git repo
    case merge              // a worktree tab → merge into an ancestor
    case attachTerminal     // a worktree tab → open a plain terminal in its checkout
    case removeWorktree     // a worktree tab → discard (remove + delete branch)
    case resolveConflicts   // a "Merge → …" tab → spawn the agent to resolve
    case createAutomation   // any tab → automation editor seeded with its cwd
}

/// Nesting depth of a tab in the worktree tree: 0 for ordinary tabs, N for a
/// worktree whose parent chain (by `parentBranch` → an ancestor's
/// `worktreeBranch`) is N deep. An attached terminal — a plain tab tagged with
/// `parentBranch` but no `worktreeBranch` — nests one step under its worktree
/// the same way. Drives the source-list indentation so worktrees-off-worktrees
/// read as nested. Capped so a deep tree can't march off the sidebar.
@MainActor
func worktreeDepth(of tab: TabsModel.Tab, in tabs: [TabsModel.Tab]) -> Int {
    guard tab.isWorktree || !(tab.parentBranch?.isEmpty ?? true) else { return 0 }
    var depth = 1
    var parentBranch = tab.parentBranch
    var guardCount = 0
    while let pb = parentBranch, !pb.isEmpty, guardCount < 8 {
        guard let parent = tabs.first(where: { $0.worktreeBranch == pb }) else { break }
        depth += 1
        parentBranch = parent.parentBranch
        guardCount += 1
    }
    return min(depth, 6)
}

/// A tab paired with its position in `model.tabs` (the select/close APIs
/// speak model positions). `id` delegates to the tab so SwiftUI rows keep
/// their identity when only the display order changes.
struct DisplayOrderedTab: Identifiable {
    let idx: Int
    let tab: TabsModel.Tab
    var id: ObjectIdentifier { tab.id }
}

/// Tabs in sidebar display order: roster order for top-level tabs, with
/// every nested tab (a worktree, or a parentBranch-tagged terminal/merge/PR
/// tab) pulled directly under its parent. tmux appends new windows at the
/// end of the roster, which used to strand a fresh worktree's indented row
/// under whatever tab happened to be listed last instead of its parent.
@MainActor
func worktreeDisplayOrdered(_ tabs: [TabsModel.Tab]) -> [DisplayOrderedTab] {
    var children: [Int: [Int]] = [:]
    var roots: [Int] = []
    for (i, tab) in tabs.enumerated() {
        var parent: Int?
        // Worktree-off-worktree / attached terminal / merge / PR tab: the
        // parent is the tab checked out at our parentBranch.
        if let pb = tab.parentBranch, !pb.isEmpty {
            parent = tabs.firstIndex(where: { $0 !== tab && $0.worktreeBranch == pb })
        }
        // Depth-1 worktree (cut from a plain branch): the repo tab it was
        // created from — the one whose git toplevel is our main checkout.
        if parent == nil, tab.isWorktree,
           let root = tab.rootRepo, !root.isEmpty {
            parent = tabs.firstIndex(where: { $0.repoRoot == root })
        }
        if let p = parent, p != i {
            children[p, default: []].append(i)
        } else {
            roots.append(i)
        }
    }
    var out: [DisplayOrderedTab] = []
    var seen = Set<Int>()
    func emit(_ i: Int) {
        guard seen.insert(i).inserted else { return }   // cycle guard
        out.append(DisplayOrderedTab(idx: i, tab: tabs[i]))
        for c in children[i] ?? [] { emit(c) }
    }
    for r in roots { emit(r) }
    // Orphan cycles (shouldn't happen) keep roster order at the end.
    for i in tabs.indices where !seen.contains(i) { emit(i) }
    return out
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
    private var sidebarHost: NonMovableHostingView<SessionSidebar>!
    /// The pane currently mounted in the stage, if any. Drives the empty state.
    private var mountedPane: SessionPane?

    /// Full-bleed overlay on top of the stage that shows the Docker dashboard
    /// for the selected VM. Hidden unless `dockerSelectedID` is set.
    private let dockerSlot = NSView()
    private var dockerHosting: NSHostingView<DockerDashboardView>?
    /// The VM whose Docker dashboard is currently shown (nil = none).
    private var dockerSelectedID: Profile.ID?
    /// Full-bleed overlay showing the VM dashboard (vitals + config) for the
    /// selected workspace. Hidden unless `vmDashboardSelectedID` is set.
    private let vmDashboardSlot = NSView()
    private var vmDashboardHosting: NSHostingView<VMDashboardView>?
    private var vmDashboardSelectedID: Profile.ID?
    /// Full-bleed overlay hosting the automation editor (sidebar
    /// "Automations" section). nil id + visible slot = composing a new one.
    private let automationSlot = NSView()
    private var automationHosting: NSHostingView<AutomationEditorView>?
    /// Automation kanban board overlay — same full-bleed slot pattern.
    private let kanbanSlot = NSView()
    private var kanbanHosting: NSHostingView<AutomationKanbanView>?
    /// Coding-task kanban board overlay.
    private let taskBoardSlot = NSView()
    private var taskBoardHosting: NSHostingView<CodingKanbanView>?
    private var automationEditorVisible = false
    /// The editor's draft differs from what's stored (reported by the view).
    /// Consulted by clearAutomationEditor so navigating away warns first.
    private var automationDraftDirty = false
    private var toolbarDelegate: UnifiedToolbarDelegate?

    /// The user-curated terminal grid (phase 2): membership persists here,
    /// surfaces live in `gridView` while the grid is showing.
    let gridStore = GridLayoutStore()
    private let gridSlot = NSView()
    private var gridView: GridStageView?

    /// Collapsible + resizable sidebar. ⌃⌘S toggles; the divider drag handle
    /// resizes, collapsing to the rail under `sidebarMinWidth` and expanding
    /// back past it. Grid mode especially wants the full window width.
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarDivider: NSBox?
    private(set) var sidebarCollapsed = false
    /// The preferred (expanded) width: what ⌃⌘S expand restores, and what is
    /// persisted to defaults. Set at init and at drag-end while expanded.
    private var expandedSidebarWidth: CGFloat = 220
    /// Below this, a drag collapses to the rail; above it, expands back.
    private static let sidebarMinWidth: CGFloat = 100
    private static let sidebarMaxWidth: CGFloat = 600
    private static let sidebarDefaultWidth: CGFloat = 220
    private static let sidebarRailWidth: CGFloat = 44
    private static let sidebarWidthKey = "ac.sidebarWidth"

    /// Right-hand file explorer (⌃⌘E / toolbar button; drag its divider under
    /// the min width to close). Lives INSIDE the stage so the grid/docker/vm
    /// overlays cover it — it's a main-window-mode surface only. Data comes
    /// from the guest over the shell vsock (see FileExplorer.swift).
    let fileExplorerModel = FileExplorerModel()
    private var filePaneHost: NonMovableHostingView<FileExplorerPane>!
    private var filePaneWidthConstraint: NSLayoutConstraint?
    private var filePaneResizeHandle: SidebarResizeHandle?
    private(set) var filePaneOpen = false
    /// Preferred width — restored on open, persisted at drag-end.
    private var expandedFilePaneWidth: CGFloat = 260
    private static let filePaneMinWidth: CGFloat = 200
    private static let filePaneMaxWidth: CGFloat = 1000
    private static let filePaneDefaultWidth: CGFloat = 260
    private static let filePaneWidthKey = "ac.filePaneWidth"
    private static let filePaneOpenKey = "ac.filePaneOpen"

    /// Right-hand agentic browser pane (⌃⌘B). A split like the file explorer
    /// but wider (default ~half the stage — see browser.png), and the
    /// outermost right split (sits right of the file pane when both are open).
    /// Lives inside the stage so the grid/docker/vm overlays cover it.
    ///
    /// One ephemeral browser VM PER WORKSPACE: models + controllers are keyed
    /// by Profile.id and created lazily. The single pane host shows the
    /// selected workspace's browser (swapped on selection); the others keep
    /// running/suspended off-screen. An empty placeholder model backs the host
    /// until a workspace's browser is shown.
    private let browserPlaceholderModel = BrowserPaneModel()
    private var browserModels: [Profile.ID: BrowserPaneModel] = [:]
    private var browserControllers: [Profile.ID: WorkspaceBrowserController] = [:]
    /// Which workspace's browser the pane currently displays.
    private var shownBrowser: Profile.ID?
    private var browserPaneHost: NonMovableHostingView<BrowserPaneView>!
    private var browserPaneWidthConstraint: NSLayoutConstraint?
    private var browserPaneResizeHandle: SidebarResizeHandle?
    /// Workspaces whose browser pane the user has opened. The pane is one
    /// global split, but its open/closed state is remembered PER workspace:
    /// switching workspaces animates the pane to match the newly selected
    /// one, so a browser opened in A doesn't spawn one in B and isn't lost
    /// when you return to A. A workspace's browser lives (hidden →
    /// suspended) as long as its pane stays open; collapsing ITS pane is
    /// what arms teardown.
    private var browserPaneOpenWorkspaces: Set<Profile.ID> = []
    /// Whether the SELECTED workspace's browser pane is open.
    var browserPaneOpen: Bool {
        guard let id = selectedID else { return false }
        return browserPaneOpenWorkspaces.contains(id)
    }
    private var expandedBrowserPaneWidth: CGFloat = 640
    private static let browserPaneMinWidth: CGFloat = 380
    private static let browserPaneMaxWidth: CGFloat = 1400
    private static let browserPaneDefaultWidth: CGFloat = 640
    /// Floor the terminal/pane slot keeps when the browser pane is open —
    /// the clamp that stops the pane from growing the window off-screen.
    private static let terminalSlotMinWidth: CGFloat = 240
    private static let browserPaneWidthKey = "ac.browserPaneWidth"

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
            gridStore: gridStore,
            onSelectGrid: { [weak self] in self?.showGrid() },
            onRemoveGridCell: { [weak self] id in self?.gridStore.remove(id: id) },
            onFocusGridCell: { [weak self] id in
                self?.showGrid()
                self?.gridStore.focusedCellID = id
            },
            onDropGridPayload: { [weak self] payload in
                guard let self,
                      let decoded = GridDragPayload.decode(payload) else { return false }
                self.addToGrid(profileID: decoded.profileID,
                               windowIndex: decoded.windowIndex,
                               label: decoded.label)
                return true
            },
            onAddAllToGrid: { [weak self] id in self?.addAllWorktreesToGrid(profileID: id) },
            onSelect:    { [weak self] id in self?.selectWorkspaceName(id) },
            onSelectTab: { [weak self] id, idx in self?.selectTab(profileID: id, index: idx) },
            onNewTab:    { [weak self] id in self?.newTab(profileID: id) },
            onCloseTab:  { [weak self] id, idx in self?.closeTab(profileID: id, index: idx) },
            onTabAction: { [weak self] id, idx, action in self?.handleTabAction(profileID: id, index: idx, action: action) },
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
            onNewProfile: { [weak self] in self?.acDelegate?.openEditorWindow(editing: nil) },
            automationStore: acDelegate.scheduledAutomationStore,
            onNewAutomation:    { [weak self] in self?.showAutomationEditor(nil) },
            onShowAutomationBoard: { [weak self] in self?.showAutomationBoard() },
            taskStore: acDelegate.codingTaskStore,
            onShowTaskBoard: { [weak self] in self?.showTaskBoard() })
        // NonMovable so a drag inside the sidebar — notably dragging a tab
        // row onto the Grid — selects/drags the row instead of moving the
        // whole window (the window is isMovableByWindowBackground).
        let sidebarHost = NonMovableHostingView(rootView: sidebar)
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
        // File-explorer pane (right edge of the stage) + its drag handle.
        // Added BEFORE the docker/vm/grid overlays so those cover it — the
        // pane and its resize handle are main-window-mode surfaces only.
        let explorerPane = FileExplorerPane(
            model: fileExplorerModel, listModel: listModel,
            onAutoSetOpen: { [weak self] open in self?.setFilePaneOpen(open, animated: true) },
            onWorktreeAction: { [weak self] action in
                // Act on the selected workspace's active tab (by its array index
                // in the pane's tab roster — what handleTabAction expects).
                guard let self, let id = self.selectedID, let p = self.pane(id),
                      let active = p.model.activeTab,
                      let idx = p.model.tabs.firstIndex(where: { $0 === active })
                else { return }
                self.handleTabAction(profileID: id, index: idx, action: action)
            })
        let filePaneHost = NonMovableHostingView(rootView: explorerPane)
        filePaneHost.translatesAutoresizingMaskIntoConstraints = false
        filePaneHost.clipsToBounds = true   // squish cleanly during open/close
        // Our width constraint is the ONLY size authority. By default an
        // NSHostingView adds a REQUIRED min-width from its SwiftUI content,
        // which beats the width-0 "closed" constant and leaves a phantom
        // strip of window (desktop shows through on translucent profiles).
        filePaneHost.sizingOptions = []
        self.filePaneHost = filePaneHost
        stage.addSubview(filePaneHost)
        let filePaneHandle = SidebarResizeHandle()
        filePaneHandle.translatesAutoresizingMaskIntoConstraints = false
        self.filePaneResizeHandle = filePaneHandle
        stage.addSubview(filePaneHandle)
        // Browser pane (outermost right split) + its drag handle. Same
        // main-window-mode treatment as the file pane: added before the
        // docker/vm/grid overlays so those cover it.
        let browserPane = BrowserPaneView(model: browserPlaceholderModel)
        let browserPaneHost = NonMovableHostingView(rootView: browserPane)
        browserPaneHost.translatesAutoresizingMaskIntoConstraints = false
        browserPaneHost.clipsToBounds = true
        browserPaneHost.sizingOptions = []   // our width constraint is the sole authority
        browserPaneHost.isHidden = true
        self.browserPaneHost = browserPaneHost
        stage.addSubview(browserPaneHost)
        let browserPaneHandle = SidebarResizeHandle()
        browserPaneHandle.translatesAutoresizingMaskIntoConstraints = false
        browserPaneHandle.isHidden = true
        self.browserPaneResizeHandle = browserPaneHandle
        stage.addSubview(browserPaneHandle)
        // The browser pane closes via ⌃⌘B / the toolbar globe (the compact tab
        // bar has no close-pane control of its own).
        // Docker dashboard overlay — added last so it sits above the framebuffer
        // and empty-state. Opaque background so it fully covers the VM behind it.
        dockerSlot.translatesAutoresizingMaskIntoConstraints = false
        dockerSlot.wantsLayer = true
        dockerSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dockerSlot.isHidden = true
        stage.addSubview(dockerSlot)
        // Automation editor overlay — same full-bleed pattern as Docker.
        automationSlot.translatesAutoresizingMaskIntoConstraints = false
        automationSlot.wantsLayer = true
        automationSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        automationSlot.isHidden = true
        stage.addSubview(automationSlot)
        // Automation kanban board overlay — same treatment.
        kanbanSlot.translatesAutoresizingMaskIntoConstraints = false
        kanbanSlot.wantsLayer = true
        kanbanSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        kanbanSlot.isHidden = true
        stage.addSubview(kanbanSlot)
        // Coding-task kanban board overlay — same treatment.
        taskBoardSlot.translatesAutoresizingMaskIntoConstraints = false
        taskBoardSlot.wantsLayer = true
        taskBoardSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        taskBoardSlot.isHidden = true
        stage.addSubview(taskBoardSlot)
        // VM dashboard overlay — same treatment as the Docker overlay.
        vmDashboardSlot.translatesAutoresizingMaskIntoConstraints = false
        vmDashboardSlot.wantsLayer = true
        vmDashboardSlot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        vmDashboardSlot.isHidden = true
        stage.addSubview(vmDashboardSlot)
        // Grid overlay — topmost stage surface.
        gridSlot.translatesAutoresizingMaskIntoConstraints = false
        gridSlot.wantsLayer = true
        gridSlot.layer?.backgroundColor = NSColor.black.cgColor
        gridSlot.isHidden = true
        stage.addSubview(gridSlot)
        NSLayoutConstraint.activate([
            gridSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            gridSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            gridSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            gridSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            vmDashboardSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            vmDashboardSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            vmDashboardSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            vmDashboardSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
        // File-pane sizing: restore the persisted width; closed = 0pt + hidden.
        // High-but-not-required priority so the framebuffer's minimum width
        // wins over the pane on narrow windows.
        let fpStored = UserDefaults.standard.double(forKey: Self.filePaneWidthKey)
        expandedFilePaneWidth = fpStored >= Self.filePaneMinWidth
            ? fpStored : Self.filePaneDefaultWidth
        filePaneOpen = UserDefaults.standard.bool(forKey: Self.filePaneOpenKey)
        listModel.filePaneOpen = filePaneOpen
        filePaneHost.isHidden = !filePaneOpen
        filePaneHandle.isHidden = !filePaneOpen
        let filePaneWidth = filePaneHost.widthAnchor.constraint(
            equalToConstant: filePaneOpen ? expandedFilePaneWidth : 0)
        filePaneWidth.priority = .defaultHigh
        self.filePaneWidthConstraint = filePaneWidth
        // Same shape as the sidebar handle: proposed width from the mouse x,
        // measured from the RIGHT edge; under the minimum closes the pane.
        filePaneHandle.onResize = { [weak self] x in
            guard let self, self.filePaneOpen else { return }
            let width = self.stage.bounds.width - x
            if width < Self.filePaneMinWidth {
                self.setFilePaneOpen(false, animated: true)
            } else {
                self.filePaneWidthConstraint?.constant = min(Self.filePaneMaxWidth, width)
            }
        }
        filePaneHandle.onResizeEnd = { [weak self] in
            guard let self, self.filePaneOpen,
                  let w = self.filePaneWidthConstraint?.constant,
                  w >= Self.filePaneMinWidth else { return }
            self.expandedFilePaneWidth = w
            UserDefaults.standard.set(w, forKey: Self.filePaneWidthKey)
        }
        // Browser-pane sizing: closed = 0pt + hidden (opened on demand, not
        // persisted — the ephemeral browser doesn't survive a restart).
        let bpStored = UserDefaults.standard.double(forKey: Self.browserPaneWidthKey)
        expandedBrowserPaneWidth = bpStored >= Self.browserPaneMinWidth
            ? bpStored : Self.browserPaneDefaultWidth
        let browserPaneWidth = browserPaneHost.widthAnchor.constraint(equalToConstant: 0)
        browserPaneWidth.priority = .defaultHigh
        self.browserPaneWidthConstraint = browserPaneWidth
        browserPaneHandle.onResize = { [weak self] x in
            guard let self, self.browserPaneOpen else { return }
            // Middle pane: its right edge is the file pane's left edge, so
            // subtract the file pane's width (0 when closed) from the stage
            // right edge before measuring.
            let fileW = self.filePaneOpen ? (self.filePaneWidthConstraint?.constant ?? 0) : 0
            let width = self.stage.bounds.width - fileW - x
            if width < Self.browserPaneMinWidth {
                self.setBrowserPaneOpen(false, animated: true)
            } else {
                self.browserPaneWidthConstraint?.constant = self.clampedBrowserPaneWidth(width)
            }
        }
        browserPaneHandle.onResizeEnd = { [weak self] in
            guard let self, self.browserPaneOpen,
                  let w = self.browserPaneWidthConstraint?.constant,
                  w >= Self.browserPaneMinWidth else { return }
            self.expandedBrowserPaneWidth = w
            UserDefaults.standard.set(w, forKey: Self.browserPaneWidthKey)
        }
        let paneSlotMin = paneSlot.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.terminalSlotMinWidth)
        paneSlotMin.priority = .init(999)   // beats the pane width, yields last
        NSLayoutConstraint.activate([
            paneSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            paneSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            paneSlot.trailingAnchor.constraint(equalTo: browserPaneHost.leadingAnchor),
            paneSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            paneSlotMin,
            filePaneHost.topAnchor.constraint(equalTo: stage.topAnchor),
            filePaneHost.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            // Right-split chain: paneSlot | browserPane | filePane | stage edge
            // (terminal, browser, files). Both right panes collapse to width 0
            // when closed, so paneSlot fills whatever they leave.
            filePaneHost.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            filePaneWidth,
            // 8pt grab strip over the pane's leading edge, full height.
            filePaneHandle.centerXAnchor.constraint(equalTo: filePaneHost.leadingAnchor),
            filePaneHandle.topAnchor.constraint(equalTo: stage.topAnchor),
            filePaneHandle.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            filePaneHandle.widthAnchor.constraint(equalToConstant: 8),
            browserPaneHost.topAnchor.constraint(equalTo: stage.topAnchor),
            browserPaneHost.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            browserPaneHost.trailingAnchor.constraint(equalTo: filePaneHost.leadingAnchor),
            browserPaneWidth,
            browserPaneHandle.centerXAnchor.constraint(equalTo: browserPaneHost.leadingAnchor),
            browserPaneHandle.topAnchor.constraint(equalTo: stage.topAnchor),
            browserPaneHandle.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            browserPaneHandle.widthAnchor.constraint(equalToConstant: 8),
            emptyStateHost.topAnchor.constraint(equalTo: paneSlot.topAnchor),
            emptyStateHost.leadingAnchor.constraint(equalTo: paneSlot.leadingAnchor),
            emptyStateHost.trailingAnchor.constraint(equalTo: paneSlot.trailingAnchor),
            emptyStateHost.bottomAnchor.constraint(equalTo: paneSlot.bottomAnchor),
            dockerSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            dockerSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            dockerSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            dockerSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            automationSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            automationSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            automationSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            automationSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            kanbanSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            kanbanSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            kanbanSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            kanbanSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            taskBoardSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            taskBoardSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            taskBoardSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            taskBoardSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])

        // ---- Layout: resizable sidebar | divider | framebuffer stage ----
        // Plain Auto Layout (no NSSplitView) so the stage deterministically
        // fills everything to the right of the sidebar — Mail.app shape. Width
        // is user-resizable via a drag handle over the divider, persisted.
        let root = NSView()
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        // Opaque backing behind the hairline. `separatorColor` has alpha, and
        // on translucent-profile windows (isOpaque = false, clear background)
        // this 1pt column would otherwise composite straight onto the desktop
        // — a see-through slit between the sidebar and the terminal.
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        let resizeHandle = SidebarResizeHandle()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarHost)
        root.addSubview(divider)
        root.addSubview(stage)
        root.addSubview(resizeHandle)   // above the divider so it gets the drag
        let stored = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        let initialWidth = stored >= Self.sidebarMinWidth ? stored : Self.sidebarDefaultWidth
        expandedSidebarWidth = initialWidth
        let sidebarWidth = sidebarHost.widthAnchor.constraint(equalToConstant: initialWidth)
        self.sidebarWidthConstraint = sidebarWidth
        self.sidebarDivider = divider
        sidebarHost.clipsToBounds = true   // squish cleanly during collapse
        // Dragging under the minimum snaps to the icon rail; dragging back
        // past it expands again — the drag handle IS the collapse control.
        resizeHandle.onResize = { [weak self] x in
            guard let self else { return }
            if x < Self.sidebarMinWidth {
                self.setSidebarCollapsed(true, animated: true)
            } else {
                self.setSidebarCollapsed(false, animated: false)
                self.sidebarWidthConstraint?.constant = min(Self.sidebarMaxWidth, x)
            }
        }
        // Persist the preferred width once, at drag end — never the transient
        // widths passed through on the way to a collapse.
        resizeHandle.onResizeEnd = { [weak self] in
            guard let self, !self.sidebarCollapsed,
                  let w = self.sidebarWidthConstraint?.constant else { return }
            self.expandedSidebarWidth = w
            UserDefaults.standard.set(w, forKey: Self.sidebarWidthKey)
        }
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            divider.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // 8pt grab strip centered on the divider, full height.
            resizeHandle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),

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
            onToggleFusion: { [weak self] id, on in if let p = self?.pane(id) { self?.acDelegate?.setFusionEngaged(on, for: p.profile) } },
            onToggleFilePane: { [weak self] in self?.toggleFilePane(nil) },
            onToggleBrowser: { [weak self] in self?.toggleBrowserPane(nil) })
        let tbDelegate = UnifiedToolbarDelegate(rootView: toolbarBar)
        self.toolbarDelegate = tbDelegate
        let bar = NSToolbar(identifier: "io.bromure.ac.unified")
        bar.delegate = tbDelegate
        bar.displayMode = .iconOnly
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        toolbarStyle = .unified
        self.toolbar = bar

        // The file explorer's queries run in the selected VM's guest over the
        // shell vsock — never the virtio share (remote-access friendly).
        fileExplorerModel.execProvider = { [weak self] id, command, timeout in
            guard let delegate = self?.acDelegate else {
                throw ACAppDelegate.GuestExecError.vmNotRunning
            }
            return try await delegate.guestExec(profileID: id, command: command,
                                                timeout: timeout)
        }

        updateEmptyState()
    }

    // MARK: File-explorer pane

    /// ⌃⌘E / the toolbar's sidebar.right button.
    @objc func toggleFilePane(_ sender: Any?) {
        setFilePaneOpen(!filePaneOpen, animated: true)
    }

    /// Open/close the right file pane. Closed = width 0 and hidden (no rail);
    /// drag-to-close under the min width lands here too. Open state persists
    /// so the pane comes back after an app restart.
    func setFilePaneOpen(_ open: Bool, animated: Bool) {
        guard open != filePaneOpen else { return }
        filePaneOpen = open
        listModel.filePaneOpen = open
        UserDefaults.standard.set(open, forKey: Self.filePaneOpenKey)
        filePaneResizeHandle?.isHidden = !open
        if open { filePaneHost.isHidden = false }
        let target = open ? expandedFilePaneWidth : 0
        let hideWhenClosed: () -> Void = { [weak self] in
            guard let self, !self.filePaneOpen else { return }
            self.filePaneHost.isHidden = true
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                filePaneWidthConstraint?.animator().constant = target
                contentView?.layoutSubtreeIfNeeded()
            }, completionHandler: hideWhenClosed)
        } else {
            filePaneWidthConstraint?.constant = target
            hideWhenClosed()
        }
    }

    // MARK: Browser pane

    /// ⌃⌘B / the toolbar globe. Opening it lazily brings up the workspace's
    /// ephemeral browser VM (phase 2 wires WorkspaceBrowserController here).
    @objc func toggleBrowserPane(_ sender: Any?) {
        setBrowserPaneOpen(!browserPaneOpen, animated: true)
    }

    // MARK: - Per-workspace browsers

    private func browserModel(for id: Profile.ID) -> BrowserPaneModel {
        if let m = browserModels[id] { return m }
        let m = BrowserPaneModel()
        browserModels[id] = m
        return m
    }

    /// The workspace's browser controller, created lazily. The MCP server and
    /// the pane both drive through this.
    func browserController(for id: Profile.ID) -> WorkspaceBrowserController {
        if let c = browserControllers[id] { return c }
        let profile = acDelegate?.profiles.first { $0.id == id }
        let c = WorkspaceBrowserController(
            model: browserModel(for: id), workspaceID: id,
            persistent: profile?.browserPersistent ?? false,
            permissions: .init(
                allowUploads: profile?.browserAllowUploads ?? true,
                allowDownloads: profile?.browserAllowDownloads ?? true,
                webcam: profile?.browserWebcam ?? false,
                microphone: profile?.browserMicrophone ?? false))
        // ⌘T inside the browser opens a new terminal SHELL (its new-tab is ⇧⌘T).
        c.onNewShell = { [weak self] in self?.newTab(profileID: id) }
        browserControllers[id] = c
        return c
    }

    /// Existing controller for the MCP `browser` resolver (nil if never made).
    func existingBrowserController(for id: Profile.ID) -> WorkspaceBrowserController? {
        browserControllers[id]
    }

    /// Boot/resume a workspace's browser for an MCP tool call. When the
    /// agent STARTS a browser for the workspace the user is looking at,
    /// reveal the pane — they asked the agent to browse, so show them the
    /// browser (this also surfaces the first-run install consent card).
    /// Background workspaces boot hidden, and an already-running browser
    /// whose pane the user closed stays closed — later tool calls don't
    /// fight the user's choice.
    func ensureBrowserForMCP(_ id: Profile.ID) {
        let controller = browserController(for: id)
        if selectedID == id, !browserPaneOpen, controller.state == .idle {
            // Opens the pane AND boots via showBrowser → setVisible(true).
            setBrowserPaneOpen(true, animated: true)
            return
        }
        controller.ensureRunning()
    }

    /// Point the pane at `id`'s browser and mark it visible; hide the
    /// previously-shown one so its collapse timers arm.
    private func showBrowser(for id: Profile.ID) {
        if let prev = shownBrowser, prev != id {
            // Hidden by a workspace switch, not a collapse: suspend-only —
            // it must stay resumable until the sidebar itself closes.
            browserControllers[prev]?.setVisible(false, teardownWhenHidden: false)
        }
        shownBrowser = id
        browserPaneHost.rootView = BrowserPaneView(model: browserModel(for: id))
        browserController(for: id).setVisible(true)
    }

    /// Called by `select(profileID:)` when the shown workspace changes:
    /// animate the pane to the newly selected workspace's remembered
    /// open/closed state, swapping (or hiding) the browser accordingly.
    func browserPaneDidChangeWorkspace() {
        applyBrowserPaneState(animated: true)
    }

    /// Stop and discard every workspace browser (window close / app quit).
    func teardownBrowserVM() {
        for (_, c) in browserControllers { c.stop() }
        browserControllers.removeAll()
        browserModels.removeAll()
        browserPaneOpenWorkspaces.removeAll()
        shownBrowser = nil
    }

    /// Recreate a workspace's browser so changed settings (the
    /// stay-signed-in persistence toggle) take effect now: tear down the
    /// current VM/controller and — when this workspace is front and
    /// center with the pane open — boot the replacement immediately. The
    /// new controller re-reads the saved profile at creation.
    func rebootBrowser(for id: Profile.ID) {
        guard browserControllers[id] != nil else { return }   // never opened
        let wasOpen = browserPaneOpenWorkspaces.contains(id)
        let wasShown = browserPaneOpen && shownBrowser == id
        teardownBrowser(for: id)
        // teardownBrowser clears the workspace's pane-open state; a reboot
        // is transient, so restore it (the browser lives as long as its
        // pane is open).
        if wasOpen { browserPaneOpenWorkspaces.insert(id) }
        if wasShown, selectedID == id {
            showBrowser(for: id)
        }
    }

    /// Tear down one workspace's browser (its session ended).
    func teardownBrowser(for id: Profile.ID) {
        browserControllers[id]?.stop()
        browserControllers[id] = nil
        browserModels[id] = nil
        browserPaneOpenWorkspaces.remove(id)
        if shownBrowser == id {
            shownBrowser = nil
            browserPaneHost.rootView = BrowserPaneView(model: browserPlaceholderModel)
        }
    }

    func setBrowserPaneOpen(_ open: Bool, animated: Bool) {
        guard let id = selectedID else { return }
        guard open != browserPaneOpenWorkspaces.contains(id) else { return }
        if open { browserPaneOpenWorkspaces.insert(id) }
        else { browserPaneOpenWorkspaces.remove(id) }
        // collapsedWorkspace = the workspace whose pane the user just
        // closed — only THAT browser is armed for teardown; every other
        // workspace's browser keeps living on its own pane state.
        applyBrowserPaneState(animated: animated, collapsedWorkspace: open ? nil : id)
    }

    /// The widest the browser pane may be right now: never so wide the
    /// terminal slot drops below its minimum, nor past the hard max. This
    /// is what stops opening OR dragging the pane from growing the window
    /// off-screen — the pane-width constraint outranks NSWindow's
    /// windowSizeStayPut, so an over-wide value pushes the window edge
    /// past the screen instead of squeezing the terminal.
    private func clampedBrowserPaneWidth(_ desired: CGFloat) -> CGFloat {
        let fileW = filePaneOpen ? (filePaneWidthConstraint?.constant ?? 0) : 0
        let available = stage.bounds.width - fileW - Self.terminalSlotMinWidth
        return max(Self.browserPaneMinWidth,
                   min(desired, min(Self.browserPaneMaxWidth, available)))
    }

    /// Reconcile the pane UI + browser visibility to the SELECTED
    /// workspace's remembered open/closed state. Opening/collapsing the
    /// pane and switching workspaces both funnel here.
    private func applyBrowserPaneState(animated: Bool, collapsedWorkspace: Profile.ID? = nil) {
        let open = browserPaneOpen
        listModel.browserPaneOpen = open
        browserPaneResizeHandle?.isHidden = !open

        if open, let id = selectedID {
            browserPaneHost.isHidden = false
            // Boots/resumes id and suspends (never tears down) the
            // previously shown one — it stays alive on its own pane state.
            showBrowser(for: id)
        } else if let prev = shownBrowser {
            // Pane collapsed for the selected workspace: hide the shown
            // browser. Arm teardown ONLY when the user explicitly closed
            // that workspace's pane; a plain switch-away is suspend-only.
            browserControllers[prev]?.setVisible(false,
                teardownWhenHidden: prev == collapsedWorkspace)
            shownBrowser = nil
        }

        let target = open ? clampedBrowserPaneWidth(expandedBrowserPaneWidth) : 0
        let hideWhenClosed: () -> Void = { [weak self] in
            guard let self, !self.browserPaneOpen else { return }
            self.browserPaneHost.isHidden = true
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                self.browserPaneWidthConstraint?.animator().constant = target
                self.contentView?.layoutSubtreeIfNeeded()
            }, completionHandler: hideWhenClosed)
        } else {
            browserPaneWidthConstraint?.constant = target
            hideWhenClosed()
        }
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
        if vmDashboardSelectedID == id { clearVMDashboard() }
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
        // If the browser pane is open, swap it to this workspace's browser.
        browserPaneDidChangeWorkspace()
    }

    // MARK: Sidebar collapse

    /// ⌃⌘S. Collapsed = a 44pt icon rail (one icon per terminal, separators
    /// between workspaces) so the stage — especially the grid — gets nearly
    /// the full width without losing navigation.
    @objc func toggleSidebar(_ sender: Any?) {
        setSidebarCollapsed(!sidebarCollapsed, animated: true)
    }

    /// Collapse/expand — animated from ⌃⌘S, immediate when the drag handle
    /// crosses the width threshold (the cursor is already mid-motion, so a
    /// snap tracks better than an animation). `expandedSidebarWidth` is NOT
    /// captured here: it's maintained at init and drag-end only, so a
    /// drag-to-collapse can't overwrite the preferred width with the ~100pt
    /// value it passed through on the way down.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        sidebarCollapsed = collapsed
        listModel.sidebarCollapsed = collapsed   // SwiftUI swaps to the rail
        let target = collapsed ? Self.sidebarRailWidth : expandedSidebarWidth
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                sidebarWidthConstraint?.animator().constant = target
                contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            sidebarWidthConstraint?.constant = target
        }
    }

    // MARK: Grid overlay

    /// Show the terminal grid as the stage surface.
    func showGrid() {
        guard clearAutomationEditor() else { return }   // dirty draft kept
        clearAutomationBoard()
        clearTaskBoard()
        clearDockerDashboard()
        clearVMDashboard()
        listModel.gridSelected = true
        if gridView == nil {
            let dataSource = GridStageView.DataSource(
                profile: { [weak self] pid in
                    self?.acDelegate?.profiles.first { $0.id == pid }
                },
                tabsModel: { [weak self] pid in
                    self?.listModel.entries.first { $0.id == pid }?.model
                },
                runState: { [weak self] pid in
                    self?.listModel.profileRows.first { $0.id == pid }?.state ?? .off
                },
                onStart: { [weak self] pid in self?.acDelegate?.startProfile(pid) },
                onJump: { [weak self] pid, windowIndex in
                    self?.jumpFromGrid(profileID: pid, windowIndex: windowIndex)
                })
            let v = GridStageView(store: gridStore, dataSource: dataSource)
            v.translatesAutoresizingMaskIntoConstraints = false
            gridSlot.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: gridSlot.topAnchor),
                v.leadingAnchor.constraint(equalTo: gridSlot.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: gridSlot.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: gridSlot.bottomAnchor),
            ])
            gridView = v
        }
        gridSlot.isHidden = false
        gridView?.reconcile()
    }

    /// Hide the grid and release its surfaces (membership persists).
    func hideGrid() {
        guard listModel.gridSelected else { return }
        listModel.gridSelected = false
        gridSlot.isHidden = true
        gridView?.retireAll()
    }

    /// Grid cell "open in workspace": leave the grid on that terminal's tab.
    private func jumpFromGrid(profileID: Profile.ID, windowIndex: Int) {
        hideGrid()
        if let entry = listModel.entries.first(where: { $0.id == profileID }),
           let position = entry.model.tabs.firstIndex(where: { $0.index == windowIndex }) {
            selectTab(profileID: profileID, index: position)
        } else {
            selectRow(profileID)
        }
    }

    func addToGrid(profileID: Profile.ID, windowIndex: Int, label: String) {
        gridStore.add(profileID: profileID, windowIndex: windowIndex, label: label)
        if listModel.gridSelected { gridView?.reconcile() }
    }

    /// ⌘D: pin a terminal AND land on it — switches the stage to the grid
    /// and hands the (possibly pre-existing) cell keyboard focus.
    func addToGridAndReveal(profileID: Profile.ID, windowIndex: Int, label: String) {
        gridStore.add(profileID: profileID, windowIndex: windowIndex, label: label)
        showGrid()   // creates the grid view if needed + reconciles, so the cell exists
        gridView?.focusCell(id: GridCell.id(profileID: profileID, windowIndex: windowIndex))
    }

    /// Bulk convenience: every worktree tab of a workspace into the grid.
    func addAllWorktreesToGrid(profileID: Profile.ID) {
        guard let entry = listModel.entries.first(where: { $0.id == profileID }) else { return }
        for tab in entry.model.tabs where tab.isWorktree {
            gridStore.add(profileID: profileID, windowIndex: tab.index, label: tab.shownLabel)
        }
        if listModel.gridSelected { gridView?.reconcile() }
    }

    /// Select any profile row — running or not. A running, attached profile
    /// mounts its framebuffer; a running-but-detached one reattaches; an
    /// off/suspended one shows its Start card in the stage.
    func selectRow(_ id: Profile.ID) {
        hideGrid()
        clearAutomationBoard()
        clearTaskBoard()
        clearDockerDashboard()
        clearVMDashboard()
        selectedID = id
        listModel.selectedID = id
        browserPaneDidChangeWorkspace()   // swap the browser pane to this workspace
        if let pane = pane(id) { mountSelected(pane); return }
        let state = listModel.profileRows.first { $0.id == id }?.state ?? .off
        switch state {
        case .running, .booting:
            acDelegate?.connectProfile(id)   // reattach a backgrounded VM
        case .off, .suspended:
            mountSelected(nil)               // drop any stale framebuffer behind the overlay
            showVMDashboard(id)              // spec + config dashboard, not a bare "is down" card
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
        pane.updateNativeTerminalMount()
        makeFirstResponder(pane.preferredFirstResponder)
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
        guard clearAutomationEditor() else { return }   // dirty draft kept
        clearAutomationBoard()
        clearTaskBoard()
        hideGrid()
        clearVMDashboard()
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

    // MARK: VM dashboard overlay

    /// Show the workspace VM dashboard (vitals + config) over the framebuffer.
    /// Shown for any run state: a running VM gets live vitals; a suspended/off
    /// one shows the spec + config (more useful than a black framebuffer).
    func showVMDashboard(_ id: Profile.ID) {
        guard let profile = acDelegate?.profile(for: id) else { return }
        guard clearAutomationEditor() else { return }   // dirty draft kept
        clearAutomationBoard()
        clearTaskBoard()
        clearDockerDashboard()
        let p = pane(id)
        let state = listModel.profileRows.first { $0.id == id }?.state ?? (p != nil ? .running : .off)
        vmDashboardSelectedID = id
        vmDashboardHosting?.removeFromSuperview()
        let info = acDelegate?.vmDashboardData(for: id)
        let view = VMDashboardView(
            model: p?.model,
            profile: p?.profile ?? profile,
            accentHex: (p?.profile ?? profile).color.hexInUI,
            state: state,
            vCPUs: UbuntuSandboxVM.runtimeCPUs,
            diskAllocatedBytes: info?.diskAllocated ?? 0,
            diskCapacityBytes: info?.diskCapacity ?? 0,
            startedAt: info?.startedAt,
            onNewTerminal: { [weak self] in self?.newTab(profileID: id) },
            onSuspend:     { [weak self] in self?.acDelegate?.suspendProfile(id) },
            onReboot:      { [weak self] in self?.acDelegate?.restartProfile(id) },
            onShutdown:    { [weak self] in self?.acDelegate?.shutdownProfile(id) },
            onResume:      { [weak self] in self?.acDelegate?.startProfile(id); self?.clearVMDashboard() })
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        vmDashboardSlot.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: vmDashboardSlot.topAnchor),
            host.bottomAnchor.constraint(equalTo: vmDashboardSlot.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: vmDashboardSlot.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: vmDashboardSlot.trailingAnchor),
        ])
        vmDashboardHosting = host
        updateVMOverlay()
    }

    func clearVMDashboard() {
        guard vmDashboardSelectedID != nil else { return }
        vmDashboardSelectedID = nil
        vmDashboardHosting?.removeFromSuperview()
        vmDashboardHosting = nil
        updateVMOverlay()
    }

    private func updateVMOverlay() {
        vmDashboardSlot.isHidden = (vmDashboardSelectedID == nil)
    }

    // MARK: Automation editor overlay

    /// Show the automation editor as the stage surface — an existing
    /// automation's, or a blank one (id = nil, the sidebar "+").
    /// Rebuilt on every show so the profile snapshot (names, credentials,
    /// ask-before-use flags) is current.
    func showAutomationEditor(_ id: UUID?, prefill: AutomationPrefill? = nil) {
        guard let delegate = acDelegate else { return }
        if automationEditorVisible {
            // Re-clicking the automation that's already open must not
            // silently rebuild over an edited draft — keep the editor as-is.
            if id != nil, id == listModel.automationSelectedID,
               automationDraftDirty { return }
            // Switching to another automation (or "+") discards the current
            // draft — same warning as any other navigation away.
            guard clearAutomationEditor() else { return }
        }
        hideGrid()
        clearAutomationBoard()
        clearTaskBoard()
        clearDockerDashboard()
        clearVMDashboard()
        automationEditorVisible = true
        automationDraftDirty = false
        listModel.automationSelectedID = id
        automationHosting?.removeFromSuperview()
        let view = AutomationEditorView(
            store: delegate.scheduledAutomationStore,
            profiles: delegate.profiles,
            editing: id,
            prefill: prefill,
            onSave: { [weak self] automation in
                self?.acDelegate?.saveAutomation(automation)
                self?.clearAutomationEditor(force: true)
            },
            onRunNow: { [weak self] automation in
                self?.acDelegate?.saveAutomation(automation)
                self?.acDelegate?.runAutomationNow(automation.id)
                self?.clearAutomationEditor(force: true)
            },
            onDelete: { [weak self] automationID in
                self?.acDelegate?.confirmDeleteAutomation(automationID)
            },
            onEditWorkspace: { [weak self] profileID in
                self?.acDelegate?.sidebarEditProfile(profileID)
            },
            onDirtyChange: { [weak self] dirty in
                self?.automationDraftDirty = dirty
            })
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        automationSlot.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: automationSlot.topAnchor),
            host.bottomAnchor.constraint(equalTo: automationSlot.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: automationSlot.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: automationSlot.trailingAnchor),
        ])
        automationHosting = host
        automationSlot.isHidden = false
        makeFirstResponder(host)
    }

    /// Tear the editor down. An edited draft warns first; false = the user
    /// chose to keep editing, so the caller must abort its navigation.
    /// `force` skips the warning — for after a save/delete, when the draft
    /// is no longer worth anything.
    @discardableResult
    func clearAutomationEditor(force: Bool = false) -> Bool {
        guard automationEditorVisible else { return true }
        if !force, automationDraftDirty {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Discard changes to this automation?", comment: "")
            alert.informativeText = NSLocalizedString(
                "You edited this automation but didn't save. Leaving now discards those changes.",
                comment: "")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Keep Editing", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Discard Changes", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn { return false }
        }
        automationEditorVisible = false
        automationDraftDirty = false
        listModel.automationSelectedID = nil
        automationHosting?.removeFromSuperview()
        automationHosting = nil
        automationSlot.isHidden = true
        return true
    }

    /// Show the automation kanban board as the stage surface: Scheduled /
    /// In Progress / (Needs Attention) / Done. The hosting view is built
    /// once and kept — everything it renders reads live observable state.
    func showAutomationBoard() {
        guard let delegate = acDelegate else { return }
        guard clearAutomationEditor() else { return }   // dirty draft kept
        hideGrid()
        clearTaskBoard()
        clearDockerDashboard()
        clearVMDashboard()
        listModel.automationBoardSelected = true
        if kanbanHosting == nil {
            let view = AutomationKanbanView(
                store: delegate.scheduledAutomationStore,
                model: listModel,
                actions: AutomationKanbanView.Actions(
                    selectAutomation: { [weak self] id in self?.showAutomationEditor(id) },
                    newAutomation: { [weak self] in self?.showAutomationEditor(nil) },
                    runNow: { [weak self] id in self?.acDelegate?.runAutomationNow(id) },
                    toggle: { [weak self] id in self?.acDelegate?.toggleAutomation(id) },
                    delete: { [weak self] id in self?.acDelegate?.confirmDeleteAutomation(id) },
                    openRun: { [weak self] run in self?.acDelegate?.openAutomationRun(run) },
                    acknowledge: { [weak self] id in
                        self?.acDelegate?.scheduledAutomationStore.acknowledge(id)
                    }))
            let host = NSHostingView(rootView: view)
            // The board's SwiftUI max-width must never resize the WINDOW —
            // same required-constraint gotcha as the file pane (sizingOptions).
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            kanbanSlot.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: kanbanSlot.topAnchor),
                host.bottomAnchor.constraint(equalTo: kanbanSlot.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: kanbanSlot.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: kanbanSlot.trailingAnchor),
            ])
            kanbanHosting = host
        }
        kanbanSlot.isHidden = false
    }

    /// Hide the board (the hosting view is kept for the next show).
    func clearAutomationBoard() {
        guard listModel.automationBoardSelected else { return }
        listModel.automationBoardSelected = false
        kanbanSlot.isHidden = true
    }

    /// Show the coding-task kanban board (Backlog / In Progress / Testing /
    /// Done) as the stage surface.
    func showTaskBoard() {
        guard let delegate = acDelegate else { return }
        guard clearAutomationEditor() else { return }   // dirty draft kept
        hideGrid()
        clearAutomationBoard()
        clearDockerDashboard()
        clearVMDashboard()
        listModel.taskBoardSelected = true
        if taskBoardHosting == nil {
            let view = CodingKanbanView(
                store: delegate.codingTaskStore,
                model: listModel,
                profilesProvider: { [weak self] in self?.acDelegate?.profiles ?? [] },
                actions: CodingKanbanView.Actions(
                    start: { [weak self] id in self?.acDelegate?.codingTaskEngine.start(id) },
                    plan: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.plan(id)
                        // The interview happens HERE, in the native window —
                        // the worktree tab is just the machinery underneath.
                        self?.acDelegate?.planSessionWindows.open(taskID: id)
                    },
                    openReview: { [weak self] id in
                        self?.acDelegate?.taskReviewWindows.open(taskID: id)
                    },
                    jumpToRun: { [weak self] task in
                        guard let slug = task.branchSlug else { return }
                        self?.focusWorktreeTab(profileID: task.profileID, slug: slug)
                    },
                    moveToTesting: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.moveToTesting(id)
                    },
                    backToInProgress: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.moveToInProgress(id)
                    },
                    merge: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.merge(id)
                    },
                    closeNoMerge: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.closeWithoutMerge(id)
                    },
                    delete: { [weak self] id in
                        self?.acDelegate?.codingTaskStore.remove(id)
                        self?.acDelegate?.codingTaskEngine.pumpQueue()
                    },
                    save: { [weak self] task in
                        self?.acDelegate?.codingTaskStore.upsert(task)
                    },
                    validate: { [weak self] task in
                        // Persist the draft first so the result has a home.
                        self?.acDelegate?.codingTaskStore.upsert(task)
                        self?.acDelegate?.codingTaskEngine.validate(task.id)
                    },
                    openPlanSession: { [weak self] id in
                        self?.acDelegate?.planSessionWindows.open(taskID: id)
                    },
                    destroy: { [weak self] id in
                        self?.acDelegate?.codingTaskEngine.destroy(id)
                    }))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            taskBoardSlot.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: taskBoardSlot.topAnchor),
                host.bottomAnchor.constraint(equalTo: taskBoardSlot.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: taskBoardSlot.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: taskBoardSlot.trailingAnchor),
            ])
            taskBoardHosting = host
        }
        taskBoardSlot.isHidden = false
    }

    func clearTaskBoard() {
        guard listModel.taskBoardSelected else { return }
        listModel.taskBoardSelected = false
        taskBoardSlot.isHidden = true
    }

    /// Land on a worktree tab from a board card: leave any overlay and
    /// select the tab (main-window position) — the grid's jump, reused.
    func focusWorktreeTab(profileID: Profile.ID, slug: String) {
        clearTaskBoard()
        clearAutomationBoard()
        hideGrid()
        if let entry = listModel.entries.first(where: { $0.id == profileID }),
           let position = entry.model.tabs.firstIndex(where: {
               AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
           }) {
            selectTab(profileID: profileID, index: position)
        } else {
            selectRow(profileID)
        }
        makeKeyAndOrderFront(nil)
    }

    /// Workspace name clicked in the source list → select it and surface its
    /// dashboard, whether the VM is running, suspended, or off.
    func selectWorkspaceName(_ id: Profile.ID) {
        guard clearAutomationEditor() else { return }   // dirty draft kept
        selectRow(id)
        showVMDashboard(id)
    }

    /// Honour the selected profile's terminal-transparency setting. The pane's
    /// own container layer carries the alpha; here we flip the *window* to
    /// non-opaque and clear the *stage* backing so that alpha composites against
    /// the desktop — frosted by the window-server blur — and ONLY the
    /// framebuffer: the sidebar/divider/titlebar stay opaque. Opaque profiles
    /// keep the solid black stage (nice during boot).
    private func applyOpacityChrome(for pane: SessionPane?) {
        let opacity = pane.map { min(1.0, max(0.3, $0.profile.windowOpacity)) } ?? 1.0
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
            stage.layer?.backgroundColor = NSColor.clear.cgColor
            setBackgroundFrost(radius: Self.terminalFrostRadius)
        } else {
            isOpaque = true
            backgroundColor = nil
            stage.layer?.backgroundColor = NSColor.black.cgColor
            setBackgroundFrost(radius: 0)
        }
    }

    // MARK: Tab actions (forward to the pane)

    func selectTab(profileID id: Profile.ID, index: Int) {
        guard clearAutomationEditor() else { return }   // dirty draft kept
        hideGrid()
        // The boards overlay the stage: without this, clicking a sidebar
        // tab while a kanban is up switches the (hidden) terminal and
        // looks like a dead click.
        clearTaskBoard()
        clearAutomationBoard()
        clearDockerDashboard()
        clearVMDashboard()
        if selectedID != id { select(profileID: id) }
        pane(id)?.switchTo(index: index)
    }
    func newTab(profileID id: Profile.ID) {
        guard clearAutomationEditor() else { return }   // dirty draft kept
        hideGrid()
        clearTaskBoard()
        clearAutomationBoard()
        clearDockerDashboard()
        clearVMDashboard()
        if selectedID != id { select(profileID: id) }
        if let p = pane(id) { acDelegate?.spawnNewTab(in: p) }
    }
    func closeTab(profileID id: Profile.ID, index: Int) {
        pane(id)?.closeTab(at: index)
    }

    /// Right-click worktree actions. Reads the tab + its VM's primary tool and
    /// hands off to the delegate (dialogs + guest commands).
    func handleTabAction(profileID id: Profile.ID, index: Int, action: TabAction) {
        guard let p = pane(id), index < p.model.tabs.count else { return }
        let tab = p.model.tabs[index]
        let tool = p.profile.tool.rawValue
        switch action {
        case .newWorktree:
            guard let cwd = tab.cwd, !cwd.isEmpty else {
                // No cwd from the roster — almost always a VM still running an
                // older guest agent (worktrees shipped later). Tell the user
                // the fix instead of failing silently.
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("This tab's working directory isn't available yet", comment: "")
                alert.informativeText = NSLocalizedString(
                    "The workspace is likely running an older in-VM agent. Restart the workspace (Shutdown, then Start) so it picks up worktree support, then try again.",
                    comment: "")
                alert.runModal()
                return
            }
            acDelegate?.presentCreateWorktree(cwd: cwd, defaultTool: tool, in: p)
        case .merge:
            acDelegate?.presentMergeWorktree(tab: tab, allTabs: p.model.tabs, in: p)
        case .attachTerminal:
            guard let branch = tab.worktreeBranch, !branch.isEmpty,
                  let root = tab.rootRepo, !root.isEmpty else { return }
            acDelegate?.requestAttachTerminal(mainRoot: root, branch: branch, in: p)
        case .removeWorktree:
            acDelegate?.confirmRemoveWorktree(tab: tab, in: p)
        case .resolveConflicts:
            guard let dir = tab.cwd else { return }
            acDelegate?.requestResolveWorktree(dir: dir, tool: tool, in: p)
        case .createAutomation:
            showAutomationEditor(nil, prefill: AutomationPrefill(
                profileID: id, repoPath: tab.cwd ?? "~"))
        }
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
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return pane.performACShortcut(chars, isRepeat: event.isARepeat)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        installOpaqueTitlebarBacking()
    }

    override func sendEvent(_ event: NSEvent) {
        // ⌃⌘S — hide/show the sidebar (classic macOS chord).
        // ⌃⌘E — hide/show the file-explorer pane.
        // ⌃⌘B — hide/show the agentic browser pane.
        if event.type == .keyDown,
           event.modifierFlags.contains([.command, .control]),
           let chord = event.charactersIgnoringModifiers?.lowercased(),
           chord == "s" || chord == "e" || chord == "b" {
            switch chord {
            case "s": toggleSidebar(nil)
            case "e": toggleFilePane(nil)
            default:  toggleBrowserPane(nil)
            }
            return
        }
        if event.type == .keyDown, handleACShortcut(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⇧⌘T → new browser tab (⌘T is the shell shortcut). Caught here, before
        // the keystroke reaches the guest, when a browser pane is shown.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "t",
           let id = shownBrowser, let ctl = browserControllers[id] {
            ctl.newTab("")
            return true
        }
        if handleACShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Sidebar SwiftUI

// Internal (not private) so the fat-client `RemoteHostWindow` can reuse the
// exact same sidebar to render a mirrored remote host 1:1.
struct SessionSidebar: View {
    @Bindable var model: SessionListModel
    /// Grid membership — drives the pinned Grid node and its children.
    let gridStore: GridLayoutStore
    let onSelectGrid: () -> Void
    let onRemoveGridCell: (String) -> Void
    let onFocusGridCell: (String) -> Void
    /// Drop of a `GridDragPayload` string onto the Grid node.
    let onDropGridPayload: (String) -> Bool
    let onAddAllToGrid: (Profile.ID) -> Void
    let onSelect: (Profile.ID) -> Void
    let onSelectTab: (Profile.ID, Int) -> Void
    let onNewTab: (Profile.ID) -> Void
    let onCloseTab: (Profile.ID, Int) -> Void
    /// Right-click worktree actions on a tab (create / merge / remove / resolve).
    let onTabAction: (Profile.ID, Int, TabAction) -> Void
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
    /// Scheduled automations — the third sidebar group, after the
    /// workspace rows.
    var automationStore: ScheduledAutomationStore
    let onNewAutomation: () -> Void
    /// Open the automation kanban board as the stage surface.
    let onShowAutomationBoard: () -> Void
    /// Coding-task board (host window only — nil hides the Tasks section).
    var taskStore: CodingTaskStore? = nil
    var onShowTaskBoard: () -> Void = {}

    var body: some View {
        if model.sidebarCollapsed {
            CompactRail(model: model,
                        onSelectGrid: onSelectGrid,
                        onSelectTab: onSelectTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            fullSidebar
        }
    }

    private var fullSidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    // Boards first — the surfaces that summarize everything —
                    // then the Workspaces group (label, Grid, rows).
                    AutomationsSection(
                        store: automationStore,
                        model: model,
                        onNew: onNewAutomation,
                        onShowBoard: onShowAutomationBoard)
                    if let taskStore {
                        CodingTasksSection(
                            store: taskStore,
                            model: model,
                            onShowBoard: onShowTaskBoard)
                    }
                    HStack {
                        Text("Workspaces")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.7)
                        Spacer()
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    GridSection(
                        store: gridStore,
                        model: model,
                        onSelect: onSelectGrid,
                        onRemoveCell: onRemoveGridCell,
                        onFocusCell: onFocusGridCell,
                        onDropPayload: onDropGridPayload)
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
                            onTabAction: onTabAction,
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
                            onDelete: onDelete,
                            onAddAllToGrid: onAddAllToGrid)
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

/// Collapsed sidebar: a flat icon rail — the Grid button, then one icon per
/// terminal (status dot riding it), workspaces separated by thin dividers.
/// No nesting, no names; tooltips carry the full context. Expand by dragging
/// the divider past the width threshold, or ⌃⌘S.
private struct CompactRail: View {
    @Bindable var model: SessionListModel
    let onSelectGrid: () -> Void
    let onSelectTab: (Profile.ID, Int) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 5) {
                Button(action: onSelectGrid) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.gridSelected ? Color.accentColor : .secondary)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(model.gridSelected ? Color.accentColor.opacity(0.16) : .clear))
                }
                .buttonStyle(.plain)
                .help("Grid")

                ForEach(model.entries) { entry in
                    let accentHex = model.profileRows.first { $0.id == entry.id }?
                        .accentHex ?? "#888888"
                    let workspaceName = model.profileRows.first { $0.id == entry.id }?
                        .name ?? ""
                    Divider().padding(.horizontal, 10)
                    ForEach(Array(entry.model.tabs.enumerated()), id: \.element.id) { idx, tab in
                        if tab.containerID == nil {
                            RailTabButton(
                                tab: tab,
                                accentHex: accentHex,
                                workspaceName: workspaceName,
                                isActive: tab.id == entry.model.activeTab?.id
                                    && model.selectedID == entry.id
                                    && !model.gridSelected,
                                onSelect: { onSelectTab(entry.id, idx) })
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One rail icon: the terminal's agent glyph (or a shell prompt) with its
/// status dot; active tab gets the workspace-accent backing.
private struct RailTabButton: View {
    let tab: TabsModel.Tab
    let accentHex: String
    let workspaceName: String
    let isActive: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private var agentKind: String? { BromureIcons.agentKind(forLabel: tab.shownLabel) }
    private var iconName: String {
        switch agentKind {
        case "claude", "codex", "grok": return agentKind ?? "robot"
        default: return "robot"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            Group {
                if agentKind != nil {
                    SVGIcon(name: iconName, fallbackSymbol: "sparkles", size: 13)
                        .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                AgentStatusDot(status: tab.agentStatus).offset(x: 2, y: 1)
            }
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(hex: accentHex).opacity(0.16)
                               : (hovering ? Color.primary.opacity(0.05) : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(workspaceName) — \(tab.shownLabel)")
    }
}

/// Pinned "Grid" node atop the source list: drop target for terminal drags,
/// expandable to show its members, click to make the grid the stage surface.
private struct GridSection: View {
    let store: GridLayoutStore
    @Bindable var model: SessionListModel
    let onSelect: () -> Void
    let onRemoveCell: (String) -> Void
    let onFocusCell: (String) -> Void
    let onDropPayload: (String) -> Bool

    @State private var expanded = true
    @State private var dropTargeted = false
    @State private var hovering = false

    private func agentStatus(for cell: GridCell) -> AgentStatus? {
        model.entries.first { $0.id == cell.profileID }?
            .model.tabs.first { $0.index == cell.windowIndex }?.agentStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.gridSelected ? Color.accentColor : .secondary)
                    .frame(width: 22)
                Text("Grid")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !store.cells.isEmpty {
                    Text("\(store.cells.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if !store.cells.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(model.gridSelected ? Color.accentColor.opacity(0.16)
                          : dropTargeted ? Color.accentColor.opacity(0.22)
                          : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { hovering = $0 }
            .dropDestination(for: String.self) { items, _ in
                var accepted = false
                for item in items where onDropPayload(item) { accepted = true }
                return accepted
            } isTargeted: { dropTargeted = $0 }
            .help(store.cells.isEmpty
                  ? "Drag terminals here to watch them side by side"
                  : "Show the terminal grid")

            if expanded, !store.cells.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(store.cells) { cell in
                        let workspace = model.profileRows.first { $0.id == cell.profileID }
                        HStack(spacing: 6) {
                            if let status = agentStatus(for: cell) {
                                AgentStatusDot(status: status)
                            } else {
                                Circle().fill(Color.secondary.opacity(0.35))
                                    .frame(width: 6, height: 6)
                            }
                            // Just the process name, tinted with the
                            // workspace's accent — the workspace is already
                            // conveyed by the dot color + grouping.
                            Text(cell.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(hex: workspace?.accentHex ?? "#888888"))
                                .lineLimit(1)
                                .help(workspace.map { "\($0.name) — \(cell.label)" } ?? cell.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture { onFocusCell(cell.id) }
                        .contextMenu {
                            Button("Remove from Grid") { onRemoveCell(cell.id) }
                        }
                    }
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
    let onTabAction: (Profile.ID, Int, TabAction) -> Void
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
    let onAddAllToGrid: (Profile.ID) -> Void

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
                            onReset: onReset, onDelete: onDelete,
                            onAddAllToGrid: onAddAllToGrid)
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
                // Tree order (each worktree under its parent), not roster
                // order; `item.idx` stays the model position the select/
                // close/action APIs expect, `pos` is the visible row number
                // driving the ⌘-digit chord (matched in performACShortcut).
                let orderedTabs = worktreeDisplayOrdered(entry.model.tabs)
                    .filter { $0.tab.containerID == nil }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(orderedTabs.enumerated()), id: \.element.id) { pos, item in
                        let idx = item.idx
                        let tab = item.tab
                        TabRow(
                            label: tab.shownLabel,
                            // Derive the icon from the shown label: a worktree
                            // tab's display ("Refactor website (claude)")
                            // names its tool, so agentKind's contains-match
                            // picks the agent even when the live foreground
                            // program is momentarily bash/node. For ordinary
                            // tabs shownLabel == label, so this is a no-op.
                            agentKind: BromureIcons.agentKind(forLabel: tab.shownLabel),
                            agentStatus: tab.agentStatus,
                            isActive: tab.id == entry.model.activeTab?.id && isSelected,
                            accentHex: row.accentHex,
                            chord: (isSelected && pos < 9) ? pos + 1 : nil,
                            isWorktree: tab.isWorktree,
                            worktreeDepth: worktreeDepth(of: tab, in: entry.model.tabs),
                            canCreateWorktree: tab.isGitRepo,
                            isMergeTab: (tab.display?.hasPrefix("Merge → ") ?? false),
                            onSelect: { onSelectTab(row.id, idx) },
                            onClose: { onCloseTab(row.id, idx) },
                            onAction: { action in onTabAction(row.id, idx, action) })
                        // Draggable onto the sidebar's Grid node.
                        .draggable(GridDragPayload.encode(
                            profileID: row.id, windowIndex: tab.index,
                            label: tab.shownLabel))
                    }
                    DockerSection(
                        profileID: row.id,
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
    let onAddAllToGrid: (Profile.ID) -> Void

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
            if row.state == .running {
                Divider()
                Button("Add Worktrees to Grid") { onAddAllToGrid(row.id) }
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
                Image(systemName: "server.rack")
                    .font(.system(size: 13))
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
    let agentStatus: AgentStatus
    let isActive: Bool
    let accentHex: String
    /// ⌘-number for this tab (1–9), or nil for tabs past 9 / unfocused VMs.
    let chord: Int?
    var isWorktree: Bool = false
    /// Worktree nesting depth (drives extra indentation). 0 for ordinary tabs.
    var worktreeDepth: Int = 0
    /// The tab's cwd is a git repo → offer "New worktree…".
    var canCreateWorktree: Bool = false
    /// A "Merge → …" tab → offer "Have the agent resolve conflicts".
    var isMergeTab: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onAction: (TabAction) -> Void = { _ in }
    @State private var hovering = false

    private var isAgent: Bool { agentKind != nil }
    /// Dedicated tab glyph for the agents that ship one; other agents
    /// (aider/goose/…) keep the generic robot.
    private var agentIconName: String {
        switch agentKind {
        case "claude", "codex", "grok": return agentKind ?? "robot"
        default: return "robot"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Invisible gutter the width of the Docker node's chevron, so a tab's
            // icon lines up with the Docker icon (and any other chevroned node)
            // rather than sitting a chevron's-width to its left.
            Color.clear.frame(width: 10, height: 14)
            // A worktree tab shows a small branch glyph before its program icon
            // so nested sub-agents read as branches, not plain tabs.
            if isWorktree {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
            }
            Group {
                if isAgent {
                    // The agent's icon stays put; a small status dot rides its
                    // lower-trailing corner (orange pulsing = working, green =
                    // done, red = needs you).
                    SVGIcon(name: agentIconName, fallbackSymbol: "sparkles", size: 13)
                        .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                        .overlay(alignment: .bottomTrailing) {
                            AgentStatusDot(status: agentStatus).offset(x: 2, y: 1)
                        }
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
        // above, the tab icon and the Docker icon align at the same x. Worktree
        // depth adds indentation so nested worktrees step inward.
        .padding(.leading, 20 + CGFloat(worktreeDepth) * 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            // "New worktree…" is ALWAYS present so right-click always opens a
            // menu. A worktree tab is itself a repo (recursion → nested
            // worktrees), so it counts as in-a-repo too. When the cwd isn't a
            // git repo the item is shown but disabled, with the reason inline —
            // never a silently-empty (invisible) menu.
            let inRepo = canCreateWorktree || isWorktree
            Button(inRepo
                   ? NSLocalizedString("New worktree…", comment: "Tab context menu: create a git worktree")
                   : NSLocalizedString("New worktree…  (Not in a git repo)",
                                       comment: "Tab context menu: disabled because the tab's cwd isn't a git repo")) {
                onAction(.newWorktree)
            }
            .disabled(!inRepo)

            // Always available: automations run in a plain tab when the cwd
            // isn't a git repo, so there's no gating to explain.
            Button(NSLocalizedString("New automation…",
                                     comment: "Tab context menu: create an automation seeded with this tab's directory")) {
                onAction(.createAutomation)
            }

            if isWorktree {
                Button(NSLocalizedString("Merge…", comment: "Tab context menu: merge a worktree into an ancestor")) {
                    onAction(.merge)
                }
                Button(NSLocalizedString("Attach terminal", comment: "Tab context menu: open a plain terminal tab in this worktree's checkout")) {
                    onAction(.attachTerminal)
                }
                Divider()
                Button(NSLocalizedString("Discard worktree", comment: "Tab context menu: remove worktree + delete branch"),
                       role: .destructive) {
                    onAction(.removeWorktree)
                }
            }
            if isMergeTab {
                Button(NSLocalizedString("Have the agent resolve conflicts",
                                         comment: "Tab context menu: spawn the agent to resolve a merge conflict")) {
                    onAction(.resolveConflicts)
                }
            }
        }
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
    let profileID: Profile.ID
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
                        profileID: profileID,
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
    let profileID: Profile.ID
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
            // Indented past the Docker node's icon (x≈38) so containers read as
            // nested under it rather than as siblings of the Docker row.
            .padding(.leading, 44)
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
                .draggable(GridDragPayload.encode(
                    profileID: profileID, windowIndex: entry.tab.index,
                    label: entry.tab.shownLabel))
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
        // One step deeper than the container row (44) it nests under.
        .padding(.leading, 58)
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
/// Small status dot overlaid on an agent's icon. Orange gently pulses while the
/// agent is working; green means it finished its turn; red means it's waiting
/// on the user. A thin ring keeps it legible over any icon/background.
struct AgentStatusDot: View {
    let status: AgentStatus
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .working:   return .orange
        case .done:      return .green
        case .needsInput: return .red
        }
    }
    private var help: String {
        switch status {
        case .working:   return NSLocalizedString("Working…", comment: "agent status dot")
        case .done:      return NSLocalizedString("Done", comment: "agent status dot")
        case .needsInput: return NSLocalizedString("Needs your input", comment: "agent status dot")
        }
    }
    /// The bare dot — a filled circle with a thin background-colored ring so it
    /// stays legible over any icon.
    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
    }

    var body: some View {
        // Only the working dot animates. Done/needs-input render as a plain,
        // STEADY dot in a separate branch, so switching out of .working
        // destroys the animated view entirely — no lingering repeatForever
        // pulse on the green/red dot.
        Group {
            if status == .working {
                dot
                    .scaleEffect(pulse ? 1.12 : 0.82)
                    .opacity(pulse ? 1.0 : 0.5)
                    .onAppear {
                        pulse = false
                        // ~30% slower than the original 0.75s for a gentler pulse.
                        withAnimation(.easeInOut(duration: 0.98).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else {
                dot
            }
        }
        .help(help)
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
    let onToggleFilePane: () -> Void
    let onToggleBrowser: () -> Void

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
                HeaderIcon(system: "globe", help: "Show or hide the agentic browser (⌃⌘B)",
                           active: model.browserPaneOpen) { onToggleBrowser() }
                HeaderIcon(system: "sidebar.right", help: "Show or hide repo files (⌃⌘E)",
                           active: model.filePaneOpen) { onToggleFilePane() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Monospace IP pill in the toolbar; click to copy. (internal — the fat-client
/// remote window's toolbar reuses it.)
struct ToolbarIP: View {
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

/// (internal — the fat-client remote window's toolbar reuses it.)
struct HeaderIcon: View {
    let system: String
    let help: String
    /// Tinted accent while the surface the button controls is showing.
    var active = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// (internal — the fat-client remote window's toolbar reuses it.)
struct FusionToggle: View {
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
