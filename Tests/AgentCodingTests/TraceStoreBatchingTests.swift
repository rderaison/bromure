import Foundation
import Testing
@testable import bromure_ac

/// The proxy records every request into the trace store. It used to wait on
/// the main thread for each one, then post a second main-queue job per
/// request — and the main queue is where the guests' vsock connections are
/// accepted, so a burst of parallel requests queued the next connects
/// behind it. Recording is now any-thread and batched.
@MainActor
@Suite("Trace store batching")
struct TraceStoreBatchingTests {
    private func store() -> TraceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-batch-\(UUID().uuidString)", isDirectory: true)
        return TraceStore(rootDir: dir)
    }

    nonisolated private static func rec(_ host: String = "registry.example", profile: UUID = UUID(),
                     status: Int = 200, at: Date = Date()) -> TraceRecord {
        TraceRecord(sessionID: profile, profileID: profile, timestamp: at, host: host, port: 443,
                    method: "GET", path: "/v2/", statusCode: status, requestBytes: 1,
                    responseBytes: 1, latencyMs: 1, swaps: [], leaks: [], bodyStored: false)
    }

    /// Lets the main queue run what was posted before this call.
    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test("recording never waits on the main thread")
    func recordsWhileMainIsBusy() async {
        let s = store()
        let group = DispatchGroup()
        // Main is blocked in group.wait below; a record that needed main
        // would never finish.
        for _ in 0..<100 {
            DispatchQueue.global().async(group: group) { s.record(Self.rec()) }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(s.recent.isEmpty)   // the ring fills on main, after
        await drainMain()
        #expect(s.recent.count == 100)
    }

    @Test("a burst lands newest first, in one pass")
    func burstOrder() async {
        let s = store()
        let base = Date()
        let records = (0..<20).map { Self.rec(at: base.addingTimeInterval(Double($0))) }
        for r in records { s.record(r) }
        await drainMain()
        #expect(s.recent.map(\.id) == records.reversed().map(\.id))
        // A later record still goes on top.
        let late = Self.rec()
        s.record(late)
        await drainMain()
        #expect(s.recent.first?.id == late.id)
        #expect(s.recent.count == 21)
    }

    @Test("the ring keeps its cap across a batch")
    func ringCap() async {
        let s = store()
        s.ringCapacity = 10
        let records = (0..<25).map { _ in Self.rec() }
        for r in records { s.record(r) }
        await drainMain()
        #expect(s.recent.map(\.id) == records.suffix(10).reversed().map(\.id))
    }

    @Test("each model call still reaches the conversation hooks")
    func conversationHooks() async {
        let s = store()
        let pid = UUID()
        var activity = 0
        var results: [Int] = []
        s.onConversationActivity = { if $0 == pid { activity += 1 } }
        s.onConversationResult = { p, _, status in if p == pid { results.append(status) } }
        s.record(Self.rec("api.anthropic.com", profile: pid, status: 200))
        s.record(Self.rec("registry.example", profile: pid))
        s.record(Self.rec("api.anthropic.com", profile: pid, status: 401))
        await drainMain()
        #expect(activity == 2)
        #expect(results == [200, 401])
    }

    @Test("main-thread stalls are counted from the threshold up")
    func lagStats() {
        var st = MainThreadLagMonitor.Stats()
        let t = Date()
        st.note(0.1, threshold: 0.5, at: t)
        #expect(st.count == 0 && st.since == nil)
        st.note(0.7, threshold: 0.5, at: t)
        st.note(2.0, threshold: 0.5, at: t.addingTimeInterval(1))
        st.note(0.5, threshold: 0.5, at: t.addingTimeInterval(2))
        #expect(st.count == 3)
        #expect(st.worst == 2.0)
        #expect(st.since == t)
    }
}
