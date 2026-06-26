import Foundation

/// Installs/removes a per-user LaunchAgent that starts the headless `bromure-ac`
/// agent at login, so profiles flagged `bootAtStartup` come up automatically.
///
/// We only write/remove the plist file: launchd auto-loads `~/Library/
/// LaunchAgents/*.plist` at the next login, so the change takes effect then —
/// without `launchctl load`-ing it now (which, with `RunAtLoad`, would spawn a
/// redundant agent into the already-running session).
///
/// This is the reliable, no-admin path. A true *before-login* boot would need a
/// system LaunchDaemon in `/Library/LaunchDaemons` (root-owned, admin to
/// install) running the VM headless with no GUI session — left as a follow-up
/// because VZ-in-a-daemon is unverified and the install needs elevation.
enum BootLaunchAgent {
    static let label = "io.bromure.agentic-coding.boot"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Install the LaunchAgent when any profile wants startup boot, else remove
    /// it. `agentExecutable` is this app's binary (the thing launchd should run).
    static func reconcile(wantsStartupBoot: Bool, agentExecutable: URL?) {
        wantsStartupBoot ? install(agentExecutable: agentExecutable) : uninstall()
    }

    private static func install(agentExecutable: URL?) {
        guard let exe = agentExecutable?.path else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "run", "--headless"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",   // GUI login session (VZ needs one)
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            FileHandle.standardError.write(Data(
                "[boot] LaunchAgent install failed: \(error)\n".utf8))
        }
    }

    private static func uninstall() {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        // Best-effort unload from the current session (in case a prior login
        // loaded it), then delete the file so it won't load next login.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plistURL)
    }
}
