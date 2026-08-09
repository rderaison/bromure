#if os(visionOS)
import SwiftUI

// MARK: - visionOS grid stage
//
// `GridScreen`'s spatial sibling. Same mirrored `GridLayoutStore` cells, same
// AttachSession-per-cell reconcile — but tuned for the canvas visionOS gives
// us: the cells always tile to FILL the window (which the user can stretch to
// wall size), every tile is gaze-highlightable, and any tile pops out into its
// own `PinnedTerminalWindow` to be pinned anywhere in the room. "Pin All"
// turns the whole grid into free-floating windows in one tap.
//
// Two flavours:
//  - embedded (`standalone == false`) — the main shell's detail column, where
//    tapping a tile navigates to the workspace, like the iPad.
//  - standalone (`standalone == true`) — a dedicated grid stage window, where
//    the grid itself is the surface being pinned; tapping a tile opens that
//    terminal as its own window instead of navigating away from the stage.
struct VisionGridScreen: View {
    let controller: RemoteHostController
    var standalone = false

    @Environment(\.openWindow) private var openWindow
    /// One live attach per cell, keyed by cell id; reconciled against the
    /// mirrored grid + run states so removed/stopped cells tear down.
    @State private var sessions: [String: AttachSession] = [:]

    private var cells: [GridCell] { controller.gridStore.cells }

    private var waitingCount: Int {
        cells.filter { status(of: $0) == .needsInput }.count
    }

    var body: some View {
        Group {
            if cells.isEmpty {
                ContentUnavailableView("No grid",
                    systemImage: "square.grid.2x2",
                    description: Text("Long-press a terminal tab and “Send to Grid,” or arrange one in the desktop app. Tiles here can be popped out and pinned anywhere in the room."))
            } else {
                stage
            }
        }
        .navigationTitle(standalone ? "\(hostName) — Grid" : "Grid")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !standalone {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: "grid",
                                   value: GridWindowValue(hostID: controller.host.id,
                                                          hostName: hostName))
                    } label: {
                        Label("Open as Window", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Open the grid as its own window")
                }
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            if standalone && !cells.isEmpty { stageOrnament }
        }
        .onAppear { reconcile() }
        .onChange(of: cells.map(\.id)) { reconcile() }
        .onChange(of: controller.revision) { reconcile() }
        .onDisappear {
            sessions.values.forEach { $0.stop() }
            sessions = [:]
        }
    }

    private var hostName: String {
        let h = controller.host
        return h.name.isEmpty ? h.address : h.name
    }

    // MARK: Stage layout

    /// Pack rows × columns so the tiles split the whole viewport — the grid is
    /// the window, and growing the window grows every terminal. Falls back to
    /// a scrolling layout only when so many cells would make tiles unreadable.
    private var stage: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 16
            let inset: CGFloat = 16
            let (cols, rows) = GridScreen.bestPacking(count: cells.count, in: geo.size)
            let w = (geo.size.width - inset * 2 - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (geo.size.height - inset * 2 - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            if h < 150 || w < 220 {
                scrollGrid
            } else {
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: spacing) {
                            ForEach(rowCells(r, cols: cols)) { cell in
                                tile(cell, height: h)
                                    .frame(width: w)
                            }
                            if rowCells(r, cols: cols).count < cols { Spacer(minLength: 0) }
                        }
                    }
                }
                .padding(inset)
            }
        }
    }

    /// Overflow layout for very large grids in a small window.
    private var scrollGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 700),
                                         spacing: 16)],
                      spacing: 16) {
                ForEach(cells) { cell in tile(cell, height: 220) }
            }
            .padding(16)
        }
    }

    private func rowCells(_ row: Int, cols: Int) -> [GridCell] {
        let start = row * cols
        guard start < cells.count else { return [] }
        return Array(cells[start..<min(start + cols, cells.count)])
    }

    // MARK: Tiles

    private func status(of cell: GridCell) -> AgentStatus? {
        controller.tabsModel(for: cell.profileID)?.tabs
            .first { $0.index == cell.windowIndex }?.agentStatus
    }

    @ViewBuilder private func tile(_ cell: GridCell, height: CGFloat) -> some View {
        let status = status(of: cell)
        let needsInput = status == .needsInput
        Group {
            if standalone {
                // The stage is the thing being looked at — a tap spawns the
                // interactive terminal as its own window and the stage stays.
                Button { openWindow(id: "terminal", value: windowValue(cell)) } label: {
                    tileBody(cell, height: height, status: status)
                }
            } else {
                NavigationLink {
                    WorkspaceScreen(controller: controller, profileID: cell.profileID,
                                    initialWindow: cell.windowIndex)
                } label: {
                    tileBody(cell, height: height, status: status)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .hoverEffect(.highlight)
        .contextMenu {
            Button {
                openWindow(id: "terminal", value: windowValue(cell))
            } label: { Label("Open as Window", systemImage: "rectangle.badge.plus") }
            Button(role: .destructive) {
                controller.gridStore.remove(id: cell.id)
                controller.pushGridLayout()
            } label: { Label("Remove from Grid", systemImage: "xmark") }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(needsInput ? Color.red : Color.primary.opacity(0.12),
                          lineWidth: needsInput ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // An agent waiting on input glows so it reads across the room.
        .shadow(color: needsInput ? .red.opacity(0.45) : .clear, radius: 14)
    }

    @ViewBuilder private func tileBody(_ cell: GridCell, height: CGFloat,
                                       status: AgentStatus?) -> some View {
        let name = controller.profile(for: cell.profileID)?.name ?? "?"
        let accent = controller.profile(for: cell.profileID)?.color.hexInUI ?? "#888888"
        let state = controller.runState(for: cell.profileID)
        let running = state == .running || state == .booting
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: accent)).frame(width: 9, height: 9)
                Text(cell.label.isEmpty ? name : cell.label)
                    .font(.callout.weight(.medium)).lineLimit(1)
                if let status { AgentStatusDot(status: status) }
                Spacer()
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    openWindow(id: "terminal", value: windowValue(cell))
                } label: {
                    Image(systemName: "rectangle.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Open as its own window")
                .accessibilityLabel("Open as its own window")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            Divider()
            Group {
                if running, let session = sessions[cell.id] {
                    // Preview font grows with the tile — a wall-sized stage
                    // window gets terminals you can actually read.
                    RemoteTerminalView(session: session, interactive: false,
                                       fixedFontSize: max(10, min(18, height / 30)))
                        .background(Color.black)
                } else {
                    ZStack {
                        Color.black.opacity(0.35)
                        VStack(spacing: 4) {
                            Image(systemName: running ? "hourglass" : "moon.zzz")
                                .foregroundStyle(.secondary)
                            Text(running ? "Attaching…" : "Workspace off")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .contentShape(Rectangle())
    }

    private func windowValue(_ cell: GridCell) -> TerminalWindowValue {
        TerminalWindowValue(
            hostID: controller.host.id,
            profileID: cell.profileID,
            windowIndex: cell.windowIndex,
            workspaceName: controller.profile(for: cell.profileID)?.name ?? "?",
            windowLabel: cell.label,
            accentHex: controller.profile(for: cell.profileID)?.color.hexInUI ?? "#888888")
    }

    // MARK: Ornament

    /// The stage's floating control bar: a summary plus "Pin All", which turns
    /// every tile into its own window to arrange around the room.
    private var stageOrnament: some View {
        HStack(spacing: 14) {
            Label("\(cells.count)", systemImage: "square.grid.2x2")
                .font(.callout.weight(.medium))
                .accessibilityLabel("\(cells.count) terminals in the grid")
            if waitingCount > 0 {
                Label("\(waitingCount) waiting", systemImage: "exclamationmark.bubble")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Divider().frame(height: 20)
            Button {
                for cell in cells {
                    openWindow(id: "terminal", value: windowValue(cell))
                }
            } label: {
                Label("Pin All as Windows", systemImage: "rectangle.3.offgrid")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: Capsule())
    }

    // MARK: Reconcile

    /// Attach running cells, stop + drop cells that are gone or stopped.
    private func reconcile() {
        var next: [String: AttachSession] = [:]
        for cell in cells {
            let state = controller.runState(for: cell.profileID)
            guard state == .running || state == .booting else { continue }
            next[cell.id] = sessions[cell.id]
                ?? AttachSession(host: controller.host,
                                 vmID: cell.profileID.uuidString,
                                 windowIndex: cell.windowIndex)
        }
        for (id, s) in sessions where next[id] == nil { s.stop() }
        if Set(next.keys) != Set(sessions.keys) { sessions = next }
    }
}
#endif
