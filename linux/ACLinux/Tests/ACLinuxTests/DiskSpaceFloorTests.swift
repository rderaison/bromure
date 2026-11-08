import Foundation
import SandboxEngine
import Testing
@testable import ACLinux

/// The free-space floor a home image is created and grown under (macOS:
/// SessionDisk's EphemeralDisk.checkDiskSpace calls): under it, nothing is
/// made or grown and the launch fails with SandboxError.diskFull.
@Suite("Disk space floor")
struct DiskSpaceFloorTests {
    @Test func underTheFloorNoHomeImageIsMadeOrGrown() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/home.img"
        #expect(throws: SandboxError.self) { try Daemon.ensureHomeImage(atPath: home, bytes: 8 << 30, floor: .max) }
        #expect(!FileManager.default.fileExists(atPath: home), "nothing made")
        try Daemon.ensureHomeImage(atPath: home, bytes: 8 << 30, floor: 0)
        #expect(throws: SandboxError.self) {
            _ = try Daemon.growHomeImageIfNeeded(atPath: home, target: 16 << 30, setting: 16, floor: .max)
        }
        var st = stat()
        #expect(stat(home, &st) == 0 && st.st_size == 8 << 30, "not grown")
        #expect(try Daemon.growHomeImageIfNeeded(atPath: home, target: 16 << 30, setting: 16, floor: 0).contains("grown"))
    }

    @Test func theFloorIsAGigabyteAndAnUnreadableVolumeFailsOpen() throws {
        #expect(EphemeralDisk.minimumFreeBytes == 1 << 30)
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try EphemeralDisk.checkDiskSpace(at: dir, minimumFreeBytes: .max)
            Issue.record("no space can be enough")
        } catch let SandboxError.diskFull(_, path) {
            #expect(path == dir)
        }
        try EphemeralDisk.checkDiskSpace(at: dir + "/missing/volume", minimumFreeBytes: .max)
    }
}
