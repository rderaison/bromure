import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Rung 2: explicit port mapping (PCP / NAT-PMP)
//
// REMOTE_P2P_PLAN.md §"Rung 2 — Explicit port mapping on the listener". The
// server designates the LISTENER (this Mac) as the mapper: it asks the home
// router to forward a public TCP port straight to the embedded sshd, and
// advertises the resulting public `ip:port` as a `.portMapped` candidate. A
// dialer then connects there directly — no relay, no shim — the same zero-cost
// path a manual port-forward would give, but set up automatically and torn
// down when we stop serving.
//
// Two protocols, tried in order of capability:
//   • PCP (RFC 6887) — the modern one, supersedes NAT-PMP.
//   • NAT-PMP (RFC 6886) — Apple's older one; same UDP port 5351.
// UPnP-IGD (SSDP + SOAP) is the widest-but-flakiest third option; not
// implemented here — it is a much larger surface for a fallback that PCP /
// NAT-PMP already cover on the routers people actually run.
//
// **The CGNAT caveat we design around (plan §Rung 2):** a mapping only pierces
// the FIRST NAT hop. Behind carrier-grade NAT the "external" address the router
// hands back is itself private/CGNAT and unreachable from the internet, so we
// verify the mapped address is genuinely PUBLIC before advertising it — a
// private result means the map didn't reach the real edge and we stay silent
// (the relay rung still covers that peer).

/// A live router port mapping: the public endpoint plus the lease it was
/// granted, so the owner can renew before expiry and delete at teardown.
struct PortMapping {
    /// Which protocol produced it — delete uses the same one.
    enum Proto { case pcp, natpmp }
    let proto: Proto
    /// The public IPv4 the router mapped, dotted-decimal. Guaranteed public
    /// (the CGNAT check ran before this was surfaced).
    let externalIP: String
    let externalPort: Int
    /// The internal (sshd) port that traffic is forwarded to.
    let internalPort: Int
    /// Granted lease in seconds; the owner renews at roughly half this.
    let lifetime: UInt32
    /// PCP echoes a 96-bit nonce that a delete/renew must repeat.
    let nonce: [UInt8]
}

/// Stateless PCP / NAT-PMP client. All calls are blocking UDP round trips with
/// bounded retransmits — run them off the main thread.
enum PortMapClient {

    /// Map `internalPort` (TCP) to a public port on the default gateway, PCP
    /// first then NAT-PMP. Returns nil if no gateway answers, the router
    /// refuses, or the mapped address isn't publicly routable (CGNAT). Bounded
    /// to a few seconds total so it can run alongside the relay standup without
    /// delaying it.
    static func mapTCP(internalPort: Int, requestedLifetime: UInt32 = 7200) -> PortMapping? {
        guard let gateway = defaultGatewayV4() else {
            FatClientLog.log("p2p: port-map: no default gateway found")
            return nil
        }
        guard let localIP = localAddress(towards: gateway) else {
            FatClientLog.log("p2p: port-map: no local address toward \(gateway)")
            return nil
        }
        if let m = PCP.map(gateway: gateway, localIP: localIP, internalPort: internalPort,
                           lifetime: requestedLifetime) {
            return validate(m)
        }
        if let m = NATPMP.map(gateway: gateway, internalPort: internalPort,
                              lifetime: requestedLifetime) {
            return validate(m)
        }
        FatClientLog.log("p2p: port-map: gateway \(gateway) speaks neither PCP nor NAT-PMP")
        return nil
    }

    /// Release a mapping (lifetime 0). Best-effort — a router that has already
    /// dropped it just ignores the request.
    static func delete(_ m: PortMapping, internalPort: Int) {
        guard let gateway = defaultGatewayV4() else { return }
        switch m.proto {
        case .pcp:
            guard let localIP = localAddress(towards: gateway) else { return }
            _ = PCP.map(gateway: gateway, localIP: localIP, internalPort: internalPort,
                        lifetime: 0, nonce: m.nonce)
        case .natpmp:
            _ = NATPMP.map(gateway: gateway, internalPort: internalPort, lifetime: 0)
        }
    }

    /// Only surface a mapping whose external IP is a globally routable address.
    /// A private/CGNAT result is the double-NAT case — the map pierced our
    /// router but there is another NAT beyond it, so the address is a dead
    /// candidate. Drop it (and release the useless hole) rather than advertise it.
    private static func validate(_ m: PortMapping) -> PortMapping? {
        guard isPublicIPv4(m.externalIP) else {
            FatClientLog.log("p2p: port-map got non-public \(m.externalIP) (CGNAT / double-NAT) — not advertising")
            delete(m, internalPort: m.internalPort)
            return nil
        }
        FatClientLog.log("p2p: port-map \(m.externalIP):\(m.externalPort) → :\(m.internalPort) "
            + "(\(m.proto == .pcp ? "PCP" : "NAT-PMP"), lease \(m.lifetime)s)")
        return m
    }
}

// MARK: - Public-address test

/// True for a globally routable IPv4 — i.e. NOT any of the ranges that can't be
/// reached from the internet: RFC1918 private, CGNAT (100.64/10), loopback,
/// link-local, "this host", and multicast/reserved.
func isPublicIPv4(_ ip: String) -> Bool {
    let o = ip.split(separator: ".").compactMap { UInt8($0) }
    guard o.count == 4 else { return false }
    switch (o[0], o[1]) {
    case (10, _):                       return false   // 10.0.0.0/8
    case (172, 16...31):                return false   // 172.16.0.0/12
    case (192, 168):                    return false   // 192.168.0.0/16
    case (100, 64...127):               return false   // 100.64.0.0/10 CGNAT
    case (169, 254):                    return false   // 169.254.0.0/16 link-local
    case (127, _):                      return false   // loopback
    case (0, _):                        return false   // "this host"
    default: break
    }
    if o[0] >= 224 { return false }                     // multicast + reserved
    return true
}

// MARK: - Default gateway (routing table via sysctl)

/// The default IPv4 gateway (the home router), dotted-decimal, read from the
/// kernel routing table. `sysctl(NET_RT_DUMP)` needs no `route` binary or
/// Process (the app sandbox has neither).
///
/// macOS only: the routing-table structs (`rt_msghdr`, `RTF_*`) live in
/// `<net/route.h>`, which the iOS SDK doesn't surface. That costs nothing —
/// port mapping is a LISTENER role, and iOS is only ever a dialer, so
/// `mapTCP` there just returns nil (no gateway → no map) and the peer uses the
/// relay exactly as before.
func defaultGatewayV4() -> String? {
#if os(macOS)
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
    var needed = 0
    guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: needed)
    guard sysctl(&mib, u_int(mib.count), &buf, &needed, nil, 0) == 0 else { return nil }

    let hdrSize = MemoryLayout<rt_msghdr>.stride
    var i = 0
    return buf.withUnsafeBytes { raw -> String? in
        while i + hdrSize <= needed {
            let hdr = raw.loadUnaligned(fromByteOffset: i, as: rt_msghdr.self)
            let msglen = Int(hdr.rtm_msglen)
            guard msglen >= hdrSize, i + msglen <= needed else { break }
            defer { i += msglen }

            // Default route only: gateway'd, up, and carrying DST + GATEWAY.
            let flags = Int32(hdr.rtm_flags)
            guard flags & RTF_GATEWAY != 0, flags & RTF_UP != 0,
                  hdr.rtm_addrs & RTA_DST != 0, hdr.rtm_addrs & RTA_GATEWAY != 0 else { continue }

            // Sockaddrs follow the header in RTA-bit order (DST, GATEWAY, …),
            // each self-sized by sa_len and 4-byte aligned. Walk to GATEWAY,
            // requiring DST to be the 0.0.0.0 default.
            var off = i + hdrSize
            var isDefault = false
            for bit in 0..<8 where hdr.rtm_addrs & (1 << bit) != 0 {
                guard off + 2 <= i + msglen else { break }
                let saLen = Int(raw.load(fromByteOffset: off, as: UInt8.self))
                let saFamily = raw.load(fromByteOffset: off + 1, as: UInt8.self)
                let step = saLen == 0 ? 4 : (saLen + 3) & ~3   // ROUNDUP(sa_len, 4)

                if bit == 0 {                                  // RTA_DST
                    // AF_INET with addr 0 == the default route; a 0-length /
                    // non-INET DST also reads as default (mask-less).
                    if saFamily == UInt8(AF_INET), off + 8 <= i + msglen {
                        let a = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                        isDefault = (a == 0)
                    } else {
                        isDefault = true
                    }
                } else if bit == 1 {                           // RTA_GATEWAY
                    guard isDefault, saFamily == UInt8(AF_INET), off + 8 <= i + msglen else { return nil }
                    let net = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                    let h = UInt32(bigEndian: net)
                    return "\(h >> 24 & 0xFF).\(h >> 16 & 0xFF).\(h >> 8 & 0xFF).\(h & 0xFF)"
                }
                off += step
            }
        }
        return nil
    }
#else
    return nil   // iOS: never a listener, so never needs the gateway
#endif
}

/// This host's source IPv4 on the path to `gateway`, dotted-decimal. A
/// connected UDP socket costs nothing (no packet is sent) and `getsockname`
/// then reports the address the kernel would source from — exactly the
/// "internal client address" PCP wants in its request.
func localAddress(towards gateway: String) -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var sa = sockaddr_in()
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = in_port_t(9).bigEndian          // discard port; nothing is sent
    guard inet_pton(AF_INET, gateway, &sa.sin_addr) == 1 else { return nil }
    let rc = withUnsafePointer(to: &sa) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else { return nil }
    var local = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let g = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard g == 0 else { return nil }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
    return String(cString: buf)
}

// MARK: - UDP request/response to the gateway's mapper port

enum MapperUDP {
    static let port = 5351

    /// Send `request` to `gateway:port` and return the first reply, retrying on
    /// timeout. Bounded deliberately short (RFC's own backoff runs to minutes):
    /// the mapper is a fast-path optimisation racing the relay standup, not
    /// something worth stalling a connection for. `port` is injectable so tests
    /// can point it at a loopback fake mapper.
    static func exchange(gateway: String, request: [UInt8], port: Int = port,
                         attempts: Int = 3, firstTimeout: TimeInterval = 0.25) -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, gateway, &sa.sin_addr) == 1 else { return nil }
        // Connected UDP: a closed mapper port surfaces as an ICMP-driven recv
        // error, so we fail over to the next protocol fast instead of eating
        // every retransmit.
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return nil }

        var timeout = firstTimeout
        for _ in 0..<attempts {
            guard request.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, request.count, 0) }) == request.count
            else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
            if pr < 0 { if errno == EINTR { continue }; return nil }
            if pr == 0 { timeout *= 2; continue }              // retransmit
            var buf = [UInt8](repeating: 0, count: 1100)
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }                           // ICMP unreachable etc.
            return Array(buf[0..<n])
        }
        return nil
    }
}

// MARK: - NAT-PMP (RFC 6886)

enum NATPMP {
    /// Map (or, with lifetime 0, delete) `internalPort` as TCP. NAT-PMP's map
    /// response carries only the external PORT, so the external IP comes from a
    /// separate "get external address" call (opcode 0). `port` is injectable
    /// for tests (default 5351).
    static func map(gateway: String, internalPort: Int, lifetime: UInt32,
                    port: Int = MapperUDP.port) -> PortMapping? {
        // opcode 2 = map TCP. Request: ver(0) op(2) reserved(2) inPort(2)
        // suggestedExt(2) lifetime(4).
        var req = [UInt8]()
        req.append(0)                                  // version
        req.append(2)                                  // op: map TCP
        req.append(contentsOf: [0, 0])                 // reserved
        req.append(contentsOf: be16(UInt16(internalPort)))
        req.append(contentsOf: be16(lifetime == 0 ? 0 : UInt16(internalPort)))  // suggest same
        req.append(contentsOf: be32(lifetime))
        guard let resp = MapperUDP.exchange(gateway: gateway, request: req, port: port), resp.count >= 16,
              resp[0] == 0, resp[1] == 130 else { return nil }
        let result = UInt16(resp[2]) << 8 | UInt16(resp[3])
        guard result == 0 else { return nil }
        let extPort = Int(UInt16(resp[10]) << 8 | UInt16(resp[11]))
        let granted = be32val(resp, 12)
        if lifetime == 0 { return nil }                // a delete has nothing to surface

        guard let extIP = externalAddress(gateway: gateway, port: port) else { return nil }
        return PortMapping(proto: .natpmp, externalIP: extIP, externalPort: extPort,
                           internalPort: internalPort, lifetime: granted, nonce: [])
    }

    /// opcode 0 — the router's public WAN IPv4.
    private static func externalAddress(gateway: String, port: Int) -> String? {
        guard let resp = MapperUDP.exchange(gateway: gateway, request: [0, 0], port: port),
              resp.count >= 12, resp[0] == 0, resp[1] == 128,
              (UInt16(resp[2]) << 8 | UInt16(resp[3])) == 0 else { return nil }
        return "\(resp[8]).\(resp[9]).\(resp[10]).\(resp[11])"
    }
}

// MARK: - PCP (RFC 6887)

enum PCP {
    /// Map (or delete, lifetime 0) `internalPort` as TCP. A fresh `nonce` is
    /// minted for a map; a delete/renew must pass the ORIGINAL mapping's nonce.
    /// PCP's response carries the external IP directly, so no second call.
    /// `port` is injectable for tests (default 5351).
    static func map(gateway: String, localIP: String, internalPort: Int,
                    lifetime: UInt32, nonce: [UInt8]? = nil,
                    port: Int = MapperUDP.port) -> PortMapping? {
        let theNonce = nonce ?? randomNonce()

        // Common header (24 bytes): ver(2) R|op(0x01) reserved(2) lifetime(4)
        // clientIP(16, IPv4-mapped IPv6).
        var req = [UInt8]()
        req.append(2)                                  // version 2
        req.append(0x01)                               // R=0, opcode 1 (MAP)
        req.append(contentsOf: [0, 0])                 // reserved
        req.append(contentsOf: be32(lifetime))
        req.append(contentsOf: mappedV6(localIP))      // client address

        // MAP opcode (36 bytes): nonce(12) proto(6=TCP) reserved(3)
        // intPort(2) suggestedExtPort(2) suggestedExtIP(16, zero = any).
        req.append(contentsOf: theNonce)
        req.append(6)                                  // protocol TCP
        req.append(contentsOf: [0, 0, 0])              // reserved
        req.append(contentsOf: be16(UInt16(internalPort)))
        req.append(contentsOf: be16(lifetime == 0 ? 0 : UInt16(internalPort)))
        req.append(contentsOf: [UInt8](repeating: 0, count: 16))  // any external IP

        guard let resp = MapperUDP.exchange(gateway: gateway, request: req, port: port), resp.count >= 60,
              resp[0] == 2, resp[1] == 0x81 else { return nil }   // response to MAP
        guard resp[3] == 0 else { return nil }                    // result SUCCESS
        // Echoed nonce must match — a stray/duplicate reply is ignored.
        guard Array(resp[24..<36]) == theNonce else { return nil }
        let granted = be32val(resp, 4)
        let extPort = Int(UInt16(resp[42]) << 8 | UInt16(resp[43]))
        if lifetime == 0 { return nil }

        // Assigned external IP: bytes 44..<60, an IPv4-mapped IPv6 — the IPv4 is
        // the low 4 bytes.
        let ext = "\(resp[56]).\(resp[57]).\(resp[58]).\(resp[59])"
        return PortMapping(proto: .pcp, externalIP: ext, externalPort: extPort,
                           internalPort: internalPort, lifetime: granted, nonce: theNonce)
    }

    /// A 96-bit mapping nonce. Not security-critical (it only pairs our request
    /// with its reply on the LAN), so a time-free spread of bytes is plenty —
    /// and the P2P scripts ban Date/random anyway.
    private static func randomNonce() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        var seed = UInt64(getpid()) &* 0x9E3779B97F4A7C15
        seed ^= UInt64(UInt(bitPattern: ObjectIdentifier(NonceSalt.self).hashValue))
        for i in 0..<12 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            out[i] = UInt8((seed >> 56) & 0xFF)
        }
        return out
    }
    private final class NonceSalt {}

    /// IPv4 `a.b.c.d` as an IPv4-mapped IPv6 (::ffff:a.b.c.d), 16 bytes.
    private static func mappedV6(_ ip: String) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        b[10] = 0xFF; b[11] = 0xFF
        let o = ip.split(separator: ".").compactMap { UInt8($0) }
        if o.count == 4 { b[12] = o[0]; b[13] = o[1]; b[14] = o[2]; b[15] = o[3] }
        return b
    }
}

// MARK: - Byte helpers

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
}
private func be32val(_ b: [UInt8], _ i: Int) -> UInt32 {
    guard i + 4 <= b.count else { return 0 }
    return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
}
