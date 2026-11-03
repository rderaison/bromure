import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "A commit's rewind base is dropped before an async
/// launch is recorded". Past 200 entries `commitBases` kept only keys of
/// runs recorded as launched or refused, plus the key firing now. A clone,
/// checkout or boot launch records its run after an await, so an earlier
/// commit of the same poll had no run yet and lost its base; and every
/// finished launched run still counted, so the map never shrank.
@Suite("Automations: a commit's rewind base outlives its async launch")
struct CommitBaseTrimTests {
    private func run(_ key: String, done: Bool = false, refused: Bool = false) -> AutomationRunRecord {
        var r = AutomationRunRecord(automationID: UUID(), firedAt: Date(), outcome: refused ? .failed : .launched,
                                    detail: key, branchSlug: "s-\(key)", itemKey: key)
        if done { r.completedAt = Date() }
        if refused { r.refusedByGuest = true }
        return r
    }

    @Test("an earlier commit of this poll, still launching, keeps its base; done runs let theirs go")
    func trim() {
        var bases: [String: String] = [:]
        for i in 0..<199 { bases["commit:done\(i)"] = "b\(i)" }
        bases["commit:launching"] = "p1"   // fired earlier this poll, no run recorded yet
        bases["commit:open"] = "p2"
        bases["commit:refused"] = "p3"
        bases["commit:refired"] = "p4"
        bases["commit:now"] = "p5"
        let runs = (0..<199).map { run("commit:done\($0)", done: true) }
            + [run("commit:open"), run("commit:refused", refused: true), run("commit:refired", refused: true)]
        let kept = ScheduledAutomationEngine.trimmedCommitBases(
            bases, runs: runs, handled: ["commit:refired"], underWay: ["commit:launching"], firing: "commit:now")
        #expect(kept == ["commit:launching": "p1", "commit:open": "p2", "commit:refused": "p3", "commit:now": "p5"])
        // Under the limit nothing is trimmed.
        let few = ["commit:a": "x"]
        #expect(ScheduledAutomationEngine.trimmedCommitBases(few, runs: [], handled: [], underWay: [], firing: "commit:b") == few)
    }

    @Test("the poll trims with the launches under way")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/ScheduledAutomations.swift"), encoding: .utf8)
        #expect(src.contains("underWay: launchesUnderWay(a.id), firing: key)"))
        #expect(!src.contains("$0.outcome == .launched || $0.refusedByGuest == true"))
    }
}
