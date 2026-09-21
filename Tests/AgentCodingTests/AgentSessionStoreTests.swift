import Foundation
import Testing
@testable import bromure_ac

// The session store against the tab rosters it reconciles with. The shapes
// here are the ones that bit: a resume paints its tab bar from the suspend
// snapshot (labels only, every pill at index 0) before tmux has reported,
// and the store once adopted every one of those pills as a session at
// window 0 — six "Lux sensor" rows for one conversation.

@Suite("Agent session store")
@MainActor
struct AgentSessionStoreTests {
    private func tempStore() -> AgentSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json")
        return AgentSessionStore(fileURL: url)
    }

    private func entry(_ id: UUID, tabs: [(index: Int, label: String, cwd: String?)],
                       live: Bool) -> SessionListModel.VMEntry {
        let model = TabsModel()
        model.tabs = tabs.map { TabsModel.Tab(label: $0.label, index: $0.index, cwd: $0.cwd) }
        model.rosterLive = live
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: model)
    }

    @Test("a rehydrated roster (labels only, all at index 0) adopts nothing")
    func rehydratedRosterIsIgnored() {
        let store = tempStore()
        let ws = UUID()
        // What rehydrateTabs produces: six saved pills, every index 0.
        let pills = (0..<6).map { _ in (index: 0, label: "Lux sensor low-end accuracy (claude)", cwd: String?.none) }
        store.reconcile(entries: [entry(ws, tabs: pills, live: false)])
        #expect(store.sessions.isEmpty)
        // The guest's own roster lands: one session per agent window.
        let real = [(index: 0, label: "Lux sensor low-end accuracy (claude)", cwd: String?("/home/ubuntu")),
                    (index: 1, label: "Heating model (claude)", cwd: "/home/ubuntu/heat")]
        store.reconcile(entries: [entry(ws, tabs: real, live: true)])
        #expect(store.sessions.count == 2)
        #expect(Set(store.sessions.compactMap(\.windowIndex)) == [0, 1])
    }

    @Test("a non-live roster neither ends nor re-adopts a bound session")
    func nonLiveRosterLeavesBindingsAlone() {
        let store = tempStore()
        let ws = UUID()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Heating model",
                             cwd: "/home/ubuntu/heat", windowIndex: 3)
        s.launchDisplay = "Heating model"
        store.upsert(s)
        // A boot placeholder: one "shell" pill at 0. Window 3 isn't in it —
        // and must not count as missing.
        store.reconcile(entries: [entry(ws, tabs: [(0, "shell", nil)], live: false)],
                        now: Date().addingTimeInterval(60))
        #expect(store.session(s.id)?.windowIndex == 3)
        #expect(store.session(s.id)?.endedAt == nil)
    }

    @Test("twins on one window collapse to the richest, oldest one")
    func twinsCollapse() {
        let ws = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        func adoptee(_ dt: TimeInterval) -> AgentSession {
            AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~",
                         createdAt: t0.addingTimeInterval(dt), windowIndex: 0)
        }
        var launched = AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~/lux",
                                    openingMessage: "Look at the lux sensor",
                                    createdAt: t0.addingTimeInterval(30), windowIndex: 0)
        launched.launchDisplay = "Lux"
        let a = adoptee(0), b = adoptee(1), c = adoptee(2)
        let other = AgentSession(profileID: ws, tool: .omp, title: "Other", cwd: "~", windowIndex: 1)
        let (drop, unbind) = AgentSessionStore.twins(in: [a, b, launched, c, other])
        // The launch wins over every adoptee, even younger; adoptees are dropped.
        #expect(drop == [a.id, b.id, c.id])
        #expect(unbind.isEmpty)

        // Two launches on one window: the older stays bound, the other is
        // unbound (kept — it carries the user's words).
        var second = launched
        second.id = UUID()
        second.createdAt = t0.addingTimeInterval(40)
        let (drop2, unbind2) = AgentSessionStore.twins(in: [second, launched])
        #expect(drop2.isEmpty)
        #expect(unbind2 == [second.id])
    }

    @Test("twins already on disk are collapsed on load")
    func twinsCollapseOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json")
        let ws = UUID()
        let twins = (0..<6).map { i in
            AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~",
                         createdAt: Date(timeIntervalSince1970: 1_000 + Double(i)), windowIndex: 0)
        }
        struct Payload: Codable { var sessions: [AgentSession] }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(Payload(sessions: twins)).write(to: url)
        let store = AgentSessionStore(fileURL: url)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == twins[0].id)
    }

    @Test("a mirror drops the server's twins")
    func mirrorDropsTwins() {
        let store = AgentSessionStore(mirror: true)
        let ws = UUID()
        let twins = (0..<3).map { i in
            AgentSession(profileID: ws, tool: .omp, title: "Troubleshoot", cwd: "~",
                         createdAt: Date(timeIntervalSince1970: 1_000 + Double(i)), windowIndex: 0)
        }
        let other = AgentSession(profileID: ws, tool: .omp, title: "Deploy", cwd: "~/vis", windowIndex: 1)
        store.applyMirror(twins + [other])
        #expect(store.sessions.count == 2)
        #expect(store.sessions.contains { $0.id == twins[0].id })
        #expect(store.sessions.contains { $0.id == other.id })
    }

    @Test("an adopted tab takes the agent's title without its glyphs")
    func adoptionCleansTitle() {
        let store = tempStore()
        let ws = UUID()
        store.reconcile(entries: [entry(ws, tabs: [(4, "π > tmp (omp)", "/tmp")], live: true)])
        // "tmp" is the folder's own name, not a title: the plain default.
        #expect(store.sessions.first?.title == AgentSession.defaultTitle(tool: .omp, cwd: "/tmp"))
        store.reconcile(entries: [entry(ws, tabs: [(4, "π > Deploy the panel (omp)", "/tmp")], live: true)])
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.title == "Deploy the panel")
    }

    @Test("a deleted session hides at once and is purged once its tab is gone")
    func deleteWaitsForTheTab() {
        let store = tempStore()
        let ws = UUID()
        let model = SessionListModel()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~/lux", windowIndex: 2)
        s.launchDisplay = "Lux"
        store.upsert(s)
        store.setDeleted(s.id)
        // Hidden from every list, still in the store while the tab is listed.
        #expect(SessionHome.orderedAll(store.sessions, in: model).isEmpty)
        #expect(SessionHome.archived(store.sessions).isEmpty)
        #expect(store.session(s.id)?.isDeleted == true)
        let t0 = Date()
        store.reconcile(entries: [entry(ws, tabs: [(2, "claude", "/home/ubuntu/lux")], live: true)], now: t0)
        #expect(store.session(s.id) != nil)
        // The tab is killed and drops out of the roster: the record goes with
        // it (after the missing grace), and nothing is adopted in its place.
        store.reconcile(entries: [entry(ws, tabs: [(0, "bash", "/home/ubuntu")], live: true)], now: t0)
        store.reconcile(entries: [entry(ws, tabs: [(0, "bash", "/home/ubuntu")], live: true)],
                        now: t0.addingTimeInterval(AgentSessionStore.missingGrace + 1))
        #expect(store.session(s.id) == nil)
        #expect(store.sessions.isEmpty)
    }

    @Test("archived sessions leave the list and come back on resume")
    func archiveFlag() {
        let store = tempStore()
        let ws = UUID()
        let model = SessionListModel()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~/lux")
        s.endedAt = Date()
        store.upsert(s)
        #expect(SessionHome.orderedAll(store.sessions, in: model).count == 1)
        store.setArchived(s.id, true)
        #expect(store.session(s.id)?.isArchived == true)
        #expect(SessionHome.orderedAll(store.sessions, in: model).isEmpty)
        #expect(SessionHome.archived(store.sessions).map(\.id) == [s.id])
        #expect(SessionHome.initialSession(in: store, model: model, remembered: s.id) == nil)
        #expect(SessionHome.statusLine(for: store.session(s.id)!, in: model) == "Archived")
        store.setArchived(s.id, false)
        #expect(SessionHome.orderedAll(store.sessions, in: model).count == 1)
    }
}
