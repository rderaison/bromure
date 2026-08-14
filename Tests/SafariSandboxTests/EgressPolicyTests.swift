import Foundation
import Testing
@testable import SandboxEngine

@Suite("EgressPolicy pf parsing + matching")
struct EgressPolicyTests {
    private func ip(_ s: String) -> UInt32 { EgressPolicy.parseIPv4(s)! }

    @Test("Parses the canonical example and round-trips")
    func roundTrip() throws {
        let text = """
        allow tcp api.github.com:443
        web api.example.com methods GET,POST
        deny udp any:53
        deny any 10.0.0.0/8
        default deny
        """
        let p = try EgressPolicy.parse(text)
        #expect(p.defaultAction == .deny)
        #expect(p.rules.count == 4)
        // Re-parse the serialization; structures must be identical.
        let again = try EgressPolicy.parse(p.serialize())
        #expect(again == p)
    }

    @Test("Comments and blank lines are skipped")
    func commentsSkipped() throws {
        let p = try EgressPolicy.parse("# header\n\nallow tcp x.com:443  # inline\n")
        #expect(p.rules.count == 1)
        #expect(p.defaultAction == .allow)   // absent default → allow
    }

    @Test("Hostname matches apex + subdomains; *.host matches subdomains only")
    func hostMatching() throws {
        let p = try EgressPolicy.parse("allow tcp example.com:443\nallow tcp *.cdn.net:443\ndefault deny")
        // example.com rule
        #expect(p.verdict(ip: nil, hostnames: ["example.com"], proto: .tcp, port: 443) == .allow)
        #expect(p.verdict(ip: nil, hostnames: ["api.example.com"], proto: .tcp, port: 443) == .allow)
        // *.cdn.net rule: subdomain yes, apex no
        #expect(p.verdict(ip: nil, hostnames: ["a.cdn.net"], proto: .tcp, port: 443) == .allow)
        #expect(p.verdict(ip: nil, hostnames: ["cdn.net"], proto: .tcp, port: 443) == .deny)
        // unrelated → default deny
        #expect(p.verdict(ip: nil, hostnames: ["evil.com"], proto: .tcp, port: 443) == .deny)
    }

    @Test("CIDR and bare IP match by destination IP")
    func cidrMatching() throws {
        let p = try EgressPolicy.parse("deny any 10.0.0.0/8\ndeny any 1.2.3.4\ndefault allow")
        #expect(p.verdict(ip: ip("10.9.9.9"), hostnames: [], proto: .tcp, port: 80) == .deny)
        #expect(p.verdict(ip: ip("11.0.0.1"), hostnames: [], proto: .tcp, port: 80) == .allow)
        #expect(p.verdict(ip: ip("1.2.3.4"), hostnames: [], proto: .udp, port: 5000) == .deny)
        #expect(p.verdict(ip: ip("1.2.3.5"), hostnames: [], proto: .udp, port: 5000) == .allow)
    }

    @Test("Protocol and port ranges gate matches")
    func protoPort() throws {
        let p = try EgressPolicy.parse("deny udp any:53\nallow tcp any:8000-8100\ndefault deny")
        #expect(p.verdict(ip: ip("8.8.8.8"), hostnames: [], proto: .udp, port: 53) == .deny)
        #expect(p.verdict(ip: ip("8.8.8.8"), hostnames: [], proto: .tcp, port: 53) == .deny)   // tcp/53 → default deny
        #expect(p.verdict(ip: ip("9.9.9.9"), hostnames: [], proto: .tcp, port: 8050) == .allow)
        #expect(p.verdict(ip: ip("9.9.9.9"), hostnames: [], proto: .tcp, port: 9000) == .deny) // outside range
    }

    @Test("First match wins")
    func precedence() throws {
        let p = try EgressPolicy.parse("allow tcp safe.example.com:443\ndeny tcp example.com:443\ndefault allow")
        #expect(p.verdict(ip: nil, hostnames: ["safe.example.com"], proto: .tcp, port: 443) == .allow)
        #expect(p.verdict(ip: nil, hostnames: ["other.example.com"], proto: .tcp, port: 443) == .deny)
    }

    @Test("web rule forces MiTM verdict")
    func webForcesMitm() throws {
        let p = try EgressPolicy.parse("web api.example.com methods GET,POST\ndefault allow")
        #expect(p.verdict(ip: nil, hostnames: ["api.example.com"], proto: .tcp, port: 443) == .mitm)
    }

    @Test("web method allowlist / read-only enforce verbs")
    func methodEnforcement() throws {
        let p = try EgressPolicy.parse("web api.example.com methods GET,POST\nweb ro.example.com read-only\ndefault allow")
        #expect(p.permitsMethod(hostnames: ["api.example.com"], port: 443, method: "GET"))
        #expect(p.permitsMethod(hostnames: ["api.example.com"], port: 443, method: "post"))   // case-insensitive
        #expect(!p.permitsMethod(hostnames: ["api.example.com"], port: 443, method: "DELETE"))
        #expect(p.permitsMethod(hostnames: ["ro.example.com"], port: 443, method: "GET"))
        #expect(!p.permitsMethod(hostnames: ["ro.example.com"], port: 443, method: "POST"))
        // A host with no web rule: everything allowed (deny is a connection-layer concern).
        #expect(p.permitsMethod(hostnames: ["free.com"], port: 443, method: "DELETE"))
    }

    @Test("Rejects methods on non-web rules and bad syntax")
    func parseErrors() {
        #expect(throws: EgressPolicy.ParseError.self) { _ = try EgressPolicy.parse("allow tcp x.com methods GET") }
        #expect(throws: EgressPolicy.ParseError.self) { _ = try EgressPolicy.parse("nope tcp x.com") }
        #expect(throws: EgressPolicy.ParseError.self) { _ = try EgressPolicy.parse("deny any 10.0.0.0/40") }
        #expect(throws: EgressPolicy.ParseError.self) { _ = try EgressPolicy.parse("default maybe") }
    }
}
