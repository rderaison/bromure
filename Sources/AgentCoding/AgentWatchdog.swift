import Foundation

/// How a workspace's agent watchdog reacts to a drifting session.
public enum AgentWatchdogMode: String, Codable, CaseIterable, Sendable {
    case off
    /// Record a detection finding (Security Timeline, OCSF) and notify.
    case alert
    /// Also cut the VM off the network and pause it, then ask the user.
    case quarantine
}

/// The out-of-band agent watchdog — Bromure's counterpart of the monitoring
/// role NVIDIA gives Sentry in its Open Agent Safety Platform: a separate
/// component in the host's trust domain (outside the VM, unreachable by the
/// agent) that judges a session's behaviour as a whole rather than one
/// request at a time, and can quarantine it in milliseconds.
///
/// Signals, scored over a sliding window:
///  - policy pressure: firewall / L7 / guardrails denials (every layer);
///  - credential abuse: unmanaged credentials, exfiltration attempts;
///  - tampering: an impersonated attestor, a binary whose hash changed;
///  - destination drift: new hosts appearing after the session settled;
///  - volume: outbound bytes far above the session's own baseline, read from
///    the network switch's counters — independent of the proxy, so a proxy
///    blind spot doesn't blind the watchdog.
/// Crossing the threshold records an OCSF detection finding and, in
/// quarantine mode, isolates the VM at the switch and pauses it.
public final class AgentWatchdog: @unchecked Sendable {
    public static let shared = AgentWatchdog()

    public struct Signal: Sendable {
        public let time: Date
        public let weight: Int
        public let kind: String
        public let detail: String
    }

    struct State {
        var signals: [Signal] = []
        var seenHosts: Set<String> = []
        var startedAt = Date()
        var lastBytes: UInt64 = 0
        var byteRates: [Double] = []           // bytes/s samples (baseline)
        var tripped = false
    }

    public static let window: TimeInterval = 60
    public static let threshold = 20
    /// New destinations before this age of a session are its baseline.
    public static let settleTime: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    /// Per-workspace mode (set by the app).
    public var modeProvider: (@Sendable (UUID) -> AgentWatchdogMode) = { _ in .off }
    /// Quarantine hook (set by the app): isolate + pause + ask.
    public var onTrip: (@Sendable (UUID, AgentWatchdogMode, [Signal]) -> Void)?

    public func reset(profileID: UUID) {
        lock.lock(); states[profileID] = nil; lock.unlock()
    }

    /// Release a quarantine: the session starts a fresh window.
    public func release(profileID: UUID) {
        lock.lock()
        if var s = states[profileID] { s.tripped = false; s.signals.removeAll(); states[profileID] = s }
        lock.unlock()
    }

    // MARK: Inputs

    /// Every security event (fed by the emitter, beside the timeline).
    public func observe(profileID: UUID, eventType: String, eventData: [String: AnyJSON], now: Date = Date()) {
        guard modeProvider(profileID) != .off else { return }
        func s(_ k: String) -> String? { if case .string(let v)? = eventData[k] { return v }; return nil }
        switch eventType {
        case "egress.firewall":
            let action = s("action") ?? ""
            let host = s("host") ?? s("ip") ?? "?"
            if action == "deny" {
                let tamper = s("layer") == "identity"
                add(profileID, Signal(time: now, weight: tamper ? 10 : 1, kind: tamper ? "tampering" : "policy_denial",
                                      detail: "\(host) — \(s("reason") ?? "denied")"))
            } else if action.hasPrefix("allow"), host != "?" {
                noteDestination(profileID, host: host, now: now)
            }
        case "guardrails.block":
            add(profileID, Signal(time: now, weight: 2, kind: "guardrails", detail: s("reason") ?? "blocked"))
        case "credential.unmanaged":
            add(profileID, Signal(time: now, weight: 6, kind: "unmanaged_credential",
                                  detail: "\(s("kind") ?? "secret") → \(s("host") ?? "?")"))
        case "credential.exfiltration":
            add(profileID, Signal(time: now, weight: 10, kind: "exfiltration",
                                  detail: "credential → \(s("observed_host") ?? "?")"))
        case "sentry.event", "sentry.alarm":
            // Kernel sentry: tampering attempts weigh enough to trip alone.
            var weight = 0
            if case .int(let w)? = eventData["weight"] { weight = w }
            if weight > 0 {
                let kind = s("category") ?? s("kind") ?? "sentry"
                add(profileID, Signal(time: now, weight: weight, kind: kind == "tampering" ? "tampering" : kind,
                                      detail: s("reason") ?? [s("kind"), s("path") ?? s("exe")].compactMap { $0 }.joined(separator: " ")))
            }
        case "sandbox.status":
            if s("filesystem") == "failed" {
                add(profileID, Signal(time: now, weight: 5, kind: "sandbox_degraded", detail: s("reason") ?? "filesystem sandbox failed"))
            }
        case "prompt_injection.detection":
            add(profileID, Signal(time: now, weight: 4, kind: "prompt_injection", detail: s("source") ?? "detected"))
        default:
            break
        }
    }

    /// Switch-side outbound byte counter for a VM, sampled periodically.
    public func sampleBytes(profileID: UUID, total: UInt64, now: Date = Date(), interval: TimeInterval) {
        guard modeProvider(profileID) != .off, interval > 0 else { return }
        lock.lock()
        var st = states[profileID] ?? State()
        let delta = total >= st.lastBytes ? total - st.lastBytes : total
        st.lastBytes = total
        let rate = Double(delta) / interval
        let baseline = st.byteRates.isEmpty ? 0 : st.byteRates.reduce(0, +) / Double(st.byteRates.count)
        st.byteRates.append(rate)
        if st.byteRates.count > 120 { st.byteRates.removeFirst() }
        states[profileID] = st
        lock.unlock()
        // 5 MB/s sustained over a sample, and 10x the session's own baseline.
        if rate > 5_000_000, rate > baseline * 10 {
            add(profileID, Signal(time: now, weight: 8, kind: "volume",
                                  detail: String(format: "%.1f MB/s outbound (baseline %.1f MB/s)",
                                                 rate / 1e6, baseline / 1e6)))
        }
    }

    private func noteDestination(_ pid: UUID, host: String, now: Date) {
        lock.lock()
        var st = states[pid] ?? State()
        let isNew = st.seenHosts.insert(host.lowercased()).inserted
        let settled = now.timeIntervalSince(st.startedAt) > Self.settleTime
        states[pid] = st
        lock.unlock()
        if isNew, settled {
            add(pid, Signal(time: now, weight: 1, kind: "new_destination", detail: host))
        }
    }

    // MARK: Scoring

    private func add(_ pid: UUID, _ signal: Signal) {
        let mode = modeProvider(pid)
        guard mode != .off else { return }
        lock.lock()
        var st = states[pid] ?? State()
        st.signals.append(signal)
        st.signals.removeAll { signal.time.timeIntervalSince($0.time) > Self.window }
        let score = st.signals.reduce(0) { $0 + $1.weight }
        let trip = score >= Self.threshold && !st.tripped
        if trip { st.tripped = true }
        let evidence = st.signals
        states[pid] = st
        lock.unlock()
        guard trip else { return }
        var data: [String: AnyJSON] = [
            "score": .int(score), "window_seconds": .int(Int(Self.window)),
            "action": .string(mode == .quarantine ? "quarantine" : "alert"),
            "signals": .array(evidence.suffix(20).map { .string("\($0.kind): \($0.detail)") }),
        ]
        data["kinds"] = .array(Array(Set(evidence.map(\.kind))).sorted().map { .string($0) })
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "watchdog.trip", eventData: data)
        onTrip?(pid, mode, evidence)
    }

    /// Current score (tests / UI).
    public func score(profileID: UUID, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (states[profileID]?.signals ?? []).filter { now.timeIntervalSince($0.time) <= Self.window }
            .reduce(0) { $0 + $1.weight }
    }
}
