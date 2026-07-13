import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bromure_ac

@Suite("UtunForwarder")
struct UtunForwarderTests {
    // MARK: Packet codec

    @Test("IP+TCP build/parse round-trips and checksums validate")
    func codec() {
        let payload = Array("hello world".utf8)
        let seg = UtunPacket.TCPSegment(
            srcIP: 0xC0A8_0405, dstIP: 0xC0A8_4005, srcPort: 51000, dstPort: 3000,
            seq: 1_000_000, ack: 2_000_000, flags: UtunPacket.PSH | UtunPacket.ACK,
            window: 65535, payload: payload[...])
        let pkt = UtunPacket.build(seg)
        let p = try! #require(UtunPacket.parse(pkt))
        #expect(p.srcIP == seg.srcIP && p.dstIP == seg.dstIP)
        #expect(p.srcPort == 51000 && p.dstPort == 3000)
        #expect(p.seq == 1_000_000 && p.ack == 2_000_000)
        #expect(p.flags == seg.flags && p.window == 65535)
        #expect(Array(p.payload) == payload)
        // Summing a header that already contains its checksum yields 0.
        #expect(UtunPacket.ipChecksum(pkt, 0, 20) == 0)
        #expect(UtunPacket.tcpChecksum(pkt, ihl: 20, tcpLen: 20 + payload.count,
                                       srcIP: seg.srcIP, dstIP: seg.dstIP) == 0)
    }

    @Test("parse rejects non-IPv4/TCP")
    func codecRejects() {
        #expect(UtunPacket.parse([UInt8](repeating: 0, count: 10)) == nil)   // too short
        var udp = UtunPacket.build(seg(flags: UtunPacket.SYN))
        udp[9] = 17   // proto UDP
        #expect(UtunPacket.parse(udp) == nil)
    }

    // MARK: End-to-end userspace TCP (no root, no remote)

    @Test("handshake + data both directions through the forwarder")
    func endToEnd() throws {
        // Mock "remote": a loopback TCP server that upper-cases what it receives.
        let serverPort = startUppercaseServer()

        // A SOCK_DGRAM socketpair stands in for the utun (preserves per-packet
        // boundaries). testEnd = us; utunEnd = the forwarder's fd.
        var sp: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sp) == 0)
        let testEnd = sp[0], utunEnd = sp[1]
        setRecvTimeout(testEnd, seconds: 3)

        let fwd = UtunForwarder(
            utunFD: utunEnd,
            host: RemoteHost(name: "t", address: "x", port: 1, user: "u"),
            localCIDR: "192.168.64.0/24", remoteCIDR: nil,
            dial: { _, _, _ in connectLoopback(serverPort) })
        Thread.detachNewThread { fwd.run() }
        defer { fwd.stop() }

        let cliISN: UInt32 = 1000
        let src: UInt32 = 0xC0A8_7F02   // 192.168.127.2 (a browser-VM-ish source)
        let dst: UInt32 = 0xC0A8_4005   // 192.168.64.5  (remote guest)

        // 1) SYN → expect SYN-ACK.
        writePkt(testEnd, seg(src: src, dst: dst, seq: cliISN, ack: 0, flags: UtunPacket.SYN))
        let synack = try #require(readMatching(testEnd) { $0.flags & UtunPacket.SYN != 0 })
        #expect(synack.flags & (UtunPacket.SYN | UtunPacket.ACK) == (UtunPacket.SYN | UtunPacket.ACK))
        #expect(synack.ack == cliISN + 1)
        let srvISN = synack.seq

        // 2) ACK the SYN-ACK → connection established.
        writePkt(testEnd, seg(src: src, dst: dst, seq: cliISN + 1, ack: srvISN + 1, flags: UtunPacket.ACK))

        // 3) Send "hello" → the forwarder writes it to the server (→ "HELLO"),
        //    reads the reply, and sends it back to us as a data segment.
        let msg = Array("hello".utf8)
        writePkt(testEnd, seg(src: src, dst: dst, seq: cliISN + 1, ack: srvISN + 1,
                              flags: UtunPacket.PSH | UtunPacket.ACK, payload: msg))
        let dataSeg = try #require(readMatching(testEnd) { !$0.payload.isEmpty })
        #expect(String(decoding: Array(dataSeg.payload), as: UTF8.self) == "HELLO")
        #expect(dataSeg.seq == srvISN + 1)   // first data byte from the server
    }

    @Test("UDP datagram forwarded and reply reconstructed")
    func udp() throws {
        var sp: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sp) == 0)
        let testEnd = sp[0], utunEnd = sp[1]
        setRecvTimeout(testEnd, seconds: 3)

        // Mock guest relay: reads a framed datagram, upper-cases the payload,
        // frames it back — same protocol as the real loopback-relay UDP mode.
        let udpDial: (RemoteHost, String) -> Int32? = { _, _ in
            var rp: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &rp) == 0 else { return -1 }
            self.startMockUDPRelay(rp[1])
            return rp[0]
        }
        let fwd = UtunForwarder(
            utunFD: utunEnd, host: RemoteHost(name: "t", address: "x", port: 1, user: "u"),
            localCIDR: "192.168.64.0/24", remoteCIDR: nil,
            dial: { _, _, _ in -1 }, udpDial: udpDial)
        Thread.detachNewThread { fwd.run() }
        defer { fwd.stop() }

        // 192.168.127.2:5000 → 192.168.64.5:53, payload "hi".
        let pkt = UtunPacket.buildUDP(.init(srcIP: 0xC0A8_7F02, dstIP: 0xC0A8_4005,
            srcPort: 5000, dstPort: 53, payload: Array("hi".utf8)[...]))
        writeRaw(testEnd, pkt)
        let raw = try #require(readRawMatching(testEnd) { $0.count >= 28 && $0[9] == 17 })
        let d = try #require(UtunPacket.parseUDP(raw))
        #expect(d.srcIP == 0xC0A8_4005 && d.dstIP == 0xC0A8_7F02)   // reply from guest:53 → us:5000
        #expect(d.srcPort == 53 && d.dstPort == 5000)
        #expect(String(decoding: Array(d.payload), as: UTF8.self) == "HI")
    }

    @Test("ICMP echo request is answered locally")
    func icmp() throws {
        var sp: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sp) == 0)
        let testEnd = sp[0], utunEnd = sp[1]
        setRecvTimeout(testEnd, seconds: 3)
        let fwd = UtunForwarder(
            utunFD: utunEnd, host: RemoteHost(name: "t", address: "x", port: 1, user: "u"),
            localCIDR: "192.168.64.0/24", remoteCIDR: nil,
            dial: { _, _, _ in -1 }, udpDial: { _, _ in -1 })
        Thread.detachNewThread { fwd.run() }
        defer { fwd.stop() }

        writeRaw(testEnd, icmpEcho(src: 0xC0A8_7F02, dst: 0xC0A8_4005, id: 0x1234, seq: 1, payload: [0xAA, 0xBB]))
        let r = try #require(readRawMatching(testEnd) { $0.count >= 28 && $0[9] == 1 })
        let ihl = Int(r[0] & 0x0F) * 4
        #expect(r[ihl] == 0)                          // type 0 = echo reply
        #expect(UtunPacket.u32(r, 12) == 0xC0A8_4005) // src = original dst
        #expect(UtunPacket.u32(r, 16) == 0xC0A8_7F02) // dst = original src
        #expect(Array(r[(ihl + 8)...]) == [0xAA, 0xBB]) // payload echoed
    }

    // MARK: helpers

    private func writeRaw(_ fd: Int32, _ pkt: [UInt8]) {
        var out: [UInt8] = [0, 0, 0, 2]
        out.append(contentsOf: pkt)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, out.count) }
    }

    private func readRawMatching(_ fd: Int32, _ pred: ([UInt8]) -> Bool) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<20 {
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 4 else { return nil }
            let pkt = Array(buf[4..<n])
            if pred(pkt) { return pkt }
        }
        return nil
    }

    private func icmpEcho(src: UInt32, dst: UInt32, id: UInt16, seq: UInt16, payload: [UInt8]) -> [UInt8] {
        var icmp = [UInt8](repeating: 0, count: 8 + payload.count)
        icmp[0] = 8   // echo request
        icmp[4] = UInt8(id >> 8); icmp[5] = UInt8(id & 0xff)
        icmp[6] = UInt8(seq >> 8); icmp[7] = UInt8(seq & 0xff)
        for (i, b) in payload.enumerated() { icmp[8 + i] = b }
        let ck = UtunPacket.ipChecksum(icmp, 0, icmp.count)
        icmp[2] = UInt8(ck >> 8); icmp[3] = UInt8(ck & 0xff)
        var p = [UInt8](repeating: 0, count: 20 + icmp.count)
        p[0] = 0x45; UtunPacket.putU16(&p, 2, UInt16(20 + icmp.count))
        UtunPacket.putU16(&p, 6, 0x4000); p[8] = 64; p[9] = 1
        UtunPacket.putU32(&p, 12, src); UtunPacket.putU32(&p, 16, dst)
        UtunPacket.putU16(&p, 10, UtunPacket.ipChecksum(p, 0, 20))
        for (i, b) in icmp.enumerated() { p[20 + i] = b }
        return p
    }

    /// Reads framed datagrams, upper-cases the payload, frames it back.
    private func startMockUDPRelay(_ fd: Int32) {
        Thread.detachNewThread {
            var acc = [UInt8](); var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                acc.append(contentsOf: buf[0..<n])
                while acc.count >= 2 {
                    let len = (Int(acc[0]) << 8) | Int(acc[1])
                    guard acc.count >= 2 + len else { break }
                    let body = Array(acc[2..<(2 + len)]); acc.removeFirst(2 + len)
                    guard body.count >= 8 else { continue }
                    var resp = Array(body[0..<8])
                    resp.append(contentsOf: body[8...].map { (97...122).contains($0) ? $0 - 32 : $0 })
                    var frame: [UInt8] = [UInt8(resp.count >> 8), UInt8(resp.count & 0xff)]
                    frame.append(contentsOf: resp)
                    _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, frame.count) }
                }
            }
        }
    }

    private func seg(src: UInt32 = 0xC0A8_7F02, dst: UInt32 = 0xC0A8_4005,
                     seq: UInt32 = 0, ack: UInt32 = 0, flags: UInt8, payload: [UInt8] = []) -> UtunPacket.TCPSegment {
        UtunPacket.TCPSegment(srcIP: src, dstIP: dst, srcPort: 51000, dstPort: 3000,
                              seq: seq, ack: ack, flags: flags, window: 65535, payload: payload[...])
    }

    private func writePkt(_ fd: Int32, _ s: UtunPacket.TCPSegment) {
        var out: [UInt8] = [0, 0, 0, 2]   // AF_INET header
        out.append(contentsOf: UtunPacket.build(s))
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, out.count) }
    }

    /// Read datagrams until one matches `pred` (or the recv timeout fires).
    private func readMatching(_ fd: Int32, _ pred: (UtunPacket.TCPSegment) -> Bool) -> UtunPacket.TCPSegment? {
        var buf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<20 {
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 4, let s = UtunPacket.parse(Array(buf[4..<n])) else { return nil }
            if pred(s) { return s }
        }
        return nil
    }

    private func setRecvTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func connectLoopback(_ port: UInt16) -> Int32 {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { Darwin.close(s); return -1 }
        return s
    }

    /// Loopback TCP server that reads a chunk and writes it back upper-cased.
    private func startUppercaseServer() -> UInt16 {
        let lfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(lfd, 4)
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
        let port = UInt16(bigEndian: got.sin_port)
        Thread.detachNewThread {
            let c = Darwin.accept(lfd, nil, nil)
            if c >= 0 {
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = Darwin.read(c, &buf, buf.count)
                if n > 0 {
                    let up = buf[0..<n].map { (b: UInt8) in (97...122).contains(b) ? b - 32 : b }
                    _ = up.withUnsafeBytes { Darwin.write(c, $0.baseAddress, up.count) }
                }
            }
            Darwin.close(lfd)
        }
        return port
    }
}
