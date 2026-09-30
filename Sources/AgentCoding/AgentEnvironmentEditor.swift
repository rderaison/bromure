import SwiftUI

// MARK: - Describe your environment (Preferences → Environment)
//
// The user's own facts about their world — which servers are what, which
// changes are theirs to make — one per line, written into every workspace's
// Claude auto-mode settings (see ClaudeAutoMode) so its safety classifier
// tells routine work from risky actions. Global: the same for every
// workspace, this Mac's or a remote server's.

struct AgentEnvironmentEditor: View {
    @Binding var text: String

    static let example = """
        Organization: Acme Corp — software development
        staging.acme.dev is our staging server: deploys and changes there are fully authorized
        prod.acme.com is production: never change anything there without asking me first
        Source control: github.com/acme — pushing to any branch is fine
        Trusted internal domains: *.acme.internal, api.acme.dev
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe your environment").font(.headline)
            Text("What your agents' safety checks should know about your world: your organization, your servers and what they're for, the repositories and domains you trust, what's safe to change. One fact per line. Claude's auto mode reads them to tell routine work from risky actions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 120, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.platformTextBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: Self.example)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            Text("Applies to every workspace from its next launch.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// This Mac's: saved into the global model settings as it's typed.
struct GlobalAgentEnvironmentEditor: View {
    @ObservedObject var store = ModelSettingsStore.shared
    var body: some View {
        AgentEnvironmentEditor(text: Binding(
            get: { store.settings.agentEnvironment },
            set: { v in store.update { $0.agentEnvironment = v } }))
    }
}
