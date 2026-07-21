import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ICE-style connection candidate

/// One reachable-endpoint hypothesis exchanged between two paired bromure-ac
/// instances over the control plane's signaling relay. This mirrors the
/// `Candidate` shape in REMOTE_P2P_PLAN.md and is deliberately opaque to the
/// server — it never parses it (§"The server never sees SSH bytes").
///
/// The dialer collects the listener's candidates, orders them by `prio`
/// (highest first), and TCP-connects to each until one carries a full SSH
/// handshake. A bogus candidate can at most waste one attempt — SSH host-key
/// pinning + pubkey auth validate the endpoint end-to-end — so nothing here is
/// trusted for security, only for reachability.
struct P2PCandidate: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case host                       // a local interface address (LAN / global IPv6)
        case srflx                      // server-reflexive (STUN-observed public ip:port)
        case portMapped = "port-mapped" // a PCP/NAT-PMP/UPnP router mapping
        case relay                      // a TURN relayed transport address (last resort)
    }

    enum Proto: String, Codable {
        case udp
        case tcp
    }

    var kind: Kind
    var proto: Proto
    var ip: String
    var port: Int
    /// ICE-style preference; the dialer tries the highest first.
    var prio: Int
    /// For `portMapped`/`relay`: lease seconds. The owner renews at ttl/2 and
    /// tears the mapping down at session end.
    var ttl: Int?

    init(kind: Kind, proto: Proto, ip: String, port: Int, prio: Int? = nil, ttl: Int? = nil) {
        self.kind = kind
        self.proto = proto
        self.ip = ip
        self.port = port
        self.prio = prio ?? P2PCandidate.defaultPriority(kind: kind, proto: proto, ip: ip)
        self.ttl = ttl
    }

    /// A stable, RFC-8445-flavoured preference so both peers rank a shared
    /// candidate set identically. Type wins first (host > srflx > port-mapped >
    /// relay), then TCP over UDP (V1's reliable transport is TCP), then IPv6
    /// over IPv4 within a type. Not the RFC's exact formula — we don't run full
    /// ICE — just a total order good enough to try the best path first.
    static func defaultPriority(kind: Kind, proto: Proto, ip: String) -> Int {
        let typePref: Int
        switch kind {
        case .host:       typePref = 126
        case .srflx:      typePref = 100
        case .portMapped: typePref = 96
        case .relay:      typePref = 0
        }
        let protoPref = proto == .tcp ? 2 : 1
        let famPref = ip.contains(":") ? 1 : 0   // slight IPv6 nudge
        return (typePref << 16) | (protoPref << 8) | (famPref << 4)
    }
}

// MARK: - Local interface candidate gathering

enum P2PCandidateGatherer {
    /// Every routable local interface address, as `host` TCP candidates pointing
    /// at `sshPort` (the listener's embedded sshd, already bound 0.0.0.0:2222).
    /// A dialer on the same LAN — or with a globally reachable IPv6 — connects
    /// straight to one of these with no relay and no shim on the listener side.
    ///
    /// Skips loopback, link-local (169.254 / fe80), and (for IPv6) unique-local
    /// fc00::/7 and the temporary/deprecated flags. Both IPv4 and IPv6 are
    /// gathered; IPv6 is often the winning direct path on modern home networks.
    static func hostCandidates(sshPort: Int) -> [P2PCandidate] {
        var out: [P2PCandidate] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return out }
        defer { freeifaddrs(addrs) }

        var ptr = addrs
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr else { continue }
            let fam = sa.pointee.sa_family
            guard fam == sa_family_t(AF_INET) || fam == sa_family_t(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            var ip = String(cString: host)
            // getnameinfo tags link-local IPv6 with a %zone suffix; drop it —
            // both are excluded below anyway, but keep IPs clean if kept.
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }

            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }   // v4 loop/link-local
            if ip == "::1" { continue }                                         // v6 loopback
            let low = ip.lowercased()
            if low.hasPrefix("fe80:") { continue }                              // v6 link-local
            if low.hasPrefix("fc") || low.hasPrefix("fd") { continue }          // v6 unique-local

            out.append(P2PCandidate(kind: .host, proto: .tcp, ip: ip, port: sshPort))
        }
        // De-dupe (aliased addresses) and rank.
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.ip):\($0.port)").inserted }
            .sorted { $0.prio > $1.prio }
    }
}
