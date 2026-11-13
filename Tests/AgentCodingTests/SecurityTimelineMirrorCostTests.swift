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

    @Test("rows key apart: a mirror's rows don't share one hash (NSDictionary's is its count)")
    func rowKeysSpread() {
        let host = SecurityTimeline(directory: nil)
        let r = rows(750, from: host)
        #expect(Set(r.map { ($0 as NSDictionary).hash }).count == 1, "the trap: NSDictionary hashes by count")
        let keys = r.map { SecurityTimeline.MirrorRowKey($0) }
        #expect(Set(keys.map(\.hashValue)).count == 750)
        #expect(Set(keys).count == 750)
        // A copy of a row (as the next snapshot brings it) is the same key.
        let copy = (try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: r[7]))) as? [String: Any]
        #expect(copy.map { SecurityTimeline.MirrorRowKey($0) } == keys[7])
        host.clear()
    }

    @Test("a full mirror with one new row applies in well under a frame's worth of lookups")
    func fullMirrorIsCheap() {
        let host = SecurityTimeline(directory: nil)
        var r = rows(750, from: host)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e1")
        host.append(.init(time: Date(timeIntervalSince1970: 1_756_100_000), engine: "Firewall",
                          condition: "new.example:443 tcp", decision: "blocked", kind: .blocked, profileID: UUID()))
        r = host.mirrorRows()
        let start = Date()
        client.applyMirror(r, host: "ark", oldestSeq: 1, epoch: "e1")
        let took = Date().timeIntervalSince(start)
        // The mirror is capped at 750: the oldest row made room for the new one.
        #expect(client.remote["ark"]?.count == 750)
        #expect(client.remote["ark"]?.last?.condition == "new.example:443 tcp")
        print("fullMirrorIsCheap took \(took)s")
        #expect(took < 0.25, "took \(took)s")
        host.clear()
    }

    @Test("two identical rows in one mirror are two events, each its own id")
    func duplicateRows() {
        let host = SecurityTimeline(directory: nil)
        let r = rows(1, from: host)
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(r + r, host: "ark")
        let ids = client.remote["ark"]?.map(\.id) ?? []
        #expect(Set(ids).count == ids.count)
        host.clear()
    }
}
