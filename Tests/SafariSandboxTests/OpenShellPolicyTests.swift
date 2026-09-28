import Foundation
import Testing
@testable import SandboxEngine

@Suite("OpenShell policy parsing, validation + evaluation")
struct OpenShellPolicyTests {
    private func ip(_ s: String) -> UInt32 { EgressPolicy.parseIPv4(s)! }

    private func policy(_ yaml: String) throws -> OpenShellPolicy { try OpenShellPolicy.parse(yaml) }

    private func rejects(_ yaml: String, _ fragment: String,
                         sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try OpenShellPolicy.parse(yaml)
            Issue.record("expected rejection containing '\(fragment)'", sourceLocation: sourceLocation)
        } catch {
            #expect("\(error)".contains(fragment), "\(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Parsing

    /// OpenShell's own supervisor fixture (crates/openshell-supervisor-network/
    /// testdata/sandbox-policy.yaml, Apache-2.0), verbatim.
    static let upstreamFixture = """
    version: 1

    filesystem_policy:
      include_workdir: true
      read_only:
        - /usr
        - /lib
        - /proc
        - /dev/urandom
        - /app
        - /etc
        - /var/log
      read_write:
        - /sandbox
        - /tmp
        - /dev/null

    landlock:
      compatibility: best_effort

    process:
      run_as_user: sandbox
      run_as_group: sandbox

    network_policies:
      claude_code:
        name: claude_code
        endpoints:
          - { host: api.anthropic.com, port: 443 }
          - { host: statsig.anthropic.com, port: 443 }
        binaries:
          - { path: /usr/local/bin/claude }
          - { path: /usr/bin/node }

      github_ssh_over_https:
        name: github-ssh-over-https
        endpoints:
          - host: github.com
            port: 443
            protocol: rest
            enforcement: enforce
            rules:
              - allow:
                  method: GET
                  path: "/**/info/refs*"
              - allow:
                  method: POST
                  path: "/**/git-upload-pack"
        binaries:
          - { path: /usr/bin/git }

      gitlab:
        name: gitlab
        endpoints:
          - { host: gitlab.com, port: 443 }
        binaries:
          - { path: /usr/bin/glab }
    """

    @Test("Parses OpenShell's own fixture and reports unenforced sections")
    func upstreamFixture() throws {
        let p = try policy(Self.upstreamFixture)
        #expect(p.networkPolicies.map(\.key) == ["claude_code", "github_ssh_over_https", "gitlab"])
        #expect(p.networkPolicies[1].name == "github-ssh-over-https")
        #expect(p.networkPolicies[0].binaries == ["/usr/local/bin/claude", "/usr/bin/node"])
        #expect(p.warnings.contains { $0.hasPrefix("binaries:") })
        #expect(p.warnings.contains { $0.hasPrefix("filesystem_policy:") })
        #expect(p.warnings.contains { $0.hasPrefix("process:") })
        #expect(p.source == Self.upstreamFixture)
    }

    /// Parses every `version: 1` policy in an OpenShell checkout (examples,
    /// prover fixtures, e2e policies): `OPENSHELL_REPO=/path/to/OpenShell
    /// swift test --filter OpenShellPolicyTests`. Files OpenShell itself
    /// rejects (named `*invalid*` / `*reject*`) and placeholder templates are
    /// skipped.
    @Test("Accepts OpenShell's own policy corpus",
          .enabled(if: ProcessInfo.processInfo.environment["OPENSHELL_REPO"] != nil))
    func upstreamCorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENSHELL_REPO"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["yaml", "yml"].contains($0.pathExtension) && !$0.path.contains("/deploy/") }
        var parsed = 0
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8),
                  text.range(of: "(?m)^version: 1\\b", options: .regularExpression) != nil,
                  text.contains("network_policies") || text.contains("filesystem_policy"),
                  !f.lastPathComponent.contains("invalid"), !f.lastPathComponent.contains("reject"),
                  !f.lastPathComponent.contains("template")
            else { continue }
            do { _ = try OpenShellPolicy.parse(text); parsed += 1 }
            catch { Issue.record("\(f.path.dropFirst(root.path.count)): \(error)") }
        }
        #expect(parsed > 0)
    }

    @Test("Rejects schema violations")
    func rejections() {
        rejects("network_policies: {}", "version")
        rejects("version: 2", "must be 1")
        rejects("version: 1\nbogus: 1", "bogus: unknown field")
        rejects("version: 1\nversion: 1", "version: duplicate key")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints:
              - { host: example.com, port: 443, colour: red }
        """, "colour: unknown field")
        rejects("""
        version: 1
        network_policies:
          _provider_x:
            endpoints: [{ host: example.com, port: 443 }]
        """, "reserved")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: example.com, port: 443, ports: [80] }]
        """, "not both")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: "*.com", port: 443 }]
        """, "three DNS labels")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: "api.**.example.com", port: 443 }]
        """, "whole first label")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: example.com, port: 443, protocol: rest }]
        """, "need access or rules")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints:
              - host: example.com
                port: 443
                protocol: rest
                access: full
                rules: [{ allow: { method: GET, path: "/" } }]
        """, "cannot be combined")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: db.example.com, port: 5432, protocol: tcp, enforcement: enforce }]
        """, "accepts no request fields")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ port: 443, allowed_ips: ["169.254.169.254"] }]
        """, "blocked range")
        rejects("""
        version: 1
        filesystem_policy:
          read_write: [/]
        """, "read_write cannot contain /")
        rejects("""
        version: 1
        process:
          run_as_user: "0"
        """, "non-root")
        rejects("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: example.com, port: 443, tls: skip }]
          b:
            endpoints: [{ host: example.com, port: 443 }]
        """, "different tls")
    }

    // MARK: Connection layer

    @Test("Default deny; exact, wildcard and double-wildcard hosts")
    func hostMatching() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints:
              - { host: api.github.com, port: 443 }
              - { host: "*.example.com", port: 443 }
              - { host: "**.corp.example.org", ports: [443, 8443] }
        """)
        func allowed(_ h: String, _ port: UInt16 = 443) -> Bool {
            if case .allow = p.evaluateConnect(hostnames: [h], ip: ip("140.82.112.6"), port: port) { return true }
            return false
        }
        #expect(allowed("api.github.com"))
        #expect(allowed("API.GitHub.com"))
        #expect(!allowed("github.com"))
        #expect(!allowed("api.github.com", 80))
        #expect(allowed("www.example.com"))
        #expect(!allowed("example.com"))                 // `*.` excludes the apex
        #expect(!allowed("a.b.example.com"))             // `*` is one label
        #expect(allowed("a.b.corp.example.org", 8443))
        #expect(!allowed("corp.example.org"))            // `**` needs ≥ 1 label
        #expect(!allowed("evil.com"))
    }

    @Test("Loopback / link-local are always blocked; private needs an exact host or allowed_ips")
    func addressGuards() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints:
              - { host: internal.example.com, port: 443 }
              - { host: "*.wild.example.com", port: 443 }
              - { port: 5432, allowed_ips: ["10.20.0.0/16"] }
        """)
        #expect(p.evaluateConnect(hostnames: ["internal.example.com"], ip: ip("10.1.2.3"), port: 443)
                == .allow(rule: "a", inspect: false, tlsSkip: false))
        if case .allow = p.evaluateConnect(hostnames: ["x.wild.example.com"], ip: ip("10.1.2.3"), port: 443) {
            Issue.record("wildcard host must not reach a private address")
        }
        if case .allow = p.evaluateConnect(hostnames: ["internal.example.com"], ip: ip("169.254.169.254"), port: 443) {
            Issue.record("metadata address must always be blocked")
        }
        // Hostless allowed_ips endpoint: matches by address only.
        #expect(p.evaluateConnect(hostnames: [], ip: ip("10.20.9.9"), port: 5432)
                == .allow(rule: "a", inspect: false, tlsSkip: false))
        if case .allow = p.evaluateConnect(hostnames: [], ip: ip("10.21.0.1"), port: 5432) {
            Issue.record("address outside allowed_ips must be denied")
        }
    }

    @Test("allowed_ips on a named endpoint pins the resolved address")
    func allowedIPsPin() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: api.internal.example, port: 443, allowed_ips: ["10.20.0.0/16"] }]
        """)
        #expect(p.evaluateConnect(hostnames: ["api.internal.example"], ip: ip("10.20.1.1"), port: 443)
                == .allow(rule: "a", inspect: false, tlsSkip: false))
        if case .allow = p.evaluateConnect(hostnames: ["api.internal.example"], ip: ip("8.8.8.8"), port: 443) {
            Issue.record("allowed_ips must hold every resolved address")
        }
    }

    @Test("Control-plane ports are blocked on exact hosts; managed provider endpoints are exempt")
    func controlPlanePorts() throws {
        let base = try policy("""
        version: 1
        network_policies:
          k:
            endpoints: [{ host: k8s.example.com, port: 6443 }]
        """)
        if case .allow = base.evaluateConnect(hostnames: ["k8s.example.com"], ip: ip("203.0.113.5"), port: 6443) {
            Issue.record("6443 on an exact host must be blocked")
        }
        let withProvider = base.withProviderLayer([("kubernetes", [.init(host: "k8s.example.com", ports: [6443])])])
        #expect(withProvider.evaluateConnect(hostnames: ["k8s.example.com"], ip: ip("203.0.113.5"), port: 6443)
                == .allow(rule: "_provider_kubernetes", inspect: false, tlsSkip: false))
        // IP-literal provider hosts match by address.
        let byIP = base.withProviderLayer([("kubernetes", [.init(host: "10.9.0.4", ports: [6443])])])
        #expect(byIP.evaluateConnect(hostnames: [], ip: ip("10.9.0.4"), port: 6443)
                == .allow(rule: "_provider_kubernetes", inspect: false, tlsSkip: false))
    }

    @Test("EgressPolicy bridges OpenShell verdicts: inspect → mitm, tls: skip → splice, UDP denied")
    func egressBridge() throws {
        let os = try policy("""
        version: 1
        network_policies:
          api:
            endpoints: [{ host: api.example.com, port: 443, protocol: rest, access: read-only }]
          smtp:
            endpoints: [{ host: smtp.example.com, port: 465, tls: skip }]
          plain:
            endpoints: [{ host: plain.example.com, port: 443 }]
        """)
        let e = EgressPolicy(openShell: os)
        #expect(e.isActive)
        #expect(e.verdict(ip: nil, hostnames: ["api.example.com"], proto: .tcp, port: 443) == .mitm)
        #expect(e.verdict(ip: nil, hostnames: ["smtp.example.com"], proto: .tcp, port: 465) == .splice)
        #expect(e.verdict(ip: nil, hostnames: ["plain.example.com"], proto: .tcp, port: 443) == .allow)
        #expect(e.verdict(ip: nil, hostnames: ["other.example.com"], proto: .tcp, port: 443) == .deny)
        #expect(e.verdict(ip: ip("1.1.1.1"), hostnames: [], proto: .udp, port: 53) == .deny)
    }

    // MARK: Request layer

    @Test("REST: presets, explicit rules, deny precedence, HEAD-as-GET")
    func restRules() throws {
        let p = try policy("""
        version: 1
        network_policies:
          ro:
            endpoints:
              - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only }
          repo:
            endpoints:
              - host: api.example.com
                port: 443
                protocol: rest
                enforcement: enforce
                rules:
                  - allow: { method: "*", path: "/repos/acme/app/**" }
                  - allow: { method: GET, path: /zen }
                deny_rules:
                  - { method: "*", path: /repos/acme/app/hooks }
                  - { method: "*", path: "/repos/acme/app/hooks/**" }
        """)
        func req(_ host: String, _ m: String, _ t: String) -> OpenShellPolicy.RequestDecision {
            p.evaluateRequest(host: host, port: 443, method: m, target: t)
        }
        #expect(req("api.github.com", "GET", "/repos/x") == .allow)
        #expect(req("api.github.com", "OPTIONS", "/") == .allow)
        if case .allow = req("api.github.com", "POST", "/repos/x/issues") { Issue.record("read-only allowed POST") }
        #expect(req("api.example.com", "DELETE", "/repos/acme/app/branches/x") == .allow)
        #expect(req("api.example.com", "HEAD", "/zen") == .allow)           // HEAD matches a GET rule
        #expect(req("api.example.com", "GET", "/repos/acme/app/hooks")
                == .violation(reason: "GET /repos/acme/app/hooks blocked by deny rule", rule: "repo", enforced: true))
        if case .allow = req("api.example.com", "GET", "/repos/acme/app/hooks/1") { Issue.record("deny ** missed") }
        if case .allow = req("api.example.com", "GET", "/repos/acme/app") { Issue.record("/** matched its base") }
        // A host with no inspected endpoint forwards everything.
        #expect(req("unrelated.example.com", "DELETE", "/x") == .allow)
    }

    @Test("Audit mode reports without blocking")
    func auditMode() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints: [{ host: api.example.com, port: 443, protocol: rest, access: read-only }]
        """)
        #expect(p.evaluateRequest(host: "api.example.com", port: 443, method: "POST", target: "/x")
                == .violation(reason: "POST /x not permitted by policy", rule: "a", enforced: false))
    }

    @Test("Query matchers: allow needs every value to match, deny fires on one")
    func queryMatchers() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints:
              - host: dl.example.com
                port: 443
                protocol: rest
                enforcement: enforce
                rules:
                  - allow:
                      method: GET
                      path: /api/v1/download
                      query:
                        platform: { any: ["linux-*", "darwin-*"] }
                deny_rules:
                  - method: GET
                    path: /api/v1/download
                    query: { channel: nightly }
        """)
        func r(_ t: String) -> OpenShellPolicy.RequestDecision {
            p.evaluateRequest(host: "dl.example.com", port: 443, method: "GET", target: t)
        }
        #expect(r("/api/v1/download?platform=linux-arm64") == .allow)
        if case .allow = r("/api/v1/download") { Issue.record("missing key must not satisfy an allow matcher") }
        if case .allow = r("/api/v1/download?platform=linux-arm64&platform=win-x64") {
            Issue.record("every value must match on the allow side")
        }
        if case .allow = r("/api/v1/download?platform=linux-arm64&channel=beta&channel=nightly") {
            Issue.record("one matching value must fire a deny")
        }
    }

    @Test("Path canonicalization defeats encoding / traversal tricks")
    func canonicalization() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints:
              - host: api.example.com
                port: 443
                protocol: rest
                enforcement: enforce
                rules: [{ allow: { method: GET, path: "/public/**" } }]
          npm:
            endpoints:
              - { host: registry.npmjs.org, port: 443, protocol: rest, enforcement: enforce,
                  access: read-only, allow_encoded_slash: true }
        """)
        func r(_ t: String, host: String = "api.example.com") -> OpenShellPolicy.RequestDecision {
            p.evaluateRequest(host: host, port: 443, method: "GET", target: t)
        }
        #expect(r("/public/a/./b") == .allow)
        #expect(r("/public//a;jsessionid=1") == .allow)
        #expect(r("/%70ublic/a") == .allow)                  // decoded before matching
        if case .allow = r("/public/../private/x") { Issue.record("dot-segments must resolve before matching") }
        if case .allow = r("/public%2F..%2Fprivate") { Issue.record("%2F must be rejected") }
        if case .allow = r("/../etc") { Issue.record("escape above root must be rejected") }
        #expect(r("/@types%2Fnode", host: "registry.npmjs.org") == .allow)
        // Malformed targets are rejected even though they'd otherwise match nothing inspected.
        #expect(r("/public/a#frag") == .violation(reason: "GET rejected: request-target contains a fragment",
                                                   rule: nil, enforced: true))
    }

    @Test("Endpoint path selectors narrow which endpoint inspects a request")
    func pathSelectors() throws {
        let p = try policy("""
        version: 1
        network_policies:
          a:
            endpoints:
              - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only }
              - { host: api.github.com, port: 443, path: /graphql, protocol: rest, enforcement: enforce,
                  rules: [{ allow: { method: POST, path: /graphql } }] }
        """)
        #expect(p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/graphql") == .allow)
        if case .allow = p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/repos") {
            Issue.record("POST outside the /graphql selector must be denied")
        }
    }

    @Test("An inspected MCP endpoint rejects a request it can't read")
    func uninspectableMCP() throws {
        let p = try policy("""
        version: 1
        network_policies:
          mcp:
            endpoints:
              - host: mcp.example.com
                port: 443
                protocol: mcp
                enforcement: enforce
                rules: [{ allow: { method: tools/call, tool: search } }]
        """)
        #expect(!p.warnings.contains { $0.contains("not supported") })
        if case .allow = p.evaluateRequest(host: "mcp.example.com", port: 443, method: "POST", target: "/mcp") {
            Issue.record("a bodiless MCP POST must not be allowed")
        }
    }

    @Test("Glob dialect matches the schema's matcher semantics")
    func globs() {
        #expect(Glob.match("/repos/*/issues", "/repos/x/issues", separator: "/", caseInsensitive: false))
        #expect(!Glob.match("/repos/*/issues", "/repos/x/y/issues", separator: "/", caseInsensitive: false))
        #expect(Glob.match("/repos/**", "/repos/a/b/c", separator: "/", caseInsensitive: false))
        #expect(!Glob.match("/repos/**", "/repos", separator: "/", caseInsensitive: false))
        #expect(Glob.match("/v[0-9]/x", "/v2/x", separator: "/", caseInsensitive: false))
        #expect(Glob.match("/a?c", "/abc", separator: "/", caseInsensitive: false))
        #expect(Glob.match("/**secret**", "/mysecretx", separator: "/", caseInsensitive: false))
        #expect(!Glob.match("/**secret**", "/a/secret", separator: "/", caseInsensitive: false))
        #expect(Glob.match("1.*", "1.2", separator: ".", caseInsensitive: false))
        #expect(!Glob.match("1.*", "1.2.3", separator: ".", caseInsensitive: false))
        #expect(Glob.match("*-api.example.com", "eu-api.example.com", separator: ".", caseInsensitive: true))
    }

    @Test("Provider layer keys are sanitized and never leak into the source")
    func providerLayer() throws {
        let p = try policy("version: 1\n")
        let eff = p.withProviderLayer([("claude", [.init(host: "anthropic.com"), .init(host: "**.anthropic.com")]),
                                       ("empty", [])])
        #expect(eff.networkPolicies.map(\.key) == ["_provider_claude"])
        #expect(eff.source == "version: 1\n")
        #expect(eff.evaluateConnect(hostnames: ["api.anthropic.com"], ip: nil, port: 443)
                == .allow(rule: "_provider_claude", inspect: false, tlsSkip: false))
    }
}
