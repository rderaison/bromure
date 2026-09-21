import Foundation
import SandboxEngine
import Testing
@testable import bromure_ac

// The "base image update available" nag: fires only for an installed image
// whose major is OLDER than the app's — never for a newer one (images stay
// backward compatible, and nagging about a newer image sent users in
// circles) and never for a revision of the bundled major.

@Suite("Base image update check")
struct BaseImageUpdateCheckTests {

    /// A storage dir holding just enough for `hasBaseImage` plus a stamp.
    private func manager(stamp: String) throws -> (UbuntuImageManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-imgcheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["base.img", "efivars.bin"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        try (stamp + "\n").write(to: dir.appendingPathComponent("base.version"),
                                 atomically: true, encoding: .utf8)
        return (UbuntuImageManager(storageDir: dir, setupDir: dir), dir)
    }

    @Test("older major nags, same/newer major and revisions don't")
    func olderOnly() throws {
        let bundled = try #require(Int(UbuntuImageManager.imageVersion))
        for (stamp, expected) in [
            ("\(bundled - 1)", true),
            ("\(bundled - 1).7", true),
            ("\(bundled)", false),
            ("\(bundled).3", false),
            ("\(bundled + 1)", false),
            ("\(bundled + 1).2", false),
        ] {
            let (m, dir) = try manager(stamp: stamp)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(m.baseImageNeedsUpdate == expected, "stamp \(stamp)")
        }
    }

    @Test("AC catalog channel is per image major, never the pre-5.0 unversioned path")
    func acChannelIsPerMajor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-accat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let major = UbuntuImageManager.imageVersion
        #expect(Int(major) ?? 0 >= 201)
        #expect(ImageDistribution.agentCoding.catalogPrefix == "images/\(major)")
        let store = ImageCatalogStore(distribution: .agentCoding, supportDir: dir)
        #expect(store.refreshURL.absoluteString
            == "https://dl.bromure.io/images/\(major)/img-catalog.json")
    }

    @Test("the baked-agent gate follows the installed major")
    func agentGate() throws {
        let baked = UbuntuImageManager.agentUnitBakedImageVersion
        for (stamp, expected) in [
            ("\(baked - 1).9", false),
            ("\(baked)", true),
            ("\(baked).1", true),
            ("\(baked + 5)", true),
        ] {
            let (m, dir) = try manager(stamp: stamp)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(m.baseImageStartsAgentItself == expected, "stamp \(stamp)")
        }
    }
}
