import Foundation
import Security
import Testing
@testable import bromure_ac

/// GitHub #65: an internal server with a self-signed certificate should be able
/// to receive real credentials. `X-bromure-insecure` deliberately injects none
/// (the guest can send it at will), so the user pins the server's exact leaf
/// certificate host-side instead, and a matching upstream is trusted like any
/// valid one.
@Suite("Guardrails: user-pinned upstream certificates")
struct TrustedUpstreamCertificateTests {
    private static let hex = String(repeating: "ab", count: 32)

    @Test("Fingerprints normalize from the forms tools print, and junk is refused")
    func normalizeFingerprint() {
        let colons = TrustedUpstreamCertificate.displayFingerprint(Self.hex)
        #expect(colons.hasPrefix("AB:AB:"))
        for raw in [Self.hex, Self.hex.uppercased(), colons, "  \(colons)\n",
                    "sha256 Fingerprint=\(colons)", "SHA256:\(Self.hex)",
                    colons.replacingOccurrences(of: ":", with: " ")] {
            #expect(TrustedUpstreamCertificate.normalizeFingerprint(raw) == Self.hex, "\(raw)")
        }
        for bad in ["", "abcd", String(repeating: "zz", count: 32), Self.hex + "ab"] {
            #expect(TrustedUpstreamCertificate.normalizeFingerprint(bad) == nil, "\(bad)")
        }
    }

    @Test("Hosts normalize: case, scheme, path and port are dropped")
    func normalizeHost() {
        func h(_ s: String) -> String? { TrustedUpstreamCertificate(host: s, sha256: "").normalizedHost }
        #expect(h("Internal.Example.com") == "internal.example.com")
        #expect(h("https://internal.example.com:8443/api") == "internal.example.com")
        #expect(h("internal.example.com.") == "internal.example.com")
        #expect(h("[fd00::1]:443") == "fd00::1")
        #expect(h("fd00::1") == "fd00::1")
        #expect(h("   ") == nil)
    }

    @Test("Pins round-trip through Codable, are omitted when empty, and reach the runtime config")
    @MainActor
    func codableAndConfig() throws {
        var p = GuardrailsPolicy.defaultForNewProfile()
        let empty = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as? [String: Any])
        #expect(empty["trustedCertificates"] == nil)

        p.trustedCertificates = [
            TrustedUpstreamCertificate(host: "Git.Internal", sha256: TrustedUpstreamCertificate.displayFingerprint(Self.hex)),
            TrustedUpstreamCertificate(host: "broken.internal", sha256: "not a fingerprint"),
            TrustedUpstreamCertificate(host: "", sha256: Self.hex),
        ]
        let back = try JSONDecoder().decode(GuardrailsPolicy.self, from: try JSONEncoder().encode(p))
        #expect(back == p)
        #expect(back.isActive)

        // Malformed entries never pin anything.
        #expect(back.pinnedCertificateFingerprints == ["git.internal": [Self.hex]])

        var profile = Profile(name: "ws", tool: .claude, authMode: .token)
        profile.guardrails = back
        let config = ACAppDelegate.makeGuardrailsConfig(for: profile)
        #expect(config.pinnedFingerprints(for: "GIT.internal.") == [Self.hex])
        #expect(config.pinnedFingerprints(for: "other.internal").isEmpty)
    }

    /// A self-signed leaf made with /usr/bin/openssl, as DER; nil when openssl
    /// isn't there.
    private static func selfSignedDER() throws -> Data? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                       "-subj", "/CN=internal.example", "-outform", "DER",
                       "-keyout", dir.appendingPathComponent("k.pem").path,
                       "-out", dir.appendingPathComponent("c.der").path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return try? Data(contentsOf: dir.appendingPathComponent("c.der"))
    }

    @Test("Only the exact pinned leaf certificate is trusted")
    func leafMatch() throws {
        let der = try #require(try Self.selfSignedDER())
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            cert, SecPolicyCreateSSL(true, "internal.example" as CFString), &trust)
        #expect(status == errSecSuccess)
        let t = try #require(trust)

        let fp = TrustedUpstreamCertificate.fingerprint(ofDER: der)
        #expect(PinnedUpstreamCertificate.leafFingerprint(t) == fp)
        #expect(PinnedUpstreamCertificate.matches(t, fingerprints: [fp], host: "internal.example"))
        #expect(!PinnedUpstreamCertificate.matches(t, fingerprints: [Self.hex], host: "internal.example"))
        #expect(!PinnedUpstreamCertificate.matches(t, fingerprints: [], host: "internal.example"))
    }

    /// A protection space carrying a given server trust (the system's own
    /// only gets one from a real handshake).
    private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        let trust: SecTrust
        init(host: String, port: Int, trust: SecTrust) {
            self.trust = trust
            super.init(host: host, port: port, protocol: NSURLProtectionSpaceHTTPS,
                       realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }
        required init?(coder: NSCoder) { nil }
        override var serverTrust: SecTrust? { trust }
    }
    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// A redirect the session follows is challenged on the same delegate:
    /// the pin is the original endpoint's only, even when the redirected
    /// server presents the very same certificate.
    @Test("A pin trusts only its own host and port; a redirect elsewhere gets the system's handling")
    func pinScopedToOriginalEndpoint() throws {
        let der = try #require(try Self.selfSignedDER())
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        _ = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        let t = try #require(trust)
        let delegate = ClientCertChallengeDelegate(
            identityRegistry: ClientIdentityRegistry(), caRegistry: ClusterCATrustRegistry(),
            consent: ConsentBroker(), profileID: UUID(), host: "internal.example", port: 443,
            pinnedFingerprints: [TrustedUpstreamCertificate.fingerprint(ofDER: der)])
        func disposition(_ host: String, _ port: Int) -> URLSession.AuthChallengeDisposition? {
            let challenge = URLAuthenticationChallenge(
                protectionSpace: TrustSpace(host: host, port: port, trust: t), proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: NoSender())
            var got: URLSession.AuthChallengeDisposition?
            delegate.urlSession(URLSession.shared, didReceive: challenge) { d, _ in got = d }
            return got
        }
        #expect(disposition("internal.example", 443) == .useCredential)
        #expect(disposition("INTERNAL.example.", 443) == .useCredential)
        #expect(disposition("elsewhere.example", 443) == .performDefaultHandling)
        #expect(disposition("internal.example", 8443) == .performDefaultHandling)
    }

    @Test("A trust failure tells the agent the user can pin the certificate, and names its fingerprint")
    func pinHintInUpstreamError() throws {
        let plain = describeUpstreamError(NSError(domain: NSURLErrorDomain,
                                                  code: NSURLErrorServerCertificateUntrusted),
                                          host: "internal.example")
        #expect(plain.body.contains("Trusted upstream certificates"))
        #expect(!plain.body.contains("SHA-256 fingerprint "))

        let der = try #require(try Self.selfSignedDER())
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        _ = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        let peerTrust = try #require(trust)
        let withTrust = describeUpstreamError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                    userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: peerTrust]),
            host: "internal.example")
        let display = TrustedUpstreamCertificate.displayFingerprint(
            TrustedUpstreamCertificate.fingerprint(ofDER: der))
        #expect(withTrust.body.contains(display))

        // Not a trust failure → no pinning advice.
        let dns = describeUpstreamError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost),
                                        host: "internal.example")
        #expect(!dns.body.contains("Trusted upstream certificates"))
    }
}
