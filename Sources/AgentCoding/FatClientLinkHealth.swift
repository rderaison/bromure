import Foundation

// MARK: - Fat-client link health (latency-adaptive timeouts + reconnect hysteresis)
//
// The mirror used to treat every failed `/state` poll as "the link is down":
// one 12 s read timeout flipped the window to "Reconnecting…", and three in a
// row on a peer host tore the P2P path down (killing every terminal riding
// it). On a LAN that's right. From Japan to a US server — 150–250 ms RTT, TCP
// over a TURN-TCP relay, the occasional multi-second loss recovery, and big
// transcript fetches sharing the connection — a slow answer is normal, and
// reacting to it as a drop made things worse (the teardown is what actually
// interrupts the user).
//
// The pieces here are pure / thread-safe value logic, unit-tested without a
// network:
//   • `LinkRTTEstimator`   — RFC 6298 SRTT/RTTVAR from request timings.
//   • `ThroughputEstimator` — EWMA bytes/s from large responses.
//   • `LinkTimeouts`       — timeouts derived from those (never below the LAN
//                             defaults, so a fast link behaves exactly as before).
//   • `LinkStats`          — the per-host, thread-safe home of the estimators,
//                             fed by `ControlClient.request`.
//   • `LinkHealthMonitor`  — the hysteresis state machine the mirror's
//                             "Reconnecting…" banner is driven by.

/// Smoothed round-trip estimator (RFC 6298 §2). Samples are request
/// time-to-first-byte on cheap calls (`GET /state`, `GET /health`), so they
/// include a channel open and the server's snapshot build — exactly what a
/// poll's timeout has to tolerate.
struct LinkRTTEstimator: Equatable {
    private(set) var srtt: TimeInterval?
    private(set) var rttvar: TimeInterval = 0
    private(set) var minRTT: TimeInterval?
    private(set) var samples = 0

    mutating func add(_ sample: TimeInterval) {
        let r = max(0, sample)
        if let s = srtt {
            rttvar = 0.75 * rttvar + 0.25 * abs(s - r)
            srtt = 0.875 * s + 0.125 * r
        } else {
            srtt = r
            rttvar = r / 2
        }
        minRTT = min(minRTT ?? r, r)
        samples += 1
    }
}

/// EWMA of delivered bytes/second, sampled from responses big enough for the
/// transfer time to dominate the per-request overhead.
struct ThroughputEstimator: Equatable {
    static let minSampleBytes = 32 * 1024
    private(set) var bytesPerSecond: Double?

    mutating func add(bytes: Int, seconds: TimeInterval) {
        guard bytes >= Self.minSampleBytes, seconds > 0.005 else { return }
        let rate = Double(bytes) / seconds
        if let b = bytesPerSecond { bytesPerSecond = 0.7 * b + 0.3 * rate } else { bytesPerSecond = rate }
    }
}

/// Timeouts derived from the measured link. Every one is floored at the value
/// the LAN-tuned code always used, so only a slow link stretches them.
enum LinkTimeouts {
    /// Ceiling for the adaptive per-read idle timeout: past this, a silent
    /// read is a dead connection however slow the link is.
    static let recvIdleCap: TimeInterval = 45

    /// Per-read idle timeout (SO_RCVTIMEO) for a control request. `base` is
    /// what the caller asked for (12 s for a plain control call, more for a
    /// long-running exec). SO_RCVTIMEO bounds the gap between two reads, not
    /// the whole transfer, so it's a "no byte for this long" limit — the
    /// adaptive part covers a slow link's loss recovery (an RTO backs off
    /// exponentially; over TCP-in-TCP through a relay a few in a row are
    /// seconds of silence on a link that's still up).
    static func recvIdle(base: TimeInterval, srtt: TimeInterval?, rttvar: TimeInterval) -> TimeInterval {
        guard let srtt else { return base }
        let adaptive = 8 + 16 * (srtt + 4 * rttvar)
        return max(base, min(recvIdleCap, adaptive))
    }

    /// Minimum gap between two fast `/state` polls. 0.75 s on a LAN; on a slow
    /// link a poll is ~3 round trips (channel open, exec, request), and
    /// polling faster than that only queues snapshots behind each other.
    static func pollGap(srtt: TimeInterval?) -> TimeInterval {
        guard let srtt else { return 0.75 }
        return min(3.0, max(0.75, 2.5 * srtt))
    }

    /// How long an SSH channel open may wait with the connection otherwise
    /// silent before the connection is declared wedged (`base`, 15 s), and
    /// the hard ceiling while bytes keep arriving on it (a big transfer ahead
    /// of the open on a slow link).
    static let channelOpenStall: TimeInterval = 15
    static let channelOpenCeiling: TimeInterval = 90
}

/// Per-host link measurements, fed by every `ControlClient.request` that runs
/// over the host's SSH transport. Thread-safe: requests run on background
/// queues; the mirror reads it on main.
final class LinkStats: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [UUID: LinkStats] = [:]

    /// The shared instance for a remote host (one per host id, process-wide).
    static func shared(for hostID: UUID) -> LinkStats {
        registryLock.lock(); defer { registryLock.unlock() }
        if let s = registry[hostID] { return s }
        let s = LinkStats()
        registry[hostID] = s
        return s
    }

    private let lock = NSLock()
    private var rtt = LinkRTTEstimator()
    private var throughput = ThroughputEstimator()
    private var lastProgress: Date?
    private var lastRTTSample: TimeInterval?

    init() {}

    /// A request's time to first response byte (only cheap calls — see
    /// `ControlClient.samplesLatency`).
    func recordLatency(_ seconds: TimeInterval) {
        lock.lock(); rtt.add(seconds); lastRTTSample = seconds; lock.unlock()
    }

    func recordTransfer(bytes: Int, seconds: TimeInterval) {
        lock.lock(); throughput.add(bytes: bytes, seconds: seconds); lock.unlock()
    }

    /// Bytes arrived on some request just now: the link is alive, even if the
    /// request they belong to is a slow one.
    func noteProgress(at now: Date = Date()) {
        lock.lock(); lastProgress = now; lock.unlock()
    }

    var lastProgressAt: Date? { lock.lock(); defer { lock.unlock() }; return lastProgress }

    func recvIdleTimeout(base: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return LinkTimeouts.recvIdle(base: base, srtt: rtt.srtt, rttvar: rtt.rttvar)
    }

    struct Snapshot: Equatable {
        var srtt: TimeInterval?
        var rttvar: TimeInterval
        var minRTT: TimeInterval?
        var lastRTT: TimeInterval?
        var samples: Int
        var bytesPerSecond: Double?
        var lastProgressAt: Date?
        var recvIdleTimeout: TimeInterval
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(srtt: rtt.srtt, rttvar: rtt.rttvar, minRTT: rtt.minRTT, lastRTT: lastRTTSample,
                        samples: rtt.samples, bytesPerSecond: throughput.bytesPerSecond,
                        lastProgressAt: lastProgress,
                        recvIdleTimeout: LinkTimeouts.recvIdle(base: 12, srtt: rtt.srtt, rttvar: rtt.rttvar))
    }

    /// One-line human readout ("request RTT 820 ms (min 610, ±90) · 1.4 MB/s ·
    /// relay"), for the window's link tooltip, the debug state and the log.
    static func describe(_ s: Snapshot, path: String?) -> String {
        var parts: [String] = []
        if let srtt = s.srtt {
            var t = "request RTT \(ms(srtt))"
            var extra: [String] = []
            if let m = s.minRTT { extra.append("min \(ms(m))") }
            extra.append("±\(ms(s.rttvar))")
            t += " (" + extra.joined(separator: ", ") + ")"
            parts.append(t)
        } else {
            parts.append("request RTT not measured yet")
        }
        if let b = s.bytesPerSecond {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + "/s")
        }
        if let path { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    private static func ms(_ t: TimeInterval) -> String { "\(Int((t * 1000).rounded())) ms" }
}

/// Hysteresis between "a poll failed" and "the link is down". Pure and
/// time-injected (unit-tested).
///
/// - A success (a 200 poll, a pushed snapshot) makes the link live at once.
/// - Failures only take it down once BOTH hold: the link has been silent for
///   `minSilenceBeforeDown` (no success and no bytes on any request), and
///   either `downAfterFailures` polls failed in a row or the silence reached
///   `downAfterSilence`. Until then it reads `.slow`: content stays live, a
///   calm indicator says the link is struggling.
/// - Bytes still arriving on another request (a big transcript download) keep
///   the link out of `.down`: it's saturated, not gone.
/// - A link that's merely high-latency (no failures) reads `.slow` when the
///   smoothed request RTT exceeds `slowRTT`.
struct LinkHealthMonitor: Equatable {
    enum State: Equatable { case connecting, live, slow, down }

    static let downAfterFailures = 3
    static let downAfterSilence: TimeInterval = 30
    static let minSilenceBeforeDown: TimeInterval = 6
    static let slowRTT: TimeInterval = 2.0
    /// Quiet this long with no failure yet still reads `.slow`.
    static let slowAfterSilence: TimeInterval = 12

    private(set) var lastSuccessAt: Date?
    private(set) var consecutiveFailures = 0

    mutating func recordSuccess(at now: Date) {
        lastSuccessAt = now
        consecutiveFailures = 0
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }

    /// Forget everything (a deliberate reconnect, a new host).
    mutating func reset() { self = LinkHealthMonitor() }

    func state(at now: Date, lastProgressAt: Date? = nil, srtt: TimeInterval? = nil) -> State {
        guard let success = lastSuccessAt else {
            return consecutiveFailures > 0 ? .down : .connecting
        }
        let alive = max(success, lastProgressAt ?? .distantPast)
        let silence = now.timeIntervalSince(alive)
        if consecutiveFailures == 0 {
            // A black-holed link fails nothing until a request times out
            // (up to the 45 s cap): say so once it's been quiet for longer
            // than any healthy poll gap (5 s with push) would explain.
            if silence >= Self.slowAfterSilence { return .slow }
            if let srtt, srtt > Self.slowRTT { return .slow }
            return .live
        }
        if silence >= Self.minSilenceBeforeDown,
           consecutiveFailures >= Self.downAfterFailures || silence >= Self.downAfterSilence {
            return .down
        }
        return .slow
    }
}

/// Test/debug knob: make the fat client's SSH transport behave like a slow
/// link, to reproduce WAN behaviour on a LAN. Env vars work in every build;
/// the matching UserDefaults keys only in debug builds.
///
///   BROMURE_FATCLIENT_SIM_RTT_MS     round trip added (half each direction)
///   BROMURE_FATCLIENT_SIM_JITTER_MS  extra random 0…N ms per packet, each way
///   BROMURE_FATCLIENT_SIM_KBPS       downstream bandwidth cap (kilobytes/s)
///
/// (defaults: `fatclient.sim.rttMs`, `fatclient.sim.jitterMs`, `fatclient.sim.kbps`)
/// Applied to every SSH connection the dialer builds (all lanes, direct and
/// peer), so the handshake, channel opens and every request see it.
struct LinkSimulation: Equatable {
    var rttMs: Int = 0
    var jitterMs: Int = 0
    var kbps: Int = 0

    var isActive: Bool { rttMs > 0 || jitterMs > 0 || kbps > 0 }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                defaults: UserDefaults? = nil) -> LinkSimulation {
        func value(_ envKey: String, _ defaultsKey: String) -> Int {
            if let s = env[envKey], let v = Int(s.trimmingCharacters(in: .whitespaces)) { return max(0, v) }
            #if DEBUG
            let d = defaults ?? UserDefaults.standard
            if d.object(forKey: defaultsKey) != nil { return max(0, d.integer(forKey: defaultsKey)) }
            #endif
            return 0
        }
        return LinkSimulation(rttMs: value("BROMURE_FATCLIENT_SIM_RTT_MS", "fatclient.sim.rttMs"),
                              jitterMs: value("BROMURE_FATCLIENT_SIM_JITTER_MS", "fatclient.sim.jitterMs"),
                              kbps: value("BROMURE_FATCLIENT_SIM_KBPS", "fatclient.sim.kbps"))
    }

    /// Read once per process (the dialer consults it per connection build).
    static let current = LinkSimulation.fromEnvironment()

    var label: String {
        var p: [String] = []
        if rttMs > 0 { p.append("rtt \(rttMs) ms") }
        if jitterMs > 0 { p.append("jitter ≤\(jitterMs) ms") }
        if kbps > 0 { p.append("\(kbps) KB/s down") }
        return p.joined(separator: ", ")
    }
}
