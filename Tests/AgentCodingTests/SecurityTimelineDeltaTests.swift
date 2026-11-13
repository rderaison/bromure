import Foundation
import Testing
@testable import bromure_ac

/// A fat client got the host's last 750 security rows with every snapshot,
/// several a second, and counted the Overview from them. Now the snapshot
/// carries the timeline's head; the client fetches only the rows it hasn't
/// got and shows the host's own totals.
@MainActor
@Suite("Security Timeline: fat-client deltas and the host's totals")
struct SecurityTimelineDeltaTests {
    private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func ev(_ i: Int, kind: SecurityTimeline.Decision = .blocked, engine: String = "Firewall",
                    ck: String? = nil, ago: TimeInterval = 60) -> SecurityTimeline.Event {
        var e = SecurityTimeline.Event(time: Date().addingTimeInterval(-ago), engine: engine,
                                       condition: "host\(i).example:443 tcp", decision: "d", kind: kind, profileID: pid)
        e.coalesceKey = ck
        return e
    }

    /// The body the route would send, through JSON as on the wire.
    private func wire(_ d: [String: Any]) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: d))) as? [String: Any] ?? [:]
    }

    private func sync(_ client: SecurityTimeline, from host: SecurityTimeline, key: String = "ark") {
        let q = client.deltaQuery(host: key)
        client.applyDelta(wire(host.deltaBody(after: q.after, epoch: q.epoch)), host: key)
    }

    @Test("first a full copy, then only the new rows; held rows keep their ids")
    func deltas() {
        let host = SecurityTimeline(directory: nil)
        for i in 0..<1000 { host.append(ev(i)) }
        let client = SecurityTimeline(directory: nil)
        #expect(client.deltaQuery(host: "ark").after == nil)
        sync(client, from: host)
        #expect(client.remote["ark"]?.count == 1000, "all it holds, not the mirror's 750")
        let ids = client.remote["ark"]?.map(\.id)

        host.append(ev(1000)); host.append(ev(1001))
        let q = client.deltaQuery(host: "ark")
        let body = host.deltaBody(after: q.after, epoch: q.epoch)
        #expect((body["rows"] as? [[String: Any]])?.count == 2, "only what's new")
        #expect(body["delta"] as? Bool == true)
        client.applyDelta(wire(body), host: "ark")
        let after = client.remote["ark"] ?? []
        #expect(after.count == 1002)
        #expect(Array(after.prefix(1000).map(\.id)) == ids)
        #expect(after.last?.condition == "host1001.example:443 tcp")
        #expect(!client.needsDelta(host: "ark", head: SecurityTimeline.SyncMark(wire(host.head()))!))
    }

    @Test("a repeat moves its row to the end: sent again, it replaces the copy")
    func coalescedRepeat() {
        let host = SecurityTimeline(directory: nil)
        host.append(ev(1, engine: "Credential brokering", ck: "swap|a"))
        host.append(ev(2))
        let client = SecurityTimeline(directory: nil)
        sync(client, from: host)
        host.append(ev(1, engine: "Credential brokering", ck: "swap|a", ago: 30))
        #expect(host.events.count == 2)
        sync(client, from: host)
        let rows = client.remote["ark"] ?? []
        #expect(rows.count == 2, "the same row, not a second one")
        #expect(rows.last?.count == 2)
        #expect(rows.map(\.condition) == host.events.map(\.condition))
    }

    @Test("rows the host no longer holds go; a restarted host's replace the copy")
    func pruneAndRestart() {
        let host = SecurityTimeline(directory: nil)
        for i in 0..<5 { host.append(ev(i)) }
        let client = SecurityTimeline(directory: nil)
        sync(client, from: host)
        host.clear()
        #expect(client.needsDelta(host: "ark", head: SecurityTimeline.SyncMark(wire(host.head()))!))
        sync(client, from: host)
        #expect(client.remote["ark"]?.isEmpty == true, "the host holds none")

        let restarted = SecurityTimeline(directory: nil)   // another run: another epoch
        for i in 0..<3 { restarted.append(ev(i)) }
        let q = client.deltaQuery(host: "ark")
        let body = restarted.deltaBody(after: q.after, epoch: q.epoch)
        #expect(body["delta"] as? Bool == false)
        client.applyDelta(wire(body), host: "ark")
        #expect(client.remote["ark"]?.count == 3)
    }

    @Test("nothing new: the copy isn't republished")
    func quiet() {
        let host = SecurityTimeline(directory: nil)
        for i in 0..<3 { host.append(ev(i)) }
        let client = SecurityTimeline(directory: nil)
        sync(client, from: host)
        var changed = false
        withObservationTracking { _ = client.remote } onChange: { changed = true }
        sync(client, from: host)
        #expect(!changed)
    }

    @Test("the tiles show the host's totals as it counts them; other rows are counted here")
    func totals() {
        let host = SecurityTimeline(directory: nil)
        for i in 0..<4 { host.append(ev(i)) }
        host.append(ev(9, kind: .allowed, ago: 3 * 3600))           // outside the last hour
        host.append(ev(10, engine: NSLocalizedString("PII protection", comment: "Security Timeline engine"), ago: 10))
        let head = wire(host.head())
        let byRange = SecurityTimeline.Totals.byRange(wire: head["totals"] as? [String: Any])!
        #expect(byRange[1]?.blocked == 5)
        #expect(byRange[1]?.allowed == 0)
        #expect(byRange[24]?.allowed == 1)
        #expect(byRange[0]?.pii == 1)

        // A client whose copy is short of rows still shows the host's numbers.
        let client = SecurityTimeline(directory: nil)
        client.append(ev(50))                                        // this Mac's own
        client.applyRemoteTotals(byRange, host: "ark")
        let t = SecurityOverview.totals(client.allEvents, machine: nil, rangeHours: 24, remote: client.remoteTotals)
        #expect(t.blocked == 6)
        #expect(t.allowed == 1)
        #expect(SecurityOverview.totals(client.allEvents, machine: "", rangeHours: 24, remote: client.remoteTotals).blocked == 1)
        #expect(SecurityOverview.totals(client.allEvents, machine: "ark", rangeHours: 24, remote: client.remoteTotals).blocked == 5)
    }

    @Test("Totals count as the tiles did: occurrences, swap counts, rows")
    func tally() {
        var swap = ev(1, kind: .info, engine: NSLocalizedString("Credential brokering", comment: "Security Timeline engine"))
        swap.count = 4
        var denied = ev(2, engine: NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"))
        denied.denials = 3
        let t = SecurityTimeline.Totals.of([swap, denied, ev(3, engine: NSLocalizedString("Supply chain", comment: "Security Timeline engine"))])
        #expect(t.credential == 4)
        #expect(t.sandbox == 3 && t.sandboxSeen)
        #expect(t.supplyChain == 1)
        #expect(t.blocked == 3 + 1)
    }

    @Test("wired: the snapshot carries the head, the route answers `after`, the client fetches deltas")
    func wired() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding")
        let server = try String(contentsOf: src.appendingPathComponent("AutomationServer.swift"), encoding: .utf8)
        let app = try String(contentsOf: src.appendingPathComponent("BromureAC.swift"), encoding: .utf8)
        let client = try String(contentsOf: src.appendingPathComponent("FatClientController.swift"), encoding: .utf8)
        #expect(server.contains(#""securityTimelineHead": self.onSecurityTimelineHead?()"#))
        #expect(server.contains("self.onSecurityDelta?(after, afterEpoch)"))
        #expect(app.contains("SecurityTimeline.shared.deltaBody(after: after, epoch: epoch)"))
        #expect(client.contains(#"snapshot["securityTimelineHead"]"#))
        #expect(client.contains("SecurityTimeline.shared.applyDelta(body, host: key)"))
    }
}
