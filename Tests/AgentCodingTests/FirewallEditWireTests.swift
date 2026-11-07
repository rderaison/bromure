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
        #expect(try src("Sources/AgentCoding/BromureAC.swift").contains("return self.applyFirewallEdit(edit, profileID: uuid)"))
    }
}
