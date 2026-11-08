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
}
