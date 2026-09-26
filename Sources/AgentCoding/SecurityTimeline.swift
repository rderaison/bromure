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
        io.async { Self.prune(dir) }
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
        events.append(e)
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
        guard var data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        data.append(0x0A)
        return data
    }

    nonisolated static func event(fromLine line: Data) -> Event? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = d["t"] as? Double, let engine = d["e"] as? String,
              let condition = d["c"] as? String, let decision = d["d"] as? String else { return nil }
        return Event(time: Date(timeIntervalSince1970: t), engine: engine, condition: condition,
                     decision: decision, kind: Decision(wire: d["k"] as? String ?? ""),
                     profileID: (d["p"] as? String).flatMap(UUID.init) ?? UUID(),
                     workspace: d["w"] as? String, count: d["n"] as? Int)
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
        return Array(out.suffix(limit))
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
            return Event(time: t, engine: engine, condition: condition,
                         decision: decision, kind: Decision(wire: r["kind"] as? String ?? ""),
                         profileID: pid, workspace: r["workspace"] as? String, machine: host,
                         count: r["count"] as? Int)
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
            return row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                       "\(fake) → \(host)",
                       String(format: NSLocalizedString("swapped in %@", comment: "Security Timeline decision"), real), .info)

        case "credential.exfiltration":
            let fake = str(d, "fake_preview") ?? "fake"
            let cred = str(d, "credential") ?? "session token"
            let declared = str(d, "declared_host") ?? "?"
            let observed = str(d, "observed_host") ?? "?"
            return row(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                       "\(fake) (\(cred), scoped to \(declared)) → \(observed)",
                       NSLocalizedString("blocked — exfiltration attempt, VM paused", comment: "Security Timeline decision"), .blocked)

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
            default:
                decision = reason.map { "\(outcome) — \($0)" } ?? outcome
                kind = .blocked
            }
            return row(NSLocalizedString("Supply chain", comment: "Security Timeline engine"), cond, decision, kind)

        case "egress.firewall":
            let host = str(d, "host") ?? str(d, "ip") ?? "?"
            let port = int(d, "port").map { ":\($0)" } ?? ""
            let proto = str(d, "proto").map { " \($0)" } ?? ""
            let action = (str(d, "action") ?? "allowed").lowercased()
            let kind: Decision = action.contains("allow") ? .allowed : .blocked
            return row(NSLocalizedString("Firewall", comment: "Security Timeline engine"), "\(host)\(port)\(proto)", action, kind)

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
            return row(NSLocalizedString("Guardrails", comment: "Security Timeline engine"), cond, decision, .blocked)

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
            var e = row(NSLocalizedString("PII protection", comment: "Security Timeline engine"),
                        "\(what.isEmpty ? String(n) : what) → \(host)",
                        NSLocalizedString("swapped for stand-ins", comment: "Security Timeline decision"), .info)
            e.count = n
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
