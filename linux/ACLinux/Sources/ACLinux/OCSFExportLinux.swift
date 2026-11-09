import Foundation

/// The OCSF export on a server: on and configured with macOS's own keys
/// (OCSFExporter.enabledKey and the others), which Foundation keeps on
/// Linux in `$XDG_CONFIG_HOME/bromure-ac.plist` (`~/.config/bromure-ac.plist`;
/// a multi-user daemon's HOME is its state dir:
/// `/var/lib/bromure-ac/<user>/.config/bromure-ac.plist`). Unless a
/// directory is set, it goes to the daemon's own state dir.
extension OCSFExporter {
    private static let linuxDefault = makeDefaultDirectory(stateDir: DaemonConfig.fromEnvironment().stateDir)

    /// `stateDir`/ocsf, made 0700 if missing: one user's events (a user-set
    /// directory is written as that user's daemon, under its permissions).
    // @port-skip linux-only: the export's default directory
    static func makeDefaultDirectory(stateDir: String) -> URL {
        let dir = stateDir + "/ocsf"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    /// `<state>/ocsf` (macOS: Application Support/BromureAC/ocsf).
    // @port-skip linux-only: the export's default directory (macOS: OCSFExporter.defaultDirectory, Application Support)
    static var defaultDirectory: URL { linuxDefault }
}
