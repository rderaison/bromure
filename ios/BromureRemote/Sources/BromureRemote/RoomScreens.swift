import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rooms (iPhone · iPad · visionOS)
//
// The mobile counterpart of the desktop's room stage (RoomStage.swift): a
// room groups sessions of the server, with its own Switchboard. The phone
// pages through them one at a time (a tab per session, swipe between); the
// pad lays them out in the room's grid (1×1 … 4×4, pages as tabs) like the
// desktop. One composer at the bottom talks to the room's Switchboard or to
// the session in focus. Everything reads the mirror (`roomStore`,
// `sessionStore`) and drives the server through `/agent-rooms` and the
// session "send" verb.

@MainActor
enum MobileRooms {
    static func members(_ c: RemoteHostController, _ room: AgentRoom) -> [AgentSession] {
        RoomTally.members(room, in: c.sessionStore.sessions).sorted { $0.createdAt < $1.createdAt }
    }

    /// Sessions in no (live) room — what the plain list shows.
    static func loose(_ list: [AgentSession], _ c: RemoteHostController) -> [AgentSession] {
        let ids = Set(c.roomStore.activeRooms.map(\.id))
        return list.filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }

    /// Put-away sessions not shown under an archived room's row.
    static func looseArchived(_ c: RemoteHostController) -> [AgentSession] {
        let ids = Set(c.roomStore.archivedRooms.map(\.id))
        return SessionHome.archived(c.sessionStore.sessions).filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }

    static func isLive(_ s: AgentSession, _ c: RemoteHostController) -> Bool {
        !s.hasEnded && s.windowIndex != nil && SessionHome.liveTab(for: s, in: c.listModel) != nil
    }

    static func move(_ c: RemoteHostController, _ sid: UUID, to room: UUID?) {
        var body: [String: Any] = ["session": sid.uuidString]
        if let room { body["room"] = room.uuidString }
        Task { await c.roomCommand(nil, "move", body: body) }
    }

    /// A new room (named) holding these sessions; its id.
    static func create(_ c: RemoteHostController, name: String, sessions: [UUID]) async -> UUID? {
        let r = await c.roomCommand(nil, "create", body: ["name": name, "sessions": sessions.map(\.uuidString)])
        return (r?["id"] as? String).flatMap(UUID.init(uuidString:))
    }
}

// MARK: - Pieces

/// The room's mark: a tinted rounded square with the grid glyph.
struct RoomTile: View {
    let hex: String
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hex: hex).gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white))
    }
}

/// Up to four members' avatars, overlapping like a group chat's.
struct RoomAvatarStack: View {
    let sessions: [AgentSession]
    let model: SessionListModel
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(sessions.prefix(4)) { s in
                AgentAvatar(tool: s.tool, size: size, status: SessionHome.dot(for: s, in: model))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28)
                        .strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.2))
            }
        }
    }
}

/// "Move to Room ▸ …, New Room…" and "Remove from Room" for a session's
/// long-press menu. `onNewRoom` asks for a name (the caller's alert).
struct RoomSessionMenu: View {
    let controller: RemoteHostController
    let session: AgentSession
    let onNewRoom: (AgentSession) -> Void

    var body: some View {
        if controller.supportsRooms, !session.isArchived {
            Menu {
                ForEach(controller.roomStore.activeRooms) { r in
                    Button(r.name) { MobileRooms.move(controller, session.id, to: r.id) }
                        .disabled(session.roomID == r.id)
                }
                if !controller.roomStore.activeRooms.isEmpty { Divider() }
                Button { onNewRoom(session) } label: {
                    Label("New Room…", systemImage: "plus.rectangle.on.rectangle")
                }
            } label: {
                Label("Move to Room", systemImage: "square.grid.2x2")
            }
            if let rid = session.roomID, controller.roomStore.room(rid) != nil {
                Button { MobileRooms.move(controller, session.id, to: nil) } label: {
                    Label("Remove from Room", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }
}

/// A room's long-press menu: new session in it, rename, color, delete.
struct RoomMenu: View {
    let controller: RemoteHostController
    let room: AgentRoom
    let onNewSession: (UUID) -> Void
    let onRename: (AgentRoom) -> Void
    let onDelete: (AgentRoom) -> Void

    var body: some View {
        Button { onNewSession(room.id) } label: {
            Label("New Session in Room", systemImage: "plus")
        }
        Button { onRename(room) } label: { Label("Rename…", systemImage: "pencil") }
        Menu {
            ForEach(AgentRoom.palette, id: \.self) { hex in
                Button {
                    Task { await controller.roomCommand(room.id, "color", body: ["hex": hex]) }
                } label: {
                    Label(RoomRowView.colorName(hex),
                          systemImage: room.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: { Label("Color", systemImage: "paintpalette") }
        Divider()
        if room.isArchived {
            Button { Task { await controller.roomCommand(room.id, "unarchive") } } label: {
                Label("Unarchive Room", systemImage: "tray.and.arrow.up")
            }
        } else {
            Button { Task { await controller.roomCommand(room.id, "archive") } } label: {
                Label("Archive Room", systemImage: "archivebox")
            }
        }
        Button { Task { await controller.roomCommand(room.id, "ungroup") } } label: {
            Label("Ungroup Room", systemImage: "rectangle.3.group")
        }
        Divider()
        Button(role: .destructive) { onDelete(room) } label: { Label("Delete Room…", systemImage: "trash") }
    }
}

/// Name a new room / rename one, and confirm a deletion — the alerts a
/// list presents for its rows' menus.
struct RoomPrompts: ViewModifier {
    let controller: RemoteHostController
    @Binding var newRoomFor: AgentSession?
    @Binding var renaming: AgentRoom?
    @Binding var deleting: AgentRoom?
    /// A room was just made: show it.
    var onCreated: (UUID) -> Void = { _ in }
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Room", isPresented: Binding(get: { newRoomFor != nil },
                                                    set: { if !$0 { newRoomFor = nil } })) {
                TextField("e.g. Payments v2", text: $name)
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sid = newRoomFor?.id
                    name = ""
                    guard !n.isEmpty else { return }
                    Task {
                        if let id = await MobileRooms.create(controller, name: n, sessions: sid.map { [$0] } ?? []) {
                            onCreated(id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("A room groups sessions that work on the same thing. Its own Switchboard keeps track of them — and only them.")
            }
            .alert("Rename Room", isPresented: Binding(get: { renaming != nil },
                                                       set: { if !$0 { renaming = nil } })) {
                TextField("e.g. Payments v2", text: $name)
                Button("Rename") {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let r = renaming, !n.isEmpty {
                        Task { await controller.roomCommand(r.id, "rename", body: ["name": n]) }
                    }
                    name = ""
                }
                Button("Cancel", role: .cancel) { name = "" }
            }
            .onChange(of: renaming?.id) { _, _ in name = renaming?.name ?? "" }
            .confirmationDialog(Text(String(format: NSLocalizedString("Delete “%@” and every session in it?", comment: "delete room"),
                                            deleting?.name ?? "")),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Room", role: .destructive) {
                    if let r = deleting { Task { await controller.roomCommand(r.id, "delete") } }
                    deleting = nil
                }
            } message: {
                Text("Their agents stop and the sessions leave the list. Their folders stay on the machines. To keep the sessions, ungroup the room instead.")
            }
    }
}

// MARK: - Phone dashboard card

struct MobileRoomCard: View {
    let controller: RemoteHostController
    let room: AgentRoom
    let action: () -> Void

    var body: some View {
        let model = controller.listModel
        let members = MobileRooms.members(controller, room)
        let urgent = members.contains { SessionHome.bucket(for: $0, in: model) == .needsYou }
        Button(action: action) {
            HStack(spacing: 12) {
                RoomTile(hex: room.colorHex, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(room.name).font(.body.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(RoomTally.summary(room, controller.sessionStore.sessions, in: model))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                RoomAvatarStack(sessions: members, model: model)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(urgent ? Color.red.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(alignment: .leading) {
                // The room's color, as a slim edge.
                Capsule().fill(Color(hex: room.colorHex)).frame(width: 3).padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pad sidebar row

struct PadRoomRow: View {
    let controller: RemoteHostController
    let room: AgentRoom

    var body: some View {
        let model = controller.listModel
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name).lineLimit(1)
                    Text(RoomTally.summary(room, controller.sessionStore.sessions, in: model))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                RoomAvatarStack(sessions: MobileRooms.members(controller, room), model: model, size: 16)
            }
        } icon: {
            RoomTile(hex: room.colorHex, size: 24)
        }
    }
}

// MARK: - The room

struct MobileRoomScreen: View {
    let controller: RemoteHostController
    let roomID: UUID
    var onOpenSession: (UUID) -> Void = { _ in }
    var onNewSession: (UUID) -> Void = { _ in }
    /// After "Delete Room": the phone pops back, the pad clears its column.
    var onGone: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var page = 0
    @State private var focusedID: UUID?
    @State private var toSwitchboard = true
    @State private var zoomedID: UUID?
    @State private var dockOpen = true
    @State private var draft = ""
    @State private var sending = false
    @State private var renaming: AgentRoom?
    @State private var deleting: AgentRoom?
    @State private var newRoomFor: AgentSession?
    @FocusState private var composing: Bool
    /// Staged for the next message: uploaded on send, into the machine of
    /// whoever it goes to.
    @State private var attachments: [ComposerAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var dropTargeted = false
    @State private var uploadProgress: Double?
    @State private var attachError: String?

    private var model: SessionListModel { controller.listModel }
    private var room: AgentRoom? { controller.roomStore.room(roomID) }
    private var members: [AgentSession] { room.map { MobileRooms.members(controller, $0) } ?? [] }
    private var switchboard: AgentSession? {
        room.flatMap { RoomTally.switchboard(of: $0, in: controller.sessionStore.sessions) }
    }
    private var compact: Bool { hSize == .compact }
    private var accent: Color { Color(hex: room?.colorHex ?? "#6366F1") }

    /// The phone shows one session at a time; the pad the room's grid.
    private var layout: RoomLayout {
        if compact { return RoomLayout(cols: 1, rows: 1) }
        return room?.layout.flatMap(RoomLayout.init) ?? .fitting(members.count)
    }
    private var pages: [[AgentSession]] { layout.pages(members) }
    private var focused: AgentSession? { focusedID.flatMap { id in members.first { $0.id == id } } }

    var body: some View {
        Group {
            if let room {
                stage(room)
            } else {
                ContentUnavailableView("This room is empty", systemImage: "square.grid.2x2")
            }
        }
        .navigationTitle(room?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .modifier(RoomPrompts(controller: controller, newRoomFor: $newRoomFor,
                              renaming: $renaming, deleting: $deleting))
        .onChange(of: controller.roomStore.room(roomID) == nil) { _, gone in if gone { onGone() } }
        .onAppear(perform: settleFocus)
        #if DEBUG
        // Headless check of the composer's attachments:
        // `BROMURE_DEBUG_ROOM_ATTACH=1` stages a sample image + text file;
        // `=upload` also uploads them to the focused session's machine
        // (no message is sent) and logs the guest paths.
        .task { await debugAttach() }
        #endif
        .onChange(of: members.map(\.id)) { _, _ in settleFocus() }
        .onChange(of: page) { _, p in
            // Swiping to a page brings the focus (and the composer) along.
            if let f = focusedID, pages.indices.contains(p), pages[p].contains(where: { $0.id == f }) { return }
            if pages.indices.contains(p) { focus(pages[p].first?.id) }
        }
    }

    private func settleFocus() {
        if switchboard == nil { toSwitchboard = false }
        if focusedID == nil || !members.contains(where: { $0.id == focusedID }) { focus(members.first?.id) }
        page = min(page, max(0, pages.count - 1))
    }

    private func focus(_ id: UUID?) {
        focusedID = id
        let s = id.flatMap { id in members.first { $0.id == id } }
        model.roomFocusProfileID = s?.profileID
        model.roomFocusCwd = s?.cwd
    }

    private func reveal(_ id: UUID) {
        if let i = members.firstIndex(where: { $0.id == id }) {
            withAnimation(.snappy) { page = i / layout.size }
        }
    }

    // MARK: Stage

    @ViewBuilder private func stage(_ room: AgentRoom) -> some View {
        VStack(spacing: 0) {
            if room.isArchived {
                // Put away: say so, and one tap brings it all back.
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                    Text("Archived").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unarchive Room") { Task { await controller.roomCommand(roomID, "unarchive") } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
            }
            if members.isEmpty {
                empty
            } else {
                if zoomedID == nil, pages.count > 1 || layout.size == 1 { tabStrip }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            dock
            composer
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            RoomTile(hex: room?.colorHex ?? "#6366F1", size: 54)
            Text("This room is empty").font(.headline)
            Text("Drag sessions onto the room in the sidebar, or start one here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { onNewSession(roomID) } label: {
                Label("New Session", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tab per page: at 1×1 (always on the phone) a tab per session.
    private var tabStrip: some View {
        let single = layout.size == 1
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        tab(p, index: i, single: single).id(i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: page) { _, p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ p: [AgentSession], index i: Int, single: Bool) -> some View {
        let on = i == page
        let label: String = single ? (p.first?.title ?? "")
            : p.prefix(2).map(\.title).joined(separator: ", ") + (p.count > 2 ? " +\(p.count - 2)" : "")
        return Button {
            withAnimation(.snappy) { page = i }
        } label: {
            HStack(spacing: 6) {
                if single, let s = p.first {
                    AgentAvatar(tool: s.tool, size: 16, status: SessionHome.dot(for: s, in: model))
                } else {
                    RoomAvatarStack(sessions: p, model: model, size: 15)
                }
                Text(label).lineLimit(1).frame(maxWidth: 180)
                    .font(.subheadline.weight(on ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? accent.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? accent.opacity(0.45) : .clear, lineWidth: 1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if let z = zoomedID, let s = members.first(where: { $0.id == z }) {
            cell(s, zoomed: true).padding(10)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        } else if compact {
            // One session per page; swipe between them.
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    if let s = p.first { cell(s, zoomed: false).padding(10).tag(i) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        } else {
            GeometryReader { geo in
                let l = layout
                let p = pages.indices.contains(page) ? pages[page] : []
                let spacing: CGFloat = 10
                let h = (geo.size.height - spacing * CGFloat(l.rows + 1)) / CGFloat(l.rows)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: l.cols),
                          spacing: spacing) {
                    ForEach(p) { s in cell(s, zoomed: false).frame(height: max(120, h)) }
                }
                .padding(spacing)
                .id(page)
                .transition(.push(from: .trailing))
            }
        }
    }

    private func cell(_ s: AgentSession, zoomed: Bool) -> some View {
        let isFocused = focusedID == s.id
        let addressed = isFocused && !toSwitchboard
        return RoomCellView(controller: controller, session: s, zoomed: zoomed,
                            onZoom: {
                                focus(s.id)
                                toSwitchboard = false
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                                    zoomedID = zoomedID == s.id ? nil : s.id
                                }
                            },
                            onOpen: { onOpenSession(s.id) },
                            onRemove: { MobileRooms.move(controller, s.id, to: nil) })
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFocused ? accent.opacity(addressed ? 1 : 0.4) : Color.primary.opacity(0.08),
                              lineWidth: isFocused ? 2 : 1))
            .shadow(color: .black.opacity(addressed ? 0.12 : 0.04), radius: addressed ? 8 : 2, y: 2)
            .simultaneousGesture(TapGesture().onEnded {
                focus(s.id)
                toSwitchboard = false
            })
    }

    // MARK: Switchboard dock

    private var dock: some View {
        let shown = dockOpen && zoomedID == nil
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { dockOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays").foregroundStyle(accent)
                    Text("Switchboard").font(.subheadline.weight(.semibold))
                    Text("keeps track of this room's sessions")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: shown ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            if shown {
                Group {
                    if let sb = switchboard, MobileRooms.isLive(sb, controller) {
                        RoomTranscriptView(controller: controller, session: sb)
                            .simultaneousGesture(TapGesture().onEnded { toSwitchboard = true })
                    } else if let sb = switchboard, sb.isLaunching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("The room's Switchboard is starting…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let sb = switchboard {
                        // Asleep or ended (its machine went down): wake it.
                        VStack(spacing: 10) {
                            Image(systemName: "moon.zzz").font(.system(size: 26, weight: .light))
                                .foregroundStyle(.tertiary)
                            Button("Resume") { controller.sessionCommand(sb.id, "resume") }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 10) {
                            Text("Ask about everything in this room at once — what's stuck, what's done — or have it answer and start sessions for you.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Start the Room's Switchboard") {
                                Task {
                                    await controller.roomCommand(roomID, "switchboard")
                                    toSwitchboard = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: compact ? 170 : 220)
                .background(Color.platformWindowBackground)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: The one composer

    private var targetID: UUID? { toSwitchboard ? switchboard?.id : focusedID }

    private var targetName: String {
        toSwitchboard ? NSLocalizedString("Switchboard", comment: "room composer target") : (focused?.title ?? "")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("To").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                targetMenu
                Spacer()
                if let attachError {
                    Label(attachError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty { attachmentChips }
                HStack(alignment: .bottom, spacing: 10) {
                    attachMenu
                    TextField(String(format: NSLocalizedString("Message %@…", comment: "room composer"),
                                     toSwitchboard ? NSLocalizedString("the Switchboard", comment: "room composer target")
                                                   : targetName),
                              text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($composing)
                        .padding(.bottom, 4)
                    Button(action: send) {
                        ZStack {
                            if let uploadProgress {
                                // Uploading: the button fills as the bytes go.
                                Circle().stroke(accent.opacity(0.2), lineWidth: 3)
                                Circle().trim(from: 0, to: max(0.04, uploadProgress))
                                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.2), value: uploadProgress)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(sendable ? accent : Color.secondary.opacity(0.35))
                            }
                        }
                        .frame(width: 30, height: 30)
                    }
                    .disabled(!sendable)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.platformTextBackground))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(dropTargeted ? accent : (composing ? accent.opacity(0.5) : Color.primary.opacity(0.1)),
                              lineWidth: dropTargeted ? 2 : 1))
            // Images and files dropped on the composer (iPad, visionOS).
            .onDrop(of: [.image, .fileURL, .data], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10,
                      matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true, onCompletion: addFiles)
    }

    /// The paperclip: photos, files, or the clipboard's image.
    private var attachMenu: some View {
        Menu {
            Button { pickingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { pickingFiles = true } label: { Label("Choose Files", systemImage: "folder") }
            if UIPasteboard.general.hasImages {
                Button(action: pasteImages) { Label("Paste Image", systemImage: "doc.on.clipboard") }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(attachments.isEmpty ? Color.secondary : accent)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .disabled(uploadProgress != nil)
        .accessibilityLabel("Attach")
    }

    /// What's staged: photo thumbnails, file chips; each removable.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ComposerAttachmentChip(attachment: a, accent: accent) {
                        withAnimation(.snappy) { attachments.removeAll { $0.id == a.id } }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
        }
    }

    /// The "To" token: whom the message goes to. A native menu — the
    /// Switchboard, then every session in the room.
    private var targetMenu: some View {
        Menu {
            Button {
                toSwitchboard = true
            } label: {
                Label("Switchboard", systemImage: toSwitchboard ? "checkmark" : "wand.and.rays")
            }
            .disabled(switchboard == nil)
            Section("Sessions") {
                ForEach(members) { m in
                    Button {
                        focus(m.id)
                        toSwitchboard = false
                        reveal(m.id)
                    } label: {
                        Label(m.title, systemImage: !toSwitchboard && focusedID == m.id ? "checkmark" : "bubble.left")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if toSwitchboard {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(accent.gradient)
                        .frame(width: 18, height: 18)
                        .overlay(Image(systemName: "wand.and.rays").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white))
                } else if let f = focused {
                    AgentAvatar(tool: f.tool, size: 18, status: SessionHome.dot(for: f, in: model))
                }
                Text(targetName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
            .foregroundStyle(.primary)
        }
    }

    private var sendable: Bool {
        !sending && targetID != nil
            && (!attachments.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Upload what's staged into the target's machine (the paths join the
    /// message, like a drop on the desktop), then send. The server types it
    /// into the live prompt, or resumes with it.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = targetID, let target = controller.sessionStore.session(id), sendable else { return }
        let staged = attachments
        sending = true
        attachError = nil
        Task { @MainActor in
            var paths: [String] = []
            if !staged.isEmpty {
                uploadProgress = 0
                do {
                    paths = try await ComposerAttachment.upload(staged, controller: controller,
                                                                profileID: target.profileID) { uploadProgress = $0 }
                } catch {
                    attachError = NSLocalizedString("Couldn't upload the attachments", comment: "room composer")
                    uploadProgress = nil
                    sending = false
                    return
                }
            }
            let message = ([text] + paths).filter { !$0.isEmpty }.joined(separator: " ")
            controller.sessionCommand(id, "send", body: ["text": message])
            draft = ""
            withAnimation(.snappy) { attachments.removeAll { a in staged.contains { $0.id == a.id } } }
            uploadProgress = nil
            sending = false
        }
    }

    #if DEBUG
    private func debugAttach() async {
        let mode = ProcessInfo.processInfo.environment["BROMURE_DEBUG_ROOM_ATTACH"] ?? ""
        guard !mode.isEmpty, attachments.isEmpty else { return }
        let img = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { ctx in
            UIColor.systemIndigo.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        stage(ComposerAttachment(name: "sample.png", data: img.pngData() ?? Data(), thumbnail: img))
        stage(ComposerAttachment(name: "meeting notes.txt", data: Data("room attachment test\n".utf8), thumbnail: nil))
        guard mode == "upload" else { return }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let f = focused else { FatClientLog.log("room-attach: no focused session"); return }
        do {
            let paths = try await ComposerAttachment.upload(attachments, controller: controller,
                                                            profileID: f.profileID) { uploadProgress = $0 }
            FatClientLog.log("room-attach: uploaded \(paths.joined(separator: " "))")
        } catch {
            FatClientLog.log("room-attach: upload failed \(error)")
        }
        uploadProgress = nil
    }
    #endif

    // MARK: Attachments in

    private func stage(_ a: ComposerAttachment) {
        let total = attachments.reduce(0) { $0 + $1.data.count } + a.data.count
        guard total <= TerminalImagePaste.maxTotalBytes else {
            attachError = NSLocalizedString("That's too much to attach at once", comment: "room composer")
            return
        }
        attachError = nil
        withAnimation(.snappy) { attachments.append(a) }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            guard let raw = try? await item.loadTransferable(type: Data.self), !raw.isEmpty else { continue }
            // Photos travel as JPEG: an agent reads it, and HEIC often not.
            let image = UIImage(data: raw)
            let data = image?.jpegData(compressionQuality: 0.9) ?? raw
            stage(ComposerAttachment(name: "photo-\(i + 1).jpg", data: data, thumbnail: image))
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            // Read while the security scope is open; the upload runs later.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            stage(ComposerAttachment(name: url.lastPathComponent, data: data,
                                     thumbnail: isImage ? UIImage(data: data) : nil))
        }
    }

    private func pasteImages() {
        for (i, img) in (UIPasteboard.general.images ?? []).enumerated() {
            guard let png = img.pngData() else { continue }
            stage(ComposerAttachment(name: "pasted-\(i + 1).png", data: png, thumbnail: img))
        }
    }

    /// Dropped images and files. A dragged session row (plain text) is not
    /// an attachment.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                _ = p.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    let name = p.suggestedName.map { $0.contains(".") ? $0 : $0 + ".png" } ?? "image.png"
                    Task { @MainActor in stage(ComposerAttachment(name: name, data: data, thumbnail: UIImage(data: data))) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                      !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                took = true
                _ = p.loadFileRepresentation(for: .data, openInPlace: false) { url, _, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    Task { @MainActor in stage(ComposerAttachment(name: name, data: data, thumbnail: nil)) }
                }
            }
        }
        return took
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if zoomedID != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { zoomedID = nil }
                } label: { Label("Room", systemImage: "chevron.left") }
            }
        }
        if !compact, !members.isEmpty, zoomedID == nil {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(RoomLayout.all, id: \.self) { l in
                        Button {
                            Task { await controller.roomCommand(roomID, "layout", body: ["layout": l.string]) }
                            // Keep the focused session on screen.
                            if let f = focusedID, let i = members.firstIndex(where: { $0.id == f }) { page = i / l.size }
                        } label: {
                            Label(String(format: NSLocalizedString("%d × %d grid", comment: "room layout"), l.cols, l.rows),
                                  systemImage: l == layout ? "checkmark" : Self.symbol(l))
                        }
                    }
                } label: { Image(systemName: Self.symbol(layout)) }
                .accessibilityLabel("Layout")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { onNewSession(roomID) } label: { Image(systemName: "plus") }
                .accessibilityLabel("New Session in Room")
        }
        if let room {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    RoomMenu(controller: controller, room: room,
                             onNewSession: onNewSession,
                             onRename: { renaming = $0 },
                             onDelete: { deleting = $0 })
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    /// The SF Symbol closest to a layout.
    static func symbol(_ l: RoomLayout) -> String {
        switch l.size {
        case 1: return "square"
        case 2: return "rectangle.split.2x1"
        case 4: return "square.grid.2x2"
        default: return "square.grid.3x3"
        }
    }
}

// MARK: - A cell

/// A session in the room: identity bar, then its live conversation (read
/// only — the room's composer talks to it), or its resting state.
struct RoomCellView: View {
    let controller: RemoteHostController
    let session: AgentSession
    let zoomed: Bool
    let onZoom: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let model = controller.listModel
        let s = session
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentAvatar(tool: s.tool, size: 20, status: SessionHome.dot(for: s, in: model))
                Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let nick = s.nickname {
                    Text("@" + nick).font(.caption.monospaced()).foregroundStyle(.tint)
                }
                Text(SessionHome.statusLine(for: s, in: model))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Button { onOpen() } label: { Label("Open as Session", systemImage: "arrow.up.forward.app") }
                    Button { onRemove() } label: {
                        Label("Remove from Room", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
                }
                Button(action: onZoom) {
                    Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left"
                                             : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(zoomed ? "Back to the whole room" : "Zoom in")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if MobileRooms.isLive(s, controller) {
                RoomTranscriptView(controller: controller, session: s)
            } else {
                resting(s)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func resting(_ s: AgentSession) -> some View {
        let bucket = SessionHome.bucket(for: s, in: controller.listModel)
        return VStack(spacing: 10) {
            if s.isLaunching {
                ProgressView()
                Text("Starting…").foregroundStyle(.secondary)
            } else {
                Image(systemName: bucket == .ended ? "stop.circle" : "moon.zzz")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text(bucket.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Button("Resume") { controller.sessionCommand(s.id, "resume") }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A live session's conversation, tailed from its own tmux window's
/// transcript (pinned, so two sessions in one folder don't mix) every two
/// seconds. Read-only.
struct RoomTranscriptView: View {
    let controller: RemoteHostController
    let session: AgentSession
    @State private var items: [TranscriptItem] = []
    @State private var loaded = false

    private var window: Int { session.windowIndex ?? 0 }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("No messages yet")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(items) { TranscriptItemView(item: $0) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: items.count) { _, _ in
                        if let last = items.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                }
            }
        }
        .task(id: "\(session.profileID)#\(window)") { await poll() }
    }

    /// The tab's folder and floor come from the guest — the desktop chat's
    /// probe: the agent process's start, 0 for a resumed agent (it
    /// reattaches an older transcript). Re-probed every ~10 s (a relaunch
    /// moves both); the transcript itself every 2 s.
    private func poll() async {
        let agent = session.tool.rawValue
        var cmd: String?
        var tick = 0
        while !Task.isCancelled {
            if cmd == nil || tick % 5 == 0,
               let probe = AgentSessionLocator.parseFloorProbe(try? await controller.guestExec(
                   session.profileID, command: AgentSessionLocator.floorProbeCommand(window: window), timeout: 8)) {
                cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: probe.cwd, since: probe.since,
                                                             agent: agent, pinnedWindow: window)
            }
            if let cmd, let raw = try? await controller.guestExec(session.profileID, command: cmd, timeout: 15) {
                items = AgentTranscript.parse(Data(raw.utf8), agent: agent)
            }
            loaded = true
            tick += 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

// MARK: - Composer attachments

/// A file staged in the room's composer.
struct ComposerAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    /// Set for images: the chip shows it.
    let thumbnail: UIImage?

    /// Into the guest's pastes dir (where desktop pastes land), chunked,
    /// under the original name so the agent sees what it is. The guest
    /// paths, in order.
    @MainActor
    static func upload(_ items: [ComposerAttachment], controller: RemoteHostController, profileID: UUID,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> [String] {
        let dir = TerminalImagePaste.pastesDir
        _ = try await controller.guestFileOp(profileID, op: ["op": "mkdir", "path": dir])
        let total = max(1, items.reduce(0) { $0 + $1.data.count })
        var sent = 0
        var paths: [String] = []
        for item in items {
            let unique = String(UUID().uuidString.prefix(6)).lowercased()
            let path = dir + "/" + unique + "-" + safeName(item.name)
            var offset = 0
            repeat {
                let end = min(offset + TerminalImagePaste.chunkBytes, item.data.count)
                _ = try await controller.guestFileOp(profileID, op: [
                    "op": "write", "path": path,
                    "data": item.data.subdata(in: offset..<end).base64EncodedString(),
                    "append": offset > 0,
                ])
                sent += end - offset
                offset = end
                progress(min(1, Double(sent) / Double(total)))
            } while offset < item.data.count
            paths.append(path)
        }
        return paths
    }

    /// One path word: no slashes or whitespace (the path joins the message).
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { $0 == "/" || $0.isWhitespace ? "-" : $0 }
        let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return s.isEmpty ? "file" : String(s.suffix(80))
    }
}

/// A staged attachment: a thumbnail for an image, a name + size for a file.
struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let accent: Color
    let onRemove: () -> Void

    var body: some View {
        Group {
            if let img = attachment.thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(attachment.name))
                        .font(.system(size: 18))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    static func symbol(_ name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .json) == true { return "chevron.left.forwardslash.chevron.right" }
        if type?.conforms(to: .text) == true { return "doc.text" }
        if type?.conforms(to: .archive) == true { return "archivebox" }
        if type?.conforms(to: .spreadsheet) == true { return "tablecells" }
        return "doc"
    }
}
