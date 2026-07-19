import SwiftUI

// MARK: - Transcript model + parser

/// One rendered element of a Claude Code session transcript.
struct TranscriptItem: Identifiable {
    enum Kind {
        case userText(String)
        case assistantText(String)
        case thinking(String)
        /// Tool call: name, a one-line summary (command / file path), and
        /// the full input JSON for the disclosure.
        case toolUse(name: String, summary: String, detail: String)
        /// Tool result: the tool it answers, trimmed content, error flag.
        case toolResult(tool: String, content: String, isError: Bool)
        /// The agent asking the user (AskUserQuestion) — rendered as the
        /// question with its options, and answerable in a live session.
        case question(TranscriptQuestion)
    }
    let id: Int
    var kind: Kind
    var timestamp: Date?
}

/// A parsed AskUserQuestion call: what the agent wants to know.
struct TranscriptQuestion: Equatable {
    struct Option: Equatable {
        var label: String
        var description: String
    }
    var question: String
    var header: String
    var multiSelect: Bool
    var options: [Option]

    /// All questions in the tool call, in order (the tool allows several;
    /// each carries its own options).
    static func parse(_ input: [String: Any]) -> [TranscriptQuestion] {
        guard let questions = input["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label,
                              description: o["description"] as? String ?? "")
            }
            return TranscriptQuestion(question: text,
                                      header: q["header"] as? String ?? "",
                                      multiSelect: q["multiSelect"] as? Bool ?? false,
                                      options: opts)
        }
    }
}

/// Tolerant reader for Claude Code's JSONL transcripts (the format the guest
/// writes under ~/.claude/projects/…). Unknown line types and malformed
/// lines are skipped, not fatal — the format is Claude Code's to evolve.
enum ClaudeTranscriptParser {
    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [TranscriptItem] = []
        /// tool_use id → tool name, so results can name their tool.
        var toolNames: [String: String] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            guard type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            // Meta lines (command echoes, hook chatter) aren't conversation.
            if obj["isMeta"] as? Bool == true { continue }
            let stamp = (obj["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            }

            func add(_ kind: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: items.count, kind: kind, timestamp: stamp))
            }

            // content is either a bare string or an array of typed blocks.
            if let s = message["content"] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    add(type == "user" ? .userText(trimmed) : .assistantText(trimmed))
                }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let s = (block["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !s.isEmpty else { continue }
                    add(type == "user" ? .userText(s) : .assistantText(s))
                case "thinking":
                    let s = (block["thinking"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { add(.thinking(s)) }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    if let id = block["id"] as? String { toolNames[id] = name }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let questions = name == "AskUserQuestion"
                        ? TranscriptQuestion.parse(input) : []
                    if !questions.isEmpty {
                        questions.forEach { add(.question($0)) }
                    } else {
                        add(.toolUse(name: name,
                                     summary: toolSummary(name: name, input: input),
                                     detail: prettyJSON(input)))
                    }
                case "tool_result":
                    let tool = (block["tool_use_id"] as? String)
                        .flatMap { toolNames[$0] } ?? "tool"
                    add(.toolResult(tool: tool,
                                    content: resultText(block["content"]),
                                    isError: block["is_error"] as? Bool ?? false))
                default:
                    continue
                }
            }
        }
        return items
    }

    /// The one-liner shown on a collapsed tool call — the command for shells,
    /// the path for file tools, the first primitive value otherwise.
    private static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "query", "url",
                    "prompt", "description"] {
            if let v = input[key] as? String, !v.isEmpty {
                return v.count > 200 ? String(v.prefix(200)) + "…" : v
            }
        }
        let first = input.values.compactMap { $0 as? String }.first ?? ""
        return first.count > 200 ? String(first.prefix(200)) + "…" : first
    }

    /// tool_result content: bare string, or an array of text blocks.
    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Transcript pane

/// Reads and renders a saved run transcript — the native (non-terminal) view
/// of what the agent did. Used by the run-detail window once a run has
/// finished, and by the kanban board's Done cards.
struct ClaudeTranscriptPane: View {
    let url: URL
    @State private var items: [TranscriptItem]?
    @State private var failed = false

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("Empty transcript", comment: ""),
                        systemImage: "doc.text",
                        description: Text(NSLocalizedString(
                            "The transcript file has no readable entries.", comment: "")))
                } else {
                    transcript(items)
                }
            } else if failed {
                ContentUnavailableView(
                    NSLocalizedString("No transcript", comment: ""),
                    systemImage: "doc.questionmark",
                    description: Text(NSLocalizedString(
                        "This run's transcript couldn't be read.", comment: "")))
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let target = url
            let parsed = await Task.detached(priority: .userInitiated) { () -> [TranscriptItem]? in
                guard let data = try? Data(contentsOf: target) else { return nil }
                return ClaudeTranscriptParser.parse(data)
            }.value
            if let parsed { items = parsed } else { failed = true }
        }
    }

    private func transcript(_ items: [TranscriptItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { TranscriptItemView(item: $0) }
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One transcript element. Prompts get a tinted bubble, assistant prose is
/// plain text, thinking and tool traffic collapse behind disclosures so the
/// narrative reads top-to-bottom without the plumbing in the way.
/// An AskUserQuestion rendered as content: the question, its options, and
/// (when `sendKeys` is set — the live planning session's ACTIVE question)
/// tappable answers. The key sequences mirror the picker's real behavior:
/// a single-select answers with digit+Enter (the picker then advances on
/// its own); a multi-select toggles with digits and moves on with Right —
/// Enter there toggles the highlighted row, it does NOT submit — plus a
/// final Enter on the last question, where Right lands on Submit.
struct TranscriptQuestionCard: View {
    let question: TranscriptQuestion
    var isLast: Bool = true
    let sendKeys: (([String]) -> Void)?

    @State private var picked = Set<Int>()
    @State private var sent = false

    private func answer(_ index: Int) {
        guard let sendKeys, !sent else { return }
        if question.multiSelect {
            if picked.contains(index) { picked.remove(index) }
            else { picked.insert(index) }
        } else {
            sent = true
            sendKeys(["\(index + 1)", "Enter"])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .foregroundStyle(.purple)
                }
                Text(NSLocalizedString("The agent is asking", comment: "transcript question"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.system(size: 12.5, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                Button {
                    answer(i)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: question.multiSelect
                              ? (picked.contains(i) ? "checkmark.square.fill" : "square")
                              : "\(i + 1).circle")
                            .font(.system(size: 12))
                            .foregroundStyle(sendKeys != nil ? Color.purple : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                            if !opt.description.isEmpty {
                                Text(opt.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(picked.contains(i)
                                      ? Color.purple.opacity(0.6)
                                      : Color.primary.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sendKeys == nil || sent)
            }
            if question.multiSelect && sendKeys != nil {
                Button {
                    guard !sent, !picked.isEmpty else { return }
                    sent = true
                    var keys = picked.sorted().map { "\($0 + 1)" } + ["Right"]
                    if isLast { keys.append("Enter") }   // Right → Submit
                    sendKeys!(keys)
                } label: {
                    Label(NSLocalizedString("Send answer", comment: "transcript question"),
                          systemImage: "arrow.up.circle.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(sent || picked.isEmpty)
            }
            if sent {
                Text(NSLocalizedString("Answer sent to the agent.", comment: "transcript question"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.purple.opacity(0.3)))
    }
}

struct TranscriptItemView: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .userText(let text):
            VStack(alignment: .leading, spacing: 4) {
                Label(NSLocalizedString("Prompt", comment: "transcript role"),
                      systemImage: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.25)))
        case .assistantText(let text):
            assistantText(text)
        case .question(let q):
            TranscriptQuestionCard(question: q, sendKeys: nil)
        case .thinking(let text):
            CollapsibleRow(icon: "brain",
                           title: NSLocalizedString("Thinking", comment: "transcript"),
                           tint: .secondary) {
                Text(text)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .toolUse(let name, let summary, let detail):
            CollapsibleRow(icon: "wrench.and.screwdriver",
                           title: name, subtitle: summary, tint: .secondary) {
                if !detail.isEmpty {
                    codeBlock(detail)
                }
            }
        case .toolResult(let tool, let content, let isError):
            CollapsibleRow(
                icon: isError ? "exclamationmark.octagon" : "arrow.turn.down.right",
                title: String(format: NSLocalizedString("%@ result", comment: "tool result"),
                              tool),
                subtitle: firstLine(content),
                tint: isError ? .red : .secondary) {
                if !content.isEmpty {
                    codeBlock(String(content.prefix(20_000)))
                }
            }
        }
    }

    /// Assistant prose, with markdown when it parses (Claude's answers are
    /// markdown-heavy — headings, lists, backticks).
    @ViewBuilder
    private func assistantText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.05)))
    }

    private func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

/// A one-line header with a chevron; the content mounts only while expanded
/// (transcripts can carry megabytes of tool output).
private struct CollapsibleRow<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    let tint: Color
    @ViewBuilder let content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content()
                    .padding(.leading, 18)
            }
        }
    }
}
