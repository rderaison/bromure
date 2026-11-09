import Foundation
import SandboxEngine
import Testing
@testable import ACLinux

@Suite("Image catalog (Linux bake)")
struct ImageCatalogACLinuxTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the Linux AC channel is macOS's ImageDistribution.agentCoding: prefix, signing magic, cache name, baseline")
    func channelMatchesMacOS() throws {
        let mac = try String(contentsOf: Self.repo.appendingPathComponent("Sources/AgentCoding/ImageCatalogAC.swift"), encoding: .utf8)
        for literal in [#"catalogPrefix: "images/\(UbuntuImageManager.imageVersion)""#,
                        #"signingMagic: "bromure-img-catalog-v1""#,
                        #"cacheFileName: "img-catalog.json""#,
                        #"defaultSupportDirName: "BromureAC""#,
                        #"resource: "img-catalog")"#] {
            #expect(mac.contains(literal), "ImageCatalogAC.swift changed: \(literal)")
        }
        let d = ImageDistribution.agentCoding(imageVersion: "201")
        #expect(d.catalogPrefix == "images/201")
        #expect(d.signingMagic == "bromure-img-catalog-v1")
        #expect(d.cacheFileName == "img-catalog.json")
        let bundled = try ImageCatalog.parse(Data(contentsOf: Self.repo.appendingPathComponent("Sources/AgentCoding/Resources/img-catalog.json")))
        #expect(d.loadBaseline() == bundled, "the baseline is the bundled img-catalog.json")
        #expect(bundled.postinstall.count >= 6)
    }

    @Test("no signed catalog: the bake gets the baseline's steps; an unsigned cached catalog isn't adopted")
    func unsignedFallsBackToBaseline() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let d = ImageDistribution.agentCoding(imageVersion: "201")
        // An unsigned catalog in the cache, with a step of its own.
        var planted = d.loadBaseline()
        planted.postinstall.append(PostinstallStep(uuid: "00000000-0000-4000-8000-000000000001", seq: 99,
                                                   description: "planted", command: "true"))
        try JSONEncoder().encode(planted).write(to: URL(fileURLWithPath: dir + "/img-catalog.json"))
        let store = ImageCatalogStore(distribution: d, supportDir: URL(fileURLWithPath: dir))
        #expect(store.remote() == nil, "an unsigned cache isn't trusted")
        #expect(!store.isSignatureValid(planted))
        // Nothing listens on the discard port: the refresh fails.
        #expect(await store.refresh(from: URL(string: "http://127.0.0.1:9/img-catalog.json")!) == nil)
        #expect(store.effective() == d.loadBaseline())
        #expect(!store.effective().sortedSteps.contains { $0.description == "planted" })
    }

    @Test("image-state.json: what macOS writes for a local build (no image uuid, the version, the applied steps)")
    func imageState() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(ImageState.load(imageDir: dir) == nil)
        let state = BaseImageState(imageUUID: nil, version: "201", appliedStepUUIDs: ["a", "b"])
        ImageState.write(state, imageDir: dir)
        #expect(ImageState.load(imageDir: dir) == state)
        let text = try String(contentsOfFile: dir + "/image-state.json", encoding: .utf8)
        #expect(text.contains(#""appliedStepUUIDs""#) && text.contains(#""version" : "201""#))
        #expect(!text.contains("imageUUID"))
    }

    @Test("no steps: nothing staged (the bake then mounts no postinstall share)")
    func noSteps() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try InterimBake.stagePostinstall([], to: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir + "/steps"))
    }
}
