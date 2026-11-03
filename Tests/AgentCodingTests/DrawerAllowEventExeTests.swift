import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

/// Finding (CWE-284): "Drawer Allow grants a later denied program, not the
/// block the row lists". Allow looked the program up when clicked, in a map
/// every later deny overwrote -- including a deny the 60 s report dedupe
/// kept off the drawer, and a deny for a sibling DNS name of the same IP --
/// so the rule named a program the row never showed. The program now rides
/// on the deny's own event, a deny for another program is its own report and
/// row, and Allow grants the row's event.
@Suite("Sandbox drawer: Allow grants the block the row lists")
struct DrawerAllowEventExeTests {
    private static func deny(_ pid: UUID, host: String, exe: String?, at t: Date) -> SecurityTimeline.Event? {
        var d: [String: AnyJSON] = ["action": .string("deny"), "layer": .string("l4"), "proto": .string("tcp"),
                                    "host": .string(host), "ip": .string("104.16.0.9"), "port": .int(9443),
                                    "by_policy": .bool(true)]
        if let exe { d["exe"] = .string(exe) }
        return SecurityTimeline.map(profileID: pid, eventType: "egress.firewall", eventData: d, now: t)
    }

    @Test("Each row's Allow names the program on its own event, whatever was denied there since")
    func rowsCarryTheirProgram() throws {
        let pid = UUID(), t0 = Date()
        let tool = try #require(Self.deny(pid, host: "api.example", exe: "/usr/bin/tool", at: t0))
        #expect(tool.firewall?.exe == "/usr/bin/tool")
        // The live identity state now points elsewhere (a later denied dial
        // to the IP, and to a sibling name): no row follows it.
        BinaryIdentityService.shared.noteExe("/tmp/curl", profileID: pid, destinations: ["api.example", "104.16.0.9"], port: 9443)
        let sibling = try #require(Self.deny(pid, host: "cdn.example", exe: "/tmp/curl", at: t0.addingTimeInterval(1)))
        let rows = PolicyDrawer.blockedRows([tool, sibling], profileID: pid, since: t0.addingTimeInterval(-60))
        let api = try #require(rows.first { $0.host == "api.example" })
        #expect(api.fw.exe == "/usr/bin/tool")
        #expect(OpenShellAdvisor.allowRule(host: api.host, port: api.port, exe: api.fw.exe).binaries == ["/usr/bin/tool"])
        #expect(rows.first { $0.host == "cdn.example" }?.fw.exe == "/tmp/curl")

        // Another program denied to the SAME host and port is a row of its
        // own: it never takes over the listed one.
        let later = try #require(Self.deny(pid, host: "api.example", exe: "/tmp/curl", at: t0.addingTimeInterval(2)))
        let rows2 = PolicyDrawer.blockedRows([tool, later], profileID: pid, since: t0.addingTimeInterval(-60))
        #expect(rows2.filter { $0.host == "api.example" }.count == 2)
        #expect(Set(rows2.compactMap(\.fw.exe)) == ["/usr/bin/tool", "/tmp/curl"])
        // A repeat of the same program still folds into its row.
        let again = try #require(Self.deny(pid, host: "api.example", exe: "/usr/bin/tool", at: t0.addingTimeInterval(3)))
        let rows3 = PolicyDrawer.blockedRows([tool, later, again], profileID: pid, since: t0.addingTimeInterval(-60))
        #expect(rows3.first { $0.fw.exe == "/usr/bin/tool" }?.count == 2)
        // The toolbar badge counts the same rows the drawer lists.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let drawer = try String(contentsOf: root.appendingPathComponent("Sources/AgentCoding/PolicyDrawer.swift"), encoding: .utf8)
        #expect(drawer.components(separatedBy: "rowKey(host: host, port: port, exe: fw.exe)").count == 3)
    }

    @Test("The program survives the timeline's persisted form")
    func wireKeepsExe() {
        let fw = SecurityTimeline.Firewall(host: "api.example", ip: nil, port: 9443, proto: "tcp", rule: nil,
                                           denied: true, byPolicy: true, exe: "/usr/bin/tool")
        #expect(SecurityTimeline.Firewall(wire: fw.wire)?.exe == "/usr/bin/tool")
    }

    @Test("A deny for another program isn't deduped into the first one's report")
    func dedupeKeysOnProgram() {
        let d = EgressReportDeduper(), pid = UUID()
        #expect(d.shouldReport(profileID: pid, host: "api.example", port: 443, denied: true, exe: "/usr/bin/tool"))
        #expect(!d.shouldReport(profileID: pid, host: "api.example", port: 443, denied: true, exe: "/usr/bin/tool"))
        #expect(d.shouldReport(profileID: pid, host: "api.example", port: 443, denied: true, exe: "/tmp/curl"))
    }

    @Test("The identity gate hands the switch the program it denied")
    func gateReturnsExe() async throws {
        let svc = BinaryIdentityService(), pid = UUID()
        svc.queryOverride = { _, _ in ["ok": true, "exe": "/tmp/curl", "sha256": "aaa", "ancestors": []] }
        var policy = EgressPolicy(openShell: try OpenShellPolicy.parse(BinaryIdentityTests.policyYAML))
        policy.enforceBinaries = true
        let ip = try #require(EgressPolicy.parseIPv4Address("140.82.112.3"))
        #expect(svc.gate(profileID: pid, sport: 4000, dstIP: ip, dport: 443, hostnames: ["api.github.com"], policy: policy) == nil)
        var decided: (verdict: EgressPolicy.Verdict, exe: String?)?
        for _ in 0..<100 {
            decided = svc.gate(profileID: pid, sport: 4000, dstIP: ip, dport: 443, hostnames: ["api.github.com"], policy: policy)
            if decided != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(decided?.verdict == .deny)
        #expect(decided?.exe == "/tmp/curl")
    }

    @Test("Every deny path puts its program on the event; nothing reads a program at Allow's click")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
        let mitm = try src("Sources/AgentCoding/Mitm/MitmEngine.swift")
        #expect(mitm.components(separatedBy: "\"exe\": .of(identity?.exe)").count == 3)
        #expect(mitm.components(separatedBy: "denied: true, exe: identity?.exe)").count == 3)
        let sw = try src("Sources/SandboxEngine/VMNetSwitch.swift")
        #expect(sw.contains("verdict = .deny; deniedExe = d.exe"))
        #expect(sw.contains("key.exe = denied ? exe : nil"))
        #expect(sw.contains("if denied { event.exe = exe }"))
        #expect(try src("Sources/AgentCoding/BromureAC.swift").contains("if let exe = ev.exe { eventData[\"exe\"] = .string(exe) }"))
        #expect(try src("Sources/AgentCoding/CloudEvents.swift").contains("exe: s(\"exe\"))"))
        let drawer = try src("Sources/AgentCoding/PolicyDrawer.swift")
        #expect(!drawer.contains("BinaryIdentityService.shared"))
        #expect(drawer.contains("allow(profileID: pid, host: host, port: port, exe: exe)"))
        #expect(drawer.contains("if let exe = program(item, profile) {\n                            Text(verbatim: exe)"))
        #expect(!(try src("Sources/AgentCoding/OpenShellAdvisor.swift")).contains("BinaryIdentityService.shared"))
    }
}
