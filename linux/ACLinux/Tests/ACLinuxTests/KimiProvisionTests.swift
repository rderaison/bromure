import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The launch's Kimi gate (macOS: kimiNeedsProvisioning before boot): a
    /// Kimi subscription record without its managed config is provisioned
    /// first; one that has it, or another tool's workspace, isn't. (The
    /// network call is a test hook here: no test reaches api.kimi.ai.)
    @Suite("Kimi provisioning at launch", .serialized)
    struct KimiProvisionTests {
        @Test func onlyAnUnprovisionedKimiRecordIsProvisioned() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let asked = NIOLockedValueBox<[UUID]>([])
            Daemon.kimiProvisionForTesting.withLockedValue { $0 = { id in asked.withLockedValue { $0.append(id) } } }
            defer { Daemon.kimiProvisionForTesting.withLockedValue { $0 = nil } }
            let mitm = try #require(await d.mitm)
            let kimi = Profile(name: "k", tool: .kimi, authMode: .subscription)
            try mitm.kimiStore.setOverride(KimiSubscriptionRecord(accessToken: "kimi-access-test", refreshToken: "kimi-refresh-test",
                                                                  expiresAt: Date().addingTimeInterval(3600), savedAt: Date()), for: kimi.id)
            #expect(await d.kimiNeedsProvisioning(kimi))
            await d.provisionKimiIfNeeded(kimi)
            #expect(asked.withLockedValue { $0 } == [kimi.id])

            let done = Profile(name: "k2", tool: .kimi, authMode: .subscription)
            let toml = "[providers.\(KimiProvisioning.providerName)]\ndefault_model = \"m\"\n"
            try mitm.kimiStore.setOverride(KimiSubscriptionRecord(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600),
                                                                  savedAt: Date(), configTOML: toml), for: done.id)
            #expect(await !d.kimiNeedsProvisioning(done))
            await d.provisionKimiIfNeeded(done)
            await d.provisionKimiIfNeeded(Profile(name: "c", tool: .claude, authMode: .subscription))
            await d.provisionKimiIfNeeded(Profile(name: "k3", tool: .kimi, authMode: .token))
            #expect(asked.withLockedValue { $0 } == [kimi.id], "nothing more asked")
            await d.shutdown()
        }
    }
}
