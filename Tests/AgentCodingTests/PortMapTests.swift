import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bromure_ac

// Rung 2 — the PCP / NAT-PMP port mapper. The real proof is a router, which no
// unit test has; what IS testable, and what actually broke in practice, is the
// wire format and the CGNAT guard. A fake mapper bound to a loopback UDP port
// decodes a genuine request from PortMap.swift and encodes a spec response, so
// the encoder and decoder are exercised against each other end to end.

@Suite("P2P rung-2 port mapping")
struct PortMapTests {

    /// A one-shot UDP responder on 127.0.0.1:<ephemeral>. `handler` gets each
    /// datagram and returns the bytes to reply with (nil = stay silent).
    final class FakeMapper: @unchecked Sendable {
        let port: Int
        private let fd: Int32
        init?(_ handler: @escaping ([UInt8]) -> [UInt8]?) {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { return nil }
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_addr.s_addr = inet_addr("127.0.0.1")
            sa.sin_port = 0
            let b = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard b == 0 else { Darwin.close(s); return nil }
            var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            fd = s
            port = Int(UInt16(bigEndian: bound.sin_port))
            Thread.detachNewThread { [fd] in
                while true {
                    var buf = [UInt8](repeating: 0, count: 1100)
                    var from = sockaddr_in(); var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, &buf, buf.count, 0, $0, &flen)
                        }
                    }
                    if n <= 0 { break }
                    if let reply = handler(Array(buf[0..<n])) {
                        _ = withUnsafePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                reply.withUnsafeBytes { sendto(fd, $0.baseAddress, reply.count, 0, sa, flen) }
                            }
                        }
                    }
                }
            }
        }
        func stop() { Darwin.close(fd) }
    }

    @Test("NAT-PMP map: encodes a valid request and parses the external ip:port")
    func natpmpRoundTrip() throws {
        // A conformant router: answers opcode 0 with a public WAN IP and
        // opcode 2 with a mapped external port + granted lifetime.
        let mapper = try #require(FakeMapper { req in
            if req.count == 2, req[0] == 0, req[1] == 0 {                 // get external address
                return [0, 128, 0, 0,  0, 0, 0, 0,  203, 0, 113, 7]      // 203.0.113.7 (TEST-NET-3, public)
            }
            if req.count == 12, req[0] == 0, req[1] == 2 {               // map TCP
                let inPort = req[8]                                       // low byte of internal port
                return [0, 130, 0, 0,  0, 0, 0, 0,  0, inPort,  0xC0, 0x00,  0, 0, 14, 16]
                    // mapped external port 0xC000 = 49152, lifetime 3600
            }
            return nil
        })
        defer { mapper.stop() }

        let m = try #require(NATPMP.map(gateway: "127.0.0.1", internalPort: 2222,
                                        lifetime: 7200, port: mapper.port))
        #expect(m.externalIP == "203.0.113.7")
        #expect(m.externalPort == 49152)
        #expect(m.lifetime == 3600)
        #expect(m.proto == .natpmp)
    }

    @Test("PCP map: echoes the nonce and reads the assigned external endpoint")
    func pcpRoundTrip() throws {
        let mapper = try #require(FakeMapper { req in
            guard req.count == 60, req[0] == 2, req[1] == 0x01 else { return nil }  // MAP request
            let nonce = Array(req[24..<36])
            let intPort = Array(req[52..<54])
            var resp = [UInt8](repeating: 0, count: 60)
            resp[0] = 2; resp[1] = 0x81; resp[3] = 0                               // version, MAP response, SUCCESS
            resp[4] = 0; resp[5] = 0; resp[6] = 0x0E; resp[7] = 0x10              // lifetime 3600
            for i in 0..<12 { resp[24 + i] = nonce[i] }                           // echo nonce
            resp[36] = 6                                                          // protocol TCP
            resp[40] = intPort[0]; resp[41] = intPort[1]                          // internal port
            resp[42] = 0xC0; resp[43] = 0x00                                      // external port 49152
            resp[54] = 0; resp[55] = 0; resp[56] = 198; resp[57] = 51; resp[58] = 100; resp[59] = 9
            resp[52] = 0xFF; resp[53] = 0xFF                                      // IPv4-mapped prefix tail
            return resp
        })
        defer { mapper.stop() }

        let m = try #require(PCP.map(gateway: "127.0.0.1", localIP: "192.168.1.50",
                                     internalPort: 2222, lifetime: 7200, port: mapper.port))
        #expect(m.externalIP == "198.51.100.9")
        #expect(m.externalPort == 49152)
        #expect(m.lifetime == 3600)
        #expect(m.proto == .pcp)
        #expect(m.nonce.count == 12)
    }

    @Test("a router that never answers yields no mapping, bounded")
    func silentRouter() throws {
        // Nothing bound here — the connected UDP socket's sends go nowhere and
        // every retransmit times out. Must return nil in a couple of seconds,
        // not hang.
        let t0 = Date()
        let m = NATPMP.map(gateway: "127.0.0.1", internalPort: 2222, lifetime: 7200, port: 5399)
        #expect(m == nil)
        #expect(Date().timeIntervalSince(t0) < 4)
    }

    @Test("the CGNAT / private-address gate")
    func publicAddressGate() {
        // Reachable-from-the-internet.
        #expect(isPublicIPv4("203.0.113.7"))
        #expect(isPublicIPv4("8.8.8.8"))
        #expect(isPublicIPv4("198.51.100.9"))
        // Not — a map that returns one of these pierced only the inner NAT.
        #expect(!isPublicIPv4("10.1.2.3"))
        #expect(!isPublicIPv4("192.168.0.1"))
        #expect(!isPublicIPv4("172.16.5.5"))
        #expect(!isPublicIPv4("172.31.255.1"))
        #expect(isPublicIPv4("172.15.0.1"))     // just outside the /12
        #expect(!isPublicIPv4("100.64.0.1"))    // CGNAT
        #expect(!isPublicIPv4("100.127.255.1")) // CGNAT top
        #expect(isPublicIPv4("100.128.0.1"))    // just outside CGNAT
        #expect(!isPublicIPv4("169.254.1.1"))   // link-local
        #expect(!isPublicIPv4("127.0.0.1"))
        #expect(!isPublicIPv4("224.0.0.1"))     // multicast
    }

    @Test("port-mapped outranks srflx and relay, below host")
    func candidatePriority() {
        let host = P2PCandidate(kind: .host, proto: .tcp, ip: "192.168.1.2", port: 2222)
        let mapped = P2PCandidate(kind: .portMapped, proto: .tcp, ip: "203.0.113.7", port: 49152)
        let srflx = P2PCandidate(kind: .srflx, proto: .tcp, ip: "203.0.113.7", port: 2222)
        let relay = P2PCandidate(kind: .relay, proto: .tcp, ip: "203.0.113.9", port: 50000)
        #expect(host.prio > mapped.prio)
        #expect(mapped.prio > srflx.prio)
        #expect(srflx.prio > relay.prio)
    }
}
