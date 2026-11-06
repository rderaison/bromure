import Crypto
import Foundation

/// The Switchboard's launch flags and its brief: what a session engine (macOS
/// or the Linux daemon) types to start one. SwitchboardEngine forwards here.
enum SwitchboardLaunch {
    /// The guest-side MCP config (staged in the meta share by SessionDisk)
    /// and the allow rule that lets its tools run without a prompt each.
    static let launchFlags = "--mcp-config \(SessionDisk.switchboardMCPConfigGuestPath) --allowedTools mcp__switchboard"
    /// What gives `tool` the switchboard MCP at launch: Claude its config
    /// file, Codex `-c` overrides (it has no project-scope config). Grok,
    /// Kimi and omp read it from the folder's project file, which the guest
    /// writes (agentd `_switchboard_mcp_setup`). No spaces inside a flag:
    /// the launcher word-splits them.
    static func launchFlags(for tool: Profile.Tool) -> String {
        switch tool {
        case .claude: return launchFlags
        case .codex:
            // env_vars: Codex filters MCP servers' environment; the shim
            // names its window from TMUX_PANE (see codexMCPConfig).
            return "-c mcp_servers.switchboard.command=\"python3\" "
                + "-c mcp_servers.switchboard.args=[\"\(SessionDisk.switchboardMCPShimGuestPath)\"] "
                + "-c mcp_servers.switchboard.env_vars=[\"TMUX\",\"TMUX_PANE\"]"
        default: return ""
        }
    }

    /// The shell line that writes the brief into the Switchboard's folder
    /// before its agent starts (AgentSessionEngine.launch). A room's
    /// Switchboard gets the room section on top of the common brief. With
    /// `token`, the session's MCP token goes beside it (SwitchboardToken),
    /// 0600, for the guest's shim to present.
    static func briefCommand(guestFolder: String, roomName: String? = nil, token: String? = nil) -> String {
        let q = "'" + guestFolder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let text = roomName.map { SwitchboardBrief.text + SwitchboardBrief.roomSection($0) } ?? SwitchboardBrief.text
        let b64 = Data(text.utf8).base64EncodedString()
        // CLAUDE.md for Claude, AGENTS.md for the others (Codex, Kimi, omp):
        // whichever agent runs finds it again after a resume.
        var cmd = "mkdir -p \(q) && echo \(b64) | base64 -d > \(q)/CLAUDE.md && cp \(q)/CLAUDE.md \(q)/AGENTS.md"
        // Hex only (a token can't carry shell syntax); written with umask 077.
        if let token, !token.isEmpty, token.allSatisfy(\.isHexDigit) {
            cmd += " && (umask 077 && printf %s \(token) > \(q)/\(SwitchboardToken.fileName).new"
                + " && mv -f \(q)/\(SwitchboardToken.fileName).new \(q)/\(SwitchboardToken.fileName))"
        }
        return cmd
    }
}

/// The Switchboard's MCP (vsock 5836) answers only its own session: the
/// caller's tmux window has to be the Switchboard's, and it has to present
/// that session's token, which the host writes into the Switchboard's folder
/// at each launch (0600, `.bromure-switchboard-token`; never on a command
/// line or in an environment). The token is HMAC-SHA256(host key, session
/// id): nothing to store, and a token can't be turned into another session's.
///
/// It's still a secret held by the guest's user: it stops an unrelated agent
/// tab that only guesses or claims a window index, not one that goes looking
/// for the file (every agent in the guest runs as the same user).
// TODO: bind the Switchboard's MCP connection host-side to the process in
// its tmux pane, which agentd can vouch for (it knows which pid runs in which
// window); a token readable by the guest's user can't keep out an agent of
// that user that reads it.
enum SwitchboardToken {
    static let fileName = ".bromure-switchboard-token"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?
    /// Where the key lives instead of the support folder (tests); setting it
    /// forgets the key in memory.
    nonisolated(unsafe) static var keyFolder: URL? {
        didSet { lock.lock(); cachedKey = nil; lock.unlock() }
    }

    /// This host's key: 32 random bytes, made once, 0600 in its support folder
    /// (macOS Application Support; on Linux the daemon's user's data folder).
    static func key() -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cachedKey { return k }
        let dir = keyFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
        let url = dir.appendingPathComponent("switchboard-token.key")
        if let d = try? Data(contentsOf: url), d.count == 32 {
            cachedKey = SymmetricKey(data: d)
            return cachedKey!
        }
        let k = SymmetricKey(size: .bits256)
        let bytes = k.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Written whole beside it, then linked into place: link() fails when
        // another process made the key first, and then theirs is used.
        let tmp = url.appendingPathExtension("new.\(getpid())")
        _ = FileManager.default.createFile(atPath: tmp.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        _ = link(tmp.path, url.path)
        _ = unlink(tmp.path)
        if let d = try? Data(contentsOf: url), d.count == 32 { cachedKey = SymmetricKey(data: d) } else { cachedKey = k }
        return cachedKey!
    }

    /// The Switchboard session's token (hex).
    static func token(for sessionID: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(sessionID.uuidString.uppercased().utf8), using: key())
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `presented` is the session's token (compared in constant time).
    static func matches(_ presented: String?, sessionID: UUID) -> Bool {
        guard let presented, !presented.isEmpty else { return false }
        let want = Array(token(for: sessionID).utf8), got = Array(presented.utf8)
        guard want.count == got.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<want.count { diff |= want[i] ^ got[i] }
        return diff == 0
    }

    /// The window and the token of a shim's hello, `w<index> t<token>`.
    static func parseHello(_ hello: String?) -> (window: Int?, token: String?) {
        let parts = (hello ?? "").split(separator: " ").map(String.init)
        // "w<index>", as DelegationMCPServer.windowIndex(fromHello:) reads it.
        let window = parts.first.flatMap { $0.hasPrefix("w") ? Int($0.dropFirst()) : nil }.flatMap { $0 >= 0 ? $0 : nil }
        let token = parts.dropFirst().first { $0.hasPrefix("t") }.map { String($0.dropFirst()) }
        return (window, token)
    }
}

/// Which model a transcript names (the session header's model), read from
/// the raw bytes. TranscriptSearchIndex forwards here.
enum TranscriptModelSniff {
    /// The model `data` (a chat's buffer) last names, as the index reads it.
    static func liveModel(in data: Data) -> String? {
        codexModel(data) ?? model(in: data)
    }

    /// The last model the agent logged: Claude's per-message `"model"`,
    /// Codex's turn context, Kimi's `modelAlias`. Placeholders an agent
    /// logs in the model slot (Claude's `<synthetic>`, Kimi's internal
    /// "agent-loop") are skipped.
    static func model(in data: Data) -> String? {
        if let m = model(inText: String(decoding: data.suffix(2_000_000), as: UTF8.self)) { return m }
        // A long journal whose model is only named at its start (Kimi's
        // `profile.bind`): its head.
        guard data.count > 2_000_000 else { return nil }
        return model(inText: String(decoding: data.prefix(512_000), as: UTF8.self))
    }

    static func model(inText raw: String) -> String? {
        func last(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let all = re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            for m in all.reversed() {
                guard let r = Range(m.range(at: 1), in: raw) else { continue }
                let v = String(raw[r])
                if !placeholderModels.contains(v.lowercased()) { return v }
            }
            return nil
        }
        // An assistant message's own model first: a bare "model" key can
        // just as well sit in a tool's input or a file the agent read.
        return last(#""message"\s*:\s*\{\s*"model"\s*:\s*"([^"<]{2,80})""#)
            // Grok: its turn's usage, keyed by model ("modelUsage":{"grok-4.7-build":…}).
            ?? last(#""modelUsage"\s*:\s*\{\s*"([^"<]{2,80})"\s*:"#)
            ?? last(#""modelAlias"\s*:\s*"([^"<]{2,80})""#)
            ?? last(#""model"\s*:\s*"([^"<]{2,80})""#)
    }

    /// Codex: the model of its latest `turn_context` (a mid-session
    /// `/model` starts a new one) — never a "model" key in a tool's input.
    static func codexModel(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(65_536), as: UTF8.self)
        guard ["\"type\":\"session_meta\"", "\"type\":\"turn_context\"", "\"type\":\"response_item\""]
            .contains(where: head.contains) else { return nil }
        return CodexTranscriptParser.latestModel(data.suffix(4_000_000))
    }

    /// Values agents put in a model field that name no model.
    static let placeholderModels: Set<String> = ["agent-loop", "synthetic", "unknown", "default"]
}

enum SwitchboardKeys {
    /// Named keys a session's tab may be sent: enough to answer a TUI prompt,
    /// nothing that can smuggle arbitrary text or escape sequences.
    static let allowed: Set<String> = [
        "Enter", "Escape", "Tab", "BTab", "Space", "BSpace", "Up", "Down", "Left", "Right",
        "C-c", "y", "n", "a", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]
}
