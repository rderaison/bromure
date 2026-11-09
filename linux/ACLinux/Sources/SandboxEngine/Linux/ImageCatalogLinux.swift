import Foundation

/// The browser image's resource bundle, for ImageDistribution.browser's
/// baseline (macOS: LinuxImageManager, the Bromure Web image manager,
/// which this build doesn't have). Bromure Web isn't on Linux: the
/// browser channel has no bundled baseline here, so it loads the empty
/// fallback catalog.
// @port-skip linux-only: stand-in for LinuxImageManager.resourceBundle (Bromure Web's image manager isn't ported)
enum LinuxImageManager {
    static let resourceBundle = Bundle.main
}
