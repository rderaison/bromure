import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// User report: a strict OpenShell workspace refused registry.npmjs.org
/// although its policy had an `npm` rule, and the agent was told "the
/// workspace's firewall denies what no rule allows". With the strict sandbox,
/// binaries are enforced, and a rule that lists none applies to no program
/// (OpenShell's semantics) — and Bromure's own template listed none, so it
/// allowed nothing there. The template now names each rule's programs, and a
/// denial says which rule refused which program.
@Suite("Strict OpenShell: the template's rules name their programs, and a refusal says why")
struct OpenShellStrictBinariesTests {
    private func id(_ exe: String, parents: [String] = ["/usr/bin/bash"]) -> OpenShellPolicy.BinaryIdentity {
        .init(exe: exe, sha256: "", ancestors: parents.map { .init(exe: $0, sha256: "") })
    }
    private func allowed(_ p: OpenShellPolicy, _ host: String, _ exe: String, port: UInt16 = 443) -> Bool {
        if case .allow = p.evaluateConnect(hostnames: [host], ip: nil, port: port, identity: id(exe), enforceBinaries: true) {
            return true
        }
        return false
    }

    @Test("under strict, the template lets each tool reach its registry, and nothing else")
    func templateWorksUnderStrict() throws {
        let p = try OpenShellPolicy.parse(OpenShellPolicyEditor.starterPolicy)
        #expect(p.networkPolicies.allSatisfy { !$0.binaries.isEmpty }, "a rule without binaries allows nothing under strict")
        #expect(allowed(p, "registry.npmjs.org", "/usr/bin/node"))            // npm, npx
        #expect(allowed(p, "registry.npmjs.org", "/opt/bun/bin/bun"))
        #expect(allowed(p, "pypi.org", "/usr/bin/python3.12"))                // pip
        #expect(allowed(p, "files.pythonhosted.org", "/usr/bin/python3.12"))
        #expect(allowed(p, "github.com", "/usr/bin/git"))
        // git's https helper opens the connection; its parent git counts.
        #expect({ if case .allow = p.evaluateConnect(hostnames: ["github.com"], ip: nil, port: 443,
                                                     identity: id("/usr/lib/git-core/git-remote-https", parents: ["/usr/bin/git"]),
                                                     enforceBinaries: true) { return true }; return false }())
        #expect(allowed(p, "api.github.com", "/usr/bin/gh"))
        #expect(allowed(p, "ports.ubuntu.com", "/usr/lib/apt/methods/http", port: 80))
        // Not the program's registry, or a copy the agent could make in $HOME.
        #expect(!allowed(p, "registry.npmjs.org", "/usr/bin/curl"))
        #expect(!allowed(p, "registry.npmjs.org", "/home/ubuntu/bin/node"))
        #expect(!allowed(p, "pypi.org", "/home/ubuntu/.local/bin/python3"))
        #expect(!allowed(p, "example.com", "/usr/bin/curl"))
    }

    @Test("a refusal by binary identity names the rule and the program")
    func reasonNamesTheRule() throws {
        // The reported workspace's policy: the template as it was, no binaries.
        let old = """
        version: 1
        network_policies:
          npm:
            endpoints:
              - { host: registry.npmjs.org, port: 443, protocol: rest, enforcement: enforce, access: read-only }
        """
        var strict = EgressPolicy(openShell: try OpenShellPolicy.parse(old))
        strict.enforceBinaries = true
        let why = try #require(strict.identityDenialReason(hostnames: ["registry.npmjs.org"], ip: nil, port: 443,
                                                           exe: "/usr/bin/node"))
        #expect(why.contains("rule `npm` lists no binaries") && why.contains("/usr/bin/node"))

        var listed = EgressPolicy(openShell: try OpenShellPolicy.parse(OpenShellPolicyEditor.starterPolicy))
        listed.enforceBinaries = true
        let other = try #require(listed.identityDenialReason(hostnames: ["registry.npmjs.org"], ip: nil, port: 443,
                                                             exe: "/usr/bin/curl"))
        #expect(other.contains("rule `npm` doesn't list /usr/bin/curl"))
        // Not a binaries matter: a destination no rule allows, or no strict.
        #expect(listed.identityDenialReason(hostnames: ["example.com"], ip: nil, port: 443, exe: "/usr/bin/curl") == nil)
        let advisory = EgressPolicy(openShell: try OpenShellPolicy.parse(old))
        #expect(advisory.identityDenialReason(hostnames: ["registry.npmjs.org"], ip: nil, port: 443, exe: "/usr/bin/node") == nil)
    }

    @Test("the firewall's event carries that reason, which the timeline and the agent's note quote")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains(".identityDenialReason(hostnames: ev.hostnames, ip: ev.dstIP, port: ev.port, exe: exe)"))
        #expect(ac.contains(#"eventData["reason"] = .string(why)"#))
        #expect(ac.contains("let egressEngine = mitmEngine"))
        // Under strict every flow goes through the MiTM: its two denials say it too.
        let mitm = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Mitm/MitmEngine.swift"), encoding: .utf8)
        #expect(mitm.components(separatedBy: "policy.identityDenialReason(hostnames:").count - 1 == 2)
        // The timeline row: "deny — <reason>"; the note: the event's own reason first.
        let row = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "host": .string("registry.npmjs.org"), "port": .int(443), "proto": .string("tcp"),
            "by_policy": .bool(true), "exe": .string("/usr/bin/node"),
            "reason": .string("rule `npm` lists no binaries"),
        ], now: Date()))
        #expect(row.decision.contains("rule `npm` lists no binaries"))
    }
}
