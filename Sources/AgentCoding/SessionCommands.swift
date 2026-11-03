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
    /// Switchboard gets the room section on top of the common brief.
    static func briefCommand(guestFolder: String, roomName: String? = nil) -> String {
        let q = "'" + guestFolder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let text = roomName.map { SwitchboardBrief.text + SwitchboardBrief.roomSection($0) } ?? SwitchboardBrief.text
        let b64 = Data(text.utf8).base64EncodedString()
        // CLAUDE.md for Claude, AGENTS.md for the others (Codex, Kimi, omp):
        // whichever agent runs finds it again after a resume.
        return "mkdir -p \(q) && echo \(b64) | base64 -d > \(q)/CLAUDE.md && cp \(q)/CLAUDE.md \(q)/AGENTS.md"
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
