import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A governance change (an organization boundary, a managed policy)
    /// re-resolves the running workspaces and the list's shield at once
    /// (macOS: reapplyOpenShellGovernance on OpenShellGovernance.changedNotification).
    @Suite("Governance changes re-applied", .serialized)
    @MainActor
    struct GovernanceReapplyTests {
        @Test func aGovernanceChangeRefreshesTheShield() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir + "/state")
            let before = LinuxSessionHost.shared
            LinuxSessionHost.shared = host
            defer { LinuxSessionHost.shared = before }
            await d.wireOpenShellAdvisor()   // Daemon.start's wiring
            let stale: Set<UUID> = [UUID()]
            host.listModel.unsandboxedProfileIDs = stale
            NotificationCenter.default.post(name: OpenShellGovernance.changedNotification, object: nil)
            for _ in 0..<100 where host.listModel.unsandboxedProfileIDs == stale { try await Task.sleep(for: .milliseconds(20)) }
            #expect(host.listModel.unsandboxedProfileIDs != stale, "recomputed from the workspaces")
            await d.shutdown()
        }
    }
}
