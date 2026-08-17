#if os(macOS)
import SwiftUI

// The Rooms window works against a `RoomsBackend`, so the same UI drives either
// the LOCAL broker (this machine's agents) or a REMOTE host over the fat-client
// tunnel (`/comms/*` control-socket endpoints). That's what makes room config
// reachable from a fat client: the window binds to whichever host you're
// driving.
@MainActor
protocol RoomsBackend: AnyObject {
    var rooms: [AgentCommsBroker.Room] { get }
    /// Bumped whenever the transcript or roster changes — the view reads it to
    /// re-render (belt-and-suspenders alongside `rooms`).
    var revision: Int { get }
    func transcript(roomID: UUID) -> [AgentCommsBroker.Message]
    func workspaceList() -> [(id: UUID, name: String)]
    @discardableResult func createRoom(name: String, members: [UUID]) -> AgentCommsBroker.Room
    func updateRoom(_ id: UUID, name: String, members: [UUID])
    func deleteRoom(_ id: UUID)
    func postAsHuman(roomID: UUID, text: String)
    /// Tell the backend which room's transcript to keep fresh (remote polls it).
    func selectRoom(_ id: UUID?)
    func startMirroring()
    func stopMirroring()
}

// MARK: - Local backend (this machine's broker)

@MainActor
final class LocalRoomsBackend: RoomsBackend {
    private let broker = AgentCommsBroker.shared
    private let workspacesProvider: () -> [(id: UUID, name: String)]

    init(workspaces: @escaping () -> [(id: UUID, name: String)]) {
        self.workspacesProvider = workspaces
    }

    var rooms: [AgentCommsBroker.Room] { broker.rooms }
    var revision: Int { broker.revision }
    func transcript(roomID: UUID) -> [AgentCommsBroker.Message] { broker.transcript(roomID: roomID) }
    func workspaceList() -> [(id: UUID, name: String)] { workspacesProvider() }
    @discardableResult func createRoom(name: String, members: [UUID]) -> AgentCommsBroker.Room {
        broker.createRoom(name: name, members: members)
    }
    func updateRoom(_ id: UUID, name: String, members: [UUID]) {
        broker.updateRoom(id, name: name, members: members)
    }
    func deleteRoom(_ id: UUID) { broker.deleteRoom(id) }
    func postAsHuman(roomID: UUID, text: String) {
        Task { await broker.postHuman(roomID: roomID, text: text) }
    }
    func selectRoom(_ id: UUID?) {}
    func startMirroring() {}
    func stopMirroring() {}
}

// MARK: - Remote backend (a fat-client-mirrored host, over /comms/*)

@MainActor
@Observable
final class RemoteRoomsClient: RoomsBackend {
    private let host: RemoteHost
    var rooms: [AgentCommsBroker.Room] = []
    var revision = 0
    private var transcripts: [UUID: [AgentCommsBroker.Message]] = [:]
    private var workspaces: [(id: UUID, name: String)] = []
    private var selectedRoomID: UUID?
    private var pollTimer: Timer?

    init(host: RemoteHost) { self.host = host }

    func transcript(roomID: UUID) -> [AgentCommsBroker.Message] { transcripts[roomID] ?? [] }
    func workspaceList() -> [(id: UUID, name: String)] { workspaces }

    @discardableResult func createRoom(name: String, members: [UUID]) -> AgentCommsBroker.Room {
        let optimistic = AgentCommsBroker.Room(name: name, members: members)
        rooms.append(optimistic)   // optimistic; poll reconciles ids
        send("POST", "/comms/rooms",
             ["name": name, "members": members.map(\.uuidString)])
        return optimistic
    }
    func updateRoom(_ id: UUID, name: String, members: [UUID]) {
        if let i = rooms.firstIndex(where: { $0.id == id }) {
            rooms[i].name = name; rooms[i].members = members
        }
        send("POST", "/comms/rooms",
             ["id": id.uuidString, "name": name, "members": members.map(\.uuidString)])
    }
    func deleteRoom(_ id: UUID) {
        rooms.removeAll { $0.id == id }
        send("DELETE", "/comms/rooms/\(id.uuidString)", nil)
    }
    func postAsHuman(roomID: UUID, text: String) {
        send("POST", "/comms/rooms/\(roomID.uuidString)/post", ["text": text])
    }
    func selectRoom(_ id: UUID?) {
        selectedRoomID = id
        if id != nil { pollNow() }
    }

    func startMirroring() {
        pollNow()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
        pollTimer = t
    }
    func stopMirroring() { pollTimer?.invalidate(); pollTimer = nil }

    // MARK: request plumbing (mirrors RemoteHostController.saveProfileDoc)

    @discardableResult
    private func request(_ method: String, _ path: String, _ body: [String: Any]?) async -> [String: Any]? {
        let host = self.host
        let resp = try? await Task.detached(priority: .userInitiated) {
            try RemoteTransport.client(for: host).request(method, path, body: body)
        }.value
        guard let resp, resp.status >= 200, resp.status < 300 else { return nil }
        return resp.json
    }
    /// Fire-and-forget mutation; refresh right after so the UI reflects it.
    private func send(_ method: String, _ path: String, _ body: [String: Any]?) {
        Task { @MainActor in
            _ = await request(method, path, body)
            pollNow()
        }
    }

    private func pollNow() {
        Task { @MainActor in
            if let j = await request("GET", "/comms/rooms", nil) {
                rooms = (j["rooms"] as? [[String: Any]] ?? []).compactMap(Self.decodeRoom)
                workspaces = (j["workspaces"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let s = d["id"] as? String, let id = UUID(uuidString: s),
                          let n = d["name"] as? String else { return nil }
                    return (id, n)
                }
            }
            if let id = selectedRoomID,
               let j = await request("GET", "/comms/rooms/\(id.uuidString)/transcript", nil) {
                transcripts[id] = (j["messages"] as? [[String: Any]] ?? [])
                    .compactMap { Self.decodeMessage($0, roomID: id) }
            }
            revision &+= 1
        }
    }

    private static func decodeRoom(_ d: [String: Any]) -> AgentCommsBroker.Room? {
        guard let s = d["id"] as? String, let id = UUID(uuidString: s),
              let name = d["name"] as? String else { return nil }
        let members = (d["members"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let remote = (d["remoteMembers"] as? [[String: Any]] ?? []).compactMap {
            r -> AgentCommsBroker.RemotePeer? in
            guard let h = r["host"] as? String, let l = r["label"] as? String else { return nil }
            return AgentCommsBroker.RemotePeer(host: h, label: l)
        }
        return AgentCommsBroker.Room(id: id, name: name, members: members, remoteMembers: remote)
    }
    private static let iso = ISO8601DateFormatter()
    private static func decodeMessage(_ d: [String: Any], roomID: UUID) -> AgentCommsBroker.Message? {
        guard let s = d["id"] as? String, let id = UUID(uuidString: s),
              let from = d["from"] as? String, let text = d["text"] as? String else { return nil }
        let ts = (d["time"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        return AgentCommsBroker.Message(id: id, roomID: roomID, fromProfileID: UUID(),
                                        fromBranch: "", fromLabel: from, text: text,
                                        ts: ts, verdict: d["verdict"] as? String ?? "clean")
    }
}

// MARK: - View

/// The Rooms window: create rooms (groups of workspaces whose agents may talk),
/// watch each room's conversation, and drop in a message yourself. A room is
/// the ACL — agents can only message peers they share a room with.
struct AgentRoomsView<B: RoomsBackend>: View {
    let backend: B
    let onClose: () -> Void

    @State private var selection: UUID?
    @State private var editing: AgentCommsBroker.Room?
    @State private var creating = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            backend.startMirroring()
            if selection == nil { selection = backend.rooms.first?.id }
            backend.selectRoom(selection)
        }
        .onChange(of: selection) { _, new in backend.selectRoom(new) }
        .onDisappear { backend.stopMirroring(); onClose() }
        .sheet(isPresented: $creating) {
            RoomEditorSheet(title: NSLocalizedString("New room", comment: ""),
                            workspaces: backend.workspaceList(), room: nil) { name, members in
                let r = backend.createRoom(name: name, members: members)
                selection = r.id
            }
        }
        .sheet(item: $editing) { room in
            RoomEditorSheet(title: NSLocalizedString("Edit room", comment: ""),
                            workspaces: backend.workspaceList(), room: room) { name, members in
                backend.updateRoom(room.id, name: name, members: members)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Rooms", comment: "")).font(.headline)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("New room", comment: ""))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if backend.rooms.isEmpty {
                Spacer()
                Text(NSLocalizedString("No rooms yet", comment: ""))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(backend.rooms) { room in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name).lineLimit(1)
                            Text(memberSummary(room))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(room.id)
                        .contextMenu {
                            Button(NSLocalizedString("Edit…", comment: "")) { editing = room }
                            Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                                backend.deleteRoom(room.id)
                                if selection == room.id { selection = nil }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let room = backend.rooms.first(where: { $0.id == id }) {
            RoomTranscriptView(backend: backend, room: room, names: nameMap()) {
                editing = room
            }
        } else {
            ContentUnavailableView(
                NSLocalizedString("No room selected", comment: ""),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(NSLocalizedString(
                    "Create a room and add two or more workspaces. Their agents can then message each other with the bromure-comms tools — you'll see the conversation here.",
                    comment: "")))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nameMap() -> [UUID: String] {
        Dictionary(backend.workspaceList().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func memberSummary(_ room: AgentCommsBroker.Room) -> String {
        let names = nameMap()
        let all = room.members.map { names[$0] ?? "?" } + room.remoteMembers.map(\.label)
        return all.isEmpty
            ? NSLocalizedString("no members", comment: "")
            : all.joined(separator: ", ")
    }
}

// MARK: - Transcript

private struct RoomTranscriptView<B: RoomsBackend>: View {
    let backend: B
    let room: AgentCommsBroker.Room
    let names: [UUID: String]
    let onEdit: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(room.name).font(.headline)
                    Text(memberLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(NSLocalizedString("Members…", comment: ""), action: onEdit)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            messages
            Divider()
            composer
        }
    }

    private var messages: some View {
        let _ = backend.revision   // observe: refresh on new posts
        let msgs = backend.transcript(roomID: room.id)
        return ScrollViewReader { proxy in
            ScrollView {
                if msgs.isEmpty {
                    Text(NSLocalizedString("No messages yet. Agents in this room can reach each other with send_message; you can post below.", comment: ""))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40).padding(.horizontal)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(msgs) { m in MessageRow(message: m).id(m.id) }
                    }
                    .padding(14)
                }
            }
            .onChange(of: msgs.count) { _, _ in
                if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(NSLocalizedString("Message this room…", comment: ""), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
            Button(NSLocalizedString("Send", comment: ""), action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        backend.postAsHuman(roomID: room.id, text: text)
    }

    private var memberLine: String {
        let local = room.members.map { names[$0] ?? "?" }
        return (local + room.remoteMembers.map(\.label)).joined(separator: " · ")
    }
}

private struct MessageRow: View {
    let message: AgentCommsBroker.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.fromLabel).font(.caption).bold()
                if message.verdict != "clean" {
                    Text(message.verdict == "blocked"
                         ? NSLocalizedString("blocked", comment: "")
                         : NSLocalizedString("flagged", comment: ""))
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(message.ts, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(message.text)
                .font(.callout)
                .foregroundStyle(message.verdict == "blocked" ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Room editor sheet

struct RoomEditorSheet: View {
    let title: String
    let workspaces: [(id: UUID, name: String)]
    let room: AgentCommsBroker.Room?
    let onSave: (String, [UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(NSLocalizedString("Room name", comment: ""), text: $name)
                .textFieldStyle(.roundedBorder)
            Text(NSLocalizedString("Workspaces in this room", comment: ""))
                .font(.subheadline).foregroundStyle(.secondary)
            if workspaces.isEmpty {
                Text(NSLocalizedString("No workspaces available.", comment: ""))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(workspaces, id: \.id) { ws in
                        Toggle(isOn: Binding(
                            get: { members.contains(ws.id) },
                            set: { on in
                                if on { members.insert(ws.id) } else { members.remove(ws.id) }
                            })) {
                            Text(ws.name)
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 240)
                .border(Color.primary.opacity(0.1))
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Save", comment: "")) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? NSLocalizedString("Room", comment: "") : trimmed,
                           Array(members))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(members.count < 1)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            name = room?.name ?? ""
            members = Set(room?.members ?? [])
        }
    }
}
#endif
