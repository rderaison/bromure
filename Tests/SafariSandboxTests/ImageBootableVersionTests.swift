import Foundation
import Testing
@testable import SandboxEngine

/// Finding: "A failed 504 upgrade prevents browsing with an intact 503
/// image". The install target (imageVersion) and what may still boot
/// (minimumBootableImageVersion…imageVersion) are separate, so the
/// previous image keeps working while its upgrade hasn't succeeded.
@Suite("Bootable image versions")
struct ImageBootableVersionTests {
    private func manager(stamp: String?, bootFiles: Bool = true) throws -> (LinuxImageManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-bootable-\(UUID().uuidString)")
        let m = LinuxImageManager(storageDir: dir)
        try FileManager.default.createDirectory(at: m.linuxDiskURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if bootFiles {
            for url in [m.linuxDiskURL, m.linuxKernelURL, m.linuxInitrdURL] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        if let stamp {
            try FileManager.default.createDirectory(at: m.imageVersionURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try stamp.write(to: m.imageVersionURL, atomically: true, encoding: .utf8)
        }
        return (m, dir)
    }

    @Test("the previous image boots while the current one is what gets installed")
    func previousImageStillBoots() throws {
        let (m, dir) = try manager(stamp: LinuxImageManager.minimumBootableImageVersion + "\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(m.bootableImageExists)
        if LinuxImageManager.minimumBootableImageVersion != LinuxImageManager.imageVersion {
            #expect(!m.baseImageExists, "an older stamp still triggers the upgrade")
        }
    }

    @Test("the current image is bootable")
    func currentImageBoots() throws {
        let (m, dir) = try manager(stamp: LinuxImageManager.imageVersion)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(m.bootableImageExists)
        #expect(m.baseImageExists)
    }

    @Test("too old, too new, unstamped or incomplete images don't boot")
    func outOfRange() throws {
        let minimum = Int(LinuxImageManager.minimumBootableImageVersion)!
        let current = Int(LinuxImageManager.imageVersion)!
        #expect(!LinuxImageManager.isBootable(stamp: String(minimum - 1)))
        #expect(!LinuxImageManager.isBootable(stamp: String(current + 1)))
        #expect(!LinuxImageManager.isBootable(stamp: "garbage"))
        let (unstamped, d1) = try manager(stamp: nil)
        defer { try? FileManager.default.removeItem(at: d1) }
        #expect(!unstamped.bootableImageExists)
        let (noFiles, d2) = try manager(stamp: LinuxImageManager.imageVersion, bootFiles: false)
        defer { try? FileManager.default.removeItem(at: d2) }
        #expect(!noFiles.bootableImageExists)
    }
}
