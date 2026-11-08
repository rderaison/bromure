import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// A new workspace's RAM follows the host's, down to 2 GB on hosts under
/// 16 GB; its home follows the free space it will draw on, down to 8 GB.
/// Once a home exists, no default grows it (`vm.homeImageGB` included):
/// only a size of its own, or a migration, does.
@Suite("New workspaces: RAM and home sized to the Mac")
struct VMSizingDefaultsTests {
    private static let gib: UInt64 = 1 << 30

    @Test("RAM: 2 GB under a 16 GB host, then 4, 6 and 8 GB")
    func memoryTiers() {
        let tiers: [(UInt64, Int)] = [(8, 2), (12, 2), (15, 2), (16, 4), (17, 4), (18, 6), (24, 6),
                                      (32, 6), (35, 6), (36, 8), (64, 8), (128, 8)]
        for (host, vm) in tiers {
            #expect(Profile.defaultMemoryGB(hostBytes: host * Self.gib) == vm, "\(host) GB host")
        }
        // The editor's stepper reaches the smallest tier.
        #expect(Profile.defaultMemoryGB(hostBytes: 8 * Self.gib) >= 2)
    }

    @Test("home: 8 GB under 64 GB free, 12 GB under 128 GB, 16 GB above; unknown free space → 16")
    func homeTiers() {
        let tiers: [(UInt64, Int)] = [(0, 8), (5, 8), (63, 8), (64, 12), (100, 12), (127, 12),
                                      (128, 16), (500, 16), (4000, 16)]
        for (free, gb) in tiers {
            #expect(SessionDisk.scaledHomeImageGB(freeBytes: free * Self.gib) == gb, "\(free) GB free")
        }
        #expect(SessionDisk.scaledHomeImageGB(freeBytes: nil) == 16)
        // Never below what the editor allows.
        #expect(SessionDisk.scaledHomeImageGB(freeBytes: 0) >= ProfileEditorView.minHomeGB)
    }

    @Test("vm.homeImageGB wins over the free-space scale, within 8 GB…1 TB")
    func overrideWins() {
        let key = "vm.homeImageGB"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { saved.map { UserDefaults.standard.set($0, forKey: key) } ?? UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(SessionDisk.resolvedHomeImageGB(freeBytes: 10 * Self.gib) == 8)
        UserDefaults.standard.set(48, forKey: key)
        #expect(SessionDisk.resolvedHomeImageGB(freeBytes: 10 * Self.gib) == 48)
        UserDefaults.standard.set(2, forKey: key)
        #expect(SessionDisk.resolvedHomeImageGB(freeBytes: 500 * Self.gib) == 8)
    }

    @Test("free space is read where the home will be, or its nearest existing parent")
    func freeNear() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString)/profiles/X", isDirectory: true)
        let free = SessionDisk.freeBytes(near: missing)
        let there = EphemeralDisk.freeBytes(at: FileManager.default.temporaryDirectory.path)
        let (a, b) = (try #require(free), try #require(there))
        #expect(max(a, b) - min(a, b) < Self.gib, "same volume (other tests write meanwhile)")
    }

    @Test("an existing home isn't grown by a default or the override; its own size or a migration grows it")
    func growOnlyWhenAsked() throws {
        let key = "vm.homeImageGB"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { saved.map { UserDefaults.standard.set($0, forKey: key) } ?? UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmsize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "h", tool: .claude, authMode: .token)
        var disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        // A home made small (a full disk at the time).
        try FileManager.default.createDirectory(at: disk.homeImageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: disk.homeImageURL.path, contents: nil)
        let h = try FileHandle(forWritingTo: disk.homeImageURL)
        try h.truncate(atOffset: 4 * Self.gib); try h.close()
        func size() throws -> UInt64 {
            (try FileManager.default.attributesOfItem(atPath: disk.homeImageURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        }
        #expect(!disk.homeGrowsToTarget)
        let note = try disk.growHomeImageIfNeeded()
        #expect(try size() == 4 * Self.gib, "\(note)")
        #expect(note.contains("default size, kept"))
        // Its own size grows it.
        p.homeImageGB = 10
        disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        #expect(disk.homeGrowsToTarget)
        _ = try disk.growHomeImageIfNeeded()
        #expect(try size() == 10 * Self.gib)
        // The app-wide override sizes new homes only (manual: Advanced).
        p.homeImageGB = nil
        disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        UserDefaults.standard.set(32, forKey: key)
        #expect(!disk.homeGrowsToTarget)
        _ = try disk.growHomeImageIfNeeded()
        #expect(try size() == 10 * Self.gib)
        // A migration does grow it.
        disk.migrateHomeThisBoot = true
        #expect(disk.homeGrowsToTarget)
        _ = try disk.growHomeImageIfNeeded()
        #expect(try size() == 64 * Self.gib)
    }
}
