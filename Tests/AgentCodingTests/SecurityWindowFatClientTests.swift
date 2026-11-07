import Foundation
import Testing
@testable import bromure_ac

/// Board report: with a fat client's window in front, Window ▸ Security…
/// showed this Mac's security data, not the host's. And the Credential
/// brokering tile stayed at 0: token swaps were only recorded while tracing
/// was on (off by default), and a client certificate the proxy presents
/// (kubectl against a client-cert kubeconfig) was never recorded at all.
@Suite("The Security window: a fat client's host, and every brokered credential")
struct SecurityWindowFatClientTests {
    private static let top = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.top.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the window opens on the front window's machine")
    func scopeFollowsTheFrontWindow() throws {
        typealias S = SecurityWindowScope
        // A fat client's window in front: that host.
        #expect(S.machine(frontHost: "Mac Studio", mirroredHosts: true) == "Mac Studio")
        #expect(S.machine(frontHost: "Mac Studio", mirroredHosts: false) == "Mac Studio")
        // One of this Mac's: this Mac, told apart only when hosts are mirrored.
        #expect(S.machine(frontHost: nil, mirroredHosts: true) == "")
        #expect(S.machine(frontHost: nil, mirroredHosts: false) == nil)

        let app = try source("Sources/AgentCoding/BromureAC.swift")
        let open = try #require(app.range(of: "@objc func openSecurityTimelineAction(_ sender: Any?) {"))
        let body = app[open.upperBound...].prefix(4000)
        #expect(body.contains("(front as? RemoteHostWindow)?.controller.securityMirrorKey"))
        // Asked from the Security window itself, it keeps what it shows.
        #expect(body.contains("if front?.identifier != id {"))
        #expect(body.contains("scope: securityWindowScope,"))
        // The mirror's bucket and the scope use the same key.
        let fc = try source("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("SecurityTimeline.shared.applyMirror(rows, host: securityMirrorKey)"))
    }

    @MainActor
    @Test("the Overview counts the machine shown, and so do its postures")
    func overviewFollowsTheMachine() throws {
        func ev(_ machine: String?) -> SecurityTimeline.Event {
            var e = SecurityTimeline.Event(time: Date(), engine: "Firewall", condition: "c", decision: "d",
                                           kind: .blocked, profileID: UUID())
            e.machine = machine
            return e
        }
        let all = [ev(nil), ev("Mac Studio"), ev("Mac Studio"), ev("Mini")]
        #expect(SecurityOverview.events(all, machine: nil).count == 4)
        #expect(SecurityOverview.events(all, machine: "").count == 1)
        #expect(SecurityOverview.events(all, machine: "Mac Studio").count == 2)
        let view = try source("Sources/AgentCoding/SecurityTimelineView.swift")
        #expect(view.contains("SecurityOverview(timeline: timeline, postures: postures(machineFilter),\n                                 machine: machineFilter,"))
        #expect(view.contains(".onChange(of: scope.generation) { _, _ in\n            machineFilter = scope.machine"))
    }

    @Test("token swaps are recorded whatever the trace level")
    func swapsBeforeTheTraceGate() throws {
        var emitted: [(UUID, String, [String: AnyJSON])] = []
        let pid = UUID()
        HTTPMitmConnection.emitSwapEvents(
            [SwapRecord(fakePreview: "brm_a1…c3", realPreview: "sk-…9f", host: "kube.example")],
            host: "kube.example:6443", path: "/api/v1/pods", profileID: pid) { emitted.append(($0, $1, $2)) }
        #expect(emitted.count == 1)
        #expect(emitted.first?.0 == pid && emitted.first?.1 == "credential.token_swap")
        HTTPMitmConnection.emitSwapEvents([], host: "h", path: "/", profileID: pid) { emitted.append(($0, $1, $2)) }
        #expect(emitted.count == 1)

        let proxy = try source("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        for fn in ["    private func emitTrace(host: String, port: Int,", "    private func emitWebSocketTrace(host: String, port: Int,"] {
            let start = try #require(proxy.range(of: fn), "\(fn)")
            let body = proxy[start.upperBound...].prefix(1400)
            let swaps = try #require(body.range(of: "Self.emitSwapEvents(swaps,"), "\(fn)")
            let gate = try #require(body.range(of: "session.level.recordsActivity else { return }"), "\(fn)")
            #expect(swaps.lowerBound < gate.lowerBound, "\(fn): swaps go out before the trace gate")
        }
        // Nowhere else: one event per swap.
        #expect(proxy.components(separatedBy: "eventType: \"credential.token_swap\"").count - 1 == 0)
        #expect(proxy.components(separatedBy: "Self.emitSwapEvents(swaps,").count - 1 == 2)
    }

    @Test("a client certificate the proxy presents is credential brokering")
    func clientCertIsBrokering() throws {
        let e = try #require(SecurityTimeline.map(
            profileID: UUID(), eventType: "credential.client_cert",
            eventData: ["host": .string("10.0.0.5:6443"), "identity": .string("kubernetes-admin")], now: Date()))
        #expect(e.engine == NSLocalizedString("Credential brokering", comment: "Security Timeline engine"))
        #expect(e.condition == "kubernetes-admin → 10.0.0.5:6443")
        #expect(e.kind == .info)
        #expect(e.coalesceKey == "client_cert|kubernetes-admin|10.0.0.5:6443")

        // Emitted where the real identity is presented: the request path's
        // challenge handler (both the gated and the ungated branch) and the
        // upgrade path (kubectl exec / logs -f).
        let proxy = try source("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        #expect(proxy.components(separatedBy: "HTTPMitmConnection.emitClientCertEvent(entry,").count - 1 == 2)
        #expect(proxy.contains("Self.emitClientCertEvent(entry, host: host, port: port, profileID: profileID)"))
    }

    /// Finding: the Overview counts one machine's events over its range, but
    /// its CSV export saved every machine's -- viewing one host, the file
    /// carried this Mac's and other hosts' activity too.
    @Test("the Overview's export saves what it shows: its machine, its range")
    func overviewExportScoped() throws {
        let now = Date()
        func ev(_ machine: String?, hoursAgo: Double) -> SecurityTimeline.Event {
            var e = SecurityTimeline.Event(time: now.addingTimeInterval(-hoursAgo * 3600), engine: "Firewall",
                                           condition: "c", decision: "d", kind: .blocked, profileID: UUID())
            e.machine = machine
            return e
        }
        let all = [ev(nil, hoursAgo: 1), ev("Mac Studio", hoursAgo: 1), ev("Mac Studio", hoursAgo: 30), ev("Mini", hoursAgo: 2)]
        let shown = SecurityOverview.shown(all, machine: "Mac Studio", rangeHours: 24, now: now)
        #expect(shown.count == 1 && shown.allSatisfy { $0.machine == "Mac Studio" })
        #expect(SecurityOverview.shown(all, machine: "Mac Studio", rangeHours: 0, now: now).count == 2)
        #expect(SecurityOverview.shown(all, machine: "", rangeHours: 24, now: now).count == 1)
        #expect(SecurityOverview.shown(all, machine: nil, rangeHours: 24, now: now).count == 3)
        let view = try source("Sources/AgentCoding/SecurityTimelineView.swift")
        #expect(view.contains("SecurityOverview.shown(timeline.allEvents, machine: machineFilter,"))
        #expect(!view.contains("for e in (tab == .timeline ? rows.reversed() : timeline.allEvents) {"))
    }
}
