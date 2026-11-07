import AppKit
import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// Board report: the Sandbox drawer (the toolbar's shield: OpenShell's
/// blocks, file denials and the advisor's proposals) showed only in this
/// Mac's own window, never in a fat client's. The drawer now reads and
/// decides through a backend: this Mac's, or the host's over its control
/// socket, where every decision is made.
@Suite("The Sandbox drawer in a fat client: the host's blocks and proposals")
struct FatClientPolicyDrawerTests {
    private static let top = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func src(_ p: String) throws -> String {
        try String(contentsOf: Self.top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("the host's routes for the drawer's one-click decisions validate, decide and say why not")
    func decisionRoute() {
        let pid = UUID()
        typealias A = ACAppDelegate
        let allowOK: @Sendable (UUID, String, Int, String?) async -> String? = { _, _, _, _ in nil }
        let allowNo: @Sendable (UUID, String, Int, String?) async -> String? = { _, _, _, _ in "Enforce binaries is on" }
        var added: [(String, Bool)] = []
        let add: (UUID, String, Bool) -> String? = { _, p, rw in added.append((p, rw)); return nil }

        #expect(A.sandboxDecisionRoute(profileID: pid, "openshell-allow", body: ["host": "api.example.com", "port": 443],
                                       allow: allowOK, addPath: add).status == 200)
        let refused = A.sandboxDecisionRoute(profileID: pid, "openshell-allow",
                                             body: ["host": "api.example.com", "port": 443, "exe": "/usr/bin/curl"],
                                             allow: allowNo, addPath: add)
        #expect(refused.status == 409 && refused.body["error"] as? String == "Enforce binaries is on")
        #expect(A.sandboxDecisionRoute(profileID: pid, "openshell-allow", body: ["host": "", "port": 443],
                                       allow: allowOK, addPath: add).status == 400)
        #expect(A.sandboxDecisionRoute(profileID: pid, "openshell-allow", body: ["host": "h", "port": 0],
                                       allow: allowOK, addPath: add).status == 400)

        #expect(A.sandboxDecisionRoute(profileID: pid, "sandbox-path", body: ["path": "/opt/tool", "readWrite": true],
                                       allow: allowOK, addPath: add).status == 200)
        #expect(added.count == 1 && added[0].0 == "/opt/tool" && added[0].1)
        #expect(A.sandboxDecisionRoute(profileID: pid, "sandbox-path", body: ["path": "relative/x"],
                                       allow: allowOK, addPath: add).status == 400)
        #expect(A.sandboxDecisionRoute(profileID: pid, "sandbox-path", body: ["path": "/a\nb"],
                                       allow: allowOK, addPath: add).status == 400)
        #expect(added.count == 1)
        #expect(A.sandboxDecisionRoute(profileID: pid, "nope", body: [:], allow: allowOK, addPath: add).status == 404)
    }

    @Test("the host's proposals and package requests decode as the drawer shows them")
    func wire() throws {
        let p = try #require(DrawerProposal(wire: [
            "id": "p-3", "status": "pending", "source": "agent_authored", "intent": "fetch the docs",
            "host": "docs.example.com", "port": 443, "binaries": ["/usr/bin/curl"], "findings": ["new_host"]]))
        #expect(p.host == "docs.example.com" && p.port == 443 && p.status == .pending && p.binaries == ["/usr/bin/curl"])
        #expect(DrawerProposal(wire: ["id": "p-4", "status": "bogus"]) == nil)
        let r = try #require(DrawerPackage(wire: ["id": "pkg-1", "status": "failed", "packages": ["jq"],
                                                  "exit_code": 100, "output": "E: Unable to locate package"]))
        #expect(r.status == .failed && r.exitCode == 100 && r.packages == ["jq"])
    }

    @Test("a host's answer: ok, refused with its reason, or no answer")
    func failures() {
        typealias B = RemotePolicyDrawerBackend
        #expect(B.failure(ControlClient.Response(status: 200, json: ["ok": true])) == nil)
        #expect(B.failure(ControlClient.Response(status: 409, json: ["error": "nope"])) == "nope")
        #expect(B.failure(ControlClient.Response(status: 500, json: [:]))?.contains("500") == true)
        #expect(B.failure(nil) != nil)
    }

    @Test("the host's full profile decodes (ISO 8601 dates, bare or under \"profile\")")
    func profileDecodes() throws {
        var p = Profile(id: UUID(), name: "Storefront", tool: .claude, authMode: .token)
        p.egressRules = "deny web any POST"
        p.networkPolicy = "version: 1\n"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let doc = try #require(try JSONSerialization.jsonObject(with: enc.encode(p)) as? [String: Any])
        #expect(RemotePolicyDrawerBackend.decodeProfile(doc)?.egressRules == "deny web any POST")
        #expect(RemotePolicyDrawerBackend.decodeProfile(["profile": doc])?.networkPolicy == "version: 1\n")
    }

    @Test("wired: the fat client's toolbar and window, the host's routes, a drawer with no local reach")
    func wired() throws {
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("PolicyDrawerButton(list: model, profileID: entry.id, machine: controller.securityMirrorKey)"))
        #expect(fc.contains("onTogglePolicyDrawer: { [weak self] in self?.togglePolicyDrawer() },"))
        #expect(fc.contains("backend: policyBackend)"))
        let server = try src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains(#"case "openshell-allow", "sandbox-path": handler = onProfileSandboxDecision"#))
        // The drawer itself reaches nothing of this Mac's but through its backend.
        let drawer = try src("Sources/AgentCoding/PolicyDrawer.swift")
        let body = try #require(drawer.components(separatedBy: "\nextension ACAppDelegate").first)
        #expect(!body.contains("OpenShellAdvisor.shared."))
        #expect(!body.contains("delegate?."))
        #expect(body.contains("e.machine == backend.machine"))
    }

    /// Review: the Blocked tab and the shield's badge took only this Mac's
    /// events, so a fat client's showed nothing of the host's.
    @MainActor
    @Test("blocks and the badge count the machine the drawer is for")
    func blocksPerMachine() {
        let pid = UUID()
        func block(_ machine: String?, host: String) -> SecurityTimeline.Event {
            var e = SecurityTimeline.Event(time: Date(), engine: "Firewall", condition: "c", decision: "d",
                                           kind: .blocked, profileID: pid, machine: machine)
            e.firewall = SecurityTimeline.Firewall(wire: ["host": host, "port": 443, "denied": true, "byPolicy": true])
            return e
        }
        let events = [block(nil, host: "local.test"), block("Mac Studio", host: "host.test")]
        let since = Date().addingTimeInterval(-60)
        #expect(PolicyDrawer.blockedRows(events, profileID: pid, since: since).map(\.host) == ["local.test"])
        #expect(PolicyDrawer.blockedRows(events, profileID: pid, since: since, machine: "Mac Studio").map(\.host) == ["host.test"])
        let fc = (try? src("Sources/AgentCoding/FatClientController.swift")) ?? ""
        #expect(fc.contains("PolicyDrawerButton(list: model, profileID: entry.id, machine: controller.securityMirrorKey)"))
        let drawer = (try? src("Sources/AgentCoding/PolicyDrawer.swift")) ?? ""
        #expect(drawer.contains("e.profileID == profileID, e.machine == machine, let fw = e.firewall"))
        #expect(drawer.contains("machine: backend.machine)"))
    }

    /// Review: the path went into the policy's YAML raw -- a comma split it
    /// into two list items, `#` started a comment. The drawer's route is a
    /// second writer of that helper.
    @Test("a path with YAML-significant characters reads back as itself")
    func yamlPaths() throws {
        let base = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\n  read_write: [/tmp]\n"
        for path in ["/opt/a,b", "/data/#notes", "/srv/x: y", "/opt/plain-tool"] {
            let out = try OpenShellPolicy.addingFilesystemPath(path, readWrite: false, to: base)
            let fs = try #require(try OpenShellPolicy.parse(out).filesystem)
            #expect(fs.readOnly.contains(path), "\(path) → \(fs.readOnly)")
            #expect(fs.readOnly.contains("/usr"))
        }
        #expect(try OpenShellPolicy.addingFilesystemPath("/opt/plain-tool", readWrite: false, to: base)
            .contains("[/usr, /opt/plain-tool]"))
        // A block list too.
        let block = "version: 1\nfilesystem_policy:\n  read_write:\n    - /tmp\n"
        let out = try OpenShellPolicy.addingFilesystemPath("/home/u/a,b", readWrite: true, to: block)
        #expect(try #require(try OpenShellPolicy.parse(out).filesystem).readWrite.contains("/home/u/a,b"))
    }

    /// User report: in a fat client, clicking the shield showed nothing. The
    /// window's mount, run on every stage refresh, removed every subview of
    /// the stage but the one it mounted, the drawer included; the window
    /// kept toggling a view no longer in it.
    @Test("a stage mount keeps the drawer on the stage, and on top")
    @MainActor func mountKeepsDrawer() throws {
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let old = NSView(), drawer = NSView(), next = NSView(), cue = NSView()
        for v in [old, next] { v.translatesAutoresizingMaskIntoConstraints = false }
        stage.addSubview(old)
        stage.addSubview(drawer, positioned: .above, relativeTo: nil)
        RemoteHostWindow.mount(next, on: stage, keeping: drawer)
        #expect(stage.subviews == [next, drawer])
        #expect(old.superview == nil)
        // The boot cue rides over the terminal, under the drawer.
        RemoteHostWindow.addBelow(drawer, cue, on: stage)
        #expect(stage.subviews.last === drawer)
        // No drawer yet: as before.
        let bare = NSView()
        RemoteHostWindow.mount(old, on: bare, keeping: nil)
        #expect(bare.subviews == [old])
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("for v in stage.subviews where v !== policyDrawerHost { v.isHidden = !contentShown }"))
        #expect(!fc.contains("stage.addSubview(host)   // last subview = topmost"))
    }
    /// User report: the shield showed on workspaces with no sandbox, where
    /// the drawer has nothing to say. Hidden there, here and in a fat client
    /// (the host says which run sandboxed; an older host, unknown, keeps it).
    @Test("no shield, and no drawer, for a workspace without a sandbox")
    @MainActor func shieldOnlyWhenSandboxed() throws {
        let list = SessionListModel()
        let plain = UUID(), boxed = UUID()
        list.unsandboxedProfileIDs = [plain]
        #expect(!list.hasSandboxDrawer(plain))
        #expect(list.hasSandboxDrawer(boxed))
        #expect(!list.hasSandboxDrawer(nil))
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        #expect(ac.contains("\"sandboxed\": p.restrictsEgress,"))
        #expect(ac.contains("profiles.filter { !$0.restrictsEgress }"))
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("if (w[\"sandboxed\"] as? Bool) == false { unsandboxed.insert(id) }"))
        #expect(fc.contains("guard list.policyDrawerOpen || list.hasSandboxDrawer(list.stageProfileID) else { return }"))
        let win = try src("Sources/AgentCoding/UnifiedSessionWindow.swift")
        #expect(win.contains("guard listModel.policyDrawerOpen || listModel.hasSandboxDrawer(listModel.stageProfileID) else { return }"))
        let drawer = try src("Sources/AgentCoding/PolicyDrawer.swift")
        #expect(drawer.contains("if list.hasSandboxDrawer(profileID) { button }"))
        #expect(drawer.contains(".onChange(of: list.unsandboxedProfileIDs) { _, _ in closeIfUnsandboxed() }"))
    }


    /// Finding: "Sandbox shield disappears for workspaces using the Bromure
    /// Firewall". The shield was hidden for every workspace without an
    /// OpenShell policy -- but the Bromure Firewall blocks too, and the
    /// drawer shows and allows its blocks; so does a workspace under the
    /// organization boundary's policy. Only a workspace nothing restricts
    /// has no shield.
    @Test("the shield is there whenever something restricts the workspace's traffic")
    @MainActor func shieldForAnyRestriction() {
        func profile(_ rules: String = "", policy: String = "") -> bromure_ac.Profile {
            var p = bromure_ac.Profile(name: "ws", tool: .claude, authMode: .token)
            p.egressRules = rules
            p.networkPolicy = policy
            return p
        }
        #expect(profile(policy: "version: 1\nnetwork_policies: {}\n").restrictsEgress)
        #expect(profile("allow web github.com\ndefault deny").restrictsEgress)     // the Bromure Firewall
        #expect(profile("deny tcp 203.0.113.9:443").restrictsEgress)
        #expect(!profile().restrictsEgress)                                          // nothing at all
        #expect(!profile("default allow").restrictsEgress)                           // rules that restrict nothing
        #expect(!profile("this is not a ruleset ((").restrictsEgress)                // never blocks (allow-all)
        // The Overview's Firewall column says the same.
        #expect(SecurityPosture(profile: profile("allow web github.com\ndefault deny")).firewall)
        #expect(!SecurityPosture(profile: profile()).firewall)
    }
}
