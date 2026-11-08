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
        #expect(fc.contains("SecurityTimeline.shared.applyMirror(\n                rows, host: securityMirrorKey,"))
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

    /// Finding: the Overview lists a host's workspaces, but a protection
    /// cell opened only this Mac's editor, looked up among this Mac's
    /// profiles -- a host's cell did nothing (or, with a matching id, opened
    /// the wrong machine's). A posture names its machine; the cell opens it.
    @Test("a protection cell opens its own machine's editor, never a host id looked up here")
    func cellOpensItsMachine() throws {
        typealias L = SecurityEditorLauncher
        let mine = UUID(), theirs = UUID(), studio = UUID(), gone = UUID()
        #expect(L.route(profileID: mine, hostID: nil, localProfiles: [mine], connectedHosts: [studio]) == .local)
        #expect(L.route(profileID: theirs, hostID: studio, localProfiles: [mine], connectedHosts: [studio])
                == .host(studio))
        // A host id that happens to match a local one still goes to the host.
        #expect(L.route(profileID: mine, hostID: studio, localProfiles: [mine], connectedHosts: [studio])
                == .host(studio))
        // Neither known here, nor a connected host: nowhere.
        #expect(L.route(profileID: theirs, hostID: nil, localProfiles: [mine], connectedHosts: []) == nil)
        #expect(L.route(profileID: theirs, hostID: gone, localProfiles: [mine], connectedHosts: [studio]) == nil)

        let app = try source("Sources/AgentCoding/BromureAC.swift")
        #expect(app.contains("c.profiles.map { var s = SecurityPosture(profile: $0); s.machine = c.securityMirrorKey; s.hostID = c.host.id; return s }"))
        let view = try source("Sources/AgentCoding/SecurityTimelineView.swift")
        #expect(view.contains("SecurityEditorLauncher.open(profileID: p.id, hostID: p.hostID, category: Self.columnCategories[i])"))
        #expect(view.contains("hosts.first { $0.controller.host.id == id }?.openWorkspaceSettings(profileID, category: category)"))
        let fc = try source("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("func openWorkspaceSettings(_ id: Profile.ID, category: EditorCategory) {"))
        #expect(fc.contains("openWorkspaceSettings(id, initialCategory: category)"))
        // An open host editor is switched to the pane, as this Mac's is.
        #expect(fc.contains(#"object: "workspace:\(id.uuidString.lowercased()):\(category.rawValue.lowercased())")"#))
    }

    /// Finding: on the WebSocket upgrade (kubectl exec / logs -f) the
    /// client-certificate event was recorded as soon as the identity was
    /// looked up -- before the destination check, the connect and the
    /// handshake -- so a refused or failed upgrade, or a server that asked
    /// for no certificate, still counted as credential brokering.
    @Test("a WebSocket upgrade records the certificate only once the upstream asked for it and got it")
    func wsClientCertAfterHandshake() throws {
        // Only a sent certificate was presented.
        #expect(TLSClientStream.presented(.certSent))
        #expect(!TLSClientStream.presented(.certRequested))
        #expect(!TLSClientStream.presented(.certNone))
        #expect(!TLSClientStream.presented(.certRejected))
        let proxy = try source("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        let emit = try #require(proxy.range(of: "Self.emitClientCertEvent(entry, host: host, port: port, profileID: profileID)"))
        let handshake = try #require(proxy.range(of: "try upstreamTLS.handshake()"))
        let gate = try #require(proxy.range(of: "if let entry = identityEntry, (upstreamTLS as? TLSClientStream)?.clientCertificateSent == true {"))
        #expect(handshake.lowerBound < gate.lowerBound && gate.lowerBound < emit.lowerBound)
        #expect(proxy.components(separatedBy: "Self.emitClientCertEvent(entry, host: host, port: port, profileID: profileID)").count - 1 == 1)
    }


    /// Finding: "Remote protection cells lose their requested pane while the
    /// editor loads". A host's editor is made after three fetches; its pane
    /// waited in one shared slot that the next cell clicked (or a local
    /// editor) overwrote meanwhile, and it opened on General. The pane now
    /// goes with the request, into the editor it makes.
    @Test("a host's editor opens on the pane its own request asked for")
    func paneTravelsWithTheRequest() throws {
        let a = UUID(), b = UUID()
        typealias V = ProfileEditorView
        // Asked for with the editor: wins, whatever the shared slot says.
        #expect(V.openingCategory(requested: .firewall, pending: (b, .guardrails), profileID: a) == .firewall)
        #expect(V.openingCategory(requested: .firewall, pending: (a, .guardrails), profileID: a) == .firewall)
        // Nothing asked: the slot, only for this workspace.
        #expect(V.openingCategory(requested: nil, pending: (a, .guardrails), profileID: a) == .guardrails)
        #expect(V.openingCategory(requested: nil, pending: (b, .guardrails), profileID: a) == nil)
        #expect(V.openingCategory(requested: nil, pending: nil, profileID: a) == nil)

        let fc = try source("Sources/AgentCoding/FatClientController.swift")
        // The fat client never uses the shared slot: the pane rides the fetch.
        #expect(!fc.contains("pendingWorkspaceCategory"))
        #expect(fc.contains("private func openWorkspaceSettings(_ id: Profile.ID, initialCategory: EditorCategory? = nil) {"))
        // The latest click's pane, whichever fetch finishes last.
        #expect(fc.contains("if let initialCategory { settingsRequestedPane[id] = initialCategory }"))
        #expect(fc.contains("let pane = self.settingsRequestedPane.removeValue(forKey: id) ?? initialCategory"))
        #expect(fc.contains("initialCategory: pane)"))
        // An editor another request made meanwhile already took this pane
        // (asked before it was built): brought forward, not switched back.
        #expect(fc.contains("if let win = self.settingsSessions[id]?.window { win.makeKeyAndOrderFront(nil); return }"))
        #expect(fc.contains("self?.openWorkspaceSettings(id, category: .firewall)"))
        // This Mac's drawer: one call that also switches an open editor.
        let win = try source("Sources/AgentCoding/UnifiedSessionWindow.swift")
        #expect(win.contains("d.openEditorWindow(editing: p, category: .firewall)"))
        #expect(!win.contains("pendingWorkspaceCategory"))
    }

    /// Finding: "Protection cell can open a different host's workspace editor
    /// when host labels match". Hosts are unique by id only; the key was the
    /// name, so two hosts named alike shared a timeline bucket and a filter,
    /// and a cell opened the first one's editor (a cloned workspace: the
    /// wrong machine's settings saved). Cells route by the host's id, and
    /// the key is unique.
    @Test("two hosts with one name: each keeps its own key, and a cell routes by host id")
    func sameNamedHosts() {
        let a = RemoteHost(name: "studio", address: "10.0.0.2", user: "u")
        var b = RemoteHost(name: "studio", address: "10.0.0.3", user: "u")
        let other = RemoteHost(name: "mini", address: "10.0.0.9", user: "u")
        // The bucket and filter key is the host's id (pinned in
        // hostKeysNeverCollide): never two hosts' one.
        // What the window calls them: unique.
        let labels = SecurityTimeline.machineLabels([a, b, other])
        #expect(labels[a.id] == "studio (10.0.0.2:2222)" && labels[b.id] == "studio (10.0.0.3:2222)")
        #expect(labels[other.id] == "mini")
        #expect(SecurityTimeline.machineLabels([a])[a.id] == "studio")
        // Two records of one machine (same address and port): the id tells them apart.
        b.address = a.address
        let same = SecurityTimeline.machineLabels([a, b])
        #expect(same[a.id] != same[b.id] && same[a.id]?.hasPrefix("studio (10.0.0.2:2222) · ") == true)
        b.address = "10.0.0.3"
        // Routing never goes by the label: b's cell opens b, whatever a is called.
        let ws = UUID()
        #expect(SecurityEditorLauncher.route(profileID: ws, hostID: b.id, localProfiles: [],
                                             connectedHosts: [a.id, b.id]) == .host(b.id))
    }


    /// Finding: "Security timeline host keys can still collide across
    /// distinct hosts". The key was a display string made unique among the
    /// saved hosts only: a third host named like another's addressed label
    /// (or an unsaved peer with the same name) got the same key, and its rows
    /// overwrote the other's. The key is the host's id; labels are made
    /// unique among every host the window has rows from.
    @Test("hosts never share a bucket, and their labels never match, peers included")
    @MainActor func hostKeysNeverCollide() {
        let a = RemoteHost(name: "studio", address: "10.0.0.2", user: "u")
        let b = RemoteHost(name: "studio", address: "10.0.0.3", user: "u")
        let c = RemoteHost(name: "studio (10.0.0.2:2222)", address: "10.0.0.4", user: "u")
        let peer = RemoteHost(name: "studio", address: "fe80::1", user: "u")   // a peer: never saved
        let all = [a, b, c, peer]
        let labels = SecurityTimeline.machineLabels(all)
        #expect(Set(labels.values).count == all.count, "\(labels)")

        // Through the timeline: each host's rows in its own bucket, each named.
        let tl = SecurityTimeline(directory: nil)
        func row(_ cond: String) -> [String: Any] {
            ["engine": "Firewall", "condition": cond, "decision": "d", "kind": "blocked",
             "t": Date().timeIntervalSince1970, "profileID": UUID().uuidString]
        }
        for h in all {
            let key = h.id.uuidString   // `securityMirrorKey`
            tl.noteMachine(key, host: h)
            tl.applyMirror([row("from \(h.address)")], host: key)
        }
        #expect(tl.remote.count == all.count)
        for h in all { #expect(tl.remote[h.id.uuidString]?.first?.condition == "from \(h.address)") }
        #expect(Set(all.map { tl.machineLabel($0.id.uuidString) }).count == all.count)
        #expect(tl.machineLabel(nil) == "This Mac")

        // The window shows labels, never the key.
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = (try? String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/SecurityTimelineView.swift"), encoding: .utf8)) ?? ""
        #expect(view.contains("Text(timeline.machineLabel($0)).tag(String?.some($0))"))
        #expect(view.contains("\\(timeline.machineLabel(e.machine)) · "))
        #expect(!view.contains("ForEach(machines, id: \\.self) { Text($0)"))
        let fc = (try? String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)) ?? ""
        #expect(fc.contains("var securityMirrorKey: String { host.id.uuidString }"))
        #expect(fc.contains("SecurityTimeline.shared.noteMachine(securityMirrorKey, host: host)"))
    }


    /// Finding: "Changing the saved host list leaves duplicate and stale
    /// security timeline buckets". The key was computed from the saved
    /// hosts at each snapshot: saving a second "studio" moved host A's rows
    /// to a new key and left the old bucket behind (every row counted
    /// twice, a stale machine in the filter); a rename or a removal did the
    /// same. The key is the host's id, which none of that changes; only
    /// the label follows.
    @Test("saving, renaming or removing hosts never moves a host's bucket")
    @MainActor func savedHostsChangeKeepsBuckets() {
        var a = RemoteHost(name: "studio", address: "10.0.0.2", user: "u")
        let b = RemoteHost(name: "studio", address: "10.0.0.3", user: "u")
        let tl = SecurityTimeline(directory: nil)
        func row(_ cond: String) -> [String: Any] {
            ["engine": "Firewall", "condition": cond, "decision": "d", "kind": "blocked",
             "t": Date().timeIntervalSince1970, "profileID": UUID().uuidString]
        }
        func snapshot(_ h: RemoteHost, _ rows: [[String: Any]]) {
            let key = h.id.uuidString            // `securityMirrorKey`
            tl.noteMachine(key, host: h)
            tl.applyMirror(rows, host: key)
        }
        snapshot(a, [row("a1")])
        #expect(tl.machineLabel(a.id.uuidString) == "studio")
        // Another "studio" is saved and mirrored: A keeps its one bucket.
        snapshot(b, [row("b1")])
        snapshot(a, [row("a1"), row("a2")])
        #expect(tl.remote.keys.sorted() == [a.id.uuidString, b.id.uuidString].sorted())
        #expect(tl.allEvents.count == 3)                    // a1, a2, b1: none twice
        #expect(tl.machineLabel(a.id.uuidString) == "studio (10.0.0.2:2222)")
        // A renamed: same bucket, new label.
        a.name = "rack"
        snapshot(a, [row("a1"), row("a2")])
        #expect(tl.remote.count == 2 && tl.allEvents.count == 3)
        #expect(tl.machineLabel(a.id.uuidString) == "rack" && tl.machineLabel(b.id.uuidString) == "studio")
    }
}
