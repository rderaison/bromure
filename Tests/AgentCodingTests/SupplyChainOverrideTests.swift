import Foundation
import Testing
@testable import bromure_ac

/// GitHub issue #54: "Override socket.dev decisions per NPM package". A
/// package a reputation check blocked got a silent 451 and no way to let
/// it through short of turning supply-chain security off; now the user is
/// asked (this session / always / not again this session), "always" is a
/// workspace allowlist, and the Security window can add to it.
@Suite("Supply chain: overriding a reputation block per package")
struct SupplyChainOverrideTests {
    @Test("the reputation allowlist matches like the others and round-trips with the profile")
    func allowlist() throws {
        var p = SupplyChainPolicy()
        #expect(!p.reputationAllows(ecosystem: "npm", name: "workerd"))
        p.reputationAllowlist = ["npm:workerd", "left-pad"]
        #expect(p.reputationAllows(ecosystem: "npm", name: "workerd"))
        #expect(p.reputationAllows(ecosystem: "npm", name: "WorkerD"))
        #expect(!p.reputationAllows(ecosystem: "pypi", name: "workerd"))
        #expect(p.reputationAllows(ecosystem: "pypi", name: "left-pad"))
        let back = try JSONDecoder().decode(SupplyChainPolicy.self, from: JSONEncoder().encode(p))
        #expect(back.reputationAllowlist == ["npm:workerd", "left-pad"])
        // A profile from before the field decodes with an empty list, and an
        // empty list isn't written.
        let old = try JSONDecoder().decode(SupplyChainPolicy.self, from: Data("{}".utf8))
        #expect(old.reputationAllowlist.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(SupplyChainPolicy()), as: UTF8.self)
        #expect(!json.contains("reputationAllowlist"))
    }

    @Test("a malware verdict is the one a block reports, so it can't hide behind an overridable alert")
    func malwareWins() {
        let scripts = SocketDevClient.Issue(type: "installScripts", severity: .high, summary: "install scripts")
        let malware = SocketDevClient.Issue(type: "malware", severity: .critical, summary: "known malware")
        #expect(SocketDevClient.blockingIssue([scripts, malware])?.type == "malware")
        #expect(SocketDevClient.blockingIssue([scripts])?.type == "installScripts")
        #expect(SocketDevClient.isMalwareVerdict("malware") && !SocketDevClient.isMalwareVerdict("installScripts"))
    }

    @Test("the answers: allow for the session, always (the list), refuse for the session, or not now (a minute)")
    func answers() async {
        let b = SupplyChainConsentBroker()
        let pid = UUID(), now = Date()
        func key(_ name: String) -> String {
            SupplyChainConsentBroker.storeKey(profileID: pid,
                                             scope: SupplyChainConsentBroker.overrideScope(ecosystem: "npm", name: name))
        }
        #expect(await b.recordOverride(.allowSession, key: key("a"), label: "a", now: now))
        #expect(await b.recordOverride(.allowAlways, key: key("b"), label: "b", now: now))
        #expect(!(await b.recordOverride(.denySession, key: key("c"), label: "c", now: now)))
        #expect(!(await b.recordOverride(.notNow, key: key("d"), label: "d", now: now)))
        let later = now.addingTimeInterval(3600)
        #expect(await b.decided(key("a"), now: later) == true)
        // "Always" is the workspace's list: the broker only bridges until the
        // saved entry is live, so removing it from the list stops it.
        #expect(await b.decided(key("b"), now: now.addingTimeInterval(5)) == true)
        #expect(await b.decided(key("b"), now: later) == nil)
        #expect(await b.decided(key("c"), now: later) == false)          // stays quiet all session
        #expect(await b.decided(key("d"), now: now.addingTimeInterval(5)) == false)
        #expect(await b.decided(key("d"), now: later) == nil)            // asked again later
        // Per package, whatever the version, and case-insensitive.
        #expect(SupplyChainConsentBroker.overrideScope(ecosystem: "npm", name: "WorkerD")
                == SupplyChainConsentBroker.overrideScope(ecosystem: "npm", name: "workerd"))
    }

    @Test("the timeline row: an overridable block carries its package; an override reads as allowed by you")
    func timelineRows() throws {
        let pid = UUID()
        func map(_ d: [String: AnyJSON]) throws -> SecurityTimeline.Event {
            try #require(SecurityTimeline.map(profileID: pid, eventType: "supply_chain.fetch", eventData: d, now: Date()))
        }
        let base: [String: AnyJSON] = ["ecosystem": .string("npm"), "package": .string("workerd"),
                                       "version": .string("1.20261012.1"), "kind": .string("artifact"),
                                       "reason_kind": .string("socket_compromised"),
                                       "reason": .string("flagged by socket.dev (high): installScripts")]
        var blocked = base; blocked["outcome"] = .string("blocked"); blocked["overridable"] = .bool(true)
        let row = try map(blocked)
        #expect(row.kind == .blocked && row.package?.allowlistEntry == "npm:workerd")
        // It survives the daily log and the fat-client mirror.
        let line = try #require(SecurityTimeline.line(row))
        #expect(SecurityTimeline.event(fromLine: line.dropLast())?.package?.allowlistEntry == "npm:workerd")
        // Malware (not overridable): no action.
        var malware = base; malware["outcome"] = .string("blocked")
        #expect(try map(malware).package == nil)
        var overridden = base; overridden["outcome"] = .string("overridden")
        let o = try map(overridden)
        #expect(o.kind == .info && o.decision.contains("allowed by you") && o.package == nil)
    }

    @Test("the row's action knows when the package is allowed since")
    @MainActor func rowContext() throws {
        var p = bromure_ac.Profile(name: "ws", tool: .claude, authMode: .token)
        var e = try #require(SecurityTimeline.map(profileID: p.id, eventType: "supply_chain.fetch", eventData: [
            "ecosystem": .string("npm"), "package": .string("workerd"), "kind": .string("artifact"),
            "outcome": .string("blocked"), "overridable": .bool(true), "reason": .string("x")], now: Date()))
        let ctx = try #require(SupplyChainRowContext(e, profiles: [p]))
        #expect(!ctx.allowedNow && ctx.allowTitle.contains("workerd"))
        p.supplyChain.reputationAllowlist = ["npm:workerd"]
        #expect(try #require(SupplyChainRowContext(e, profiles: [p])).allowedNow)
        e.machine = "ark"
        #expect(try #require(SupplyChainRowContext(e, profiles: [p])).isRemote)
    }
}
