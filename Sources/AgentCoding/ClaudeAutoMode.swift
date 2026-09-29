import Foundation

// MARK: - What Claude's auto-mode classifier knows about a workspace
//
// Auto mode routes Claude Code's tool calls through a classifier that blocks
// what looks risky for an ordinary developer machine. A Bromure workspace
// isn't one, and until `autoMode.environment` says so the classifier blocks
// routine work there — reading the workspace's own (placeholder) API keys is
// "Credential Exploration" — then, three blocks in a row, pauses auto mode
// and offers `/auto-mode-setup`. Bromure writes what it knows about the VM,
// plus the user's own description (Preferences → Models), into the guest's
// ~/.claude/settings.json: agentd merges them from claude-settings.spec.json
// (ext4 homes), ProfileStore directly (virtiofs homes).

enum ClaudeAutoMode {
    /// Ends every entry Bromure writes: what the merge replaces on the next
    /// launch. Everything else in the list (the user's own) is left alone.
    static let tag = "[managed by Bromure]"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _userText = ""

    /// The user's description of their environment (the global Models
    /// settings), kept here so staging — off the main actor — can read it.
    static var userText: String {
        get { lock.lock(); defer { lock.unlock() }; return _userText }
        set { lock.lock(); _userText = newValue; lock.unlock() }
    }

    /// The entries for a workspace VM: Bromure's own, then one per line of
    /// the user's description.
    static func environment(userText: String) -> [String] {
        var out = [
            "Host containment: Claude Code runs inside a Bromure Agentic Coding workspace — a Linux VM on the user's Mac, dedicated to this workspace, with its own disk. Its network traffic leaves through the Mac's Bromure proxy, which applies the workspace's network policy. The agent works under the user's identity for this workspace: the SSH keys and the git, cloud, cluster and registry credentials in the VM (~/.ssh, ~/.git-credentials, ~/.aws, ~/.kube, ~/.docker, gh) were put there by the user for the agent's tasks. API keys and tokens in the environment (ANTHROPIC_API_KEY, OPENAI_API_KEY, AWS_BEARER_TOKEN_BEDROCK and the like) are placeholders: the proxy swaps the real secrets in on the wire, so reading them reveals nothing. \(tag)",
            "Key internal services: the Bromure host behind the VM's default gateway and its vsock serves the agent's MCP tools (delegation, display, browser, task board, infrastructure); using them is routine. Files under ~/.bromure/inbox were sent by the user or by their other agents through Bromure. \(tag)",
        ]
        for line in userText.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append("\(t) \(tag)") }
        }
        return out
    }

    /// `settings.autoMode.environment` with Bromure's entries replaced by
    /// `managed`. A list the user never wrote starts from `$defaults` (the
    /// built-in entries); one they wrote keeps its choice about them.
    static func merged(_ existing: Any?, managed: [String]) -> [Any] {
        var env: [Any] = (existing as? [Any]) ?? ["$defaults"]
        env.removeAll { ($0 as? String)?.hasSuffix(tag) == true }
        return env + managed
    }
}
