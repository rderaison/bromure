import Crypto
import Foundation

/// The daemon as the host of a workspace's save (macOS: ProfileEdits+App.swift):
/// create, PUT and PATCH from a fat client or the CLI run the shared
/// ProfileEditHost.automationUpsertProfile.
extension LinuxSessionHost: ProfileEditHost {
    /// The workspaces, read from the store each time (the daemon keeps no
    /// list of its own); a set is the save's own reload, nothing to keep.
    // @port-skip linux-only: the daemon reads ProfileStore directly (macOS: the app's profiles array)
    var profiles: [Profile] {
        get { ProfileStore().loadAll() }
        set {}
    }
    // @port-skip linux-only: the daemon's ProfileStore
    var store: ProfileStore { ProfileStore() }
    /// A server has no Terminal preferences: the defaults (as its seeds).
    // @port-skip linux-only: no terminal preferences on a server
    var terminalDefaults: TerminalAppDefaults { .fallback }
    // @port-skip linux-only: the daemon's proxy salt
    var fakeTokenSalt: Data? { daemon?.mitm?.fakeTokenSalt }

    // @port-skip linux-only: Daemon.workspace (macOS: profileByNameOrID over the app's list)
    func profileByNameOrID(_ key: String) -> Profile? { Daemon.workspace(key) }

    /// The save's token plan: Claude's subscription bogus key registered,
    /// the OAuth stand-in with account features (Daemon.sessionTokenPlan).
    // @port-skip linux-only: Daemon.sessionTokenPlan over the proxy's store (macOS: ACAppDelegate.sessionTokenPlan)
    func sessionTokenPlan(for profile: Profile, salt: Data) -> SessionTokenPlan {
        let mitm = daemon?.mitm
        let available = mitm?.claudeStore.hasCredential(for: profile.id) ?? false
        var plan = profile.makeTokenPlan(salt: salt, claudeSubscriptionAvailable: available)
        if let bogus = plan.claudeSubscriptionBogusKey {
            mitm?.claudeStore.registerBogusKey(bogus, for: profile.id)
            if ClaudeStandIn.isEnabled {
                plan.claudeOAuthStandIn = ClaudeStandIn.credentialsJSON(ClaudeStandIn.mint(profileID: profile.id))
            }
        }
        return plan
    }

    /// A fresh ed25519 key in the workspace's host-only agent dir
    /// (`id_ed25519.raw`: seed + public, 0600) and its OpenSSH public key.
    // partial: the VM home's id_ed25519.pub copy is macOS's virtiofs-home path (an ext4 home gets it from the seed)
    // @port ACAppDelegate.makeSSHKey(in: URL) h=87376ec31c91ab04 @2f4772cf
    func makeSSHKey(in dir: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation             // 32 bytes
        let pub  = key.publicKey.rawRepresentation   // 32 bytes
        var raw = Data()
        raw.append(seed)
        raw.append(pub)
        let rawURL = dir.appendingPathComponent("id_ed25519.raw")
        try raw.write(to: rawURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: rawURL.path)
        func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        let label = "ssh-ed25519"
        var blob = Data()
        blob.append(u32(UInt32(label.utf8.count)))
        blob.append(Data(label.utf8))
        blob.append(u32(UInt32(pub.count)))
        blob.append(pub)
        let pubText = "ssh-ed25519 \(blob.base64EncodedString()) bromure-ac"
        try pubText.write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        return pubText
    }

    /// An edit lands at the workspace's next boot here: the meta share and
    /// home seed are staged at launch.
    // partial: no live edit of a running workspace on Linux (applies at its next boot)
    /// A running workspace's edit: its trace level applies at once (the
    /// proxy reads it per request), its session id kept so the trace isn't
    /// split (macOS: applyLiveSessionRefresh's trace step).
    // partial: only the trace level is applied live on Linux; the rest waits for the next launch
    // @port ACAppDelegate.applyLiveSessionRefresh(from: Profile, to: Profile, terminalDefaults: TerminalAppDefaults, window: SessionPane?, sandbox: UbuntuSandboxVM?) h=ca482e2c12f5ab30 @7057d502
    func applyLiveEditToRunningSession(_ new: Profile) {
        guard let mitm = daemon?.mitm, let cur = mitm.sessionTrace(for: new.id),
              cur.level != new.traceLevel else { return }
        mitm.setSessionTrace(TraceSession(sessionID: cur.sessionID, level: new.traceLevel), for: new.id)
    }

    // @port-skip linux-only: Daemon.describe's summary without the actor's VM records
    func automationProfileDescribe(_ key: String) -> [String: Any]? {
        guard let p = Daemon.workspace(key) else { return nil }
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": p.id.uuidString,
            "shortId": String(p.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)),
            "name": p.name, "color": p.color.rawValue, "tool": p.tool.rawValue,
            "authMode": p.authMode.rawValue, "apiKeySet": (p.apiKey?.isEmpty == false),
            "memoryGB": p.memoryGB, "networkMode": p.networkMode.rawValue,
            "closeAction": p.closeAction.rawValue, "bootAtStartup": p.bootAtStartup,
            "folderPaths": p.folderPaths, "mcpServers": p.mcpServers.map { $0.name },
            "sshKeySet": (p.sshPublicKey?.isEmpty == false), "importedSSHKeys": p.importedSSHKeys.count,
            "running": Self.running.withLockedValue { $0.contains(p.id) },
            "comments": p.comments, "createdAt": iso.string(from: p.createdAt),
        ]
        if let last = p.lastUsedAt { d["lastUsedAt"] = iso.string(from: last) }
        return d
    }

    /// A save's live part (no sidebar or launch agent on a server): the
    /// prompt-injection policy, as macOS applies it to a running workspace.
    // partial: the prompt-injection policy only (macOS: the egress, supply-chain, PII and credential restage too)
    // @port-skip linux-only: no app surfaces to refresh on a server
    func profilesDidChange(saved: Profile?, editing: Profile?) {
        // A running workspace's only: a stopped one's comes with its launch
        // (and a stop clears it).
        guard let saved, LinuxSessionHost.running.withLockedValue({ $0.contains(saved.id) }) else { return }
        daemon?.mitm?.setPromptInjectionPolicy(saved.promptInjection, for: saved.id)
    }
}
