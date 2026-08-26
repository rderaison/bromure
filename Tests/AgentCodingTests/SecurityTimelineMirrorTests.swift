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
        let tl = SecurityTimeline.shared
        tl.clear()
        let orig = sample()
        orig.forEach(tl.append)
        let rows = tl.mirrorRows()
        #expect(rows.count == 3)

        // Rebuild into a clean store (simulating the fat client).
        tl.clear()
        tl.applyMirror(rows)
        #expect(tl.events.count == 3)

        for (a, b) in zip(orig, tl.events) {
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
        let tl = SecurityTimeline.shared
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
        let tl = SecurityTimeline.shared
        tl.clear()
        tl.applyMirror([
            ["engine": "Firewall", "condition": "h", "decision": "allowed",
             "kind": "allowed", "t": 1.0, "profileID": UUID().uuidString],
            ["engine": "Firewall"],                       // missing fields → dropped
            ["condition": "x", "decision": "y"],          // missing engine → dropped
        ])
        #expect(tl.events.count == 1)
        // Unknown kind falls back to .info, never crashes.
        tl.applyMirror([["engine": "E", "condition": "c", "decision": "d", "kind": "???"]])
        #expect(tl.events.first?.kind == .info)
        tl.clear()
    }
}
