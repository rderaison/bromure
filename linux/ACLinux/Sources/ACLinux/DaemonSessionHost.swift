import Foundation

/// What the shared agent-session engine asks of its host (macOS: the app
/// delegate), done the daemon's way: a workspace is a VM record, its shell
/// is GuestShell. Shaped after ACAppDelegate's members; the AgentSessionHost
/// conformance wraps these once that protocol lands.
extension Daemon {
    /// A command in a workspace's guest failed to run, or ran and failed.
    enum GuestCommandError: Error, CustomStringConvertible {
        case unavailable(String)
        case failed(exitCode: Int, stderr: String)
        // @port-skip linux-only: guest exec errors
        var description: String {
            switch self {
            case .unavailable(let why): return why
            case .failed(let code, let err): return "exit \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// `command` in the workspace's guest (bash, as the workspace user); its
    /// stdout. A non-zero exit throws with stderr, as on macOS.
    // @port-skip linux-only: ACAppDelegate.guestExec over VZ vsock; this one is GuestShell's
    func guestExec(profileID: UUID, command: String, timeout: Int = 30) async throws -> String {
        // An attached machine (Bromure Sidecar) runs it on that machine: the
        // board's worktree lookups and reviews reach its sessions too.
        if let out = try await LinuxMachines.exec(profileID: profileID, command: command, timeout: timeout) {
            return out
        }
        guard let l = live.first(where: { $0.key.caseInsensitiveCompare(profileID.uuidString) == .orderedSame })?.value else {
            throw GuestCommandError.unavailable("workspace \(profileID.uuidString.prefix(8)) isn't running")
        }
        let r = try await l.shell.exec(command, timeout: timeout, wait: .seconds(10))
        guard r.exitCode == 0 else { throw GuestCommandError.failed(exitCode: r.exitCode, stderr: r.stderr) }
        return r.stdout
    }

    /// One native file op (`{"file": {...}}`, the file browser's data plane)
    /// in the workspace's guest: agentd's reply as it came. The op failing
    /// in the guest throws with its error, as on macOS.
    // @port-skip linux-only: ACAppDelegate.guestFileOp over VZ vsock; this one is GuestShell's
    func guestFileOp(profileID: UUID, op: [String: Any], timeout: Int = 30) async throws -> [String: Any] {
        guard let l = live.first(where: { $0.key.caseInsensitiveCompare(profileID.uuidString) == .orderedSame })?.value else {
            throw GuestCommandError.unavailable("workspace \(profileID.uuidString.prefix(8)) isn't running")
        }
        let o = try await l.shell.request(["file": op, "timeout": timeout], wait: .seconds(10))
        if let err = o["error"] as? String {
            throw GuestCommandError.failed(exitCode: o["exit_code"] as? Int ?? 1, stderr: err)
        }
        return o
    }

    /// Boots the workspace's VM if it isn't running (macOS: startProfile,
    /// startProfileQuietly, startProfileRemotely, which differ only in where
    /// a boot's questions are asked; a server has no screen to ask on).
    /// Nil when it's up (or was already), else why not.
    // @port ACAppDelegate.startProfileRemotely(_: Profile.ID) h=b41392c8b01a656d @7dd92fdf
    func startWorkspace(_ id: UUID) async -> String? {
        guard let rec = registry.find(id.uuidString.lowercased()) else { return "no workspace \(id.uuidString)" }
        if rec.state == .running || live[rec.id] != nil { return nil }
        let r = await start(rec)
        return r.status < 300 ? nil : (r.body["error"]?.stringValue ?? "couldn't start (\(r.status))")
    }

    /// The workspace's guest address on the switch, while it runs: what a
    /// client's `forward <ip> <port>` dials.
    // @port-skip linux-only: the daemon's DHCP lease for a workspace
    func guestIP(_ id: UUID) -> String? {
        guard let rec = registry.find(id.uuidString.lowercased()), rec.state == .running else { return nil }
        return sw.dhcp.leasedIP(for: rec.mac)
    }

    /// Codex's login, into a running machine: the stand-in
    /// `~/.codex/auth.json` (its bogus tokens registered with the proxy).
    // @port ACAppDelegate.pushCodexAuth(profileID: UUID) h=b989b5fc6a033b6a @dd7ba30d
    func pushCodexAuth(profileID: UUID) async -> Bool {
        guard let data = codexStandInAuth(for: profileID) else { return false }
        let b64 = data.base64EncodedString()
        let out = try? await guestExec(
            profileID: profileID,
            command: "mkdir -p ~/.codex && umask 077 && echo \(b64) | base64 -d > ~/.codex/auth.json.tmp "
                + "&& mv -f ~/.codex/auth.json.tmp ~/.codex/auth.json && echo ok",
            timeout: 15)
        return out?.contains("ok") == true
    }

    /// The stand-in `~/.codex/auth.json` for a workspace's Codex login — the
    /// bogus tokens registered with the proxy — or nil when there's no login.
    // @port ACAppDelegate.codexStandInAuth(for: UUID) h=58363fc1bd492534 @dd7ba30d
    func codexStandInAuth(for profileID: UUID) -> Data? {
        guard let mitm, let real = mitm.codexStore.record(for: profileID) else { return nil }
        guard let standIn = CodexStandIn.mint(real, profileID: profileID) else {
            FileHandle.standardError.write(Data("[codex-sub] seed skipped — stored tokens aren't JWT-shaped\n".utf8))
            return nil
        }
        let bogusAccess = standIn.access, bogusID = standIn.id, bogusRefresh = standIn.refresh
        mitm.codexStore.registerBogusKey(bogusAccess, for: profileID)
        var tokens: [String: Any] = [
            "id_token": bogusID, "access_token": bogusAccess, "refresh_token": bogusRefresh,
        ]
        if let accountID = Self.codexAccountID(fromIDToken: real.idToken) {
            tokens["account_id"] = accountID
        }
        let doc: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        return try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted])
    }

    /// A launch's token plan, with Claude's subscription mode when a login
    /// is stored: its bogus key registered with the proxy, and with account
    /// features the OAuth stand-in. nil without a proxy (the guest then
    /// runs on whatever it has). The plan only, as macOS's: the swap map is
    /// set once, by the kubeconfig step (installKube) -- fresh at launch,
    /// merged on a live refresh, so a token the map already holds (an exec
    /// plugin's) is never dropped first.
    // partial: api_key.env and proxy.env are written at launch only: a live edit doesn't rewrite them or bump env.generation (macOS: refreshMetadataShare)
    // @port ACAppDelegate.sessionTokenPlan(for: Profile, salt: Data) h=71b1ca7b397c2cf6 @dd7ba30d
    func sessionTokenPlan(for profile: Profile) -> SessionTokenPlan? {
        mitm.map { Self.makeSessionTokenPlan(for: profile, mitm: $0) }
    }

    // @port-skip linux-only: sessionTokenPlan's body over a given proxy (the refresh path's, testable)
    static func makeSessionTokenPlan(for profile: Profile, mitm: MitmProxy) -> SessionTokenPlan {
        let available = mitm.claudeStore.hasCredential(for: profile.id)
        var plan = profile.makeTokenPlan(salt: mitm.fakeTokenSalt, claudeSubscriptionAvailable: available)
        if let bogus = plan.claudeSubscriptionBogusKey {
            mitm.claudeStore.registerBogusKey(bogus, for: profile.id)
            if ClaudeStandIn.isEnabled {
                plan.claudeOAuthStandIn = ClaudeStandIn.credentialsJSON(ClaudeStandIn.mint(profileID: profile.id))
            }
        }
        return plan
    }

    /// Codex subscription mode: the stand-in `~/.codex/auth.json` in the
    /// home seed's `files/` (agentd copies it into the ext4 home). No-op
    /// unless the workspace runs Codex on a subscription with a stored login.
    // @port ACAppDelegate.seedCodexAuthFile(for: Profile, homeRoot: URL?) h=803c67f8b98a1ef5 @dd7ba30d
    func seedCodexAuthFile(for profile: Profile, homeRoot: URL) {
        guard profile.allToolSpecs.contains(where: { $0.tool == .codex && $0.authMode == .subscription }),
              let data = codexStandInAuth(for: profile.id) else { return }
        let dir = homeRoot.appendingPathComponent(".codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    /// Pull `chatgpt_account_id` out of a Codex id-token JWT (best effort).
    // @port ACAppDelegate.static codexAccountID(fromIDToken: String) h=feb12e2521f81dfb @dd7ba30d
    static func codexAccountID(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let acct = auth["chatgpt_account_id"] as? String { return acct }
        return obj["chatgpt_account_id"] as? String
    }

    /// Claude with account features, into a running machine: its OAuth
    /// stand-in (`~/.claude/.credentials.json`), which the proxy swaps for
    /// the host's live token.
    // @port ACAppDelegate.pushClaudeStandIn(profileID: UUID) h=dc39248e17ca452c @5f46a841
    func pushClaudeStandIn(profileID: UUID) async -> Bool {
        guard ClaudeStandIn.isEnabled, mitm?.claudeStore.hasCredential(for: profileID) == true else { return false }
        let b64 = ClaudeStandIn.credentialsJSON(ClaudeStandIn.mint(profileID: profileID)).base64EncodedString()
        let out = try? await guestExec(
            profileID: profileID,
            command: "mkdir -p ~/.claude && chmod 700 ~/.claude && umask 077 && echo \(b64) | base64 -d > ~/.claude/.credentials.json.tmp "
                + "&& mv -f ~/.claude/.credentials.json.tmp ~/.claude/.credentials.json && echo ok",
            timeout: 15)
        return out?.contains("ok") == true
    }
}
