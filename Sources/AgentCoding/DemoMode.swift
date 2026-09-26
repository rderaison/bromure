import AppKit
import Foundation
import SwiftUI

// MARK: - Demo mode (documentation screenshots)
//
// The manual's screenshots show the real window populated from a fixture,
// with no VM and no agent: `POST /debug/editor {"action":"seed-demo",
// "spec":"<path>"}` (debug builds of the routes only) writes workspaces,
// sessions, rooms and their transcripts from a JSON spec, and turns demo
// mode on for the life of the process. In demo mode a fixture session
// takes the state the spec gives it (needs you / working / ready) instead
// of reading it off a VM, and a live one's chat is the real chat view fed
// from its fixture transcript. Nothing here runs unless seed-demo was
// called — and only in an app launched with the debug routes enabled.

@MainActor
enum DemoMode {
    /// On once seed-demo ran.
    private(set) static var isOn = false
    /// Fixture sessions' states (asleep / ended ones fall out of the store's
    /// own fields; these are the live ones).
    private(set) static var buckets: [UUID: SessionBucket] = [:]
    /// Fixture workspaces shown as running.
    private(set) static var runningProfiles: Set<UUID> = []

    static func bucket(for id: UUID) -> SessionBucket? { isOn ? buckets[id] : nil }
    static func isRunning(_ profileID: UUID) -> Bool { isOn && runningProfiles.contains(profileID) }
    /// A fixture session whose chat is live (the real chat view).
    static func isLive(_ id: UUID) -> Bool {
        guard let b = bucket(for: id) else { return false }
        return b == .needsYou || b == .working || b == .idle
    }

    /// A started chat model for a live fixture session, fed from its cached
    /// transcript. Fresh each call (a room stops the ones it lets go).
    static func chatModel(for s: AgentSession, delegate: ACAppDelegate) -> BeautifiedSessionModel {
        let accent = Color(hex: delegate.profile(for: s.profileID)?.color.hexInUI ?? "#3B82F6")
        let data = delegate.agentSessionEngine.transcripts.load(s.id) ?? Data()
        let provider = FixtureTranscriptProvider(accent: accent, transcript: data,
                                                 working: bucket(for: s.id) == .working)
        let m = BeautifiedSessionModel(provider: provider)
        let sid = s.id
        m.delegationStore = delegate.delegationStore
        m.sessionStore = delegate.agentSessionStore
        m.currentSession = { [weak delegate] in delegate?.agentSessionStore.session(sid) }
        m.openSession = { [weak delegate] id in delegate?.ensureUnifiedWindow().selectSession(id) }
        m.workspaceName = { [weak delegate] pid in delegate?.profile(for: pid)?.name ?? "" }
        m.peerMentions = { [weak delegate] in
            delegate?.peerMentions(forWorkspace: s.profileID, excluding: sid) ?? []
        }
        m.loadSlashCommands(agent: s.tool.rawValue, cwd: s.cwd)
        m.start()
        return m
    }

    // MARK: Seed

    struct Spec: Decodable {
        struct Workspace: Decodable {
            var name: String
            var color: String?
            var tool: String?
            var running: Bool?
        }
        struct Room: Decodable {
            var name: String
            var layout: String?
        }
        struct Branch: Decodable {
            var name: String
            var parent: String?
            var root: String?
            var ahead: Int?
            var behind: Int?
            var changed: Int?
        }
        struct Session: Decodable {
            var title: String
            var workspace: String
            var tool: String?
            var cwd: String?
            /// needsYou | working | idle | asleep | ended | archived
            var state: String?
            var nickname: String?
            var room: String?
            var role: String?
            var opening: String?
            /// Transcript file (Claude JSONL), relative to the spec.
            var transcript: String?
            /// How long ago it started / last moved, in minutes.
            var ageMinutes: Double?
            var idleMinutes: Double?
            var branch: Branch?
            var worktreeOf: String?
        }
        var workspaces: [Workspace]
        var rooms: [Room]?
        var sessions: [Session]
    }

    /// Write the spec's fixture into the stores; returns title → id.
    static func seed(specPath: String, delegate d: ACAppDelegate) throws -> [String: String] {
        let url = URL(fileURLWithPath: (specPath as NSString).expandingTildeInPath)
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()

        var profileIDs: [String: UUID] = [:]
        for w in spec.workspaces {
            let id: UUID
            if let existing = d.profiles.first(where: { $0.name == w.name }) {
                id = existing.id
            } else {
                let p = Profile(name: w.name,
                                tool: w.tool.flatMap(Profile.Tool.init(rawValue:)) ?? .claude,
                                authMode: .token,
                                color: w.color.flatMap(ProfileColor.init(rawValue:)) ?? .blue)
                try d.store.save(p)
                id = p.id
            }
            profileIDs[w.name] = id
            if w.running == true { runningProfiles.insert(id) }
        }
        d.profiles = d.store.loadAll()

        var roomIDs: [String: UUID] = [:]
        for r in spec.rooms ?? [] {
            let room = d.agentRoomStore.rooms.first(where: { $0.name == r.name })
                ?? d.agentRoomStore.create(name: r.name)
            if let layout = r.layout { d.agentRoomStore.setLayout(room.id, layout) }
            roomIDs[r.name] = room.id
        }

        var ids: [String: String] = [:]
        var byTitle: [String: UUID] = [:]
        let now = Date()
        for (i, e) in spec.sessions.enumerated() {
            guard let pid = profileIDs[e.workspace] else { continue }
            let tool = e.tool.flatMap(Profile.Tool.init(rawValue:)) ?? .claude
            let started = now.addingTimeInterval(-60 * (e.ageMinutes ?? Double(30 + i * 7)))
            var s = AgentSession(profileID: pid, tool: tool, title: e.title,
                                 cwd: e.cwd ?? "~", openingMessage: e.opening,
                                 createdAt: started, windowIndex: i + 1)
            s.userTitled = true
            s.nickname = e.nickname
            s.role = e.role
            s.roomID = e.room.flatMap { roomIDs[$0] }
            s.lastSeenAt = now.addingTimeInterval(-60 * (e.idleMinutes ?? 1))
            s.agentSeenAt = s.lastSeenAt
            if let b = e.branch {
                s.worktreeBranch = b.name
                s.branchParent = b.parent ?? "main"
                s.branchRoot = b.root ?? s.cwd
                s.branchInfo = BranchInfo(ahead: b.ahead ?? 0, behind: b.behind ?? 0,
                                          changed: b.changed ?? 0, checkedAt: now)
            }
            if let parent = e.worktreeOf { s.worktreeOf = byTitle[parent] }
            let state = e.state ?? "idle"
            switch state {
            case "needsYou": buckets[s.id] = .needsYou
            case "working":  buckets[s.id] = .working
            case "idle":     buckets[s.id] = .idle
            case "ended":    s.endedAt = s.lastSeenAt; s.windowIndex = nil
            case "archived": s.endedAt = s.lastSeenAt; s.windowIndex = nil; s.archivedAt = s.lastSeenAt
            default:         s.windowIndex = nil   // asleep: its machine is off
            }
            d.agentSessionStore.upsert(s)
            if let t = e.transcript {
                let data = try Data(contentsOf: dir.appendingPathComponent(t))
                d.agentSessionEngine.transcripts.save(s.id, data)
            }
            byTitle[e.title] = s.id
            ids[e.title] = s.id.uuidString
        }
        isOn = true
        _ = d.ensureUnifiedWindow()   // the sidebar's machine rows are built on the window's model
        d.refreshSidebar()
        return ids
    }
}

/// Feeds the real chat view a fixture transcript: answers the two guest
/// commands a chat poll runs (the tab's folder, then the transcript chunk)
/// as a guest would, from memory.
@MainActor
final class FixtureTranscriptProvider: BeautifiedTranscriptProvider {
    let accent: Color
    private let transcript: Data
    private let working: Bool
    private var served = false
    private static let path = "/home/ubuntu/.claude/projects/-home-ubuntu-demo/demo.jsonl"

    init(accent: Color, transcript: Data, working: Bool) {
        self.accent = accent
        self.transcript = transcript
        self.working = working
    }

    func activeTabIndex() -> Int? { 1 }
    func isWorking() -> Bool { working }
    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }

    func execGuest(_ command: String, timeout: Int) async -> String? {
        if command.contains("pane_current_path") { return "/home/ubuntu/demo\n0\n" }
        // The transcript chunk (CodingTaskEngine.transcriptChunkCommand).
        guard command.hasPrefix("f=\"\";"), !transcript.isEmpty else { return nil }
        let size = transcript.count
        // Once: the whole file; after that, "nothing new" from its end.
        if served { return "\(Self.path)\n\n\(size)\n\(size)\n\(size)\n" }
        served = true
        return "\(Self.path)\n\n\(size)\n0\n\(size)\n" + String(decoding: transcript, as: UTF8.self)
    }
}

/// A room over the fixture: live fixture members (and the Switchboard) get
/// fixture chats; the rest behave as on this Mac.
@MainActor
final class DemoRoomBackend: RoomStageBackend {
    private weak var delegate: ACAppDelegate?
    private let local: LocalRoomBackend
    init(_ delegate: ACAppDelegate) {
        self.delegate = delegate
        self.local = LocalRoomBackend(delegate)
    }

    var roomStore: AgentRoomStore { local.roomStore }
    var roomSessions: [AgentSession] { local.roomSessions }

    func chatKey(for s: AgentSession) -> String? {
        DemoMode.isLive(s.id) ? "demo#\(s.id.uuidString)" : local.chatKey(for: s)
    }

    func makeChat(for s: AgentSession) -> BeautifiedSessionModel? {
        guard DemoMode.isLive(s.id), let d = delegate else { return local.makeChat(for: s) }
        let m = DemoMode.chatModel(for: s, delegate: d)
        m.stop()   // the room starts it
        return m
    }

    func startSwitchboard(_ room: AgentRoom) { local.startSwitchboard(room) }
    func setLayout(_ room: UUID, _ layout: String) { local.setLayout(room, layout) }
    func wake(_ s: AgentSession, with text: String) {}
    func restingTranscript(for s: AgentSession, ended: Bool) async -> Data? {
        delegate?.agentSessionEngine.transcripts.load(s.id)
    }
    func peerMentions(for s: AgentSession) -> [PeerMention] { local.peerMentions(for: s) }
    func assignNickname(_ id: UUID, _ nick: String) { local.assignNickname(id, nick) }
}
