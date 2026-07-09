import AppKit
import SwiftUI

/// The stage's grid mode: N live terminal cells (up to 5×5), each a
/// libghostty surface attached to one tmux window of one workspace, laid out
/// by `GridLayoutStore.dimensions(for:)`.
///
/// The grid owns its *own* `TerminalSessionController` per workspace —
/// separate grouped tmux view-sessions from the workspace stage's, because a
/// view can only live in one superview and tmux is built for N independent
/// viewers. Works regardless of the workspace's nativeTerminal toggle.
@MainActor
final class GridStageView: NSView {
    let store: GridLayoutStore

    /// Live data + actions, injected by the unified window.
    struct DataSource {
        /// Profile for a workspace id (nil when deleted).
        var profile: (UUID) -> Profile?
        /// Live tab model when the workspace is running + attached.
        var tabsModel: (UUID) -> TabsModel?
        /// Run state for placeholder rendering.
        var runState: (UUID) -> SessionListModel.RunState
        var onStart: (UUID) -> Void
        /// Jump to the workspace's own stage (select workspace + tab).
        var onJump: (UUID, Int) -> Void
    }
    private let dataSource: DataSource

    /// Grid-scoped surface controllers, one per workspace.
    private var controllers: [UUID: TerminalSessionController] = [:]
    private var cellViews: [String: GridCellView] = [:]
    private var reconcileTimer: Timer?

    init(store: GridLayoutStore, dataSource: DataSource) {
        self.store = store
        self.dataSource = dataSource
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reconcile()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reconcileTimer = timer
        } else {
            reconcileTimer?.invalidate()
            reconcileTimer = nil
        }
    }

    /// Tear down every grid surface (grid hidden or window closing). The
    /// store (membership) is untouched — surfaces reattach on next show.
    func retireAll() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        for (_, cell) in cellViews { cell.removeFromSuperview() }
        cellViews.removeAll()
        for (_, controller) in controllers { controller.retireAll() }
        controllers.removeAll()
    }

    // MARK: Reconciliation

    /// Periodic + on-demand sync: prune cells whose window died (running
    /// workspaces only), swap placeholder ↔ live surface as run state
    /// changes, refresh header status dots, and relayout.
    func reconcile() {
        // 1. Roster pruning for running workspaces.
        let profileIDs = Set(store.cells.map(\.profileID))
        for pid in profileIDs {
            if let tabs = dataSource.tabsModel(pid)?.tabs, !tabs.isEmpty {
                store.reconcile(profileID: pid,
                                tabs: tabs.map { ($0.index, $0.shownLabel) })
            }
            if dataSource.profile(pid) == nil {
                store.removeAll(profileID: pid)   // deleted workspace
            }
        }

        // 2. Sync cell views to membership.
        let liveIDs = Set(store.cells.map(\.id))
        for (id, view) in cellViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            cellViews.removeValue(forKey: id)
        }
        for cell in store.cells where cellViews[cell.id] == nil {
            let view = GridCellView(
                cell: cell,
                onRemove: { [weak self] in
                    // Remove + reconcile now, so the cell disappears on click
                    // instead of on the next ~1s timer tick (which felt like
                    // "✕ does nothing", especially on placeholder/off cells).
                    self?.store.remove(id: cell.id)
                    self?.reconcile()
                },
                onJump: { [weak self] in
                    self?.dataSource.onJump(cell.profileID, cell.windowIndex)
                },
                onStart: { [weak self] in self?.dataSource.onStart(cell.profileID) },
                onToggleZoom: { [weak self] in self?.toggleZoom(cell.id) },
                onFocus: { [weak self] in self?.focus(cell.id) },
                onSwap: { [weak self] draggedID in self?.swapCells(draggedID, cell.id) })
            cellViews[cell.id] = view
            addSubview(view)
        }

        // 3. Content + chrome per cell.
        for cell in store.cells {
            guard let view = cellViews[cell.id] else { continue }
            let state = dataSource.runState(cell.profileID)
            let profile = dataSource.profile(cell.profileID)
            let tabs = dataSource.tabsModel(cell.profileID)?.tabs
            let tab = tabs?.first { $0.index == cell.windowIndex }

            view.update(
                label: tab?.shownLabel ?? cell.label,
                workspaceName: profile?.name ?? "?",
                accentHex: profile?.color.hexInUI ?? "#888888",
                agentStatus: tab?.agentStatus,
                runState: state)

            if state == .running, let profile {
                let controller = controllers[cell.profileID]
                    ?? {
                        let c = TerminalSessionController(profile: profile)
                        controllers[cell.profileID] = c
                        return c
                    }()
                if let surface = controller.view(forWindow: cell.windowIndex) {
                    view.showTerminal(surface)
                }
            } else {
                view.showPlaceholder()
                // The workspace is down: its grid surfaces are dead weight.
                if let controller = controllers.removeValue(forKey: cell.profileID) {
                    controller.retireAll()
                }
            }
        }

        needsLayout = true
    }

    // MARK: Rearrange

    /// Swap two cells' positions (drag one cell's header onto another) and
    /// animate the layout so the terminals glide to their new slots.
    private func swapCells(_ draggedID: String, _ targetID: String) {
        guard draggedID != targetID else { return }
        store.swap(draggedID, targetID)
        // A zoomed cell would hide everything mid-animation; clear it.
        store.zoomedCellID = nil
        needsLayout = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: Focus & zoom

    private func focus(_ id: String) {
        store.focusedCellID = id
        if let surface = cellViews[id]?.terminalView {
            window?.makeFirstResponder(surface)
        }
    }

    private func toggleZoom(_ id: String) {
        store.zoomedCellID = (store.zoomedCellID == id) ? nil : id
        focus(id)
        needsLayout = true
    }

    /// ⌘↩ toggles zoom on the focused cell. (Esc belongs to the terminal —
    /// agents use it — so it deliberately does not unzoom.)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 /* return */,
           let focused = store.focusedCellID {
            toggleZoom(focused)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let cells = store.cells
        guard !cells.isEmpty else { return }

        if let zoomed = store.zoomedCellID, let view = cellViews[zoomed] {
            for (id, v) in cellViews { v.isHidden = (id != zoomed) }
            view.frame = bounds.insetBy(dx: 4, dy: 4)
            return
        }

        let (rows, cols) = GridLayoutStore.dimensions(for: cells.count)
        let gap: CGFloat = 6
        let cellW = (bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (i, cell) in cells.enumerated() {
            guard let view = cellViews[cell.id] else { continue }
            view.isHidden = false
            let row = i / cols, col = i % cols
            // Row 0 at the top (AppKit's y grows upward).
            view.frame = NSRect(
                x: gap + CGFloat(col) * (cellW + gap),
                y: bounds.height - CGFloat(row + 1) * (cellH + gap),
                width: cellW, height: cellH)
        }
    }
}

// MARK: - One grid cell

/// Header (status dot · workspace · label, hover ✕/jump) over either a live
/// terminal surface or an off-workspace placeholder card.
@MainActor
final class GridCellView: NSView {
    private let headerHeight: CGFloat = 24

    private(set) var terminalView: TerminalSurfaceView?
    private var headerHost: NSHostingView<GridCellHeader>?
    private var placeholderHost: NSHostingView<GridCellPlaceholder>?

    private let onRemove: () -> Void
    private let onJump: () -> Void
    private let onStart: () -> Void
    private let onToggleZoom: () -> Void
    private let onFocus: () -> Void
    /// Given the DRAGGED cell's id, swap it with this cell.
    private let onSwap: (String) -> Void

    private var header = GridCellHeader.Model()

    init(cell: GridCell,
         onRemove: @escaping () -> Void,
         onJump: @escaping () -> Void,
         onStart: @escaping () -> Void,
         onToggleZoom: @escaping () -> Void,
         onFocus: @escaping () -> Void,
         onSwap: @escaping (String) -> Void) {
        self.onRemove = onRemove
        self.onJump = onJump
        self.onStart = onStart
        self.onToggleZoom = onToggleZoom
        self.onFocus = onFocus
        self.onSwap = onSwap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        header.cellID = cell.id

        let headerView = GridCellHeader(
            model: header,
            onRemove: onRemove, onJump: onJump,
            onDoubleClick: onToggleZoom,
            onSwap: onSwap)
        let host = NSHostingView(rootView: headerView)
        headerHost = host
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(label: String, workspaceName: String, accentHex: String,
                agentStatus: AgentStatus?, runState: SessionListModel.RunState) {
        header.label = label
        header.workspaceName = workspaceName
        header.accentHex = accentHex
        header.agentStatus = agentStatus
        header.runState = runState
    }

    func showTerminal(_ view: TerminalSurfaceView) {
        guard terminalView !== view else { return }
        placeholderHost?.removeFromSuperview()
        placeholderHost = nil
        terminalView?.removeFromSuperview()
        terminalView = view
        addSubview(view, positioned: .below, relativeTo: headerHost)
        needsLayout = true
    }

    func showPlaceholder() {
        if let t = terminalView {
            t.removeFromSuperview()
            terminalView = nil
        }
        guard placeholderHost == nil else { return }
        let host = NSHostingView(rootView: GridCellPlaceholder(
            model: header, onStart: onStart))
        placeholderHost = host
        addSubview(host, positioned: .below, relativeTo: headerHost)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        headerHost?.frame = NSRect(x: 0, y: bounds.height - headerHeight,
                                   width: bounds.width, height: headerHeight)
        let content = NSRect(x: 0, y: 0,
                             width: bounds.width,
                             height: bounds.height - headerHeight)
        terminalView?.frame = content
        placeholderHost?.frame = content
    }

    override func mouseDown(with event: NSEvent) {
        onFocus()
        super.mouseDown(with: event)
    }
}

// MARK: - SwiftUI chrome

struct GridCellHeader: View {
    @MainActor
    @Observable
    final class Model {
        var label = ""
        var workspaceName = ""
        var accentHex = "#888888"
        var agentStatus: AgentStatus?
        var runState: SessionListModel.RunState = .off
        /// This cell's grid id — the drag payload for rearranging.
        var cellID = ""
    }

    @Bindable var model: Model
    let onRemove: () -> Void
    let onJump: () -> Void
    let onDoubleClick: () -> Void
    /// Given the dragged cell's id, swap it into this cell's slot.
    let onSwap: (String) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            // Drag handle: grab here to swap this cell with another. Shown on
            // hover so it doesn't clutter the header at rest.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .frame(width: hovering ? 10 : 0)
                .draggable(model.cellID)
                .help("Drag to rearrange")
            if let status = model.agentStatus {
                AgentStatusDot(status: status)
            } else {
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            }
            Text(model.workspaceName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: model.accentHex))
                .lineLimit(1)
            Text(model.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button(action: onJump) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Open in workspace")
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Remove from grid — the terminal keeps running")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.25)
                                 : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { onDoubleClick() })
        // Drop another cell's header here to swap the two. Ignore a drop of
        // this same cell onto itself.
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != model.cellID else { return false }
            onSwap(dragged)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Open in Workspace", action: onJump)
            Divider()
            Button("Remove from Grid", action: onRemove)
        }
    }
}

/// Card shown when the cell's workspace is off/suspended: the arrangement
/// survives VM downtime; Start brings it back.
struct GridCellPlaceholder: View {
    @Bindable var model: GridCellHeader.Model
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(model.runState == .suspended ? "Suspended" : "Off")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Start", action: onStart)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
