import Foundation
import Testing
@testable import bromure_ac

/// Board report: a fat client's Security window didn't show the server's
/// numbers. The host's /state mirror carries only its last 750 rows; the
/// server's own window counts everything it holds (up to 5000). The window
/// now fetches the host's history for its range, and the live mirror merges
/// into it instead of replacing it.
@MainActor
@Suite("A fat client's Security window counts what the server's does")
struct FatClientSecurityCountsTests {
    private func ev(_ minutesAgo: Double, engine: String = "Firewall", ck: String? = nil,
                    pid: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, count: Int? = nil) -> SecurityTimeline.Event {
        var e = SecurityTimeline.Event(time: Date().addingTimeInterval(-minutesAgo * 60), engine: engine,
                                       condition: "c", decision: "d", kind: .blocked, profileID: pid)
        e.coalesceKey = ck
        e.count = count
        return e
    }

    @Test("the host serves every row in the range, not just the mirror's last 750")
    func historyCoversTheRange() {
        let tl = SecurityTimeline(directory: nil)
        for i in 0..<2000 { tl.append(ev(Double(i % 600))) }        // all within 10 hours
        tl.append(ev(48 * 60))                                       // two days ago
        #expect(tl.mirrorRows().count == 750)
        #expect(tl.historyRows(hours: 24).count == 2000)
        #expect(tl.historyRows(hours: 0).count == 2001)
    }

    @Test("the live mirror merges into the fetched history; a coalesced row counts once")
    func mirrorMerges() {
        let pid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        // Fetched: 100 old rows, one coalesced swap row (3 repeats) from an hour ago.
        var history = (0..<100).map { ev(Double(120 + $0)) }
        history.append(ev(60, engine: "Credential brokering", ck: "swap|a", pid: pid, count: 3))
        // Mirror: the last rows, the swap row again (now 5 repeats, moved forward).
        let mirror = [ev(5), ev(4, engine: "Credential brokering", ck: "swap|a", pid: pid, count: 5), ev(1)]
        let merged = SecurityTimeline.merged(history: history, mirror: mirror)
        #expect(merged.count == 103)                                 // 100 old + 3 mirrored; old swap copy dropped
        let swaps = merged.filter { $0.coalesceKey == "swap|a" }
        #expect(swaps.count == 1 && swaps.first?.count == 5)
        #expect(merged.map(\.time) == merged.map(\.time).sorted())
        // An empty mirror: the host holds nothing.
        #expect(SecurityTimeline.merged(history: history, mirror: []).isEmpty)
        // No history fetched: the mirror as it is (the window never opened).
        #expect(SecurityTimeline.merged(history: [], mirror: mirror).count == 3)

        // Through the timeline: a mirror merges into the fetched history only,
        // never into an earlier mirror.
        let tl = SecurityTimeline(directory: nil)
        func row(_ minutesAgo: Double) -> [String: Any] {
            ["engine": "Firewall", "condition": "c", "decision": "d", "kind": "blocked",
             "t": Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970, "profileID": pid.uuidString]
        }
        tl.applyMirror([row(300), row(200)], host: "h")
        tl.applyMirror([row(10)], host: "h")
        #expect(tl.remote["h"]?.count == 1)                          // no fetch: replaced, as before
        tl.applyHistory((0..<50).map { row(Double(100 + $0)) }, host: "h")
        tl.applyMirror([row(10), row(5)], host: "h")
        #expect(tl.remote["h"]?.count == 52)                         // 50 fetched + 2 live
        tl.applyMirror([], host: "h")
        #expect(tl.remote["h"]?.isEmpty == true)
        tl.applyMirror([row(1)], host: "h")
        #expect(tl.remote["h"]?.count == 1)                          // the history went with it
    }

    @Test("the window fetches enough for both its Timeline range and its Overview")
    func historyHours() {
        typealias V = SecurityTimelineView
        #expect(V.historyHours(range: 1, overview: 24) == 24)
        #expect(V.historyHours(range: 168, overview: 24) == 168)
        #expect(V.historyHours(range: 0, overview: 24) == 0)
        #expect(V.historyHours(range: 24, overview: 0) == 0)
    }

    @Test("wired: the route, the fetch and the window")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let server = try src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains(#"case ("GET", let p) where p == "/security-timeline" || p.hasPrefix("/security-timeline?"):"#))
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains(#""GET", "/security-timeline?hours=\(max(0, hours))""#))
        #expect(fc.contains("SecurityTimeline.shared.applyHistory(rows, host: key)"))
        // Only the latest fetch's reply lands (review: a slow 24 h reply
        // after a 7-day one cut the history back).
        #expect(fc.contains("guard let self, Self.isLatest(generation, of: self.securityHistoryGeneration) else { return }"))
        #expect(RemoteHostController.isLatest(3, of: 3) && !RemoteHostController.isLatest(2, of: 3))
        let app = try src("Sources/AgentCoding/BromureAC.swift")
        #expect(app.contains("SecurityTimeline.shared.historyRows(hours: hours)"))
        #expect(app.contains("w.controller.fetchSecurityHistory(hours: hours)"))
        let view = try src("Sources/AgentCoding/SecurityTimelineView.swift")
        #expect(view.contains(".onChange(of: rangeHours) { _, h in"))
    }

    /// Finding: the host keeps 5000 rows and prunes its oldest as events
    /// come; the client kept every fetched row older than the mirror, so its
    /// bucket grew to 6000 and counted up to 1000 the host no longer held.
    @Test("rows the host pruned leave the client too; the bucket never exceeds the host's cap")
    func prunedRowsLeave() {
        let pid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let history = (0..<100).map { ev(Double(200 + $0)) }            // 200…299 minutes ago
        let mirror = [ev(10), ev(5)]
        // The host now holds nothing older than 250 and a half minutes (between rows).
        let cutoff = Date().addingTimeInterval(-250.5 * 60)
        let merged = SecurityTimeline.merged(history: history, mirror: mirror, oldestRetained: cutoff)
        #expect(merged.allSatisfy { $0.time >= cutoff })
        #expect(merged.count == 51 + 2)                                  // 200…250 kept, plus the mirror
        // No marker (an older host): capped at the host's own size.
        let big = (0..<6000).map { ev(Double(100 + $0) / 10) }
        #expect(SecurityTimeline.merged(history: big, mirror: [ev(1)]).count <= 5000)

        // Through the timeline: the fetched history is pruned too, so a later
        // mirror without the marker doesn't bring the rows back.
        let tl = SecurityTimeline(directory: nil)
        func row(_ minutesAgo: Double) -> [String: Any] {
            ["engine": "Firewall", "condition": "c", "decision": "d", "kind": "blocked",
             "t": Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970, "profileID": pid.uuidString]
        }
        tl.applyHistory((0..<100).map { row(Double(200 + $0)) }, host: "h")
        tl.applyMirror([row(10)], host: "h", oldestRetained: cutoff)
        #expect(tl.remote["h"]?.count == 52)
        tl.applyMirror([row(9)], host: "h")
        #expect(tl.remote["h"]?.count == 52)
    }

    @Test("the host sends its oldest retained row, as JSON; the client passes it on")
    func hostSendsOldest() throws {
        let tl = SecurityTimeline(directory: nil)
        #expect(tl.oldestRetained == nil)
        let first = ev(30)
        tl.append(first); tl.append(ev(20))
        #expect(tl.oldestRetained == first.time)
        #expect(JSONSerialization.isValidJSONObject(["o": ACAutomationServer.jsonNumberOrNull(nil)]))
        #expect(JSONSerialization.isValidJSONObject(["o": ACAutomationServer.jsonNumberOrNull(1_700_000_000.5)]))
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        #expect(try src("Sources/AgentCoding/AutomationServer.swift")
            .contains(#""securityTimelineOldest": Self.jsonNumberOrNull(self.onSecurityTimelineOldest?() ?? nil),"#))
        #expect(try src("Sources/AgentCoding/FatClientController.swift")
            .contains(#"oldestRetained: (snapshot["securityTimelineOldest"] as? Double).map(Date.init(timeIntervalSince1970:)))"#))
    }
}
