import Foundation
import SandboxEngine

/// The connections the MiTM has open on a workspace's behalf — every CONNECT
/// tunnel and forward-proxy request on the proxy route (`HTTPMitmConnection.
/// drive`), and every MiTM'd flow on the transparent route — with the
/// destination and the rule that let each one through.
///
/// The firewall is otherwise only consulted when a connection opens. The
/// switch re-checks every frame of the transparent route, but the proxy route
/// arrives over vsock and never crosses it: switching a rule off (or its
/// expiry, or the workspace stopping an until-stop rule) would leave an
/// established download running to completion. So on every policy change
/// (`MitmEngine.setGuardrailsConfig`) each open connection of that workspace
/// is re-evaluated against the new rules, and the ones now denied are cut —
/// both sides — with a Security Timeline row saying so.
final class EgressConnectionRegistry: @unchecked Sendable {
    static let shared = EgressConnectionRegistry()

    struct Entry: Sendable {
        let id: UInt64
        let profileID: UUID
        let host: String
        let port: UInt16
        /// "proxy" (CONNECT / forward proxy) or "transparent".
        let route: String
        /// The rule that allowed it when it opened (nil: the default action).
        let rule: String?
        /// Close both sides. Called at most once, never under the lock.
        let cut: @Sendable () -> Void
    }

    /// Why an open connection was closed.
    struct Closure: Sendable, Equatable {
        let host: String
        let port: UInt16
        let route: String
        /// The rule that had allowed it.
        let previousRule: String?
        /// The rule that now denies it (nil: the default action).
        let denyingRule: String?
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 1
    /// Reports a cut (default: an `egress.firewall` event). Replaceable in tests.
    var onClose: @Sendable (UUID, Closure) -> Void = { pid, c in
        EgressConnectionRegistry.report(profileID: pid, c)
    }

    init() {}

    /// Track an open connection; returns the token to `unregister` it with.
    /// Unregister BEFORE closing the fd `cut` acts on, so a cut can never hit
    /// a reused descriptor.
    @discardableResult
    func register(profileID: UUID, host: String, port: Int, route: String, rule: String?,
                  cut: @escaping @Sendable () -> Void) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        entries[id] = Entry(id: id, profileID: profileID, host: host.lowercased(),
                            port: UInt16(truncatingIfNeeded: port), route: route, rule: rule, cut: cut)
        return id
    }

    func unregister(_ id: UInt64) {
        lock.lock(); entries.removeValue(forKey: id); lock.unlock()
    }

    func openConnections(profileID: UUID) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.profileID == profileID }.sorted { $0.id < $1.id }
    }

    /// Re-check every open connection of `profileID` against `policy` (nil:
    /// allow-all) at `now`; cut and report the ones it denies. Returns them.
    @discardableResult
    func reevaluate(profileID: UUID, policy: EgressPolicy?, now: Date = Date()) -> [Closure] {
        guard let policy else { return [] }
        lock.lock()
        var victims: [Entry] = []
        for (id, e) in entries where e.profileID == profileID {
            if policy.verdict(ip: nil, hostnames: [e.host], proto: .tcp, port: e.port, now: now) == .deny {
                victims.append(e)
                entries.removeValue(forKey: id)
            }
        }
        lock.unlock()
        victims.sort { $0.id < $1.id }
        var out: [Closure] = []
        for e in victims {
            e.cut()
            let c = Closure(host: e.host, port: e.port, route: e.route, previousRule: e.rule,
                            denyingRule: policy.firstMatch(ip: nil, hostnames: [e.host], proto: .tcp,
                                                           port: e.port, now: now)?.text)
            out.append(c)
            onClose(profileID, c)
        }
        return out
    }

    /// The Security Timeline row (and cloud event) for a cut connection.
    static func report(profileID: UUID, _ c: Closure) {
        SupplyChainLog.shared.record(
            "[firewall] ✗ closed tcp \(c.host):\(c.port) (\(profileID.uuidString.prefix(8))) — no longer allowed")
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: "egress.firewall",
            eventData: ["action": .string("deny"), "proto": .string("tcp"),
                        "host": .string(c.host), "port": .int(Int(c.port)),
                        "layer": .string(c.route), "closed": .bool(true),
                        "previous_rule": .of(c.previousRule),
                        "rule": .of(c.denyingRule), "by_policy": .bool(true)])
    }
}

/// One firewall row per destination per minute: a busy client opening many
/// connections to the same host (or one host behind several addresses) must
/// not flood the Security Timeline. Keyed by workspace, host, port and
/// decision, so a verdict change still shows at once. Mirrors the switch's own
/// per-destination dedupe (`VMNetSwitch.fireEgress`) for the proxy route.
final class EgressReportDeduper: @unchecked Sendable {
    static let shared = EgressReportDeduper()
    static let window: TimeInterval = 60

    private struct Key: Hashable { let pid: UUID; let host: String; let port: Int; let denied: Bool }
    private let lock = NSLock()
    private var seen: [Key: Date] = [:]

    init() {}

    /// True when this verdict should be reported now (and records it).
    func shouldReport(profileID: UUID, host: String, port: Int, denied: Bool, now: Date = Date()) -> Bool {
        let k = Key(pid: profileID, host: host.lowercased(), port: port, denied: denied)
        lock.lock(); defer { lock.unlock() }
        if let last = seen[k], now.timeIntervalSince(last) < Self.window { return false }
        if seen.count > 8192 { seen = seen.filter { now.timeIntervalSince($0.value) < Self.window } }
        seen[k] = now
        return true
    }

    /// Forget a workspace's history (its rules changed): the next verdict for
    /// each destination shows up right away.
    func reset(profileID: UUID) {
        lock.lock(); seen = seen.filter { $0.key.pid != profileID }; lock.unlock()
    }
}
