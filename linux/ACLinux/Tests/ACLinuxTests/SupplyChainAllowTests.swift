import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The override prompt's "Always allow" on the daemon (macOS:
    /// SupplyChainOverrides.swift): saved in the workspace's reputation
    /// allowlist, once, in the test's own profiles folder.
    @Suite("Supply chain: always allow", .serialized)
    struct SupplyChainAllowTests {
        @Test func anAlwaysAllowIsSavedOnce() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            defer { ProfileStore.defaultRootDir = prior }
            let p = try ProfileStore().save(Profile(name: "sc", tool: .claude, authMode: .local))
            func list() -> [String] { ProfileStore().loadAll().first { $0.id == p.id }?.supplyChain.reputationAllowlist ?? [] }
            #expect(await d.allowSupplyChainPackage("npm:workerd", profileID: p.id))
            #expect(await d.allowSupplyChainPackage("npm:WORKERD", profileID: p.id), "already on the list")
            #expect(list() == ["npm:workerd"])
            #expect(await !d.allowSupplyChainPackage("npm:x", profileID: UUID()), "no such workspace")
        }

        /// A workspace's session answers end with it: "allow for the rest of
        /// the session" is asked again after a stop (macOS: MitmEngine
        /// .unregister revokes every consent broker's).
        @Test func sessionAnswersEndWithTheSession() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let asked = NIOLockedValueBoxShim(0)
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in asked.mutate { $0 += 1 }; return 2 } }   // for the session
            defer { ConsentPrompt.chooseForTesting.withLockedValue { $0 = nil } }
            let mitm = try #require(await d.mitm)
            let pid = UUID()
            func ask() async -> Bool {
                await mitm.supplyChainBroker.consent(profileID: pid, scope: "lockfile:npm", scopeDisplayName: "npm ci", detail: "?")
            }
            #expect(await ask() && asked.value == 1)
            #expect(await ask() && asked.value == 1, "remembered for the session")
            await d.clearWorkspaceProxyState(pid)
            #expect(await ask() && asked.value == 2, "asked again after the stop")
        }

        /// A test run's ProfileStore() never points at the user's profiles.
        @Test func aTestRunsProfilesAreItsOwn() {
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = nil
            defer { ProfileStore.defaultRootDir = prior }
            let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BromureAC/profiles", isDirectory: true)
            #expect(ProfileStore().profilesDirectory.standardizedFileURL != real.standardizedFileURL)
        }
    }
}
