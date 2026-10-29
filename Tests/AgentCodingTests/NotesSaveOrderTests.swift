import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-362): "A second implicit notes save uses the uncommitted
/// draft as its base, so the later text is dropped". Each fat-client notes
/// PUT dialed its own connection and the host ran whichever arrived first:
/// the second (its base the first's draft, not stored yet) was refused as
/// superseded, then the first wrote the older draft.
@Suite("Notes saves go in order")
@MainActor
struct NotesSaveOrderTests {
    final class Log { var events: [String] = [] }

    @Test("a slow first save finishes before the second starts, for one workspace")
    func inOrder() async {
        let q = InOrder<String, Int>()
        let log = Log()
        async let first = q.run("ws") {
            log.events.append("start 1")
            try? await Task.sleep(nanoseconds: 200_000_000)
            log.events.append("end 1"); return 1
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let second = q.run("ws") {
            log.events.append("start 2"); log.events.append("end 2"); return 2
        }
        let (a, b) = await (first, second)
        #expect(a == 1 && b == 2)
        #expect(log.events == ["start 1", "end 1", "start 2", "end 2"])
        #expect(q.idle)
    }

    @Test("another workspace doesn't wait")
    func otherKey() async {
        let q = InOrder<String, Int>()
        let log = Log()
        async let slow = q.run("a") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            log.events.append("a"); return 1
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let fast = q.run("b") { log.events.append("b"); return 2 }
        _ = await (slow, fast)
        #expect(log.events == ["b", "a"])
    }

    @Test("the fat client's dashboard saves notes through the queue")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let f = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(f.contains("onSaveNotes:   { text, base in await c.saveNotesInOrder(id, text, ifStill: base) })"))
        #expect(f.contains("await notesSaves.run(id) { await Self.saveNotes(self, id, text, ifStill: base) }"))
        // The whole-document save keeps its own doc and @discardableResult.
        let doc = try #require(f.range(of: "func saveProfileDoc(_ id: Profile.ID, _ doc: [String: Any]) async throws -> [String: Any] {"))
        #expect(f[..<doc.lowerBound].suffix(60).contains("@discardableResult"))
    }
}
