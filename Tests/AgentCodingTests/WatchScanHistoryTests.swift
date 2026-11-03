import Foundation
import Testing
@testable import bromure_ac

/// Board report: switching a repository watch's scans around (the weekly
/// review off, commits on their own) emptied its past runs. Saving the watch
/// removed the automation of every scan switched off, and removing an
/// automation removes its runs — the record that the code WAS reviewed.
@Suite("A watch's past runs outlive a change of scans")
struct WatchScanHistoryTests {
    @Test("a scan switched off keeps its automation, disabled; switched on again, the same one")
    func switchedOffScanKeepsItsAutomation() {
        var w = WatchedRepo(repo: "acme/api", profileID: UUID(), scans: [.fullScan, .commits])
        var stored: [UUID: ScheduledAutomation] = [:]
        func save() {
            let plan = RepoWatchEngine.automations(for: w) { stored[$0] }
            for (scan, a) in plan { stored[a.id] = a; w.automationIDs[scan.rawValue] = a.id }
        }
        save()
        let commitsID = try! #require(w.automationID(for: .commits))
        let fullID = try! #require(w.automationID(for: .fullScan))
        #expect(w.automationID(for: .pullRequests) == nil)       // never on: none

        // The weekly review and the commit scan both off.
        w.scans = []
        let plan = RepoWatchEngine.automations(for: w) { stored[$0] }
        #expect(plan[.commits]?.id == commitsID && plan[.commits]?.enabled == false)
        #expect(plan[.fullScan]?.id == fullID && plan[.fullScan]?.enabled == false)
        #expect(plan[.pullRequests] == nil)
        save()

        // Back on: the automation (and its runs) it had.
        w.scans = [.commits]
        let back = RepoWatchEngine.automations(for: w) { stored[$0] }
        #expect(back[.commits]?.id == commitsID && back[.commits]?.enabled == true)
    }

    @Test("an automation gone from the store is made anew")
    func missingAutomationIsRecreated() {
        var w = WatchedRepo(repo: "acme/api", profileID: UUID(), scans: [.commits])
        let stale = UUID()
        w.automationIDs[WatchedRepo.Scan.commits.rawValue] = stale
        let plan = RepoWatchEngine.automations(for: w) { _ in nil }
        #expect(plan[.commits] != nil && plan[.commits]?.id != stale)
        w.scans = []
        #expect(RepoWatchEngine.automations(for: w) { _ in nil }[.commits] == nil)
    }
}
