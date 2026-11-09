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
        let dir = URL(fileURLWithPath: stateDir + "/ocsf", isDirectory: true)
        makeDirectory(dir)
        return dir
    }

    /// The export's directory, made 0700 if missing (also one deleted while
    /// the daemon runs: record makes it again through here).
    // @port-skip linux-only: the export's directory, 0700 (macOS: OCSFExporter.makeDirectory, the umask's)
    static func makeDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// `<state>/ocsf` (macOS: Application Support/BromureAC/ocsf).
    // @port-skip linux-only: the export's default directory (macOS: OCSFExporter.defaultDirectory, Application Support)
    static var defaultDirectory: URL { linuxDefault }
}
