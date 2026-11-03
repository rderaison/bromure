import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Worktree failure sheet still fires while the refusal
/// is only held". A guest worktree-error inside the tab grace is held, and
/// dropped if the tab shows up -- but the host showed "Worktree action
/// failed" at once anyway, for a run that may start fine (or a forged
/// claim). The sheet now follows what the engines did with it.
@Suite("Worktree errors: the failure sheet only for a refusal that stands")
@MainActor
struct WorktreeFailureSheetTests {
    static let grace = ScheduledAutomationEngine.tabAppearGrace

    @Test("held, ignored and applied refusals, for automation runs and tasks")
    func outcomes() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID(), t0 = Date()
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        store.upsert(a)
        store.record(AutomationRunRecord(automationID: a.id, firedAt: t0, outcome: .launched,
                                         detail: "commit 1", branchSlug: "review-a"))
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        #expect(engine.runRefused(profileID: pid, slug: "review-a", reason: "x", liveBranches: [], now: t0.addingTimeInterval(2)) == .held)
        #expect(engine.runRefused(profileID: pid, slug: "review-a", reason: "x", liveBranches: ["wt/review-a"],
                                  now: t0.addingTimeInterval(Self.grace + 1)) == .ignored)
        #expect(engine.runRefused(profileID: pid, slug: "nope", reason: "x", liveBranches: [], now: t0) == .noRun)
        #expect(engine.runRefused(profileID: pid, slug: "review-a", reason: "x", liveBranches: [],
                                  now: t0.addingTimeInterval(Self.grace + 1)) == .applied)

        let tasks = CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
        tasks.upsert(CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-a", startedAt: t0))
        let board = CodingTaskEngine(store: tasks, delegate: nil)
        #expect(board.runRefused(profileID: pid, slug: "task-a", reason: "x", liveBranches: [], now: t0.addingTimeInterval(2)) == .held)
        #expect(board.runRefused(profileID: pid, slug: "task-a", reason: "x", liveBranches: ["wt/task-a"], now: t0) == .ignored)
        #expect(board.runRefused(profileID: pid, slug: "task-a", reason: "x", liveBranches: [],
                                 now: t0.addingTimeInterval(Self.grace + 1)) == .applied)
    }

    @Test("the sheet: for an applied refusal or an error naming no run; not for one held or ignored")
    func sheetRule() throws {
        let show = ScheduledAutomationEngine.showsWorktreeFailure
        #expect(!show([.held, .noRun]))
        #expect(!show([.noRun, .held]))
        #expect(!show([.ignored, .noRun]))
        #expect(show([.applied, .noRun]))
        #expect(show([.noRun, .applied]))
        #expect(show([.noRun, .noRun]))
        // The handler asks the rule before presenting.
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let handler = try #require(src.range(of: "sandbox.onWorktreeError = {"))
        let body = src[handler.upperBound...].prefix(3000)
        let gate = try #require(body.range(of: "guard ScheduledAutomationEngine.showsWorktreeFailure(outcomes) else { return }"))
        let sheet = try #require(body.range(of: "alert.beginSheetModal(for: win)"))
        #expect(gate.lowerBound < sheet.lowerBound)
    }
}
