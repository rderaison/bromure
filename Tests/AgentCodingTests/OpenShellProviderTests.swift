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

    @Test("OpenShell placeholders: env credentials become openshell:resolve:env:NAME, aliases get their own")
    func placeholderPlan() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.networkPolicy = "version: 1\nnetwork_policies: {}\n"
        p.manualTokens = [ManualToken(name: "gh", realValue: "ghp_real", envVarName: "GITHUB_TOKEN",
                                      hostFilters: ["github.com"], envVarAliases: ["GH_TOKEN"])]
        let off = Dictionary(p.makeTokenPlan(salt: Data("s".utf8)).manualEnvExports, uniquingKeysWith: { a, _ in a })
        #expect(off["GITHUB_TOKEN"]?.hasPrefix("openshell:") == false)
        p.openShellCredentialPlaceholders = true
        let plan = p.makeTokenPlan(salt: Data("s".utf8))
        let on = Dictionary(plan.manualEnvExports, uniquingKeysWith: { a, _ in a })
        #expect(on["GITHUB_TOKEN"] == "openshell:resolve:env:GITHUB_TOKEN")
        #expect(on["GH_TOKEN"] == "openshell:resolve:env:GH_TOKEN")
        #expect(plan.entries.filter { $0.realValue == "ghp_real" }.count == 2)
        // Without an OpenShell policy the option does nothing.
        p.networkPolicy = ""
        #expect(Dictionary(p.makeTokenPlan(salt: Data("s".utf8)).manualEnvExports, uniquingKeysWith: { a, _ in a })["GITHUB_TOKEN"]?
            .hasPrefix("openshell:") == false)
    }

    @Test("OpenShell placeholders resolve in headers on their host; in bodies only when the endpoint opts in")
    func placeholderSwap() async {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        let ph = "openshell:resolve:env:WS_TOKEN"
        swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: ph, real: "sk-real-secret", host: "api.example.com")]), for: pid)
        let req = Data("POST /v1 HTTP/1.1\r\nHost: api.example.com\r\nAuthorization: Bearer \(ph)\r\nContent-Type: application/json\r\n\r\n{\"k\":\"\(ph)\"}".utf8)
        let plain = await swapper.swap(rawRequest: req, host: "api.example.com", profileID: pid)
        let text = String(decoding: plain.modified, as: UTF8.self)
        #expect(text.contains("Bearer sk-real-secret") && text.contains("{\"k\":\"\(ph)\"}"))
        let opted = await swapper.swap(rawRequest: req, host: "api.example.com", profileID: pid, placeholderBody: true)
        #expect(String(decoding: opted.modified, as: UTF8.self).contains("{\"k\":\"sk-real-secret\"}"))
        let elsewhere = await swapper.swap(rawRequest: req, host: "evil.example.com", profileID: pid, placeholderBody: true)
        #expect(elsewhere.swaps.isEmpty)
    }

    @Test("An OpenShell placeholder left unresolved (unbound host or path) is detected; body only when resolved there")
    func unresolvedPlaceholder() {
        let known = ["openshell:resolve:env:A", "brm_fake_other"]
        let hdr = Data("GET /other HTTP/1.1\r\nAuthorization: Bearer openshell:resolve:env:A\r\n\r\n".utf8)
        #expect(HTTPMitmConnection.unresolvedPlaceholder(in: hdr, checkBody: false, known: known) == "openshell:resolve:env:A")
        let body = Data("POST / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"k\":\"openshell:resolve:env:A\"}".utf8)
        #expect(HTTPMitmConnection.unresolvedPlaceholder(in: body, checkBody: false, known: known) == nil)   // not opted in: forwarded as is
        #expect(HTTPMitmConnection.unresolvedPlaceholder(in: body, checkBody: true, known: known) != nil)
        #expect(HTTPMitmConnection.unresolvedPlaceholder(in: hdr, checkBody: false, known: ["brm_fake_other"]) == nil)
    }
}
