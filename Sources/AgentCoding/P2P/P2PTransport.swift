import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Candidate TCP connection

/// Low-level TCP connect used to validate and use candidates. Handles IPv4 and
/// IPv6 numeric addresses with a bounded connect timeout (a candidate that
/// hangs must not stall the whole ladder).
enum P2PTCP {
    /// Non-blocking connect to a numeric `ip:port`, waiting at most `timeout`.
    /// Returns a connected blocking fd (caller owns/closes it), or nil.
    static func connect(ip: String, port: Int, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }

        // Non-blocking connect so we can enforce `timeout`.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = info.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, info.pointee.ai_addrlen)
        }
        if rc == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
        guard errno == EINPROGRESS else { Darwin.close(fd); return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(max(1, timeout * 1000))
        let pr = poll(&pfd, 1, ms)
        guard pr > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { Darwin.close(fd); return nil }

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 else {
            Darwin.close(fd); return nil
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}

// MARK: - Path types (surfaced to the UI as a connection-quality pill)

/// Which rung of the candidate ladder carried a session. Feeds the toolbar
/// network-state pill: `Direct (LAN) / Direct / Relayed`.
enum P2PPath: String, Equatable {
    case lan                 // a same-network host candidate
    case direct              // a globally reachable host / srflx / port-mapped path
    case relay               // TURN fallback (metered)

    var reportKind: ConnectionReport.PathKind {
        switch self {
        case .lan, .direct: return .direct
        case .relay:        return .relay
        }
    }

    var uiLabel: String {
        switch self {
        case .lan:    return "Direct (LAN)"
        case .direct: return "Direct"
        case .relay:  return "Relayed"
        }
    }
}

// MARK: - Direct dialer

/// Tries a candidate list best-first and returns the winning candidate + a live
/// connected fd, classifying the path. LAN vs global is inferred from the
/// candidate's address (RFC1918 / same-subnet → LAN). A `relay` candidate is a
/// TURN relayed transport address the LISTENER allocated (`TurnRelayListener`)
/// — to this dialer it's just another TCP endpoint (the plan's "ordinary TCP
/// connection, zero new transport code"), ranked last by prio so direct paths
/// always win when reachable.
enum P2PDirectDialer {
    struct Win {
        let candidate: P2PCandidate
        let fd: Int32
        let path: P2PPath
    }

    /// How many candidates race at once. A peer advertises one address per live
    /// interface plus its srflx/relay rungs; the cap is a sanity bound, not a
    /// throttle (each racer is one blocked connect, not real work).
    private static let maxConcurrent = 24
    /// After the first candidate connects, how long to keep listening for a
    /// BETTER (higher-priority) one before committing. Direct beats relayed, and
    /// a relay that answers 100 ms sooner shouldn't win the session for its
    /// whole life — but nobody should wait longer than this for the upgrade.
    private static let upgradeGrace: TimeInterval = 0.25

    /// Race every candidate at once and take the best one that connects.
    ///
    /// This used to walk the ladder one candidate at a time, which made the
    /// common case pathologically slow: a Mac advertises an address per live
    /// interface (Wi-Fi, Ethernet, VPN tunnels, VM bridges), a phone off that
    /// LAN can reach NONE of them, and each dead rung burned the full
    /// `perCandidateTimeout` before the relay — always ranked last — got its
    /// turn. Six unreachable host candidates meant ~18 s of nothing. Racing them
    /// costs one blocked connect per candidate and finishes as soon as the first
    /// one answers, so establishment is bounded by the fastest working path
    /// (plus `upgradeGrace`) instead of the sum of every broken one.
    ///
    /// `perCandidateTimeout` bounds each attempt; `overallDeadline` the lot.
    static func dial(candidates: [P2PCandidate],
                     perCandidateTimeout: TimeInterval = 3,
                     overallDeadline: Date) -> Win? {
        let ordered = candidates
            .filter { $0.proto == .tcp }
            .sorted { $0.prio > $1.prio }
            .prefix(maxConcurrent)
        guard !ordered.isEmpty else { return nil }
        let budget = min(perCandidateTimeout, overallDeadline.timeIntervalSinceNow)
        guard budget > 0 else { return nil }

        let race = DialRace(topPrio: ordered[ordered.startIndex].prio, total: ordered.count)
        for c in ordered {
            Thread.detachNewThread {
                defer { race.finishOne() }
                guard !race.settled else { return }
                guard let fd = P2PTCP.connect(ip: c.ip, port: c.port, timeout: budget) else { return }
                race.offer(Win(candidate: c, fd: fd, path: pathFor(c)))
            }
        }
        return race.result(grace: upgradeGrace, deadline: overallDeadline)
    }

    /// Just probe whether a candidate is currently reachable (used to verify a
    /// port map actually pierces CGNAT before advertising it).
    static func reachable(_ c: P2PCandidate, timeout: TimeInterval = 2) -> Bool {
        guard let fd = P2PTCP.connect(ip: c.ip, port: c.port, timeout: timeout) else { return false }
        Darwin.close(fd)
        return true
    }

    private static func pathFor(_ c: P2PCandidate) -> P2PPath {
        if c.kind == .relay { return .relay }
        if c.kind == .host && isPrivate(c.ip) { return .lan }
        return .direct
    }

    /// Collects the racers' results, keeps the best, and closes every loser's
    /// socket so a race never leaks an fd (the winner's fd is the caller's).
    private final class DialRace: @unchecked Sendable {
        private let cond = NSCondition()
        private let topPrio: Int
        private let total: Int
        private var best: Win?
        private var firstWinAt: Date?
        private var finished = 0
        private var resolved = false

        init(topPrio: Int, total: Int) {
            self.topPrio = topPrio
            self.total = total
        }

        /// True once `result` has committed — racers that finish afterwards drop
        /// their connection instead of handing over an fd nobody will close.
        var settled: Bool {
            cond.lock(); defer { cond.unlock() }
            return resolved
        }

        func offer(_ win: Win) {
            cond.lock()
            defer { cond.unlock() }
            if resolved { Darwin.close(win.fd); return }
            if let current = best {
                if win.candidate.prio > current.candidate.prio {
                    Darwin.close(current.fd)
                    best = win
                } else {
                    Darwin.close(win.fd)
                }
            } else {
                best = win
                firstWinAt = Date()
            }
            cond.broadcast()
        }

        func finishOne() {
            cond.lock(); finished += 1; cond.broadcast(); cond.unlock()
        }

        func result(grace: TimeInterval, deadline: Date) -> Win? {
            cond.lock()
            defer { resolved = true; cond.unlock() }
            while true {
                // Nothing better can arrive: everyone reported, or the winner is
                // already the top-priority candidate.
                if finished >= total { return best }
                if let b = best, b.candidate.prio >= topPrio { return b }
                if let first = firstWinAt, Date().timeIntervalSince(first) >= grace { return best }
                if Date() >= deadline { return best }
                let wake = min(deadline, firstWinAt?.addingTimeInterval(grace) ?? deadline)
                _ = cond.wait(until: wake)
            }
        }
    }

    private static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        // IPv6 ULA already filtered out of host candidates; treat link-local-ish
        // as private too.
        if ip.lowercased().hasPrefix("fe80") { return true }
        return false
    }
}
