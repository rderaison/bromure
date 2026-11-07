import Foundation
import Testing
@testable import SandboxEngine

/// `evil.com.` is the fully qualified spelling of `evil.com`: it resolves to
/// the same host, so a rule about one is a rule about the other.
@Suite("Egress rules: a trailing dot names the same host")
struct EgressTrailingDotTests {
    private func verdict(_ pf: String, _ host: String) throws -> EgressPolicy.Verdict {
        try EgressPolicy.parse(pf).verdict(ip: nil, hostnames: [host], proto: .tcp, port: 443)
    }

    @Test("a deny rule holds for the fully qualified name and its subdomains")
    func denyHolds() throws {
        let pf = "deny evil.com\ndefault allow"
        for h in ["evil.com", "evil.com.", "EVIL.COM.", "api.evil.com.", "evil.com.."] {
            #expect(try verdict(pf, h) == .deny, "\(h) should be denied")
        }
        #expect(try verdict(pf, "notevil.com.") == .allow)
    }

    @Test("an allow rule admits the fully qualified name, and nothing else")
    func allowAdmits() throws {
        let pf = "allow api.acme.com\ndefault deny"
        #expect(try verdict(pf, "api.acme.com.") == .allow)
        #expect(try verdict(pf, "evil.com.") == .deny)
    }

    @Test("a subdomain-only rule still leaves the apex out")
    func subdomainsOnly() throws {
        let pf = "deny *.evil.com\ndefault allow"
        #expect(try verdict(pf, "a.evil.com.") == .deny)
        #expect(try verdict(pf, "evil.com.") == .allow)
    }
}
