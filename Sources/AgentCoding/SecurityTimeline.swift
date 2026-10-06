import Foundation

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
        /// Repeats of a routine event (same credential swapped in for the same
        /// host) share this key and fold into one row with a `count` (B40).
        public var coalesceKey: String? = nil
        /// A connection-level firewall verdict, structured — what the row's
        /// quick actions (allow / block / switch the rule off) work from.
        public var firewall: Firewall? = nil
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

        public init(host: String?, ip: String?, port: Int?, proto: String?, rule: String?,
                    denied: Bool, byPolicy: Bool, aliases: [String] = []) {
            self.host = host; self.ip = ip; self.port = port; self.proto = proto
            self.rule = rule; self.denied = denied; self.byPolicy = byPolicy
            self.aliases = aliases
        }

        var wire: [String: Any] {
            var d: [String: Any] = ["denied": denied, "byPolicy": byPolicy]
            if !aliases.isEmpty { d["aliases"] = aliases }
            if let host { d["host"] = host }
            if let ip { d["ip"] = ip }
            if let port { d["port"] = port }
            if let proto { d["proto"] = proto }
            if let rule { d["rule"] = rule }
            return d
        }

        init?(wire d: [String: Any]?) {
            guard let d else { return nil }
            self.init(host: d["host"] as? String, ip: d["ip"] as? String, port: d["port"] as? Int,
                      proto: d["proto"] as? String, rule: d["rule"] as? String,
                      denied: d["denied"] as? Bool ?? false, byPolicy: d["byPolicy"] as? Bool ?? false,
                      aliases: d["aliases"] as? [String] ?? [])
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
                    merged.firewall = e.firewall ?? old.firewall
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
    private static let cap = 5000
    /// Days of history kept on disk.
    nonisolated static let retentionDays = 90

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
        let dir = directory
        io.async { Self.prune(dir); Self.redactLegacyPreviews(in: dir) }
    }

    /// The app's timeline: persisted in the support folder, except in a test
    /// run (which must never write the user's history).
    private static func defaultDirectory() -> URL? {
        let testing = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
        guard let e = Self.map(profileID: profileID, eventType: eventType,
                               eventData: eventData, now: Date()) else { return }
        Task { @MainActor in self.append(e) }
    }

    /// Append an event of this Mac's: into the view and onto the disk log.
    public func append(_ e: Event) {
        var e = e
        if e.workspace == nil { e.workspace = workspaceName(e.profileID) }
        // Routine repeats fold into one row; the disk log keeps every raw
        // event (with its key) and `load` folds them the same way.
        Self.coalesce(e, into: &events)
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
        persist(e)
    }

    /// Clear the window. The log on disk stays (it's the audit trail); the
    /// cleared events just don't come back at the next launch.
    public func clear() {
        events.removeAll()
        remote.removeAll()
        if directory != nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.clearedAtKey)
        }
    }

    // MARK: - Disk

    nonisolated private static let dayFormatter: DateFormatter = {
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
        if let ck = e.coalesceKey { d["ck"] = ck }
        if let fw = e.firewall { d["fw"] = fw.wire }
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
                      workspace: d["w"] as? String, count: d["n"] as? Int)
        e.coalesceKey = (d["ck"] as? String).map(SecretFingerprint.redactLegacy)
        e.firewall = Firewall(wire: d["fw"] as? [String: Any])
        return e
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
        let cutoff = dayFormatter.string(from: now.addingTimeInterval(-Double(retentionDays) * 86400))
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
    public func mirrorRows(limit: Int = 750) -> [[String: Any]] {
        events.suffix(limit).map { e in
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
            if let ck = e.coalesceKey { r["ck"] = ck }
            if let fw = e.firewall { r["fw"] = fw.wire }
            return r
        }
    }

    /// Rebuild a mirrored host's events from its snapshot (fat client). The
    /// host is authoritative for its own bucket, which this replaces; this
    /// Mac's events and other hosts' are left alone.
    public func applyMirror(_ rows: [[String: Any]], host: String) {
        remote[host] = rows.compactMap { r in
            guard let engine = r["engine"] as? String,
                  let condition = r["condition"] as? String,
                  let decision = r["decision"] as? String else { return nil }
            let t = (r["t"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let pid = (r["profileID"] as? String).flatMap(UUID.init) ?? UUID()
            var e = Event(time: t, engine: engine, condition: SecretFingerprint.redactLegacy(condition),
                          decision: SecretFingerprint.redactLegacy(decision),
                          kind: Decision(wire: r["kind"] as? String ?? ""),
                          profileID: pid, workspace: r["workspace"] as? String, machine: host,
                          count: r["count"] as? Int)
            e.coalesceKey = r["ck"] as? String
            e.firewall = Firewall(wire: r["fw"] as? [String: Any])
            return e
        }
    }

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
            default:
                decision = reason.map { "\(outcome) — \($0)" } ?? outcome
                kind = .blocked
            }
            return row(NSLocalizedString("Supply chain", comment: "Security Timeline engine"), cond, decision, kind)

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
            let kind: Decision = action.contains("allow") ? .allowed : .blocked
            // The verdict word, localized (the event carries English
            // "allow"/"deny", older ones "allowed"/"blocked").
            let word = kind == .allowed
                ? NSLocalizedString("allow", comment: "Security Timeline firewall decision word: the connection was let through")
                : NSLocalizedString("deny", comment: "Security Timeline firewall decision word: the connection was refused")
            // A `web` rule's verb decision carries the request: show it like a
            // guardrails block ("POST httpbin.org/post").
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
                decision = rule.map { "\(word) — \($0)" }
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
            e.firewall = Firewall(host: primary, ip: str(d, "ip"), port: int(d, "port"),
                                  proto: str(d, "proto"), rule: rule,
                                  denied: kind == .blocked, byPolicy: byPolicy, aliases: aliases)
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
