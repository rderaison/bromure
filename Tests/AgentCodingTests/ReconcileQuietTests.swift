import Foundation
import Observation
import Testing
@testable import bromure_ac

/// A sample of a busy server: its main thread at 95%, most of it laying out
/// the sidebar again and again. Every reconcile pass (the state feed runs one
/// up to 2.5 times a second) stamped each live session's `lastSeenAt`, so the
/// store always changed: the sidebar re-rendered, sessions.json was rewritten.
/// A pass over a roster that didn't change now changes nothing.
@Suite("A reconcile pass over an unchanged roster changes nothing")
@MainActor
struct ReconcileQuietTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString).json")
    }
    private func entry(_ id: UUID, tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
        let m = TabsModel()
        m.tabs = tabs
        m.rosterLive = true
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: m)
    }
    private final class Flag: @unchecked Sendable { var fired = false }

    private func liveStore(_ url: URL, ws: UUID, t0: Date) -> (AgentSessionStore, AgentSession) {
        let store = AgentSessionStore(fileURL: url)
        var s = AgentSession(profileID: ws, tool: .claude, title: "Lux", cwd: "~",
                             createdAt: t0.addingTimeInterval(-600), windowIndex: 2)
        s.launchDisplay = "Lux"
        store.upsert(s)
        return (store, s)
    }

    @Test("a second pass a second later: no observed change, no write")
    func quietPass() throws {
        let url = tempURL(), ws = UUID(), t0 = Date()
        let (store, s) = liveStore(url, ws: ws, t0: t0)
        let tabs = [TabsModel.Tab(label: "claude", index: 2, cwd: "/home/ubuntu")]
        store.reconcile(entries: [entry(ws, tabs: tabs)], now: t0)
        let first = try #require(store.session(s.id))
        #expect(first.lastSeenAt == t0 && first.agentSeenAt == t0)

        try? FileManager.default.removeItem(at: url)
        let flag = Flag()
        withObservationTracking { _ = store.sessions } onChange: { flag.fired = true }
        for k in 1...20 {
            store.reconcile(entries: [entry(ws, tabs: tabs)], now: t0.addingTimeInterval(Double(k)))
        }
        #expect(!flag.fired, "the sidebar would re-render on every pass")
        #expect(!FileManager.default.fileExists(atPath: url.path), "sessions.json rewritten on a quiet pass")
        #expect(store.session(s.id) == first)
    }

    @Test("stamps still move: every 30 s, and at once after a resume")
    func stampsMove() throws {
        let url = tempURL(), ws = UUID(), t0 = Date()
        let (store, s) = liveStore(url, ws: ws, t0: t0)
        let tabs = [TabsModel.Tab(label: "claude", index: 2, cwd: "/home/ubuntu")]
        store.reconcile(entries: [entry(ws, tabs: tabs)], now: t0)
        let later = t0.addingTimeInterval(AgentSessionStore.seenStride)
        store.reconcile(entries: [entry(ws, tabs: tabs)], now: later)
        #expect(store.session(s.id)?.lastSeenAt == later)
        #expect(store.session(s.id)?.agentSeenAt == later)

        // A resume just after: "has the agent run since?" must say yes on
        // the first pass that sees it, not 30 s later.
        let resumed = later.addingTimeInterval(1)
        store.mutate(s.id) { $0.resumedAt = resumed }
        let next = resumed.addingTimeInterval(1)
        store.reconcile(entries: [entry(ws, tabs: tabs)], now: next)
        #expect(store.session(s.id)?.agentSeenAt == next)
        #expect(store.session(s.id)?.lastSeenAt == later)   // liveness waits its turn
    }

    @Test("the liveness probe stamps agentSeenAt on the same terms")
    func probe() throws {
        let url = tempURL(), ws = UUID(), t0 = Date()
        let (store, s) = liveStore(url, ws: ws, t0: t0)
        store.setLiveness(s.id, alive: true, now: t0)
        #expect(store.session(s.id)?.agentSeenAt == t0)
        let flag = Flag()
        withObservationTracking { _ = store.sessions } onChange: { flag.fired = true }
        store.setLiveness(s.id, alive: true, now: t0.addingTimeInterval(5))
        #expect(!flag.fired)
        store.setLiveness(s.id, alive: true, now: t0.addingTimeInterval(AgentSessionStore.seenStride))
        #expect(flag.fired)
    }

    @Test("restamp: unset, stale, or older than the last start")
    func restampRule() {
        let now = Date()
        #expect(AgentSessionStore.restamp(nil, now))
        #expect(!AgentSessionStore.restamp(now.addingTimeInterval(-29), now))
        #expect(AgentSessionStore.restamp(now.addingTimeInterval(-30), now))
        #expect(AgentSessionStore.restamp(now.addingTimeInterval(-2), now, since: now.addingTimeInterval(-1)))
    }

    @Test("the Agent Host's roster pass and the sidebar's rows follow the same rule")
    func sources() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: top.appendingPathComponent("Sources/AgentHost/Sessions.swift"), encoding: .utf8)
        let pass = try #require(host.range(of: "private func reconcileLocked("))
        let body = host[pass.upperBound...].prefix(1500)
        #expect(body.contains("if Self.restamp(s.lastSeenAt, now) { s.lastSeenAt = now }"))
        #expect(!body.contains("                s.lastSeenAt = now\n"))
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("if w.listModel.profileRows != rows { w.listModel.profileRows = rows }"))
        #expect(!ac.contains("w.listModel.profileRows = profiles.map"))
    }
}
