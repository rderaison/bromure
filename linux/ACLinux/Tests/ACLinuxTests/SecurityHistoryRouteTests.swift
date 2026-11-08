import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A fat client's Security window on a Linux server (main: GET
    /// /security-timeline and /state's retention stamps): the host's rows of
    /// the last hours, and how far back it still holds, in its own order.
    @Suite("Security timeline history", .serialized)
    struct SecurityHistoryRouteTests {
        @Test func theHistoryAndTheRetentionStampsAreServed() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let pid = UUID()
            await SecurityTimeline.shared.record(profileID: pid, eventType: "egress.firewall",
                                                 eventData: ["action": .string("deny"), "proto": .string("tcp"),
                                                             "host": .string("history.example"), "port": .int(443)])
            let epoch = await MainActor.run { SecurityTimeline.shared.epoch }
            let r = await d.securityTimelineHistory("/security-timeline?hours=1")
            #expect(r.status == 200 && r.body["epoch"] == .string(epoch))
            guard case .array(let rows) = r.body["rows"] ?? .null else { Issue.record("\(r.body)"); return }
            #expect(rows.contains { "\($0)".contains("history.example") }, "\(rows.count) rows")
            let state = await d.stateBody()
            #expect(state["securityTimelineEpoch"] == .string(epoch))
            if case .number = state["securityTimelineOldest"] ?? .null {} else { Issue.record("no oldest: \(String(describing: state["securityTimelineOldest"]))") }
            if case .number = state["securityTimelineOldestSeq"] ?? .null {} else { Issue.record("no oldest seq") }
            await d.shutdown()
        }
    }
}
