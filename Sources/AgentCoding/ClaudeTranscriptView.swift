import MarkdownUI
import SwiftUI

extension Color {
    /// The Bromure brand blue (the app icon's mark), lifted in dark mode.
    static let bromureBrand: Color = {
        let light = (r: 0.345, g: 0.400, b: 0.996)   // #5866FE
        let dark = (r: 0.576, g: 0.682, b: 1.000)    // #93AEFF
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }()
}

// MARK: - Transcript pane

/// Reads and renders a saved run transcript — the native (non-terminal) view
/// of what the agent did. Used by the run-detail window once a run has
/// finished, and by the kanban board's Done cards.
struct ClaudeTranscriptPane: View {
    let url: URL
    /// The agent that wrote it ("codex", …), when known; nil = sniffed.
    var agent: String? = nil
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
            let agent = agent
            let parsed = await Task.detached(priority: .userInitiated) { () -> [TranscriptItem]? in
                guard let data = try? Data(contentsOf: target) else { return nil }
                // Archived runs may have been driven by any of the supported
                // agents: the recorded one when known, else sniffed.
                return AgentTranscript.parse(data, agent: agent)
            }.value
            if let parsed { items = parsed } else { failed = true }
        }
    }

    private func transcript(_ items: [TranscriptItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                TranscriptRowsView(items: items)
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground)
    }
}

/// One transcript element. Prompts get a tinted bubble, assistant prose is
/// plain text, thinking and tool traffic collapse behind disclosures so the
/// narrative reads top-to-bottom without the plumbing in the way.
/// Keys the composer's text area offers its host before acting on them
/// itself, so a completion palette can take the arrows, Tab, Return and
/// Escape (macOS; see ComposerTextView).
enum ComposerKey { case up, down, tab, enter, escape }

/// A modern chat composer, Codex-Desktop style: the text area rides on
/// top, a slim utility bar with the key hint and the send control sits
/// beneath it, all in one elevated rounded container that glows with the
/// accent while focused. Return sends, Option-Return inserts a newline.
struct ChatComposer: View {
    let placeholder: String
    @Binding var text: String
    var disabled = false
    /// macOS: the text area takes the keyboard when it appears, unless
    /// another control in the window already has it.
    var autofocus = false
    var busy = false
    var accent: Color = .accentColor
    /// Allow sending with empty text (the beautified composer with pending
    /// attachments: the paths ARE the message).
    var canSendEmpty = false
    /// The agent is running — the send control becomes a Stop button (Esc), so a
    /// runaway turn can be interrupted without hunting for the hidden terminal.
    var working = false
    var onStop: () -> Void = {}
    /// macOS: keys the text area offers the host before acting on them
    /// itself — a "/" palette takes the arrows, Tab, Return and Escape.
    var onKey: ((ComposerKey) -> Bool)? = nil
    /// The footer's key hint, when this composer does something else with ⏎.
    var hint: String? = nil
    /// The send button's symbol and tooltip.
    var sendSymbol = "arrow.up"
    var sendHelp: String? = nil
    /// A control that belongs with the text — shown in the footer, before
    /// the send button.
    var accessory: AnyView? = nil
    let onSend: () -> Void

    #if os(macOS)
    // A real text view (see ComposerTextView): SwiftUI's vertical field
    // stops re-wrapping once editing has begun and the pane changes width.
    @State private var editorHeight: CGFloat = 24
    @State private var editorFocused = false
    private var focused: Bool { editorFocused }
    #else
    @FocusState private var focused: Bool
    #endif

    private var sendable: Bool {
        !disabled && !busy
            && (canSendEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            ComposerTextView(text: $text, placeholder: placeholder, disabled: disabled,
                             autofocus: autofocus, height: $editorHeight, focused: $editorFocused,
                             onKey: onKey, onSubmit: { if sendable { onSend() } })
                .frame(maxWidth: .infinity)
                .frame(height: editorHeight)
            #else
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit { if sendable { onSend() } }
                .disabled(disabled)
                .frame(minHeight: 22)
            #endif
            HStack(spacing: 8) {
                Text(hint ?? (working
                     ? NSLocalizedString("⎋ stop   ⏎ send   ⇧⏎ newline", comment: "composer hint")
                     : NSLocalizedString("⏎ send   ⇧⏎ newline", comment: "composer hint")))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 0)
                if let accessory { accessory }
                if working {
                    // Interrupt the running agent (sends Esc to its pane).
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)          // Esc
                    .help(NSLocalizedString("Stop the agent (Esc)", comment: "composer"))
                } else {
                    Button(action: { if sendable { onSend() } }) {
                        Group {
                            if busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: sendSymbol)
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
                    .help(sendHelp ?? NSLocalizedString("Send (⏎)", comment: "composer"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(focused ? accent.opacity(0.55)
                                  : Color.acHairline,
                          lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// The pictures of a user turn, inside its bubble: each at its own shape,
/// no taller than a few lines of text, side by side and scrolling
/// sideways when there are several.
struct DropPictureStrip: View {
    let images: [Data]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(images.indices, id: \.self) { i in
                    if let img = PlatformImage(data: images[i]) {
                        picture(img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 360, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func picture(_ img: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }
}

/// An AskUserQuestion rendered statically (archived transcripts, or a
/// question that is no longer answerable): the question with its options.
/// Once answered it folds to one quiet line — the question and the pick —
/// that opens back up on a click.
struct TranscriptQuestionCard: View {
    let question: TranscriptQuestion
    @State private var expanded = false

    var body: some View {
        if question.isResolved && !expanded {
            resolvedLine
        } else {
            card
        }
    }

    private var resolvedLine: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded = true } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: question.declined ? "xmark.circle" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(question.question)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let pick = pickText {
                    Text("→ " + pick)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Show the question and its options", comment: "transcript question"))
    }

    /// The pick as shown on the folded line; nil when there's nothing to name.
    private var pickText: String? {
        if question.declined { return NSLocalizedString("dismissed", comment: "transcript question") }
        guard let a = question.answer, !a.isEmpty else { return nil }
        return a
    }

    /// The labels the user picked (a multi-select answer is comma-joined).
    private var pickedLabels: Set<String> {
        guard let a = question.answer, !a.isEmpty else { return [] }
        let labels = Set(question.options.map(\.label))
        if labels.contains(a) { return [a] }
        return Set(a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            .intersection(labels)
    }

    private var card: some View {
        let resolved = question.isResolved
        let tint: Color = resolved ? .secondary : Color.bromureBrand
        let picked = pickedLabels
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.15)))
                        .foregroundStyle(tint)
                }
                Text(resolved
                     ? NSLocalizedString("The agent asked — answered", comment: "transcript question")
                     : NSLocalizedString("The agent asked", comment: "transcript question"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if resolved {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded = false } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("Fold", comment: "transcript question"))
                }
            }
            Text(question.question)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(resolved ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, opt in
                QuestionOptionRow(index: i, option: opt,
                                  multiSelect: question.multiSelect,
                                  picked: picked.contains(opt.label), interactive: false,
                                  tint: tint)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(resolved ? Color.primary.opacity(0.035) : Color.bromureBrand.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(resolved ? Color.primary.opacity(0.1) : Color.bromureBrand.opacity(0.3)))
    }
}

private struct QuestionOptionRow: View {
    let index: Int
    let option: TranscriptQuestion.Option
    let multiSelect: Bool
    let picked: Bool
    let interactive: Bool
    var tint: Color = Color.bromureBrand

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: multiSelect
                  ? (picked ? "checkmark.square.fill" : "square")
                  : (picked ? "\(index + 1).circle.fill" : "\(index + 1).circle"))
                .font(.system(size: 12))
                .foregroundStyle(interactive || picked ? tint : .secondary)
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
            .fill(picked ? tint.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(picked ? tint.opacity(0.6)
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
    /// Streamed (plan-stream) sessions answer with STRUCTURED payloads
    /// instead of TUI keystrokes. When set, it's tried first; a false
    /// return falls back to the keystroke path (session not live).
    var onSubmitAnswers: (([(question: String, labels: [String], other: String?)]) async -> Bool)? = nil

    /// The structured form of the current picks, question order preserved.
    private func structuredAnswers() -> [(question: String, labels: [String], other: String?)] {
        questions.enumerated().map { i, q in
            let labels = (picks[i] ?? []).sorted().compactMap {
                q.options.indices.contains($0) ? q.options[$0].label : nil
            }
            return (question: q.question, labels: labels, other: nil)
        }
    }

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
                    .foregroundStyle(Color.bromureBrand)
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
                                tab == i ? Color.bromureBrand.opacity(0.2)
                                         : Color.primary.opacity(0.05)))
                            .foregroundStyle(tab == i ? Color.bromureBrand :
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
                    let answers = structuredAnswers()
                    Task {
                        var ok = false
                        if let onSubmitAnswers {
                            ok = await onSubmitAnswers(answers)
                        }
                        if !ok { ok = await onSubmit(keys) }
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
                .tint(Color.bromureBrand)
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
            .fill(Color.bromureBrand.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.bromureBrand.opacity(0.3)))
    }
}

extension TranscriptItem {
    /// Roughly how much text the row shows (for sizing a render window).
    var approximateLength: Int {
        switch kind {
        case .userText(let t), .assistantText(let t): return t.count
        default: return 300
        }
    }
}

/// An agent's reply is laid out line by line in its terminal; Markdown
/// folds lines separated by a single newline into one paragraph (a soft
/// break), so a reply written as separate lines read as one run-on
/// paragraph in the chat. This makes those single newlines hard breaks
/// (a trailing backslash) — only between two plain paragraph lines: code
/// (fenced or indented), lists and their continuation lines, tables,
/// headings, setext underlines and HTML keep their Markdown meaning.
enum MarkdownHardBreaks {
    static func apply(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let lines = text.components(separatedBy: "\n")
        var out = lines
        var fence: String?          // the open fence's marker
        var inList = false          // a list block, until a blank line
        var inTable = false
        for i in lines.indices {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if t.hasPrefix(f) { fence = nil }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fence = String(t.prefix(3))
                continue
            }
            if t.isEmpty { inList = false; inTable = false; continue }
            if isListItem(t) { inList = true }
            if isTableRow(t) { inTable = true }
            guard !inList, !inTable, isParagraphLine(line, trimmed: t),
                  i + 1 < lines.count else { continue }
            let next = lines[i + 1]
            let nt = next.trimmingCharacters(in: .whitespaces)
            guard !nt.isEmpty, isParagraphLine(next, trimmed: nt), !isListItem(nt),
                  !isTableRow(nt), !isSetextUnderline(nt),
                  !nt.hasPrefix("```"), !nt.hasPrefix("~~~") else { continue }
            if line.hasSuffix("\\") || line.hasSuffix("  ") { continue }
            out[i] = line + "\\"
        }
        return out.joined(separator: "\n")
    }

    private static func isParagraphLine(_ line: String, trimmed t: String) -> Bool {
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return false }   // indented code
        if t.hasPrefix("#") || t.hasPrefix("<") { return false }            // heading, HTML
        if isThematicBreak(t) { return false }
        return true
    }

    static func isListItem(_ t: String) -> Bool {
        if let c = t.first, "-*+".contains(c) {
            let rest = t.dropFirst()
            return rest.isEmpty || rest.first == " " || rest.first == "\t"
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = t.dropFirst(digits.count)
        guard let m = rest.first, m == "." || m == ")" else { return false }
        let after = rest.dropFirst()
        return after.isEmpty || after.first == " " || after.first == "\t"
    }

    /// A row with a leading pipe, or a delimiter row (`---|:--:`) — whose
    /// header line above it has none.
    private static func isTableRow(_ t: String) -> Bool {
        if t.hasPrefix("|") { return true }
        return t.contains("|") && t.contains("-") && t.allSatisfy { "|-: \t".contains($0) }
    }

    private static func isSetextUnderline(_ t: String) -> Bool {
        !t.isEmpty && (t.allSatisfy { $0 == "=" } || t.allSatisfy { $0 == "-" })
    }

    private static func isThematicBreak(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }
}

/// Parsed markdown by text. A transcript row is rebuilt often (a poll, a
/// mirror push, a resize, a layout switch) and `Markdown(String)` parses
/// again each time; the parse is kept here instead, and new messages are
/// parsed ahead, off the main thread, as they arrive (`prewarm`).
enum TranscriptMarkdownCache {
    private final class Box {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 4000
        return c
    }()

    static func content(_ text: String) -> MarkdownContent {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.content }
        let parsed = MarkdownContent(MarkdownHardBreaks.apply(text))
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    /// Parse the assistant prose among `items` in the background, so the
    /// rows find it ready.
    static func prewarm(_ items: [TranscriptItem]) {
        let texts: [String] = items.compactMap {
            if case .assistantText(let t) = $0.kind, cache.object(forKey: t as NSString) == nil { return t }
            return nil
        }
        guard !texts.isEmpty else { return }
        Task.detached(priority: .utility) {
            for t in texts {
                for case .markdown(let m) in TranscriptTables.segments(t) { _ = content(m) }
            }
        }
    }
}

// MARK: - Tables in assistant prose

/// A GFM pipe table lifted out of a reply, drawn by `TranscriptTableView`
/// instead of MarkdownUI. MarkdownUI draws a table's borders and row tints
/// from cell bounds collected through anchor preferences and read back by
/// GeometryReaders over the grid (`tableDecoration`); inside the chat's
/// lazy, tail-following stack, while a reply with a table streamed in, that
/// geometry → preference → redraw cycle kept the main thread in SwiftUI
/// updates for minutes (S3-1). Here every tint and rule belongs to the
/// cell or row it decorates: no geometry is read back, nothing is measured
/// twice.
struct TranscriptTable: Equatable {
    enum Align: Equatable { case leading, center, trailing }
    var alignments: [Align]
    /// Row 0 is the header; every row has `alignments.count` cells.
    var rows: [[String]]
    /// `rows`, parsed as inline markdown (bold, code, links).
    var cells: [[AttributedString]]

    init(alignments: [Align], rows: [[String]]) {
        self.alignments = alignments
        self.rows = rows
        self.cells = rows.map { $0.map(Self.inline) }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

enum TranscriptProseSegment: Equatable {
    case markdown(String)
    case table(TranscriptTable)
}

enum TranscriptTables {
    private final class Box {
        let segments: [TranscriptProseSegment]
        init(_ s: [TranscriptProseSegment]) { segments = s }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 2000
        return c
    }()

    /// `text` cut into markdown runs and the top-level pipe tables between
    /// them (not those inside a code fence, an indented block, a quote or a
    /// list — those stay MarkdownUI's). Text without a table is one run.
    static func segments(_ text: String) -> [TranscriptProseSegment] {
        guard text.contains("|"), text.contains("-") else { return [.markdown(text)] }
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.segments }
        let parsed = parse(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    static func parse(_ text: String) -> [TranscriptProseSegment] {
        let lines = text.components(separatedBy: "\n")
        var out: [TranscriptProseSegment] = []
        var buf: [String] = []
        var fence: String?
        func flush() {
            let s = buf.joined(separator: "\n")
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.markdown(s)) }
            buf = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                buf.append(line)
                if t.hasPrefix(f) { fence = nil }
                i += 1
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fence = String(t.prefix(3))
                buf.append(line)
                i += 1
                continue
            }
            if i + 1 < lines.count, isTopLevel(line), t.contains("|"),
               let aligns = delimiter(lines[i + 1].trimmingCharacters(in: .whitespaces)),
               cells(t).count == aligns.count {
                var rows = [cells(t)]
                var j = i + 2
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|"), isTopLevel(lines[j]),
                          !r.hasPrefix("```"), !r.hasPrefix("~~~") else { break }
                    var row = cells(r)
                    if row.count < aligns.count { row += Array(repeating: "", count: aligns.count - row.count) }
                    rows.append(Array(row.prefix(aligns.count)))
                    j += 1
                }
                flush()
                out.append(.table(TranscriptTable(alignments: aligns, rows: rows)))
                i = j
                continue
            }
            buf.append(line)
            i += 1
        }
        flush()
        return out.isEmpty ? [.markdown(text)] : out
    }

    /// Not indented code, a quote or a list item.
    private static func isTopLevel(_ line: String) -> Bool {
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix(">") && !MarkdownHardBreaks.isListItem(t)
    }

    /// The column alignments of a delimiter row (`|---|:--:|--:|`), or nil.
    static func delimiter(_ t: String) -> [TranscriptTable.Align]? {
        guard t.contains("|") || t.contains(":"), t.contains("-") else { return nil }
        let parts = cells(t)
        guard !parts.isEmpty else { return nil }
        var out: [TranscriptTable.Align] = []
        for p in parts {
            let c = p.trimmingCharacters(in: .whitespaces)
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }

    /// The cells of one row: split at unescaped pipes (outer pipes
    /// dropped, `\|` kept as a pipe), each trimmed.
    static func cells(_ t: String) -> [String] {
        var s = Substring(t.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = s.dropLast() }
        var out: [String] = []
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped {
                if ch != "|" { cur.append("\\") }
                cur.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if escaped { cur.append("\\") }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}

/// A reply's table: a card, not a spreadsheet — rows parted by hairlines,
/// the header set off by a tint, cells with room around the words, one
/// rounded border around the whole. In a column narrower than `narrow`
/// (a room cell) it keeps its natural width — each cell at most `cap`
/// wide — and scrolls sideways rather than squeeze into a table many
/// screens tall. The choice is `ViewThatFits`'s, from the width offered,
/// and the cells are placed by `TranscriptTableLayout` from their own
/// sizes: no measured state and no geometry read back, so nothing the
/// table draws can change how it is laid out.
struct TranscriptTableView: View {
    static var narrow: CGFloat { 480 }
    static var cap: CGFloat { 240 }
    let table: TranscriptTable
    let bodySize: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(cap: nil)
                .frame(minWidth: 0, idealWidth: Self.narrow, maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                grid(cap: Self.cap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var columns: Int { max(1, table.alignments.count) }

    private func grid(cap: CGFloat?) -> some View {
        TranscriptTableLayout(columns: columns, cap: cap) {
            ForEach(0..<(table.cells.count * columns), id: \.self) { i in
                cell(i / columns, i % columns)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14)))
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let align = c < table.alignments.count ? table.alignments[c] : .leading
        let value = r < table.cells.count && c < table.cells[r].count ? table.cells[r][c] : AttributedString()
        return Text(value)
            .font(.system(size: bodySize * 0.95, weight: r == 0 ? .semibold : .regular))
            .lineSpacing(bodySize * 0.2)
            .multilineTextAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: align == .center ? .top : align == .trailing ? .topTrailing : .topLeading)
            .background(r == 0 ? Color.primary.opacity(0.06)
                        : r % 2 == 0 ? Color.primary.opacity(0.025) : Color.clear)
            .overlay(alignment: .top) {
                if r > 0 { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
            }
    }
}

/// Table cells, row-major, `columns` to a row: each column as wide as its
/// widest cell (at most `cap`), shrunk fairly when the row doesn't fit the
/// width offered (the narrowest columns keep their width, the rest share
/// what is left); each row as tall as its tallest cell at those widths.
/// Every cell is proposed exactly its column × row box, so its tint and
/// hairline fill it. A pure function of the cells' sizes.
struct TranscriptTableLayout: Layout {
    let columns: Int
    let cap: CGFloat?

    struct Cache { var ideal: [CGFloat] }

    func makeCache(subviews: Subviews) -> Cache { Cache(ideal: idealWidths(subviews)) }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.ideal = idealWidths(subviews) }

    private func idealWidths(_ subviews: Subviews) -> [CGFloat] {
        var w = Array(repeating: CGFloat(0), count: max(1, columns))
        for (i, s) in subviews.enumerated() {
            var x = s.sizeThatFits(.unspecified).width
            if let cap { x = min(x, cap) }
            if x.isFinite { w[i % w.count] = max(w[i % w.count], x.rounded(.up)) }
        }
        return w
    }

    static func widths(available: CGFloat?, ideal: [CGFloat]) -> [CGFloat] {
        guard let available, available.isFinite, ideal.reduce(0, +) > available else { return ideal }
        var out = ideal
        var remaining = max(0, available)
        var left = ideal.count
        for c in ideal.indices.sorted(by: { ideal[$0] < ideal[$1] }) {
            let w = min(ideal[c], (remaining / CGFloat(left)).rounded(.down))
            out[c] = w
            remaining -= w
            left -= 1
        }
        return out
    }

    private func heights(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
        let cols = max(1, columns)
        var h = Array(repeating: CGFloat(0), count: (subviews.count + cols - 1) / cols)
        for (i, s) in subviews.enumerated() {
            let y = s.sizeThatFits(ProposedViewSize(width: widths[i % cols], height: nil)).height
            if y.isFinite { h[i / cols] = max(h[i / cols], y.rounded(.up)) }
        }
        return h
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let w = Self.widths(available: proposal.width, ideal: cache.ideal)
        return CGSize(width: w.reduce(0, +), height: heights(w, subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let cols = max(1, columns)
        let w = Self.widths(available: bounds.width, ideal: cache.ideal)
        let h = heights(w, subviews)
        var xs: [CGFloat] = [bounds.minX]
        for x in w { xs.append(xs[xs.count - 1] + x) }
        var y = bounds.minY
        for (i, s) in subviews.enumerated() {
            let r = i / cols, c = i % cols
            if c == 0, r > 0 { y += h[r - 1] }
            s.place(at: CGPoint(x: xs[c], y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w[c], height: h[r]))
        }
    }
}

/// Bromure's colours (the website's tokens, from the 2026 brand guide). Flat and
/// square: structure comes from hairlines and spacing, not shadows or rounding.
enum BrandInk {
    private static func rgb(_ v: Int) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: 1)
    }
    /// Fills, the accent rule, large emphasis.
    static func accent(_ s: ColorScheme) -> Color { rgb(s == .dark ? 0x93AEFF : 0x5866FE) }
    /// Small accent text: the indigo is too light for it on white.
    static func accentStrong(_ s: ColorScheme) -> Color { rgb(s == .dark ? 0x93AEFF : 0x33497B) }
    /// Text on an accent fill.
    static func accentOn(_ s: ColorScheme) -> Color { rgb(s == .dark ? 0x000000 : 0xFFFFFF) }
    static func secondary(_ s: ColorScheme) -> Color { rgb(s == .dark ? 0x9AA5C4 : 0x55618A) }
    static func panel(_ s: ColorScheme) -> Color { rgb(s == .dark ? 0x0E1220 : 0xF4F6FD) }
    /// The token's dark value (0x222840) assumes the site's pure black ground and
    /// disappears on the app's grey window: its light blue-grey, thinned, instead.
    static func hairline(_ s: ColorScheme) -> Color {
        s == .dark ? rgb(0x9AA5C4).opacity(0.3) : rgb(0xDCE2F8)
    }
}

struct TranscriptItemView: View {
    let item: TranscriptItem
    /// A later piece of a long message of yours: the header is on its first.
    var continuesMessage = false
    /// Pictures shown inside a user turn's bubble, under its words (the
    /// chat's dropped images), and the paths they stand for — left out of
    /// the words, since the picture says it.
    var attachments: [Data] = []
    var hiddenPaths: [String] = []
    @Environment(\.colorScheme) private var colorScheme

    #if os(iOS) || os(visionOS)
    private static let userTextSize: CGFloat = 16
    #else
    private static let userTextSize: CGFloat = 13
    #endif

    /// `text` without `paths`, the whitespace around them folded.
    static func withoutPaths(_ text: String, _ paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        var out = text
        for p in paths { out = out.replacingOccurrences(of: p, with: "") }
        return out.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var body: some View {
        switch item.kind {
        case .userText(let text):
            // A task prompt shows the brief only — the operating notes the
            // engine appends are plumbing, not conversation.
            // A line the host typed for a delegation (a delegate asked,
            // delivered…) is the host's aside, not the user's words.
            if let notice = DelegationNotice.strip(text) {
                DelegationNoticeRow(text: notice)
            } else if let notice = DelegationNotice.stripSwitchboard(text) {
                DelegationNoticeRow(text: notice, switchboard: true)
            } else {
                let words = Self.withoutPaths(CodingTask.displayPrompt(text), hiddenPaths)
                // Your turn is the one thing in the accent: a faint wash, the
                // rule and a label, where a code block or a tool's output is
                // grey. Findable at a glance when scrolling a long conversation.
                VStack(alignment: .leading, spacing: 8) {
                    if !continuesMessage { userHeader }
                    if !words.isEmpty {
                        Text(words)
                            .font(.system(size: Self.userTextSize, weight: .medium))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !attachments.isEmpty { DropPictureStrip(images: attachments) }
                }
                .padding(.top, continuesMessage ? 10 : 12)
                .padding(.bottom, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrandInk.accent(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.07))
                .overlay(alignment: .topLeading) {
                    if !continuesMessage {
                        Rectangle().fill(BrandInk.accent(colorScheme)).frame(width: 52, height: 2)
                    }
                }
            }
        case .assistantText(let text):
            assistantText(text)
        case .question(let q):
            TranscriptQuestionCard(question: q)
        case .thinking(let text) where TranscriptRow.isNarration(text):
            // The agent's running commentary: in the conversation, quieter
            // than what it answers.
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            ToolCallCard(name: name, summary: summary, detail: detail)
        case .todo(let title, let rows):
            TodoListView(title: title, rows: rows)
        case .agentError(let e):
            // A Bromure block says what it is in its title: the agent's raw
            // "API error (status 451 …)" stays behind the disclosure.
            CollapsibleRow(icon: "exclamationmark.triangle.fill", title: e.headline,
                           subtitle: e.kind == .blocked ? "" : firstLine(e.message), tint: .orange) {
                if let hint = e.blockedBy?.recoveryHint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !e.message.isEmpty { clippedBlock(e.message, limit: TranscriptCopy.errorLimit) }
            }
        case .toolResult(let tool, let content, let isError):
            CollapsibleRow(
                icon: isError ? "exclamationmark.octagon" : "arrow.turn.down.right",
                title: String(format: NSLocalizedString("%@ result", comment: "tool result"),
                              tool),
                subtitle: firstLine(content),
                tint: isError ? .red : .secondary) {
                if !content.isEmpty {
                    clippedBlock(content, limit: TranscriptCopy.outputLimit)
                }
            }
        }
    }

    /// "YOU · 3:42 PM", the brand's eyebrow over your message.
    private var userHeader: some View {
        HStack(spacing: 6) {
            Text(NSLocalizedString("You", comment: "transcript: your own message"))
                .foregroundStyle(BrandInk.accentStrong(colorScheme))
            if let t = item.timestamp {
                Text("·").foregroundStyle(BrandInk.secondary(colorScheme))
                Text(t.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .foregroundStyle(BrandInk.secondary(colorScheme))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.2)
        .textCase(.uppercase)
    }

    /// Assistant prose, rendered as full markdown (Claude's answers are
    /// markdown-heavy — headings, lists, fenced code) with the Claude reading
    /// look. The old inline-only `AttributedString` couldn't render block
    /// elements: lists showed their literal markers and code fences ran together.
    @ViewBuilder
    private func assistantText(_ text: String) -> some View {
        #if os(iOS) || os(visionOS)
        let bodySize: CGFloat = 17     // a reading surface on the phone
        let serif = true
        #else
        let bodySize: CGFloat = 14     // a dense dev tool on the Mac
        let serif = false
        #endif
        let segments = TranscriptTables.segments(text)
        if segments.count == 1, case .markdown(let only) = segments[0] {
            markdown(only, bodySize: bodySize, serif: serif)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Tables drawn by `TranscriptTableView` (see `TranscriptTable`).
            VStack(alignment: .leading, spacing: bodySize * 0.85) {
                ForEach(segments.indices, id: \.self) { k in
                    switch segments[k] {
                    case .markdown(let m): markdown(m, bodySize: bodySize, serif: serif)
                    case .table(let t): TranscriptTableView(table: t, bodySize: bodySize)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ text: String, bodySize: CGFloat, serif: Bool) -> some View {
        Markdown(TranscriptMarkdownCache.content(text))
            .markdownTheme(.claudeReader(bodySize: bodySize, serif: serif))
            .markdownCodeSyntaxHighlighter(TranscriptCodeHighlighter(dark: colorScheme == .dark))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Output shown up to `limit` characters; past that, a visible note of
    /// how much is shown and a button that copies all of it.
    @ViewBuilder
    private func clippedBlock(_ text: String, limit: Int) -> some View {
        let clip = TranscriptCopy.clip(text, limit: limit)
        if let total = clip.total {
            VStack(alignment: .leading, spacing: 6) {
                codeBlock(clip.shown + "\n…")
                HStack(spacing: 10) {
                    Label(TranscriptCopy.truncationMarker(shown: limit, total: total),
                          systemImage: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button {
                        platformCopyToPasteboard(text)
                    } label: {
                        Label(NSLocalizedString("Copy full output", comment: "truncated transcript output"),
                              systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else {
            codeBlock(text)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .transcriptCard(radius: 6)
    }

    private func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

// MARK: - Shared transcript card chrome

/// One place for the transcript's visual language, so every activity card
/// (command, diff, file, checklist, raw JSON) reads as the same flat surface —
/// the coherent, low-chrome look of the Codex / Claude desktop transcripts.
enum TranscriptStyle {
    static let radius: CGFloat = 8
    static let cardFill = Color.secondary.opacity(0.07)
    static let cardStroke = Color.primary.opacity(0.06)
    static let headerFill = Color.primary.opacity(0.045)
    static let gutter: CGFloat = 16
    static let headerSize: CGFloat = 11.5
    static let monoSize: CGFloat = 11.5

    /// A subtle per-category tint for a tool's glyph, so the transcript is
    /// scannable at a glance (green = shell, orange = writes/edits, blue =
    /// reads, teal = search, indigo = web) without breaking the flat, low-chrome
    /// language — only the small icon is tinted, never a fill. An unrecognized
    /// tool stays neutral `.secondary`.
    static func toolTint(_ name: String) -> Color {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("shell") || n.contains("command")
            || n.contains("execute") || n.contains("run_") { return .green }
        if n.contains("write") || n.contains("create") || n.contains("edit")
            || n.contains("patch") || n.contains("notebook") { return .orange }
        if n.contains("grep") || n.contains("search") { return .teal }
        if n.contains("web") || n.contains("fetch") { return .indigo }
        if n.contains("read") || n.contains("glob") || n.contains("ls") { return .blue }
        return .secondary
    }
}

extension View {
    /// Flat, subtly-filled rounded cell with a hairline border — the shared
    /// chrome of every transcript activity card.
    func transcriptCard(radius: CGFloat = TranscriptStyle.radius) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(TranscriptStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TranscriptStyle.cardStroke))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

#if os(macOS)
/// Small, unobtrusive copy affordance shared by code fences, command cells and
/// diffs — flips to a green check for a moment after a copy.
struct CopyButton: View {
    let text: String
    var size: CGFloat = 11
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size))
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Copy", comment: "copy"))
    }
}
#endif

/// A typed rendering of a tool call, so a beautified session reads like the
/// native Claude Code / Codex desktop apps: Edit/Write → a green/red diff,
/// Bash → a `$ command` card, Read/Grep/Glob → a path/query row, WebFetch/
/// WebSearch → a url/query row. The full input JSON is already carried in
/// `detail` (the parsers stash `prettyJSON(input)`), so the classification is
/// pure presentation — anything unrecognized falls back to the generic
/// collapsible with the raw JSON.
struct ToolCallCard: View {
    let name: String
    let summary: String
    let detail: String

    private var input: [String: Any] {
        guard let d = detail.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return obj
    }

    var body: some View {
        let n = name.lowercased()
        if let display = DisplayRequest.parse(name: name, detail: detail) {
            // The display MCP: show it, not the call.
            DisplayCard(request: display)
        } else if isTodo(n) {
            TodoCard(input: input, intent: summary)
        } else if let (content, path) = writeParts(n) {
            FileWriteCard(tool: name, path: path, content: content)
        } else if let (old, new, path) = editParts(n) {
            DiffCard(title: name, path: path, oldText: old, newText: new)
        } else if isBash(n), let cmd = firstString(["command"]) {
            CommandCard(command: cmd)
        } else if isWeb(n), let u = firstString(["url", "query"]) {
            FileCard(icon: "globe", tool: name, value: u)
        } else if isFileTool(n), let p = firstString(["file_path", "path", "pattern", "query", "notebook_path"]) {
            FileCard(icon: fileIcon(n), tool: name, value: p)
        } else {
            CollapsibleRow(icon: ActivitySummary.category(name) == .delegation ? "arrow.left.arrow.right" : "wrench.and.screwdriver",
                           title: ActivitySummary.humanTool(name),
                           subtitle: summary, tint: .secondary) {
                if !detail.isEmpty { RawJSONBlock(detail) }
            }
        }
    }

    private func isBash(_ n: String) -> Bool {
        ["bash", "shell", "run_command", "execute", "local_shell"].contains { n.contains($0) }
    }
    /// A todo / plan tool: omp's `todo`, Claude's `TodoWrite`, Codex's
    /// `update_plan`. Rendered as a checklist rather than raw JSON.
    private func isTodo(_ n: String) -> Bool {
        n.contains("todo") || n == "update_plan" || n == "updateplan"
    }
    private func isWeb(_ n: String) -> Bool { n.contains("web") || n.contains("fetch") }
    private func isFileTool(_ n: String) -> Bool {
        ["read", "glob", "grep", "ls", "search", "notebook"].contains { n.contains($0) }
    }
    private func fileIcon(_ n: String) -> String {
        if n.contains("read") || n.contains("notebook") { return "doc.text" }
        if n.contains("grep") || n.contains("search") { return "magnifyingglass" }
        if n.contains("glob") || n.contains("ls") { return "folder" }
        return "doc"
    }

    /// A whole-file Write/create → (content, path): the brand-new file's
    /// contents plus its path. Only a create carrying `content` (and NOT an
    /// `old_string` edit) lands here — it renders as syntax-highlighted SOURCE
    /// (`FileWriteCard`) instead of a wall of `+` additions. Real edits and
    /// patches fall through to `editParts` → `DiffCard`.
    private func writeParts(_ n: String) -> (String, String?)? {
        guard n.contains("write") || n.contains("create"),
              input["old_string"] == nil,
              let content = input["content"] as? String else { return nil }
        return (content, firstString(["file_path", "path", "notebook_path"]))
    }

    /// Edit → (old, new, path); Codex apply_patch → the patch split into
    /// removed/added. (A whole-file write is caught earlier by `writeParts`.)
    private func editParts(_ n: String) -> (String, String, String?)? {
        let path = firstString(["file_path", "path", "notebook_path"])
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            return (old, new, path)
        }
        if n.contains("patch"), let patch = firstString(["patch", "input", "diff"]) {
            return splitUnifiedPatch(patch, path: path)
        }
        return nil
    }

    private func firstString(_ keys: [String]) -> String? {
        for k in keys { if let v = input[k] as? String, !v.isEmpty { return v } }
        return nil
    }

    /// Best-effort: fold a unified patch into (removed, added) line blocks so it
    /// renders in the same DiffCard. `+`/`-` lines split; everything else is
    /// shared context; file/hunk headers are dropped.
    private func splitUnifiedPatch(_ patch: String, path: String?) -> (String, String, String?) {
        var oldLines: [String] = [], newLines: [String] = []
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("@@")
                || raw.hasPrefix("*** ") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") { continue }
            if raw.hasPrefix("+") { newLines.append(String(raw.dropFirst())) }
            else if raw.hasPrefix("-") { oldLines.append(String(raw.dropFirst())) }
            else {
                let c = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                oldLines.append(c); newLines.append(c)
            }
        }
        return (oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), path)
    }
}

// MARK: - Todo / plan card


/// The checklist body — a header (title + done/total) and one row per item,
/// grouped by phase. Shared by the consolidated `.todo` transcript item (omp,
/// which ticks in place across polls) and the per-call `TodoCard`.
struct TodoListView: View {
    let title: String
    let rows: [TodoRowModel]

    private var showPhases: Bool { Set(rows.compactMap(\.phase)).count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if !rows.isEmpty {
                    let done = rows.filter { $0.status == .done }.count
                    Text("\(done)/\(rows.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(done == rows.count ? .green : .secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptStyle.headerFill)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    TodoRow(row: row, showPhase: showPhases,
                            prevPhase: i > 0 ? rows[i - 1].phase : nil)
                }
            }
            .padding(.vertical, 3)
        }
        .transcriptCard()
    }
}

/// A per-call checklist card for agents whose todo tool carries full status in
/// each call (Claude `TodoWrite` — `todos:[{content,status}]`; Codex
/// `update_plan` — `plan:[{step,status}]`). omp instead flows through the
/// consolidated `.todo` item (its status lives in the tool result, not the
/// call), so it doesn't reach here. A delta call with no item list renders as a
/// one-line status update.
private struct TodoCard: View {
    let input: [String: Any]
    let intent: String

    private var rows: [TodoRowModel] { TodoParse.rows(from: input) }
    private var headerTitle: String {
        let t = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? NSLocalizedString("To-dos", comment: "todo card") : t
    }
    private var deltaLine: String? {
        guard let op = input["op"] as? String else { return nil }
        let what = (input["task"] as? String) ?? (input["phase"] as? String) ?? ""
        let verb: String
        switch op {
        case "done": verb = NSLocalizedString("Completed", comment: "todo op")
        case "unblock": verb = NSLocalizedString("Reopened", comment: "todo op")
        case "block": verb = NSLocalizedString("Blocked", comment: "todo op")
        case "add": verb = NSLocalizedString("Added", comment: "todo op")
        default: verb = op.capitalized
        }
        return what.isEmpty ? verb : "\(verb): \(what)"
    }

    var body: some View {
        if rows.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(deltaLine ?? headerTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .transcriptCard()
        } else {
            TodoListView(title: headerTitle, rows: rows)
        }
    }
}

private struct TodoRow: View {
    let row: TodoRowModel
    let showPhase: Bool
    let prevPhase: String?

    private var icon: String {
        switch row.status {
        case .pending: return "circle"
        case .active:  return "circle.dotted"
        case .done:    return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle"
        }
    }
    private var tint: Color {
        switch row.status {
        case .pending: return .secondary
        case .active:  return .orange
        case .done:    return .green
        case .blocked: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showPhase, let p = row.phase, p != prevPhase, !p.isEmpty {
                Text(p).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 1)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundStyle(tint).frame(width: 14)
                Text(row.text).font(.system(size: 12))
                    .foregroundStyle(row.status == .done ? .secondary : .primary)
                    .strikethrough(row.status == .done, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
        }
    }
}

/// Green/red line diff card for Edit/Write/apply_patch tool calls.
private struct DiffCard: View {
    let title: String
    let path: String?
    let oldText: String
    let newText: String
    @State private var expanded = true

    private static let maxLines = 200

    var body: some View {
        let result = DiffLine.compute(old: oldText, new: newText, cap: Self.maxLines)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TranscriptStyle.toolTint(title)).frame(width: 14)
                        Text(title).font(.system(size: TranscriptStyle.headerSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let path {
                            Text(path).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        DiffStat(result: result)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                if !newText.isEmpty { CopyButton(text: newText) }
                #endif
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptStyle.headerFill)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(result.lines.indices, id: \.self) { i in DiffRowView(row: result.lines[i]) }
                    if result.truncatedBy > 0 {
                        Text(String(format: NSLocalizedString("… %d more lines", comment: "diff"),
                                    result.truncatedBy))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .transcriptCard()
    }
}

private struct DiffStat: View {
    let result: DiffLine.Result
    var body: some View {
        let adds = result.lines.filter { $0.kind == .add }.count
        let dels = result.lines.filter { $0.kind == .remove }.count
        HStack(spacing: 5) {
            if adds > 0 { Text("+\(adds)").foregroundStyle(.green) }
            if dels > 0 { Text("−\(dels)").foregroundStyle(.red) }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
    }
}

private struct DiffRowView: View {
    let row: DiffLine
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color).frame(width: 9, alignment: .center)
            Text(row.text.isEmpty ? " " : row.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(row.kind == .context ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 0.5)
        .background(background)
    }
    private var marker: String { row.kind == .add ? "+" : row.kind == .remove ? "−" : "" }
    private var color: Color { row.kind == .add ? .green : row.kind == .remove ? .red : .secondary }
    private var background: Color {
        switch row.kind {
        case .add: return Color.green.opacity(0.12)
        case .remove: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

/// A line-level diff (LCS). Falls back to remove-all-then-add-all when the
/// inputs are large enough that the O(n·m) table would be costly.
struct DiffLine {
    enum Kind { case context, add, remove }
    let kind: Kind
    let text: String

    struct Result { var lines: [DiffLine]; var truncatedBy: Int }

    static func compute(old: String, new: String, cap: Int) -> Result {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var lines: [DiffLine]
        if a.count * b.count > 250_000 || a.count + b.count > 4000 {
            lines = a.map { DiffLine(kind: .remove, text: $0) }
                  + b.map { DiffLine(kind: .add, text: $0) }
        } else {
            lines = lcs(a, b)
        }
        if lines.count > cap {
            return Result(lines: Array(lines.prefix(cap)), truncatedBy: lines.count - cap)
        }
        return Result(lines: lines, truncatedBy: 0)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count, m = b.count
        guard n > 0 else { return b.map { DiffLine(kind: .add, text: $0) } }
        guard m > 0 else { return a.map { DiffLine(kind: .remove, text: $0) } }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(.init(kind: .context, text: a[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append(.init(kind: .remove, text: a[i])); i += 1 }
            else { out.append(.init(kind: .add, text: b[j])); j += 1 }
        }
        while i < n { out.append(.init(kind: .remove, text: a[i])); i += 1 }
        while j < m { out.append(.init(kind: .add, text: b[j])); j += 1 }
        return out
    }
}

// MARK: - Source rendering (shared by file writes and heredocs)

/// Maps a file path, an interpreter name, or a heredoc delimiter word to a
/// highlight.js language id ("code" = none/unknown → plain monospaced text).
enum TranscriptLang {
    /// From a path's extension: `foo.swift` → "swift".
    static func forPath(_ path: String?) -> String {
        guard let path else { return "code" }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "code" }
        switch ext {
        case "swift": return "swift"
        case "py", "pyw": return "python"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "json": return "json"
        case "sh", "bash", "zsh": return "bash"
        case "yml", "yaml": return "yaml"
        case "html", "htm": return "html"
        case "css", "scss": return "css"
        case "md", "markdown": return "markdown"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "toml", "ini", "cfg": return "ini"
        case "xml", "plist", "entitlements", "storyboard", "xib": return "xml"
        case "sql": return "sql"
        default: return "code"
        }
    }

    /// The language a heredoc's interpreter emits: `python3 - <<PY` → python.
    static func forInterpreter(_ launcher: String) -> String {
        let l = launcher.lowercased()
        if l.contains("python") { return "python" }
        if l.range(of: #"\bnode\b"#, options: .regularExpression) != nil { return "javascript" }
        if l.contains("ruby") { return "ruby" }
        if l.contains("perl") { return "perl" }
        if l.contains("psql") || l.contains("sqlite3") || l.contains("mysql") { return "sql" }
        if l.contains("awk") { return "awk" }
        if l.range(of: #"\b(bash|sh|zsh)\b"#, options: .regularExpression) != nil { return "bash" }
        return "code"
    }

    /// Authors often name the delimiter after the content — `<<'PY'`, `<<SQL`,
    /// `<<'JSON'`. A last-resort hint when neither path nor interpreter decides.
    static func forDelimiter(_ word: String) -> String {
        switch word.uppercased() {
        case "PY", "PYTHON": return "python"
        case "SQL": return "sql"
        case "JSON": return "json"
        case "YAML", "YML": return "yaml"
        case "HTML": return "html"
        case "JS", "JAVASCRIPT": return "javascript"
        case "TS": return "typescript"
        case "SH", "BASH", "ZSH": return "bash"
        case "RB", "RUBY": return "ruby"
        case "CSS": return "css"
        case "MD", "MARKDOWN": return "markdown"
        case "XML": return "xml"
        case "TOML": return "ini"
        case "GO": return "go"
        case "RS", "RUST": return "rust"
        default: return "code"
        }
    }
}

/// The source as a single (optionally syntax-colored) `Text`. macOS reuses the
/// memoizing Highlightr cache; iOS and unknown languages fall back to plain
/// monospaced text. Font is applied on the whole run — the cache bakes in only
/// per-span colors, so it composes without a fight. Called from a view body
/// (main thread on macOS), mirroring `TranscriptCodeHighlighter`.
fileprivate func transcriptSource(_ code: String, language: String, dark: Bool, size: CGFloat) -> Text {
    #if os(macOS)
    if language != "code" {
        let colored = MainActor.assumeIsolated {
            TranscriptHighlightCache.shared.text(for: code, language: language, dark: dark)
        }
        return colored.font(.system(size: size, design: .monospaced))
    }
    #endif
    return Text(code).font(.system(size: size, design: .monospaced))
}

/// Syntax-highlighted, horizontally-scrollable source with a line cap — the
/// body shared by the file-write card and the heredoc block.
private struct SourceBody: View {
    let code: String
    let language: String
    var maxLines = 240
    @Environment(\.colorScheme) private var colorScheme

    private var lines: [String] { code.components(separatedBy: "\n") }
    private var shown: String {
        lines.count <= maxLines ? code : lines.prefix(maxLines).joined(separator: "\n")
    }
    private var hidden: Int { max(0, lines.count - maxLines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                transcriptSource(shown, language: language,
                                 dark: colorScheme == .dark, size: TranscriptStyle.monoSize)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hidden > 0 {
                Text(String(format: NSLocalizedString("… %d more lines", comment: "source"), hidden))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }
}

/// A small monospace language pill (hidden for unknown "code").
private struct LanguageChip: View {
    let language: String
    var body: some View {
        if !language.isEmpty, language != "code" {
            Text(language)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
    }
}

/// A written file shown as SOURCE, not a diff. Write/create tool calls carry the
/// whole new file in `content`; rendering that as an all-`+` DiffCard buried the
/// code in diff chrome, so a freshly-written file gets its own card — a header
/// (path · +lines · language) over syntax-highlighted source.
private struct FileWriteCard: View {
    let tool: String
    let path: String?
    let content: String
    @State private var expanded = true

    private var lineCount: Int { content.components(separatedBy: "\n").count }
    private var language: String { TranscriptLang.forPath(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TranscriptStyle.toolTint(tool)).frame(width: 14)
                        Text(tool).font(.system(size: TranscriptStyle.headerSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let path {
                            Text(path).font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Text(verbatim: "+\(lineCount)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
                        LanguageChip(language: language)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                CopyButton(text: content)
                #endif
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptStyle.headerFill)
            if expanded { SourceBody(code: content, language: language) }
        }
        .transcriptCard()
    }
}

// MARK: - Heredoc-aware shell command card

/// A run of a shell command: literal command text, or a heredoc body pulled out
/// so it can render as its own syntax-highlighted block.
enum CommandSegment: Equatable {
    case shell(String)
    case heredoc(target: String?, language: String, content: String)
}

/// Splits a shell command into command text and heredoc bodies — the thing that
/// makes "modern agents write files via bash" legible. Agents constantly write
/// through `python3 - <<'PY' … PY`, `cat > f <<EOF … EOF`, etc.; left whole
/// that's an opaque monospace wall, so we lift each heredoc body out to show it
/// as real (highlighted) source. No heredoc → one `.shell` segment (the caller
/// keeps the plain rendering).
enum HeredocParser {
    struct Opener { let word: String; let stripTabs: Bool }

    static func segments(_ command: String) -> [CommandSegment] {
        let lines = command.components(separatedBy: "\n")
        var out: [CommandSegment] = []
        var cmd: [String] = []
        var i = 0
        func flush() {
            let joined = cmd.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.shell(joined)) }
            cmd = []
        }
        while i < lines.count {
            let line = lines[i]
            let openers = heredocOpeners(line)
            guard !openers.isEmpty else { cmd.append(line); i += 1; continue }
            cmd.append(line)
            flush()
            let head = launcher(line)
            let target = redirectTarget(head)
            let interp = TranscriptLang.forInterpreter(head)
            i += 1
            for op in openers {
                var body: [String] = []
                while i < lines.count {
                    let raw = lines[i]
                    let candidate = op.stripTabs ? String(raw.drop(while: { $0 == "\t" })) : raw
                    if candidate == op.word { i += 1; break }
                    body.append(raw); i += 1
                }
                let byTarget = target.map(TranscriptLang.forPath) ?? "code"
                let language = byTarget != "code" ? byTarget
                    : (interp != "code" ? interp : TranscriptLang.forDelimiter(op.word))
                out.append(.heredoc(target: target, language: language,
                                    content: body.joined(separator: "\n")))
            }
        }
        flush()
        return out
    }

    /// Heredoc openers on a line, in order: `<<WORD`, `<<'WORD'`, `<<-WORD`.
    private static func heredocOpeners(_ line: String) -> [Opener] {
        guard line.contains("<<") else { return [] }
        let pattern = #"<<(-?)\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).map {
            Opener(word: ns.substring(with: $0.range(at: 3)),
                   stripTabs: ns.substring(with: $0.range(at: 1)) == "-")
        }
    }

    /// The launcher text before the first `<<` on a line.
    private static func launcher(_ line: String) -> String {
        guard let r = line.range(of: "<<") else { return line }
        return String(line[..<r.lowerBound])
    }

    /// A redirect target on the launcher: `> file`, `>> file`, `tee file`.
    private static func redirectTarget(_ head: String) -> String? {
        let pattern = #"(?:>>?|tee(?:\s+-a)?)\s+("?)([^\s"'|]+)\1"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = head as NSString
        guard let m = re.matches(in: head, range: NSRange(location: 0, length: ns.length)).last
        else { return nil }
        let t = ns.substring(with: m.range(at: 2))
        return (t == "/dev/null" || t.hasPrefix("&")) ? nil : t
    }
}

/// Best-effort scan of a shell command for the files it WRITES — shell redirects
/// (`> f`, `>> f`, `tee f`) and Python `open('f','w')` (resolving a `var='…'`
/// bound earlier in the same command). Purely a scannability hint: a miss just
/// omits a chip, never blocks the render.
enum FileWriteScan {
    static func targets(in command: String) -> [String] {
        var found: [String] = []
        func push(_ raw: String) {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !t.isEmpty, t != "/dev/null", t != "/dev/stdout", t != "-",
                  !t.hasPrefix("&"), !found.contains(t) else { return }
            found.append(t)
        }
        let ns = command as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func scan(_ pattern: String, _ group: Int, _ body: (String) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: command, range: whole) where m.range(at: group).location != NSNotFound {
                body(ns.substring(with: m.range(at: group)))
            }
        }
        // Shell redirects and tee (skip fd dups / bit-shift via lookbehind).
        scan(#"(?<![-=<>&\d])>>?\s*("?)([^\s"'|;&()<>]+)\1"#, 2, push)
        scan(#"\btee\b(?:\s+-a)?\s+("?)([^\s"'|;&()<>]+)\1"#, 2, push)
        // Python open('literal', 'w'|'a').
        scan(#"open\(\s*["']([^"']+)["']\s*,\s*["'][wax]"#, 1, push)
        // Python open(var, 'w') → resolve `var = 'literal'` from the same command.
        var vars: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z_]\w*)\s*=\s*["']([^"']+)["']"#) {
            for m in re.matches(in: command, range: whole) {
                vars[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
        }
        scan(#"open\(\s*([A-Za-z_]\w*)\s*,\s*["'][wax]"#, 1) { name in
            if let v = vars[name] { push(v) }
        }
        return found
    }
}

/// Terminal-style card for Bash / shell tool calls. A plain command renders as a
/// single `$`-prefixed line; a command carrying heredocs is broken into its
/// launcher line(s) plus each heredoc body as a highlighted source block, with a
/// "writes …" header naming the files the command mutates.
private struct CommandCard: View {
    let command: String

    var body: some View {
        let segments = HeredocParser.segments(command)
        let hasHeredoc = segments.contains { if case .heredoc = $0 { return true } else { return false } }
        if hasHeredoc {
            let targets = FileWriteScan.targets(in: command)
            VStack(alignment: .leading, spacing: 6) {
                if !targets.isEmpty { WriteTargetsRow(targets: targets) }
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .shell(let c):
                        ShellLine(command: c)
                    case .heredoc(let target, let language, let content):
                        HeredocBlock(target: target, language: language, content: content)
                    }
                }
            }
        } else {
            ShellLine(command: command)
        }
    }
}

/// One `$`-prefixed shell command line, horizontally scrollable, with copy.
private struct ShellLine: View {
    let command: String
    var body: some View {
        // The copy button sits BESIDE the scroller, never over it: a long
        // command scrolls under nothing.
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "$").foregroundStyle(TranscriptStyle.toolTint("bash"))
                    Text(command).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: TranscriptStyle.monoSize, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            #if os(macOS)
            CopyButton(text: command).padding(.vertical, 6).padding(.trailing, 8)
            #endif
        }
        .transcriptCard()
    }
}

/// A heredoc body lifted out of a shell command and shown as source: a header
/// (the redirect target as a path, else "heredoc" + a language pill) over the
/// highlighted body. `cat > f <<EOF` reads as a file write; `python3 - <<PY`
/// reads as an inline script.
private struct HeredocBlock: View {
    let target: String?
    let language: String
    let content: String
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: target != nil
                              ? "square.and.pencil" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(target != nil
                                             ? TranscriptStyle.toolTint("write") : .secondary)
                            .frame(width: 14)
                        if let target {
                            Text(target).font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(NSLocalizedString("heredoc", comment: "inline script"))
                                .font(.system(size: TranscriptStyle.headerSize, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        LanguageChip(language: language)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                CopyButton(text: content)
                #endif
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptStyle.headerFill)
            if expanded { SourceBody(code: content, language: language) }
        }
        .transcriptCard()
    }
}

/// A "writes file1 file2" header on a shell card — the files a command mutates,
/// surfaced so a bash blob announces its side effects without being read.
private struct WriteTargetsRow: View {
    let targets: [String]
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TranscriptStyle.toolTint("write"))
            Text(NSLocalizedString("writes", comment: "command writes files"))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(targets, id: \.self) { t in
                        Text((t as NSString).lastPathComponent)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            .help(t)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }
}

/// A compact one-line row for Read/Grep/Glob/WebFetch/WebSearch tool calls.
private struct FileCard: View {
    let icon: String
    let tool: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(TranscriptStyle.toolTint(tool))
                .frame(width: TranscriptStyle.gutter)
            Text(tool).font(.system(size: TranscriptStyle.headerSize, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: TranscriptStyle.monoSize, design: .monospaced)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .transcriptCard()
    }
}

struct RawJSONBlock: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8)
        }
        .transcriptCard(radius: 6)
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

// MARK: - Claude reading theme

private extension MarkdownUI.Theme {
    /// Claude-style reading typography for assistant prose: a serif body with
    /// generous line spacing, monospaced inline code and code fences, and proper
    /// block rendering (headings, lists, blockquotes) — as close as MarkdownUI
    /// gets to the look of the Claude app. `bodySize`/`serif` differ by platform:
    /// the iPhone reader is a reading surface (serif, larger), the Mac transcript
    /// window a dense dev tool (system font, compact).
    ///
    /// Built stepwise (not one long chain) so the type-checker stays fast, and
    /// qualified as `MarkdownUI.Theme` because the vendored Highlightr also
    /// declares a `Theme`.
    static func claudeReader(bodySize: CGFloat, serif: Bool) -> MarkdownUI.Theme {
        let family: FontProperties.Family = serif ? .system(.serif) : .system(.default)
        var t = MarkdownUI.Theme()
        t = t.text {
            ForegroundColor(.primary)
            FontFamily(family)
            FontSize(bodySize)
        }
        t = t.code {
            FontFamilyVariant(.monospaced)
            FontSize(bodySize * 0.92)
            BackgroundColor(Color.secondary.opacity(0.12))
        }
        t = t.strong { FontWeight(.semibold) }
        t = t.link { ForegroundColor(.accentColor) }
        t = t.paragraph { c in
            c.label
                .relativeLineSpacing(.em(0.24))
                .markdownMargin(top: .em(0), bottom: .em(0.85))
        }
        t = t.listItem { c in
            c.label.markdownMargin(top: .em(0.12), bottom: .em(0.12))
        }
        t = t.heading1 { c in
            c.label
                .markdownMargin(top: .em(0.9), bottom: .em(0.4))
                .markdownTextStyle { FontFamily(family); FontWeight(.bold); FontSize(bodySize * 1.5) }
        }
        t = t.heading2 { c in
            c.label
                .markdownMargin(top: .em(0.8), bottom: .em(0.35))
                .markdownTextStyle { FontFamily(family); FontWeight(.bold); FontSize(bodySize * 1.3) }
        }
        t = t.heading3 { c in
            c.label
                .markdownMargin(top: .em(0.7), bottom: .em(0.3))
                .markdownTextStyle { FontFamily(family); FontWeight(.semibold); FontSize(bodySize * 1.12) }
        }
        t = t.blockquote { c in
            c.label
                .markdownTextStyle { FontStyle(.italic); ForegroundColor(.secondary) }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3)
                }
                .markdownMargin(top: .em(0.3), bottom: .em(0.85))
        }
        t = t.codeBlock { c in
            Group {
                // A ```mermaid fence is a diagram, not code: render it with the
                // bundled mermaid.js, falling back to the plain fence if it
                // can't (no bundle on iOS, or a parse error).
                if (c.language ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "mermaid" {
                    MermaidFence(source: c.content, bodySize: bodySize) {
                        TranscriptCodeFence(configuration: c, bodySize: bodySize)
                    }
                } else {
                    TranscriptCodeFence(configuration: c, bodySize: bodySize)
                }
            }
            .markdownMargin(top: .em(0.4), bottom: .em(0.85))
        }
        // Tables: a card, not a spreadsheet — rows parted by hairlines, the
        // header set off by a tint, cells with room around the words, one
        // rounded border around the whole. In a narrow column (a room cell)
        // it scrolls sideways rather than squeeze (`ReadableTableWidth`).
        t = t.table { c in
            ReadableTableWidth {
                c.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(.insideHorizontalBorders,
                                                    color: Color.primary.opacity(0.10)))
                    .markdownTableBackgroundStyle(.alternatingRows(
                        Color.clear, Color.primary.opacity(0.025),
                        header: Color.primary.opacity(0.06)))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14)))
            }
            .markdownMargin(top: .em(0.5), bottom: .em(0.9))
        }
        t = t.tableCell { c in
            TableCellWidthCap {
                c.label
                    .markdownTextStyle {
                        FontSize(bodySize * 0.95)
                        if c.row == 0 { FontWeight(.semibold) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
        }
        return t
    }
}

/// A markdown table in a column too narrow for it (a room cell) keeps its
/// natural width — each cell at most `TableCellWidthCap.cap` wide — and
/// scrolls sideways, instead of being squeezed until its cells wrap a few
/// letters to a line. Squeezed, a table grew many screens tall, and the
/// chat's lazy list draws a row that tall as nothing: the whole room cell
/// went blank. In a column at least `narrow` wide it wraps to the column
/// as before.
private struct ReadableTableWidth<Content: View>: View {
    static var narrow: CGFloat { 480 }
    @ViewBuilder let content: Content
    /// The column's width (not the table's).
    @State private var column: CGFloat?

    var body: some View {
        Group {
            // Until the column is measured, the natural width: a first pass
            // squeezed into a narrow column is the tall row itself.
            if column.map({ $0 < Self.narrow }) ?? true {
                ScrollView(.horizontal, showsIndicators: false) {
                    content.environment(\.transcriptTableSqueezed, true)
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if column != w { column = w }
        }
    }
}

private struct TranscriptTableSqueezedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Inside a table laid out at its natural width in a narrow column.
    fileprivate var transcriptTableSqueezed: Bool {
        get { self[TranscriptTableSqueezedKey.self] }
        set { self[TranscriptTableSqueezedKey.self] = newValue }
    }
}

/// A table cell no wider than a readable line when its table isn't wrapped
/// to the column (`ReadableTableWidth`).
private struct TableCellWidthCap<Content: View>: View {
    static var cap: CGFloat { 240 }
    @ViewBuilder let content: Content
    @Environment(\.transcriptTableSqueezed) private var squeezed

    var body: some View {
        if squeezed {
            CappedWidthLayout(cap: Self.cap) { content }
        } else {
            content
        }
    }
}

/// Its one subview at its natural width up to `cap`, as tall as it wraps
/// to there (a `frame(maxWidth:)` keeps the one-line height of the natural
/// size, so the wrapped lines overlap the next row).
private struct CappedWidthLayout: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let w = min(s.sizeThatFits(.unspecified).width, cap, proposal.width ?? .infinity)
        return s.sizeThatFits(ProposedViewSize(width: w, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Internal accessor for the (private) reader theme, so the standalone
/// snapshot hooks can render markdown exactly as the transcript does.
func transcriptReaderTheme(bodySize: CGFloat, serif: Bool) -> MarkdownUI.Theme {
    .claudeReader(bodySize: bodySize, serif: serif)
}

// MARK: - Syntax-highlighted code fences (beautified transcript)

/// A modern code fence for assistant prose: a compact header (language + copy)
/// over syntax-colored, horizontally-scrollable code — the look of the Codex /
/// Claude desktop transcripts. The coloring comes from `TranscriptCodeHighlighter`
/// via the code block's `label`; this view owns the chrome and the mono font.
private struct TranscriptCodeFence: View {
    let configuration: CodeBlockConfiguration
    let bodySize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // An unlabeled fence (command output, a plain listing) says
                // nothing rather than a generic "code".
                if let languageLabel {
                    Text(languageLabel)
                        .font(.system(size: bodySize * 0.7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                #if os(macOS)
                CopyButton(text: configuration.content, size: bodySize * 0.72)
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(bodySize * 0.86) }
                    .padding(12)
            }
        }
        .transcriptCard()
    }

    private var languageLabel: String? { CodeFenceLabel.text(configuration.language) }
}

enum CodeFenceLabel {
    /// A code fence's header label: its language, lowercased; nil when the
    /// fence has none (or a placeholder like "text"/"code").
    static func text(_ language: String?) -> String? {
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "code", "text", "plain", "plaintext", "txt"].contains(lang) ? nil : lang
    }
}

/// Syntax highlighter for the markdown code fences in assistant prose, so the
/// beautified transcript renders colored code the way Codex / Claude desktop do.
/// MarkdownUI calls `highlightCode` synchronously during body evaluation, so the
/// (comparatively slow) Highlightr / JavaScriptCore pass is memoized in a shared
/// cache — the transcript re-renders on every ~1.5 s poll, and re-highlighting
/// each block every time would hitch. No language, an oversized block, or the
/// iOS port all fall back to plain (uncolored) text.
struct TranscriptCodeHighlighter: CodeSyntaxHighlighter {
    let dark: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let language, !language.isEmpty else { return Text(code) }
        #if os(macOS)
        // MarkdownUI evaluates code blocks during view body on the main thread,
        // so the cache's main-actor state is safe to touch synchronously here.
        return MainActor.assumeIsolated {
            TranscriptHighlightCache.shared.text(for: code, language: language, dark: dark)
        }
        #else
        return Text(code)
        #endif
    }
}

#if os(macOS)
/// Main-thread-only memoizing cache in front of a single Highlightr context.
/// Keyed by (content, language, appearance); LRU-evicted so a long session
/// doesn't grow without bound.
@MainActor
final class TranscriptHighlightCache {
    static let shared = TranscriptHighlightCache()

    private var highlightr: Highlightr?
    private var themeName: String?
    private var cache: [Key: Text] = [:]
    private var order: [Key] = []
    private let maxEntries = 240
    /// Beyond this a synchronous JSC highlight would stall the render; the fence
    /// stays monospaced but uncolored.
    private let maxLength = 12_000

    private struct Key: Hashable {
        let hash: Int
        let count: Int
        let language: String
        let dark: Bool
    }

    func text(for code: String, language: String, dark: Bool) -> Text {
        guard code.count <= maxLength else { return Text(code) }
        let key = Key(hash: code.hashValue, count: code.count, language: language, dark: dark)
        if let hit = cache[key] { return hit }
        let value = render(code, language: language, dark: dark)
        cache[key] = value
        order.append(key)
        if order.count > maxEntries {
            let evict = order.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return value
    }

    private func render(_ code: String, language: String, dark: Bool) -> Text {
        guard let h = highlightr ?? Highlightr() else { return Text(code) }
        highlightr = h
        let theme = dark ? "atom-one-dark" : "xcode"
        if themeName != theme {
            h.setTheme(to: theme)
            themeName = theme
        }
        // Unknown language ids fall back to highlight.js auto-detection inside
        // Highlightr, so pass the fence's language through as-is.
        guard let ns = h.highlight(code, as: language, fastRender: true) else {
            return Text(code)
        }
        return Self.text(from: ns)
    }

    /// One `Text` run per foreground-color span, carrying only the color — the
    /// code-fence view owns the monospaced font, so a baked-in font would fight
    /// its `FontSize`/`FontFamilyVariant`.
    private static func text(from ns: NSAttributedString) -> Text {
        var result = Text(verbatim: "")
        ns.enumerateAttribute(.foregroundColor,
                              in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            let piece = ns.attributedSubstring(from: range).string
            var run = Text(verbatim: piece)
            if let color = value as? NSColor {
                run = run.foregroundStyle(Color(nsColor: color))
            }
            result = result + run
        }
        return result
    }
}
#endif
