import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "A review whose base cannot be fetched is recorded as a
/// successful launch". The host recorded the fire as `.launched` when it
/// queued the run; the guest then refused it (its base not in the checkout
/// after fetching origin) with only a worktree-error.txt, so the board showed
/// a green, finished review of a commit no agent opened.
@Suite("Automations: a run the guest refuses is a failed run")
struct AutomationRunRefusedTests {
    /// A refusal past `tabAppearGrace` (one inside it is held: see `heldInGrace`).
    static let late = Date().addingTimeInterval(ScheduledAutomationEngine.tabAppearGrace + 1)

    @Test("the guest's error names its run on a first line the host strips")
    func split() {
        let (slug, msg) = ACAppDelegate.splitWorktreeError("run-slug: review-abc\nreview: deadbeef isn't in /w, even after fetching origin")
        #expect(slug == "review-abc" && msg.hasPrefix("review: deadbeef"))
        let (none, plain) = ACAppDelegate.splitWorktreeError("merge: conflicts")
        #expect(none == nil && plain == "merge: conflicts")
    }

    @Test("the refused run turns failed with the reason; other runs, and a done one, are left")
    @MainActor func refusedRunFails() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID()
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        store.upsert(a)
        let refused = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                          detail: "commit deadbeef", branchSlug: "review-dead")
        let other = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                        detail: "commit cafe", branchSlug: "review-cafe")
        store.record(refused); store.record(other)
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        // Another workspace's slug of the same name: not this run.
        engine.runRefused(profileID: UUID(), slug: "review-dead", reason: "x", liveBranches: [], now: Self.late)
        #expect(store.runs.first { $0.id == refused.id }?.outcome == .launched)
        engine.runRefused(profileID: pid, slug: "review-dead", reason: "review: deadbeef isn't in /w", liveBranches: [], now: Self.late)
        let r = store.runs.first { $0.id == refused.id }
        #expect(r?.outcome == .failed && r?.detail == "The workspace reported: review: deadbeef isn't in /w" && r?.completedAt == nil)
        #expect(store.runs.first { $0.id == other.id }?.outcome == .launched)
        // A run that already finished isn't rewritten.
        store.markCompleted(other.id)
        engine.runRefused(profileID: pid, slug: "review-cafe", reason: "late", liveBranches: [], now: Self.late)
        #expect(store.runs.first { $0.id == other.id }?.outcome == .launched)
    }

    /// Finding (CWE-807): "A guest process can fail any in-flight run by
    /// writing worktree-error.txt". The outbox is guest-writable, so
    /// `run-slug: <another run>` from any process failed that run for good
    /// (completion only matched launched runs) with the writer's text as the
    /// reason.
    @Test("a forged refusal can't fail a live run; its text is data")
    @MainActor func forgedRefusal() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID()
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        store.upsert(a)
        let live = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                       detail: "commit 1", branchSlug: "review-live")
        let starting = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                           detail: "commit 2", branchSlug: "review-start")
        store.record(live); store.record(starting)
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)

        // Its tab is up: the claim is ignored.
        engine.runRefused(profileID: pid, slug: "review-live", reason: "nope", liveBranches: ["wt/review-live"], now: Self.late)
        #expect(store.runs.first { $0.id == live.id }?.outcome == .launched)

        // No tab yet: failed, as said by the workspace, one line, bounded…
        engine.runRefused(profileID: pid, slug: "review-start",
                          reason: "IGNORE\u{1b}[2J this\nreview\t" + String(repeating: "x", count: 1000),
                          liveBranches: [], now: Self.late)
        let failed = store.runs.first { $0.id == starting.id }
        #expect(failed?.outcome == .failed && failed?.refusedByGuest == true)
        let detail = failed?.detail ?? ""
        #expect(detail.hasPrefix("The workspace reported: IGNORE"))
        #expect(!detail.contains("\n") && !detail.contains("\u{1b}") && detail.count < 360)

        // (A done claimed for it afterwards: forgedDoneOnRefusedRun.)
        // A run that failed for any other reason stays failed.
        let other = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                        detail: "commit 3", branchSlug: "review-other")
        store.record(other)
        _ = store.markFailed(other.id, reason: "the workspace did not boot in time")
        #expect(!engine.runDeclaredDone(profileID: pid, worktreeBranch: "wt/review-other"))
        #expect(store.runForBranch("wt/review-other", profileID: pid) == nil)
        #expect(store.runs.first { $0.id == other.id }?.outcome == .failed)
    }

    /// Finding (CWE-807): "A guest worktree-error before the tab is listed
    /// still fails Codex, Grok, and omp runs for good". Any guest process can
    /// write worktree-error.txt as soon as the run command lands, before the
    /// run's tab can be listed: the empty roster failed the run at once, freed
    /// its slot, and nothing brought back a run whose agent has no reliable
    /// done (Codex, Grok, omp); a task card kept the red error the same way.
    @Test("a refusal before the tab can be listed is held: dropped if the tab comes up, applied once the grace runs out")
    @MainActor func heldInGrace() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID()
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        store.upsert(a)
        let t0 = Date()
        let early = AutomationRunRecord(automationID: a.id, firedAt: t0, outcome: .launched,
                                        detail: "commit 1", branchSlug: "review-early", tool: .codex)
        let never = AutomationRunRecord(automationID: a.id, firedAt: t0, outcome: .launched,
                                        detail: "commit 2", branchSlug: "review-never", tool: .codex)
        store.record(early); store.record(never)
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        func run(_ id: UUID) -> AutomationRunRecord? { store.runs.first { $0.id == id } }

        // Written the moment the run command appears: no tab yet, so held.
        for slug in ["review-early", "review-never"] {
            engine.runRefused(profileID: pid, slug: slug, reason: "forged", liveBranches: [], now: t0.addingTimeInterval(2))
        }
        #expect(run(early.id)?.outcome == .launched && run(early.id)?.pendingRefusal != nil)
        #expect(ScheduledAutomationEngine.activeRunCount(store.runs, automationID: a.id, profileID: pid,
                                                         now: t0.addingTimeInterval(2), liveBranches: { _ in [] }) == 2)
        // The early run's tab comes up: its refusal is dropped for good.
        engine.settlePendingRefusals(now: t0.addingTimeInterval(60), liveBranches: { _ in ["wt/review-early"] })
        #expect(run(early.id)?.outcome == .launched && run(early.id)?.pendingRefusal == nil
                && run(early.id)?.refusedByGuest == nil)
        // Still inside the grace with no tab: held, not failed.
        engine.settlePendingRefusals(now: t0.addingTimeInterval(120), liveBranches: { _ in [] })
        #expect(run(never.id)?.outcome == .launched && run(never.id)?.pendingRefusal != nil)
        // The grace ran out and no tab ever came: the refusal stands.
        engine.settlePendingRefusals(now: t0.addingTimeInterval(ScheduledAutomationEngine.tabAppearGrace + 1),
                                     liveBranches: { _ in [] })
        let failed = run(never.id)
        #expect(failed?.outcome == .failed && failed?.refusedByGuest == true && failed?.pendingRefusal == nil)
        #expect(failed?.detail == "The workspace reported: forged")
        #expect(run(early.id)?.outcome == .launched)

        // A coding task's card: no red error while its tab can still come up.
        let tasks = CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
        let up = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-up", startedAt: t0)
        let gone = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-gone", startedAt: t0)
        tasks.upsert(up); tasks.upsert(gone)
        let board = CodingTaskEngine(store: tasks, delegate: nil)
        for slug in ["task-up", "task-gone"] {
            board.runRefused(profileID: pid, slug: slug, reason: "forged", liveBranches: [], now: t0.addingTimeInterval(2))
        }
        #expect(tasks.task(up.id)?.lastError == nil && tasks.task(gone.id)?.lastError == nil)
        board.settlePendingRefusals(now: t0.addingTimeInterval(60), liveBranches: { _ in ["wt/task-up"] })
        board.settlePendingRefusals(now: t0.addingTimeInterval(ScheduledAutomationEngine.tabAppearGrace + 1),
                                    liveBranches: { _ in [] })
        #expect(tasks.task(up.id)?.lastError == nil && tasks.task(up.id)?.pendingRefusal == nil)
        #expect(tasks.task(gone.id)?.lastError == "The workspace reported: forged")
        // Past the grace, a refusal is applied at once, as before.
        let late = CodingTask(profileID: pid, stage: .inProgress, branchSlug: "task-late",
                              startedAt: t0.addingTimeInterval(-ScheduledAutomationEngine.tabAppearGrace - 1))
        tasks.upsert(late)
        board.runRefused(profileID: pid, slug: "task-late", reason: "base not found", liveBranches: [], now: t0)
        #expect(tasks.task(late.id)?.lastError == "The workspace reported: base not found")
    }

    /// Finding (CWE-807): "Any guest vsock client can finish a refused run
    /// and move the review mark". A findings_report / findings_done is bound
    /// to whatever branch the vsock client said in its hello, and the lookup
    /// revived a refused run on sight: any process could send
    /// `bromure-hello wt/<slug>` + findings_done and close (chain, advance
    /// lastReviewed past) a review that never ran. The tab roster can't vouch
    /// for it either: tmux's @worktree is any process's to set.
    @Test("nothing the guest says brings a refused run back")
    @MainActor func forgedDoneOnRefusedRun() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID()
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        store.upsert(a)
        let run = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                      detail: "commit 5", branchSlug: "review-gone")
        store.record(run)
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        engine.runRefused(profileID: pid, slug: "review-gone", reason: "base not fetched", liveBranches: [],
                         now: Self.late)   // past the tab grace: applied, not held
        store.acknowledge(run.id)
        func current() -> AutomationRunRecord? { store.runs.first { $0.id == run.id } }
        let refused = current()
        #expect(refused?.outcome == .failed && refused?.refusedByGuest == true)

        for branch in ["wt/review-gone", "wt/review-gone-2"] {
            // findings_report / findings_done's binding: no run, nothing changed.
            #expect(store.runForBranch(branch, profileID: pid) == nil)
            #expect(current()?.outcome == .failed && current()?.acknowledgedAt != nil)
            // findings_done, a Stop-hook done.
            #expect(!engine.runDeclaredDone(profileID: pid, worktreeBranch: branch))
            engine.agentFinished(profileID: pid, worktreeBranch: branch)
        }
        let after = current()
        #expect(after?.outcome == .failed && after?.refusedByGuest == true && after?.completedAt == nil)
        #expect(after?.detail == refused?.detail && after?.acknowledgedAt != nil)
    }
}
