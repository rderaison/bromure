import Foundation
import Testing
@testable import ACLinux
@testable import SandboxEngine

/// A destination the policy allows, but not for this program (binaries
/// enforced): the deny says which rule and which program, not "default
/// policy" (main: identityDenialReason on the transparent MiTM's deny and
/// on the switch's report, through the engine's guardrails).
@Suite("Identity denials say why", .serialized)
struct IdentityReasonTests {
    static func rows(_ pid: UUID, _ containing: String) async throws -> [SecurityTimeline.Event] {
        var rows: [SecurityTimeline.Event] = []
        for _ in 0..<150 {
            rows = await MainActor.run {
                SecurityTimeline.shared.allEvents.filter { $0.profileID == pid && "\($0)".contains(containing) }
            }
            if !rows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return rows
    }
    /// The row's decision names the rule that doesn't list the program.
    static func reason(_ e: SecurityTimeline.Event) -> String? {
        e.decision.contains("doesn't list") ? e.decision : nil
    }

    @Test func theTransparentDenySaysWhy() async throws {
        let (rig, _) = try TransparentIdentityTests.rig(answer: "/usr/bin/python3"); defer { rig.stop() }
        _ = try TransparentIdentityTests().flow(rig, srcPort: 40177)
        let rows = try await Self.rows(rig.pid, "/usr/bin/python3")
        let why = try #require(rows.compactMap(Self.reason).first, "\(rows)")
        #expect(why.contains("`web`") && why.contains("/usr/bin/python3"), Comment(rawValue: why))
    }

    @Test func theSwitchReportSaysWhyWithTheEngine() async throws {
        let (rig, _) = try TransparentIdentityTests.rig(answer: nil); defer { rig.stop() }
        var ev = VMNetSwitch.EgressEvent(profileID: rig.pid, dstIP: EgressPolicy.parseIPv4Address(rig.ip)!,
                                         hostnames: [], proto: 6, port: 80, denied: true)
        ev.exe = "/usr/bin/wget"
        SwitchEgressReport.record(ev, engine: rig.proxy)
        let rows = try await Self.rows(rig.pid, "/usr/bin/wget")
        let why = try #require(rows.compactMap(Self.reason).first, "\(rows)")
        #expect(why.contains("`web`") && why.contains("/usr/bin/wget"), Comment(rawValue: why))
        // Without the engine: no reason (as before).
        ev.exe = "/usr/bin/nc"
        SwitchEgressReport.record(ev)
        let plain = try await Self.rows(rig.pid, "/usr/bin/nc")
        #expect(!plain.isEmpty && plain.allSatisfy { Self.reason($0) == nil }, "\(plain)")
    }
}
