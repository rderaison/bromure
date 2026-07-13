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

    // MARK: helpers

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
