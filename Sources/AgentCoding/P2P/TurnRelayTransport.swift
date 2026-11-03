import Foundation

// MARK: - TURN relay (Rung 4 — the metered fallback)

/// The relay leg of the candidate ladder. When neither peer can offer a
/// reachable direct candidate (symmetric×symmetric NAT, UDP-blocked corporate
/// networks), the session relays through coturn (REMOTE_P2P_PLAN.md §"Rung 4 —
/// TURN relay (fallback)"): the LISTENER allocates a TCP relay (RFC 6062, see
/// `TurnRelayListener`) and advertises the relayed transport address as a
/// `relay` candidate; the dialer then makes an ordinary TCP connection to it
/// (§"dialer's ssh connects to the public endpoint with zero new transport
/// code"), coturn splices the two legs, and the listener binds its half into
/// the local sshd. SSH stays end-to-end — the relay moves opaque bytes.
///
/// This enum holds the small pure pieces: credential fetch
/// (`POST /v1/connections/:id/turn-credentials`) and URL parsing/selection,
/// unit-testable without a relay.
enum TurnRelayTransport {
    /// Fetch short-lived REST credentials for this grant. These outlive the 45 s
    /// grant (they bound the relayed session, not the rendez-vous); the username
    /// is `<unix-expiry>:<connectionId>` and stops working at its timestamp.
    static func credentials(client: ControlPlaneClient, bearer: String,
                            connectionId: String) async -> TurnCredentials? {
        try? await client.turnCredentials(bearer: bearer, connectionId: connectionId)
    }

    /// Pick the endpoint for the TURN client legs (control + RFC 6062 data),
    /// preferring `turns:…?transport=tcp` (TLS, 5349) so the TURN envelope — the
    /// long-term-credential username, realm/nonce, and the XOR-obfuscated peer
    /// addresses — is encrypted to the relay, and falling back to plain
    /// `turn:…?transport=tcp` (3478) when no TLS URL is offered. The relayed
    /// payload is SSH either way; TLS here protects the metadata, not the data.
    /// `tls == true` means dial via `TurnTLSTunnel`.
    static func preferredRelayEndpoint(_ urls: [String]) -> (host: String, port: Int, tls: Bool)? {
        for url in urls where url.hasPrefix("turns:") {
            if let p = parseHostPort(fromURL: url), p.transport == "tcp" {
                return (p.host, p.port, true)
            }
        }
        if let p = preferredTCPEndpoint(urls) {
            return (p.host, p.port, false)
        }
        return nil
    }

    /// The plain `turn:…?transport=tcp` endpoint (RFC 6062 requires a TCP client
    /// leg). Kept for the STUN-Binding fallback (`stunEndpoint`) and as the
    /// non-TLS relay fallback; the relay path prefers `preferredRelayEndpoint`.
    static func preferredTCPEndpoint(_ urls: [String]) -> (host: String, port: Int, transport: String?)? {
        for url in urls where url.hasPrefix("turn:") {
            if let parsed = parseHostPort(fromURL: url), parsed.transport == "tcp" {
                return parsed
            }
        }
        return nil
    }

    /// The plain `turn:…?transport=udp` endpoint — the UDP relay leg (RFC 5766
    /// Allocate/ChannelBind, `TurnUDPClient`). No TLS variant: coturn's `turns:`
    /// listener is TLS-over-TCP, so the UDP relay stays on 3478; the metadata
    /// (peer addresses, already exchanged as srflx candidates over signaling) is
    /// the only thing in clear, and the payload is SSH, encrypted end to end.
    static func preferredUDPEndpoint(_ urls: [String]) -> (host: String, port: Int)? {
        for url in urls where url.hasPrefix("turn:") {
            if let p = parseHostPort(fromURL: url), p.transport == "udp" {
                return (p.host, p.port)
            }
        }
        return nil
    }

    /// The STUN endpoint (Binding needs no credentials): the `stun:` URL if
    /// present, else any TURN host — coturn answers Binding on the same port.
    static func stunEndpoint(_ urls: [String]) -> (host: String, port: Int, transport: String?)? {
        for url in urls where url.hasPrefix("stun:") {
            if let parsed = parseHostPort(fromURL: url) { return parsed }
        }
        return preferredTCPEndpoint(urls)
    }

    /// One STUN endpoint per distinct relay host, in `urls` order (nearest
    /// first once ranked): its `stun:` URL, else its TCP turn endpoint.
    static func stunEndpointsPerHost(_ urls: [String]) -> [(host: String, port: Int, transport: String?)] {
        distinctHosts(urls).compactMap { h in
            stunEndpoint(urls.filter { parseHostPort(fromURL: $0)?.host == h })
        }
    }

    /// Distinct relay hosts in first-seen order (a coturn `urls` list repeats
    /// each host across its stun/turn/turns entries).
    static func distinctHosts(_ urls: [String]) -> [String] {
        var hosts: [String] = []
        for u in urls {
            if let h = parseHostPort(fromURL: u)?.host, !hosts.contains(h) { hosts.append(h) }
        }
        return hosts
    }

    /// Reorder `urls` so the lowest-RTT relay's URLs come first — the "pick
    /// first" selectors above then choose the nearest relay. Probes at most the
    /// first `limit` distinct hosts in parallel (TCP connect to the port the data
    /// leg would actually use — `turns:` and its `turn:`/`stun:` share a path).
    /// Unreachable/unprobed hosts keep their original relative order, after the
    /// reachable ones. Blocking — call off-main. Returns `urls` unchanged when
    /// there's nothing to choose.
    ///
    /// TODO(scale): with a large relay fleet, have the control plane return only
    /// the nearest-K in turn-credentials so the client never probes more than K.
    static func orderURLsByRTT(_ urls: [String], limit: Int = 3,
                               timeout: TimeInterval = 1.0) -> [String] {
        let hosts = distinctHosts(urls)
        let probed = Array(hosts.prefix(limit))
        guard probed.count > 1 else { return urls }

        let lock = NSLock()
        var rtt: [String: TimeInterval] = [:]
        let group = DispatchGroup()
        for h in probed {
            let hostURLs = urls.filter { parseHostPort(fromURL: $0)?.host == h }
            let port = preferredRelayEndpoint(hostURLs)?.port
                ?? parseHostPort(fromURL: hostURLs.first ?? "")?.port ?? 3478
            group.enter()
            Thread.detachNewThread {
                let r = P2PTCP.probeRTT(host: h, port: port, timeout: timeout)
                lock.lock(); if let r { rtt[h] = r }; lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout + 1)
        lock.lock(); let measured = rtt; lock.unlock()   // snapshot; a late thread must not race the read

        FatClientLog.log("p2p: relay probe: " + probed.map {
            "\($0)=\(measured[$0].map { "\(Int($0 * 1000))ms" } ?? "unreachable")" }.joined(separator: " "))

        let reachable = probed.filter { measured[$0] != nil }.sorted { measured[$0]! < measured[$1]! }
        let order = reachable + hosts.filter { !reachable.contains($0) }
        return order.flatMap { h in urls.filter { parseHostPort(fromURL: $0)?.host == h } }
    }

    /// Parse the STUN/TURN host:port out of a coturn `urls` entry
    /// (`turn:host:3478?transport=tcp`) — small, pure, and unit-testable ahead
    /// of the data path so the credential wiring is verified end to end.
    static func parseHostPort(fromURL url: String) -> (host: String, port: Int, transport: String?)? {
        // Strip the scheme (stun:/turn:/turns:).
        guard let schemeEnd = url.firstIndex(of: ":") else { return nil }
        var rest = String(url[url.index(after: schemeEnd)...])
        var transport: String?
        if let q = rest.firstIndex(of: "?") {
            let query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "transport" { transport = String(kv[1]) }
            }
        }
        // rest is host[:port]; a bare host defaults to 3478.
        if let colon = rest.lastIndex(of: ":"),
           let port = Int(rest[rest.index(after: colon)...]) {
            return (String(rest[..<colon]), port, transport)
        }
        return (rest, 3478, transport)
    }
}

/// The peer addresses a relay allocation lets in. An address counts as
/// installed only once CreatePermission succeeded — only those are renewed
/// with the allocation (coturn drops a permission after 5 minutes). One
/// that failed (at allocation, added later, or at a renewal) stays queued
/// and is tried again on the next pass, up to `maxTries`: dropped, or
/// marked done before it was, it left the far relay refusing the dialer.
/// Not thread-safe: its listener guards it with its lock, and runs the
/// (blocking) CreatePermission calls outside that lock.
///
/// The permissions are the network ACL in front of the embedded sshd, and
/// the addresses come from the peer's unsigned signalling: only public
/// unicast addresses are let in (`admit`), at most `maxAddresses` per
/// allocation — enough for a dialer behind a NAT with a few exits, not a
/// list a peer (or the relaying control plane) can grow.
struct RelayPermits {
    static let maxTries = 6
    static let maxAddresses = 4
    private(set) var installed: [String]
    private(set) var pending: [(ip: String, tries: Int)] = []
    /// Taken off the queue, its CreatePermission under way (in neither list
    /// meanwhile): still counts towards the cap until `record`.
    private(set) var inFlight: Set<String> = []
    private let admit: (String) -> Bool

    init(installed: [String], pending: [String] = [],
         admit: @escaping (String) -> Bool = RelayPermits.isPublicUnicast) {
        self.admit = admit
        self.installed = Array(installed.filter(admit).prefix(Self.maxAddresses))
        for ip in pending { add(ip) }
    }

    /// The addresses of `ips` a relay may let in: admitted, distinct, at
    /// most `maxAddresses`, in order.
    static func admissible(_ ips: [String], admit: (String) -> Bool = isPublicUnicast) -> [String] {
        var out: [String] = []
        for ip in ips where admit(ip) && !out.contains(ip) && out.count < maxAddresses { out.append(ip) }
        return out
    }

    /// A new address to let in. False when it isn't one (not public
    /// unicast) or the allocation has its `maxAddresses` already; true when
    /// it is installed or queued.
    @discardableResult
    mutating func add(_ ip: String) -> Bool {
        if installed.contains(ip) || inFlight.contains(ip) || pending.contains(where: { $0.ip == ip }) { return true }
        guard admit(ip), installed.count + pending.count + inFlight.count < Self.maxAddresses else { return false }
        pending.append((ip, 0))
        return true
    }

    /// A numeric, globally routable unicast address — what a relay on the
    /// internet sees a dialer come from. Not private, loopback, link-local,
    /// carrier-grade NAT, documentation, multicast, reserved or unspecified.
    static func isPublicUnicast(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            func inNet(_ net: UInt32, _ bits: UInt32) -> Bool { a >> (32 - bits) == net >> (32 - bits) }
            let blocked: [(UInt32, UInt32)] = [
                (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8),
                (0xA9FE_0000, 16), (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24),
                (0xC0A8_0000, 16), (0xC612_0000, 15), (0xC633_6400, 24), (0xCB00_7100, 24),
                (0xE000_0000, 4), (0xF000_0000, 4),
            ]
            return !blocked.contains { inNet($0.0, $0.1) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }   // not numeric
        let b = withUnsafeBytes(of: v6) { Array($0) }
        // Global unicast is 2000::/3; the documentation block 2001:db8::/32 is not.
        guard b[0] & 0xE0 == 0x20 else { return false }
        return !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8)
    }

    /// The queued addresses to try now (taken off the queue).
    mutating func take() -> [(ip: String, tries: Int)] {
        defer { pending.removeAll() }
        for p in pending { inFlight.insert(p.ip) }
        return pending
    }

    /// The next queued address to try (taken off the queue).
    mutating func takeOne() -> (ip: String, tries: Int)? {
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        inFlight.insert(next.ip)
        return next
    }

    /// How a try went. A failure is queued again until `maxTries`; true
    /// when it is (false: given up).
    @discardableResult
    mutating func record(_ ip: String, tries: Int, ok: Bool) -> Bool {
        inFlight.remove(ip)
        if ok {
            if !installed.contains(ip) { installed.append(ip) }
            return false
        }
        guard tries + 1 < Self.maxTries, !pending.contains(where: { $0.ip == ip }) else { return false }
        pending.append((ip, tries + 1))
        return true
    }

    /// A renewal that failed: tried again a couple more times (it stays
    /// installed meanwhile — coturn still holds it until it expires).
    mutating func renewalFailed(_ ip: String) {
        guard !pending.contains(where: { $0.ip == ip }) else { return }
        pending.append((ip, Self.maxTries - Self.renewalTries))
    }
    static let renewalTries = 3
}
