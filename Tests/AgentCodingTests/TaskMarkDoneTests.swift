import Foundation
import Testing
@testable import bromure_ac

@Suite("Mark as done")
@MainActor
struct TaskMarkDoneTests {
    @Test("a task in review goes Done as it stands — nothing merged, nothing removed")
    func markDone() {
        let store = CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
        let engine = CodingTaskEngine(store: store, delegate: nil)
        var t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        t.stage = .testing
        t.branch = "wt/fix-it"
        t.worktreeDir = "/home/ubuntu/.bromure/worktrees/repo/fix-it"
        t.lastError = "stale"
        store.upsert(t)
        engine.markDone(t.id)
        let done = store.task(t.id)
        #expect(done?.stage == .done)
        #expect(done?.merged == false)
        #expect(done?.completedAt != nil)
        #expect(done?.lastError == nil)
        // The worktree is left exactly where it was.
        #expect(done?.branch == "wt/fix-it" && done?.worktreeDir == t.worktreeDir)
        #expect(done?.completion == .markedDone(byUser: true))
        // From In Progress too (the agent is stopped); not from the Backlog.
        var running = CodingTask(title: "Busy", profileID: UUID(), tool: .claude)
        running.stage = .inProgress
        store.upsert(running)
        engine.markDone(running.id)
        #expect(store.task(running.id)?.stage == .done)
        let idle = CodingTask(title: "Later", profileID: UUID(), tool: .claude)
        store.upsert(idle)
        engine.markDone(idle.id)
        #expect(store.task(idle.id)?.stage == .backlog)
    }
}
