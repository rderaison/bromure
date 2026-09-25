#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Room stage
//
// Clicking a room shows its sessions as a grid of live chats, with the
// room's Switchboard docked underneath. One cell has the focus (the Files
// pane follows it); clicking a cell's title zooms it to the whole stage —
// a spring morph with a Metal shockwave (shaders/RoomEffects.metal) — and
// "← Room" goes back. Each cell is a full beautified chat pinned to its
// session's tmux window, independent of what the workspace pane shows.

/// A beautified chat's data source pinned to one tmux window of a workspace
/// — the pane's own provider follows whatever tab is active; a room cell
/// must keep showing its session.
@MainActor
final class PinnedTranscriptProvider: BeautifiedTranscriptProvider {
    let accent: Color
    private weak var pane: SessionPane?
    private let window: Int

    init(pane: SessionPane, window: Int) {
        self.pane = pane
        self.window = window
        self.accent = Color(hex: pane.profile.color.hexInUI)
    }

    func activeTabIndex() -> Int? { window }

    func execGuest(_ command: String, timeout: Int) async -> String? {
        guard let pane, let delegate = pane.acDelegate else { return nil }
        return try? await delegate.guestExec(profileID: pane.profile.id, command: command, timeout: timeout)
    }

    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? {
        guard let pane, let delegate = pane.acDelegate else { return nil }
        return try? await delegate.guestFileOp(profileID: pane.profile.id, op: op, timeout: 30)
    }

    func isWorking() -> Bool {
        pane?.model.tabs.first { $0.index == window }?.agentStatus == .working
    }
}

/// Where a room stage's data lives: this Mac (the app delegate) or a
/// remote server's mirror (a fat-client window).
@MainActor
protocol RoomStageBackend: AnyObject {
    var roomStore: AgentRoomStore { get }
    var roomSessions: [AgentSession] { get }
    /// What identifies the session's live chat right now (its machine +
    /// tmux window); nil while it isn't live. A change rebuilds the cell.
    func chatKey(for s: AgentSession) -> String?
    /// A chat model for the session's live window (not started).
    func makeChat(for s: AgentSession) -> BeautifiedSessionModel?
    func startSwitchboard(_ room: AgentRoom)
    func setLayout(_ room: UUID, _ layout: String)
}

/// This Mac's rooms: the delegate's stores, chats pinned to the local panes.
@MainActor
final class LocalRoomBackend: RoomStageBackend {
    private weak var delegate: ACAppDelegate?
    init(_ delegate: ACAppDelegate) { self.delegate = delegate }

    var roomStore: AgentRoomStore { delegate?.agentRoomStore ?? AgentRoomStore(mirror: true) }
    var roomSessions: [AgentSession] { delegate?.agentSessionStore.sessions ?? [] }

    func chatKey(for s: AgentSession) -> String? {
        guard let w = s.windowIndex, !s.hasEnded, s.agentAlive != false,
              delegate?.pane(for: s.profileID) != nil else { return nil }
        return "\(s.profileID.uuidString)#\(w)"
    }

    func makeChat(for s: AgentSession) -> BeautifiedSessionModel? {
        guard let w = s.windowIndex, let pane = delegate?.pane(for: s.profileID) else { return nil }
        return pane.makeBeautifiedModel(windowIndex: w, provider: PinnedTranscriptProvider(pane: pane, window: w))
    }

    func startSwitchboard(_ room: AgentRoom) {
        _ = delegate?.switchboardEngine.ensureSwitchboard(room: room)
    }

    func setLayout(_ room: UUID, _ layout: String) {
        delegate?.agentRoomStore.setLayout(room, layout)
    }
}

/// What the room stage shows and does: one chat model per live member
/// (rebuilt when its tab changes), the Switchboard's, focus and zoom.
@MainActor
@Observable
final class RoomStageController {
    let roomID: UUID
    @ObservationIgnored let backend: RoomStageBackend
    @ObservationIgnored let listModel: SessionListModel

    var focusedID: UUID?
    var zoomedID: UUID?
    /// The tab on show (a page of `layout.size` sessions).
    var page = 0
    /// +1 / −1: which way the last page change went (the slide's direction).
    var pageDirection = 1
    /// Who the one composer under the grid talks to: the room's
    /// Switchboard, or the focused session. Clicking a cell aims it there.
    enum Target { case switchboard, focused }
    var target: Target = .switchboard
    /// Where the last zoom started (stage coordinates), for the shockwave.
    var zoomOrigin: CGPoint = .zero
    private(set) var models: [UUID: BeautifiedSessionModel] = [:]
    @ObservationIgnored private var modelKeys: [UUID: String] = [:]
    @ObservationIgnored private var timer: Timer?

    /// Stage actions the window supplies.
    @ObservationIgnored var onNewSession: () -> Void = {}
    @ObservationIgnored var onOpenSession: (UUID) -> Void = { _ in }
    @ObservationIgnored var onRemoveFromRoom: (UUID) -> Void = { _ in }
    @ObservationIgnored var onResume: (UUID) -> Void = { _ in }
    @ObservationIgnored var onRename: (String) -> Void = { _ in }
    @ObservationIgnored var onUnarchive: () -> Void = {}

    init(roomID: UUID, backend: RoomStageBackend, listModel: SessionListModel) {
        self.roomID = roomID
        self.backend = backend
        self.listModel = listModel
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var room: AgentRoom? { backend.roomStore.room(roomID) }

    var members: [AgentSession] {
        guard let room else { return [] }
        return RoomTally.members(room, in: backend.roomSessions)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var layout: RoomLayout {
        room?.layout.flatMap(RoomLayout.init) ?? .fitting(members.count)
    }

    var pages: [[AgentSession]] { layout.pages(members) }

    func setLayout(_ l: RoomLayout) {
        backend.setLayout(roomID, l.string)
        // Keep the focused session on screen.
        if let f = focusedID, let i = members.firstIndex(where: { $0.id == f }) {
            page = i / l.size
        } else {
            page = 0
        }
    }

    func show(page p: Int) {
        let n = pages.count
        guard n > 0 else { return }
        let target = (p % n + n) % n
        guard target != page else { return }
        pageDirection = target > page ? 1 : -1
        page = target
        // Focus follows onto the page when it was elsewhere.
        if let f = focusedID, pages[target].contains(where: { $0.id == f }) { return }
        focus(pages[target].first?.id)
    }

    /// The page holding a session (it becomes the tab on show).
    func reveal(_ id: UUID) {
        if let i = members.firstIndex(where: { $0.id == id }) { show(page: i / layout.size) }
    }

    var switchboard: AgentSession? {
        guard let room else { return nil }
        return RoomTally.switchboard(of: room, in: backend.roomSessions)
    }

    /// Keep one running chat model per live member (and the Switchboard);
    /// drop the ones whose session left or whose tab changed.
    func refresh() {
        var wanted: [UUID: (AgentSession, String)] = [:]
        for s in members + [switchboard].compactMap({ $0 }) {
            if let key = backend.chatKey(for: s) { wanted[s.id] = (s, key) }
        }
        for (id, m) in models where wanted[id]?.1 != modelKeys[id] {
            m.stop()
            models[id] = nil
            modelKeys[id] = nil
        }
        for (id, (s, key)) in wanted where models[id] == nil {
            guard let m = backend.makeChat(for: s) else { continue }
            m.start()
            models[id] = m
            modelKeys[id] = key
        }
        if focusedID == nil || !members.contains(where: { $0.id == focusedID }) {
            focus(members.first?.id)
        }
        if let z = zoomedID, !members.contains(where: { $0.id == z }) { zoomedID = nil }
        page = min(page, max(0, pages.count - 1))
    }

    /// The chat the composer sends to right now (nil: nothing live there).
    var targetModel: BeautifiedSessionModel? {
        switch target {
        case .switchboard: return switchboard.flatMap { models[$0.id] }
        case .focused: return focusedID.flatMap { models[$0] }
        }
    }

    func focus(_ id: UUID?) {
        focusedID = id
        let s = id.flatMap { id in backend.roomSessions.first { $0.id == id } }
        listModel.roomFocusProfileID = s?.profileID
        listModel.roomFocusCwd = s?.cwd
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for m in models.values { m.stop() }
        models = [:]
        modelKeys = [:]
    }

    /// Start the room's Switchboard (it greets with the room's status).
    func startSwitchboard() {
        guard let room else { return }
        backend.startSwitchboard(room)
    }
}

// MARK: - The Metal shockwave

enum RoomEffects {
    /// RoomEffects.metallib next to the app's resources, when build.sh
    /// could compile it.
    static let library: ShaderLibrary? = {
        guard let url = Bundle.main.url(forResource: "RoomEffects", withExtension: "metallib") else { return nil }
        return ShaderLibrary(url: url)
    }()
}

/// A ring of light sweeping across a zooming cell. Animatable, so a
/// withAnimation on `progress` drives the shader frame by frame.
private struct Shockwave: ViewModifier, Animatable {
    var progress: Double
    let origin: CGPoint
    let tint: Color

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay {
            if let lib = RoomEffects.library, progress > 0, progress < 1 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white)
                        .colorEffect(lib.roomShockwave(
                            .float2(geo.size), .float2(origin),
                            .float(progress), .color(tint)))
                        .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Views

struct RoomStageView: View {
    let controller: RoomStageController
    @Namespace private var zoom
    @State private var wave: Double = 1
    @State private var dockHeight: CGFloat = 220
    @State private var dockOpen = true
    /// While one session is zoomed the Switchboard folds away; the chevron
    /// peeks at it without changing the grid's preference.
    @State private var dockPeek = false
    private var dockShown: Bool { controller.zoomedID == nil ? dockOpen : dockPeek }
    @State private var renaming = false
    @State private var draftName = ""
    @State private var pickingTarget = false
    /// The cell a zoom is moving (in or out), until the spring settles: it
    /// draws a placeholder meanwhile, and the Switchboard strip folding
    /// under it stays empty — laying a whole transcript out on every
    /// animation frame is what made zooming crawl (worst over a fat
    /// client's tunnel). The live chat mounts once, at the end.
    @State private var zoomMoving: UUID?

    private var accent: Color { Color(hex: controller.room?.colorHex ?? "#6366F1") }

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.zoomedID == nil, controller.pages.count > 1 || controller.layout.size == 1 {
                tabBar
            }
            ZStack {
                if let z = controller.zoomedID, let s = controller.members.first(where: { $0.id == z }) {
                    zoomed(s)
                        .transition(.opacity)
                } else {
                    grid
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "roomStage")
            // Over the whole stage, in the same space the click was measured in.
            .modifier(Shockwave(progress: wave, origin: controller.zoomOrigin, tint: accent))
            .background(Color(nsColor: .windowBackgroundColor))
            dock
        }
        .background(pageKeys)
        // Opaque: the fat client's stage underneath is black.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// ⌃Tab / ⌃⇧Tab walk the tabs.
    private var pageKeys: some View {
        ZStack {
            Button("") { withAnimation(.snappy) { controller.show(page: controller.page + 1) } }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("") { withAnimation(.snappy) { controller.show(page: controller.page - 1) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if controller.zoomedID != nil {
                Button {
                    setZoom(nil)
                } label: {
                    Label(NSLocalizedString("Room", comment: "room stage back"), systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                .help(NSLocalizedString("Back to the whole room (Esc)", comment: "room stage"))
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.gradient)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            if renaming {
                TextField("", text: $draftName, onCommit: {
                    controller.onRename(draftName)
                    renaming = false
                })
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            } else {
                Text(controller.room?.name ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .onTapGesture(count: 2) {
                        draftName = controller.room?.name ?? ""
                        renaming = true
                    }
                    .help(NSLocalizedString("Double-click to rename", comment: "room stage"))
            }
            Text(tally).font(.system(size: 12)).foregroundStyle(.secondary)
            if controller.room?.isArchived == true {
                // Put away: say so, and one click brings it all back.
                Label(NSLocalizedString("Archived", comment: "sidebar section"), systemImage: "archivebox")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .foregroundStyle(.secondary)
                Button(NSLocalizedString("Unarchive Room", comment: "room menu"), action: controller.onUnarchive)
                    .controlSize(.small)
            }
            Spacer()
            if controller.zoomedID == nil, !controller.members.isEmpty { layoutPicker }
            Button(action: controller.onNewSession) {
                Label(NSLocalizedString("New Session", comment: "room stage"), systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help(NSLocalizedString("Start a session in this room", comment: "room stage"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var tally: String {
        let n = controller.members.count
        return n == 1 ? NSLocalizedString("1 session", comment: "room row")
                      : String(format: NSLocalizedString("%d sessions", comment: "room row"), n)
    }

    /// Six little grids in a pill; the room's layout lit.
    private var layoutPicker: some View {
        let current = controller.layout
        return HStack(spacing: 2) {
            ForEach(RoomLayout.all, id: \.self) { l in
                let on = l == current
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { controller.setLayout(l) }
                } label: {
                    GridGlyph(cols: l.cols, rows: l.rows, on: on, accent: accent)
                        .frame(width: 26, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(on ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(format: NSLocalizedString("%d × %d grid", comment: "room layout"), l.cols, l.rows))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Tabs

    /// One tab per page: at 1×1 each session is a tab; bigger grids group
    /// them (4×4 with 20 sessions = two tabs).
    private var tabBar: some View {
        let pages = controller.pages
        let single = controller.layout.size == 1
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                        RoomTab(page: page, index: i, single: single, selected: i == controller.page,
                                model: controller.listModel, accent: accent) {
                            withAnimation(.snappy(duration: 0.3)) { controller.show(page: i) }
                        }
                        .id(i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: controller.page) { _, p in withAnimation { proxy.scrollTo(p) } }
        }
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Grid

    private var grid: some View {
        let pages = controller.pages
        let layout = controller.layout
        return GeometryReader { geo in
            if pages.isEmpty {
                emptyRoom.frame(width: geo.size.width, height: geo.size.height)
            } else {
                let page = pages[min(controller.page, pages.count - 1)]
                let spacing: CGFloat = 10
                let h = (geo.size.height - spacing * CGFloat(layout.rows + 1)) / CGFloat(layout.rows)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: layout.cols),
                          spacing: spacing) {
                    ForEach(page) { s in
                        cell(s, zoomed: false)
                            .frame(height: max(80, h))
                            .matchedGeometryEffect(id: s.id, in: zoom)
                    }
                }
                .padding(spacing)
                .id(controller.page)
                .transition(.asymmetric(
                    insertion: .move(edge: controller.pageDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: controller.pageDirection > 0 ? .leading : .trailing).combined(with: .opacity)))
            }
        }
        .clipped()
    }

    private var emptyRoom: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("This room is empty", comment: "room stage"))
                .font(.system(size: 15, weight: .semibold))
            Text(NSLocalizedString("Drag sessions onto the room in the sidebar, or start one here.", comment: "room stage"))
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("New Session", comment: "room stage"), action: controller.onNewSession)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Zoom

    private func zoomed(_ s: AgentSession) -> some View {
        cell(s, zoomed: true)
            .matchedGeometryEffect(id: s.id, in: zoom)
            .padding(10)
    }

    /// Zoom a cell in (or back out with nil), keeping its chat out of the
    /// animation (see `zoomMoving`).
    private func setZoom(_ id: UUID?) {
        guard id != controller.zoomedID else { return }
        let moving = id ?? controller.zoomedID
        zoomMoving = moving
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86), completionCriteria: .logicallyComplete) {
            controller.zoomedID = id
        } completion: {
            if zoomMoving == moving { zoomMoving = nil }
        }
    }

    private func toggleZoom(_ s: AgentSession, at point: CGPoint) {
        controller.focus(s.id)
        controller.target = .focused
        let zoomingIn = controller.zoomedID != s.id
        controller.zoomOrigin = point
        wave = 0
        setZoom(zoomingIn ? s.id : nil)
        if zoomingIn {
            withAnimation(.easeOut(duration: 0.9)) { wave = 1 }
        } else {
            wave = 1
        }
    }

    // MARK: Cell

    private func cell(_ s: AgentSession, zoomed: Bool) -> some View {
        let focused = controller.focusedID == s.id
        let addressed = focused && controller.target == .focused
        return VStack(spacing: 0) {
            cellTitle(s, zoomed: zoomed)
            Divider()
            Group {
                if zoomMoving == s.id {
                    movingPlaceholder(s)
                } else if let m = controller.models[s.id] {
                    BeautifiedSessionView(model: m, parts: .transcript)
                } else {
                    restingCell(s)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(focused ? accent.opacity(addressed ? 1 : 0.45) : Color.primary.opacity(0.08),
                          lineWidth: focused ? 2 : 1))
        .shadow(color: .black.opacity(addressed ? 0.16 : 0.05), radius: addressed ? 10 : 3, y: 2)
        .simultaneousGesture(TapGesture().onEnded {
            controller.focus(s.id)
            controller.target = .focused
        })
    }

    private func cellTitle(_ s: AgentSession, zoomed: Bool) -> some View {
        let model = controller.listModel
        return HStack(spacing: 8) {
            AgentAvatar(tool: s.tool, size: 18, status: SessionHome.dot(for: s, in: model))
            Text(s.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            if let nick = s.nickname {
                Text("@" + nick).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
            }
            Text(SessionHome.statusLine(for: s, in: model))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Button(NSLocalizedString("Open as Session", comment: "room cell")) { controller.onOpenSession(s.id) }
                Button(NSLocalizedString("Remove from Room", comment: "room cell")) { controller.onRemoveFromRoom(s.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // On the bar itself (a handler behind its contents never fires),
        // measured in the stage's space for the shockwave's origin.
        .onTapGesture(coordinateSpace: .named("roomStage")) { location in
            toggleZoom(s, at: location)
        }
        .help(zoomed ? NSLocalizedString("Back to the whole room", comment: "room cell")
                     : NSLocalizedString("Zoom in", comment: "room cell"))
    }

    /// What a cell shows while a zoom moves it: nothing to lay out.
    private func movingPlaceholder(_ s: AgentSession) -> some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            AgentAvatar(tool: s.tool, size: 30).opacity(0.25)
        }
    }

    private func restingCell(_ s: AgentSession) -> some View {
        let bucket = SessionHome.bucket(for: s, in: controller.listModel)
        return VStack(spacing: 10) {
            if s.isLaunching {
                ProgressView()
                Text(NSLocalizedString("Starting…", comment: "room cell")).foregroundStyle(.secondary)
            } else {
                Image(systemName: bucket == .ended ? "stop.circle" : "moon.zzz")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text(bucket.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Button(NSLocalizedString("Resume", comment: "room cell")) { controller.onResume(s.id) }
            }
        }
    }

    // MARK: Switchboard dock + the one composer

    private var dock: some View {
        let sb = controller.switchboard
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays").foregroundStyle(accent)
                Text(NSLocalizedString("Switchboard", comment: "room dock"))
                    .font(.system(size: 12, weight: .semibold))
                Text(NSLocalizedString("keeps track of this room's sessions", comment: "room dock"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if controller.zoomedID == nil { dockOpen.toggle() } else { dockPeek.toggle() }
                    }
                } label: {
                    Image(systemName: dockShown ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(dockShown ? NSLocalizedString("Fold the Switchboard", comment: "room dock")
                               : NSLocalizedString("Show the Switchboard", comment: "room dock"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .top) {
                // Drag the dock's edge to resize it.
                Rectangle().fill(Color.clear).frame(height: 6)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { v in
                        dockHeight = min(560, max(120, dockHeight - v.translation.height))
                    })
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
            }
            if dockShown {
                Group {
                    if zoomMoving != nil {
                        Color.clear   // folding / unfolding with a zoom: nothing to lay out
                    } else if let sb, let m = controller.models[sb.id] {
                        BeautifiedSessionView(model: m, parts: .transcript)
                            .simultaneousGesture(TapGesture().onEnded { controller.target = .switchboard })
                    } else if let sb, sb.isLaunching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(NSLocalizedString("The room's Switchboard is starting…", comment: "room dock"))
                                .foregroundStyle(.secondary)
                        }
                    } else if let sb {
                        // Asleep or ended (its machine went down): wake it.
                        VStack(spacing: 8) {
                            Image(systemName: "moon.zzz").font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Button(NSLocalizedString("Resume", comment: "room cell")) { controller.onResume(sb.id) }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Text(NSLocalizedString("Ask about everything in this room at once — what's stuck, what's done — or have it answer and start sessions for you.", comment: "room dock"))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520)
                            Button(NSLocalizedString("Start the Room's Switchboard", comment: "room dock"),
                                   action: controller.startSwitchboard)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: dockHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composerBar
        }
        .onChange(of: controller.zoomedID) { _, _ in dockPeek = false }
    }

    /// The room's one composer, full width, with a "To" token above it:
    /// the target's avatar + name; a click opens a searchable picker.
    private var composerBar: some View {
        let focused = controller.focusedID.flatMap { id in controller.members.first { $0.id == id } }
        let toSwitchboard = controller.target == .switchboard || focused == nil
        let name = toSwitchboard ? NSLocalizedString("Switchboard", comment: "room composer target")
                                 : (focused?.title ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(NSLocalizedString("To", comment: "room composer target"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Button { pickingTarget.toggle() } label: {
                    HStack(spacing: 6) {
                        if toSwitchboard {
                            SwitchboardGlyph(accent: accent, size: 16)
                        } else if let focused {
                            AgentAvatar(tool: focused.tool, size: 16,
                                        status: SessionHome.dot(for: focused, in: controller.listModel))
                        }
                        Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(pickingTarget ? 0.18 : 0.10)))
                    .overlay(Capsule().strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickingTarget, arrowEdge: .top) {
                    RoomTargetPicker(controller: controller, accent: accent) { pickingTarget = false }
                }
                .help(NSLocalizedString("Who this message goes to — the room's Switchboard, or the session you clicked", comment: "room composer target"))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Group {
                if let m = controller.targetModel {
                    BeautifiedSessionView(model: m, parts: .composer, placeholder: String(
                        format: NSLocalizedString("Message %@…  (or drop files)", comment: "beautified composer"),
                        toSwitchboard ? NSLocalizedString("the Switchboard", comment: "room composer target") : name))
                        .id(ObjectIdentifier(m))   // a fresh composer per target
                } else {
                    Text(toSwitchboard && controller.switchboard == nil
                         ? NSLocalizedString("Start the room's Switchboard to ask it about everything here.", comment: "room composer")
                         : NSLocalizedString("This session isn't running — resume it to talk to it.", comment: "room composer"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .onAppear { if controller.switchboard == nil { controller.target = .focused } }
    }
}

// MARK: - Pieces

/// A tab: at 1×1 the session itself (avatar, title, status); on bigger
/// grids a page — its sessions' avatars stacked, the first titles.
private struct RoomTab: View {
    let page: [AgentSession]
    let index: Int
    let single: Bool
    let selected: Bool
    let model: SessionListModel
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    private var label: String {
        if single { return page.first?.title ?? "" }
        let names = page.prefix(2).map { Self.short($0.title) }
        let more = page.count - names.count
        return names.joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    private static func short(_ t: String) -> String {
        t.count > 18 ? String(t.prefix(17)) + "…" : t
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if single, let s = page.first {
                    AgentAvatar(tool: s.tool, size: 16, status: SessionHome.dot(for: s, in: model))
                } else {
                    // Overlapping avatars, like a group chat's.
                    HStack(spacing: -5) {
                        ForEach(page.prefix(4)) { s in
                            AgentAvatar(tool: s.tool, size: 15, status: SessionHome.dot(for: s, in: model))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        }
                    }
                }
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: single ? 200 : 260, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor)
                                   : (hovering ? Color.primary.opacity(0.05) : .clear))
                    .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 2, y: 1)
            }
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(accent).frame(height: 2).padding(.horizontal, 10).offset(y: 4)
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(page.map(\.title).joined(separator: "\n"))
    }
}

/// A layout's little grid of cells.
private struct GridGlyph: View {
    let cols: Int
    let rows: Int
    let on: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 1.5) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.2)
                            .fill(on ? accent : Color.secondary.opacity(0.55))
                    }
                }
            }
        }
        .frame(width: 14, height: 11)
    }
}

/// The Switchboard's mark: the wand on the room's tint.
private struct SwitchboardGlyph: View {
    let accent: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(accent.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "wand.and.rays")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
    }
}

/// The "To" picker: search, the Switchboard pinned on top, then every
/// session in the room with its avatar, status and folder.
private struct RoomTargetPicker: View {
    let controller: RoomStageController
    let accent: Color
    let done: () -> Void
    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searching: Bool

    private struct Row: Identifiable {
        let id: String
        let session: AgentSession?
        let title: String
        let subtitle: String
    }

    private var rows: [Row] {
        let model = controller.listModel
        var out = [Row(id: "switchboard", session: nil,
                       title: NSLocalizedString("Switchboard", comment: "room composer target"),
                       subtitle: NSLocalizedString("The whole room at once", comment: "room composer target"))]
        for s in controller.members {
            var sub = SessionHome.statusLine(for: s, in: model)
            if let nick = s.nickname { sub = "@\(nick) · " + sub }
            out.append(Row(id: s.id.uuidString, session: s, title: s.title, subtitle: sub))
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return out }
        return out.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
    }

    private var selectedID: String {
        controller.target == .switchboard ? "switchboard" : (controller.focusedID?.uuidString ?? "switchboard")
    }

    private func pick(_ id: String) {
        if id == "switchboard" {
            controller.target = .switchboard
        } else if let uuid = UUID(uuidString: id) {
            controller.focus(uuid)
            controller.reveal(uuid)
            controller.target = .focused
        }
        done()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("Send to…", comment: "room composer target"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { if let first = rows.first { pick(first.id) } }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { r in row(r) }
                    if rows.isEmpty {
                        Text(NSLocalizedString("No match", comment: "room composer target"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 320)
        .onAppear { searching = true }
    }

    private func row(_ r: Row) -> some View {
        let selected = r.id == selectedID
        let live = r.session.map { controller.models[$0.id] != nil } ?? (controller.switchboard != nil)
        return Button { pick(r.id) } label: {
            HStack(spacing: 10) {
                if let s = r.session {
                    AgentAvatar(tool: s.tool, size: 26, status: SessionHome.dot(for: s, in: controller.listModel))
                } else {
                    SwitchboardGlyph(accent: accent, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(r.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                }
            }
            .opacity(live ? 1 : 0.55)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hovered == r.id ? Color.primary.opacity(0.07)
                                      : (selected ? accent.opacity(0.10) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
    }
}
#endif
