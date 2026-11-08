import Foundation

// The switch's packet helpers: frame fields, the egress firewall's transport
// checks, and the RST it answers a denied segment with. Pure functions over
// the frame bytes, shared by the macOS vmnet switch and the Linux daemon's
// switch, so both read and answer frames byte for byte alike.
extension VMNetSwitch {
    /// Whether an L4 denial is handed to the MiTM instead, which decides again
    /// from the TLS SNI / Host header (the switch may not know the hostname).
    /// Never for an always-blocked address -- loopback, link-local with the
    /// metadata address, unspecified: no hostname makes it allowed, and handed
    /// over, the guest's connect() succeeded before the MiTM dropped the flow,
    /// where OpenShell refuses the connect itself.
    public static func defersDenialToInterception(proto: UInt8, dport: UInt16, dstIP: UInt32,
                                                  policyDefers: Bool, intercepted: Bool) -> Bool {
        proto == 6 && policyDefers && intercepted && !OpenShellPolicy.isAlwaysBlocked(.v4(dstIP))
    }

    public static func u16(_ b: UnsafeMutablePointer<UInt8>, _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    public static func u32(_ b: UnsafeMutablePointer<UInt8>, _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    public static func putU16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8((v >> 8) & 0xFF); b[o + 1] = UInt8(v & 0xFF)
    }

    public static func putU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8((v >> 24) & 0xFF); b[o + 1] = UInt8((v >> 16) & 0xFF)
        b[o + 2] = UInt8((v >> 8) & 0xFF); b[o + 3] = UInt8(v & 0xFF)
    }

    /// How the switch answers a denied TCP segment from the guest, by its
    /// flags: a bare SYN gets the classic RST+ACK (connect fails fast); a
    /// segment of an established flow (ACK set) gets a RST whose sequence is
    /// the guest's own ACK number — exactly the next byte it expects, so the
    /// guest kernel accepts it (RFC 5961) and the socket errors out instead of
    /// hanging on retransmits. A RST from the guest is never answered.
    public enum DenyReset: Equatable { case none, syn, established }

    public static func denyReset(tcpFlags: UInt8?) -> DenyReset {
        guard let f = tcpFlags else { return .none }
        if f & 0x04 != 0 { return .none }                      // RST
        if f & 0x02 != 0, f & 0x10 == 0 { return .syn }        // SYN, not ACK
        if f & 0x10 != 0 { return .established }               // ACK
        return .none
    }

    /// Whether an off-subnet frame from an inspected session VM uses a
    /// transport that would skip the host firewall + MiTM and must therefore be
    /// dropped:
    ///  - any IP fragment (`fragmented`) — a fragmented datagram can't be
    ///    inspected or reliably filtered as a whole; the guest re-sends it
    ///    unfragmented;
    ///  - QUIC / HTTP-3 (UDP :443) — the TCP-only MiTM can't see it, so the
    ///    guest falls back to TCP, which the proxy inspects.
    /// IPv6 global unicast is handled by the caller (the frame isn't IPv4 here).
    public static func isEgressBypassTransport(fragmented: Bool, ipProto: UInt8, dport: UInt16) -> Bool {
        if fragmented { return true }
        if ipProto == 17, dport == 443 { return true }   // QUIC / HTTP-3
        return false
    }

    /// Whether allowed flows are reported to the egress observer. The
    /// workspace's "Log allowed connections" choice (`logsAllowed`) when it
    /// made one; otherwise only when a real ruleset is in force
    /// (`EgressPolicy.isActive`) — a firewall that's off doesn't claim to
    /// have "allowed" anything (B25). Denials always are.
    public static func reportsAllowedFlows(_ policy: EgressPolicy?) -> Bool {
        policy?.reportsAllowed ?? false
    }

    /// (proto, dstIP, dstPort) for a unicast IPv4 TCP/UDP frame (first fragment
    /// only), else nil.
    public static func offSubnetL4(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> (UInt8, UInt32, UInt16)? {
        guard n >= 14 + 20, u16(buf, 12) == 0x0800 else { return nil }    // IPv4
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, n >= 14 + ihl + 4 else { return nil }
        let proto = buf[14 + 9]
        guard proto == 6 || proto == 17 else { return nil }              // TCP/UDP
        guard (u16(buf, 14 + 6) & 0x1FFF) == 0 else { return nil }       // first fragment only
        return (proto, u32(buf, 14 + 16), u16(buf, 14 + ihl + 2))
    }

    /// The TCP flags byte of an IPv4/TCP frame, or nil when it's too short.
    public static func tcpFlags(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> UInt8? {
        let ihl = Int(buf[14] & 0x0F) * 4
        guard n >= 14 + ihl + 14 else { return nil }
        return buf[14 + ihl + 13]
    }

    public static func isTCPSyn(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        denyReset(tcpFlags: tcpFlags(buf, n)) == .syn
    }

    /// True if an IPv6 frame's destination is a routable (global / ULA) unicast
    /// address — i.e. egress. Link-local (fe80::/10), multicast (ff00::/8), and
    /// loopback/unspecified are local and return false.
    public static func isGlobalUnicastV6Dst(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        let off = 14 + 24                                               // IPv6 dst address
        guard n >= off + 16 else { return false }
        if buf[off] == 0xFF { return false }                           // multicast
        if buf[off] == 0xFE, (buf[off + 1] & 0xC0) == 0x80 { return false }  // fe80::/10
        var allZero = true
        for i in 0..<15 where buf[off + i] != 0 { allZero = false; break }
        if allZero { return false }                                    // :: or ::1
        return true
    }

    /// Snoop a DNS response frame (UDP src port 53) into the IP→hostname cache.
    public static func snoopDNSResponse(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int, into cache: DNSSnoopCache) {
        guard n >= 14 + 20 + 8, u16(buf, 12) == 0x0800 else { return }
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, buf[14 + 9] == 17, n >= 14 + ihl + 8 else { return }  // UDP
        guard u16(buf, 14 + ihl) == 53 else { return }                        // src port 53
        let dnsOff = 14 + ihl + 8
        guard n > dnsOff else { return }
        let payload = [UInt8](UnsafeBufferPointer(start: buf + dnsOff, count: n - dnsOff))
        for a in DNSSnoop.parseResponse(payload) { cache.record(ip: a.ip, name: a.name, ttl: a.ttl, query: a.query) }
    }

    /// Build an IPv4 TCP RST+ACK toward the guest in response to its SYN, so a
    /// firewall-denied connect fails immediately instead of retransmitting.
    /// The RST answering a denied guest segment (Ethernet frame in `syn`).
    /// For a SYN: RST+ACK acknowledging it. For an established flow
    /// (`established`): a bare RST with seq = the guest's ACK number, the one
    /// sequence number its kernel accepts a reset at.
    public static func buildTCPReset(_ syn: UnsafeMutablePointer<UInt8>, _ n: Int,
                              established: Bool = false) -> [UInt8] {
        let ihl = Int(syn[14] & 0x0F) * 4
        let gIP = u32(syn, 14 + 12), dIP = u32(syn, 14 + 16)             // guest, dst
        let sPort = u16(syn, 14 + ihl), dPort = u16(syn, 14 + ihl + 2)
        let gSeq = u32(syn, 14 + ihl + 4)
        if established {
            let gAck = u32(syn, 14 + ihl + 8)
            var ip = [UInt8](repeating: 0, count: 20 + 20)
            ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[8] = 64; ip[9] = 6
            putU32(&ip, 12, dIP); putU32(&ip, 16, gIP)
            putU16(&ip, 10, ipChecksum(ip, 0, 20))
            putU16(&ip, 20 + 0, dPort); putU16(&ip, 20 + 2, sPort)
            putU32(&ip, 20 + 4, gAck); putU32(&ip, 20 + 8, 0)
            ip[20 + 12] = 0x50
            ip[20 + 13] = 0x04                                          // RST
            putU16(&ip, 20 + 16, tcpChecksum(ip, dIP, gIP))
            return ip
        }

        var ip = [UInt8](repeating: 0, count: 20 + 20)
        // IPv4 header
        ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[8] = 64; ip[9] = 6       // ver/ihl, total len 40, ttl, proto TCP
        putU32(&ip, 12, dIP); putU32(&ip, 16, gIP)                       // src = dst, dst = guest
        putU16(&ip, 10, ipChecksum(ip, 0, 20))
        // TCP header (RST+ACK, seq 0, ack gSeq+1)
        putU16(&ip, 20 + 0, dPort); putU16(&ip, 20 + 2, sPort)
        putU32(&ip, 20 + 4, 0); putU32(&ip, 20 + 8, gSeq &+ 1)
        ip[20 + 12] = 0x50                                               // data offset 5
        ip[20 + 13] = 0x14                                              // RST | ACK
        putU16(&ip, 20 + 16, tcpChecksum(ip, dIP, gIP))
        return ip
    }

    public static func ipChecksum(_ b: [UInt8], _ off: Int, _ len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = off
        while i < off + len { sum += UInt32(b[i]) << 8 | UInt32(b[i+1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    public static func tcpChecksum(_ ip: [UInt8], _ src: UInt32, _ dst: UInt32) -> UInt16 {
        var sum: UInt32 = 0
        sum += (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF)
        sum += 6 + 20                                                    // proto + TCP length
        var i = 20
        while i < 40 { sum += UInt32(ip[i]) << 8 | UInt32(ip[i+1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}
