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
