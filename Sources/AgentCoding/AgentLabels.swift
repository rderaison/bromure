import Foundation

/// Which coding agent a tmux window's label names (the sidebar badge, the
/// session model's agent matching). Foundation only: the macOS app, iOS and
/// the Linux daemon all compile it. `BromureIcons` forwards to it.
enum AgentLabel {
    nonisolated static let knownAgents: [String] = [
        "claude", "codex", "grok", "kimi", "omp", "aider", "goose", "amp",
        "opencode", "gemini", "cursor",
    ]

    /// Process/label spellings that mean an agent we already know, mapped to
    /// its canonical `knownAgents` name. Kimi Code installs its bin as
    /// `kimi-code` (with `kimi` as the documented command) and the guest
    /// reports the foreground program truncated — `kimi-co` is what
    /// `pane_current_command` actually shows — so neither spelling matches a
    /// bare stem comparison.
    nonisolated static let agentAliases: [String: String] = [
        "kimi-code": "kimi", "kimi-co": "kimi",
    ]

    /// The foreground program a tmux window reports maps to a coding agent (and
    /// which one), so the sidebar can badge it. nil = a plain shell / other.
    ///
    /// Tolerant of the shapes the guest reports: a bare name, a path
    /// (`/usr/bin/claude`), an extension (`claude.exe`, `claude.js`), a wrapped
    /// command (`node claude`), or — once the agent sets its OSC-2 session title
    /// — the renamed form the guest publishes, `"<title> (<agent>)"`. That
    /// trailing marker is authoritative and checked FIRST: the title is free
    /// text that may itself name another tool ("Port the codex prompts
    /// (claude)"), so a scan over the whole label would pick the wrong one.
    nonisolated static func agentKind(forLabel label: String) -> String? {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        // "<session title> (<agent>)" — bromure-agentd's `_resolve_tab_name`.
        if lower.hasSuffix(")"), let open = lower.lastIndex(of: "(") {
            let marker = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            if knownAgents.contains(marker) { return marker }
            if let canonical = agentAliases[marker] { return canonical }
        }
        // Basename of the first whitespace-separated token, minus any extension.
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
        let base = (firstWord as NSString).lastPathComponent
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        if knownAgents.contains(stem) { return stem }
        if let canonical = agentAliases[stem] { return canonical }
        // Fallback: the agent name appears as a whole word somewhere in the
        // label (e.g. `node /opt/claude.js`) — word-wise, not a raw substring,
        // so "claudette" or "amplify" don't read as agents.
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
        return knownAgents.first { words.contains($0) }
    }
}
