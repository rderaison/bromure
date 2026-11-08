import Foundation

/// How big a new workspace home is made when it has no size of its own:
/// scaled to the free space it will draw on (the image is sparse, but its
/// size is how far the guest can fill the host's disk). The macOS app
/// (SessionDisk) and the Linux daemon size new homes by the same rule.
enum HomeImageSizing {
    /// The largest a new home gets, GiB, unless a setting says otherwise.
    static let defaultGB = 16

    /// A new home's size for the free space it will draw on:
    ///   < 64 GB free  →  8 GB
    ///   < 128 GB free → 12 GB
    ///   otherwise     → 16 GB (`defaultGB`)
    /// 8 GB is the floor (`ProfileEditorView.minHomeGB`): the agents' CLIs, a
    /// toolchain and one project's dependencies already take several.
    static func scaledGB(freeBytes: UInt64?) -> Int {
        guard let freeBytes else { return defaultGB }
        let gb = freeBytes >> 30
        if gb < 64 { return 8 }
        if gb < 128 { return 12 }
        return defaultGB
    }
}
