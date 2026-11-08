import Foundation

/// How an agent is interrupted in its pane: the composer's Stop and the
/// Switchboard's phone STOP send the same key.
enum AgentInterrupt {
    /// The tmux key that interrupts this agent: what its busy line says, else
    /// what its kind takes (Grok: Ctrl-C; the others: Esc).
    static func key(screen: String, agent: String?) -> String {
        for raw in screen.split(whereSeparator: \.isNewline).suffix(14).reversed() {
            let l = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if l.contains("ctrl+c to interrupt") || l.contains("ctrl-c to interrupt") { return "C-c" }
            if l.contains("esc to interrupt") { return "Escape" }
            if l.hasSuffix("[stop]") || l == "[stop]" { return "C-c" }   // Grok's busy line
        }
        return agent == "grok" ? "C-c" : "Escape"
    }
}
