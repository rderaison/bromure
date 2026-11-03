import Foundation
import Testing
@testable import bromure_ac

@Suite("Security window: grouped blocks, search keys, history settings")
struct SecurityWindowQoLTests {
    private func block(_ engine: String, _ condition: String, ws: UUID, at t: TimeInterval) -> SecurityTimeline.Event {
        .init(time: Date(timeIntervalSince1970: t), engine: engine, condition: condition, decision: "deny",
              kind: .blocked, profileID: ws)
    }

    @Test("Latest blocks fold repeats into one row: its count, its last time, the workspaces it hit")
    func groups() {
        let a = UUID(), b = UUID()
        var events = (0..<101).map { block("Firewall", "telemetry.example.net:443 tcp", ws: $0 % 2 == 0 ? a : b, at: Double($0)) }
        events.append(block("Firewall", "evil.example:443 tcp", ws: a, at: 50))
        let groups = SecurityOverview.blockGroups(events)
        #expect(groups.count == 2)
        let noisy = groups.first { $0.latest.condition.hasPrefix("telemetry") }!
        #expect(noisy.count == 101)
        #expect(noisy.latest.time == Date(timeIntervalSince1970: 100))
        #expect(noisy.workspaces == [a, b])
        // Newest group first, and a quiet block is still shown.
        #expect(groups.first?.latest.condition.hasPrefix("telemetry") == true)
        #expect(groups.contains { $0.latest.condition.hasPrefix("evil") })
    }

    @Test("A guest-sandbox denial groups and searches by what was tried, not the pid")
    func sandboxKey() {
        let ws = UUID()
        let e1 = block("Guest sandbox", "bash (pid 412) — exec /opt/grok/bin/grok", ws: ws, at: 1)
        let e2 = block("Guest sandbox", "bash (pid 980) — exec /opt/grok/bin/grok ×3", ws: ws, at: 2)
        #expect(e1.searchKey == "exec /opt/grok/bin/grok")
        #expect(e2.searchKey == e1.searchKey)
        #expect(SecurityOverview.blockGroups([e1, e2]).count == 1)
        #expect(block("Firewall", "evil.example:443 tcp", ws: ws, at: 3).searchKey == "evil.example:443 tcp")
    }

    /// Finding (CWE-670): "Clicking a Security Overview block searches by an
    /// unanchored substring". The row opened the Timeline with its key in the
    /// search box, which kept any blocked row *containing* it: clone matched
    /// clone3, example.com matched notexample.com.
    @Test("A block is opened as itself: same engine and whole key, never a substring of another")
    func blockOpensExactly() {
        let ws = UUID()
        func key(_ engine: String, _ condition: String) -> String {
            SecurityOverview.blockKey(block(engine, condition, ws: ws, at: 0))
        }
        // Distinct blocks whose keys contain one another.
        #expect(key("Firewall", "example.com:443 tcp") != key("Firewall", "notexample.com:443 tcp"))
        #expect(key("Firewall", "github.com:443 tcp") != key("Firewall", "api.github.com:443 tcp"))
        #expect(key("Guest sandbox", "a (pid 1) — syscall clone") != key("Guest sandbox", "a (pid 1) — syscall clone3"))
        #expect(key("Guest sandbox", "ls (pid 2) — exec /bin/ls") != key("Guest sandbox", "ls (pid 2) — exec /bin/lsblk"))
        // The same block across pids and repeat counts, and pinned to its engine.
        #expect(key("Guest sandbox", "a (pid 1) — syscall clone") == key("Guest sandbox", "b (pid 9) — syscall clone ×4"))
        #expect(key("Firewall", "evil.example:443 tcp") != key("PII protection", "evil.example:443 tcp"))
        // What the row opens with: the block's own key, its search text shown.
        let e = block("Guest sandbox", "a (pid 1) — syscall clone", ws: ws, at: 0)
        let f = SecurityTimelineFilter(outcome: .blocked, query: e.searchKey, block: SecurityOverview.blockKey(e))
        #expect(f.block == SecurityOverview.blockKey(e) && f.query == "syscall clone")
    }

    /// Finding (CWE-670): "Sandbox block counts ignore the ×N denial
    /// multiplier". The sentry folds identical denials (×3 on the first row,
    /// "×47 more in the last minute" on the follow-up); the group and the
    /// tile added one per row.
    @Test("Folded guest-sandbox denials count what they stand for, in the group, the tiles and the mirror")
    @MainActor func sandboxDenialCounts() throws {
        let ws = UUID()
        func denial(_ extra: [String: AnyJSON]) throws -> SecurityTimeline.Event {
            var d: [String: AnyJSON] = ["category": .string("sandbox_denial"), "kind": .string("file_open_denied"),
                                        "exe": .string("python3"), "pid": .int(4242),
                                        "op": .string("create"), "path": .string("/etc/cron.d/x")]
            d.merge(extra) { $1 }
            return try #require(SecurityTimeline.map(profileID: ws, eventType: "sentry.event", eventData: d, now: Date()))
        }
        let first = try denial(["count": .int(3)])
        let more = try denial(["count": .int(47), "repeat": .bool(true)])
        let single = try denial([:])
        #expect(first.occurrences == 3 && more.occurrences == 47 && single.occurrences == 1)
        let groups = SecurityOverview.blockGroups([first, more, single])
        #expect(groups.count == 1)
        #expect(groups.first?.count == 51)
        // The tile's sum.
        #expect([first, more, single].reduce(0) { $0 + $1.occurrences } == 51)
        // The fat client's mirror keeps it.
        let tl = SecurityTimeline(directory: nil)
        tl.applyMirror([["engine": first.engine, "condition": first.condition, "decision": first.decision,
                         "kind": "blocked", "profileID": ws.uuidString, "dn": 3]], host: "ark")
        #expect(tl.allEvents.first { $0.machine == "ark" }?.occurrences == 3)
        // …and so does the on-disk log the overview is rebuilt from at launch.
        let line = try #require(SecurityTimeline.line(more))
        #expect(SecurityTimeline.event(fromLine: line.dropLast())?.occurrences == 47)
    }

    @Test("History settings: unset means 90 days and 24 hours; 0 keeps everything")
    func settings() {
        let d = UserDefaults.standard
        let savedR = d.object(forKey: SecurityTimeline.retentionKey), savedH = d.object(forKey: SecurityTimeline.defaultRangeKey)
        defer {
            if let savedR { d.set(savedR, forKey: SecurityTimeline.retentionKey) } else { d.removeObject(forKey: SecurityTimeline.retentionKey) }
            if let savedH { d.set(savedH, forKey: SecurityTimeline.defaultRangeKey) } else { d.removeObject(forKey: SecurityTimeline.defaultRangeKey) }
        }
        d.removeObject(forKey: SecurityTimeline.retentionKey)
        d.removeObject(forKey: SecurityTimeline.defaultRangeKey)
        #expect(SecurityTimeline.retentionDays == 90)
        #expect(SecurityTimeline.defaultRangeHours == 24)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec-prune-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("2020-01-01.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        d.set(0, forKey: SecurityTimeline.retentionKey)
        SecurityTimeline.prune(dir)
        #expect(FileManager.default.fileExists(atPath: old.path))
        d.set(30, forKey: SecurityTimeline.retentionKey)
        SecurityTimeline.prune(dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
