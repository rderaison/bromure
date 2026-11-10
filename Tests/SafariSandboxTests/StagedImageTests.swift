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
}
