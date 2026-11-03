import Foundation
import Testing
@testable import bromure_ac

/// 20 commits pushed at once to a watched branch: reviewed one after the
/// other (by default), not by 20 agents side by side.
@Suite("Automation runs at a time")
struct AutomationParallelismTests {
    private let aid = UUID(), pid = UUID()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func run(_ ago: TimeInterval, slug: String, done: Bool = false,
                     outcome: AutomationRunRecord.Outcome = .launched) -> AutomationRunRecord {
        var r = AutomationRunRecord(automationID: aid, firedAt: now.addingTimeInterval(-ago), outcome: outcome,
                                    detail: "", branchSlug: slug, itemKey: "commit:\(slug)")
        if done { r.completedAt = now }
        return r
    }

    @Test("a run counts while it works: launched, not done, its tab up")
    func counting() {
        let runs = [run(60, slug: "a"),                     // just launched, tab not there yet: counts
                    run(1800, slug: "b"),                   // tab up: counts
                    run(1800, slug: "c"),                   // tab gone (closed, crashed): free
                    run(1800, slug: "d", done: true),       // finished: free
                    run(1800, slug: "e", outcome: .failed), // never ran: free
                    run(7 * 3600, slug: "f")]               // never reported, long past: free
        let n = ScheduledAutomationEngine.activeRunCount(runs, automationID: aid, profileID: pid, now: now) { _ in
            ["wt/b-2", "wt/unrelated"]
        }
        #expect(n == 2)
        // The workspace's tabs can't be told: launched and not done counts.
        #expect(ScheduledAutomationEngine.activeRunCount(runs, automationID: aid, profileID: pid, now: now) { _ in nil } == 3)
        // The workspace isn't running: only the just-launched one (it may be booting).
        #expect(ScheduledAutomationEngine.activeRunCount(runs, automationID: aid, profileID: pid, now: now) { _ in [] } == 1)
        // Another automation's runs don't count.
        #expect(ScheduledAutomationEngine.activeRunCount(runs, automationID: UUID(), profileID: pid, now: now) { _ in nil } == 0)
    }

    /// Finding (CWE-770): a watch scan records its run only after its clone
    /// (up to 15 min) or a boot — polls in between found no record, the cap
    /// counted nothing, and the same commit fired again and again.
    @Test("a launch still cloning or booting holds its slot and its event")
    @MainActor func launchUnderWayHolds() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        let held = engine.holdLaunch(aid, "commit:abc")
        let other = engine.holdLaunch(aid, nil)
        #expect(engine.launchesUnderWay(aid) == ["commit:abc", other])
        #expect(engine.launchesUnderWay(UUID()).isEmpty)
        engine.releaseLaunch(aid, held)
        #expect(engine.launchesUnderWay(aid) == [other])
        engine.releaseLaunch(aid, other)
        #expect(engine.launchesUnderWay(aid).isEmpty)
    }

    @Test("a run's tab grace starts when it was queued, not when its clone or boot began")
    func graceFromQueued() {
        var r = run(15 * 60, slug: "late")          // fired 15 min ago…
        r.queuedAt = now.addingTimeInterval(-60)    // …queued a minute ago, after its clone
        // Its tab isn't in the roster yet: it still counts.
        #expect(ScheduledAutomationEngine.activeRunCount([r], automationID: aid, profileID: pid, now: now) { _ in [] } == 1)
        r.queuedAt = nil
        #expect(ScheduledAutomationEngine.activeRunCount([r], automationID: aid, profileID: pid, now: now) { _ in [] } == 0)
    }

    @Test("one at a time by default — also for automations and watches saved before the choice")
    func defaults() throws {
        let a = ScheduledAutomation(profileID: pid, trigger: .githubCommit)
        #expect(a.maxParallelRuns == 1)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        json.removeValue(forKey: "maxParallelRuns")
        let old = try JSONDecoder().decode(ScheduledAutomation.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        #expect(old.maxParallelRuns == 1)
        var three = a; three.maxParallelRuns = 3
        #expect(try JSONDecoder().decode(ScheduledAutomation.self, from: JSONEncoder().encode(three)).maxParallelRuns == 3)

        let w = WatchedRepo(repo: "o/r", profileID: pid)
        #expect(w.maxParallelScans == 1)
        var wjson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]
        wjson.removeValue(forKey: "maxParallelScans")
        #expect(try JSONDecoder().decode(WatchedRepo.self,
                                         from: JSONSerialization.data(withJSONObject: wjson)).maxParallelScans == 1)
    }

    @Test("a watch's commit and pull-request scans run as many at once as it says")
    func watchCarriesIt() {
        var w = WatchedRepo(repo: "o/r", profileID: pid)
        w.maxParallelScans = 2
        for scan in [WatchedRepo.Scan.commits, .pullRequests] {
            #expect(RepoWatchEngine.automation(for: scan, of: w, id: UUID(), createdAt: nil).maxParallelRuns == 2)
        }
    }
}
