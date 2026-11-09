import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A clone-first automation run's workspace copy on the daemon (macOS:
    /// cloneWorkspaceForAutomation / destroyAutomationClone): the profile
    /// duplicated, its VM's images cloned into a VM registered stopped under
    /// the copy's id, and all of it gone with the run. Copy-on-write only: no
    /// reflink, no clone, nothing left behind. (The cloner is injected: the
    /// test directory's filesystem may not reflink.)
    @Suite("Workspace clones for automation runs", .serialized,
           .enabled(if: FileManager.default.isExecutableFile(atPath: MachineConfig.defaultFirecrackerBinary)))
    struct WorkspaceCloneTests {
        static let copier: VMCheckpoints.Cloner = { src, dst in
            do { try FileManager.default.copyItem(atPath: src, toPath: dst); return nil } catch { return "\(error)" }
        }

        static func base(_ d: Daemon, _ dir: String) async throws -> (Profile, String) {
            var p = Profile(name: "repo-ws", tool: .claude, authMode: .token)
            p.bootAtStartup = true
            p = try ProfileStore().save(p)
            let key = p.id.uuidString.lowercased()
            var rec = RepairMarksTests.stopped(key)
            rec.name = "repo-ws"
            rec.cpus = 3
            rec.memoryMiB = 3072
            rec.homeGB = 24
            try await d.registerForTesting(rec)
            let vm = await d.vmDir(key)
            try FileManager.default.createDirectory(atPath: vm + "/meta", withIntermediateDirectories: true)
            try Data("system".utf8).write(to: URL(fileURLWithPath: vm + "/disk.raw"))
            try Data("home".utf8).write(to: URL(fileURLWithPath: vm + "/home.img"))
            try Data("x".utf8).write(to: URL(fileURLWithPath: vm + "/meta/hostname.txt"))
            return (p, vm)
        }

        /// A private workspace's clone is private too: in the set handed to
        /// the event emitter and the HTTP-log uploader by the time the clone
        /// exists (before its VM could emit anything).
        @Test func aPrivateWorkspacesCloneIsKeptOutOfTheCloud() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            let (base, _) = try await Self.base(d, dir)
            _ = try ProfileWrites.edit(base.id, store: ProfileStore()) { $0.privateMode = true; return true }
            let clone = try #require(await d.cloneWorkspace(base.id, runSlug: "private-run", cloner: Self.copier))
            #expect(ProfileStore().loadAll().first { $0.id == clone.id }?.privateMode == true)
            let ids = Daemon.streamingPrivateIDs.withLockedValue { $0 }
            #expect(ids.contains(clone.id) && ids.contains(base.id), "\(ids)")
        }

        @Test func aCloneCarriesTheImagesAndGoesWithTheRun() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            let (base, _) = try await Self.base(d, dir)

            let clone = try #require(await d.cloneWorkspace(base.id, runSlug: "run-1", cloner: Self.copier))
            #expect(clone.id != base.id && clone.name == "repo-ws ⌁ run-1")
            #expect(ProfileStore().loadAll().first { $0.id == clone.id }?.bootAtStartup == false, "a leftover clone never boots itself")
            let key = clone.id.uuidString.lowercased()
            let rec = try #require(await d.registry.find(key))
            #expect(rec.state == .stopped && rec.cpus == 3 && rec.memoryMiB == 3072 && rec.homeGB == 24)
            let vm = await d.vmDir(key)
            #expect(try String(contentsOfFile: vm + "/disk.raw", encoding: .utf8) == "system")
            #expect(try String(contentsOfFile: vm + "/home.img", encoding: .utf8) == "home")
            #expect(!FileManager.default.fileExists(atPath: vm + "/meta"), "a cold boot: no meta share or saved state")

            await d.destroyClone(clone.id, pollInterval: .milliseconds(10))
            #expect(await d.registry.find(key) == nil)
            #expect(!FileManager.default.fileExists(atPath: vm))
            #expect(!ProfileStore().loadAll().contains { $0.id == clone.id })
            #expect(await d.registry.find(base.id.uuidString.lowercased()) != nil, "the base stays")
            await d.shutdown()
        }

        @Test func withoutReflinksThereIsNoCloneAndNothingLeft() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            let (base, _) = try await Self.base(d, dir)
            let before = Set(ProfileStore().loadAll().map(\.id))
            let records = await d.registry.records.count
            #expect(await d.cloneWorkspace(base.id, runSlug: "run-2", cloner: { _, _ in VMCheckpoints.unsupportedReason }) == nil)
            #expect(Set(ProfileStore().loadAll().map(\.id)) == before, "the duplicated profile is undone")
            #expect(await d.registry.records.count == records)
            let vms = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/state/vms")) ?? []
            #expect(vms == [base.id.uuidString.lowercased()], "\(vms)")
            await d.shutdown()
        }
    }
}
