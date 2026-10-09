import Foundation
import Testing
@testable import bromure_ac

@Suite("Task board: Stop and couldn't-start")
@MainActor
struct TaskBoardStopTests {
    private func store() -> CodingTaskStore {
        CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-\(UUID().uuidString).json"))
    }

    @Test("Stop on a task in Review is refused with the reason, and the task stays put")
    func stopRefusedOutsideInProgress() {
        let s = store()
        let engine = CodingTaskEngine(store: s, delegate: nil)
        var t = CodingTask(title: "Review me", profileID: UUID())
        t.stage = .testing
        t.branch = "wt/review-me"
        s.upsert(t)
        let why = engine.stopToBacklog(t.id)
        #expect(why == CodingTaskEngine.stopRefusal(.testing))
        #expect(!(why ?? "").isEmpty)
        #expect(s.task(t.id)?.stage == .testing)
        #expect(s.task(t.id)?.branch == "wt/review-me")
        for stage in [CodingTask.Stage.backlog, .planning, .done] {
            t.stage = stage
            s.upsert(t)
            #expect(engine.stopToBacklog(t.id) != nil)
            #expect(s.task(t.id)?.stage == stage)
        }
        #expect(engine.stopToBacklog(UUID()) != nil)
    }

    @Test("Stop on a task In Progress returns it to the Backlog, branch kept for the resume")
    func stopInProgress() {
        let s = store()
        let engine = CodingTaskEngine(store: s, delegate: nil)
        var t = CodingTask(title: "Run me", profileID: UUID())
        t.stage = .inProgress
        t.branch = "wt/run-me"
        t.startedAt = Date()
        s.upsert(t)
        #expect(engine.stopToBacklog(t.id) == nil)
        #expect(s.task(t.id)?.stage == .backlog)
        #expect(s.task(t.id)?.resumeBranch == "wt/run-me")
        #expect(!engine.hasPendingTabClose(profileID: t.profileID, branch: "wt/other"))
    }

    @Test("an agent that died at launch reads Couldn't start, and the board counts it as needing you")
    func couldntStartIsCounted() {
        let tasks = store()
        let sessions = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let model = SessionListModel()
        let ws = UUID()
        var s = AgentSession(profileID: ws, tool: .kimi, title: "Dies", cwd: "~/x", windowIndex: 2)
        s.lastError = "Kimi quit right after it started"
        sessions.upsert(s)
        var t = CodingTask(title: "Dies", profileID: ws)
        t.stage = .inProgress
        t.sessionID = s.id
        t.branch = "wt/dies"
        tasks.upsert(t)
        #expect(TaskLiveState.couldntStart(t, in: model, sessions: sessions))
        #expect(TaskLiveState.needsAttention(t, in: model, sessions: sessions))
        // Its session healthy: neither.
        sessions.mutate(s.id) { $0.lastError = nil }
        #expect(!TaskLiveState.couldntStart(t, in: model, sessions: sessions))
        // No session at all, but the launch failure on the card: still it.
        var lone = CodingTask(title: "Lone", profileID: ws)
        lone.stage = .inProgress
        lone.branch = "wt/lone"
        lone.lastError = "Couldn't reach the workspace"
        #expect(TaskLiveState.couldntStart(lone, in: model, sessions: sessions))
        // Not running: never.
        lone.stage = .testing
        #expect(!TaskLiveState.couldntStart(lone, in: model, sessions: sessions))
    }
}
