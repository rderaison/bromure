import Foundation

/// Host-side broker for inter-agent messaging in Bromure AC.
///
/// The coding agents (Claude/Codex/Grok/Kimi) each run isolated in their own
/// disposable VM, so they can't — and mustn't — reach each other directly:
/// that would break the disposable-VM isolation and the egress firewall. The
/// Mac app is the only component that sees every workspace, is persistent
/// (the VMs come and go), and already runs the egress firewall, the
/// prompt-injection detector, and the audit pipeline. So it brokers every
/// message: agent → host → agent.
///
/// A **room** is the unit of who-may-talk — literally "the workspaces of my
/// choice." Two agent tabs can exchange messages only if their workspaces
/// share a room (default-deny). Each room owns a transcript held here on the
/// host, so a conversation survives the ephemeral VMs. Every message is
/// prompt-injection–scanned before delivery (an agent is untrusted input to
/// another agent), audited via `BACEventEmitter`, and rate/loop-limited so two
/// agents can't ping-pong forever burning tokens.
///
/// The broker is transport-agnostic: it holds the model and the policy, and
/// calls out through `Hooks` the app installs — enumerate live peers, push a
/// message into a running agent's turn, scan text, audit, and (for cross-host
/// rooms) relay to another machine.
@MainActor
@Observable
public final class AgentCommsBroker {
    public static let shared = AgentCommsBroker()

    // MARK: - Model

    /// A participant is one agent tab: a workspace (profile) + its worktree
    /// branch. The branch is how the board already distinguishes the several
    /// agents that can run in one workspace.
    public struct Participant: Hashable, Codable, Sendable {
        public var profileID: UUID
        public var branch: String   // "wt/<slug>" — the tab's identity
        public init(profileID: UUID, branch: String) {
            self.profileID = profileID
            self.branch = branch
        }
    }

    /// A live agent tab the app knows about — the raw material for `list_peers`
    /// and for resolving who a message reaches.
    public struct PeerInfo: Sendable, Hashable {
        public var profileID: UUID
        public var profileName: String
        public var branch: String
        public var tool: String        // "claude" | "codex" | "grok" | "kimi"
        public var live: Bool
        public init(profileID: UUID, profileName: String, branch: String,
                    tool: String, live: Bool) {
            self.profileID = profileID; self.profileName = profileName
            self.branch = branch; self.tool = tool; self.live = live
        }
        /// Human handle other agents address / @mention. Stable per tab.
        public var label: String {
            let slug = branch.hasPrefix("wt/") ? String(branch.dropFirst(3)) : branch
            let base = tool.isEmpty ? "agent" : tool
            if slug.isEmpty { return "\(base)·\(profileName)" }
            return "\(base)·\(profileName)·\(slug)"
        }
        public var participant: Participant { Participant(profileID: profileID, branch: branch) }
    }

    /// A cross-host member (a workspace on another machine reached over the
    /// fat-client tunnel). Kept opaque — the app's `deliverRemote` hook knows
    /// how to route to `host`.
    public struct RemotePeer: Codable, Equatable, Sendable {
        public var host: String    // remote server id/name (fat-client target)
        public var label: String
        public init(host: String, label: String) { self.host = host; self.label = label }
    }

    public struct Room: Identifiable, Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        /// Local workspaces (profile IDs) allowed to talk in this room.
        public var members: [UUID]
        /// Remote workspaces (other machines) in this room.
        public var remoteMembers: [RemotePeer]
        public var createdAt: Date
        public init(id: UUID = UUID(), name: String, members: [UUID],
                    remoteMembers: [RemotePeer] = [], createdAt: Date = Date()) {
            self.id = id; self.name = name; self.members = members
            self.remoteMembers = remoteMembers; self.createdAt = createdAt
        }
    }

    public struct Message: Identifiable, Codable, Sendable {
        public var id: UUID
        public var roomID: UUID
        public var fromProfileID: UUID
        public var fromBranch: String
        public var fromLabel: String
        public var text: String
        public var ts: Date
        /// "clean", "flagged:<detector>", or "blocked" — set by the PI scan.
        public var verdict: String
        public init(id: UUID = UUID(), roomID: UUID, fromProfileID: UUID,
                    fromBranch: String, fromLabel: String, text: String,
                    ts: Date = Date(), verdict: String = "clean") {
            self.id = id; self.roomID = roomID; self.fromProfileID = fromProfileID
            self.fromBranch = fromBranch; self.fromLabel = fromLabel
            self.text = text; self.ts = ts; self.verdict = verdict
        }
    }

    /// The prompt-injection verdict for one message. The app fills this via
    /// `PromptInjectionClassifier`; the broker only decides delivery from it.
    public struct Scan: Sendable {
        public var blocked: Bool
        public var detector: String?
        public var snippet: String?
        public init(blocked: Bool, detector: String? = nil, snippet: String? = nil) {
            self.blocked = blocked; self.detector = detector; self.snippet = snippet
        }
        public static let clean = Scan(blocked: false)
    }

    /// What `post` tells the sending agent.
    public struct PostResult: Sendable {
        public var ok: Bool
        public var summary: String
        public var messageID: UUID?
    }

    /// App-installed callbacks. Defaults are inert so the broker is safe before
    /// `configure(_:)` runs and in tests.
    public struct Hooks: Sendable {
        public var peers: @MainActor @Sendable () -> [PeerInfo]
        /// Deliver `text` into the running agent at (profileID, branch). Returns
        /// true if it was injected into a live turn.
        public var deliverPush: @MainActor @Sendable (UUID, String, String) async -> Bool
        /// Prompt-injection scan of a message body.
        public var scan: @Sendable (String) async -> Scan
        /// Emit the `agent.message` audit event (message + recipient labels).
        public var audit: @MainActor @Sendable (Message, [String]) -> Void
        /// Remote hosts currently reachable over the fat-client tunnel.
        public var remoteHosts: @MainActor @Sendable () -> [String]
        /// Relay a message to a room member on another machine.
        public var deliverRemote: @MainActor @Sendable (String, Message) async -> Bool

        public init(
            peers: @escaping @MainActor @Sendable () -> [PeerInfo] = { [] },
            deliverPush: @escaping @MainActor @Sendable (UUID, String, String) async -> Bool = { _, _, _ in false },
            scan: @escaping @Sendable (String) async -> Scan = { _ in .clean },
            audit: @escaping @MainActor @Sendable (Message, [String]) -> Void = { _, _ in },
            remoteHosts: @escaping @MainActor @Sendable () -> [String] = { [] },
            deliverRemote: @escaping @MainActor @Sendable (String, Message) async -> Bool = { _, _ in false }
        ) {
            self.peers = peers; self.deliverPush = deliverPush; self.scan = scan
            self.audit = audit; self.remoteHosts = remoteHosts; self.deliverRemote = deliverRemote
        }
    }

    // MARK: - State

    /// Rooms — the ACL. Persisted; observed by the Rooms window.
    public private(set) var rooms: [Room] = []
    /// Per-room transcript, in-memory (the host is the persistence; VMs are
    /// disposable). Capped ring so a runaway conversation can't grow forever.
    private var messagesByRoom: [UUID: [Message]] = [:]
    /// Bumped on every transcript append so `@Observable` views refresh.
    public private(set) var revision = 0
    private var lastReadByParticipant: [Participant: Date] = [:]

    // Loop / rate guards.
    private var postTimesByRoom: [UUID: [Date]] = [:]
    private var pushTimesByTab: [Participant: [Date]] = [:]
    private static let maxRoomPostsPerMinute = 40
    private static let maxPushesPerTabPerMinute = 12
    private static let transcriptCap = 2000

    private var hooks = Hooks()
    private var loaded = false

    // MARK: - Lifecycle

    public func configure(_ hooks: Hooks) {
        self.hooks = hooks
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Room].self, from: data) else { return }
        rooms = decoded
    }

    /// Test seam: when set, rooms persist here instead of the shared support
    /// file, so tests never touch (or clobber) the user's real rooms.
    static var storeURLOverrideForTesting: URL?

    private static var storeURL: URL? {
        if let override = storeURLOverrideForTesting { return override }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("BromureAC", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("agent-rooms.json")
    }

    private func persistRooms() {
        guard let url = Self.storeURL,
              let data = try? JSONEncoder().encode(rooms) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Room management (Rooms window)

    @discardableResult
    public func createRoom(name: String, members: [UUID],
                           remoteMembers: [RemotePeer] = []) -> Room {
        loadIfNeeded()
        let room = Room(name: name, members: members, remoteMembers: remoteMembers)
        rooms.append(room)
        persistRooms()
        return room
    }

    public func updateRoom(_ id: UUID, name: String? = nil, members: [UUID]? = nil,
                           remoteMembers: [RemotePeer]? = nil) {
        guard let i = rooms.firstIndex(where: { $0.id == id }) else { return }
        if let name { rooms[i].name = name }
        if let members { rooms[i].members = members }
        if let remoteMembers { rooms[i].remoteMembers = remoteMembers }
        persistRooms()
    }

    public func deleteRoom(_ id: UUID) {
        rooms.removeAll { $0.id == id }
        messagesByRoom[id] = nil
        persistRooms()
    }

    /// Rooms a workspace belongs to.
    public func rooms(forProfile profileID: UUID) -> [Room] {
        loadIfNeeded()
        return rooms.filter { $0.members.contains(profileID) }
    }

    public func transcript(roomID: UUID) -> [Message] { messagesByRoom[roomID] ?? [] }

    /// Debug/demo seam: append a message straight into a room's transcript
    /// (bypasses ACL/scan/delivery). Used only by the screenshot fixture.
    public func seedMessage(roomID: UUID, fromLabel: String, text: String,
                            verdict: String = "clean", ts: Date) {
        append(Message(roomID: roomID, fromProfileID: UUID(), fromBranch: "",
                       fromLabel: fromLabel, text: text, ts: ts, verdict: verdict),
               to: roomID)
    }

    /// A tab's own handle, from the live roster (falls back to a constructed
    /// one when the app hasn't published this tab yet).
    public func label(for me: Participant) -> String {
        if let p = hooks.peers().first(where: { $0.participant == me }) { return p.label }
        let slug = me.branch.hasPrefix("wt/") ? String(me.branch.dropFirst(3)) : me.branch
        return slug.isEmpty ? "agent" : "agent·\(slug)"
    }

    // MARK: - Peer discovery (list_peers / list_rooms)

    /// Live peers the given tab is allowed to reach: every OTHER member tab of
    /// the rooms this workspace shares. Default-deny — a workspace in no shared
    /// room sees nobody.
    public func peers(for me: Participant) -> [(peer: PeerInfo, rooms: [String])] {
        loadIfNeeded()
        let myRooms = rooms.filter { $0.members.contains(me.profileID) }
        guard !myRooms.isEmpty else { return [] }
        let reachableProfiles = Set(myRooms.flatMap(\.members))
        let live = hooks.peers()
        return live.compactMap { p in
            guard reachableProfiles.contains(p.profileID),
                  p.participant != me else { return nil }
            let inRooms = myRooms
                .filter { $0.members.contains(p.profileID) }
                .map(\.name)
            return (p, inRooms)
        }
    }

    /// The rooms this workspace is in, with the labels of the other members
    /// currently live.
    public func roomSummaries(for me: Participant) -> [(name: String, id: UUID, members: [String])] {
        loadIfNeeded()
        let live = hooks.peers()
        return rooms.filter { $0.members.contains(me.profileID) }.map { room in
            let members = live
                .filter { room.members.contains($0.profileID) && $0.participant != me }
                .map(\.label)
            let remotes = room.remoteMembers.map(\.label)
            return (room.name, room.id, members + remotes)
        }
    }

    // MARK: - Posting

    /// Post a message from `me`. Resolves the target room (explicit `roomName`,
    /// or the room shared with the addressed peer `toLabel`), enforces the ACL,
    /// rate/loop guards, PI-scans, records to the transcript, audits, and pushes
    /// to every live recipient (offline members pull it later).
    public func post(from me: Participant, meLabel: String,
                     roomName: String?, toLabel: String?, text: String) async -> PostResult {
        loadIfNeeded()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return PostResult(ok: false, summary: "Message is empty.", messageID: nil) }
        guard body.count <= 8000 else {
            return PostResult(ok: false, summary: "Message too long (limit 8000 chars).", messageID: nil)
        }

        // Resolve target room, enforcing default-deny membership.
        let myRooms = rooms.filter { $0.members.contains(me.profileID) }
        guard !myRooms.isEmpty else {
            return PostResult(ok: false, summary: "This workspace isn't in any room. Ask the user to add it to a room in the Rooms window.", messageID: nil)
        }
        let room: Room
        if let roomName {
            guard let r = myRooms.first(where: { $0.name.caseInsensitiveCompare(roomName) == .orderedSame }) else {
                return PostResult(ok: false, summary: "No room named “\(roomName)” that you belong to. Your rooms: \(myRooms.map(\.name).joined(separator: ", ")).", messageID: nil)
            }
            room = r
        } else if let toLabel {
            guard let peer = peers(for: me).first(where: { $0.peer.label.caseInsensitiveCompare(toLabel) == .orderedSame }),
                  let r = myRooms.first(where: { $0.name == peer.rooms.first }) else {
                return PostResult(ok: false, summary: "No peer “\(toLabel)” you share a room with. Call list_peers to see who you can reach.", messageID: nil)
            }
            room = r
        } else if myRooms.count == 1 {
            room = myRooms[0]   // unambiguous
        } else {
            return PostResult(ok: false, summary: "You're in several rooms (\(myRooms.map(\.name).joined(separator: ", "))) — pass `room` or `to`.", messageID: nil)
        }

        // Rate guard — a spamming agent is stopped, not silently dropped.
        if roomRateExceeded(room.id) {
            return PostResult(ok: false, summary: "Rate limit: too many messages in “\(room.name)” this minute. Wait before sending again.", messageID: nil)
        }
        recordRoomPost(room.id)

        // Prompt-injection scan — an agent is untrusted input to another agent.
        let scan = await hooks.scan(body)
        let verdict = scan.blocked ? "blocked" : (scan.detector != nil ? "flagged:\(scan.detector!)" : "clean")
        let mentionText = toLabel.map { "@\($0) " } ?? ""
        var msg = Message(roomID: room.id, fromProfileID: me.profileID,
                          fromBranch: me.branch, fromLabel: meLabel,
                          text: mentionText + body, ts: Date(), verdict: verdict)

        // Record + audit even when blocked (admins want to see the attempt).
        append(msg, to: room.id)

        if scan.blocked {
            hooks.audit(msg, [])   // no recipients — nothing was delivered
            return PostResult(ok: false,
                summary: "Message blocked by Bromure's prompt-injection policy (\(scan.detector ?? "detector")) and NOT delivered.",
                messageID: msg.id)
        }

        // Deliver to live local recipients (push), queue for offline (pull),
        // relay to remote members.
        let live = hooks.peers()
        let recipients = live.filter {
            room.members.contains($0.profileID) && $0.participant != me && $0.live
        }
        var delivered: [String] = []
        var queued: [String] = []
        for r in recipients {
            let tab = r.participant
            if pushBudgetExceeded(tab) {
                queued.append(r.label); continue    // still in transcript → pull
            }
            recordPush(tab)
            let header = "[bromure • \(msg.fromLabel) in room “\(room.name)”]"
            let ok = await hooks.deliverPush(r.profileID, r.branch, "\(header)\n\(body)")
            if ok { delivered.append(r.label) } else { queued.append(r.label) }
        }
        // Offline local members that aren't live at all.
        let liveProfiles = Set(recipients.map(\.profileID))
        for pid in room.members where pid != me.profileID && !liveProfiles.contains(pid) {
            queued.append(profileName(pid))
        }
        // Remote members.
        for remote in room.remoteMembers {
            if await hooks.deliverRemote(remote.host, msg) { delivered.append(remote.label) }
            else { queued.append(remote.label) }
        }

        hooks.audit(msg, delivered)

        var parts: [String] = []
        if !delivered.isEmpty { parts.append("delivered to \(delivered.joined(separator: ", "))") }
        if !queued.isEmpty { parts.append("queued for \(queued.joined(separator: ", ")) (they'll read it when active)") }
        let summary = parts.isEmpty
            ? "Posted to “\(room.name)”. No other members are online yet."
            : "Posted to “\(room.name)” — " + parts.joined(separator: "; ") + "."
        return PostResult(ok: true, summary: summary, messageID: msg.id)
    }

    /// A message the user typed into a room from the Rooms window — the human
    /// is just another participant.
    public func postHuman(roomID: UUID, text: String) async {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let msg = Message(roomID: room.id, fromProfileID: UUID(), fromBranch: "",
                          fromLabel: "you", text: body, verdict: "clean")
        append(msg, to: room.id)
        let live = hooks.peers().filter { room.members.contains($0.profileID) && $0.live }
        for r in live where !pushBudgetExceeded(r.participant) {
            recordPush(r.participant)
            _ = await hooks.deliverPush(r.profileID, r.branch,
                "[bromure • you in room “\(room.name)”]\n\(body)")
        }
        hooks.audit(msg, live.map(\.label))
    }

    // MARK: - Inbox / wait (pull)

    /// New messages for `me` since its last read (across all its rooms),
    /// excluding its own. Marks read.
    public func inbox(for me: Participant, markRead: Bool = true) -> [Message] {
        loadIfNeeded()
        let since = lastReadByParticipant[me] ?? .distantPast
        let myRoomIDs = Set(rooms.filter { $0.members.contains(me.profileID) }.map(\.id))
        let msgs = myRoomIDs
            .flatMap { messagesByRoom[$0] ?? [] }
            .filter { $0.ts > since && $0.fromProfileID != me.profileID && $0.verdict != "blocked" }
            .sorted { $0.ts < $1.ts }
        if markRead { lastReadByParticipant[me] = Date() }
        return msgs
    }

    /// Block until a new message arrives for `me` or `timeout` elapses.
    public func waitForReply(for me: Participant, timeout: TimeInterval) async -> [Message] {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 600))
        while Date() < deadline {
            let msgs = inbox(for: me, markRead: true)
            if !msgs.isEmpty { return msgs }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return []
    }

    // MARK: - Internals

    private func append(_ msg: Message, to roomID: UUID) {
        var arr = messagesByRoom[roomID] ?? []
        arr.append(msg)
        if arr.count > Self.transcriptCap { arr.removeFirst(arr.count - Self.transcriptCap) }
        messagesByRoom[roomID] = arr
        revision &+= 1
    }

    private func profileName(_ id: UUID) -> String {
        hooks.peers().first { $0.profileID == id }?.profileName ?? id.uuidString.prefix(8).description
    }

    private func roomRateExceeded(_ roomID: UUID) -> Bool {
        prune(&postTimesByRoom[roomID])
        return (postTimesByRoom[roomID]?.count ?? 0) >= Self.maxRoomPostsPerMinute
    }
    private func recordRoomPost(_ roomID: UUID) {
        postTimesByRoom[roomID, default: []].append(Date())
    }
    private func pushBudgetExceeded(_ tab: Participant) -> Bool {
        prune(&pushTimesByTab[tab])
        return (pushTimesByTab[tab]?.count ?? 0) >= Self.maxPushesPerTabPerMinute
    }
    private func recordPush(_ tab: Participant) {
        pushTimesByTab[tab, default: []].append(Date())
    }
    private func prune(_ times: inout [Date]?) {
        guard times != nil else { return }
        let cutoff = Date().addingTimeInterval(-60)
        times?.removeAll { $0 < cutoff }
    }
}
