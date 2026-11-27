import Foundation
import Testing
@testable import ACLinux
@testable import SandboxEngine

/// Signing out of the bromure.io device identity: the device is revoked on
/// bromure.io first (Fixtures/http_stub_server.py stands in for it), and the
/// identity forgotten here only once that is confirmed, or once the user was
/// told bromure.io refuses the credentials (CWE-613). With a managed
/// (enterprise) enrollment still there, as on macOS, the identity is the
/// managed one afterwards and the key sync goes on under it; with nothing
/// left, it stops. Gated (BROMURE_TEST_ISOLATED=1, and XDG_DATA_HOME a temp
/// folder): the enrollment record lives in the data folder; its token goes
/// to an in-memory secret store.
@Suite("Account sign-out", .serialized)
struct AccountSignOutTests {
    static var isolated: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["BROMURE_TEST_ISOLATED"] == "1" && (e["XDG_DATA_HOME"] ?? "").hasPrefix("/tmp/") && HTTPStub.available
    }

    final class MemorySecrets: BACSecretStore.Backend, @unchecked Sendable {
        let lock = NSLock(); var items: [String: Data] = [:]
        func store(service: String, account: String, data: Data) throws { lock.lock(); items[service + "/" + account] = data; lock.unlock() }
        func read(service: String, account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[service + "/" + account] }
        func delete(service: String, account: String) { lock.lock(); items[service + "/" + account] = nil; lock.unlock() }
    }

    /// `token`'s start says what the stand-in answers its revoke (ok-, gone-,
    /// late2-, boom-). `enrolled` nil: a record from before the field, whose
    /// refusal is final.
    static func device(_ token: String, api: String, enrolled: Date? = nil) -> DeviceRecord {
        DeviceRecord(privateKeyHex: String(repeating: "0", count: 64), deviceToken: token, deviceTokenExpiresAt: nil,
                     deviceId: "dev-1", capability: "server", orgSlug: "o", orgKind: "individual",
                     apiBase: api, enrolledAt: enrolled)
    }

    /// A daemon, the stand-in bromure.io, and a clean account state; all put
    /// back afterwards.
    @MainActor
    static func withWorld(_ body: (Daemon, HTTPStub) async throws -> Void) async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stub = try #require(try await HTTPStub(), "the stand-in bromure.io didn't start")
        defer { stub.stop() }
        let savedDir = BromureLinuxPaths.stateDir.withLockedValue { $0 }
        BromureLinuxPaths.stateDir.withLockedValue { $0 = dir }
        let saved = BACSecretStore.backend
        BACSecretStore.backend = MemorySecrets()
        AcceptedCredential.forget()
        LinuxAccountKeys.shared.forgetRefusal()
        defer {
            DeviceIdentityStore.erase()
            BACEnrollmentStore.destroy()
            BACSecretStore.backend = saved
            AcceptedCredential.forget()
            LinuxAccountKeys.shared.forgetRefusal()
            LinuxAccountKeys.shared.signedOut()
            BromureLinuxPaths.stateDir.withLockedValue { $0 = savedDir }
        }
        try await body(d, stub)
        await d.shutdown()
    }

    static func signedInAsDevice() -> Bool {
        if case .found = DeviceIdentityStore.load() { return true }
        return false
    }

    @Test(.enabled(if: isolated)) @MainActor
    func theSyncGoesOnUnderAManagedEnrollmentAndStopsWithoutOne() async throws {
        try await Self.withWorld { d, stub in
            // A device identity and a managed enrollment.
            #expect(DeviceIdentityStore.store(Self.device("ok-dev-token", api: stub.base + "/api")))
            try BACEnrollmentStore.save(BACInstall(installId: "inst-1", orgSlug: "acme", userId: "u", userEmail: "u@acme.example",
                                                   serverURL: URL(string: "http://127.0.0.1:9")!, enrolledAt: Date(), deviceName: "srv"))
            try BACEnrollmentStore.storeInstallToken("managed-token")
            #expect(P2PIdentity.current()?.source == .device)
            LinuxAccountKeys.shared.start(every: 3600)
            #expect(LinuxAccountKeys.shared.isTicking)
            let out = await d.accountSignOut()
            #expect(out.status == 200 && out.body["localOnly"] == nil, "\(out.body)")
            // bromure.io was asked to revoke the device, with its own token.
            let revokes = stub.events.filter { $0.hasPrefix("POST /api/v1/devices/self-revoke ") }
            #expect(revokes.count == 1 && revokes.first?.contains("auth=Bearer ok-dev-token agent=bromure-ac/") == true, "\(stub.events)")
            #expect(P2PIdentity.current()?.source == .enterprise, "the managed enrollment is the identity now")
            #expect(LinuxAccountKeys.shared.isTicking, "the pulls go on under it")
            // The managed one can't be signed out of here.
            #expect(await d.accountSignOut().status == 409)

            // Without it: sign-out stops the pulls.
            BACEnrollmentStore.destroy()
            #expect(DeviceIdentityStore.store(Self.device("ok-dev-token", api: stub.base + "/api")))
            #expect(await d.accountSignOut().status == 200)
            #expect(P2PIdentity.current() == nil)
            #expect(!LinuxAccountKeys.shared.isTicking)
        }
    }

    // Regression (CWE-613): the identity was erased whatever bromure.io
    // said, so a revoke that never got there left the device's token live
    // with nothing left to retry it with.
    @Test(.enabled(if: isolated)) @MainActor
    func aRevokeThatDidNotGetThroughKeepsTheIdentity() async throws {
        try await Self.withWorld { d, stub in
            // bromure.io unreachable (a closed port).
            #expect(DeviceIdentityStore.store(Self.device("ok-dev-token", api: "http://127.0.0.1:9")))
            let unreachable = await d.accountSignOut()
            #expect(unreachable.status == 502, "\(unreachable.body)")
            #expect(unreachable.body["error"]?.stringValue?.contains("still registered") == true)
            #expect(Self.signedInAsDevice(), "still signed in: the revoke can be tried again")
            // bromure.io answering 500.
            #expect(DeviceIdentityStore.store(Self.device("boom-dev-token", api: stub.base + "/api")))
            let broken = await d.accountSignOut()
            #expect(broken.status == 502 && broken.body["error"]?.stringValue?.contains("HTTP 500") == true, "\(broken.body)")
            #expect(Self.signedInAsDevice())
            // And again, once it answers.
            #expect(DeviceIdentityStore.store(Self.device("ok-dev-token", api: stub.base + "/api")))
            #expect(await d.accountSignOut().status == 200)
            #expect(!Self.signedInAsDevice())
        }
    }

    // bromure.io's 401 is the same for a revoked device and for a token
    // that expired with the device still live: not a confirmed revoke. The
    // first sign-out says so and keeps the identity; the second forgets it
    // here only.
    @Test(.enabled(if: isolated)) @MainActor
    func refusedCredentialsAreForgottenOnlyOnTheSecondSignOut() async throws {
        try await Self.withWorld { d, stub in
            #expect(DeviceIdentityStore.store(Self.device("gone-dev-token", api: stub.base + "/api")))
            let first = await d.accountSignOut()
            #expect(first.status == 409 && first.body["error"]?.stringValue == Daemon.signOutRefusedMessage, "\(first.body)")
            #expect(Self.signedInAsDevice(), "kept: this bearer is the only one that could revoke a live device")
            let second = await d.accountSignOut()
            #expect(second.status == 200 && second.body["localOnly"] == .bool(true), "\(second.body)")
            #expect(second.body["note"]?.stringValue?.contains("revoke it there") == true)
            #expect(!Self.signedInAsDevice())
            #expect(stub.events.filter { $0.hasPrefix("POST /api/v1/devices/self-revoke ") }.count == 2, "asked both times")
            // Signed in again with the same dead token: explained again.
            #expect(DeviceIdentityStore.store(Self.device("gone-dev-token", api: stub.base + "/api")))
            #expect(await d.accountSignOut().status == 409)
        }
    }

    // The device channel finds the bearer refused (P2PBroker's notice):
    // `account status` says so, and the next sign-out forgets the identity
    // here at once.
    @Test(.enabled(if: isolated)) @MainActor
    func aRefusalTheChannelReportedIsShownAndSignsOutAtOnce() async throws {
        try await Self.withWorld { d, stub in
            #expect(DeviceIdentityStore.store(Self.device("gone-dev-token", api: stub.base + "/api")))
            _ = LinuxAccountKeys.shared   // its observer
            // Another device's bearer: not ours to act on.
            NotificationCenter.default.post(name: .p2pCredentialRefused, object: nil, userInfo: ["bearer": "someone-else"])
            NotificationCenter.default.post(name: .p2pCredentialRefused, object: nil, userInfo: ["bearer": "gone-dev-token"])
            for _ in 0..<100 where LinuxAccountKeys.shared.credentialProblem == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(await d.accountStatus().body["problem"]?.stringValue == Daemon.credentialRefusedMessage)
            #expect(Self.signedInAsDevice(), "nothing is erased on the refusal itself")
            let out = await d.accountSignOut()
            #expect(out.status == 200 && out.body["localOnly"] == .bool(true), "\(out.body)")
            #expect(await d.accountStatus().body["problem"] == nil)
        }
    }

    // A 401 right after enrollment can be propagation lag: retried, and
    // while it lasts the identity stays.
    @Test(.enabled(if: isolated)) @MainActor
    func aFreshCredentialsRefusalIsRetried() async throws {
        try await Self.withWorld { d, stub in
            // Clears on the third try.
            #expect(DeviceIdentityStore.store(Self.device("late2-dev-token", api: stub.base + "/api", enrolled: Date())))
            #expect(await d.accountSignOut(retryDelay: 0).status == 200)
            #expect(stub.events.filter { $0.contains("late2-dev-token") }.count == 3)
            // Never clears: reported, kept.
            #expect(DeviceIdentityStore.store(Self.device("gone-fresh-token", api: stub.base + "/api", enrolled: Date())))
            let out = await d.accountSignOut(retryDelay: 0)
            #expect(out.status == 502 && out.body["error"]?.stringValue?.contains("may still be registered") == true, "\(out.body)")
            #expect(stub.events.filter { $0.contains("gone-fresh-token") }.count == 4)
            #expect(Self.signedInAsDevice())
        }
    }
}
