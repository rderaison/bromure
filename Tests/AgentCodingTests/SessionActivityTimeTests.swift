import Foundation
import Testing
@testable import bromure_ac

/// Board: "Every session that is live has a timestamp set to Now, even if
/// it's idle." The card counted from `lastSeenAt`, which every roster pass
/// stamps while the tab is up — liveness, not activity.
@Suite("Session card time")
@MainActor
struct SessionActivityTimeTests {
    private func tempStore() -> AgentSessionStore {
        AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
    }
    private func entry(_ id: UUID, tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
        let m = TabsModel()
        m.tabs = tabs
        m.rosterLive = true
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: m)
    }

    @Test("an idle live session keeps the time of its last reply, whatever the roster passes")
    func idleKeepsItsTime() throws {
        let store = tempStore()
        let ws = UUID()
        let t0 = Date()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~",
                             createdAt: t0.addingTimeInterval(-7200), windowIndex: 2)
        s.launchDisplay = "Lux"
        store.upsert(s)
        store.noteReply(s.id)
        let replied = try #require(store.session(s.id)?.activeAt)
        // An hour of roster passes over the idle tab.
        let later = replied.addingTimeInterval(3600)
        store.reconcile(entries: [entry(ws, tabs: [TabsModel.Tab(label: "Lux", index: 2, cwd: "/home/ubuntu")])], now: later)
        let after = try #require(store.session(s.id))
        #expect(after.lastSeenAt == later)                   // seen: yes
        #expect(SessionHome.lastActivity(after) == replied)  // active: no
        #expect(SessionHome.elapsedCompact(since: SessionHome.lastActivity(after), now: later) == "1h")
        #expect(SessionHome.rowWhen(after, in: SessionListModel(), now: later) == "1h")
    }

    @Test("the latest of reply, end, resume and start counts")
    func latest() {
        let t = Date()
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", createdAt: t.addingTimeInterval(-500))
        #expect(SessionHome.lastActivity(s) == s.createdAt)
        s.lastSeenAt = t                                      // never counts
        #expect(SessionHome.lastActivity(s) == s.createdAt)
        s.activeAt = t.addingTimeInterval(-300)
        s.resumedAt = t.addingTimeInterval(-200)
        #expect(SessionHome.lastActivity(s) == s.resumedAt)
        s.endedAt = t.addingTimeInterval(-100)
        #expect(SessionHome.lastActivity(s) == s.endedAt)
    }

    @Test("\"now\" only while the agent works; the stage's idle line and iOS read the same")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let a = try src("Sources/AgentCoding/AgentSessions.swift")
        #expect(a.contains("bucket(for: s, in: model) == .working ? now : lastActivity(s)"))
        #expect(a.contains("when: SessionHome.rowWhen(s, in: model),"))
        for p in ["Sources/AgentCoding/SessionStageViews.swift", "ios/BromureRemote/Sources/BromureRemote/SessionScreens.swift"] {
            let v = try src(p)
            #expect(v.contains("case .idle:    detail = SessionHome.elapsed(since: SessionHome.lastActivity(s))"), "\(p)")
            #expect(!v.contains("elapsed(since: s.lastSeenAt)"), "\(p)")
        }
        #expect(try src("ios/BromureRemote/Sources/BromureRemote/SessionScreens.swift").contains("SessionHome.rowWhen(s, in: model)"))
    }
}
