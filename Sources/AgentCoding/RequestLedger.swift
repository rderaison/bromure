import Foundation

/// What the fat client's control requests cost over a remote link, per
/// route: how many, how many bytes each way, and where the time went —
/// `dial` (getting a channel), `wait` (request sent → first reply byte:
/// round trip + server work) and `total`. Read it to tell a slow link's
/// bandwidth from its round trips.
///
/// Written every few minutes (when there was traffic) to
/// remote-client/link-report.json and the unified log
/// (`log show --predicate 'subsystem == "io.bromure.fatclient"' --last 1h`),
/// and served by the `request-report` debug action.
final class RequestLedger: @unchecked Sendable {
    static let shared = RequestLedger()

    struct Entry: Codable {
        var count = 0
        var bytesOut = 0
        var bytesIn = 0
        var dialMs = 0.0
        var waitMs = 0.0
        var totalMs = 0.0
        var maxTotalMs = 0.0
        var failures = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var since = Date()
    private var lastFlush = Date()
    /// Where the periodic report goes (set by the macOS app).
    var reportURL: URL?
    static let flushInterval: TimeInterval = 300

    /// "GET /vms/:id/exec" — ids and numbers folded so a route aggregates.
    static func routeKey(_ method: String, _ path: String) -> String {
        let bare = path.split(separator: "?").first.map(String.init) ?? path
        let parts = bare.split(separator: "/").prefix(4).map { seg -> String in
            let s = String(seg)
            if UUID(uuidString: s) != nil || s.allSatisfy(\.isNumber) { return ":id" }
            return s.count > 40 ? ":x" : s
        }
        return method + " /" + parts.joined(separator: "/")
    }

    func record(method: String, path: String, bytesOut: Int, bytesIn: Int,
                dial: TimeInterval, wait: TimeInterval?, total: TimeInterval, failed: Bool) {
        let key = Self.routeKey(method, path)
        lock.lock()
        var e = entries[key] ?? Entry()
        e.count += 1
        e.bytesOut += bytesOut
        e.bytesIn += bytesIn
        e.dialMs += dial * 1000
        e.waitMs += (wait ?? total) * 1000
        e.totalMs += total * 1000
        e.maxTotalMs = max(e.maxTotalMs, total * 1000)
        if failed { e.failures += 1 }
        entries[key] = e
        let due = Date().timeIntervalSince(lastFlush) >= Self.flushInterval
        if due { lastFlush = Date() }
        lock.unlock()
        if due { flush() }
    }

    /// The aggregates, slowest total first, with per-request means.
    func report() -> [String: Any] {
        lock.lock()
        let snapshot = entries
        let start = since
        lock.unlock()
        let rows: [[String: Any]] = snapshot.sorted { $0.value.totalMs > $1.value.totalMs }.map { k, e in
            let n = Double(max(1, e.count))
            return ["route": k, "count": e.count, "failures": e.failures,
                    "bytesIn": e.bytesIn, "bytesOut": e.bytesOut,
                    "meanDialMs": Int(e.dialMs / n), "meanWaitMs": Int(e.waitMs / n),
                    "meanTotalMs": Int(e.totalMs / n), "maxTotalMs": Int(e.maxTotalMs),
                    "sumTotalS": Int(e.totalMs / 1000)]
        }
        let totalIn = snapshot.values.reduce(0) { $0 + $1.bytesIn }
        let totalOut = snapshot.values.reduce(0) { $0 + $1.bytesOut }
        let requests = snapshot.values.reduce(0) { $0 + $1.count }
        return ["since": ISO8601DateFormatter().string(from: start),
                "seconds": Int(Date().timeIntervalSince(start)),
                "requests": requests, "bytesIn": totalIn, "bytesOut": totalOut,
                "routes": rows]
    }

    func reset() {
        lock.lock()
        entries = [:]
        since = Date()
        lock.unlock()
    }

    func flush() {
        let r = report()
        guard (r["requests"] as? Int ?? 0) > 0 else { return }
        if let url = reportURL,
           let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        let top = (r["routes"] as? [[String: Any]] ?? []).prefix(8).map {
            "\($0["route"] ?? "") ×\($0["count"] ?? 0) total \($0["meanTotalMs"] ?? 0)ms "
                + "(dial \($0["meanDialMs"] ?? 0) wait \($0["meanWaitMs"] ?? 0)) in \($0["bytesIn"] ?? 0)B"
        }
        FatClientLog.log("request report: \(r["requests"] ?? 0) requests in \(r["seconds"] ?? 0)s, "
            + "\(r["bytesIn"] ?? 0)B in / \(r["bytesOut"] ?? 0)B out — " + top.joined(separator: "; "))
    }
}
