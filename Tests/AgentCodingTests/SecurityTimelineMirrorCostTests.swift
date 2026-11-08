import Foundation
import Observation
import Testing
@testable import bromure_ac

/// A fat client gets the host's security timeline with every snapshot,
/// several a second. Each one was decoded (and every row's secrets redacted)
/// again and published as all-new events with new ids: the open timeline
/// window redrew from scratch and its table replaced every row each time --
/// in a sample taken while typing, most of the main thread.
@MainActor
@Suite("Security Timeline: an unchanged mirror changes nothing")
struct SecurityTimelineMirrorCostTests {
    private func rows(_ n: Int, from host: SecurityTimeline) -> [[String: Any]] {
        host.clear()
        let pid = UUID()
        for i in 0..<n {
            host.append(.init(time: Date(timeIntervalSince1970: 1_756_000_000 + Double(i)), engine: "Firewall",
                              condition: "host\(i).example:443 tcp", decision: "blocked", kind: .blocked, profileID: pid))
        }
        return host.mirrorRows()
    }

    /// Whether reading `remote` sees a change while `body` runs.
    private func publishes(_ tl: SecurityTimeline, _ body: () -> Void) -> Bool {
        var changed = false
        withObservationTracking { _ = tl.remote } onChange: { changed = true }
        body()
        return changed
    }

    @Test("the same mirror again: not republished, the events (and their ids) as they were")
    func sameMirror() {
        let host = SecurityTimeline(directory: nil)
        let r = rows(5, from: host)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e1")
        let ids = client.remote["ark"]?.map(\.id)
        #expect(ids?.count == 5)
        #expect(!publishes(client) { client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e1") })
        #expect(client.remote["ark"]?.map(\.id) == ids)
        host.clear()
    }

    @Test("one new row: published, the others keep their ids")
    func oneNewRow() {
        let host = SecurityTimeline(directory: nil)
        let first = rows(5, from: host)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(first, host: "ark", oldestSeq: 1, epoch: "e1")
        let before = client.remote["ark"] ?? []
        host.append(.init(time: Date(timeIntervalSince1970: 1_756_000_100), engine: "Firewall",
                          condition: "new.example:443 tcp", decision: "blocked", kind: .blocked, profileID: UUID()))
        let next = host.mirrorRows()
        #expect(publishes(client) { client.applyMirror(next, host: "ark", oldestSeq: 1, epoch: "e1") })
        let after = client.remote["ark"] ?? []
        #expect(after.count == 6)
        #expect(Array(after.prefix(5).map(\.id)) == before.map(\.id), "unchanged rows are the same events")
        #expect(after.last?.condition == "new.example:443 tcp")
        host.clear()
    }

    @Test("other retention words, a fetched history or a clear: applied again")
    func reapplied() {
        let host = SecurityTimeline(directory: nil)
        let r = rows(3, from: host)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e1")
        #expect(publishes(client) { client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e2") }, "another run of the host")
        client.applyHistory(r, host: "ark", epoch: "e2")
        #expect(publishes(client) { client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e2") }, "after a history fetch")
        client.clear()
        #expect(client.remote["ark"] == nil)
        client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e2")
        #expect(client.remote["ark"]?.count == 3, "a clear doesn't keep the next mirror out")
        host.clear()
    }
}
