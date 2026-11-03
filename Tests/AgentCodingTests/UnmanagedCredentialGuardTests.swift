import Foundation
import Testing
@testable import bromure_ac

@Suite("Strict credential mode (UnmanagedCredentialGuard)")
struct UnmanagedCredentialGuardTests {
    private let ghToken = "ghp_" + String(repeating: "aB3dE5fG7h", count: 4)          // 44 chars
    private let fake = "brm_Zq9xY8wV7uT6sR5qP4oN3mL2kJ1iH0gF"

    private func req(_ head: String, body: String = "") -> Data {
        Data((head + "\r\n\r\n" + body).utf8)
    }

    private func guardOn() -> (UnmanagedCredentialGuard, UUID) {
        let g = UnmanagedCredentialGuard()
        let pid = UUID()
        g.setEnabled(true, for: pid)
        return (g, pid)
    }

    @Test("Finds known token formats in headers, query and body")
    func scanFormats() {
        let r = req("POST /upload?api_key=\(ghToken) HTTP/1.1\r\nHost: x.example\r\nX-Custom: token=AKIAIOSFODNN7EXAMPLE",
                    body: #"{"k":"sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"}"#)
        let kinds = Set(UnmanagedCredentialGuard.scan(rawRequest: r).map(\.kind))
        #expect(kinds.contains("github-token"))
        #expect(kinds.contains("aws-access-key"))
        #expect(kinds.contains("anthropic-key"))
    }

    @Test("Generic high-entropy bearer and Basic passwords count; low-entropy values don't")
    func genericSecrets() {
        let basic = Data("git:Xk29fLq0Zr8vPw3MtYs7Nb4H".utf8).base64EncodedString()
        let r = req("GET / HTTP/1.1\r\nAuthorization: Bearer q8Z3kLm2Xw9Rt4Yp7Vn1Bc6Hd0Js5Fg\r\nProxy-Authorization: Basic \(basic)")
        let found = UnmanagedCredentialGuard.scan(rawRequest: r)
        #expect(found.map(\.kind).contains("bearer"))
        #expect(found.map(\.kind).contains("basic-password"))
        let dull = req("GET / HTTP/1.1\r\nAuthorization: Bearer aaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(UnmanagedCredentialGuard.scan(rawRequest: dull).isEmpty)
    }

    @Test("Bromure fakes and subscription placeholders are exempt")
    func fakesExempt() {
        let (g, pid) = guardOn()
        let basic = Data("x-access-token:\(fake)".utf8).base64EncodedString()
        let r = req("GET / HTTP/1.1\r\nAuthorization: Basic \(basic)\r\nX-Api-Key: sk-ant-api03-brm-QQQQwwwwEEEErrrrTTTTyyyy")
        #expect(g.check(rawRequest: r, host: "github.com", profileID: pid, fakes: [fake], awsAccessKeyID: nil,
                        isPlaceholder: { $0.hasPrefix("sk-ant-api03-brm-") }).isEmpty)
    }

    @Test("A real token the guest found is flagged; off when strict mode is off")
    func flagged() {
        let (g, pid) = guardOn()
        let r = req("GET /user HTTP/1.1\r\nAuthorization: token \(ghToken)")
        let f = g.check(rawRequest: r, host: "api.github.com", profileID: pid, fakes: [fake], awsAccessKeyID: nil)
        #expect(f.count == 1)
        #expect(f.first?.kind == "github-token")
        #expect(f.first?.preview == "ghp_…fG7h")
        g.setEnabled(false, for: pid)
        #expect(g.check(rawRequest: r, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
    }

    @Test("Tokens a site issues are allowed back to the same site only")
    func learnedTokens() {
        let (g, pid) = guardOn()
        let issued = "gho_" + String(repeating: "Zy8Xw7Vu6T", count: 4)
        let resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: sess=Q1w2E3r4T5y6U7i8O9p0Lk; Path=/\r\n\r\n{\"access_token\":\"\(issued)\",\"token_type\":\"bearer\"}".utf8)
        g.learn(response: resp, host: "github.com", profileID: pid)
        let use = req("GET /user HTTP/1.1\r\nAuthorization: Bearer \(issued)")
        #expect(g.check(rawRequest: use, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
        #expect(!g.check(rawRequest: use, host: "evil.example.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
        g.reset(profileID: pid)
        #expect(!g.check(rawRequest: use, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
    }

    @Test("The workspace's own AWS key id in SigV4 is managed; another key id isn't")
    func awsKeys() {
        let (g, pid) = guardOn()
        let sig = "AWS4-HMAC-SHA256 Credential=AKIAOWNKEY0000000001/20260928/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=abc"
        let r = req("GET / HTTP/1.1\r\nAuthorization: \(sig)")
        #expect(g.check(rawRequest: r, host: "s3.amazonaws.com", profileID: pid, fakes: [],
                        awsAccessKeyID: "AKIAOWNKEY0000000001").isEmpty)
        #expect(g.check(rawRequest: r, host: "s3.amazonaws.com", profileID: pid, fakes: [],
                        awsAccessKeyID: "AKIAOTHERKEY00000002").map(\.kind) == ["aws-access-key"])
    }

    @Test("Session approval is per credential")
    func sessionApproval() {
        let (g, pid) = guardOn()
        let r = req("GET / HTTP/1.1\r\nAuthorization: token \(ghToken)")
        let f = g.check(rawRequest: r, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil)
        g.allowForSession(f.map(\.fingerprint), profileID: pid)
        #expect(g.check(rawRequest: r, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
        let other = req("GET / HTTP/1.1\r\nAuthorization: token ghp_\(String(repeating: "Q", count: 36))x")
        #expect(!g.check(rawRequest: other, host: "api.github.com", profileID: pid, fakes: [], awsAccessKeyID: nil).isEmpty)
    }

    @Test("Registrable domains")
    func domains() {
        #expect(UnmanagedCredentialGuard.registrableDomain("api.github.com") == "github.com")
        #expect(UnmanagedCredentialGuard.registrableDomain("a.b.example.co.uk") == "example.co.uk")
        #expect(UnmanagedCredentialGuard.registrableDomain("localhost") == "localhost")
    }
}
