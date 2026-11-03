import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Held task refusal overwrites a later error on the
/// card". A worktree error inside `tabAppearGrace` is held on the task; a
/// later reason (a second report after the grace, the launch watch's own
/// diagnosis) left the hold in place, and the next tick wrote the older held
/// text over it.
@Suite("Coding tasks: a held refusal never overwrites a later reason")
struct TaskHeldRefusalTests {
    @MainActor private func board() -> (CodingTaskStore, CodingTaskEngine, UUID, Date) {
        let tasks = CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
        return (tasks, CodingTaskEngine(store: tasks, delegate: nil), UUID(), Date())
    }
    static let grace = ScheduledAutomationEngine.tabAppearGrace

    @Test("a later report after the grace stands; the held one is dropped with it")
    @MainActor func laterReportStands() {
        let (tasks, engine, pid, t0) = board()
        let t = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-a", startedAt: t0)
        tasks.upsert(t)
        engine.runRefused(profileID: pid, slug: "task-a", reason: "forged early", liveBranches: [], now: t0.addingTimeInterval(2))
        #expect(tasks.task(t.id)?.pendingRefusal != nil && tasks.task(t.id)?.lastError == nil)
        engine.runRefused(profileID: pid, slug: "task-a", reason: "base fetch failed", liveBranches: [],
                          now: t0.addingTimeInterval(Self.grace + 5))
        engine.settlePendingRefusals(now: t0.addingTimeInterval(Self.grace + 30), liveBranches: { _ in [] })
        #expect(tasks.task(t.id)?.lastError == "The workspace reported: base fetch failed")
        #expect(tasks.task(t.id)?.pendingRefusal == nil)
    }

    @Test("a reason the host put on the card meanwhile isn't written over")
    @MainActor func hostReasonStands() {
        let (tasks, engine, pid, t0) = board()
        let t = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-b", startedAt: t0)
        tasks.upsert(t)
        engine.runRefused(profileID: pid, slug: "task-b", reason: "forged early", liveBranches: [], now: t0.addingTimeInterval(2))
        // e.g. the launch watch: "exited right after it started…"
        tasks.mutate(t.id) { $0.lastError = "Claude exited right after it started." }
        engine.settlePendingRefusals(now: t0.addingTimeInterval(Self.grace + 1), liveBranches: { _ in [] })
        #expect(tasks.task(t.id)?.lastError == "Claude exited right after it started.")
        #expect(tasks.task(t.id)?.pendingRefusal == nil)
        // A clear card still gets the held refusal, as before.
        let u = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-c", startedAt: t0)
        tasks.upsert(u)
        engine.runRefused(profileID: pid, slug: "task-c", reason: "no base", liveBranches: [], now: t0.addingTimeInterval(2))
        engine.settlePendingRefusals(now: t0.addingTimeInterval(Self.grace + 1), liveBranches: { _ in [] })
        #expect(tasks.task(u.id)?.lastError == "The workspace reported: no base")
    }

    @Test("a refusal ignored for a live tab drops a held one too")
    @MainActor func liveTabDropsHold() {
        let (tasks, engine, pid, t0) = board()
        let t = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-d", startedAt: t0)
        tasks.upsert(t)
        engine.runRefused(profileID: pid, slug: "task-d", reason: "forged", liveBranches: [], now: t0.addingTimeInterval(2))
        engine.runRefused(profileID: pid, slug: "task-d", reason: "again", liveBranches: ["wt/task-d"], now: t0.addingTimeInterval(3))
        #expect(tasks.task(t.id)?.pendingRefusal == nil)
    }

    @Test("the launch diagnoses and every run (re)start clear the hold in the same update")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/CodingTasks.swift"), encoding: .utf8)
        #expect(src.components(separatedBy: "$0.lastError = why; $0.pendingRefusal = nil").count == 3)
        #expect(src.components(separatedBy: "$0.pendingRefusal = nil   // ").count == 5)
    }
}
