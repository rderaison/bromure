import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto   // swift-crypto: the same API off Apple platforms
#endif
import Observation

/// A live, on-device record of what Bromure's security engines actually did —
/// every credential swap, firewall verdict, package check, prompt-injection
/// scan, and credential use — surfaced as a single chronological table in the
/// Security Timeline window.
///
/// Fed by tapping `BACEventEmitter` BEFORE its cloud-upload gate, so it works
/// for EVERY workspace (enrolled or not, private or not): the window is a local
/// view of the user's own machine, distinct from the enrolled-only telemetry
/// that goes to bromure.io.
///
/// Always recorded: every event this Mac's engines produce is appended to a
/// daily log on disk (`security-timeline/<yyyy-MM-dd>.jsonl` in the support
/// folder, kept 90 days) and the window reloads the most recent ones at
/// launch — it used to be memory-only and came up empty after every restart.
/// A fat client's mirrored hosts are kept apart (`remote`), each in its own
/// bucket: they no longer overwrite this Mac's own events.
@MainActor
@Observable
public final class SecurityTimeline {
    public static let shared = SecurityTimeline(directory: SecurityTimeline.defaultDirectory())

    /// How a decision reads at a glance — drives the row's colour.
    public enum Decision: Sendable, Equatable {
        case allowed    // let through / signed / passed (green)
        case blocked    // denied / rejected / stripped  (red)
        case info       // a transformation, neither pass nor block (blue)

        /// Stable string used on the fat-client mirror wire.
        var wire: String {
            switch self {
            case .allowed: return "allowed"
            case .blocked: return "blocked"
            case .info:    return "info"
            }
        }
        init(wire: String) {
            switch wire {
            case "blocked": self = .blocked
            case "allowed": self = .allowed
            default:        self = .info
            }
        }
    }

    public struct Event: Identifiable, Sendable {
        public let id = UUID()
        /// The row this event stands for across coalescing, restarts and the
        /// fat-client mirror: the id of the event the row started as (nil =
        /// this one's). A coalesced row is a new Event each time it folds a
        /// repeat; this stays.
        public var rowID: UUID? = nil
        public var stableID: UUID { rowID ?? id }
        /// Where the row sits in its host's timeline: a number that only
        /// grows as rows are added (a repeat folded in moves the row to the
        /// end, with a new one). Retention follows this order, not the
        /// rows' times, which a clock set back makes go backwards. nil = a
        /// host that doesn't number its rows.
        public var seq: Int? = nil
        public let time: Date
        /// The engine that fired ("Firewall", "Credential brokering", …).
        public let engine: String
        /// What it saw (the host, package, snippet, key…).
        public let condition: String
        /// What it decided ("blocked", "swapped in oai_…", "signed"…).
        public let decision: String
        public let kind: Decision
        public let profileID: UUID
        /// The workspace's name when it happened (nil: unknown).
        public var workspace: String? = nil
        /// Where it happened: nil = this Mac, else a mirrored host's name.
        public var machine: String? = nil
        /// How many things it covers when it's more than one (PII values
        /// swapped in one request); nil = one.
        public var count: Int? = nil
        /// The raw event, kept for the rows that open into a detail view
        /// (a network flow's full lineage, an agent's reasoning).
        public var eventType: String? = nil
        public var detail: [String: AnyJSON]? = nil
        /// Repeats of a routine event (same credential swapped in for the same
        /// host) share this key and fold into one row with a `count` (B40).
        public var coalesceKey: String? = nil
        /// How many refused attempts the row stands for, when the engine
        /// folds them itself (a guest-sandbox denial: the guest's own count on
        /// the first row; the extra denials on a "×N more" row). nil = one.
        public var denials: Int? = nil
        /// A connection-level firewall verdict, structured — what the row's
        /// quick actions (allow / block / switch the rule off) work from.
        public var firewall: Firewall? = nil
        /// A package a reputation check blocked that the user may let
        /// through: what the row's "Always allow" action adds.
        public var package: PackageRef? = nil
    }

    /// `ecosystem:name`, as the supply-chain allowlists write it.
    public struct PackageRef: Sendable, Equatable {
        public let ecosystem: String
        public let name: String
        public var allowlistEntry: String { "\(ecosystem):\(name)" }
        init(ecosystem: String, name: String) { self.ecosystem = ecosystem; self.name = name }
        init?(wire: String?) {
            guard let wire, let i = wire.firstIndex(of: ":"), i != wire.startIndex,
                  wire.index(after: i) != wire.endIndex else { return nil }
            ecosystem = String(wire[..<i]); name = String(wire[wire.index(after: i)...])
        }
    }

    /// Event types whose rows keep their raw data (`detail`).
    nonisolated static let detailedTypes: Set<String> = ["net.flow", "agent.reasoning"]

    nonisolated static func foundation(_ d: [String: AnyJSON]) -> Any? {
        (try? JSONEncoder().encode(d)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    nonisolated static func anyJSON(_ v: Any?) -> [String: AnyJSON]? {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode([String: AnyJSON].self, from: data)
    }

    /// The destination and deciding rule of a firewall connection verdict.
    public struct Firewall: Sendable, Equatable {
        /// The hostname (DNS-snooped name, SNI, CONNECT host); nil for a flow
        /// to a bare IP.
        public var host: String?
        public var ip: String?
        public var port: Int?
        /// "tcp" / "udp" (or "ipv6" for the v6 drop).
        public var proto: String?
        /// The deciding rule's text (`EgressPolicy.Rule.text`); nil = the
        /// default action decided.
        public var rule: String?
        public var denied: Bool
        /// False for drops that aren't a ruleset decision (IPv6 / QUIC / IP
        /// fragments) — nothing a rule change would alter.
        public var byPolicy: Bool
        /// The destination's other DNS names (CNAME targets, other names
        /// seen for its address) — `host` is the one the guest asked for.
        public var aliases: [String] = []
        /// The program the guest's attestor named for a denied connection,
        /// as decided: what this block's Allow grants.
        public var exe: String? = nil

        public init(host: String?, ip: String?, port: Int?, proto: String?, rule: String?,
                    denied: Bool, byPolicy: Bool, aliases: [String] = [], exe: String? = nil) {
            self.host = host; self.ip = ip; self.port = port; self.proto = proto
            self.rule = rule; self.denied = denied; self.byPolicy = byPolicy
            self.aliases = aliases; self.exe = exe
        }

        var wire: [String: Any] {
            var d: [String: Any] = ["denied": denied, "byPolicy": byPolicy]
            if !aliases.isEmpty { d["aliases"] = aliases }
            if let host { d["host"] = host }
            if let ip { d["ip"] = ip }
            if let port { d["port"] = port }
            if let proto { d["proto"] = proto }
            if let rule { d["rule"] = rule }
            if let exe { d["exe"] = exe }
            return d
        }

        init?(wire d: [String: Any]?) {
            guard let d else { return nil }
            self.init(host: d["host"] as? String, ip: d["ip"] as? String, port: d["port"] as? Int,
                      proto: d["proto"] as? String, rule: d["rule"] as? String,
                      denied: d["denied"] as? Bool ?? false, byPolicy: d["byPolicy"] as? Bool ?? false,
                      aliases: d["aliases"] as? [String] ?? [], exe: d["exe"] as? String)
        }
    }

    /// A routine row folds into an earlier one with the same `coalesceKey`
    /// seen within this long (sliding: each repeat restarts it).
    nonisolated static let coalesceWindow: TimeInterval = 10 * 60

    /// Fold `e` into `events` (oldest first): a repeat of a recent row with the
    /// same `coalesceKey` (same profile) replaces it — moved to the end, time
    /// bumped, count incremented — instead of adding a row.
    nonisolated static func coalesce(_ e: Event, into events: inout [Event]) {
        if let key = e.coalesceKey {
            // Look back a bounded number of rows; routine repeats are recent.
            let lowerBound = max(0, events.count - 500)
            var i = events.count - 1
            while i >= lowerBound {
                let old = events[i]
                if old.time < e.time.addingTimeInterval(-coalesceWindow) { break }
                if old.coalesceKey == key, old.profileID == e.profileID, old.machine == e.machine {
                    var merged = Event(time: e.time, engine: e.engine, condition: e.condition,
                                       decision: e.decision, kind: e.kind, profileID: e.profileID,
                                       workspace: e.workspace ?? old.workspace, machine: e.machine,
                                       count: (old.count ?? 1) + (e.count ?? 1))
                    merged.coalesceKey = key
                    merged.rowID = old.stableID
                    merged.firewall = e.firewall ?? old.firewall
                    merged.package = e.package ?? old.package
                    merged.eventType = e.eventType ?? old.eventType
                    merged.detail = e.detail ?? old.detail
                    events.remove(at: i)
                    events.append(merged)
                    return
                }
                i -= 1
            }
        }
        events.append(e)
    }

    /// This Mac's events, oldest first (the most recent `cap` in memory; the
    /// full history is on disk).
    public private(set) var events: [Event] = []
    /// Mirrored hosts' events (fat client), by host name.
    public private(set) var remote: [String: [Event]] = [:]
    /// The host behind each of `remote`'s keys (its id): what the window
    /// calls it is made from these.
    private(set) var machineHosts: [String: RemoteHost] = [:]

    func noteMachine(_ key: String, host: RemoteHost) {
        if machineHosts[key] != host { machineHosts[key] = host }
    }

    /// What the window calls a machine: this Mac (nil), else the host's
    /// label, unique among every host it has rows from (saved or a peer).
    func machineLabel(_ key: String?) -> String {
        guard let key else { return NSLocalizedString("This Mac", comment: "security timeline") }
        guard let host = machineHosts[key] else { return key }
        return Self.machineLabels(Array(machineHosts.values))[host.id] ?? key
    }

    /// Hosts' labels, unique among them: the name (or address); with the
    /// address and port when another host has the same name; then, for any
    /// label still shared (a name spelled like another's addressed label,
    /// two records of one machine), the id too.
    nonisolated static func machineLabels(_ hosts: [RemoteHost]) -> [UUID: String] {
        func base(_ h: RemoteHost) -> String { h.name.isEmpty ? h.address : h.name }
        var bases: [String: Int] = [:]
        for h in hosts { bases[base(h), default: 0] += 1 }
        var out: [UUID: String] = [:]
        for h in hosts { out[h.id] = bases[base(h)] == 1 ? base(h) : "\(base(h)) (\(h.address):\(h.port))" }
        for pass in 0..<2 {
            var counts: [String: Int] = [:]
            for v in out.values { counts[v, default: 0] += 1 }
            for h in hosts where (counts[out[h.id] ?? ""] ?? 0) > 1 {
                out[h.id] = "\(out[h.id] ?? base(h)) · \(pass == 0 ? String(h.id.uuidString.prefix(8)) : h.id.uuidString)"
            }
        }
        return out
    }
    private static let cap = 5000
    /// The next row's `seq`. Starts over at each launch: `epoch` says which.
    private var nextSeq = 0
    /// This run of the timeline: a fat client compares `seq`s only between
    /// rows of the same one.
    public let epoch = UUID().uuidString
    /// Days of history kept on disk (Preferences › Tracing › Security
    /// history): 0 = forever. Unset = 90.
    nonisolated static let retentionKey = "securityTimeline.retentionDays"
    nonisolated static var retentionDays: Int {
        UserDefaults.standard.object(forKey: retentionKey) == nil ? 90 : UserDefaults.standard.integer(forKey: retentionKey)
    }
    /// The time range the Overview counts and the Timeline opens on, in hours:
    /// 0 = all history. Unset = 24.
    nonisolated static let defaultRangeKey = "securityTimeline.defaultRangeHours"
    nonisolated static var defaultRangeHours: Int {
        UserDefaults.standard.object(forKey: defaultRangeKey) == nil ? 24 : UserDefaults.standard.integer(forKey: defaultRangeKey)
    }
    /// The ranges offered, in hours (0 = all).
    nonisolated static let rangeChoices = [1, 24, 168, 720, 0]
    nonisolated static func rangeTitle(hours: Int) -> String {
        switch hours {
        case 1:   return NSLocalizedString("Last hour", comment: "security time range")
        case 24:  return NSLocalizedString("Last 24 hours", comment: "security time range")
        case 168: return NSLocalizedString("Last 7 days", comment: "security time range")
        case 720: return NSLocalizedString("Last 30 days", comment: "security time range")
        default:  return NSLocalizedString("All history", comment: "security time range")
        }
    }

    /// Apply a changed retention now (not only at the next launch).
    public func pruneNow() {
        guard let dir = directory else { return }
        io.async { Self.prune(dir) }
    }

    /// This Mac's and every mirrored host's events, oldest first.
    public var allEvents: [Event] {
        guard !remote.isEmpty else { return events }
        return (events + remote.values.flatMap { $0 }).sorted { $0.time < $1.time }
    }

    /// A workspace's name, for the rows (set by the app).
    @ObservationIgnored public var workspaceName: @MainActor (UUID) -> String? = { _ in nil }

    /// Where the daily logs go; nil keeps the timeline in memory only
    /// (tests).
    private let directory: URL?
    private let io = DispatchQueue(label: "io.bromure.security-timeline", qos: .utility)
    /// Events before this were cleared from the view (still on disk).
    private static let clearedAtKey = "securityTimeline.clearedAt"

    public init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clearedAt = UserDefaults.standard.double(forKey: Self.clearedAtKey)
        events = Self.load(from: directory, limit: Self.cap, after: clearedAt)
        for i in events.indices { events[i].seq = nextSeq; nextSeq += 1 }
        let dir = directory
        io.async { Self.prune(dir); Self.redactLegacyPreviews(in: dir) }
    }

    /// The app's timeline: persisted in the support folder, except in a test
    /// run (which must never write the user's history).
    private static func defaultDirectory() -> URL? {
        let testing = isTestRun()
        guard !testing else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("BromureAC/security-timeline", isDirectory: true)
    }

    /// Record a raw `BACEventEmitter` event. Callable from any thread (the
    /// proxy fires these off the main actor); it hops to the main actor to
    /// mutate. Non-security event types (file/command/tool/llm activity) map
    /// to nil and are ignored — this is a security view, not an activity log.
    nonisolated public func record(profileID: UUID, eventType: String,
                                   eventData: [String: AnyJSON]) {
        guard var e = Self.map(profileID: profileID, eventType: eventType,
                               eventData: eventData, now: Date()) else { return }
        if Self.detailedTypes.contains(eventType) { e.eventType = eventType; e.detail = eventData }
        // A sandbox denial keeps its path and program: the Sandbox drawer
        // offers to allow the path from it.
        if eventType == "sentry.event", case .string("sandbox_denial")? = eventData["category"] {
            e.eventType = eventType; e.detail = eventData
        }
        Task { @MainActor in self.append(e) }
    }

    /// Append an event of this Mac's: into the view and onto the disk log.
    public func append(_ e: Event) {
        var e = e
        if e.workspace == nil { e.workspace = workspaceName(e.profileID) }
        // Routine repeats fold into one row; the disk log keeps every raw
        // event (with its key) and `load` folds them the same way.
        Self.coalesce(e, into: &events)
        // The new (or moved) row is the last one: numbered after every other.
        events[events.count - 1].seq = nextSeq
        nextSeq += 1
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
        persist(e)
    }

    /// Clear the window. The log on disk stays (it's the audit trail); the
    /// cleared events just don't come back at the next launch.
    public func clear() {
        events.removeAll()
        remote.removeAll()
        fetched.removeAll()
        if directory != nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.clearedAtKey)
        }
    }

    // MARK: - Disk

    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func line(_ e: Event) -> Data? {
        var d: [String: Any] = ["t": e.time.timeIntervalSince1970, "e": e.engine, "c": e.condition,
                                "d": e.decision, "k": e.kind.wire, "p": e.profileID.uuidString]
        if let w = e.workspace { d["w"] = w }
        if let n = e.count { d["n"] = n }
        if let t = e.eventType, let x = e.detail.flatMap(foundation) { d["y"] = t; d["x"] = x }
        if let ck = e.coalesceKey { d["ck"] = ck }
        if let dn = e.denials { d["dn"] = dn }
        if let fw = e.firewall { d["fw"] = fw.wire }
        if let pk = e.package { d["pk"] = pk.allowlistEntry }
        d["rid"] = e.stableID.uuidString
        guard var data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        data.append(0x0A)
        return data
    }

    nonisolated static func event(fromLine line: Data) -> Event? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = d["t"] as? Double, let engine = d["e"] as? String,
              let condition = d["c"] as? String, let decision = d["d"] as? String else { return nil }
        // Rows written before fingerprints carry "sk-a…kUyU" previews of real
        // secrets: never show (or re-export) those characters.
        var e = Event(time: Date(timeIntervalSince1970: t), engine: engine,
                      condition: SecretFingerprint.redactLegacy(condition),
                      decision: SecretFingerprint.redactLegacy(decision),
                      kind: Decision(wire: d["k"] as? String ?? ""),
                      profileID: (d["p"] as? String).flatMap(UUID.init) ?? UUID(),
                      workspace: d["w"] as? String, count: d["n"] as? Int,
                      eventType: d["y"] as? String, detail: anyJSON(d["x"]))
        e.coalesceKey = (d["ck"] as? String).map(SecretFingerprint.redactLegacy)
        e.denials = d["dn"] as? Int
        e.firewall = Firewall(wire: d["fw"] as? [String: Any])
        e.package = PackageRef(wire: d["pk"] as? String)
        // A row logged before rows had ids: one derived from what it says,
        // the same at every load. A fresh one each launch made the row a
        // stranger to a fat client that fetched it before the restart: its
        // next repeat came back under another id and counted twice (Finding:
        // "Legacy timeline rows duplicate after a host restart and repeat").
        e.rowID = (d["rid"] as? String).flatMap(UUID.init) ?? legacyRowID(e)
        return e
    }

    /// A stable id for a logged row without one: a hash of its persisted
    /// fields, as read (redacted -- the log's one rewrite redacts them too).
    nonisolated static func legacyRowID(_ e: Event) -> UUID {
        let fields: [String] = ["legacy-row", String(e.time.timeIntervalSince1970.bitPattern), e.engine,
                                e.condition, e.decision, e.kind.wire, e.profileID.uuidString,
                                e.coalesceKey ?? "", e.workspace ?? "", e.count.map(String.init) ?? ""]
        var b = Array(SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // a name-based UUID (version 5 layout)
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Rewrite the daily logs so no legacy secret preview stays on disk.
    /// Idempotent; only files that change are rewritten (atomically).
    nonisolated static func redactLegacyPreviews(in directory: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(".jsonl") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8), text.contains("…") else { continue }
            var changed = false
            var out = Data()
            for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let lineData = Data(raw)
                if let d = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    var m = d
                    for k in ["c", "d", "ck"] {
                        if let s = d[k] as? String {
                            let r = SecretFingerprint.redactLegacy(s)
                            if r != s { m[k] = r; changed = true }
                        }
                    }
                    if let enc = try? JSONSerialization.data(withJSONObject: m) { out.append(enc) } else { out.append(lineData) }
                } else {
                    out.append(lineData)
                }
                out.append(0x0A)
            }
            if changed { try? out.write(to: url, options: .atomic) }
        }
    }

    private func persist(_ e: Event) {
        guard let directory, let data = Self.line(e) else { return }
        let file = directory.appendingPathComponent(Self.dayFormatter.string(from: e.time) + ".jsonl")
        io.async {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
    }

    /// The most recent `limit` events (newer than `after`), oldest first,
    /// reading the daily logs newest first.
    nonisolated static func load(from directory: URL, limit: Int, after: TimeInterval) -> [Event] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted(by: >)
        var out: [Event] = []
        for name in files {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            let day = data.split(separator: 0x0A).compactMap { event(fromLine: Data($0)) }
                .filter { $0.time.timeIntervalSince1970 > after }
            out = day + out
            if out.count >= limit { break }
        }
        var folded: [Event] = []
        folded.reserveCapacity(out.count)
        for e in out { coalesce(e, into: &folded) }
        return Array(folded.suffix(limit))
    }

    /// Drop daily logs past the retention window.
    nonisolated static func prune(_ directory: URL, now: Date = Date()) {
        let days = retentionDays
        guard days > 0 else { return }   // kept forever
        let cutoff = dayFormatter.string(from: now.addingTimeInterval(-Double(days) * 86400))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(".jsonl") && String(name.dropLast(6)) < cutoff {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Fat-client mirror

    /// The security engines (credential broker, firewall, guardrails, MiTM)
    /// run on the HOST, so the host owns the live timeline. A fat client mirrors
    /// a remote host and runs no engines of its own — its local store would
    /// stay empty and the Security Timeline window blank. These two methods
    /// ship the host's recent decisions over `/state` and rebuild them on the
    /// client so the window works there too.

    /// Serialize the most recent events for the `/state` snapshot. Bounded —
    /// the window is a "what just happened" view, not the full 5000-cap history.
    public func mirrorRows(limit: Int = 750, since: Date? = nil) -> [[String: Any]] {
        let pool = since.map { t in events.filter { $0.time >= t } } ?? events
        return pool.suffix(limit).map { e in
            var r: [String: Any] = [
                "t": e.time.timeIntervalSince1970,
                "engine": e.engine,
                "condition": e.condition,
                "decision": e.decision,
                "kind": e.kind.wire,
                "profileID": e.profileID.uuidString,
            ]
            if let w = e.workspace { r["workspace"] = w }
            if let n = e.count { r["count"] = n }
            if let t = e.eventType, let x = e.detail.flatMap(Self.foundation) { r["type"] = t; r["detail"] = x }
            if let ck = e.coalesceKey { r["ck"] = ck }
            r["rid"] = e.stableID.uuidString
            if let sq = e.seq { r["sq"] = sq }
            if let dn = e.denials { r["dn"] = dn }
            if let fw = e.firewall { r["fw"] = fw.wire }
            if let pk = e.package { r["pk"] = pk.allowlistEntry }
            return r
        }
    }

    /// A host's events in the last `hours` (0 = all it holds), as many as its
    /// own window counts (the in-memory cap): what a fat client's Security
    /// window fetches, so its numbers are the server's. The live mirror is
    /// only the most recent rows.
    public func historyRows(hours: Int) -> [[String: Any]] {
        mirrorRows(limit: Self.cap, since: hours > 0 ? Date().addingTimeInterval(-Double(hours) * 3600) : nil)
    }

    /// Rebuild a mirrored host's events from its snapshot (fat client). The
    /// host is authoritative for its own bucket, which this replaces; this
    /// Mac's events and other hosts' are left alone.
    /// What the host still holds (its in-memory cap prunes from the front):
    /// `oldestSeq` with its `epoch`, the first row it holds; fetched rows
    /// before it are gone on the host and go here too. An older host sends
    /// only `oldestRetained`, its first row's time.
    public func applyMirror(_ rows: [[String: Any]], host: String, oldestRetained: Date? = nil,
                            oldestSeq: Int? = nil, epoch: String? = nil) {
        let mirror = Self.events(rows, host: host)
        // No rows: the host holds none -- its bucket empties, history too.
        if mirror.isEmpty { fetched[host] = nil; fetchedEpoch[host] = nil }
        let retention: Retention
        if let oldestSeq, let epoch {
            // Numbers from another run of the host (it restarted since the
            // fetch) say nothing about these rows: none dropped until a new
            // fetch replaces them (`historyIsStale`).
            retention = fetchedEpoch[host] == epoch ? .sequence(oldestSeq) : .unknown
        } else {
            retention = .time(oldestRetained)
        }
        if let history = fetched[host] {
            switch retention {
            case .sequence(let first): fetched[host] = history.filter { $0.seq.map { $0 >= first } ?? true }
            case .time(let t?):        fetched[host] = history.filter { $0.time >= t }
            case .time(nil), .unknown: break
            }
        }
        remote[host] = Self.merged(history: fetched[host] ?? [], mirror: mirror, retention: retention)
    }

    /// The host's history was fetched from an earlier run of it (or from a
    /// host that didn't say which): fetch it again.
    public func historyIsStale(host: String, epoch: String?) -> Bool {
        guard let epoch, fetched[host] != nil else { return false }
        return fetchedEpoch[host] != epoch
    }

    /// The oldest event this Mac holds in memory (what its window counts
    /// from), for an older fat client's mirror: nil with none. Not the
    /// oldest TIME: a clock set back puts later rows before it.
    public var oldestRetained: Date? { events.first?.time }   // oldest first; a repeat moves to the end
    /// The first row this Mac holds in memory, by `seq` (with `epoch`).
    public var oldestRetainedSeq: Int? { events.first?.seq }

    /// A host's history for the window's range, as last fetched (fat
    /// client): the mirror merges into this one, not into earlier mirrors,
    /// so rows the host has since pruned don't linger.
    @ObservationIgnored private var fetched: [String: [Event]] = [:]
    /// The run of the host each fetched history came from.
    @ObservationIgnored private var fetchedEpoch: [String: String] = [:]

    /// A host's full history for the window's range (fetched): replaces its
    /// bucket. Later mirrors merge into it.
    public func applyHistory(_ rows: [[String: Any]], host: String, epoch: String? = nil) {
        let history = Self.events(rows, host: host)
        fetched[host] = history
        fetchedEpoch[host] = epoch
        remote[host] = history
    }

    /// How a mirror tells which fetched rows its host still holds.
    enum Retention {
        /// Rows numbered by the host (same run): it holds `seq` >= this.
        case sequence(Int)
        /// An older host: rows at or after its first row's time (nil: no word).
        case time(Date?)
        /// Numbered by another run of the host: can't tell, none dropped.
        case unknown
    }

    /// The live mirror (the host's most recent rows) over what the bucket
    /// held: rows older than the mirror's oldest are kept -- a fetched
    /// history would otherwise shrink back to the mirror's size at every
    /// snapshot -- except a coalesced row the mirror carries again (its
    /// repeat count grew and its time moved: counted once, the new copy).
    ///
    /// Rows the host no longer holds (older than `oldestRetained`, when it
    /// says) are dropped, and the result never exceeds the host's own cap:
    /// it pruned its oldest as new events came, while this kept counting
    /// them (Finding: "Client retains security rows after the host prunes
    /// its 5000-row timeline").
    nonisolated static func merged(history: [Event], mirror: [Event], oldestRetained: Date? = nil) -> [Event] {
        merged(history: history, mirror: mirror, retention: .time(oldestRetained))
    }

    nonisolated static func merged(history: [Event], mirror: [Event], retention: Retention) -> [Event] {
        guard !history.isEmpty else { return mirror }
        guard !mirror.isEmpty else { return [] }
        let mirroredRows = Set(mirror.compactMap(\.rowID))
        switch retention {
        case .time(let oldestRetained):
            return timeMerged(history: history, mirror: mirror, mirroredRows: mirroredRows, oldestRetained: oldestRetained)
        case .sequence(let first):
            // In the host's own order: what it holds is from `first` on, and
            // the mirror is its last rows, so a fetched row is still there
            // when it's numbered between them -- whatever its time says (a
            // clock set back makes later rows older; Finding: "Security
            // timeline cutoff hides retained rows after a backward clock
            // change"). The mirror's copy of a row replaces it.
            let mirrorFirst = mirror.compactMap(\.seq).min()
            let kept = history.filter { e in
                if let rid = e.rowID, mirroredRows.contains(rid) { return false }
                guard let s = e.seq, let mirrorFirst else { return true }
                return s >= first && s < mirrorFirst
            }
            return (kept + mirror).sorted { ($0.seq ?? -1, $0.time) < ($1.seq ?? -1, $1.time) }.suffix(cap).map { $0 }
        case .unknown:
            // History from another run of the host (it restarted): its
            // numbers can't be compared, its rows' ids can (stable across runs).
            let kept = notCarriedAgain(history, mirror: mirror, mirroredRows: mirroredRows)
            return (kept + mirror).sorted { $0.time < $1.time }.suffix(cap).map { $0 }
        }
    }

    /// An older host (rows not numbered): by time, as it sends nothing else.
    private nonisolated static func timeMerged(history: [Event], mirror: [Event], mirroredRows: Set<UUID>,
                                               oldestRetained: Date?) -> [Event] {
        guard let oldest = mirror.map(\.time).min() else { return [] }
        // The mirror's copy of a row replaces exactly that row: by its stable
        // id. A key alone matched every older row with it -- and the host
        // starts a new row when a key recurs after the coalescing window, so
        // distinct earlier decisions were dropped (Finding: "Recent coalesced
        // event removes distinct older events with the same key"). A host
        // that sends no ids: only a copy within the window of a mirrored
        // repeat is the same row.
        //
        // A fetched row with an id is the mirror's row only by that id: ids
        // are stable across the host's restarts (a row logged without one gets
        // one derived from it; Finding: "Legacy timeline rows duplicate after
        // a host restart and repeat"). The window inferred it from a key and
        // a time, and a new row the host started for the same key -- the old
        // one past its 500-row look-back and out of the 750-row mirror --
        // erased the earlier, distinct decision it still held (Finding: "New
        // coalesced timeline row can erase an earlier distinct decision").
        // Only a fetched row without an id (an older host) is matched by the
        // window.
        // Older than the mirror, still held by the host (its cap prunes the
        // oldest), and not the row the mirror carries again.
        let candidates = history.filter { e in
            e.time < oldest && (oldestRetained.map { e.time >= $0 } ?? true)
        }
        let kept = notCarriedAgain(candidates, mirror: mirror, mirroredRows: mirroredRows)
        return (kept + mirror).sorted { $0.time < $1.time }.suffix(cap).map { $0 }
    }

    /// The fetched `candidates` the mirror doesn't carry again: a row with an
    /// id unless the mirror has that id; a row without one (an older host)
    /// unless a mirrored repeat with its key follows it within the
    /// coalescing window.
    private nonisolated static func notCarriedAgain(_ candidates: [Event], mirror: [Event],
                                                    mirroredRows: Set<UUID>) -> [Event] {
        var repeatTimes: [String: [Date]] = [:]
        for e in mirror {
            if let ck = e.coalesceKey { repeatTimes["\(e.profileID)|\(ck)", default: []].append(e.time) }
        }
        return candidates.filter { e in
            // Its own id: the same row only when the mirror carries that id.
            if let rid = e.rowID { return !mirroredRows.contains(rid) }
            // No id (an older host): a copy within the window of a mirrored
            // repeat is that row.
            guard let ck = e.coalesceKey, let times = repeatTimes["\(e.profileID)|\(ck)"] else { return true }
            return !times.contains { $0 >= e.time && $0.timeIntervalSince(e.time) <= coalesceWindow }
        }
    }

    private static func events(_ rows: [[String: Any]], host: String) -> [Event] {
        rows.compactMap { r in
            guard let engine = r["engine"] as? String,
                  let condition = r["condition"] as? String,
                  let decision = r["decision"] as? String else { return nil }
            let t = (r["t"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let pid = (r["profileID"] as? String).flatMap(UUID.init) ?? UUID()
            var e = Event(time: t, engine: engine, condition: SecretFingerprint.redactLegacy(condition),
                          decision: SecretFingerprint.redactLegacy(decision),
                          kind: Decision(wire: r["kind"] as? String ?? ""),
                          profileID: pid, workspace: r["workspace"] as? String, machine: host,
                          count: r["count"] as? Int, eventType: r["type"] as? String,
                          detail: Self.anyJSON(r["detail"]))
            e.coalesceKey = r["ck"] as? String
            e.rowID = (r["rid"] as? String).flatMap(UUID.init)
            e.seq = r["sq"] as? Int
            e.denials = r["dn"] as? Int
            e.firewall = Firewall(wire: r["fw"] as? [String: Any])
            e.package = PackageRef(wire: r["pk"] as? String)
            return e
        }
    }

    /// arm64 numbers of the syscalls the guest's process layer can block
    /// (mirrors `_SYSCALLS_AARCH64` in bromure_openshell.py); the sentry
    /// reports a seccomp denial by number.
    nonisolated static let arm64Syscalls: [Int: String] = [
        277: "seccomp", 198: "socket", 279: "memfd_create", 117: "ptrace", 280: "bpf",
        270: "process_vm_readv", 271: "process_vm_writev", 438: "pidfd_getfd",
        424: "pidfd_send_signal", 425: "io_uring_setup", 426: "io_uring_enter",
        427: "io_uring_register", 40: "mount", 430: "fsopen", 431: "fsconfig",
        432: "fsmount", 433: "fspick", 429: "move_mount", 428: "open_tree",
        268: "setns", 39: "umount2", 41: "pivot_root", 282: "userfaultfd",
        241: "perf_event_open", 281: "execveat", 97: "unshare", 220: "clone",
        435: "clone3", 434: "pidfd_open", 272: "kcmp", 440: "process_madvise",
        448: "process_mrelease", 51: "chroot", 91: "capset", 146: "setuid",
        144: "setgid", 145: "setreuid", 143: "setregid", 147: "setresuid",
        149: "setresgid", 151: "setfsuid", 152: "setfsgid", 159: "setgroups",
        161: "sethostname", 162: "setdomainname", 140: "setpriority",
        30: "ioprio_set", 129: "kill", 130: "tkill", 131: "tgkill",
        138: "rt_sigqueueinfo", 240: "rt_tgsigqueueinfo", 261: "prlimit64",
        122: "sched_setaffinity", 274: "sched_setattr", 118: "sched_setparam",
        119: "sched_setscheduler", 436: "close_range", 25: "fcntl", 29: "ioctl",
        105: "init_module", 273: "finit_module", 106: "delete_module",
        104: "kexec_load", 294: "kexec_file_load",
    ]

    // MARK: - Mapping

    nonisolated private static func str(_ d: [String: AnyJSON], _ k: String) -> String? {
        if case .string(let v)? = d[k] { return v }
        return nil
    }
    nonisolated private static func int(_ d: [String: AnyJSON], _ k: String) -> Int? {
        if case .int(let v)? = d[k] { return v }
        return nil
    }

    /// Turn one emitted event into a timeline row, or nil if it isn't a
    /// security-engine decision.
    nonisolated static func map(profileID: UUID, eventType: String,
                                eventData d: [String: AnyJSON], now: Date) -> Event? {
        func row(_ engine: String, _ condition: String,
                 _ decision: String, _ kind: Decision) -> Event {
            Event(time: now, engine: engine, condition: condition,
                  decision: decision, kind: kind, profileID: profileID)
        }

        switch eventType {
        case "credential.token_swap":
            let fake = str(d, "fake_preview") ?? "fake"
            let real = str(d, "real_preview") ?? "real"
            let host = str(d, "host") ?? "?"
            var e = row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                        "\(fake) → \(host)",
                        String(format: NSLocalizedString("swapped in %@", comment: "Security Timeline decision"), real), .info)
            // One row per credential + host, not one per API call (B40).
            e.coalesceKey = "token_swap|\(fake)|\(real)|\(host)"
            return e

        case "credential.subscription_auth":
            // A workspace set to its subscription that runs on the API key
            // from Settings › Models instead: a neutral note, not a block.
            let agent = str(d, "agent").flatMap { Profile.Tool(rawValue: $0)?.displayName } ?? str(d, "agent") ?? "?"
            var e = row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                        String(format: NSLocalizedString("%@ subscription not signed in", comment: "Security Timeline condition: agent name"), agent),
                        NSLocalizedString("using API key", comment: "Security Timeline decision: subscription workspace runs on the API key"),
                        .info)
            e.coalesceKey = "subscription_auth|\(agent)"
            return e

        case "sandbox.status":
            let fs = str(d, "filesystem") ?? "off"
            let strictFailed: Bool = { if case .bool(false)? = d["strict_applied"] { return true }; return false }()
            // An `off` the guest says failed (a run_as identity it couldn't
            // set up) is a failure, not "no filesystem policy"; one asked for
            // and not in force yet (held for the sentry) is a wait.
            let offReason = fs == "off" ? (str(d, "reason") ?? "") : ""
            let offFailed = !offReason.isEmpty && !GuestSandboxStatusStore.Status.filesystemOffAsAsked.contains(offReason)
            let offWaiting: Bool = {
                if fs == "off", offReason.isEmpty, case .bool(true)? = d["requested_filesystem"] { return true }
                return false
            }()
            let bad = fs == "failed" || fs == "degraded" || strictFailed || offFailed
            var parts = [String(format: NSLocalizedString("filesystem %@", comment: "guest sandbox condition"), fs)]
            if let u = str(d, "run_as") { parts.append(String(format: NSLocalizedString("runs as %@", comment: "guest sandbox condition"), u)) }
            if let sc = str(d, "seccomp") { parts.append("seccomp \(sc)") }
            if let se = str(d, "sentry") {
                var part = String(format: NSLocalizedString("sentry %@", comment: "guest sandbox condition"), se)
                if se == "unavailable", let why = str(d, "sentry_reason") { part += " (\(why))" }
                parts.append(part)
            }
            let off = fs == "off"
            return row(NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"),
                       parts.joined(separator: " · "),
                       strictFailed ? NSLocalizedString("strict sandbox not applied — no session will start", comment: "Security Timeline decision")
                       : bad ? (str(d, "reason") ?? NSLocalizedString("not enforced", comment: "Security Timeline decision"))
                           : offWaiting ? NSLocalizedString("not applied yet", comment: "Security Timeline decision: guest sandbox still being set up")
                           : off ? NSLocalizedString("no filesystem policy", comment: "Security Timeline decision")
                                 : NSLocalizedString("enforced", comment: "Security Timeline decision"),
                       bad ? .blocked : off ? .info : .allowed)

        case "sandbox.package_request":
            // A system package the agent asked for, and what became of it.
            var names: [String] = []
            if case .array(let a)? = d["packages"] { names = a.compactMap { if case .string(let v) = $0 { return v }; return nil } }
            let status = str(d, "status") ?? "requested"
            let decision: String
            let kind: Decision
            switch status {
            case "installed": decision = NSLocalizedString("installed", comment: "Security Timeline decision"); kind = .allowed
            case "rejected":  decision = NSLocalizedString("rejected", comment: "Security Timeline decision"); kind = .blocked
            case "failed":    decision = NSLocalizedString("install failed", comment: "Security Timeline decision"); kind = .blocked
            default:          decision = NSLocalizedString("asked for approval", comment: "Security Timeline decision"); kind = .info
            }
            return row(NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"),
                       "\(str(d, "manager") ?? "apt") install \(names.joined(separator: " "))", decision, kind)

        case "sentry.state":
            let up = str(d, "state") == "connected"
            return row(NSLocalizedString("Kernel sentry", comment: "Security Timeline engine"),
                       [str(d, "kernel"), str(d, "module")].compactMap { $0 }.joined(separator: " · "),
                       up ? NSLocalizedString("connected", comment: "Security Timeline decision")
                          : NSLocalizedString("disconnected", comment: "Security Timeline decision"),
                       up ? .allowed : .info)

        case "sentry.event" where str(d, "category") == "sandbox_denial":
            // One refused action inside the guest sandbox: who tried what.
            let kind = str(d, "kind") ?? "sandbox_denied"
            // seccomp_denied carries the executable in `path`.
            let who = str(d, "exe") ?? (kind == "seccomp_denied" ? str(d, "path") : nil) ?? str(d, "comm") ?? "?"
            let pid = int(d, "pid").map { " (pid \($0))" } ?? ""
            let times: String
            let isRepeat: Bool = { if case .bool(true)? = d["repeat"] { return true }; return false }()
            // What the row stands for: the guest's own count on a first row,
            // the extra denials on a folded "×N more" row.
            let denials = max(1, int(d, "count") ?? 1)
            if isRepeat {
                // Folded repeats of a denial already shown.
                let procs = int(d, "processes") ?? 1
                times = procs > 1
                    ? String(format: NSLocalizedString(" — ×%d more in the last minute, from %d processes", comment: "guest sandbox repeated denial"), int(d, "count") ?? 0, procs)
                    : String(format: NSLocalizedString(" — ×%d more in the last minute", comment: "guest sandbox repeated denial"), int(d, "count") ?? 0)
            } else {
                times = (int(d, "count") ?? 1) > 1 ? " ×\(int(d, "count")!)" : ""
            }
            let what: String
            if kind == "seccomp_denied" {
                let name = str(d, "syscall_name")
                    ?? int(d, "syscall").map { Self.arm64Syscalls[$0] ?? "#\($0)" }
                    ?? str(d, "syscall") ?? str(d, "detail") ?? "?"
                what = String(format: NSLocalizedString("syscall %@", comment: "guest sandbox denial"), name)
            } else {
                let op = str(d, "op") ?? (kind == "file_open_denied" ? "open" : "access")
                what = "\(op) \(str(d, "path") ?? "?")"
            }
            var e = row(NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"),
                        "\(who)\(pid) — \(what)\(times)",
                        NSLocalizedString("denied", comment: "Security Timeline decision"), .blocked)
            e.denials = denials > 1 ? denials : nil
            return e

        case "net.flow":
            // One network flow, explained: who ran it (the process chain from
            // the agent down) and, when known, which tool call caused it.
            let chain: [String] = {
                guard case .array(let ps)? = d["processes"] else { return [] }
                return ps.compactMap { if case .object(let p) = $0 { return Self.str(p, "comm") } else { return nil } }
            }()
            let proto = (str(d, "proto") ?? "ip").uppercased()
            let dst = str(d, "host") ?? str(d, "dst") ?? "?"
            let port = (int(d, "dport") ?? 0) > 0 ? ":\(int(d, "dport")!)" : ""
            // A raw packet socket has no destination, only the interface.
            let target = proto == "PACKET"
                ? String(format: NSLocalizedString("raw frames on %@", comment: "network flow target"), str(d, "dev") ?? "?")
                : "\(proto) \(dst)\(port)"
            var cond = (chain + [target]).joined(separator: " → ")
            if case .object(let agent)? = d["agent"], let tool = Self.str(agent, "tool") {
                cond = "\(tool)" + (str(d, "command").map { " `\($0)`" } ?? "") + ": " + cond
            }
            if (int(d, "count") ?? 1) > 1 { cond += " ×\(int(d, "count")!)" }
            let decision = str(d, "decision") ?? "unknown"
            let shown: String
            switch decision {
            case "deny": shown = str(d, "reason").map { "denied — \($0)" } ?? NSLocalizedString("denied", comment: "Security Timeline decision")
            case "audit": shown = NSLocalizedString("audited", comment: "Security Timeline decision")
            case "unfiltered": shown = NSLocalizedString("passed (not filtered)", comment: "network flow decision")
            case "raw": shown = NSLocalizedString("raw socket", comment: "network flow decision")
            case "unknown": shown = NSLocalizedString("seen", comment: "network flow decision")
            default: shown = NSLocalizedString("allowed", comment: "Security Timeline decision")
            }
            return row(NSLocalizedString("Network", comment: "Security Timeline engine"), cond, shown,
                       decision == "deny" ? .blocked : decision == "allow" ? .allowed : .info)

        case "agent.reasoning":
            let tool = str(d, "tool") ?? "tool"
            // The model's reasoning when it gave any, else its stated intent,
            // else the prompt it was acting on.
            let text = [str(d, "text"), str(d, "intent"), str(d, "prompt")]
                .compactMap { $0 }.first { !$0.isEmpty }?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            return row(NSLocalizedString("Agent reasoning", comment: "Security Timeline engine"),
                       "\(tool): \(String(text.prefix(300)))\(text.count > 300 || { if case .bool(true)? = d["truncated"] { return true }; return false }() ? "…" : "")",
                       NSLocalizedString("before the tool call", comment: "Security Timeline decision"), .info)

        case "sandbox.activity":
            let allowed = int(d, "allowed_file_ops") ?? 0
            let denied = int(d, "denied_file_ops") ?? 0
            let syscalls = int(d, "denied_syscalls") ?? 0
            return row(NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"),
                       String(format: NSLocalizedString("since boot: %d file operations allowed, %d denied, %d syscalls denied",
                                                        comment: "guest sandbox tallies"), allowed, denied, syscalls),
                       NSLocalizedString("activity", comment: "Security Timeline decision"),
                       denied + syscalls > 0 ? .blocked : .allowed)

        case "sentry.alarm" where str(d, "kind") == "sandbox_probing":
            return row(NSLocalizedString("Guest sandbox", comment: "Security Timeline engine"),
                       str(d, "reason") ?? "",
                       NSLocalizedString("probing its limits", comment: "Security Timeline decision"), .blocked)

        case "sentry.event":
            let kind = str(d, "kind") ?? "event"
            let subject = str(d, "path") ?? str(d, "exe") ?? str(d, "target") ?? str(d, "detail") ?? ""
            let pid = int(d, "pid").map { " (pid \($0))" } ?? ""
            return row(NSLocalizedString("Kernel sentry", comment: "Security Timeline engine"),
                       "\(kind)\(subject.isEmpty ? "" : ": \(subject)")\(pid)",
                       str(d, "category") ?? "",
                       // Anything weighted 10+ (tampering: an unsigned module, lowering
                       // lockdown, kexec, …) is red; the rest is context.
                       kind == "landlock_denied" || kind == "file_open_denied" || (int(d, "weight") ?? 0) >= 10
                           ? .blocked : .info)

        case "sentry.alarm":
            return row(NSLocalizedString("Kernel sentry", comment: "Security Timeline engine"),
                       str(d, "reason") ?? "",
                       str(d, "kind") == "tampering"
                           ? NSLocalizedString("tampering suspected", comment: "Security Timeline decision")
                           : NSLocalizedString("warning", comment: "Security Timeline decision"),
                       str(d, "kind") == "tampering" ? .blocked : .info)

        case "watchdog.trip":
            var kinds: [String] = []
            if case .array(let a)? = d["kinds"] { kinds = a.compactMap { if case .string(let s) = $0 { return s }; return nil } }
            let quarantine = str(d, "action") == "quarantine"
            return row(NSLocalizedString("Agent watchdog", comment: "Security Timeline engine"),
                       String(format: NSLocalizedString("score %d in a minute: %@", comment: "watchdog condition"),
                              int(d, "score") ?? 0, kinds.joined(separator: ", ")),
                       quarantine
                           ? NSLocalizedString("quarantined — network cut, VM paused", comment: "Security Timeline decision")
                           : NSLocalizedString("drift detected", comment: "Security Timeline decision"),
                       quarantine ? .blocked : .info)

        case "policy.proposal":
            let status = str(d, "status") ?? "submitted"
            var auto = false
            if case .bool(let v)? = d["auto"] { auto = v }
            let kind: Decision = status == "approved" ? .allowed : (status == "rejected" ? .blocked : .info)
            return row(NSLocalizedString("Firewall", comment: "Security Timeline engine"),
                       "\(str(d, "rule") ?? "rule") (\(str(d, "host") ?? "?"):\(int(d, "port") ?? 0)) — \(str(d, "source") == "mechanistic" ? "drafted" : "agent proposal")",
                       status + (auto ? " (automatic)" : "") + (str(d, "reason").map { " — \($0)" } ?? ""), kind)

        case "egress.middleware":
            let action = str(d, "action") ?? "?"
            return row(NSLocalizedString("Firewall", comment: "Security Timeline engine"),
                       "\(str(d, "middleware") ?? "middleware") on \(str(d, "host") ?? "?")",
                       action == "redact" ? "redacted \(int(d, "count") ?? 0) value(s)" : action,
                       action == "deny" ? .blocked : .info)

        case "credential.unmanaged":
            var paused = true
            if case .bool(let v)? = d["vm_paused"] { paused = v }
            return row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                       "\(str(d, "preview") ?? "***") (\(str(d, "kind") ?? "secret"), \(str(d, "location") ?? "request")) → \(str(d, "host") ?? "?")",
                       paused
                           ? NSLocalizedString("blocked — credential not issued by Bromure, VM paused", comment: "Security Timeline decision")
                           : NSLocalizedString("blocked — credential not issued by Bromure", comment: "Security Timeline decision"),
                       .blocked)

        case "credential.exfiltration":
            let fake = str(d, "fake_preview") ?? "fake"
            let cred = str(d, "credential") ?? "session token"
            let declared = str(d, "declared_host") ?? "?"
            let observed = str(d, "observed_host") ?? "?"
            // Older events carry no flag: they predate the opt-out, so paused.
            var paused = true
            if case .bool(let v)? = d["vm_paused"] { paused = v }
            return row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                       "\(fake) (\(cred), scoped to \(declared)) → \(observed)",
                       paused
                           ? NSLocalizedString("blocked — exfiltration attempt, VM paused", comment: "Security Timeline decision")
                           : NSLocalizedString("blocked — exfiltration attempt (alerts off, VM not paused)", comment: "Security Timeline decision"),
                       .blocked)

        case "credential.client_cert":
            // The proxy presented a client certificate upstream for the
            // guest (kubectl with a client-cert kubeconfig): brokered, like a
            // token swap, but no token went in.
            let host = str(d, "host") ?? "?"
            let identity = str(d, "identity") ?? "client certificate"
            var e = row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                        "\(identity) → \(host)",
                        NSLocalizedString("presented client certificate", comment: "Security Timeline decision"), .info)
            e.coalesceKey = "client_cert|\(identity)|\(host)"
            return e

        case "credential.exfiltration_allowed":
            let observed = str(d, "observed_host") ?? "?"
            return row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                       observed,
                       NSLocalizedString("allowed by user for this session", comment: "Security Timeline decision"), .allowed)

        case "agent.delegation":
            // One agent's word to another, brokered by the host: every
            // message is a row, the ones the injection scan withheld in red.
            let title = str(d, "delegation") ?? "delegation"
            let kind = str(d, "kind") ?? "message"
            let from = str(d, "from") ?? "agent"
            let to = str(d, "to") ?? "agent"
            let text = (str(d, "text") ?? "").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let short = text.count > 80 ? String(text.prefix(80)) + "…" : text
            let blocked = (str(d, "verdict") ?? "clean") != "clean"
            let cond = "“\(title)” \(from) → \(to): \(kind) — \(short)"
            return row(NSLocalizedString("Agent delegation", comment: "Security Timeline engine"), cond,
                       blocked
                           ? NSLocalizedString("withheld — prompt injection", comment: "Security Timeline decision")
                           : NSLocalizedString("relayed", comment: "Security Timeline decision"),
                       blocked ? .blocked : .info)

        case "supply_chain.fetch":
            let eco = str(d, "ecosystem") ?? ""
            let pkg = str(d, "package") ?? "?"
            let ver = str(d, "version").map { "@\($0)" } ?? ""
            let outcome = (str(d, "outcome") ?? "allowed").lowercased()
            let fetch = (str(d, "kind") ?? "artifact").lowercased()
            let cond = (eco.isEmpty ? "" : eco + " · ") + pkg + ver
            let reason = str(d, "reason")
            // Only a real block is red. A version list run through the age
            // filter ("rewritten" — every one, filtered or not) and a stripped
            // install script are the engine doing its normal job: blue.
            let decision: String
            let kind: Decision
            switch outcome {
            case "allowed", "passed":
                decision = fetch == "metadata"
                    ? NSLocalizedString("checked", comment: "Security Timeline decision: package index looked up")
                    : NSLocalizedString("downloaded", comment: "Security Timeline decision: package fetched")
                kind = .allowed
            case "rewritten":
                decision = NSLocalizedString("checked — versions newer than the cooldown hidden",
                                             comment: "Security Timeline decision: age-gated package index")
                kind = .info
            case "stripped":
                decision = NSLocalizedString("install scripts stripped", comment: "Security Timeline decision")
                kind = .info
            case "unchecked":
                // The strip couldn't read the tarball: it went through as-is.
                decision = NSLocalizedString("downloaded — install scripts could not be checked",
                                             comment: "Security Timeline decision: npm tarball passed through unread")
                kind = .blocked
            case "overridden":
                // A reputation block the user let through (allowlist or prompt).
                decision = String(format: NSLocalizedString("downloaded — allowed by you despite: %@",
                                                            comment: "Security Timeline decision: supply-chain block overridden; %@ = the block's reason"),
                                  reason ?? "a reputation warning")
                kind = .info
            default:
                decision = reason.map { "\(outcome) — \($0)" } ?? outcome
                kind = .blocked
            }
            var e = row(NSLocalizedString("Supply chain", comment: "Security Timeline engine"), cond, decision, kind)
            if outcome == "blocked", case .bool(true)? = d["overridable"], !eco.isEmpty, pkg != "?" {
                e.package = PackageRef(ecosystem: eco, name: pkg)
            }
            return e

        case "egress.firewall":
            // The destination as the guest asked for it. The switch names a
            // flow by its DNS-snooped names (the queried name first); should
            // that first name still be a CDN / load-balancer server
            // (`dyna.wikimedia.org`) while another is the site
            // (`www.wikipedia.org`), the site is the row's host and the
            // server an alias — the same requested-name-first the blocked
            // rows (SNI / CONNECT host) get.
            var snooped: [String] = []
            if case .array(let names)? = d["hostnames"] {
                for case .string(let n) in names where !snooped.contains(n) { snooped.append(n) }
            }
            var primary = str(d, "host")
            if let p = primary, FirewallRuleActions.isServerName(p),
               let site = snooped.first(where: { !FirewallRuleActions.isServerName($0) }) {
                primary = site
            }
            let host = primary ?? str(d, "ip") ?? "?"
            let action = (str(d, "action") ?? "allowed").lowercased()
            // An OpenShell `audit` endpoint records the violation but
            // forwards the request.
            let kind: Decision = action == "audit" ? .info : (action.contains("allow") ? .allowed : .blocked)
            // The verdict word, localized (the event carries English
            // "allow"/"deny", older ones "allowed"/"blocked").
            let word = kind == .info
                ? NSLocalizedString("audit", comment: "Security Timeline firewall decision word: an OpenShell audit endpoint let a request through that its rules would deny")
                : kind == .allowed
                ? NSLocalizedString("allow", comment: "Security Timeline firewall decision word: the connection was let through")
                : NSLocalizedString("deny", comment: "Security Timeline firewall decision word: the connection was refused")
            // A `web` rule's verb decision (or an OpenShell L7 request
            // decision) carries the request: show it like a guardrails block
            // ("POST httpbin.org/post").
            if let method = str(d, "method"), !method.isEmpty {
                let cond = "\(method) \(host)\(str(d, "path") ?? "")"
                let decision = str(d, "reason").map { "\(word) — \($0)" } ?? word
                return row(NSLocalizedString("Firewall", comment: "Security Timeline engine"), cond, decision, kind)
            }
            let port = int(d, "port").map { ":\($0)" } ?? ""
            let proto = str(d, "proto").map { " \($0)" } ?? ""
            // A ruleset decision names what decided: the matching rule, or the
            // default action. Older events carry neither key — left as they
            // were. Transport drops (IPv6 / QUIC / fragments) say by_policy false.
            var byPolicy = d["rule"] != nil
            if case .bool(let v)? = d["by_policy"] { byPolicy = v }
            let rule = str(d, "rule")
            var decision = word
            if byPolicy {
                // OpenShell decisions name no pf rule; theirs is the reason
                // (no matching policy, a destination that failed validation…).
                decision = rule.map { "\(word) — \($0)" }
                    ?? str(d, "reason").map { "\(word) — \($0)" }
                    ?? String(format: NSLocalizedString("%@ — default policy",
                                                        comment: "Security Timeline decision: firewall verdict from the unmatched-traffic default; %@ = the localized allow/deny word"),
                              word)
            }
            // An open connection the firewall cut when its rules changed
            // (a rule switched off, expired, or a new deny).
            var closed = false
            if case .bool(true)? = d["closed"] {
                closed = true
                let why = str(d, "previous_rule").map {
                    String(format: NSLocalizedString("“%@” no longer allows it",
                                                     comment: "Security Timeline: why an open connection was closed; %@ = the rule that had allowed it"), $0)
                } ?? decision
                // Which route the cut connection took: the guest's proxy
                // (HTTPS_PROXY, via vsock) or direct (the transparent route).
                switch str(d, "layer") {
                case "proxy"?:
                    decision = String(format: NSLocalizedString("connection closed (proxy) — %@",
                                                                comment: "Security Timeline decision: an open connection through the workspace's HTTP proxy cut by a firewall change; %@ = why"),
                                      why)
                case .some:
                    decision = String(format: NSLocalizedString("connection closed (direct) — %@",
                                                                comment: "Security Timeline decision: an open direct (not proxied) connection cut by a firewall change; %@ = why"),
                                      why)
                case nil:
                    decision = String(format: NSLocalizedString("connection closed — %@",
                                                                comment: "Security Timeline decision: an open connection cut by a firewall change; %@ = why"),
                                      why)
                }
            }
            var e = row(NSLocalizedString("Firewall", comment: "Security Timeline engine"),
                        "\(host)\(port)\(proto)", decision, kind)
            var aliases: [String] = snooped.filter { $0 != primary }
            if let original = str(d, "host"), original != primary, !aliases.contains(original) {
                aliases.insert(original, at: 0)
            }
            e.firewall = Firewall(host: primary, ip: str(d, "ip") ?? str(d, "dst_ip"), port: int(d, "port"),
                                  proto: str(d, "proto"), rule: rule,
                                  denied: kind == .blocked, byPolicy: byPolicy, aliases: aliases,
                                  exe: kind == .blocked ? str(d, "exe") : nil)
            // Allowed connections are routine: repeats to one destination
            // fold into one counted row (blocks and cuts stay one row each).
            if kind == .allowed, !closed {
                e.coalesceKey = "egress_allow|\(primary ?? str(d, "ip") ?? "")|\(int(d, "port") ?? 0)|\(str(d, "proto") ?? "")|\(rule ?? "")"
            }
            return e

        case "credential.consent":
            // The user's answer to a credential-approval prompt (or its
            // absence): every grant, deny and timeout is a row.
            let cred = SecretFingerprint.redactLegacy(str(d, "credential") ?? "credential")
            let scope = SecretFingerprint.redactLegacy(str(d, "scope") ?? "")
            let cond = scope.isEmpty ? cred : "\(cred) — \(scope)"
            let engine = NSLocalizedString("Credential approval", comment: "Security Timeline engine")
            switch str(d, "decision") ?? "" {
            case "allow_1h":
                return row(engine, cond, NSLocalizedString("allowed for 1 hour", comment: "Security Timeline decision"), .allowed)
            case "allow_5m":
                return row(engine, cond, NSLocalizedString("allowed for 5 minutes", comment: "Security Timeline decision"), .allowed)
            case "allow_session":
                return row(engine, cond, NSLocalizedString("allowed for the rest of the session", comment: "Security Timeline decision"), .allowed)
            case "timeout":
                return row(engine, cond, NSLocalizedString("denied — no answer in time; the next request asks again",
                                                           comment: "Security Timeline decision: consent prompt timed out"), .blocked)
            case "deny_remembered":
                var e = row(engine, cond, NSLocalizedString("denied — you said no a moment ago",
                                                            comment: "Security Timeline decision: a remembered Don't allow"), .blocked)
                e.coalesceKey = "consent_deny|\(profileID.uuidString)|\(str(d, "credential_id") ?? cred)"
                return e
            default:
                return row(engine, cond, NSLocalizedString("denied by you", comment: "Security Timeline decision"), .blocked)
            }

        case "credential.ssh_sign":
            let label = str(d, "key_label").flatMap { $0.isEmpty ? nil : $0 } ?? "SSH key"
            let knd = str(d, "key_kind").map { " (\($0))" } ?? ""
            return row(NSLocalizedString("Credential used", comment: "Security Timeline engine"), "SSH key “\(label)”\(knd)",
                       NSLocalizedString("signed", comment: "Security Timeline decision"), .allowed)

        case "credential.aws_sign":
            let svc = str(d, "service") ?? "aws"
            let method = str(d, "method") ?? ""
            let host = str(d, "host") ?? ""
            let cond = "AWS \(svc) \(method) \(host)"
                .trimmingCharacters(in: .whitespaces)
            return row(NSLocalizedString("Credential used", comment: "Security Timeline engine"), cond,
                       NSLocalizedString("signed", comment: "Security Timeline decision"), .allowed)

        case "guardrails.block":
            let host = str(d, "host") ?? "?"
            let method = str(d, "method") ?? ""
            let path = str(d, "path") ?? ""
            let cond = "\(method) \(host)\(path)".trimmingCharacters(in: .whitespaces)
            let decision = str(d, "reason").map { "blocked — \($0)" } ?? "blocked"
            // A firewall `web` rule's verb denial goes through the same 403
            // path; the proxy tags it so it isn't credited to Guardrails.
            let engine = (str(d, "engine") ?? str(d, "source") ?? "").lowercased()
            let isFirewall = engine == "firewall" || engine == "egress"
            return row(isFirewall
                           ? NSLocalizedString("Firewall", comment: "Security Timeline engine")
                           : NSLocalizedString("Guardrails", comment: "Security Timeline engine"),
                       cond, decision, .blocked)

        case "tls.upstream_untrusted":
            let host = str(d, "host") ?? "?"
            let reason = str(d, "reason") ?? "certificate not trusted by the host"
            return row(NSLocalizedString("Upstream TLS", comment: "Security Timeline engine"), host, "blocked — \(reason)", .blocked)

        case "tls.insecure_bypass":
            let host = str(d, "host") ?? "?"
            return row(NSLocalizedString("Upstream TLS", comment: "Security Timeline engine"), host,
                       NSLocalizedString("allowed — certificate validation skipped (X-bromure-insecure); no credentials injected",
                                         comment: "Security Timeline decision"), .allowed)

        case "privacy.pii_swap":
            // Counts only — the values themselves never leave the proxy.
            let host = str(d, "host") ?? "?"
            let n = int(d, "count") ?? 0
            let parts: [(String, String, String)] = [
                ("name", NSLocalizedString("1 name", comment: "PII swap count"),
                 NSLocalizedString("%d names", comment: "PII swap count")),
                ("email", NSLocalizedString("1 email", comment: "PII swap count"),
                 NSLocalizedString("%d emails", comment: "PII swap count")),
                ("phone", NSLocalizedString("1 phone number", comment: "PII swap count"),
                 NSLocalizedString("%d phone numbers", comment: "PII swap count")),
                ("address", NSLocalizedString("1 address", comment: "PII swap count"),
                 NSLocalizedString("%d addresses", comment: "PII swap count")),
                ("card", NSLocalizedString("1 card number", comment: "PII swap count"),
                 NSLocalizedString("%d card numbers", comment: "PII swap count")),
                ("ssn", NSLocalizedString("1 SSN", comment: "PII swap count"),
                 NSLocalizedString("%d SSNs", comment: "PII swap count")),
                ("identifier", NSLocalizedString("1 ID number", comment: "PII swap count"),
                 NSLocalizedString("%d ID numbers", comment: "PII swap count")),
            ]
            let what = parts.compactMap { k, one, many in
                int(d, k).flatMap { $0 == 1 ? one : $0 > 1 ? String(format: many, $0) : nil }
            }.joined(separator: " · ")
            // The per-request model budget ran out: part of the new text was
            // scanned by the pattern recognizers alone.
            var partial = false
            if case .bool(let v)? = d["partial"] { partial = v }
            var e = row(NSLocalizedString("PII protection", comment: "Security Timeline engine"),
                        n == 0 && what.isEmpty ? host : "\(what.isEmpty ? String(n) : what) → \(host)",
                        partial
                            ? NSLocalizedString("partial — model budget reached; pattern rules only", comment: "Security Timeline decision")
                            : NSLocalizedString("swapped for stand-ins", comment: "Security Timeline decision"),
                        .info)
            e.count = n
            return e

        case "content_scan.skipped":
            // An AI request that went out without the content scans (body too
            // large, or compressed in a way the proxy can't decode). Credited to
            // the engine(s) that would have scanned it; blue, not a block.
            let host = str(d, "host") ?? "?"
            let reason = str(d, "reason") ?? "unknown reason"
            var ids: [String] = []
            if case .array(let a)? = d["engines"] {
                ids = a.compactMap { if case .string(let v) = $0 { return v.lowercased() } else { return nil } }
            } else if let one = str(d, "engines") {
                ids = one.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let pi = NSLocalizedString("Prompt injection", comment: "Security Timeline engine")
            let pii = NSLocalizedString("PII protection", comment: "Security Timeline engine")
            let names = ids.compactMap { id -> String? in
                switch id {
                case "prompt_injection", "promptinjection", "prompt injection": return pi
                case "pii", "pii_protection", "pii protection": return pii
                default: return nil
                }
            }
            let engine = names.first ?? pi
            // Both engines missed it: one row, the other named in the condition.
            let cond = names.count > 1 ? "\(host) (\(names.joined(separator: " + ")))" : host
            // Fail closed: a body the proxy couldn't decode was refused, not sent.
            let blocked = str(d, "action")?.lowercased() == "blocked"
            var e = blocked
                ? row(engine, cond,
                      String(format: NSLocalizedString("blocked, not sent — %@", comment: "Security Timeline decision: request refused because the content scans couldn't read it; %@ = reason"), reason),
                      .blocked)
                : row(engine, cond,
                      String(format: NSLocalizedString("not scanned — %@", comment: "Security Timeline decision: content scans skipped; %@ = reason"), reason),
                      .info)
            // Every occurrence is emitted; repeats fold into one row with a
            // count so a per-request miss reads "×N", not a single quiet row.
            e.coalesceKey = "content_scan|\(blocked ? "blocked" : "skipped")|\(host.lowercased())|\(reason)|\(ids.joined(separator: ","))"
            return e

        case "prompt_injection.detection":
            let action = (str(d, "action") ?? "detected").lowercased()
            let detector = str(d, "detector") ?? "prompt injection"
            let src = str(d, "source").map { " in \($0)" } ?? ""
            let snippet = (str(d, "snippet") ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let shortSnip = snippet.count > 90 ? String(snippet.prefix(90)) + "…" : snippet
            let cond = "\(detector)\(src): \(shortSnip)"
            let kind: Decision = (action == "blocked") ? .blocked : .allowed
            return row(NSLocalizedString("Prompt injection", comment: "Security Timeline engine"), cond, action, kind)

        default:
            return nil
        }
    }
}
