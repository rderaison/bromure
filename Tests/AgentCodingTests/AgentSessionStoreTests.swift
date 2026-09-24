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

    private func roster(_ id: UUID, _ tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
        let model = TabsModel()
        model.tabs = tabs
        model.rosterLive = true
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: model)
    }

    private func launching(_ ws: UUID, _ title: String, cwd: String, baseline: Int) -> AgentSession {
        var s = AgentSession(profileID: ws, tool: .claude, title: title, cwd: cwd)
        s.launchingSince = Date()
        s.launchBaselineIndex = baseline
        s.launchDisplay = title
        return s
    }

    @Test("two launches racing on one machine each bind their own tab",
          arguments: [false, true])
    func racingLaunchesDontSwapTabs(peerFirst: Bool) {
        let store = tempStore()
        let ws = UUID()
        // A notice resumes a sleeping peer while the user starts a new
        // session: both wait past the same baseline, and the new session's
        // tab is the one that shows up first. Whichever the store walks
        // first, neither may take the other's tab.
        let peer = launching(ws, "Wago", cwd: "~/wago", baseline: 0)
        let fresh = launching(ws, "hello", cwd: "~/hello-260924-1003", baseline: 0)
        for s in peerFirst ? [fresh, peer] : [peer, fresh] { store.upsert(s) }
        let shell = TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu")
        let helloTab = TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/hello-260924-1003",
                                     display: "hello")
        store.reconcile(entries: [roster(ws, [shell, helloTab])])
        #expect(store.session(peer.id)?.windowIndex == nil)
        #expect(store.session(fresh.id)?.windowIndex == 1)
        let wagoTab = TabsModel.Tab(label: "claude", index: 2, cwd: "/home/ubuntu/wago", display: "Wago")
        store.reconcile(entries: [roster(ws, [shell, helloTab, wagoTab])])
        #expect(store.session(peer.id)?.windowIndex == 2)
        #expect(store.session(fresh.id)?.windowIndex == 1)
        #expect(store.sessions.count == 2)
    }

    @Test("a tab not named yet waits while another launch is pending, and isn't adopted")
    func unnamedTabWaitsForItsLaunch() {
        let store = tempStore()
        let ws = UUID()
        let a = launching(ws, "Wago", cwd: "~/wago", baseline: 0)
        let b = launching(ws, "hello", cwd: "~/hello", baseline: 0)
        store.upsert(a)
        store.upsert(b)
        let shell = TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu")
        // Caught between new-window and set-option: no @display yet.
        let early = TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/hello")
        store.reconcile(entries: [roster(ws, [shell, early])])
        #expect(store.sessions.count == 2)
        #expect(store.sessions.allSatisfy { $0.windowIndex == nil })
        // Named on the next tick: it goes to its own launch.
        let named = TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/hello", display: "hello")
        store.reconcile(entries: [roster(ws, [shell, named])])
        #expect(store.session(b.id)?.windowIndex == 1)
        #expect(store.session(a.id)?.windowIndex == nil)

        // A lone launch still takes an unnamed agent tab (a guest that
        // never names it).
        let solo = tempStore()
        let s = launching(ws, "Lux", cwd: "~/lux", baseline: 0)
        solo.upsert(s)
        solo.reconcile(entries: [roster(ws, [shell, early])])
        #expect(solo.session(s.id)?.windowIndex == 1)
    }

    @Test("a binding from an earlier guest boot is dropped, not trusted")
    func staleBootUnbinds() {
        let store = tempStore()
        let ws = UUID()
        var s = AgentSession(profileID: ws, tool: .claude, title: "Wago", cwd: "~/wago", windowIndex: 2)
        s.launchDisplay = "Wago"
        store.upsert(s)
        // First probe: the binding takes this boot.
        #expect(store.checkBoot(s.id, bootID: "boot-a"))
        #expect(store.session(s.id)?.bootID == "boot-a")
        #expect(store.checkBoot(s.id, bootID: "boot-a"))
        #expect(store.session(s.id)?.windowIndex == 2)
        // The machine booted fresh: index 2 is whatever opened since.
        #expect(!store.checkBoot(s.id, bootID: "boot-b"))
        #expect(store.session(s.id)?.windowIndex == nil)
        #expect(store.session(s.id)?.endedAt != nil)
        // Rebound (a resume's tab): the stamp starts over.
        store.reconcile(entries: [roster(ws, [
            TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"),
            TabsModel.Tab(label: "claude", index: 3, cwd: "/home/ubuntu/wago", display: "Wago")])])
        #expect(store.session(s.id)?.windowIndex == 3)
        #expect(store.session(s.id)?.bootID == nil)
    }

    @Test("the liveness probe's boot line parses and doesn't read as a window")
    func probeBootLine() {
        let out = "boot\t6f1c2d3e-aaaa-bbbb-cccc-0123456789ab\n2\tclaude\t\tWago\n"
        #expect(AgentSessionEngine.parseBootID(out) == "6f1c2d3e-aaaa-bbbb-cccc-0123456789ab")
        #expect(AgentSessionEngine.parseProbe(out).map(\.index) == [2])
        #expect(AgentSessionEngine.parseBootID("boot\t\n2\tclaude\t\t\n") == nil)
        #expect(AgentSessionEngine.parseBootID("2\tclaude\t\t\n") == nil)
    }

    @Test("the liveness probe is valid shell, all windows or one")
    func probeCommandParses() throws {
        for window in ["", "3"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-n", "-c", AgentSessionEngine.probeCommand(window: window)]
            let err = Pipe(); proc.standardError = err
            try proc.run()
            let diag = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0, "bash -n: \(diag)")
        }
    }
}
