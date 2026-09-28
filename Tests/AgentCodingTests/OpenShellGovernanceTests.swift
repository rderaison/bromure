import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("OpenShell governance")
struct OpenShellGovernanceTests {
    @Test("openshell-prover JSON maps to boundary results")
    func proverJSON() {
        #expect(OpenShellProver.parse(Data(#"{"result":"within_boundary"}"#.utf8)) == .withinBoundary)
        if case .exceedsBoundary(let c)? = OpenShellProver.parse(Data(#"{"result":"exceeds_boundary","counterexample":{"kind":"filesystem","path":"/tmp"}}"#.utf8)) {
            #expect(c.contains("/tmp"))
        } else { Issue.record("exceeds expected") }
        #expect(OpenShellProver.parse(Data(#"{"result":"unsupported","reason_code":"unsupported_policy_shape","reason":"graphql"}"#.utf8))
                == .unsupported(reason: "graphql"))
        #expect(OpenShellProver.parse(Data("junk".utf8)) == nil)
    }

    @Test("Provider rules join the candidate outside the reserved namespace")
    func candidate() throws {
        let rule = try #require(try OpenShellProviderProfile.parse(OpenShellProviderTests.githubProfile)
            .networkRule(instanceName: "gh") as OpenShellPolicy.NetworkRule?)
        let yaml = OpenShellGovernance.candidateYAML(policy: "version: 1\n", providerRules: [rule])
        let parsed = try OpenShellPolicy.parse(yaml)
        #expect(parsed.networkPolicies.map(\.key) == ["provider_gh"])
    }

    @Test("Managed documents decode; empty means none")
    func managedDecode() {
        let m = OpenShellManagedPolicySync.decode(Data(#"{"boundary_yaml":"version: 1\n","require_strict_sandbox":true,"max_advisor_mode":"review"}"#.utf8))
        #expect(m?.boundaryYAML == "version: 1\n")
        #expect(m?.requireStrictSandbox == true)
        #expect(m?.maxAdvisorMode == "review")
        #expect(OpenShellManagedPolicySync.decode(Data(#"{"boundary_yaml":"  "}"#.utf8)) == nil)
    }

    @Test("Advisor mode is clamped to the organization's maximum")
    func clamp() {
        let g = OpenShellGovernance()
        #expect(g.effectiveAdvisorMode(.auto) == .auto || g.managed != nil)
        var m = OpenShellGovernance.Managed()
        m.maxAdvisorMode = "review"
        let saved = UserDefaults.standard.data(forKey: OpenShellGovernance.managedKey)
        defer { UserDefaults.standard.set(saved, forKey: OpenShellGovernance.managedKey) }
        g.setManaged(m)
        #expect(g.effectiveAdvisorMode(.auto) == .review)
        #expect(g.effectiveAdvisorMode(.off) == .off)
    }
}
