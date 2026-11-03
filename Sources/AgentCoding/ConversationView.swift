#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: - View

/// Chat-style render of a parsed `Conversation`. Bubbles per message,
/// special blocks for tool_use / tool_result, monospace for code.
struct ConversationView: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 10) {
                    if let env = conversation.requestEnvelope, !env.isEmpty {
                        RequestEnvelopeBubble(json: env)
                    }
                    if let sys = conversation.systemPrompt, !sys.isEmpty {
                        SystemBubble(text: sys)
                    }
                    ForEach(conversation.messages) { msg in
                        MessageBubble(message: msg)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: providerIcon)
                .foregroundStyle(.secondary)
            Text(providerLabel)
                .font(.subheadline.weight(.semibold))
            if let model = conversation.model {
                Text(model)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12),
                                in: Capsule())
            }
            Spacer()
            if let inT = conversation.inputTokens {
                Label("\(inT) in", systemImage: "arrow.down")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if let outT = conversation.outputTokens {
                Label("\(outT) out", systemImage: "arrow.up")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var providerLabel: String {
        switch conversation.provider {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .gemini:    return "Google Gemini"
        case .cohere:    return "Cohere"
        case .unknown:   return "AI conversation"
        }
    }
    private var providerIcon: String {
        "sparkles"
    }
}

/// The original request envelope (the response.create event, the
/// /v1/responses POST body, etc.) shown as a collapsible JSON
/// preview at the top of the conversation. Surfaces fields the
/// per-provider parsers don't promote to system / messages so the
/// user can audit `tools`, `tool_choice`, `metadata`, vendor
/// extensions, and the WS event envelope itself.
private struct RequestEnvelopeBubble: View {
    let json: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Request", systemImage: "tray.and.arrow.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $expanded) {
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } label: {
                Text(expanded ? "Hide JSON" : "Show JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

private struct SystemBubble: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("System prompt", systemImage: "gear")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                )
        }
    }
}

private struct MessageBubble: View {
    let message: Conversation.Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 60)
                bubble(alignment: .trailing)
            } else {
                bubble(alignment: .leading)
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(roleLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { (_, block) in
                    BlockView(block: block)
                }
                if message.content.isEmpty {
                    Text("(empty)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(10)
            .frame(maxWidth: 720, alignment: .leading)
            .background(bubbleBackground,
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user:       return "You"
        case .assistant:  return "Assistant"
        case .system:     return "System"
        case .tool:       return "Tool"
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:       return Color.accentColor.opacity(0.18)
        case .assistant:  return Color.secondary.opacity(0.10)
        case .system:     return Color.secondary.opacity(0.06)
        case .tool:       return Color.purple.opacity(0.10)
        }
    }
}

private struct BlockView: View {
    let block: Conversation.Block

    var body: some View {
        switch block {
        case .text(let s):
            Text(prettyText(s))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let s):
            Text(prettyText(s))
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let name, let input, _):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(name)
                        .font(.caption.weight(.semibold).monospaced())
                }
                .foregroundStyle(.purple)
                if !input.isEmpty {
                    Text(input)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.purple.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .toolResult(_, let content, let isError):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: isError
                          ? "xmark.octagon.fill"
                          : "checkmark.seal.fill")
                    Text(isError
                         ? NSLocalizedString("Tool error", comment: "")
                         : NSLocalizedString("Tool result", comment: ""))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(isError ? .red : .green)
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        (isError ? Color.red : Color.green).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            }
        case .image(let mediaType):
            HStack(spacing: 4) {
                Image(systemName: "photo")
                Text("\(mediaType) attachment")
                    .font(.caption.italic())
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Trim trailing whitespace per-line so streaming-assembled deltas
    /// don't look ragged. Preserves markdown-y formatting otherwise —
    /// we leave actual markdown rendering for later.
    private func prettyText(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces.subtracting(.init(charactersIn: ""))) }
            .joined(separator: "\n")
    }
}
