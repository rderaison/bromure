import Foundation
import Testing
@testable import SandboxEngine

@Suite("DNS snoop parser")
struct DNSSnoopTests {
    /// A response for `example.com` with a CNAME to `cdn.example.net` and an A
    /// record on the alias. Both the query name and the record owner should map
    /// to the IP, so a rule on either matches.
    private func response() -> [UInt8] {
        var b: [UInt8] = []
        // Header: id, flags=0x8180 (response), qd=1, an=2, ns=0, ar=0
        b += [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]
        // Question: example.com, A, IN
        b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
        b += [0x00, 0x01, 0x00, 0x01]
        let qnamePtr: UInt8 = 0x0C   // offset 12
        // Answer 1: name=ptr(12), CNAME → cdn.example.net
        b += [0xC0, qnamePtr, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C]  // type CNAME, ttl 300
        var rd: [UInt8] = [3] + Array("cdn".utf8) + [7] + Array("example".utf8) + [3] + Array("net".utf8) + [0]
        b += [0x00, UInt8(rd.count)] + rd
        let cnameOff = b.count - rd.count
        // Answer 2: name=ptr(cname target), A 1.2.3.4, ttl 300
        b += [0xC0, UInt8(cnameOff), 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C]
        b += [0x00, 0x04, 1, 2, 3, 4]
        _ = rd
        return b
    }

    @Test("Maps A-record IP to the query name and the record owner")
    func parsesAndMaps() {
        let answers = DNSSnoop.parseResponse(response())
        let ip: UInt32 = 0x01020304
        let names = Set(answers.filter { $0.ip == ip }.map { $0.name })
        #expect(names.contains("example.com"))          // original query name
        #expect(names.contains("cdn.example.net"))       // A-record owner (CNAME target)
    }

    @Test("Non-response (query) yields nothing")
    func ignoresQuery() {
        var b = response()
        b[2] = 0x01   // clear QR bit → a query
        #expect(DNSSnoop.parseResponse(b).isEmpty)
    }

    @Test("Cache honors matching and expiry")
    func cache() {
        let c = DNSSnoopCache()
        let now = Date()
        c.record(ip: 0x08080808, name: "dns.google", ttl: 300, now: now)
        #expect(c.names(for: 0x08080808, now: now).contains("dns.google"))
        #expect(c.names(for: 0x08080808, now: now.addingTimeInterval(4000)).isEmpty)  // past max TTL
        #expect(c.names(for: 0x01010101, now: now).isEmpty)
    }
}
