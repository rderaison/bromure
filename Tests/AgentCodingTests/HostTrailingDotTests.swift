import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

/// `registry.npmjs.org.` is the fully qualified spelling of npm's registry
/// (a repo's .npmrc can name it so): every policy decision sees the host
/// lowercased and without its trailing dots, the supply chain and Depi,
/// the passthrough list, the OpenShell host match and the credential scope
/// match (the firewall already did: EgressTrailingDotTests).
@Suite("Trailing-dot hosts")
struct HostTrailingDotTests {
    @Test func theNormalisedHost() {
        #expect(EgressPolicy.normalizedHost("Registry.NPMJS.org.") == "registry.npmjs.org")
        #expect(EgressPolicy.normalizedHost("registry.npmjs.org..") == "registry.npmjs.org")
        #expect(EgressPolicy.normalizedHost("registry.npmjs.org") == "registry.npmjs.org")
    }

    @Test func theSupplyChainAndDepi() {
        guard case .metadata(let eco, let pkg)? = SupplyChainRegistry.classify(host: "registry.npmjs.org.", path: "/left-pad") else {
            Issue.record("a trailing-dot npm host isn't npm"); return
        }
        #expect(eco == .npm && pkg == "left-pad")
        #expect(SupplyChainRegistry.isRegistryRequest(host: "PYPI.org.", path: "/pypi/x/json"))
        #expect(DepiRegistry.shouldRoute(host: "registry.npmjs.org."))
        #expect(DepiRegistry.shouldRoute(host: DepiRegistry.host + "."))
        #expect(!DepiRegistry.shouldRoute(host: "npmjs.org.evil."))
    }

    @Test func thePassthroughList() {
        let list = PassthroughList(extra: ["corp.example"])
        #expect(list.matches("git.corp.example.") && list.matches("CORP.EXAMPLE."))
        #expect(!list.matches("corp.example.evil."))
    }

    @Test func theOpenShellHostMatch() throws {
        let p = try OpenShellPolicy.parse("""
        version: 1
        network_policies:
          a:
            endpoints:
              - host: api.example.com
                port: 443
              - host: "*.wild.example"
                port: 443
        """)
        let eps = p.networkPolicies.flatMap(\.endpoints)
        #expect(eps.contains { $0.matches(host: "api.example.com.", port: 443) })
        #expect(eps.contains { $0.matches(host: "x.wild.example.", port: 443) })
        #expect(!eps.contains { $0.matches(host: "api.example.com.evil.", port: 443) })
    }

    @Test func theCredentialScope() {
        #expect(TokenSwapper.hostMatchesScope(host: "api.github.com.", scope: "github.com"))
        #expect(TokenSwapper.hostMatchesScope(host: "github.com", scope: "github.com."))
        #expect(TokenSwapper.hostMatchesScope(host: "k8s.example.", port: 6443, scope: "k8s.example:6443"))
        #expect(!TokenSwapper.hostMatchesScope(host: "github.com.evil.", scope: "github.com"))
    }

    /// The transparent :80 path peeks the Host before any decision; the
    /// advisor check compares it to `policy.local` as is.
    @Test func thePeekedPlainHTTPHost() {
        func peek(_ request: String) -> String? {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { Issue.record("socketpair"); return nil }
            defer { close(fds[0]); close(fds[1]) }
            let bytes = Array(request.utf8)
            _ = bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, bytes.count) }
            return MitmEngine.peekHTTPHost(fd: fds[0])
        }
        #expect(peek("GET /v1/policy HTTP/1.1\r\nHost: Policy.Local.\r\n\r\n") == OpenShellAdvisor.host)
        #expect(peek("GET http://policy.local.:80/v1/policy HTTP/1.1\r\nHost: x\r\n\r\n") == OpenShellAdvisor.host)
        #expect(peek("GET / HTTP/1.1\r\nHost: registry.npmjs.org..:80\r\n\r\n") == "registry.npmjs.org")
        #expect(peek("GET / HTTP/1.1\r\nHost: .\r\n\r\n") == nil)
    }
}
