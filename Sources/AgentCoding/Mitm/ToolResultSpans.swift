import Foundation

/// The untrusted tool output a request carries that the prompt-injection
/// scan reads: the newest ingestion, not the whole history re-sent every
/// turn. Shared by the intercepting proxies (macOS's HTTPMitmConnection,
/// which forwards its `newToolResultSpans`, and Linux's MitmProxy).
enum ToolResultSpans {
    /// Pull the untrusted `tool_result` spans that were freshly added
    /// this turn. The request re-sends the whole history every turn, so
    /// we scan only the last message that carries tool_results (the
    /// newest external ingestion) rather than re-scanning — and
    /// re-logging — every prior result. Each element is the result's
    /// `(toolUseId, content)`.
    ///
    /// Wire shapes: Anthropic puts every result of a turn in ONE user message
    /// as `tool_result` blocks; OpenAI Chat Completions (Kimi, Grok, Mistral,
    /// most OpenAI-compatible agents) sends one `role: "tool"` message PER
    /// call, whose content the parser surfaces as plain text. Those used to be
    /// invisible to the scan (B37) — the trailing run of tool messages is now
    /// the newest ingestion too.
    static func newest(
        in conv: Conversation
    ) -> [(id: String?, content: String)] {
        if conv.responsesItems { return newResponsesToolOutputs(in: conv) }
        var collected: [(id: String?, content: String)] = []
        var inToolRun = false
        for message in conv.messages.reversed() {
            var spans: [(id: String?, content: String)] = []
            for block in message.content {
                if case let .toolResult(toolUseId, content, _) = block,
                   !content.isEmpty {
                    spans.append((id: toolUseId, content: content))
                }
            }
            if !spans.isEmpty {
                // Anthropic / Responses-style results: this message is the
                // newest ingestion on its own (plus any tool run after it).
                return spans + collected
            }
            if message.role == .tool {
                // OpenAI-chat tool message: its text is the tool's output.
                let text = message.content.compactMap { block -> String? in
                    if case let .text(s) = block, !s.isEmpty { return s }
                    return nil
                }.joined(separator: "\n")
                if !text.isEmpty { collected.insert((id: nil, content: text), at: 0) }
                inToolRun = true
                continue
            }
            if inToolRun { break }   // the run of tool messages ended
        }
        return collected
    }

    /// OpenAI Responses wire (Codex, Grok): one item per message. The fresh
    /// tool output is the trailing run of call / output items since the last
    /// message with real text — `[…, call₁, call₂, out₁, out₂]`, or just
    /// `[out₁]` on a WebSocket turn chained by `previous_response_id`.
    ///
    /// Grok (1.0.46, cli-chat-proxy /v1/responses) pairs each call with its
    /// output (`call₁, out₁, call₂, out₂`) and slips harness notes
    /// (`<system-reminder>` user messages) between steps; the older "outputs
    /// after the last batch of calls only" walk stopped at the first of either
    /// and left a shell `cat` of a planted file unscanned while its Read was
    /// caught. Now every output in the run is a span: an output already
    /// scanned is a verdict-cache hit (and logged once, see `scanAndLog`); a
    /// blocked one arrives as the redaction placeholder.
    static let maxResponsesRunSpans = 64
    private static func newResponsesToolOutputs(
        in conv: Conversation
    ) -> [(id: String?, content: String)] {
        var collected: [(id: String?, content: String)] = []
        for message in conv.messages.reversed() {
            var results: [(id: String?, content: String)] = []
            var calls = 0
            var texts: [String] = []
            for block in message.content {
                switch block {
                case let .toolResult(id, content, _):
                    if !content.isEmpty { results.append((id: id, content: content)) }
                case .toolUse: calls += 1
                case let .text(t): if message.role != .tool { texts.append(t) }
                case .image: break   // a screenshot output is still output
                case .thinking: break
                }
            }
            if !results.isEmpty || calls > 0 || message.role == .tool {
                collected.insert(contentsOf: results, at: 0)
                if collected.count >= maxResponsesRunSpans { break }
                continue
            }
            // A harness note between steps isn't the user talking.
            if message.role == .user, !texts.isEmpty, texts.allSatisfy(isHarnessReminder) { continue }
            break
        }
        return Array(collected.suffix(maxResponsesRunSpans))
    }

    /// An agent harness's own note in a user turn (`<system-reminder>…`),
    /// not something the user typed.
    static func isHarnessReminder(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<system-reminder>") && t.hasSuffix("</system-reminder>")
    }
}
