import Foundation
import Testing
@testable import bromure_ac

// "Ask <session> to fix it" is resent once when it got no answer. When the
// first send had got through and its task was Done by the resend, the server
// queued a second fix task. Each hand-over now carries a key; a resend with
// it gets the first send's task back.
@Suite("Finding → session hand-over: a resend gets the same task")
struct HandOverLedgerTests {
    @Test("same key: the first task, Done or not; a new key or another finding: a new hand-over")
    func ledger() {
        var l = HandOverLedger()
        let f = UUID(), g = UUID(), t = UUID()
        #expect(l.task(f, "k1", exists: { _ in true }) == nil)
        l.record(f, "k1", task: t)
        #expect(l.task(f, "k1", exists: { _ in true }) == t)
        #expect(l.task(f, "k2", exists: { _ in true }) == nil)
        #expect(l.task(g, "k1", exists: { _ in true }) == nil)
        #expect(l.task(f, "k1", exists: { _ in false }) == nil, "a task gone from the board isn't handed back")
        l.record(f, nil, task: UUID())
        #expect(l.task(f, nil, exists: { _ in true }) == nil, "no key, no memory: an older client")
    }

    @Test("only the last few hundred are kept")
    func bounded() {
        var l = HandOverLedger()
        let f = UUID(), first = UUID()
        l.record(f, "0", task: first)
        for i in 1...HandOverLedger.kept { l.record(f, "\(i)", task: UUID()) }
        #expect(l.task(f, "0", exists: { _ in true }) == nil)
        #expect(l.task(f, "\(HandOverLedger.kept)", exists: { _ in true }) != nil)
    }

    @Test("both clients send a key with the resent hand-over; the host passes it on")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let fat = try read("Sources/AgentCoding/FatClientController.swift")
        let at = try #require(fat.range(of: "/session\","))
        #expect(fat[at.upperBound...].prefix(250).contains("\"handOver\": UUID().uuidString"))
        let web = try read("web-client/src/features/boards/AutomationHub.tsx")
        #expect(web.contains("/session`, { session: s.id, confirmed, handOver: crypto.randomUUID() }"))
        let host = try read("Sources/AgentCoding/RepoWatchWiring.swift")
        #expect(host.contains("body[\"handOver\"]"))
        #expect(host.contains("repoWatchEngine.fix(findingID, by: s, handOver: handOver)"))
    }
}
