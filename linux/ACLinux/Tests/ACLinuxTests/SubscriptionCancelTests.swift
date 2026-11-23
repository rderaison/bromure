import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `POST /subscriptions/cancel` (macOS: ACAutomationServer's route and
    /// onCancelRegistration): a fat client that gave up its sign-in ends the
    /// run it was given, and only that one.
    @Suite("Sign-in cancel", .serialized)
    struct SubscriptionCancelTests {
        @Test func aRunIsNamedAndOnlyALiveOneEnds() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let missing = try #require(await d.subscriptionsRoute("POST", "/subscriptions/cancel", .object([:])))
            #expect(missing.status == 400)
            let unknown = try #require(await d.subscriptionsRoute("POST", "/subscriptions/cancel",
                                                                  ["registration": .string(UUID().uuidString)]))
            #expect(unknown.status == 404 && unknown.body["ok"] == .bool(false), "no sign-in under way: nothing ended")
            await d.shutdown()
        }
    }
}
