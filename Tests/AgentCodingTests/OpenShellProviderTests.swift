import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("OpenShell provider profiles + credential binding")
struct OpenShellProviderTests {
    /// OpenShell's documented GitHub example profile (docs/how-it-works/providers/profiles.mdx).
    static let githubProfile = """
    id: github
    display_name: GitHub
    category: source_control
    credentials:
      - name: api_token
        env_vars: [GITHUB_TOKEN, GH_TOKEN]
        required: true
        auth_style: bearer
        header_name: authorization
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        access: read-only
        enforcement: enforce
      - host: api.github.com
        port: 443
        path: /graphql
        protocol: graphql
        access: read-only
        enforcement: enforce
      - host: github.com
        port: 443
        protocol: rest
        enforcement: enforce
        rules:
          - allow: { method: GET, path: "**" }
          - allow: { method: HEAD, path: "**" }
          - allow: { method: OPTIONS, path: "**" }
          - allow: { method: POST, path: "/**/git-upload-pack" }
    binaries: [/usr/bin/gh, /usr/local/bin/gh, /usr/bin/git, /usr/local/bin/git]
    """

    @Test("Parses the documented GitHub profile")
    func parsesGitHub() throws {
        let p = try OpenShellProviderProfile.parse(Self.githubProfile)
        #expect(p.id == "github")
        #expect(p.credentials.first?.envVars == ["GITHUB_TOKEN", "GH_TOKEN"])
        #expect(p.credentials.first?.required == true)
        #expect(p.credentialHostScopes == ["api.github.com", "github.com"])
        #expect(p.credentialPathScopes.isEmpty)           // not every endpoint narrows by path
        let rule = p.networkRule(instanceName: "work-github")
        #expect(rule.key == "_provider_work_github")
        #expect(rule.endpoints.allSatisfy { $0.managed })
    }

    @Test("The provider rule enforces its L7 rules in the effective policy")
    func providerRuleEnforces() throws {
        let p = try OpenShellProviderProfile.parse(Self.githubProfile)
        let policy = try OpenShellPolicy.parse("version: 1\n").withRules([p.networkRule(instanceName: "gh")])
        #expect(policy.evaluateRequest(host: "github.com", port: 443, method: "POST",
                                       target: "/acme/app.git/git-upload-pack") == .allow)
        if case .allow = policy.evaluateRequest(host: "github.com", port: 443, method: "POST",
                                                target: "/acme/app.git/git-receive-pack") {
            Issue.record("push must be denied by the read-only provider rules")
        }
    }

    @Test("Rejects unknown fields and bad auth styles")
    func rejects() {
        #expect(throws: OpenShellPolicy.ParseError.self) {
            try OpenShellProviderProfile.parse("id: x\nbogus: 1")
        }
        #expect(throws: OpenShellPolicy.ParseError.self) {
            try OpenShellProviderProfile.parse("id: x\ncredentials: [{ name: k, auth_style: magic }]")
        }
    }

    @Test("A path-bound credential swaps only on its paths")
    func pathBoundSwap() async {
        let pid = UUID()
        let swapper = TokenSwapper(consent: ConsentBroker())
        swapper.setMap(TokenMap(entries: [
            .init(fake: "brm_FAKE123456", real: "REALSECRET99", host: "api.example.com", paths: ["/v1/**"])
        ]), for: pid)
        func req(_ path: String) -> Data {
            Data("GET \(path) HTTP/1.1\r\nhost: api.example.com\r\nauthorization: Bearer brm_FAKE123456\r\n\r\n".utf8)
        }
        let inside = await swapper.swap(rawRequest: req("/v1/items?x=1"), host: "api.example.com", profileID: pid)
        #expect(inside.swaps.count == 1)
        let base = await swapper.swap(rawRequest: req("/v1"), host: "api.example.com", profileID: pid)
        #expect(base.swaps.count == 1)
        let outside = await swapper.swap(rawRequest: req("/admin/keys"), host: "api.example.com", profileID: pid)
        #expect(outside.swaps.isEmpty)
        let sneaky = await swapper.swap(rawRequest: req("/v1/../admin"), host: "api.example.com", profileID: pid)
        #expect(sneaky.swaps.isEmpty)
    }

    @Test("Env var aliases export the same fake")
    func aliases() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.manualTokens = [ManualToken(name: "gh", realValue: "ghp_real", envVarName: "GITHUB_TOKEN",
                                      hostFilters: ["github.com"], envVarAliases: ["GH_TOKEN"])]
        let plan = p.makeTokenPlan(salt: Data("salt".utf8))
        let exports = Dictionary(plan.manualEnvExports, uniquingKeysWith: { a, _ in a })
        #expect(exports["GITHUB_TOKEN"] != nil)
        #expect(exports["GH_TOKEN"] == exports["GITHUB_TOKEN"])
    }

    @Test("Strict mode flags credentials without a host filter")
    func unbound() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.manualTokens = [ManualToken(name: "anywhere", realValue: "x"),
                          ManualToken(name: "bound", realValue: "y", hostFilters: ["a.com"])]
        #expect(p.unboundCredentialNames == ["anywhere"])
    }
}
