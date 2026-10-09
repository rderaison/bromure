import Foundation
import Testing
@testable import SandboxEngine
@testable import bromure_ac

/// Issue #38 QA: live cuts on the proxy route, the host a timeline row names,
/// allowed-connection logging, and the editor keeping unsaved edits.
@Suite("Firewall live QA (#38)")
struct FirewallLiveQATests {

    private func policy(_ text: String) throws -> EgressPolicy { try EgressPolicy.parse(text) }

    /// A registry whose reports are captured instead of emitted.
    private final class Captured: @unchecked Sendable {
        let lock = NSLock()
        var closures: [EgressConnectionRegistry.Closure] = []
        var cuts: [String] = []
        func add(_ c: EgressConnectionRegistry.Closure) { lock.lock(); closures.append(c); lock.unlock() }
        func cut(_ s: String) { lock.lock(); cuts.append(s); lock.unlock() }
    }

    private func registry(_ cap: Captured) -> EgressConnectionRegistry {
        let r = EgressConnectionRegistry()
        r.onClose = { _, c in cap.add(c) }
        return r
    }

    // MARK: 1 — established connections follow rule changes

    @Test("Switching the allowing rule off cuts the open tunnel; others stay")
    func switchOffCuts() throws {
        let cap = Captured()
        let reg = registry(cap)
        let pid = UUID(), other = UUID()
        let before = try policy("allow tcp example.com:443\nallow tcp github.com:443\ndefault deny")
        let rule = before.firstMatch(ip: nil, hostnames: ["example.com"], proto: .tcp, port: 443)?.text
        reg.register(profileID: pid, host: "example.com", port: 443, route: "proxy", rule: rule) { cap.cut("example") }
        reg.register(profileID: pid, host: "github.com", port: 443, route: "proxy", rule: "allow tcp github.com:443") { cap.cut("github") }
        reg.register(profileID: other, host: "example.com", port: 443, route: "proxy", rule: nil) { cap.cut("other-ws") }

        // Nothing changed: nothing cut.
        #expect(reg.reevaluate(profileID: pid, policy: before).isEmpty)

        let after = try policy("#@off allow tcp example.com:443\nallow tcp github.com:443\ndefault deny")
        let closed = reg.reevaluate(profileID: pid, policy: after)
        #expect(cap.cuts == ["example"])
        #expect(closed == [.init(host: "example.com", port: 443, route: "proxy",
                                 previousRule: "allow tcp example.com:443", denyingRule: nil)])
        #expect(cap.closures == closed)
        // Cut once: it's gone from the registry.
        #expect(reg.reevaluate(profileID: pid, policy: after).isEmpty)
        #expect(reg.openConnections(profileID: pid).map(\.host) == ["github.com"])
        #expect(reg.openConnections(profileID: other).count == 1)
    }

    @Test("A timed rule's expiry cuts at the instant it lapses; a new deny rule cuts too")
    func expiryAndNewDeny() throws {
        let cap = Captured()
        let reg = registry(cap)
        let pid = UUID()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let timed = try policy("allow tcp npmjs.org:443 #@until=\(2_000_000 + 900)\ndefault deny")
        reg.register(profileID: pid, host: "registry.npmjs.org", port: 443, route: "proxy",
                     rule: "allow tcp npmjs.org:443") { cap.cut("npm") }
        #expect(reg.reevaluate(profileID: pid, policy: timed, now: t0.addingTimeInterval(899)).isEmpty)
        #expect(reg.reevaluate(profileID: pid, policy: timed, now: t0.addingTimeInterval(900)).count == 1)
        #expect(cap.cuts == ["npm"])

        reg.register(profileID: pid, host: "pastebin.com", port: 443, route: "transparent", rule: nil) { cap.cut("paste") }
        let closed = reg.reevaluate(profileID: pid, policy: try policy("deny any pastebin.com\ndefault allow"))
        #expect(closed.first?.denyingRule == "deny any pastebin.com")
        #expect(cap.cuts == ["npm", "paste"])
    }

    @Test("An unregistered connection is never cut; nil policy cuts nothing")
    func unregistered() throws {
        let cap = Captured()
        let reg = registry(cap)
        let pid = UUID()
        let token = reg.register(profileID: pid, host: "a.com", port: 443, route: "proxy", rule: nil) { cap.cut("a") }
        #expect(reg.reevaluate(profileID: pid, policy: nil).isEmpty)
        reg.unregister(token)
        #expect(reg.reevaluate(profileID: pid, policy: try policy("default deny")).isEmpty)
        #expect(cap.cuts.isEmpty)
    }

    @Test("A cut that shuts the guest socket ends both directions of the tunnel")
    func cutShutsSocket() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        var one: Int32 = 1
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let reg = EgressConnectionRegistry()
        reg.onClose = { _, _ in }
        let pid = UUID()
        let fd = fds[0]
        reg.register(profileID: pid, host: "a.com", port: 443, route: "proxy", rule: "allow tcp a.com:443") {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
        reg.reevaluate(profileID: pid, policy: try policy("default deny"))
        var b: UInt8 = 0
        #expect(read(fds[1], &b, 1) == 0)            // the guest end sees EOF
        #expect(write(fds[0], &b, 1) == -1)           // and the relay can't write on
    }

    @Test("Firewall rows are deduplicated per destination and decision, per workspace")
    func dedupe() {
        let d = EgressReportDeduper()
        let pid = UUID()
        let t = Date(timeIntervalSince1970: 100)
        #expect(d.shouldReport(profileID: pid, host: "a.com", port: 443, denied: false, now: t))
        #expect(!d.shouldReport(profileID: pid, host: "A.com", port: 443, denied: false, now: t.addingTimeInterval(30)))
        #expect(d.shouldReport(profileID: pid, host: "a.com", port: 443, denied: true, now: t.addingTimeInterval(30)))
        #expect(d.shouldReport(profileID: UUID(), host: "a.com", port: 443, denied: false, now: t))
        #expect(d.shouldReport(profileID: pid, host: "a.com", port: 443, denied: false, now: t.addingTimeInterval(61)))
        d.reset(profileID: pid)
        #expect(d.shouldReport(profileID: pid, host: "a.com", port: 443, denied: false, now: t.addingTimeInterval(62)))
    }

    // MARK: 2 — the requested host, never a CDN's whole domain

    private func fw(host: String?, aliases: [String] = [], ip: String? = "104.16.1.1", port: Int = 443,
                    rule: String? = nil, denied: Bool) -> SecurityTimeline.Firewall {
        .init(host: host, ip: ip, port: port, proto: "tcp", rule: rule, denied: denied, byPolicy: true,
              aliases: aliases)
    }

    @Test("CDN / shared hosting: the exact names only, never 'all of cloudflare.net'")
    func cdnTargets() {
        let iana = FirewallRuleActions.targets(for: fw(host: "www.iana.org", aliases: ["www.iana.org.cdn.cloudflare.net"], denied: true))
        // The CDN's server name is never an Allow target (only in the tooltip).
        #expect(iana.map(\.name) == ["www.iana.org", "iana.org"])
        #expect(iana.map(\.wholeDomain) == [false, true])
        #expect(!iana.contains { $0.wholeDomain && $0.name == "cloudflare.net" })
        for host in ["d1234.cloudfront.net", "foo.s3.amazonaws.com", "me.github.io", "app.herokuapp.com",
                     "x.akamaiedge.net", "y.fastly.net", "z.azureedge.net", "lh3.googleusercontent.com"] {
            let t = FirewallRuleActions.targets(for: fw(host: host, denied: true))
            #expect(t == [.init(host)], "\(host)")
        }
        #expect(FirewallRuleActions.isSharedHosting("www.iana.org.cdn.cloudflare.net"))
        #expect(!FirewallRuleActions.isSharedHosting("github.com"))
    }

    @Test("A timeline row maps its queried host first and keeps the CNAME aliases")
    func timelineAliases() throws {
        let e = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("allow"), "proto": .string("tcp"), "host": .string("www.wikipedia.org"),
            "hostnames": .array([.string("www.wikipedia.org"), .string("dyna.wikimedia.org")]),
            "ip": .string("185.15.59.224"), "port": .int(443), "rule": .null, "by_policy": .bool(true),
        ], now: Date()))
        let f = try #require(e.firewall)
        #expect(f.host == "www.wikipedia.org")
        #expect(f.aliases == ["dyna.wikimedia.org"])
        #expect(FirewallRuleActions.targets(for: f).first?.name == "www.wikipedia.org")
        // Survives the disk log.
        let line = try #require(SecurityTimeline.line(e))
        #expect(SecurityTimeline.event(fromLine: line.dropLast())?.firewall?.aliases == ["dyna.wikimedia.org"])
    }

    @Test("A block made from a transparent row matches what the proxy route sees")
    func blockMatchesBothRoutes() throws {
        let f = fw(host: "www.wikipedia.org", aliases: ["dyna.wikimedia.org"], denied: false)
        let target = try #require(FirewallRuleActions.targets(for: f).first)
        let rule = try #require(FirewallRuleActions.blockRule(target: target.name))
        let p = EgressPolicy(defaultAction: .allow, rules: [rule])
        // Proxy route: the CONNECT host.
        #expect(p.verdict(ip: nil, hostnames: ["www.wikipedia.org"], proto: .tcp, port: 443) == .deny)
        // Transparent route: every snooped name for the address.
        #expect(p.verdict(ip: nil, hostnames: ["www.wikipedia.org", "dyna.wikimedia.org"], proto: .tcp, port: 443) == .deny)
    }

    // MARK: 3/4 — allowed connections are logged

    @Test("Log allowed connections: automatic follows the rules; an explicit choice wins")
    func logAllowedSetting() {
        var p = bromure_ac.Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        #expect(!p.resolvedEgressPolicy.reportsAllowed)                 // no rules, automatic
        p.logAllowedConnections = true
        #expect(p.resolvedEgressPolicy.reportsAllowed)                  // zero rules, on
        #expect(VMNetSwitch.reportsAllowedFlows(p.resolvedEgressPolicy))
        p.logAllowedConnections = nil
        p.egressRules = "default allow"
        // Only the built-in local-models allowance: not "rules" for this.
        #expect(!p.resolvedEgressPolicy.reportsAllowed)
        p.egressRules = "deny any pastebin.com\ndefault allow"
        #expect(p.resolvedEgressPolicy.reportsAllowed)
        p.logAllowedConnections = false
        #expect(!p.resolvedEgressPolicy.reportsAllowed)
        #expect(!VMNetSwitch.reportsAllowedFlows(p.resolvedEgressPolicy))
    }

    @Test("The setting round-trips through the profile JSON; absent stays automatic")
    func logAllowedCodable() throws {
        var p = bromure_ac.Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        let auto = try JSONDecoder().decode(bromure_ac.Profile.self, from: JSONEncoder().encode(p))
        #expect(auto.logAllowedConnections == nil)
        p.logAllowedConnections = false
        let off = try JSONDecoder().decode(bromure_ac.Profile.self, from: JSONEncoder().encode(p))
        #expect(off.logAllowedConnections == false)
    }

    @MainActor
    @Test("Allowed rows to one destination fold into one counted row; blocks don't")
    func allowedRowsCoalesce() throws {
        let pid = UUID()
        let data: [String: AnyJSON] = ["action": .string("allow"), "proto": .string("tcp"), "host": .string("github.com"),
                                       "ip": .string("140.82.112.3"), "port": .int(443), "rule": .null,
                                       "by_policy": .bool(true), "layer": .string("proxy")]
        let a = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: data, now: Date()))
        #expect(a.coalesceKey != nil)
        var deny = data; deny["action"] = .string("deny")
        let d = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: deny, now: Date()))
        #expect(d.coalesceKey == nil)
        var events: [SecurityTimeline.Event] = []
        SecurityTimeline.coalesce(a, into: &events)
        let a2 = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: data,
                                                   now: Date().addingTimeInterval(60)))
        SecurityTimeline.coalesce(a2, into: &events)
        #expect(events.count == 1 && events[0].count == 2)
        #expect(events[0].firewall?.host == "github.com")
    }

    @Test("A cut connection reads as closed, naming the rule that no longer allows it")
    func closedRow() throws {
        let e = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("tcp"), "host": .string("example.com"), "port": .int(443),
            "layer": .string("proxy"), "closed": .bool(true), "previous_rule": .string("allow tcp example.com:443"),
            "rule": .null, "by_policy": .bool(true),
        ], now: Date()))
        #expect(e.kind == .blocked)
        #expect(e.decision == "connection closed (proxy) — “allow tcp example.com:443” no longer allows it")
        #expect(e.firewall?.denied == true && e.coalesceKey == nil)
        let d = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("tcp"), "host": .string("pastebin.com"), "port": .int(443),
            "closed": .bool(true), "rule": .string("deny any pastebin.com"), "by_policy": .bool(true),
        ], now: Date()))
        #expect(d.decision == "connection closed — deny — deny any pastebin.com")
        // The direct (transparent) route says so.
        let t = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("deny"), "proto": .string("tcp"), "host": .string("example.com"), "port": .int(443),
            "layer": .string("transparent"), "closed": .bool(true), "previous_rule": .string("allow tcp example.com:443"),
            "rule": .null, "by_policy": .bool(true),
        ], now: Date()))
        #expect(t.decision == "connection closed (direct) — “allow tcp example.com:443” no longer allows it")
    }

    @Test("Default-policy rows use the localized decision word")
    func defaultPolicyWording() throws {
        let e = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("allowed"), "proto": .string("tcp"), "host": .string("a.com"), "port": .int(443),
            "rule": .null, "by_policy": .bool(true),
        ], now: Date()))
        #expect(e.decision == "allow — default policy")
    }

    // MARK: 9 — rows whose destination the rules have flipped since

    @Test("An old block row knows the destination is allowed now, and by what")
    func currentDecision() throws {
        let row = fw(host: "api.example.com", ip: "93.184.216.34", denied: true)
        let p = try policy("allow tcp example.com:443\ndefault deny")
        let now = try #require(FirewallRuleActions.currentDecision(for: row, policy: p))
        #expect(!now.denied && now.rule == "allow tcp example.com:443")
        let still = try #require(FirewallRuleActions.currentDecision(for: row, policy: try policy("default deny")))
        #expect(still.denied && still.rule == nil)
        // An alias match counts (transparent rows).
        let aliased = fw(host: "www.wikipedia.org", aliases: ["dyna.wikimedia.org"], denied: false)
        #expect(FirewallRuleActions.currentDecision(for: aliased, policy: try policy("deny any wikimedia.org"))?.denied == true)
    }

    @Test("An identical rule is found so a quick allow can show its current time limit")
    func existingRule() throws {
        let rule = try #require(FirewallRuleActions.allowRule(target: "a.com", fw: fw(host: "a.com", denied: true)))
        let ex = try #require(FirewallRuleActions.existing(rule, in: "deny any a.com\nallow tcp a.com:443 #@until=4000000000\ndefault deny"))
        #expect(ex.expiresAt == Date(timeIntervalSince1970: 4_000_000_000))
        #expect(FirewallRuleActions.existing(rule, in: "default deny") == nil)
    }

    // MARK: Follow-up QA (#38 round 2)

    /// Live QA run 1: a download started right after a CLI `vm edit` save
    /// outlived its timed rule — the CLI path pushes the policy without
    /// arming the app's expiry timer, so enforcement waited for the 15 s
    /// sweep to save + re-push the switched-off rule, and the transfer ended
    /// first. The registry now cuts at the expiry instant by itself.
    @Test("A timed rule's expiry cuts an open tunnel at that instant with no save")
    func expiryCutsWithoutSave() async throws {
        let cap = Captured()
        let reg = registry(cap)
        let pid = UUID()
        let now = Date()
        let until = Int(now.timeIntervalSince1970.rounded(.down)) + 2
        let timed = try policy("allow tcp speed.cloudflare.com:443 #@until=\(until)\ndefault deny")
        // The policy in force when the download opens…
        reg.applyPolicy(profileID: pid, policy: timed)
        reg.register(profileID: pid, host: "speed.cloudflare.com", port: 443, route: "proxy",
                     rule: "allow tcp speed.cloudflare.com:443") { cap.cut("dl") }
        // …a CLI-style save re-pushes the same rules (no timer of the app's
        // armed), and nothing saves the switched-off rule afterwards.
        #expect(reg.applyPolicy(profileID: pid, policy: timed).isEmpty)
        #expect(reg.armedExpiry(profileID: pid) == Date(timeIntervalSince1970: TimeInterval(until)))
        #expect(cap.cuts.isEmpty)
        var waited = 0.0
        while cap.cuts.isEmpty, waited < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        #expect(cap.cuts == ["dl"])
        #expect(Date().timeIntervalSince1970 >= TimeInterval(until))
        #expect(cap.closures.first?.previousRule == "allow tcp speed.cloudflare.com:443")
        // The expired rule is past: nothing left to arm.
        #expect(reg.armedExpiry(profileID: pid) == nil)
        // A later save of the switched-off rule finds nothing more to cut.
        #expect(reg.applyPolicy(profileID: pid, policy: try policy("#@off allow tcp speed.cloudflare.com:443\ndefault deny")).isEmpty)
    }

    @Test("A new policy re-arms the expiry; a forgotten workspace has none")
    func expiryRearm() throws {
        let reg = registry(Captured())
        let pid = UUID()
        let t0 = Date()
        let soon = Int(t0.timeIntervalSince1970) + 600, later = soon + 600
        reg.applyPolicy(profileID: pid, policy: try policy("allow tcp a.com:443 #@until=\(later)\nallow tcp b.com:443 #@until=\(soon)\ndefault deny"), now: t0)
        #expect(reg.armedExpiry(profileID: pid, now: t0) == Date(timeIntervalSince1970: TimeInterval(soon)))
        // b.com switched off (the sweep): the next expiry is a.com's.
        reg.applyPolicy(profileID: pid, policy: try policy("allow tcp a.com:443 #@until=\(later)\n#@off allow tcp b.com:443\ndefault deny"), now: t0)
        #expect(reg.armedExpiry(profileID: pid, now: t0) == Date(timeIntervalSince1970: TimeInterval(later)))
        reg.forget(profileID: pid)
        #expect(reg.armedExpiry(profileID: pid, now: t0) == nil)
    }

    @Test("The trailing packets of a cut connection are recognised as that connection")
    func recentlyCut() throws {
        let reg = registry(Captured())
        let pid = UUID()
        reg.register(profileID: pid, host: "www.wikipedia.org", port: 443, route: "transparent",
                     rule: "allow tcp www.wikipedia.org:443") {}
        let t = Date()
        #expect(reg.reevaluate(profileID: pid, policy: try policy("default deny"), now: t).count == 1)
        #expect(reg.recentlyCut(profileID: pid, hostnames: ["www.wikipedia.org", "dyna.wikimedia.org"],
                                ip: "185.15.59.224", port: 443, now: t.addingTimeInterval(1)))
        #expect(!reg.recentlyCut(profileID: pid, hostnames: ["www.wikipedia.org"], ip: nil, port: 80,
                                 now: t.addingTimeInterval(1)))
        #expect(!reg.recentlyCut(profileID: UUID(), hostnames: ["www.wikipedia.org"], ip: nil, port: 443,
                                 now: t.addingTimeInterval(1)))
        #expect(!reg.recentlyCut(profileID: pid, hostnames: ["www.wikipedia.org"], ip: nil, port: 443,
                                 now: t.addingTimeInterval(EgressConnectionRegistry.recentCutWindow + 1)))
    }

    @Test("An allowed transparent row names the site, not the CDN server, first")
    func allowedRowNamesSite() throws {
        // The switch's snooped names, the CDN server first.
        let e = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("allow"), "proto": .string("tcp"), "host": .string("dyna.wikimedia.org"),
            "hostnames": .array([.string("dyna.wikimedia.org"), .string("www.wikipedia.org")]),
            "ip": .string("185.15.59.224"), "port": .int(443), "rule": .null, "by_policy": .bool(true),
            "layer": .string("l4"),
        ], now: Date()))
        #expect(e.condition.hasPrefix("www.wikipedia.org:443"))
        #expect(e.firewall?.host == "www.wikipedia.org")
        #expect(e.firewall?.aliases == ["dyna.wikimedia.org"])
        // A host that's a server name with no better alias stays as is.
        let cdn = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "egress.firewall", eventData: [
            "action": .string("allow"), "proto": .string("tcp"), "host": .string("d1.cloudfront.net"),
            "hostnames": .array([.string("d1.cloudfront.net")]), "port": .int(443), "by_policy": .bool(true),
        ], now: Date()))
        #expect(cdn.firewall?.host == "d1.cloudfront.net")
    }

    @Test("The Allow menu hides CDN / server aliases; an old row is offered under the site")
    func serverAliasesHidden() {
        let wiki = FirewallRuleActions.targets(for: fw(host: "www.wikipedia.org", aliases: ["dyna.wikimedia.org"], denied: true))
        #expect(wiki.map(\.name) == ["www.wikipedia.org", "wikipedia.org"])
        // A row written before the fix (host = the CDN server).
        let old = FirewallRuleActions.targets(for: fw(host: "dyna.wikimedia.org", aliases: ["www.wikipedia.org"], denied: true))
        #expect(old.first?.name == "www.wikipedia.org")
        #expect(!old.contains { $0.name == "dyna.wikimedia.org" })
        for name in ["www.iana.org.cdn.cloudflare.net", "e1234.a.akamaiedge.net", "e9.dscx.akamaiedge.net",
                     "part-0012.t-0009.t-msedge.net", "foo.edgekey.net", "x.cdn.example.net", "dyna.wikimedia.org"] {
            #expect(FirewallRuleActions.isServerName(name), "\(name)")
        }
        for name in ["www.wikipedia.org", "api.github.com", "registry.npmjs.org", "pypi.org"] {
            #expect(!FirewallRuleActions.isServerName(name), "\(name)")
        }
        // A non-server alias stays offered.
        let gh = FirewallRuleActions.targets(for: fw(host: "github.com", aliases: ["lb-140-82-112-3-iad.github.com", "gh.example.org"], denied: true))
        #expect(gh.map(\.name) == ["github.com", "gh.example.org"])
    }

    @MainActor
    @Test("Every folded connection counts on the allowed row")
    func repeatsCount() throws {
        let pid = UUID()
        let data: [String: AnyJSON] = ["action": .string("allow"), "proto": .string("tcp"), "host": .string("github.com"),
                                       "port": .int(443), "rule": .null, "by_policy": .bool(true), "layer": .string("proxy")]
        let tl = SecurityTimeline(directory: nil)
        // One reported row + five deduped repeats (counted, not listed).
        for i in 0..<6 {
            let e = try #require(SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: data,
                                                      now: Date().addingTimeInterval(Double(i))))
            tl.append(e)
        }
        #expect(tl.events.count == 1)
        #expect(tl.events.first?.repeats == 6)
    }

    // MARK: 5 — the editor keeps unsaved edits

    @Test("No unsaved edits: the external change is adopted as is")
    func adoptClean() {
        let saved = "allow tcp a.com:443\ndefault deny"
        // The editor's text may differ only by formatting.
        #expect(EgressRulesEditor.adopt(external: "#@off allow tcp a.com:443\ndefault deny",
                                        previous: saved, editing: "allow  tcp a.com:443\n\ndefault deny")
                == .replace("#@off allow tcp a.com:443\ndefault deny"))
        #expect(EgressRulesEditor.adopt(external: "x", previous: nil, editing: "y") == .replace("x"))
    }

    @Test("Unsaved edits: a timeline action merges in rule by rule")
    func mergeEdits() throws {
        let saved = "allow tcp a.com:443\nallow tcp b.com:443 #@until=4000000000\ndefault deny"
        // The user, unsaved: added c.com, deleted nothing, changed the default.
        let editing = "allow tcp a.com:443\nallow tcp b.com:443 #@until=4000000000\nallow udp c.com:53\ndefault allow"
        // Outside: a quick allow of d.com (first), b.com expired → off, a.com removed.
        let external = "allow tcp d.com:443\n#@off allow tcp b.com:443\ndefault deny"
        guard case .merged(let out) = EgressRulesEditor.adopt(external: external, previous: saved, editing: editing) else {
            Issue.record("expected a merge"); return
        }
        let p = try EgressPolicy.parse(out)
        #expect(p.rules.map(\.text) == ["allow tcp d.com:443", "allow tcp b.com:443", "allow udp c.com:53"])
        #expect(p.rules[1].enabled == false && p.rules[1].expiresAt == nil)
        // The default didn't change outside, so the user's change stays.
        #expect(p.defaultAction == .allow)
    }

    @Test("Edits that don't parse: ask instead of dropping them")
    func mergeConflict() {
        #expect(EgressRulesEditor.adopt(external: "allow tcp d.com:443\ndefault deny",
                                        previous: "default deny", editing: "allow tcp a.com:99999\ndefault deny")
                == .ask)
    }
}
