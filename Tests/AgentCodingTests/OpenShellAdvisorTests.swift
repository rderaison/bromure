import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("OpenShell policy advisor")
struct OpenShellAdvisorTests {
    static let base = """
    version: 1
    # my policy
    network_policies:
        github:            # four-space indent on purpose
            endpoints:
                - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only }

    filesystem_policy:
      read_only: [/usr]
    """

    /// A fresh advisor wired to an in-memory "workspace".
    private func advisor(mode: OpenShellAdvisorMode, policy: String = base,
                         scopes: [String] = ["github.com"]) -> (OpenShellAdvisor, UUID, Box) {
        let a = OpenShellAdvisor()
        let pid = UUID()
        let box = Box(policy: policy)
        a.modeProvider = { _ in mode }
        a.policyProvider = { _ in try? OpenShellPolicy.parse(box.policy) }
        a.credentialScopesProvider = { _ in scopes }
        a.applyApproved = { _, p in
            do { box.policy = try OpenShellPolicy.insertingRules(p.yaml, into: box.policy); return nil }
            catch { return "\(error)" }
        }
        return (a, pid, box)
    }

    final class Box: @unchecked Sendable { var policy: String; init(policy: String) { self.policy = policy } }

    private func proposal(_ rule: String, host: String, method: String = "GET", path: String = "/**",
                          proto: String = "rest") -> Data {
        let json: [String: Any] = [
            "intent_summary": "test",
            "operations": [["addRule": ["ruleName": rule, "rule": [
                "endpoints": [["host": host, "port": 443, "protocol": proto, "enforcement": "enforce",
                               "rules": [["allow": ["method": method, "path": path]]]]],
                "binaries": [["path": "/usr/bin/curl"]]]]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("Rules are inserted into the policy text in place, keeping comments and indentation")
    func insertion() throws {
        let rule = try #require(try OpenShellPolicy.parse("""
        version: 1
        network_policies:
          docs:
            endpoints: [{ host: docs.example.com, port: 443 }]
        """).networkPolicies.first)
        let out = try OpenShellPolicy.insertingRules(OpenShellPolicy.yaml(rule: rule), into: Self.base)
        #expect(out.contains("# my policy"))
        #expect(out.contains("    \"docs\":"))                           // matched the 4-space indent
        let p = try OpenShellPolicy.parse(out)
        #expect(p.networkPolicies.map(\.key) == ["github", "docs"])
        // A policy with no network_policies gets the section appended.
        let bare = try OpenShellPolicy.insertingRules(OpenShellPolicy.yaml(rule: rule), into: "version: 1\n")
        #expect(try OpenShellPolicy.parse(bare).networkPolicies.map(\.key) == ["docs"])
    }

    @Test("Emitted YAML round-trips every endpoint feature")
    func roundTrip() throws {
        let src = """
        version: 1
        network_policies:
          r:
            name: Rich
            endpoints:
              - host: api.example.com
                ports: [443, 8443]
                path: /v1/**
                allowed_ips: [10.0.0.0/8]
                protocol: rest
                enforcement: enforce
                allow_encoded_slash: true
                rules:
                  - allow: { method: GET, path: "/v1/**", query: { tag: { any: ["a*"] } } }
                deny_rules:
                  - { method: DELETE, path: "/v1/**" }
              - { host: mcp.example.com, port: 443, protocol: mcp, enforcement: enforce,
                  mcp: { versions: ["2025-06-18"] }, rules: [{ allow: { method: tools/call, tool: search } }] }
              - { host: gql.example.com, port: 443, protocol: graphql, enforcement: enforce,
                  rules: [{ allow: { operation_type: query, fields: [viewer] } }] }
            binaries: [{ path: /usr/bin/curl }]
        """
        let rule = try #require(try OpenShellPolicy.parse(src).networkPolicies.first)
        let again = try OpenShellPolicy.parse("version: 1\nnetwork_policies:\n" + OpenShellPolicy.yaml(rule: rule) + "\n")
        #expect(again.networkPolicies.first == rule)
    }

    @Test("Agent JSON: allowed fields only; tcp / tls skip refused")
    func agentJSON() {
        let ok = OpenShellAdvisor.rule(fromAgentJSON: [
            "endpoints": [["host": "api.example.com", "port": 443, "protocol": "rest", "enforcement": "enforce",
                           "rules": [["allow": ["method": "PUT", "path": "/x/**"]]]]],
            "binaries": [["path": "/usr/bin/gh"]]], key: "x_write")
        guard case .ok(let rule) = ok else { Issue.record("expected ok"); return }
        #expect(rule.endpoints.first?.rules.first?.method == "PUT")
        #expect(rule.binaries == ["/usr/bin/gh"])
        if case .ok = OpenShellAdvisor.rule(fromAgentJSON: ["endpoints": [["host": "db.example.com", "port": 5432, "protocol": "tcp"]]], key: "db") {
            Issue.record("tcp must be refused")
        }
        if case .ok = OpenShellAdvisor.rule(fromAgentJSON: ["endpoints": [["host": "a.example.com", "port": 443, "tls": "skip"]]], key: "a") {
            Issue.record("tls: skip must be refused")
        }
        if case .ok = OpenShellAdvisor.rule(fromAgentJSON: ["endpoints": [["host": "a.example.com", "port": 443]]], key: "_provider_x") {
            Issue.record("reserved key must be refused")
        }
    }

    @Test("Risk-free proposals auto-approve and load; credentialed ones wait")
    func autoApproval() async throws {
        let (a, pid, box) = advisor(mode: .auto)
        let r1 = a.submit(profileID: pid, body: proposal("cdn_read", host: "cdn.example.org"))
        let id1 = try #require((r1["accepted_chunk_ids"] as? [String])?.first)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(a.proposal(id: id1, profileID: pid)?.status == .approved)
        #expect(box.policy.contains("cdn.example.org"))

        // A write on the credentialed github host: capability_expansion → review.
        let r2 = a.submit(profileID: pid, body: proposal("gh_write", host: "api.github.com", method: "PUT", path: "/repos/a/b/**"))
        let id2 = try #require((r2["accepted_chunk_ids"] as? [String])?.first)
        let p2 = try #require(a.proposal(id: id2, profileID: pid))
        #expect(p2.findings.contains("capability_expansion"))
        #expect(p2.status == .pending)
        // New reach to a credentialed host.
        let r3 = a.submit(profileID: pid, body: proposal("gh_web", host: "github.com"))
        let p3 = try #require(a.proposal(id: (r3["accepted_chunk_ids"] as? [String])!.first!, profileID: pid))
        #expect(p3.findings.contains("credential_reach_expansion"))
    }

    /// The kube swap's scopes are `host:port` (Finding CWE-670, "Kube bearer
    /// and exec tokens are scoped to host:port…"): the risk check compared a
    /// rule's bare host with the whole scope and never saw them credentialed.
    @Test("A host carrying a port-scoped kube token counts as credentialed")
    func portScopedCredential() throws {
        let (a, pid, _) = advisor(mode: .auto, scopes: ["k8s.example.com:6443"])
        let r = a.submit(profileID: pid, body: proposal("k8s", host: "k8s.example.com"))
        let p = try #require(a.proposal(id: (r["accepted_chunk_ids"] as? [String])!.first!, profileID: pid))
        #expect(p.findings.contains("credential_reach_expansion"))
    }

    @Test("Blocked connections become drafts; an agent proposal supersedes the draft")
    func drafts() throws {
        let (a, pid, _) = advisor(mode: .review)
        a.recordDenial(profileID: pid, layer: "sni", host: "pypi.org", port: 443, method: nil, path: nil, reason: "no rule")
        a.recordDenial(profileID: pid, layer: "sni", host: "pypi.org", port: 443, method: nil, path: nil, reason: "no rule")
        a.recordDenial(profileID: pid, layer: "l4", host: "10.1.2.3", port: 5432, method: nil, path: nil, reason: "no rule")
        let drafts = a.pending(for: pid)
        #expect(drafts.count == 1)
        #expect(drafts.first?.source == "mechanistic")
        _ = a.submit(profileID: pid, body: proposal("pypi_read", host: "pypi.org"))
        let all = a.proposals(for: pid)
        #expect(all.first { $0.source == "mechanistic" }?.status == .rejected)
        #expect(a.pending(for: pid).map(\.rule.key) == ["pypi_read"])
    }

    @Test("Allow from the drawer: the rule goes in at once and names the program the attestor reported")
    func allowNamesProgram() async throws {
        let (a, pid, box) = advisor(mode: .review)
        // A draft for the same destination is settled by the allow.
        a.recordDenial(profileID: pid, layer: "l4", host: "www.bromure.io", port: 443, method: nil, path: nil, reason: "no rule")
        let error = await a.allow(profileID: pid, host: "www.bromure.io", port: 443, exe: "/usr/bin/curl")
        #expect(error == nil)
        let policy = try OpenShellPolicy.parse(box.policy)
        let rule = try #require(policy.networkPolicies.first { $0.key == "allow_www_bromure_io_443_curl_" + OpenShellAdvisor.pathHash("/usr/bin/curl") })
        #expect(rule.binaries == ["/usr/bin/curl"])
        #expect(rule.endpoints.first?.host == "www.bromure.io")
        #expect(a.pending(for: pid).isEmpty)
    }

    @Test("Allow with no attested program: a host-and-port rule for any program")
    func allowWithoutProgram() async throws {
        let (a, pid, box) = advisor(mode: .review)
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: nil) == nil)
        let rule = try #require(try OpenShellPolicy.parse(box.policy).networkPolicies.first { $0.key == "allow_pypi_org_443" })
        #expect(rule.binaries.isEmpty)
        // Allowing it again is refused, not duplicated.
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: nil) != nil)
    }

    /// Finding (CWE-694): "Drawer Allow cannot grant a second program that
    /// shares a file name". The key named the program by file name only, so
    /// allowing /tmp/curl after /usr/bin/curl was refused as a duplicate
    /// key; drafts and the "allowed by hand" settle keyed on host and port.
    @Test("Under Enforce binaries: two programs with one file name are two grants")
    func allowSameFileName() async throws {
        let (a, pid, box) = advisor(mode: .review)
        a.enforceBinariesProvider = { _ in true }
        for exe in ["/usr/bin/curl", "/tmp/curl"] {
            a.recordDenial(profileID: pid, layer: "sni", host: "pypi.org", port: 443, method: nil, path: nil,
                           reason: "no rule", exe: exe)
        }
        #expect(Set(a.pending(for: pid).map(\.rule.binaries)) == [["/usr/bin/curl"], ["/tmp/curl"]])
        // Allowing one settles its own draft, not the other program's.
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: "/usr/bin/curl") == nil)
        #expect(a.pending(for: pid).map(\.rule.binaries) == [["/tmp/curl"]])
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: "/tmp/curl") == nil)
        let rules = try OpenShellPolicy.parse(box.policy).networkPolicies.filter { $0.key.hasPrefix("allow_pypi_org_443") }
        #expect(Set(rules.map(\.binaries)) == [["/usr/bin/curl"], ["/tmp/curl"]])
        #expect(Set(rules.map(\.key)).count == 2)
        #expect(a.pending(for: pid).isEmpty)
        // The same program again is still refused, not duplicated.
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: "/tmp/curl") != nil)
        // An agent's rule for one program doesn't supersede another's draft.
        a.recordDenial(profileID: pid, layer: "sni", host: "pypi.org", port: 443, method: nil, path: nil,
                       reason: "no rule", exe: "/usr/local/bin/python3")
        _ = a.submit(profileID: pid, body: proposal("pypi_alt", host: "pypi.org"))   // lists /usr/bin/curl
        #expect(a.pending(for: pid).contains { $0.source == "mechanistic" && $0.rule.binaries == ["/usr/local/bin/python3"] })
        // Keys are stable across launches.
        #expect(OpenShellAdvisor.pathHash("/usr/bin/curl") == OpenShellAdvisor.pathHash("/usr/bin/curl"))
        #expect(OpenShellAdvisor.pathHash("/usr/bin/curl") != OpenShellAdvisor.pathHash("/tmp/curl"))
    }

    /// Finding (CWE-670): "Sandbox drawer Allow saves a no-op rule when
    /// Enforce binaries is on": a rule naming no program allows nothing.
    /// The program now comes from the blocked row's own event.
    @Test("Under Enforce binaries: Allow names the row's program, and refuses when there's none")
    func allowUnderEnforce() async throws {
        let (a, pid, box) = advisor(mode: .review)
        a.enforceBinariesProvider = { _ in true }
        #expect(await a.allow(profileID: pid, host: "pypi.org", port: 443, exe: "/usr/bin/pip") == nil)
        let rule = try #require(try OpenShellPolicy.parse(box.policy).networkPolicies.first { $0.key.hasPrefix("allow_pypi_org_443") })
        #expect(rule.binaries == ["/usr/bin/pip"])
        // No program on the row: refused, nothing saved, no draft queued.
        let before = box.policy
        let refused = await a.allow(profileID: pid, host: "files.example.com", port: 443, exe: nil)
        #expect(refused?.contains("Enforce binaries") == true)
        #expect(box.policy == before)
        a.recordDenial(profileID: pid, layer: "sni", host: "files.example.com", port: 443, method: nil, path: nil, reason: "no rule")
        #expect(a.pending(for: pid).isEmpty)
        // A denial that names its program is drafted for it.
        a.recordDenial(profileID: pid, layer: "sni", host: "files.example.com", port: 443, method: nil, path: nil,
                       reason: "no rule", exe: "/usr/bin/curl")
        #expect(a.pending(for: pid).first?.rule.binaries == ["/usr/bin/curl"])
    }

    @Test("A MiTM firewall row carries its destination IP (dst_ip)")
    func timelineReadsDstIP() {
        let e = SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall",
                                           eventData: ["action": .string("deny"), "host": .string("pypi.org"),
                                                       "port": .int(443), "layer": .string("sni"),
                                                       "dst_ip": .string("151.101.0.223")], now: Date())
        #expect(e?.firewall?.ip == "151.101.0.223")
    }

    @Test("policy.local routes: feature_disabled when off; denials, policy, proposal wait")
    func agentAPI() async throws {
        let (off, offPID, _) = advisor(mode: .off)
        let (s0, _, _) = await off.handle(profileID: offPID, method: "GET", target: "/v1/policy/current", body: Data(),
                                         policyReloaded: { _ in false })
        #expect(s0 == 404)

        let (a, pid, box) = advisor(mode: .review)
        a.recordDenial(profileID: pid, layer: "l7", host: "api.github.com", port: 443, method: "POST",
                       path: "/repos/a/b/issues?token=secret", reason: "not permitted")
        let (s1, _, d1) = await a.handle(profileID: pid, method: "GET", target: "/v1/denials?last=5", body: Data(),
                                         policyReloaded: { _ in false })
        #expect(s1 == 200)
        let text = String(decoding: d1, as: UTF8.self)
        #expect(text.contains("HTTP:POST api.github.com:443"))
        #expect(!text.contains("secret"))

        let (s2, type, d2) = await a.handle(profileID: pid, method: "GET", target: "/v1/policy/current", body: Data(),
                                            policyReloaded: { _ in false })
        #expect(s2 == 200 && type == "application/yaml")
        #expect(String(decoding: d2, as: UTF8.self).contains("api.github.com"))

        let (s3, _, d3) = await a.handle(profileID: pid, method: "POST", target: "/v1/proposals",
                                         body: proposal("docs", host: "docs.example.org"), policyReloaded: { _ in false })
        #expect(s3 == 202)
        let id = try #require(((try JSONSerialization.jsonObject(with: d3)) as? [String: Any])?["accepted_chunk_ids"] as? [String]).first!
        // Approve in the background; /wait returns once the rule is loaded.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await a.approve(id: id, profileID: pid)
        }
        let (s4, _, d4) = await a.handle(profileID: pid, method: "GET", target: "/v1/proposals/\(id)/wait?timeout=5",
                                         body: Data(), policyReloaded: { key in box.policy.contains(key) })
        #expect(s4 == 200)
        let obj = try #require(try JSONSerialization.jsonObject(with: d4) as? [String: Any])
        #expect(obj["status"] as? String == "approved")
        #expect(obj["policy_reloaded"] as? Bool == true)
    }

    @Test("Control-socket route: list, reject with a reason, approve; decided proposals are final")
    func controlRoute() throws {
        let (a, pid, box) = advisor(mode: .review)
        let r1 = a.submit(profileID: pid, body: proposal("docs_a", host: "a.example.org"))
        let r2 = a.submit(profileID: pid, body: proposal("docs_b", host: "b.example.org"))
        let id1 = try #require((r1["accepted_chunk_ids"] as? [String])?.first)
        let id2 = try #require((r2["accepted_chunk_ids"] as? [String])?.first)
        let route = { (m: String, sub: [String], body: [String: Any]) in
            ACAppDelegate.advisorProposalsRoute(profileID: pid, method: m, sub: sub, body: body, advisor: a)
        }
        let (s0, list) = route("GET", ["proposals"], [:])
        #expect(s0 == 200 && (list["proposals"] as? [[String: Any]])?.count == 2)

        let (s1, rej) = route("POST", ["proposals", id1, "reject"], ["reason": "too broad"])
        #expect(s1 == 200)
        #expect((rej["proposal"] as? [String: Any])?["rejection_reason"] as? String == "too broad")
        #expect(a.proposal(id: id1, profileID: pid)?.status == .rejected)

        let (s2, _) = route("POST", ["proposals", id2, "approve"], [:])
        #expect(s2 == 200)
        #expect(a.proposal(id: id2, profileID: pid)?.status == .approved)
        #expect(box.policy.contains("b.example.org"))

        #expect(route("POST", ["proposals", id1, "approve"], [:]).status == 409)   // already rejected
        #expect(route("POST", ["proposals", "nope", "reject"], [:]).status == 404)
    }

    /// Finding (CWE-284): "Drawer Allow names whichever program last used the
    /// destination IP". The attested exe is filed under the destination IP
    /// and then the hostname; a later connection to the same IP (a shared CDN
    /// address, or a guest process dialing it after the deny) overwrote only
    /// the IP key, and the newest-wins lookup put that program in the rule.
    /// Finding (CWE-284): "Drawer Allow keeps the first L4 program on a
    /// shared DNS name and ignores the program just blocked". On a port the
    /// MiTM doesn't see, the gate files the program under every DNS name
    /// cached for the IP as a guess; the first one held those names for an
    /// hour, so Allow named it, not the program the row was for.
    @Test("On an L4 port, Allow names the program just blocked; a guess never displaces an attested name")
    func l4AllowNamesLatest() throws {
        let pid = UUID(), ids = BinaryIdentityService.shared
        let ip = "104.16.0.7"
        // gate(): identity() files the IP, then the cached names as guesses.
        func l4(_ exe: String) {
            ids.noteExe(exe, profileID: pid, destinations: [ip], port: 8443)
            ids.noteExe(exe, profileID: pid, destinations: ["cdn.example", "api.example"], port: 8443, replace: false)
        }
        l4("/tmp/first")
        Thread.sleep(forTimeInterval: 0.01)
        l4("/usr/bin/tool")                                        // the connection just blocked
        #expect(ids.recentExe(profileID: pid, destinations: ["cdn.example"], port: 8443) == "/usr/bin/tool")
        // A later program on the IP alone doesn't take the row's name over
        // (Finding CWE-284, "Drawer Allow on an L4 port names whoever last
        // dialed the destination IP"): the name comes first, guess or not.
        ids.noteExe("/tmp/third", profileID: pid, destinations: [ip], port: 8443)
        #expect(ids.recentExe(profileID: pid, destinations: ["api.example", ip], port: 8443) == "/usr/bin/tool")
        // A name the flow itself named (SNI / Host) stays attested: a guess
        // doesn't replace it, nor turn it into a guess.
        ids.noteHost(.init(exe: "/usr/bin/curl", sha256: "a", ancestors: []), profileID: pid, host: "named.example", port: 8443)
        ids.noteExe("/tmp/evil", profileID: pid, destinations: ["named.example"], port: 8443, replace: false)
        ids.noteExe("/usr/bin/curl", profileID: pid, destinations: ["named.example"], port: 8443, replace: false)
        ids.noteExe("/tmp/evil", profileID: pid, destinations: ["named.example"], port: 8443, replace: false)
        #expect(ids.recentExe(profileID: pid, destinations: ["named.example", ip], port: 8443) == "/usr/bin/curl")
    }

    @Test("Allow names the program attested for the row's hostname, not a newer occupant of its IP")
    func allowNamesTheHostsProgram() throws {
        let pid = UUID(), ids = BinaryIdentityService.shared
        // The blocked connection: curl to pypi.org (151.101.0.223:443).
        ids.noteExe("/usr/bin/curl", profileID: pid, destinations: ["151.101.0.223"], port: 443)
        ids.noteExe("/usr/bin/curl", profileID: pid, destinations: ["pypi.org"], port: 443)
        // Afterwards, another program dials the same address.
        Thread.sleep(forTimeInterval: 0.01)
        ids.noteExe("/tmp/evil", profileID: pid, destinations: ["151.101.0.223"], port: 443)
        #expect(ids.recentExe(profileID: pid, destinations: ["pypi.org", "151.101.0.223"], port: 443) == "/usr/bin/curl")
        // The L4 gate files a connection under every name cached for its IP
        // (a guess): it fills a name with no program on record, never
        // replaces the one attested for it.
        ids.noteExe("/tmp/evil", profileID: pid, destinations: ["pypi.org", "files.example"], port: 443, replace: false)
        #expect(ids.recentExe(profileID: pid, destinations: ["pypi.org"], port: 443) == "/usr/bin/curl")
        #expect(ids.recentExe(profileID: pid, destinations: ["files.example"], port: 443) == "/tmp/evil")
        // No hostname on record (a bare-IP row): the IP's program, as before.
        #expect(ids.recentExe(profileID: pid, destinations: ["other.example", "151.101.0.223"], port: 443) == "/tmp/evil")
    }

    /// Same finding, for network proposals: the pending check and the
    /// status write straddled the policy write, so two approvals applied the
    /// rule twice and a reject during it was overwritten.
    @Test("Two approvals of one proposal apply it once; a reject while it applies is ignored")
    func oneApply() async throws {
        let (a, pid, box) = advisor(mode: .review)
        final class Count: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let applied = Count()
        a.applyApproved = { _, p in
            applied.lock.lock(); applied.n += 1; applied.lock.unlock()
            try? await Task.sleep(nanoseconds: 200_000_000)
            do { box.policy = try OpenShellPolicy.insertingRules(p.yaml, into: box.policy); return nil }
            catch { return "\(error)" }
        }
        let (s, _, d) = await a.handle(profileID: pid, method: "POST", target: "/v1/proposals",
                                       body: proposal("docs", host: "docs.example.org"), policyReloaded: { _ in false })
        #expect(s == 202)
        let id = try #require(((try JSONSerialization.jsonObject(with: d)) as? [String: Any])?["accepted_chunk_ids"] as? [String]).first!
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await a.approve(id: id, profileID: pid) }
            g.addTask { await a.approve(id: id, profileID: pid) }
            g.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                a.reject(id: id, profileID: pid, reason: "changed my mind")
            }
        }
        #expect(applied.n == 1)
        #expect(a.proposal(id: id, profileID: pid)?.status == .approved)
    }

    @Test("A draft being approved isn't superseded mid-apply: its rule is saved, so it ends approved")
    func notSupersededMidApply() async throws {
        let (a, pid, box) = advisor(mode: .review)
        a.applyApproved = { _, p in
            try? await Task.sleep(nanoseconds: 200_000_000)
            do { box.policy = try OpenShellPolicy.insertingRules(p.yaml, into: box.policy); return nil }
            catch { return "\(error)" }
        }
        a.recordDenial(profileID: pid, layer: "sni", host: "pypi.org", port: 443, method: nil, path: nil, reason: "no rule")
        let draft = try #require(a.pending(for: pid).first)
        #expect(draft.source == "mechanistic")
        async let approving: Void = a.approve(id: draft.id, profileID: pid)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // While it applies: an agent's proposal for the same endpoint, and a reject.
        _ = a.submit(profileID: pid, body: proposal("pypi_read", host: "pypi.org"))
        a.reject(id: draft.id, profileID: pid, reason: "no")
        await approving
        #expect(a.proposal(id: draft.id, profileID: pid)?.status == .approved)
        #expect(a.proposal(id: draft.id, profileID: pid)?.rejectionReason == nil)
    }
}
