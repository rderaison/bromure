import Foundation

extension Daemon {
    /// The workspaces set to boot at login (Profile.bootAtStartup) start
    /// with the daemon -- a server's login -- detached, as macOS's headless
    /// launch boots them; one already running (taken back) is left as it is.
    /// Once per login, as macOS's headless agent: a marker in the runtime
    /// dir (a tmpfs: XDG_RUNTIME_DIR goes at logout, /tmp at reboot) says it
    /// was done, so a daemon restart or update doesn't bring back VMs the
    /// user stopped.
    // @port ACAppDelegate.bootFlaggedProfilesAtStartup() h=cd8ca7aa075771ce @4bd8405e
    func bootFlaggedWorkspacesAtStartup() async {
        let marker = config.runtimeDir + "/booted-at-login"
        let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }   // done already this login
        close(fd)
        for profile in profileStore.loadAll() where profile.bootAtStartup {
            let key = profile.id.uuidString.lowercased()
            guard live[key] == nil, !starting.contains(key) else { continue }
            FileHandle.standardError.write(Data("bromure-ac daemon: [boot] starting '\(profile.name)' at startup\n".utf8))
            let r = await handle(ControlRequest(method: "POST", path: "/vms",
                                                body: ["profile": .string(profile.id.uuidString), "detach": true]))
            if r.status >= 300 {
                FileHandle.standardError.write(Data("bromure-ac daemon: [boot] '\(profile.name)' didn't start: \(r.body["error"]?.stringValue ?? "HTTP \(r.status)")\n".utf8))
            }
        }
    }
}
