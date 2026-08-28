import Foundation

/// A live, on-device record of what Bromure's security engines actually did —
/// every credential swap, firewall verdict, package check, prompt-injection
/// scan, and credential use — surfaced as a single chronological table in the
/// Security Timeline window.
///
/// Fed by tapping `BACEventEmitter` BEFORE its cloud-upload gate, so it works
/// for EVERY workspace (enrolled or not, private or not): the window is a local
/// view of the user's own machine, distinct from the enrolled-only telemetry
/// that goes to bromure.io. Purely in-memory and capped — it's a "what just
/// happened" view, not an audit store.
@MainActor
@Observable
public final class SecurityTimeline {
    public static let shared = SecurityTimeline()

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
    }

    public private(set) var events: [Event] = []
    private static let cap = 5000

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

    /// Append a pre-built event (used by the debug seed).
    public func append(_ e: Event) {
        events.append(e)
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
    }

    public func clear() { events.removeAll() }

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
            [
                "t": e.time.timeIntervalSince1970,
                "engine": e.engine,
                "condition": e.condition,
                "decision": e.decision,
                "kind": e.kind.wire,
                "profileID": e.profileID.uuidString,
            ]
        }
    }

    /// Rebuild the timeline from a host mirror snapshot (fat client). The host
    /// is authoritative, so this replaces wholesale.
    public func applyMirror(_ rows: [[String: Any]]) {
        events = rows.compactMap { r in
            guard let engine = r["engine"] as? String,
                  let condition = r["condition"] as? String,
                  let decision = r["decision"] as? String else { return nil }
            let t = (r["t"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let pid = (r["profileID"] as? String).flatMap(UUID.init) ?? UUID()
            return Event(time: t, engine: engine, condition: condition,
                         decision: decision, kind: Decision(wire: r["kind"] as? String ?? ""),
                         profileID: pid)
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

        case "supply_chain.fetch":
            let eco = str(d, "ecosystem") ?? ""
            let pkg = str(d, "package") ?? "?"
            let ver = str(d, "version").map { "@\($0)" } ?? ""
            let outcome = (str(d, "outcome") ?? "allowed").lowercased()
            let cond = (eco.isEmpty ? "" : eco + " ") + pkg + ver
            let decision = str(d, "reason").map { "\(outcome) — \($0)" } ?? outcome
            let kind: Decision = (outcome == "allowed" || outcome == "passed")
                ? .allowed : .blocked
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
