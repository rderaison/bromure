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

    /// Connect to the first viable candidate. `perCandidateTimeout` bounds each
    /// attempt; `overallDeadline` bounds the whole ladder.
    static func dial(candidates: [P2PCandidate],
                     perCandidateTimeout: TimeInterval = 3,
                     overallDeadline: Date) -> Win? {
        let ordered = candidates
            .filter { $0.proto == .tcp }
            .sorted { $0.prio > $1.prio }
        for c in ordered {
            if Date() >= overallDeadline { break }
            let budget = min(perCandidateTimeout, overallDeadline.timeIntervalSinceNow)
            guard budget > 0 else { break }
            if let fd = P2PTCP.connect(ip: c.ip, port: c.port, timeout: budget) {
                return Win(candidate: c, fd: fd, path: pathFor(c))
            }
        }
        return nil
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
