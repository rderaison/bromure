import Foundation
import Testing
@testable import bromure_ac

/// Board report: a watch's per-commit review listed commits as skipped
/// beside the review that covered them. Each edit of the watch re-baselined
/// its commit trigger, and the baseline recorded every commit listed as a
/// skipped backlog item. An edit that keeps the polled source now keeps the
/// poll state, the commit baseline records nothing (its tip is the
/// baseline), and the run lists leave older backlog records out.
@Suite("Commit review: no skipped-commit noise")
@MainActor struct CommitBacklogNoiseTests {
    private func store() -> ScheduledAutomationStore {
        ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("backlog-\(UUID().uuidString).json"))
    }

    private func commitScan() -> ScheduledAutomation {
        var a = ScheduledAutomation(name: "Commits", profileID: UUID(), trigger: .githubCommit,
                                    githubRepo: "o/r", prompt: "Review {{commit.key}}.")
        a.filters.commitBranch = "main"
        return a
    }

    @Test("an edit that keeps the source keeps the poll state; another source or a re-enable starts afresh")
    func editKeepsPollState() {
        let s = store()
        var a = commitScan()
        s.upsert(a)
        var state = ScheduledAutomationStore.PRPollState()
        state.highWater = Date(); state.tipSHA = "0a00000"
        s.setPollState(state, for: a.id)

        a.prompt = "Review {{commit.key}} for injections."   // the watch's focus changed
        a.tool = .grok
        s.upsert(a)
        #expect(s.pollState(for: a.id)?.tipSHA == "0a00000")

        a.filters.commitBranch = "release"                    // another branch: re-baseline
        s.upsert(a)
        #expect(s.pollState(for: a.id) == nil)

        s.setPollState(state, for: a.id)
        a.enabled = false
        s.upsert(a)
        #expect(s.pollState(for: a.id)?.tipSHA == "0a00000")
        a.enabled = true                                      // back on: what landed meanwhile isn't replayed
        s.upsert(a)
        #expect(s.pollState(for: a.id) == nil)
    }

    @Test("backlog records stay dedup keys but no run list shows them")
    func backlogSeedsHidden() {
        let aid = UUID()
        let seed = AutomationRunRecord(automationID: aid, firedAt: Date(), outcome: .skipped,
                                       detail: "commit 0a00001: fix \(AutomationRunRecord.backlogMarker)",
                                       itemKey: "commit:0a00001")
        let legacy = AutomationRunRecord(automationID: aid, firedAt: Date(), outcome: .skipped,
                                         detail: "commit 0a00002: tidy (pre-existing)",
                                         itemKey: "commit:0a00002")
        let off = AutomationRunRecord(automationID: aid, firedAt: Date(), outcome: .skipped,
                                      detail: "The workspace isn't running and this automation doesn't start it",
                                      itemKey: "commit:0a00003")
        let ran = AutomationRunRecord(automationID: aid, firedAt: Date(), outcome: .launched,
                                      detail: "commit 0a00004: feature", itemKey: "commit:0a00004")
        #expect(seed.isBacklogSeed && legacy.isBacklogSeed)
        #expect(!off.isBacklogSeed && !ran.isBacklogSeed)
        let cols = AutomationBoard.classify(runs: [seed, legacy, off, ran]) { _ in false }
        #expect(Set(cols.done.map(\.id)) == [off.id, ran.id])
    }
}
