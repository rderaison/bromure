import Foundation
import Testing
@testable import bromure_ac

/// Regression tests for the CONNECT-authority / request-target parsing
/// differential: the credential scope checks run against the CONNECT
/// host, so the upstream URL must be guaranteed to resolve to that same
/// host. A request-target that isn't origin-form (e.g. `"@evil.com/"`)
/// would otherwise turn the concatenated URL into
/// `https://scoped.host@evil.com/` and deliver the swapped real
/// credential to an attacker server.
@Suite("Upstream URL construction")
struct UpstreamURLBuildingTests {

    @Test("Origin-form target resolves to the CONNECT host")
    func originForm() throws {
        let url = try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                      port: 443, path: "/v1/messages")
        #expect(url.host == "api.anthropic.com")
        #expect(url.path == "/v1/messages")
    }

    @Test("Userinfo-smuggling target is rejected")
    func userinfoSmuggle() {
        // The reported attack: scope checks pass on api.anthropic.com,
        // but "https://api.anthropic.com@evil.com/" resolves to evil.com.
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                port: 443, path: "@evil.com/")
        }
    }

    @Test("Absolute-form target is rejected")
    func absoluteForm() {
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                port: 443, path: "http://evil.com/x")
        }
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                port: 443, path: "https://evil.com/x")
        }
    }

    @Test("Authority-form and asterisk-form targets are rejected")
    func authorityAndAsteriskForm() {
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                port: 443, path: "evil.com:443")
        }
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                port: 443, path: "*")
        }
    }

    @Test("CONNECT authority with a path component cannot smuggle the destination")
    func connectAuthorityWithPathComponent() {
        // Second variant of the reported attack: the CONNECT authority
        // itself carries a "/.scoped.domain" suffix, so the naive
        // hasSuffix("." + scope) check passes (for a bare-domain scope)
        // while URL parsing stops the authority at the "/" and resolves
        // the attacker host. The origin-form guard does NOT catch this —
        // the inner request target is a normal path — but the
        // resolved-host assertion does.
        #expect(throws: MitmError.self) {
            try mitmUpstreamURL(scheme: "https", host: "evil.example/.anthropic.com",
                                port: 443, path: "/v1/messages")
        }
        // Sanity: the URL parser really does resolve the attacker host.
        let raw = URL(string: "https://evil.example/.anthropic.com/v1/messages")
        #expect(raw?.host == "evil.example")
    }

    @Test("Protocol-relative-looking path cannot escape the CONNECT host")
    func doubleSlashPath() throws {
        // "//evil.com/x" is odd but stays a path: the authority was
        // already terminated by the first "/", so the host is unchanged.
        let url = try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com",
                                      port: 443, path: "//evil.com/x")
        #expect(url.host == "api.anthropic.com")
    }

    @Test("Non-default port is preserved")
    func nonDefaultPort() throws {
        let url = try mitmUpstreamURL(scheme: "https", host: "cluster.local",
                                      port: 6443, path: "/api/v1/pods")
        #expect(url.host == "cluster.local")
        #expect(url.port == 6443)
    }

    @Test("Plain-HTTP scheme for the local engine works")
    func localEngineScheme() throws {
        let url = try mitmUpstreamURL(scheme: "http", host: "127.0.0.1",
                                      port: 8080, path: "/v1/chat/completions")
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
    }

    @Test("Trailing root dot and IPv6 brackets don't false-positive the host assertion")
    func hostNormalization() throws {
        let dotted = try mitmUpstreamURL(scheme: "https", host: "api.anthropic.com.",
                                         port: 443, path: "/v1/messages")
        #expect(dotted.host.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                == "api.anthropic.com")
        let v6 = try mitmUpstreamURL(scheme: "https", host: "[fd00::1]",
                                     port: 6443, path: "/api")
        #expect(v6.host == "fd00::1" || v6.host == "[fd00::1]")
    }
}
