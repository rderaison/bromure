import Foundation
import Testing
@testable import bromure_ac

/// The Done archive is read first forever after, so it must come from the
/// guest's full transcript, not the session's tail-seeded cache. Finding:
/// "Finished tasks can permanently archive a truncated session transcript".
@Suite("Task transcript archive: read order")
struct TaskTranscriptArchiveOrderTests {
    @Test("The archive reads the full file first; the session copy is only its fallback")
    func archiveOrder() {
        #expect(TaskTranscriptArchive.readOrder(forArchive: true) == [.guest, .session])
    }

    @Test("On demand: the archive, then the session copy, then the guest")
    func onDemandOrder() {
        #expect(TaskTranscriptArchive.readOrder(forArchive: false) == [.archive, .session, .guest])
    }

    @Test("Reaching Done archives with the full-read order")
    func doneUsesArchiveOrder() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tasks = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/CodingTasks.swift"), encoding: .utf8)
        let fn = try #require(tasks.range(of: "func archiveTranscriptThenCleanup("))
        let body = tasks[fn.upperBound...].prefix(1500)
        #expect(body.contains("delegate.fetchTaskTranscriptRaw(task, forArchive: true)"))
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("for source in TaskTranscriptArchive.readOrder(forArchive: forArchive) {"))
    }
}

@Suite("Task transcript archive: a capped full read")
struct TaskTranscriptArchiveCapTests {
    @Test("A read at the cap may be short of the end; a shorter one is whole")
    func capped() {
        #expect(TaskTranscriptArchive.mayBeCapped(String(repeating: "a", count: TaskTranscriptArchive.fullReadCap)))
        #expect(!TaskTranscriptArchive.mayBeCapped(String(repeating: "a", count: 1_000_000)))
    }

    @Test("The capped head and the session tail join into the whole conversation")
    func headAndTailJoin() throws {
        func line(_ n: Int) -> String {
            #"{"type":"user","message":{"role":"user","content":"m\#(n)"},"uuid":"u\#(n)","timestamp":"2026-09-19T20:00:\#(String(format: "%02d", n % 60)).000Z","sessionId":"s1"}"#
        }
        let head = (1...40).map(line).joined(separator: "\n") + "\n"
        let tail = (30...60).map(line).joined(separator: "\n") + "\n"
        let joined = try #require(SessionTranscriptCache.merge(history: Data(head.utf8), incoming: Data(tail.utf8), mode: .overlapOnly))
        let text = String(decoding: joined, as: UTF8.self)
        #expect(text.contains(#""uuid":"u1""#))
        #expect(text.contains(#""uuid":"u60""#))
        #expect(text.components(separatedBy: #""uuid":"u35""#).count == 2)   // once
    }
}
