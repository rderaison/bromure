import Foundation
import Testing
@testable import ACLinux

/// A new home's size on the Linux server, as main sizes it on a Mac
/// (SessionDisk.resolvedHomeImageGB / newHomeDefaultGB): the daemon's
/// setting when set, else scaled to the free space where the VMs live; an
/// existing home grows only to a size of its own; a fat client is told
/// this host's default.
@Suite("Home sizing by free space")
struct HomeSizingTests {
    static let gib: UInt64 = 1 << 30

    @Test func theDefaultFollowsFreeSpaceUnlessSet() {
        #expect(Daemon.resolvedHomeImageGB(override: nil, freeBytes: 10 * Self.gib) == 8)
        #expect(Daemon.resolvedHomeImageGB(override: nil, freeBytes: 100 * Self.gib) == 12)
        #expect(Daemon.resolvedHomeImageGB(override: nil, freeBytes: 500 * Self.gib) == 16)
        #expect(Daemon.resolvedHomeImageGB(override: nil, freeBytes: nil) == 16, "unknown: the full default")
        #expect(Daemon.resolvedHomeImageGB(override: 48, freeBytes: 10 * Self.gib) == 48, "the setting wins")
        #expect(Daemon.resolvedHomeImageGB(override: 2, freeBytes: nil) == 8)
        #expect(Daemon.resolvedHomeImageGB(override: 4096, freeBytes: nil) == 1024)
    }

    @Test func freeSpaceIsMeasuredAtTheNearestExistingFolder() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let here = Daemon.freeBytes(near: dir)
        #expect(here != nil)
        #expect(Daemon.freeBytes(near: dir + "/vms/not-made-yet") == here)
    }

    @Test func aDefaultSizedHomeIsntGrownLater() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/home.img"
        try Daemon.ensureHomeImage(atPath: path, bytes: 8 << 30)
        // More room now: the default would be bigger, but it only sizes a new home.
        let kept = try Daemon.growHomeImageIfNeeded(atPath: path, target: 16 << 30, setting: nil)
        #expect(kept == "home image 8 GiB (default size, kept: the default only sizes a new home) — nothing to grow")
        var st = stat()
        _ = stat(path, &st)
        #expect(st.st_size == 8 << 30)
        // A size of its own grows it.
        #expect(try Daemon.growHomeImageIfNeeded(atPath: path, target: 16 << 30, setting: 16, floor: 0).contains("grown"))
    }
}

extension DaemonGlobalSuites {
    /// GET /storage/defaults and a workspace's storage reply say this
    /// host's new-home size (main 285c37f7: a remote editor shows the
    /// server's, not the client's).
    @Suite("Storage defaults", .serialized)
    struct StorageDefaultsTests {
        @Test func theServerSaysItsDefault() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let want = await d.newHomeDefaultGB()
            #expect([8, 12, 16].contains(want), "\(want)")
            let r = await d.storageDefaults()
            #expect(r.status == 200 && r.body["homeImageGB"] == .number(Double(want)))
            let prior = ProfileStore.defaultRootDir
            defer { ProfileStore.defaultRootDir = prior }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            let p = try ProfileStore().save(Profile(name: "sized", tool: .claude, authMode: .token))
            #expect(await d.storage(p)["defaultHomeGB"] == .number(Double(want)))
            await d.shutdown()
        }
    }
}
