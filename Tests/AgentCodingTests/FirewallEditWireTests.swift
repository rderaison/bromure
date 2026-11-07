import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// Finding CWE-362: a fat client's drawer read the host's whole rules,
/// edited them, and committed the document back; two quick Allows read the
/// same rules, so the second commit dropped the first's rule (and an editor
/// save or an expiry in between was lost the same way). The drawer now sends
/// the edit; the host applies it to the rules it holds at that moment.
@Suite("Firewall edits from a fat client apply on the host, one at a time")
struct FirewallEditWireTests {
    private func rule(_ text: String) throws -> EgressPolicy.Rule {
        try #require(try EgressPolicy.parse(text + "\ndefault deny").rules.first)
    }

    @Test("every edit round-trips, an inserted rule with its time limit")
    func roundTrip() throws {
        typealias E = FirewallRuleActions.Edit
        var timed = try rule("allow web docs.example.com")
        FirewallRuleActions.Duration.oneHour.apply(to: &timed, now: Date())
        var untilStop = try rule("allow tcp 203.0.113.9:443")
        FirewallRuleActions.Duration.untilStop.apply(to: &untilStop, now: Date())
        for e: E in [.insert(timed), .insert(untilStop), .disable(ruleText: "deny web any POST"),
                     .enable(ruleText: "allow web x.test", .fifteenMinutes), .remove(ruleText: "allow web y.test")] {
            #expect(E(wire: e.wire) == e, "\(e)")
        }
        // The time limit came along.
        guard case .insert(let back)? = E(wire: E.insert(timed).wire) else { Issue.record("no insert"); return }
        #expect(back.expiresAt != nil)
        // Nonsense is refused.
        #expect(E(wire: ["op": "drop-all"]) == nil)
        #expect(E(wire: ["op": "remove", "ruleText": ""]) == nil)
        #expect(E(wire: ["op": "enable", "ruleText": "allow web x", "duration": "forever"]) == nil)
        #expect(E(wire: ["op": "insert", "rule": "allow web a.test\nallow web b.test\ndefault allow"]) == nil)
    }

    @Test("two Allows applied one after the other on the host both stay")
    func sequentialEditsKeepBoth() throws {
        let base = "deny web any POST\ndefault allow"
        let a = try rule("allow web a.test"), b = try rule("allow web b.test")
        // What the host does now: each edit applied to the rules then in force.
        let afterA = try #require(FirewallRuleActions.apply(.insert(a), to: base))
        let afterB = try #require(FirewallRuleActions.apply(.insert(b), to: afterA))
        let rules = try EgressPolicy.parse(afterB).rules.map(\.text)
        #expect(rules.contains(a.text) && rules.contains(b.text))
        // What it did before: both computed from the same document, the
        // second committed whole -- a's rule gone.
        let lost = try #require(FirewallRuleActions.apply(.insert(b), to: base))
        #expect(!(try EgressPolicy.parse(lost).rules.map(\.text)).contains(a.text))
    }

    @Test("wired: the drawer sends the edit, the host applies it on the main thread")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let backend = try src("Sources/AgentCoding/PolicyDrawerBackend.swift")
        #expect(backend.contains("/firewall-edit\","))
        #expect(backend.contains("body: edit.wire)"))
        #expect(!backend.contains("\"rules\": text"))
        let server = try src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains("if method == \"POST\", raw.hasSuffix(\"/firewall-edit\") {"))
        #expect(server.contains("DispatchQueue.main.sync(execute: { self.onFirewallEdit?(id, edit) })"))
        #expect(try src("Sources/AgentCoding/BromureAC.swift").contains("return self.applyFirewallEditResult(edit, profileID: uuid)"))
    }

    /// Finding: "Remote firewall drawer reports failed edits as successful".
    /// The host answered 200 ok for an edit it couldn't make (rules that
    /// don't parse, a rule since removed, a save that failed), and the
    /// drawer checked only the status: an Allow showed done with no rule
    /// installed.
    @Test("an edit that can't be made is a failure with its reason; one already in place isn't")
    func outcomes() throws {
        typealias A = FirewallRuleActions
        let base = "allow web a.test\ndefault deny"
        let a = try rule("allow web a.test"), b = try rule("allow web b.test")
        guard case .changed(let out) = A.outcome(.insert(b), to: base) else { Issue.record("no change"); return }
        #expect(out.contains("b.test"))
        #expect(A.outcome(.insert(a), to: base) == .unchanged)             // already there, already first
        #expect(A.outcome(.remove(ruleText: "allow web gone.test"), to: base)
                == .failed("that rule is no longer in the workspace's firewall"))
        #expect(A.outcome(.disable(ruleText: "allow web gone.test"), to: base) != .unchanged)
        if case .failed = A.outcome(.insert(b), to: "this is not a ruleset ((") {} else { Issue.record("parsed nonsense") }
        // apply keeps its old meaning: new rules, or nil.
        #expect(A.apply(.insert(a), to: base) == nil)
        #expect(A.apply(.insert(b), to: base) == out)

        // What the host answers.
        let ok = ACAutomationServer.firewallResponse(.changed)
        #expect(ok.status == 200 && ok.body["ok"] as? Bool == true && ok.body["changed"] as? Bool == true)
        let same = ACAutomationServer.firewallResponse(.unchanged)
        #expect(same.status == 200 && same.body["ok"] as? Bool == true && same.body["changed"] as? Bool == false)
        let bad = ACAutomationServer.firewallResponse(.failed("couldn't save the workspace's firewall rules"))
        #expect(bad.status == 409 && bad.body["ok"] as? Bool == false
                && bad.body["error"] as? String == "couldn't save the workspace's firewall rules")
        #expect(FirewallCommitResult.unchanged.succeeded && !FirewallCommitResult.failed("x").succeeded)

        // What the drawer takes as done: a 200 that says ok, nothing else.
        typealias R = RemotePolicyDrawerBackend
        #expect(R.editSucceeded(ControlClient.Response(status: 200, json: ["ok": true, "changed": false])))
        #expect(!R.editSucceeded(ControlClient.Response(status: 200, json: ["ok": false])))
        #expect(!R.editSucceeded(ControlClient.Response(status: 200, json: [:])))
        #expect(!R.editSucceeded(ControlClient.Response(status: 409, json: ["ok": false, "error": "x"])))
        #expect(!R.editSucceeded(nil))

        // Both firewall routes answer this way.
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AutomationServer.swift"), encoding: .utf8)
        #expect(server.components(separatedBy: "case .some(let result): sendFirewallResult(fd: fd, result)").count - 1 == 2)
        #expect(!server.contains(#"case .some(let changed): sendResponse(fd: fd, status: 200, body: ["ok": true, "changed": changed])"#))
        #expect(try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
            .contains("return self.commitFirewallRulesResult(rules, profileID: uuid)"))
    }
}
