import Foundation
import Testing
@testable import ACLinux
@testable import SandboxEngine

/// Signing out of the bromure.io device identity with a managed
/// (enterprise) enrollment still there: as on macOS, the identity is the
/// managed one now and the key sync goes on under it; with nothing left,
/// it stops. Gated (BROMURE_TEST_ISOLATED=1, and XDG_DATA_HOME a temp
/// folder): the enrollment record lives in the data folder; its token goes
/// to an in-memory secret store, its server is a closed local port.
@Suite("Account sign-out under a managed enrollment", .serialized)
struct AccountSignOutTests {
    static var isolated: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["BROMURE_TEST_ISOLATED"] == "1" && (e["XDG_DATA_HOME"] ?? "").hasPrefix("/tmp/")
    }

    final class MemorySecrets: BACSecretStore.Backend, @unchecked Sendable {
        let lock = NSLock(); var items: [String: Data] = [:]
        func store(service: String, account: String, data: Data) throws { lock.lock(); items[service + "/" + account] = data; lock.unlock() }
        func read(service: String, account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[service + "/" + account] }
        func delete(service: String, account: String) { lock.lock(); items[service + "/" + account] = nil; lock.unlock() }
    }

    static func device() -> DeviceRecord {
        DeviceRecord(privateKeyHex: String(repeating: "0", count: 64), deviceToken: "dev-token", deviceTokenExpiresAt: nil,
                     deviceId: "dev-1", capability: "client", orgSlug: "o", orgKind: "individual",
                     apiBase: "http://127.0.0.1:9")
    }

    @Test(.enabled(if: isolated)) @MainActor
    func theSyncGoesOnUnderAManagedEnrollmentAndStopsWithoutOne() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        BromureLinuxPaths.stateDir.withLockedValue { $0 = dir }
        let saved = BACSecretStore.backend
        BACSecretStore.backend = MemorySecrets()
        defer { BACSecretStore.backend = saved; BACEnrollmentStore.destroy() }

        // A device identity and a managed enrollment.
        #expect(DeviceIdentityStore.store(Self.device()))
        try BACEnrollmentStore.save(BACInstall(installId: "inst-1", orgSlug: "acme", userId: "u", userEmail: "u@acme.example",
                                               serverURL: URL(string: "http://127.0.0.1:9")!, enrolledAt: Date(), deviceName: "srv"))
        try BACEnrollmentStore.storeInstallToken("managed-token")
        #expect(P2PIdentity.current()?.source == .device)
        LinuxAccountKeys.shared.start(every: 3600)
        #expect(LinuxAccountKeys.shared.isTicking)
        #expect(await d.accountSignOut().status == 200)
        #expect(P2PIdentity.current()?.source == .enterprise, "the managed enrollment is the identity now")
        #expect(LinuxAccountKeys.shared.isTicking, "the pulls go on under it")
        // The managed one can't be signed out of here.
        #expect(await d.accountSignOut().status == 409)

        // Without it: sign-out stops the pulls.
        BACEnrollmentStore.destroy()
        #expect(DeviceIdentityStore.store(Self.device()))
        #expect(await d.accountSignOut().status == 200)
        #expect(P2PIdentity.current() == nil)
        #expect(!LinuxAccountKeys.shared.isTicking)
        await d.shutdown()
    }
}
