import Foundation

/// Claude Code hooks for sessions this host launches, passed with
/// `--settings` so the user's own ~/.claude/settings.json is never edited.
/// Same events and states as bromure-ac's managed hooks (Profile.swift):
/// prompt/tool → working, Stop → done, Notification → needsInput, plus the
/// AskUserQuestion dump a remote reader shows while the picker is up.
enum ClaudeHooks {
    static func writeSettings() {
        let exe = shellQuote(AgentHostPaths.stableExecutable)
        func hook(_ state: String) -> [String: Any] {
            ["hooks": [["type": "command", "command": "\(exe) __hook \(state)"]]]
        }
        let pq = "\"$HOME/.bromure/pq-$(pwd | tr './' '--').json\""
        let pqPre: [String: Any] = ["matcher": "AskUserQuestion", "hooks":
            [["type": "command", "command": "mkdir -p ~/.bromure && cat > " + pq]]]
        let pqClear: [String: Any] = ["hooks": [["type": "command", "command": "rm -f " + pq]]]
        var pqPost = pqClear
        pqPost["matcher"] = "AskUserQuestion"
        let settings: [String: Any] = [
            // Agent-to-agent traffic never waits on a permission prompt, nor
            // do the files other agents hand over (~/.bromure/inbox): read,
            // listed and unpacked unprompted — running one still goes through
            // the approval mode. The rules bromure-ac seeds in its workspaces.
            "permissions": [
                "allow": ["mcp__delegation", "Read(~/.bromure/inbox/**)", "Edit(~/.bromure/inbox/**)"],
                "additionalDirectories": ["~/.bromure/inbox"],
            ],
            "hooks": [
                "SessionStart": [hook("done")],
                "UserPromptSubmit": [hook("working")],
                "PreToolUse": [hook("working"), pqPre],
                "PostToolUse": [pqPost],
                "Stop": [hook("done"), pqClear],
                "Notification": [hook("needsInput")],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: AgentHostPaths.claudeSettings, options: .atomic)
        }
        // The delegation MCP: this binary, relaying to a connected Bromure AC.
        let mcp: [String: Any] = ["mcpServers": ["delegation": [
            "command": AgentHostPaths.stableExecutable, "args": ["__mcp-delegation"], "alwaysLoad": true]]]
        if let data = try? JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: AgentHostPaths.claudeMCPConfig, options: .atomic)
        }
    }

    /// `bromure-sidecar __hook <state>`, run by Claude inside its tmux
    /// pane: tag the window with the status and the transcript Claude
    /// reported on stdin, and pin the transcript where a fat client's chat
    /// view looks for it (`~/.bromure/transcript-<idx>.path`: the path, then
    /// "<pane id> <boot id>" — no boot id on macOS, so it's empty there too).
    static func runHook(state: String) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let pane = env["TMUX_PANE"], !pane.isEmpty else { return 0 }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        // Claude's Notification fires for more than questions: idle_prompt
        // comes after the agent merely sat at its prompt for a while — that
        // is "done", not "needs you" (which also holds delegation notices
        // back). Only a real prompt is needsInput; other notices (auth,
        // quota…) say nothing about the turn. As bromure-ac's guest hook.
        var state = state
        if state == "needsInput", let type = json["notification_type"] as? String, !type.isEmpty {
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": break
            case "idle_prompt": state = "done"
            default: return 0
            }
        }
        let transcript = json["transcript_path"] as? String ?? ""
        let agentSession = json["session_id"] as? String ?? ""

        var args = ["set-option", "-w", "-t", pane, "@bromure_status", state]
        if !transcript.isEmpty {
            args += [";", "set-option", "-w", "-t", pane, "@bromure_transcript", transcript]
        }
        if !agentSession.isEmpty {
            args += [";", "set-option", "-w", "-t", pane, "@bromure_agent_session", agentSession]
        }
        Tmux.run(args, timeout: 5)

        if !transcript.isEmpty {
            let r = Tmux.run(["display-message", "-p", "-t", pane, "#{window_index} #{pane_id}"], timeout: 5)
            let parts = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            if parts.count == 2 {
                let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bromure")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let record = "\(transcript)\n\(parts[1]) \n"
                try? record.write(to: dir.appendingPathComponent("transcript-\(parts[0]).path"),
                                  atomically: true, encoding: .utf8)
            }
        }
        return 0
    }
}
