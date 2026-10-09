import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

/// Security Timeline firewall quick actions: from a verdict to the rule that
/// changes it, and the restart prompt staying out of firewall edits.
@Suite("Firewall quick actions")
struct FirewallRuleActionsTests {

    private func fw(host: String?, ip: String? = "140.82.112.3", port: Int = 443, proto: String = "tcp",
                    rule: String? = nil, denied: Bool, byPolicy: Bool = true) -> SecurityTimeline.Firewall {
        .init(host: host, ip: ip, port: port, proto: proto, rule: rule, denied: denied, byPolicy: byPolicy)
    }

    @Test("Targets: exact host first, then its registrable domain; bare IP when nameless")
    func targets() {
        func names(_ f: SecurityTimeline.Firewall) -> [String] { FirewallRuleActions.targets(for: f).map(\.name) }
        #expect(names(fw(host: "api.github.com", denied: true)) == ["api.github.com", "github.com"])
        #expect(FirewallRuleActions.targets(for: fw(host: "api.github.com", denied: true)).map(\.wholeDomain) == [false, true])
        #expect(names(fw(host: "github.com", denied: true)) == ["github.com"])
        #expect(names(fw(host: "a.b.example.co.uk", denied: true)) == ["a.b.example.co.uk", "example.co.uk"])
        #expect(names(fw(host: nil, denied: true)) == ["140.82.112.3"])
        // The :80 path reports the destination IP as the host when there's no Host header.
        #expect(names(fw(host: "1.2.3.4", ip: nil, denied: true)) == ["1.2.3.4"])
    }

    @Test("Only ruleset decisions on TCP/UDP get actions")
    func actionable() {
        #expect(FirewallRuleActions.isActionable(fw(host: "a.com", denied: true)))
        #expect(!FirewallRuleActions.isActionable(fw(host: "a.com", denied: true, byPolicy: false)))
        #expect(!FirewallRuleActions.isActionable(fw(host: nil, ip: nil, port: 0, proto: "ipv6", denied: true)))
    }

    @Test("Allow on a blocked row: a proto+port rule placed first, which flips the verdict")
    func allowBlocked() throws {
        let rules = "deny tcp github.com\nallow tcp example.com:443\ndefault deny"
        let f = fw(host: "api.github.com", denied: true)
        let rule = try #require(FirewallRuleActions.allowRule(target: "api.github.com", fw: f))
        #expect(rule.text == "allow tcp api.github.com:443")
        let out = try #require(FirewallRuleActions.apply(.insert(rule), to: rules))
        let p = try EgressPolicy.parse(out)
        #expect(p.rules.first?.text == "allow tcp api.github.com:443")
        #expect(p.verdict(ip: nil, hostnames: ["api.github.com"], proto: .tcp, port: 443) == .allow)
        // Narrow: another port of it, and the rest of github.com, still denied.
        #expect(p.verdict(ip: nil, hostnames: ["api.github.com"], proto: .tcp, port: 22) == .deny)
        #expect(p.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == .deny)
        // UDP flows get a UDP rule.
        let u = try #require(FirewallRuleActions.allowRule(target: "8.8.8.8", fw: fw(host: nil, ip: "8.8.8.8", port: 53, proto: "udp", denied: true)))
        #expect(u.text == "allow udp 8.8.8.8:53")
    }

    @Test("A temporary allow lapses on its own and is swept off")
    func temporaryAllow() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var rule = try #require(FirewallRuleActions.allowRule(target: "registry.npmjs.org",
                                                              fw: fw(host: "registry.npmjs.org", denied: true)))
        FirewallRuleActions.Duration.fifteenMinutes.apply(to: &rule, now: now)
        let out = try #require(FirewallRuleActions.apply(.insert(rule), to: "default deny", now: now))
        #expect(out.contains("#@until=\(1_000_000 + 900)"))
        let p = try EgressPolicy.parse(out)
        #expect(p.verdict(ip: nil, hostnames: ["registry.npmjs.org"], proto: .tcp, port: 443,
                          now: now.addingTimeInterval(899)) == .allow)
        #expect(p.verdict(ip: nil, hostnames: ["registry.npmjs.org"], proto: .tcp, port: 443,
                          now: now.addingTimeInterval(900)) == .deny)
        let swept = try #require(EgressPolicy.sweeping(out, now: now.addingTimeInterval(901), workspaceStopped: false))
        #expect(swept.hasPrefix("#@off allow tcp registry.npmjs.org:443"))
    }

    @Test("Re-allowing replaces the same rule instead of piling up duplicates")
    func noDuplicates() throws {
        let start = "#@off allow tcp a.com:443\ndeny tcp a.com\ndefault deny"
        let rule = try #require(FirewallRuleActions.allowRule(target: "a.com", fw: fw(host: "a.com", denied: true)))
        let out = try #require(FirewallRuleActions.apply(.insert(rule), to: start))
        #expect(out == "allow tcp a.com:443\ndeny tcp a.com\ndefault deny")
    }

    @Test("Allowed by a rule: switch it off or remove it; allowed by default: block the host")
    func allowedRow() throws {
        let rules = "allow tcp github.com:443 #@until=stop\ndefault deny"
        let off = try #require(FirewallRuleActions.apply(.disable(ruleText: "allow tcp github.com:443"), to: rules))
        #expect(off == "#@off allow tcp github.com:443\ndefault deny")
        #expect(try EgressPolicy.parse(off).verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == .deny)
        let gone = try #require(FirewallRuleActions.apply(.remove(ruleText: "allow tcp github.com:443"), to: rules))
        #expect(gone == "default deny")
        // A rule no longer in the text: nothing to do.
        #expect(FirewallRuleActions.apply(.disable(ruleText: "allow tcp x.com:443"), to: rules) == nil)
        #expect(!FirewallRuleActions.contains(ruleText: "allow web bromure.llm", in: rules))

        let block = try #require(FirewallRuleActions.blockRule(target: "pastebin.com"))
        #expect(block.text == "deny any pastebin.com")
        let blocked = try #require(FirewallRuleActions.apply(.insert(block), to: "allow tcp a.com:443\ndefault allow"))
        let p = try EgressPolicy.parse(blocked)
        #expect(p.verdict(ip: nil, hostnames: ["pastebin.com"], proto: .tcp, port: 443) == .deny)
        #expect(p.verdict(ip: nil, hostnames: ["pastebin.com"], proto: .udp, port: 53) == .deny)
        #expect(p.verdict(ip: nil, hostnames: ["a.com"], proto: .tcp, port: 443) == .allow)
    }

    @Test("Re-enabling a switched-off rule for a while")
    func enableFor() throws {
        let now = Date(timeIntervalSince1970: 500)
        let out = try #require(FirewallRuleActions.apply(.enable(ruleText: "allow tcp a.com:443", .oneHour),
                                                         to: "#@off allow tcp a.com:443\ndefault deny", now: now))
        #expect(out == "allow tcp a.com:443 #@until=4100\ndefault deny")
    }

    // MARK: - Timeline rows

    @Test("A firewall event names its deciding rule and carries the destination")
    func timelineMapping() throws {
        let pid = UUID()
        let e = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: [
            "action": .string("allow"), "layer": .string("l4"), "proto": .string("tcp"),
            "host": .string("api.github.com"), "ip": .string("140.82.112.3"), "port": .int(443),
            "rule": .string("allow tcp github.com:443"), "by_policy": .bool(true),
        ], now: Date()))
        #expect(e.decision == "allow — allow tcp github.com:443")
        let f = try #require(e.firewall)
        #expect(f.host == "api.github.com" && f.port == 443 && f.rule == "allow tcp github.com:443")
        #expect(!f.denied && f.byPolicy)

        // Default action (rule key present but null).
        let d = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("tcp"), "host": .null, "ip": .string("1.2.3.4"),
            "port": .int(22), "rule": .null, "by_policy": .bool(true),
        ], now: Date()))
        #expect(d.kind == .blocked && d.firewall?.rule == nil && d.firewall?.byPolicy == true)
        #expect(d.decision.hasPrefix("deny"))

        // A transport drop and a legacy event: no rule wording, no actions.
        let t = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("udp"), "port": .int(443), "rule": .null,
            "by_policy": .bool(false),
        ], now: Date()))
        #expect(t.decision == "deny" && t.firewall?.byPolicy == false)
        let legacy = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("tcp"), "host": .string("a.com"), "port": .int(443),
        ], now: Date()))
        #expect(legacy.decision == "deny" && legacy.firewall?.byPolicy == false)
    }

    @Test("The structured verdict survives the disk log and the fat-client mirror")
    func persistence() throws {
        var e = SecurityTimeline.Event(time: Date(timeIntervalSince1970: 1000), engine: "Firewall",
                                       condition: "a.com:443 tcp", decision: "deny", kind: .blocked,
                                       profileID: UUID())
        e.firewall = fw(host: "a.com", rule: "deny tcp a.com", denied: true)
        let line = try #require(SecurityTimeline.line(e))
        let back = try #require(SecurityTimeline.event(fromLine: line.dropLast()))
        #expect(back.firewall == e.firewall)
    }

    // MARK: - Restart prompt

    @Test("Firewall-only edits never ask for a restart")
    func noRestartForFirewall() {
        var booted = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        booted.egressRules = "allow tcp github.com:443\ndefault deny"
        var edited = booted
        edited.egressRules = "#@off allow tcp github.com:443\nallow tcp registry.npmjs.org:443 #@until=stop\ndefault deny"
        #expect(ACAppDelegate.restartRequiringChangeKinds(from: booted, to: edited).isEmpty)
        #expect(ACAppDelegate.restartChangesToPrompt(previous: booted, new: edited, booted: booted).isEmpty)
        // A real VM-baked change alongside still prompts, for that change only.
        edited.memoryGB = booted.memoryGB + 2
        #expect(ACAppDelegate.restartChangesToPrompt(previous: booted, new: edited, booted: booted) == [.memory])
    }
}
