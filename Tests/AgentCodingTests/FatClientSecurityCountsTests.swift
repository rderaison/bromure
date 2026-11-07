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
        var swapRow = ev(60, engine: "Credential brokering", ck: "swap|a", pid: pid, count: 3)
        swapRow.rowID = UUID()
        history.append(swapRow)
        // Mirror: the last rows, the swap row again (the same row, by its id:
        // now 5 repeats, moved forward).
        var grown = ev(4, engine: "Credential brokering", ck: "swap|a", pid: pid, count: 5)
        grown.rowID = swapRow.rowID
        let mirror = [ev(5), grown, ev(1)]
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
        #expect(fc.contains(#""GET", "/security-timeline?hours=\(range)""#))
        #expect(fc.contains("SecurityTimeline.shared.applyHistory(rows, host: key, epoch: epoch)"))
        // A reply lands when it covers the range asked for last and is newer
        // than the one applied last.
        #expect(fc.contains("guard let self, Self.acceptsHistory(generation: generation, hours: range,"))
        #expect(fc.contains("self.securityHistoryApplied = generation"))
        let app = try src("Sources/AgentCoding/BromureAC.swift")
        #expect(app.contains("SecurityTimeline.shared.historyRows(hours: hours)"))
        #expect(app.contains("w.controller.fetchSecurityHistory(hours: hours)"))
        let view = try src("Sources/AgentCoding/SecurityTimelineView.swift")
        #expect(view.contains(".onChange(of: rangeHours) { _, h in"))
    }

    /// Finding: every fetch bumped the stamp and only the newest request's
    /// reply was taken, so a repeat for the same range that failed threw away
    /// the earlier request's good reply -- the Overview fell back to the live
    /// mirror. Now: a reply that covers the range asked for, and is newer
    /// than the last applied, lands.
    @Test("a failed repeat keeps the earlier good reply; a narrower or older one still doesn't land")
    func historyAcceptance() {
        typealias C = RemoteHostController
        // A (24 h, #1) in flight, B (24 h, #2) fails: A's reply lands.
        #expect(C.acceptsHistory(generation: 1, hours: 24, requestedHours: 24, applied: 0))
        // The window went from 24 h (#1) to 7 days (#2): #1's late reply would cut it back.
        #expect(!C.acceptsHistory(generation: 1, hours: 24, requestedHours: 168, applied: 0))
        #expect(C.acceptsHistory(generation: 2, hours: 168, requestedHours: 168, applied: 0))
        // An older reply after a newer one was applied: never.
        #expect(!C.acceptsHistory(generation: 1, hours: 168, requestedHours: 168, applied: 2))
        // All history covers any range; a bounded one never covers "all".
        #expect(C.acceptsHistory(generation: 3, hours: 0, requestedHours: 24, applied: 2))
        #expect(!C.acceptsHistory(generation: 3, hours: 720, requestedHours: 0, applied: 2))
        // A wider reply for a narrower request: fine.
        #expect(C.acceptsHistory(generation: 4, hours: 168, requestedHours: 24, applied: 3))
    }

    /// Finding: the host starts a new row when a key recurs after the
    /// coalescing window, but the client's merge dropped every older fetched
    /// row with the mirror's key -- distinct earlier decisions vanished.
    @Test("the mirror replaces exactly its own row; an older, distinct row with the same key stays")
    func sameKeyDistinctRows() {
        let pid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var a = ev(90, engine: "Credential brokering", ck: "swap|x", pid: pid, count: 4)   // an earlier row
        a.rowID = UUID()
        var b = ev(30, engine: "Credential brokering", ck: "swap|x", pid: pid, count: 2)   // a later row, same key
        b.rowID = UUID()
        var bNow = ev(2, engine: "Credential brokering", ck: "swap|x", pid: pid, count: 6)  // b, grown
        bNow.rowID = b.rowID
        let merged = SecurityTimeline.merged(history: [a, b] + (0..<10).map { ev(Double(100 + $0)) },
                                             mirror: [ev(5), bNow])
        let swaps = merged.filter { $0.coalesceKey == "swap|x" }
        #expect(swaps.count == 2)                                   // a kept, b's old copy replaced
        #expect(Set(swaps.compactMap(\.count)) == [4, 6])

        // A host that sends no ids: only a copy within the window of the
        // mirrored repeat counts as the same row.
        let old = ev(40, engine: "Credential brokering", ck: "swap|y", pid: pid, count: 1)
        let recent = ev(8, engine: "Credential brokering", ck: "swap|y", pid: pid, count: 3)
        let repeatNow = ev(1, engine: "Credential brokering", ck: "swap|y", pid: pid, count: 4)
        let legacy = SecurityTimeline.merged(history: [old, recent, ev(50)], mirror: [ev(3), repeatNow])
        #expect(legacy.filter { $0.coalesceKey == "swap|y" }.map(\.count) == [1, 4])
    }

    @MainActor
    @Test("a row keeps the id it started with through every fold, on disk and on the wire")
    func rowIdentityIsStable() throws {
        let tl = SecurityTimeline(directory: nil)
        let pid = UUID()
        func swap(_ minutesAgo: Double) -> SecurityTimeline.Event {
            var e = SecurityTimeline.Event(time: Date().addingTimeInterval(-minutesAgo * 60), engine: "Credential brokering",
                                           condition: "c", decision: "d", kind: .info, profileID: pid)
            e.coalesceKey = "swap|z"
            return e
        }
        let first = swap(9)
        tl.append(first); tl.append(swap(6)); tl.append(swap(3))
        let row = try #require(tl.events.last)
        #expect(tl.events.count == 1 && row.count == 3)
        #expect(row.stableID == first.id)
        // The wire and the disk carry it.
        let wire = try #require(tl.mirrorRows().last)
        #expect(wire["rid"] as? String == first.id.uuidString)
        let line = try #require(SecurityTimeline.line(row))
        #expect(SecurityTimeline.event(fromLine: line)?.stableID == first.id)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror([wire], host: "h")
        #expect(client.remote["h"]?.first?.stableID == first.id)
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
            .contains(#"oldestRetained: (snapshot["securityTimelineOldest"] as? Double).map(Date.init(timeIntervalSince1970:)),"#))
    }

    /// Finding: "Security timeline cutoff hides retained rows after a
    /// backward clock change". The host keeps rows in the order they came,
    /// and the client cut fetched history at the host's first row's TIME: a
    /// clock set back gives later rows earlier times, so rows the host still
    /// held (and counted) vanished on the client. Rows are numbered now, and
    /// the client prunes by number.
    @Test("rows the host still holds stay after its clock went back: pruned by order, not time")
    func clockSetBack() throws {
        // The host: three rows added one after the other, each stamped
        // earlier than the last (the clock went back between them).
        let host = SecurityTimeline(directory: nil)
        for minutesAgo in [80.0, 90, 100] { host.append(ev(minutesAgo)) }
        #expect(host.events.map(\.seq) == [0, 1, 2])
        #expect(host.oldestRetainedSeq == 0)
        let rows = host.historyRows(hours: 0)
        #expect(rows.map { $0["sq"] as? Int } == [0, 1, 2])

        // The finding's case: all three fetched, a mirror of the last one.
        let client = SecurityTimeline(directory: nil)
        client.applyHistory(rows, host: "h", epoch: host.epoch)
        client.applyMirror(Array(rows.suffix(1)), host: "h", oldestRetained: host.oldestRetained,
                           oldestSeq: host.oldestRetainedSeq, epoch: host.epoch)
        #expect(client.remote["h"]?.count == 3)
        // It used to be the 80 one alone -- still so from an older host,
        // which numbers nothing and sends only the time.
        let unnumbered = rows.map { r in r.filter { $0.key != "sq" } }
        let legacy = SecurityTimeline(directory: nil)
        legacy.applyHistory(unnumbered, host: "h")
        legacy.applyMirror(Array(unnumbered.suffix(1)), host: "h", oldestRetained: host.oldestRetained)
        #expect(legacy.remote["h"]?.count == 1)

        // The host pruned its first row: it goes, whatever the times.
        client.applyMirror(Array(rows.suffix(1)), host: "h", oldestSeq: 1, epoch: host.epoch)
        #expect(client.remote["h"]?.compactMap(\.seq) == [1, 2])
    }

    @Test("a repeat folded in is renumbered last; a host restart's numbers prune nothing until a refetch")
    func numberingAndEpochs() {
        let host = SecurityTimeline(directory: nil)
        host.append(ev(10, ck: "k")); host.append(ev(9)); host.append(ev(8, ck: "k"))
        #expect(host.events.count == 2)
        #expect(host.events.map(\.seq) == [1, 2])          // the repeat moved to the end, numbered last
        // The cap prunes by order: the first held row is the oldest number.
        for i in 0..<5000 { host.append(ev(Double(i % 7))) }
        #expect(host.events.count == 5000)
        #expect(host.oldestRetainedSeq == host.events.compactMap(\.seq).min())

        // History from the host's previous run: its numbers say nothing now.
        let client = SecurityTimeline(directory: nil)
        let rows = host.historyRows(hours: 0)
        client.applyHistory(rows, host: "h", epoch: "an earlier run")
        #expect(client.historyIsStale(host: "h", epoch: host.epoch))
        client.applyMirror(Array(rows.suffix(10)), host: "h", oldestSeq: 1_000_000, epoch: host.epoch)
        #expect(client.remote["h"]?.count == 5000)          // none dropped
        client.applyHistory(rows, host: "h", epoch: host.epoch)
        #expect(!client.historyIsStale(host: "h", epoch: host.epoch))
        #expect(!client.historyIsStale(host: "h", epoch: nil))   // an older host: nothing to compare
    }

    @Test("the host sends its first row's number and run; the client prunes and refetches by them")
    func wiredRetention() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let server = try src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains(#""securityTimelineOldestSeq": "#))
        #expect(server.contains(#""securityTimelineEpoch": "#))
        #expect(server.contains(#"if let epoch { body["epoch"] = epoch }"#))
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains(#"oldestSeq: snapshot["securityTimelineOldestSeq"] as? Int, epoch: epoch)"#))
        #expect(fc.contains("SecurityTimeline.shared.applyHistory(rows, host: key, epoch: epoch)"))
        #expect(fc.contains("SecurityTimeline.shared.historyIsStale(host: securityMirrorKey, epoch: epoch)"))
        #expect(try src("Sources/AgentCoding/BromureAC.swift")
            .contains("(SecurityTimeline.shared.oldestRetainedSeq, SecurityTimeline.shared.epoch)"))
    }
}
