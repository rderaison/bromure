import Foundation
import Testing
@testable import bromure_ac

/// A configured host that synced its security timeline by deltas, later run
/// on an older version that only mirrors: its totals, sync mark and "no
/// history needed" state were kept, so the Overview showed the old run's
/// totals and the window's history never loaded. Finding: "Older host
/// fallback keeps stale delta totals and disables history fetching".
@Suite("Security timeline: older-host fallback")
@MainActor
struct SecurityOlderHostFallbackTests {
    private func head(_ epoch: String) -> [String: Any] {
        ["epoch": epoch, "last": 3, "oldest": 1,
         "totals": ["24": ["blocked": 7, "allowed": 2]]]
    }
    private let row: [String: Any] = ["time": 1_700_000_000.0, "engine": "firewall", "kind": "blocked",
                                      "summary": "x"]

    @Test("falling back to the mirror drops the delta totals and fetches the history asked for")
    func fallback() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let key = c.securityMirrorKey
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimelineHead": head("e1")])
        #expect(c.securityDeltaHost)
        #expect(SecurityTimeline.shared.remoteTotals[key]?[24]?.blocked == 7)

        // The window asks for its history: a delta host needs none.
        let before = c.securityHistoryGeneration
        c.fetchSecurityHistory(hours: 24)
        #expect(c.securityHistoryGeneration == before, "no fetch from a delta host")

        // Let the delta fetch (to a closed port) finish before falling back.
        c.securityHistoryInFlight = 0
        c.securityHistoryRetryAt = nil
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimeline": [row]])
        #expect(!c.securityDeltaHost)
        #expect(SecurityTimeline.shared.remoteTotals[key] == nil, "the old run's totals are gone")
        #expect(c.securityHistoryGeneration == before + 1, "the history asked for is fetched")
        #expect(c.securityHistoryHours == 24)
    }

    @Test("a fetch still under way at the fallback doesn't lose the history owed")
    func owedSurvivesInFlight() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimelineHead": head("e2")])
        c.fetchSecurityHistory(hours: 0)
        let before = c.securityHistoryGeneration
        c.securityHistoryInFlight = 1
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimeline": [row]])
        #expect(c.securityHistoryGeneration == before, "one at a time")
        c.securityHistoryInFlight = 0
        c.securityHistoryRetryAt = nil
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimeline": [row]])
        #expect(c.securityHistoryGeneration == before + 1, "fetched by the next snapshot")
    }

    @Test("a host that was never asked for history isn't fetched on fallback")
    func notAsked() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimelineHead": head("e3")])
        c.securityHistoryInFlight = 0
        c.securityHistoryRetryAt = nil
        c.applyPushedSnapshot(["workspaces": [], "vms": [], "securityTimeline": [row]])
        #expect(c.securityHistoryGeneration == 0)
    }
}
