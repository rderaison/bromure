import Foundation
import Testing
@testable import bromure_ac

/// A running task's card reads its agent the way the sidebar reads the
/// session (one source), and a start being checked keeps its column.
@Suite("Task live state")
@MainActor
struct TaskLiveStateTests {
    private func tempStore() -> AgentSessionStore {
        AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
    }

    private func running(_ ws: UUID, slug: String) -> CodingTask {
        var t = CodingTask(title: "Fix it", profileID: ws, tool: .claude)
        t.stage = .inProgress
        t.branchSlug = slug
        t.startedAt = Date()
        return t
    }

    private func model(_ ws: UUID, tabs: [TabsModel.Tab]) -> SessionListModel {
        let tm = TabsModel()
        tm.tabs = tabs
        tm.rosterLive = true
        let m = SessionListModel()
        m.entries = [SessionListModel.VMEntry(id: ws, name: "ws", accentHex: "#000000", model: tm)]
        m.profileRows = [SessionListModel.ProfileRow(id: ws, name: "ws", accentHex: "#000000",
                                                     state: .running, compromised: false)]
        return m
    }

    @Test("with no session record, the tab's own status maps onto the sidebar's buckets")
    func tabFallback() {
        let ws = UUID()
        let task = running(ws, slug: "fix-it-261004-1200")
        let tab = TabsModel.Tab(label: "claude", index: 1, worktreeBranch: "wt/fix-it-261004-1200")
        let m = model(ws, tabs: [tab])
        tab.agentStatus = .done
        #expect(TaskLiveState.bucket(of: task, in: m, sessions: nil) == .idle)
        tab.agentStatus = .working
        #expect(TaskLiveState.bucket(of: task, in: m, sessions: nil) == .working)
        tab.agentStatus = .needsInput
        #expect(TaskLiveState.bucket(of: task, in: m, sessions: nil) == .needsYou)
        // A uniquified branch ("-2") is still the task's.
        tab.worktreeBranch = "wt/fix-it-261004-1200-2"
        #expect(TaskLiveState.bucket(of: task, in: m, sessions: nil) == .needsYou)
        // No tab yet: unknown (the card says Starting, then Session gone).
        #expect(TaskLiveState.bucket(of: task, in: model(ws, tabs: []), sessions: nil) == nil)
    }

    @Test("with a session record, the card's state IS the sidebar row's bucket")
    func sessionIsTheSource() {
        let ws = UUID()
        let task = running(ws, slug: "fix-it-261004-1200")
        let tab = TabsModel.Tab(label: "claude", index: 1, worktreeBranch: "wt/fix-it-261004-1200")
        let m = model(ws, tabs: [tab])
        let store = tempStore()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Fix it", cwd: "~/repo", windowIndex: 1)
        s.worktreeBranch = "wt/fix-it-261004-1200"
        store.upsert(s)
        for status in [AgentStatus.done, .working, .needsInput] {
            tab.agentStatus = status
            let sidebar = SessionHome.bucket(for: store.session(s.id)!, in: m)
            #expect(TaskLiveState.bucket(of: task, in: m, sessions: store) == sidebar)
        }
    }

    @Test("a start being checked holds the task in its column, bounded in time")
    func isStarting() {
        var t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        #expect(!t.isStarting)
        t.startingAt = Date()
        #expect(t.isStarting)
        t.stage = .planning
        #expect(t.isStarting)
        // Moved on (the checks passed): no longer "starting".
        t.stage = .inProgress
        #expect(!t.isStarting)
        // A crash mid-check can't pin the spinner forever.
        t.stage = .backlog
        t.startingAt = Date().addingTimeInterval(-3600)
        #expect(!t.isStarting)
    }

    @Test("startingAt survives the JSON round trip (the API and the fat client read it)")
    func codable() throws {
        var t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        t.startingAt = Date(timeIntervalSince1970: 1_700_000_000)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(CodingTask.self, from: enc.encode(t))
        #expect(back.startingAt == t.startingAt)
        #expect(back.isStarting == false)   // long past: bounded
    }
}
