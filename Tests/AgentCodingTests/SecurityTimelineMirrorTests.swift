import Foundation
import Testing
@testable import bromure_ac

/// The security engines run on the HOST, so a fat client mirroring a remote
/// instance has no local timeline of its own. The host ships its recent
/// decisions over `/state` (`mirrorRows`) and the client rebuilds them
/// (`applyMirror`) so the Security Timeline window works in fat-client mode.
/// These pin that the round trip preserves every field, including the
/// decision colour.
@MainActor
@Suite("Security Timeline fat-client mirror")
struct SecurityTimelineMirrorTests {

    private func sample() -> [SecurityTimeline.Event] {
        let pid = UUID()
        let t = Date(timeIntervalSince1970: 1_756_000_000)
        return [
            .init(time: t, engine: "Credential brokering",
                  condition: "brm_a1…c3 → api.z.ai", decision: "swapped in zai_9f…2a",
                  kind: .info, profileID: pid),
            .init(time: t.addingTimeInterval(3), engine: "Firewall",
                  condition: "evil.com:443 tcp", decision: "blocked",
                  kind: .blocked, profileID: pid),
            .init(time: t.addingTimeInterval(7), engine: "Upstream TLS",
                  condition: "registry.ny.secl.io", decision: "blocked — untrusted CA",
                  kind: .blocked, profileID: UUID()),
        ]
    }

    @Test("mirrorRows → applyMirror preserves every field")
    func roundTrip() {
        let tl = SecurityTimeline(directory: nil)
        tl.clear()
        let orig = sample()
        orig.forEach(tl.append)
        let rows = tl.mirrorRows()
        #expect(rows.count == 3)

        // Rebuild into a clean store (simulating the fat client).
        let client = SecurityTimeline(directory: nil)
        client.applyMirror(rows, host: "ark")
        let mirrored = client.remote["ark"] ?? []
        #expect(mirrored.count == 3)
        #expect(client.events.isEmpty)   // the client's own events are its own

        for (a, b) in zip(orig, mirrored) {
            #expect(a.engine == b.engine)
            #expect(a.condition == b.condition)
            #expect(a.decision == b.decision)
            #expect(a.kind == b.kind)               // colour survives
            #expect(a.profileID == b.profileID)
            #expect(abs(a.time.timeIntervalSince(b.time)) < 0.001)
        }
        tl.clear()
    }

    @Test("mirrorRows caps to the most recent N")
    func caps() {
        let tl = SecurityTimeline(directory: nil)
        tl.clear()
        let pid = UUID()
        for i in 0..<900 {
            tl.append(.init(time: Date(timeIntervalSince1970: Double(i)),
                            engine: "Firewall", condition: "h\(i)", decision: "allowed",
                            kind: .allowed, profileID: pid))
        }
        let rows = tl.mirrorRows(limit: 750)
        #expect(rows.count == 750)
        // The most recent survive (suffix), so the last row is h899.
        #expect(rows.last?["condition"] as? String == "h899")
        tl.clear()
    }

    @Test("applyMirror tolerates a malformed row without crashing")
    func malformed() {
        let tl = SecurityTimeline(directory: nil)
        tl.clear()
        tl.applyMirror([
            ["engine": "Firewall", "condition": "h", "decision": "allowed",
             "kind": "allowed", "t": 1.0, "profileID": UUID().uuidString],
            ["engine": "Firewall"],                       // missing fields → dropped
            ["condition": "x", "decision": "y"],          // missing engine → dropped
        ], host: "h")
        #expect(tl.remote["h"]?.count == 1)
        // Unknown kind falls back to .info, never crashes.
        tl.applyMirror([["engine": "E", "condition": "c", "decision": "d", "kind": "???"]], host: "h")
        #expect(tl.remote["h"]?.first?.kind == .info)
        tl.clear()
    }

    @Test("credential.exfiltration maps to a blocked credential-brokering row")
    func exfiltrationMapping() {
        let pid = UUID()
        let e = SecurityTimeline.map(
            profileID: pid,
            eventType: "credential.exfiltration",
            eventData: [
                "credential": .string("GitHub token"),
                "fake_preview": .string("brm_a1b2…c3d4"),
                "declared_host": .string("api.github.com"),
                "observed_host": .string("evil.example"),
            ],
            now: Date(timeIntervalSince1970: 1_756_000_000))
        #expect(e != nil)
        #expect(e?.engine == "Credential brokering")
        #expect(e?.kind == .blocked)
        #expect(e?.condition.contains("brm_a1b2…c3d4") == true)
        #expect(e?.condition.contains("api.github.com") == true)
        #expect(e?.condition.contains("evil.example") == true)
        #expect(e?.decision.contains("exfiltration") == true)
        #expect(e?.profileID == pid)
    }

    @Test("A mirrored host never overwrites this Mac's events, nor another host's")
    func separateMachines() {
        let tl = SecurityTimeline(directory: nil)
        let mine = sample()[0]
        tl.append(mine)
        let rows = [["engine": "Firewall", "condition": "x", "decision": "allowed",
                     "kind": "allowed", "t": 2.0, "profileID": UUID().uuidString]]
        tl.applyMirror(rows, host: "ark")
        tl.applyMirror(rows + rows, host: "daigo")
        tl.applyMirror([], host: "ark")          // an empty remote empties only itself
        #expect(tl.events.count == 1)
        #expect(tl.remote["ark"]?.isEmpty == true)
        #expect(tl.remote["daigo"]?.count == 2)
        #expect(tl.allEvents.count == 3)
        #expect(tl.allEvents.filter { $0.machine == "daigo" }.count == 2)
    }
}

@MainActor
@Suite("Security Timeline persistence")
struct SecurityTimelinePersistenceTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sectl-\(UUID().uuidString)")
    }

    private func settle() async {
        // Writes go through a background queue.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test("Events survive a restart, with their workspace")
    func survivesRestart() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = UUID()
        let tl = SecurityTimeline(directory: dir)
        tl.workspaceName = { $0 == pid ? "Claude Dev" : nil }
        tl.append(.init(time: Date(), engine: "Firewall", condition: "github.com:443 tcp",
                        decision: "allow", kind: .allowed, profileID: pid))
        tl.append(.init(time: Date(), engine: "Supply chain", condition: "apt curl@8.5.0",
                        decision: "allowed", kind: .allowed, profileID: pid))
        await settle()
        let again = SecurityTimeline(directory: dir)
        #expect(again.events.count == 2)
        #expect(again.events.first?.engine == "Firewall")
        #expect(again.events.last?.condition == "apt curl@8.5.0")
        #expect(again.events.first?.workspace == "Claude Dev")
        #expect(again.events.first?.profileID == pid)
    }

    @Test("Old daily logs are pruned past retention")
    func prunes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("2020-01-01.jsonl")
        let recent = dir.appendingPathComponent("2026-09-20.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: recent.path, contents: Data())
        SecurityTimeline.prune(dir, now: ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test("A garbled line is skipped, not fatal")
    func garbled() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = SecurityTimeline.line(.init(time: Date(), engine: "Firewall", condition: "c",
                                               decision: "allow", kind: .allowed, profileID: UUID()))!
        var data = Data("{not json\n".utf8)
        data.append(good)
        try data.write(to: dir.appendingPathComponent("2026-09-25.jsonl"))
        #expect(SecurityTimeline.load(from: dir, limit: 100, after: 0).count == 1)
    }

    @Test("apt downloads are recognized by name and version")
    func debParsing() {
        let d = SupplyChainRegistry.debPackage(path: "/ubuntu/pool/main/c/curl/curl_8.5.0-2ubuntu10.6_arm64.deb")
        #expect(d?.name == "curl")
        #expect(d?.version == "8.5.0-2ubuntu10.6")
        let epoch = SupplyChainRegistry.debPackage(path: "/debian/pool/main/o/openssl/libssl3_3.0.13-1%7edeb12u1_arm64.deb")
        #expect(epoch?.name == "libssl3")
        #expect(epoch?.version == "3.0.13-1~deb12u1")
        #expect(SupplyChainRegistry.debPackage(path: "/ubuntu/dists/noble/InRelease") == nil)
        #expect(SupplyChainRegistry.debPackage(path: "/downloads/tool.deb") == nil)   // not an archive pool
    }
}
