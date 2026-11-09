import Foundation

/// A script of the user's, run as root inside the base image after
/// Bromure's setup and the agent installs, so every workspace created or
/// reset from the image has their toolchain; applied on every full build
/// (macOS: BaseImageCustomize in BromureAC.swift, set up from File →
/// Rebuild Base Image). Here its defaults are the daemon's
/// (~/.config/bromure-ac.plist).
// @port-skip linux-only: container of BaseImageCustomize's port (BromureAC.swift isn't shared)
public enum BaseImageCustomize {
    static let enabledKey = "image.customizeScript.enabled"
    static let pathKey = "image.customizeScript.path"

    /// The script to run (nil: off), or why it couldn't be read.
    // @port BaseImageCustomize.static load(defaults: UserDefaults) h=45433c61f397564c @4237c02e
    public static func load(defaults: UserDefaults = .standard) -> (script: String?, problem: String?) {
        guard defaults.bool(forKey: enabledKey) else { return (nil, nil) }
        let path = (defaults.string(forKey: pathKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return (nil, nil) }
        guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, String(format: NSLocalizedString("Your customize script (%@) can't be read — the image is built without it.", comment: "base image customize"), path))
        }
        return (text, nil)
    }
}
