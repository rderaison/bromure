import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "A guest refusal permanently drops a commit, PR, or
/// issue scan". A refused run is never revived from the guest, but its
/// `itemKey` still counted as handled, so the next poll skipped the event;
/// a commit watch also walked its tip past the commit, which was then never
/// listed again. Event automations don't retry on their own, so the scan was
/// lost. Now a refused run's event fires again, and a commit watch walks
/// back to before it.
@Suite("Automations: a refused run's event fires again")
struct AutomationRefusedRetryTests {
    static let late = Date().addingTimeInterval(ScheduledAutomationEngine.tabAppearGrace + 1)

    @MainActor private func setup(_ trigger: ScheduledAutomation.TriggerKind)
        -> (ScheduledAutomationStore, ScheduledAutomationEngine, ScheduledAutomation, UUID) {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let pid = UUID()
        let a = ScheduledAutomation(profileID: pid, trigger: trigger)
        store.upsert(a)
        return (store, ScheduledAutomationEngine(store: store, delegate: nil), a, pid)
    }

    @Test("a refused PR or issue run no longer counts as handled; a live or done one does")
    @MainActor func refusedKeyIsntHandled() {
        for trigger in [ScheduledAutomation.TriggerKind.githubPullRequest, .githubIssue, .linearIssue] {
            let (store, engine, a, pid) = setup(trigger)
            let refused = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                              detail: "x", branchSlug: "run-a", itemKey: "pr:7")
            let live = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                           detail: "y", branchSlug: "run-b", itemKey: "pr:8")
            let failed = AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                             detail: "z", branchSlug: "run-c", itemKey: "pr:9")
            store.record(refused); store.record(live); store.record(failed)
            _ = store.markFailed(failed.id, reason: "the workspace did not boot in time")
            #expect(store.handledItemKeys(for: a.id) == ["pr:7", "pr:8", "pr:9"])
            // A refusal held inside the tab grace isn't one yet.
            engine.runRefused(profileID: pid, slug: "run-a", reason: "nope", liveBranches: [], now: Date())
            #expect(store.handledItemKeys(for: a.id).contains("pr:7"))
            engine.runRefused(profileID: pid, slug: "run-a", reason: "nope", liveBranches: [], now: Self.late)
            #expect(store.handledItemKeys(for: a.id) == ["pr:8", "pr:9"])
            // It still says what it was for, and nothing revives it.
            #expect(store.runs.first { $0.id == refused.id }?.itemKey == "pr:7")
            #expect(store.runForBranch("wt/run-a", profileID: pid) == nil)
            // Fired again: handled again.
            store.record(AutomationRunRecord(automationID: a.id, firedAt: Date(), outcome: .launched,
                                             detail: "x", branchSlug: "run-a2", itemKey: "pr:7"))
            #expect(store.handledItemKeys(for: a.id).contains("pr:7"))
        }
    }

    @Test("a commit watch walks back to before the oldest refused commit not yet fired again")
    @MainActor func commitTipRewinds() {
        let (store, engine, a, pid) = setup(.githubCommit)
        func run(_ sha: String, _ slug: String, at t: TimeInterval) -> AutomationRunRecord {
            let r = AutomationRunRecord(automationID: a.id, firedAt: Date(timeIntervalSince1970: t), outcome: .launched,
                                        detail: "commit \(sha)", branchSlug: slug, itemKey: "commit:\(sha)")
            store.record(r); return r
        }
        _ = run("bbbbbbb", "review-b", at: 100)
        _ = run("ccccccc", "review-c", at: 200)
        // The poll settled past both; it kept where each was walked from.
        var state = ScheduledAutomationStore.PRPollState(lastPolledAt: Date(), highWater: Date(), tipSHA: "ddddddd")
        state.commitBases = ["commit:bbbbbbb": "aaaaaaa", "commit:ccccccc": "bbbbbbb"]
        store.setPollState(state, for: a.id)

        engine.runRefused(profileID: pid, slug: "review-c", reason: "x", liveBranches: [], now: Self.late)
        #expect(store.pollState(for: a.id)?.tipSHA == "bbbbbbb")
        #expect(store.pollState(for: a.id)?.lastPolledAt == nil)       // polled on the next tick
        // An older one refused later: walked back further, never forward.
        engine.runRefused(profileID: pid, slug: "review-b", reason: "x", liveBranches: [], now: Self.late)
        #expect(store.pollState(for: a.id)?.tipSHA == "aaaaaaa")
        _ = run("ccccccc", "review-c2", at: 300)                        // re-fired
        engine.requeueRefused(a.id)
        #expect(store.pollState(for: a.id)?.tipSHA == "aaaaaaa")      // b still waits
    }

    @Test("a poll under way when a refusal lands doesn't undo its rewind")
    func pollKeepsRewind() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/ScheduledAutomations.swift"), encoding: .utf8)
        #expect(src.contains("if current.tipSHA != previous?.tipSHA { next.tipSHA = current.tipSHA }"))
        #expect(src.contains("next.commitBases = previous?.commitBases"))
        // A commit fired with no tip yet (the first walk) still has a base:
        // its parent, where the walk stopped.
        #expect(src.contains("$0 > 0 ? landed[$0 - 1].sha : next.tipSHA ?? walkBase"))
        #expect(src.contains("walkBase = walk.base"))
        #expect(src.contains("let processed = store.handledItemKeys(for: a.id)"))
        #expect(src.components(separatedBy: "requeueRefused(run.automationID)").count == 3)
    }
}
