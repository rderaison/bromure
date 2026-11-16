import Foundation
import Testing
@testable import SandboxEngine

/// A failed image upgrade (e.g. 502 → 503) or rebuild must leave the
/// previous image bootable: the local build goes to staging files, which
/// replace the live disk/kernel/initrd only when the build succeeds.
@Suite("Staged base-image builds")
struct StagedImageTests {
    private func makeManager() throws -> (LinuxImageManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = LinuxImageManager(storageDir: dir)
        for url in [manager.linuxDiskURL, manager.linuxKernelURL, manager.linuxInitrdURL] {
            try Data("old-\(url.lastPathComponent)".utf8).write(to: url)
        }
        try Data("502".utf8).write(to: manager.imageVersionURL)
        return (manager, dir)
    }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    struct BuildFailed: Error {}

    @Test("A failing build keeps the previous image and removes staging files")
    func failedBuildKeepsPreviousImage() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        var stagedURLs: [URL] = []

        await #expect(throws: BuildFailed.self) {
            try await manager.withStagedImage { staged in
                stagedURLs = [staged.disk, staged.kernel, staged.initrd]
                try Data("new-disk".utf8).write(to: staged.disk)
                try Data("new-kernel".utf8).write(to: staged.kernel)
                throw BuildFailed()
            }
        }

        #expect(contents(manager.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(manager.linuxKernelURL) == "old-vmlinuz")
        #expect(contents(manager.linuxInitrdURL) == "old-initrd")
        #expect(contents(manager.imageVersionURL) == "502")
        #expect(manager.hasBootFiles)
        #expect(!stagedURLs.isEmpty)
        for url in stagedURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("A build missing a boot file is refused and keeps the previous image")
    func incompleteBuildKeepsPreviousImage() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: (any Error).self) {
            try await manager.withStagedImage { staged in
                try Data("new-disk".utf8).write(to: staged.disk)
                try Data("new-kernel".utf8).write(to: staged.kernel)
            }
        }

        #expect(contents(manager.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(manager.linuxKernelURL) == "old-vmlinuz")
        #expect(contents(manager.linuxInitrdURL) == "old-initrd")
    }

    @Test("A promotion failing midway restores every previous boot file")
    func failedPromotionRollsBack() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let newDisk = dir.appendingPathComponent("new-disk")
        let newKernel = dir.appendingPathComponent("new-kernel")
        try Data("new-disk".utf8).write(to: newDisk)
        try Data("new-kernel".utf8).write(to: newKernel)
        // The initrd source is missing, so its move fails after the disk
        // and kernel were already promoted.
        let missing = dir.appendingPathComponent("missing-initrd")

        #expect(throws: (any Error).self) {
            try manager.promote([(newDisk, manager.linuxDiskURL),
                                 (newKernel, manager.linuxKernelURL),
                                 (missing, manager.linuxInitrdURL)])
        }

        #expect(contents(manager.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(manager.linuxKernelURL) == "old-vmlinuz")
        #expect(contents(manager.linuxInitrdURL) == "old-initrd")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".previous") }
        #expect(leftovers.isEmpty)
    }

    @Test("A successful build replaces all three boot files")
    func successfulBuildPromotes() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await manager.withStagedImage { staged in
            try Data("new-disk".utf8).write(to: staged.disk)
            try Data("new-kernel".utf8).write(to: staged.kernel)
            try Data("new-initrd".utf8).write(to: staged.initrd)
        }

        #expect(contents(manager.linuxDiskURL) == "new-disk")
        #expect(contents(manager.linuxKernelURL) == "new-kernel")
        #expect(contents(manager.linuxInitrdURL) == "new-initrd")
    }

    // MARK: A promotion a crash interrupted
    //
    // Finding "Interrupted local promotion leaves no bootable live image"
    // (CWE-459): a kill between setting the live files aside and moving the
    // new ones in left no live image; startup asked for setup while the old
    // one sat under .previous.

    private func journal(_ dir: URL, _ entries: [(String, Bool)]) throws {
        try JSONEncoder().encode(entries.map { ImagePromotion.Entry(live: $0.0, hadLive: $0.1) })
            .write(to: dir.appendingPathComponent(ImagePromotion.journalName))
    }
    private func setAside(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("previous"))
    }
    private func leftovers(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".previous") || $0 == ImagePromotion.journalName }
    }

    @Test("Killed after the live files were set aside: the next launch has the previous image back")
    func crashAfterSetAside() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal(dir, [("linux-base.img", true), ("vmlinuz", true), ("initrd", true)])
        for url in [m.linuxDiskURL, m.linuxKernelURL, m.linuxInitrdURL] { try setAside(url) }
        #expect(!m.hasBootFiles)

        let relaunched = LinuxImageManager(storageDir: dir)
        #expect(relaunched.hasBootFiles)
        #expect(contents(m.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(m.linuxKernelURL) == "old-vmlinuz")
        #expect(contents(m.linuxInitrdURL) == "old-initrd")
        #expect(try leftovers(dir).isEmpty)
    }

    @Test("Killed midway (one new file in, one set aside, one not yet): all three old ones")
    func crashMidway() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal(dir, [("linux-base.img", true), ("vmlinuz", true), ("initrd", true)])
        try setAside(m.linuxDiskURL)
        try Data("new-disk".utf8).write(to: m.linuxDiskURL)
        try setAside(m.linuxKernelURL)
        // initrd: never set aside, still the old one.

        _ = LinuxImageManager(storageDir: dir)
        #expect(contents(m.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(m.linuxKernelURL) == "old-vmlinuz")
        #expect(contents(m.linuxInitrdURL) == "old-initrd")
        #expect(try leftovers(dir).isEmpty)
    }

    @Test("A first install killed midway leaves no half image to boot")
    func crashFirstInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staged-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal(dir, [("linux-base.img", false), ("vmlinuz", false), ("initrd", false)])
        try Data("new-disk".utf8).write(to: dir.appendingPathComponent("linux-base.img"))

        let m = LinuxImageManager(storageDir: dir)
        #expect(!m.hasImageFiles)
        #expect(try leftovers(dir).isEmpty)
    }

    @Test("A promotion under way elsewhere (its lock held) isn't rolled back")
    func liveLockSkipsRecovery() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try journal(dir, [("linux-base.img", true)])
        try setAside(m.linuxDiskURL)
        try Data("new-disk".utf8).write(to: m.linuxDiskURL)
        let fd = open(dir.appendingPathComponent(ImagePromotion.lockName).path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        _ = LinuxImageManager(storageDir: dir)
        #expect(contents(m.linuxDiskURL) == "new-disk")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ImagePromotion.journalName).path))
        flock(fd, LOCK_UN); close(fd)
        // Released (the other process gone): the next launch rolls it back.
        _ = LinuxImageManager(storageDir: dir)
        #expect(contents(m.linuxDiskURL) == "old-linux-base.img")
        #expect(try leftovers(dir).isEmpty)
    }

    // Finding "Recovery discards its journal even when restoring a boot
    // artifact fails" (CWE-459): a failed restore still dropped the journal,
    // so the next launch saw no marker and booted (or kept) a mix.
    @Test("A restore that fails keeps the journal and backups, blocks booting, and is retried")
    func failedRestoreKeepsJournal() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try journal(dir, [("linux-base.img", true), ("vmlinuz", true), ("initrd", true)])
        for url in [m.linuxDiskURL, m.linuxKernelURL, m.linuxInitrdURL] { try setAside(url) }
        try Data("new-disk".utf8).write(to: m.linuxDiskURL)
        // Something rename(2) can't replace sits at the kernel's live path
        // (a non-empty directory), so restoring vmlinuz.previous fails.
        try fm.createDirectory(at: m.linuxKernelURL, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: m.linuxKernelURL.appendingPathComponent("blocker"))

        let relaunched = LinuxImageManager(storageDir: dir)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(ImagePromotion.journalName).path))
        #expect(fm.fileExists(atPath: m.linuxKernelURL.appendingPathExtension("previous").path))
        #expect(!relaunched.hasBootFiles)
        #expect(!relaunched.baseImageExists)
        // The restores that could happen did.
        #expect(contents(m.linuxDiskURL) == "old-linux-base.img")
        #expect(contents(m.linuxInitrdURL) == "old-initrd")
        // A promotion is refused rather than deleting the remaining backup.
        let staged = dir.appendingPathComponent("staged-disk")
        try Data("newer".utf8).write(to: staged)
        #expect(throws: (any Error).self) { try m.promote([(staged, m.linuxDiskURL)]) }
        #expect(fm.fileExists(atPath: m.linuxKernelURL.appendingPathExtension("previous").path))

        // Obstacle gone: the next launch finishes the rollback.
        try fm.removeItem(at: m.linuxKernelURL)
        let again = LinuxImageManager(storageDir: dir)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent(ImagePromotion.journalName).path))
        #expect(again.hasBootFiles)
        #expect(contents(m.linuxKernelURL) == "old-vmlinuz")
        #expect(try leftovers(dir).isEmpty)
    }

    @Test("An unreadable journal keeps its backups, and blocks a promotion that would delete them")
    func unreadableJournalKept() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = dir.appendingPathComponent(ImagePromotion.journalName)
        try Data("not json".utf8).write(to: j)
        try setAside(m.linuxDiskURL)
        _ = LinuxImageManager(storageDir: dir)
        #expect(FileManager.default.fileExists(atPath: j.path))
        #expect(contents(m.linuxDiskURL.appendingPathExtension("previous")) == "old-linux-base.img")
        let staged = dir.appendingPathComponent("x.building")
        try Data("new".utf8).write(to: staged)
        #expect(throws: (any Error).self) { try m.promote([(staged, m.linuxDiskURL)]) }
        #expect(contents(m.linuxDiskURL.appendingPathExtension("previous")) == "old-linux-base.img")
    }

    @Test("A single file is replaced in one rename, never missing")
    func replaceInOneRename() throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("linux-base.img.partial")
        try Data("amended".utf8).write(to: staged)
        try ImagePromotion.replace(staged, over: m.linuxDiskURL)
        #expect(contents(m.linuxDiskURL) == "amended")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(throws: (any Error).self) { try ImagePromotion.replace(staged, over: m.linuxDiskURL) }
        #expect(contents(m.linuxDiskURL) == "amended")
    }

    @Test("A completed promotion leaves no journal or backups behind, and recovery then changes nothing")
    func completedPromotionIsClean() async throws {
        let (m, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await m.withStagedImage { staged in
            try Data("new-disk".utf8).write(to: staged.disk)
            try Data("new-kernel".utf8).write(to: staged.kernel)
            try Data("new-initrd".utf8).write(to: staged.initrd)
        }
        #expect(try leftovers(dir).isEmpty)
        _ = LinuxImageManager(storageDir: dir)
        #expect(contents(m.linuxDiskURL) == "new-disk")
        #expect(contents(m.linuxInitrdURL) == "new-initrd")
    }
}
