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
        /// Question texts of the last AskUserQuestion seen in the
        /// transcript proper, and whether its result already landed —
        /// a pq hook dump matching a RESOLVED call is stale, not pending.
        var lastAskedQuestions: [String] = []
        var lastAskResolved = false
        var pendingDumps: [[TranscriptQuestion]] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            // A PreToolUse hook dump of a PENDING AskUserQuestion (appended
            // to the tail by the plan-transcript fetch): the question is on
            // screen in the session but not yet in the transcript proper.
            if type.isEmpty, obj["tool_name"] as? String == "AskUserQuestion",
               let input = obj["tool_input"] as? [String: Any] {
                // Defer: whether this is genuinely pending depends on the
                // rest of the transcript (see the flush below).
                let qs = TranscriptQuestion.parse(input)
                if !qs.isEmpty { pendingDumps.append(qs) }
                continue
            }
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
                        lastAskedQuestions = questions.map(\.question)
                        lastAskResolved = false
                        questions.forEach { add(.question($0)) }
                    } else {
                        add(.toolUse(name: name,
                                     summary: toolSummary(name: name, input: input),
                                     detail: prettyJSON(input)))
                    }
                case "tool_result":
                    let tool = (block["tool_use_id"] as? String)
                        .flatMap { toolNames[$0] } ?? "tool"
                    if tool == "AskUserQuestion" { lastAskResolved = true }
                    add(.toolResult(tool: tool,
                                    content: resultText(block["content"]),
                                    isError: block["is_error"] as? Bool ?? false))
                default:
                    continue
                }
            }
        }
        // Flush pending-question dumps: only a dump whose questions are
        // NOT the transcript's last (already answered or declined)
        // AskUserQuestion round is genuinely pending.
        for qs in pendingDumps {
            // A dump matching the transcript's last AskUserQuestion round is
            // never pending: resolved → stale file; unresolved-but-present →
            // the transcript items already carry it.
            if qs.map(\.question) == lastAskedQuestions { continue }
            qs.forEach {
                items.append(TranscriptItem(id: items.count,
                                            kind: .question($0), timestamp: nil))
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
/// A modern chat composer, Codex-Desktop style: the text area rides on
/// top, a slim utility bar with the key hint and the send control sits
/// beneath it, all in one elevated rounded container that glows with the
/// accent while focused. Return sends, Option-Return inserts a newline.
struct ChatComposer: View {
    let placeholder: String
    @Binding var text: String
    var disabled = false
    var busy = false
    var accent: Color = .accentColor
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var sendable: Bool {
        !disabled && !busy
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit { if sendable { onSend() } }
                .disabled(disabled)
                .frame(minHeight: 22)
            HStack(spacing: 8) {
                Text(NSLocalizedString("⏎ send   ⌥⏎ newline", comment: "composer hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 0)
                Button(action: { if sendable { onSend() } }) {
                    Group {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 27, height: 27)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(sendable ? accent : Color.secondary.opacity(0.28)))
                }
                .buttonStyle(.plain)
                .disabled(!sendable)
                .keyboardShortcut(.return, modifiers: .command)
                .help(NSLocalizedString("Send (⏎)", comment: "composer"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .textBackgroundColor))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(focused ? accent.opacity(0.55)
                                  : Color.primary.opacity(0.12),
                          lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// An AskUserQuestion rendered statically (archived transcripts, or a
/// question that is no longer answerable): the question with its options.
struct TranscriptQuestionCard: View {
    let question: TranscriptQuestion

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
                Text(NSLocalizedString("The agent asked", comment: "transcript question"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.system(size: 12.5, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                QuestionOptionRow(index: i, option: opt,
                                  multiSelect: question.multiSelect,
                                  picked: false, interactive: false)
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

private struct QuestionOptionRow: View {
    let index: Int
    let option: TranscriptQuestion.Option
    let multiSelect: Bool
    let picked: Bool
    let interactive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: multiSelect
                  ? (picked ? "checkmark.square.fill" : "square")
                  : (picked ? "\(index + 1).circle.fill" : "\(index + 1).circle"))
                .font(.system(size: 12))
                .foregroundStyle(interactive ? Color.purple : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(.system(size: 12, weight: .medium))
                if !option.description.isEmpty {
                    Text(option.description)
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
            .fill(picked ? Color.purple.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(picked ? Color.purple.opacity(0.6)
                                 : Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
    }
}

/// The LIVE question batch as one tabbed card — one tab per question (the
/// session's picker shows the same tabs), answers collected locally and
/// editable until a single Submit sends the whole set as the picker's key
/// sequence. Nothing reaches the agent before Submit, so a mis-click is
/// just a click away from being fixed.
struct TranscriptQuestionBatchCard: View {
    let questions: [TranscriptQuestion]
    /// Sends the picker keystrokes; awaited so the card can show progress.
    let onSubmit: ([String]) async -> Bool

    @State private var tab = 0
    @State private var picks: [Int: Set<Int>] = [:]
    @State private var sending = false
    @State private var sent = false
    @State private var failed = false

    private func answered(_ i: Int) -> Bool {
        guard let q = questions.indices.contains(i) ? questions[i] : nil
        else { return false }
        // A multi-select may legitimately be submitted with nothing picked;
        // it counts as answered once visited or picked.
        return q.multiSelect ? (picks[i] != nil) : !(picks[i] ?? []).isEmpty
    }

    private var allAnswered: Bool {
        questions.indices.allSatisfy { answered($0) }
    }

    /// The picker's real key semantics, front to back: a single-select
    /// answers with digit+Enter (the picker advances itself); a
    /// multi-select toggles digits then moves on with Right — plus a final
    /// Enter when it's the last question, where Right lands on Submit.
    private func submitKeys() -> [String] {
        var keys: [String] = []
        for (i, q) in questions.enumerated() {
            let sel = (picks[i] ?? []).sorted()
            if q.multiSelect {
                keys += sel.map { "\($0 + 1)" }
                keys.append("Right")
                if i == questions.count - 1 { keys.append("Enter") }
            } else if let s = sel.first {
                keys += ["\(s + 1)", "Enter"]
            }
        }
        return keys
    }

    private func toggle(_ option: Int) {
        guard !sending, !sent else { return }
        var sel = picks[tab] ?? []
        if questions[tab].multiSelect {
            if sel.contains(option) { sel.remove(option) } else { sel.insert(option) }
        } else {
            sel = [option]
        }
        picks[tab] = sel
        // Single-select: picking advances to the next unanswered tab, the
        // same flow the terminal picker has — minus the instant commit.
        if !questions[tab].multiSelect,
           let next = questions.indices.first(where: { !answered($0) }) {
            tab = next
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)
                Text(questions.count > 1
                     ? String(format: NSLocalizedString(
                        "The agent is asking %d questions — answer them all, then Submit",
                        comment: "question batch"), questions.count)
                     : NSLocalizedString("The agent is asking", comment: "question batch"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if questions.count > 1 {
                HStack(spacing: 4) {
                    ForEach(questions.indices, id: \.self) { i in
                        Button {
                            if !sending && !sent { tab = i }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: answered(i)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 9))
                                Text(questions[i].header.isEmpty
                                     ? String(format: NSLocalizedString(
                                        "Q%d", comment: "question tab"), i + 1)
                                     : questions[i].header)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(
                                tab == i ? Color.purple.opacity(0.2)
                                         : Color.primary.opacity(0.05)))
                            .foregroundStyle(tab == i ? Color.purple :
                                             answered(i) ? Color.green : .secondary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }

            let q = questions[min(tab, questions.count - 1)]
            Text(q.question)
                .font(.system(size: 12.5, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                Button {
                    toggle(i)
                } label: {
                    QuestionOptionRow(index: i, option: opt,
                                      multiSelect: q.multiSelect,
                                      picked: (picks[tab] ?? []).contains(i),
                                      interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(sending || sent)
            }
            if q.multiSelect && picks[tab] == nil {
                Button(NSLocalizedString("None of these", comment: "question batch")) {
                    picks[tab] = []
                }
                .controlSize(.small)
                .disabled(sending || sent)
            }

            HStack(spacing: 8) {
                Button {
                    guard allAnswered, !sending, !sent else { return }
                    sending = true
                    failed = false
                    let keys = submitKeys()
                    Task {
                        let ok = await onSubmit(keys)
                        sending = false
                        if ok { sent = true } else { failed = true }
                    }
                } label: {
                    if sending {
                        Label(NSLocalizedString("Sending answers…", comment: "question batch"),
                              systemImage: "ellipsis.circle")
                    } else {
                        Label(NSLocalizedString("Submit", comment: "question batch"),
                              systemImage: "arrow.up.circle.fill")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!allAnswered || sending || sent)
                if sent {
                    Text(NSLocalizedString("Answers sent to the agent.",
                                           comment: "question batch"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else if failed {
                    Text(NSLocalizedString("Couldn't reach the session — try again.",
                                           comment: "question batch"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                } else if !allAnswered && questions.count > 1 {
                    Text(NSLocalizedString("Submit enables once every tab is answered.",
                                           comment: "question batch"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
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
            TranscriptQuestionCard(question: q)
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
