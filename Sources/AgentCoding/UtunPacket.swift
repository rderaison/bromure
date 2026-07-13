import Foundation

// MARK: - IPv4 / TCP packet parsing + building for the utun forwarder

/// Minimal IPv4+TCP codec for the tun2socks-style forwarder. Pure byte math so
/// it's unit-testable without a utun. All multi-byte fields are network order.
enum UtunPacket {
    // TCP flag bits.
    static let FIN: UInt8 = 0x01
    static let SYN: UInt8 = 0x02
    static let RST: UInt8 = 0x04
    static let PSH: UInt8 = 0x08
    static let ACK: UInt8 = 0x10

    struct TCPSegment {
        var srcIP: UInt32           // host order
        var dstIP: UInt32           // host order
        var srcPort: UInt16
        var dstPort: UInt16
        var seq: UInt32
        var ack: UInt32
        var flags: UInt8
        var window: UInt16
        var payload: ArraySlice<UInt8>
    }

    /// Parse an IPv4 packet (no AF header) into a TCP segment, or nil if it isn't
    /// a well-formed IPv4/TCP packet.
    static func parse(_ p: [UInt8]) -> TCPSegment? {
        guard p.count >= 20, (p[0] >> 4) == 4 else { return nil }
        let ihl = Int(p[0] & 0x0F) * 4
        guard ihl >= 20, p.count >= ihl + 20, p[9] == 6 /* TCP */ else { return nil }
        let totalLen = Int(u16(p, 2))
        guard totalLen >= ihl + 20, totalLen <= p.count else { return nil }
        let srcIP = u32(p, 12), dstIP = u32(p, 16)
        let t = ihl   // TCP header offset
        let srcPort = u16(p, t), dstPort = u16(p, t + 2)
        let seq = u32(p, t + 4), ack = u32(p, t + 8)
        let dataOff = Int(p[t + 12] >> 4) * 4
        guard dataOff >= 20, ihl + dataOff <= totalLen else { return nil }
        let flags = p[t + 13]
        let window = u16(p, t + 14)
        let payload = p[(ihl + dataOff)..<totalLen]
        return TCPSegment(srcIP: srcIP, dstIP: dstIP, srcPort: srcPort, dstPort: dstPort,
                          seq: seq, ack: ack, flags: flags, window: window, payload: payload)
    }

    /// Build an IPv4+TCP packet (no AF header) from a segment, filling both
    /// checksums. `payload` is sent as the TCP data.
    static func build(_ s: TCPSegment) -> [UInt8] {
        let ihl = 20, tcpHdr = 20
        let total = ihl + tcpHdr + s.payload.count
        var p = [UInt8](repeating: 0, count: total)
        // IP header
        p[0] = 0x45                    // v4, ihl=5
        p[1] = 0                       // DSCP/ECN
        putU16(&p, 2, UInt16(total))   // total length
        putU16(&p, 4, 0)               // id
        putU16(&p, 6, 0x4000)          // flags: DF
        p[8] = 64                      // TTL
        p[9] = 6                       // proto TCP
        putU32(&p, 12, s.srcIP)
        putU32(&p, 16, s.dstIP)
        putU16(&p, 10, ipChecksum(p, 0, ihl))
        // TCP header
        let t = ihl
        putU16(&p, t, s.srcPort)
        putU16(&p, t + 2, s.dstPort)
        putU32(&p, t + 4, s.seq)
        putU32(&p, t + 8, s.ack)
        p[t + 12] = UInt8((tcpHdr / 4) << 4)   // data offset
        p[t + 13] = s.flags
        putU16(&p, t + 14, s.window)
        for (i, b) in s.payload.enumerated() { p[ihl + tcpHdr + i] = b }
        putU16(&p, t + 16, tcpChecksum(p, ihl: ihl, tcpLen: tcpHdr + s.payload.count,
                                       srcIP: s.srcIP, dstIP: s.dstIP))
        return p
    }

    // MARK: Checksums

    /// One's-complement 16-bit checksum over `p[start..<start+len]`.
    static func ipChecksum(_ p: [UInt8], _ start: Int, _ len: Int) -> UInt16 {
        checksum(p, start, len, initial: 0)
    }

    /// TCP checksum: pseudo-header (src,dst,proto,tcpLen) + TCP header+payload.
    static func tcpChecksum(_ p: [UInt8], ihl: Int, tcpLen: Int,
                            srcIP: UInt32, dstIP: UInt32) -> UInt16 {
        var sum: UInt32 = 0
        sum += (srcIP >> 16) & 0xffff; sum += srcIP & 0xffff
        sum += (dstIP >> 16) & 0xffff; sum += dstIP & 0xffff
        sum += UInt32(6)              // proto
        sum += UInt32(tcpLen)
        var i = ihl
        let end = ihl + tcpLen
        while i + 1 < end { sum += UInt32(u16(p, i)); i += 2 }
        if i < end { sum += UInt32(p[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    private static func checksum(_ p: [UInt8], _ start: Int, _ len: Int, initial: UInt32) -> UInt16 {
        var sum = initial
        var i = start
        let end = start + len
        while i + 1 < end { sum += UInt32(u16(p, i)); i += 2 }
        if i < end { sum += UInt32(p[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    // MARK: Byte helpers (network order)

    static func u16(_ p: [UInt8], _ o: Int) -> UInt16 { (UInt16(p[o]) << 8) | UInt16(p[o + 1]) }
    static func u32(_ p: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(p[o]) << 24) | (UInt32(p[o + 1]) << 16) | (UInt32(p[o + 2]) << 8) | UInt32(p[o + 3])
    }
    static func putU16(_ p: inout [UInt8], _ o: Int, _ v: UInt16) { p[o] = UInt8(v >> 8); p[o + 1] = UInt8(v & 0xff) }
    static func putU32(_ p: inout [UInt8], _ o: Int, _ v: UInt32) {
        p[o] = UInt8(v >> 24); p[o + 1] = UInt8((v >> 16) & 0xff)
        p[o + 2] = UInt8((v >> 8) & 0xff); p[o + 3] = UInt8(v & 0xff)
    }
    static func ipString(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}
