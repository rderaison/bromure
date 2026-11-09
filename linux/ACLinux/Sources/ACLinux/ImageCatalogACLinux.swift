import Foundation
import SandboxEngine

extension ImageDistribution {
    /// The Bromure Agentic Coding channel for an image major, as macOS's
    /// `ImageDistribution.agentCoding` (ImageCatalogAC.swift) binds it: the
    /// `images/<major>/` prefix, the AC signing magic and the bundled
    /// img-catalog.json baseline. The major is the bake's image version
    /// (macOS: UbuntuImageManager.imageVersion, which this build doesn't
    /// have). ImageCatalogACLinuxTests pins these values to macOS's.
    // @port-skip linux-only: ImageDistribution.agentCoding with the image version passed in (UbuntuImageManager isn't in this build)
    public static func agentCoding(imageVersion: String) -> ImageDistribution {
        ImageDistribution(
            catalogPrefix: "images/\(imageVersion)",
            signingMagic: "bromure-img-catalog-v1",
            cacheFileName: "img-catalog.json",
            defaultSupportDirName: "BromureAC",
            loadBaseline: {
                ImageCatalog.loadBaseline(bundle: acResourceBundle, resource: "img-catalog")
            }
        )
    }
}

/// The image's state sidecar, `image-state.json` next to the version stamp
/// (macOS: UbuntuImageManager.imageStateURL, loadImageState and
/// writeImageState).
enum ImageState {
    // @port UbuntuImageManager.loadImageState() h=df7ba5dab3b9e7a1 @84e171b8
    static func load(imageDir: String) -> BaseImageState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: imageDir + "/image-state.json")) else { return nil }
        return try? JSONDecoder().decode(BaseImageState.self, from: data)
    }

    /// Best-effort persist: the state is advisory (it only gates prompts,
    /// never whether the image boots), so a write failure must not fail a
    /// build that already promoted successfully.
    // @port UbuntuImageManager.writeImageState(_: BaseImageState) h=68070be3f001c6a3 @84e171b8
    static func write(_ state: BaseImageState, imageDir: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: imageDir + "/image-state.json"), options: .atomic)
        }
    }
}
