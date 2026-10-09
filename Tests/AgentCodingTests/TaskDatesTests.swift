import Foundation
import Testing
@testable import bromure_ac

@Suite("Task dates")
@MainActor
struct TaskDatesTests {
    private func store() -> CodingTaskStore {
        CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
    }

    @Test("a change stamps updatedAt; a save that changes nothing doesn't")
    func stamping() throws {
        let s = store()
        let t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        s.upsert(t)
        #expect(s.task(t.id)?.updatedAt == nil)            // just created
        s.mutate(t.id) { $0.title = "Fix it" }              // no change
        #expect(s.task(t.id)?.updatedAt == nil)
        s.mutate(t.id) { $0.title = "Fix it properly" }
        let first = try #require(s.task(t.id)?.updatedAt)
        // Saving the same task back (the editor, a fat client) isn't a change.
        s.upsert(try #require(s.task(t.id)))
        #expect(s.task(t.id)?.updatedAt == first)
        var edited = try #require(s.task(t.id))
        edited.details = "and add a test"
        edited.updatedAt = nil                              // a client's stale copy
        s.upsert(edited)
        #expect((s.task(t.id)?.updatedAt ?? .distantPast) >= first)
        #expect(s.task(t.id)?.createdAt == t.createdAt)    // creation never moves
    }
}
