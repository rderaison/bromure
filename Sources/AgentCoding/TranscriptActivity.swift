import SwiftUI

// MARK: - Activity lines
//
// A chat is the words — yours, the agent's, its questions. What the agent did
// between two of them (tool calls, their results, its thinking) is useful but
// secondary, so each run of it folds into one quiet line — "3 commands · 2
// files read · 1 edit" — that opens to the full detail on a click. Errors
// stay visible on the line; the run in progress shows what it's doing now.

/// A row of the chat: a message on its own, a run of activity, or what a
/// turn changed in the files.
enum TranscriptRow: Identifiable {
    case item(TranscriptItem)
    case activity([TranscriptItem])
    case changes(TurnChanges, after: Int)

    /// The first item's id, so scroll anchors keep working.
    var id: Int {
        switch self {
        case .item(let i): return i.id
        case .activity(let a): return a.first?.id ?? 0
        case .changes(_, let after): return Self.changesID(after: after)
        }
    }

    // Row ids live in their own space. Item ids are hashes (or, from a
    // parser that numbers by position, small integers; the optimistic echo
    // counts down from Int.max): an id derived by arithmetic (`id * 131 + k`,
    // `-(id + 1)`) could land on another row's — a lazy stack with two rows
    // of one id never settles its placement (B23) — or overflow.

    /// The id of piece `k` (k ≥ 1) of a reply cut into rows.
    static func chunkID(_ itemID: Int, _ k: Int) -> Int {
        var h = Hasher()
        h.combine("reply-piece")
        h.combine(itemID)
        h.combine(k)
        return h.finalize()
    }

    /// The id of the "what this turn changed" row after item `after`.
    static func changesID(after: Int) -> Int {
        var h = Hasher()
        h.combine("turn-changes")
        h.combine(after)
        return h.finalize()
    }

    static func isActivity(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        // Something the agent SHOWS the user (display MCP) is content, not
        // activity: folded into "3 commands · …" it would never be seen.
        case .toolUse(let name, _, let detail):
            return DisplayRequest.parse(name: name, detail: detail) == nil
        case .toolResult, .thinking: return true
        default: return false
        }
    }

    /// A long reply cut into rows of about this many characters, so no row
    /// is several screens tall (a lazy list can't draw one of those).
    static let chunkChars = 2000

    /// The piece size for a chat column `width` points wide: the same
    /// height of row whatever the width — a 2000-character piece is a
    /// screen at 700 pt but five at 180 pt (the chat squeezed by the
    /// browser and files panes), where the lazy stack's re-measure churned.
    /// In steps, so a resize re-cuts the replies only a few times.
    static func chunkLimit(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return chunkChars }
        switch width {
        case ..<260: return 500
        case ..<400: return 900
        case ..<560: return 1400
        default: return chunkChars
        }
    }

    /// `text` split at paragraph breaks outside code fences into pieces of
    /// about `limit` characters (a fence is cut only when it alone runs
    /// past `hardCap` pieces' worth — closed and reopened, so each piece
    /// still renders as code). A piece never grows past `hardCap × limit`:
    /// a reply with no blank line (one giant paragraph, a 20 KB code block)
    /// used to stay one row several screens tall.
    static func chunks(_ text: String, limit: Int = chunkChars) -> [String] {
        let limit = max(1, limit)
        guard text.utf16.count > limit * 3 / 2, text.count > limit * 3 / 2 else { return [text] }
        let cap = limit * hardCap
        var out: [String] = []
        var current = ""
        var size = 0              // current.utf16.count, kept as we go (no O(n) count per line)
        var fence: String?        // the opening line of the fence we're in
        var close = "```"         // what closes it
        func push() {
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
            current = ""
            size = 0
        }
        func add(_ line: Substring) {
            if size > 0 || !current.isEmpty { current += "\n"; size += 1 }
            current += line
            size += line.utf16.count
        }
        // The header + delimiter rows of the pipe table we're in: a table
        // cut mid-way repeats them atop the next piece, which otherwise
        // shows its rows as lines of pipes.
        var tableHead: (Substring, Substring)?
        var previous: Substring?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            defer { previous = raw }
            if fence == nil {
                if tableHead != nil, trimmed.isEmpty || !trimmed.contains("|") || isFence {
                    tableHead = nil
                } else if tableHead == nil, let head = previous, head.contains("|"),
                          let aligns = TranscriptTables.delimiter(trimmed),
                          TranscriptTables.cells(head.trimmingCharacters(in: .whitespaces)).count == aligns.count {
                    tableHead = (head, raw)
                }
            }
            // A break is a blank line outside a fence, once the piece is big enough.
            if fence == nil, trimmed.isEmpty, size >= limit {
                push()
                continue
            }
            // Way past a screen with no break in sight: cut at this line
            // (never at the line that closes a fence — it ends the piece,
            // nor at a table's delimiter row — it belongs to its header).
            if size >= cap, !(isFence && fence != nil), !(tableHead.map { $0.1 == raw } ?? false) {
                if let open = fence {
                    current += "\n" + close
                    push()
                    add(Substring(open))
                } else {
                    push()
                    if let (head, delimiter) = tableHead {
                        add(head)
                        add(delimiter)
                    }
                }
            }
            if isFence {
                if fence == nil {
                    fence = String(raw)
                    close = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                } else {
                    fence = nil
                }
            }
            // One line longer than a whole piece (minified JSON, a base64
            // blob): cut the line itself.
            if raw.utf16.count > cap {
                var rest = raw[...]
                while !rest.isEmpty {
                    let part = rest.prefix(cap)
                    rest = rest.dropFirst(part.count)
                    add(part)
                    if !rest.isEmpty {
                        if fence != nil { current += "\n" + close }
                        push()
                        if let open = fence { add(Substring(open)) }
                    }
                }
                continue
            }
            add(raw)
        }
        push()
        return out.isEmpty ? [text] : out
    }

    /// How many pieces' worth a reply piece may grow to before it is cut
    /// without a paragraph break.
    static let hardCap = 3

    /// The rows of a long reply: the first keeps the item's id (search and
    /// scroll anchors find it), the rest get ids derived from it.
    static func split(_ item: TranscriptItem, limit: Int = chunkChars) -> [TranscriptItem] {
        guard case .assistantText(let text) = item.kind else { return [item] }
        let pieces = chunks(text, limit: limit)
        guard pieces.count > 1 else { return [item] }
        return pieces.enumerated().map { k, piece in
            TranscriptItem(id: k == 0 ? item.id : chunkID(item.id, k), kind: .assistantText(piece),
                           timestamp: item.timestamp)
        }
    }

    /// Every row id of a reply (its first row and each later piece) → the
    /// whole reply, so Copy on ANY piece of a long reply takes all of it
    /// (a selection can't cross the rows, nor a markdown block within one).
    static func replyTexts(_ items: [TranscriptItem], chunkLimit: Int = chunkChars) -> [Int: String] {
        layout(items, chunkLimit: chunkLimit).replies
    }

    static func rows(_ items: [TranscriptItem], chunked: Bool = true,
                     chunkLimit: Int = chunkChars, expanded: Set<Int> = []) -> [TranscriptRow] {
        layout(items, chunked: chunked, chunkLimit: chunkLimit, expanded: expanded).rows
    }

    /// The rows, and what each row of a long message stands for.
    static func layout(_ items: [TranscriptItem], chunked: Bool = true,
                       chunkLimit: Int = chunkChars, expanded: Set<Int> = []) -> TranscriptLayout {
        var out = buildRows(items, chunked: chunked, chunkLimit: chunkLimit, expanded: expanded)
        out.rows = uniqued(out.rows)
        return out
    }

    // MARK: Long messages of yours

    /// Most lines a piece of a long user message holds: a paste of short
    /// lines is screens tall long before it is long in characters.
    static let userLinesPerPiece = 40
    /// The lines a collapsed long message shows.
    static let userPreviewLines = 12

    /// A message of yours too long to show whole by default. A 20 KB paste
    /// was ONE row thousands of points tall (the reply cuts never applied
    /// to user turns): the lazy chat stack placing it never settled and
    /// the app froze. It shows its start, with Show all / Copy.
    static func userCollapses(_ text: String, limit: Int = chunkChars) -> Bool {
        var chars = 0
        var lines = 1
        for u in text.utf16 {
            chars += 1
            if u == 10 { lines += 1 }
        }
        return chars > max(1, limit) * 3 / 2 || lines > userLinesPerPiece * 3 / 2
    }

    /// `text` cut into pieces of at most `limit` characters and `lines`
    /// lines, at line ends (a longer line is cut itself). `maxPieces`
    /// stops early (a preview needs only the first).
    static func userPieces(_ text: String, limit: Int = chunkChars, lines: Int = userLinesPerPiece,
                           maxPieces: Int = .max) -> [String] {
        let limit = max(1, limit), lines = max(1, lines)
        var out: [String] = []
        var current = ""
        var size = 0
        var count = 0
        func flush() {
            if count > 0 { out.append(current) }
            current = ""
            size = 0
            count = 0
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = raw[...]
            repeat {
                let part = rest.prefix(limit)
                rest = rest.dropFirst(part.count)
                let n = part.utf16.count
                if count > 0, size + n + 1 > limit || count >= lines {
                    flush()
                    if out.count >= maxPieces { return out }
                }
                if count > 0 { current += "\n" }
                current += part
                size += n + (count > 0 ? 1 : 0)
                count += 1
            } while !rest.isEmpty
        }
        flush()
        return Array(out.prefix(maxPieces))
    }

    /// The start of a long message, shown while it's collapsed.
    static func userPreview(_ text: String, limit: Int = chunkChars) -> String {
        userPieces(text, limit: max(200, limit / 2), lines: userPreviewLines, maxPieces: 1).first ?? text
    }

    /// Whether a user turn is the user's own words (a host aside or a
    /// delegation notice renders as its own short line, never cut).
    private static func isOwnWords(_ text: String) -> Bool {
        DelegationNotice.strip(text) == nil && DelegationNotice.stripSwitchboard(text) == nil
            && !DelegationNotice.isHostAside(text)
    }

    /// The rows of one user turn: itself, or — long — its preview
    /// (collapsed) or its pieces (expanded), with what each row stands for.
    private static func userRows(_ item: TranscriptItem, text: String, limit: Int,
                                 expanded: Bool, into layout: inout TranscriptLayout) -> [TranscriptItem] {
        guard isOwnWords(text) else { return [item] }
        let shown = CodingTask.displayPrompt(text)
        guard userCollapses(shown, limit: limit) else { return [item] }
        let total = shown.count
        if !expanded {
            let row = TranscriptItem(id: item.id, kind: .userText(userPreview(shown, limit: limit)),
                                     timestamp: item.timestamp)
            layout.longUsers[row.id] = LongUserMessage(itemID: item.id, whole: shown, total: total,
                                                       expanded: false, controls: true)
            return [row]
        }
        let pieces = userPieces(shown, limit: limit)
        return pieces.enumerated().map { k, piece in
            let row = TranscriptItem(id: k == 0 ? item.id : chunkID(item.id, k), kind: .userText(piece),
                                     timestamp: item.timestamp)
            layout.longUsers[row.id] = LongUserMessage(itemID: item.id, whole: shown, total: total,
                                                       expanded: true, controls: k == pieces.count - 1)
            return row
        }
    }

    /// No two rows with one id, whatever the items brought: a repeat is
    /// re-keyed (its content stays).
    static func uniqued(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var seen = Set<Int>()
        seen.reserveCapacity(rows.count)
        return rows.map { row in
            var r = row
            var salt = 0
            rekey: while !seen.insert(r.id).inserted {
                salt += 1
                switch row {
                case .item(let i):
                    r = .item(TranscriptItem(id: chunkID(i.id, -salt), kind: i.kind, timestamp: i.timestamp))
                case .activity(var run):
                    guard let first = run.first else { break rekey }
                    run[0] = TranscriptItem(id: chunkID(first.id, -salt), kind: first.kind, timestamp: first.timestamp)
                    r = .activity(run)
                case .changes(let c, let after):
                    r = .changes(c, after: chunkID(after, -salt))
                }
            }
            return r
        }
    }

    private static func buildRows(_ items: [TranscriptItem], chunked: Bool, chunkLimit: Int,
                                  expanded: Set<Int>) -> TranscriptLayout {
        var layout = TranscriptLayout()
        var out: [TranscriptRow] = []
        var run: [TranscriptItem] = []
        var turn: [TranscriptItem] = []
        func closeTurn() {
            if let c = TurnChanges.of(turn), let last = turn.last { out.append(.changes(c, after: last.id)) }
            turn = []
        }
        for item in items {
            if isActivity(item) {
                run.append(item)
            } else {
                if !run.isEmpty { out.append(.activity(run)); run = [] }
                // Your next message closes the agent's turn: its changes go
                // at the end of it.
                if case .userText = item.kind { closeTurn() }
                switch item.kind {
                case .assistantText(let text):
                    let pieces = chunked ? split(item, limit: chunkLimit) : [item]
                    for p in pieces where layout.replies[p.id] == nil { layout.replies[p.id] = text }
                    out += pieces.map { .item($0) }
                case .userText(let text) where chunked:
                    out += userRows(item, text: text, limit: chunkLimit,
                                    expanded: expanded.contains(item.id), into: &layout).map { .item($0) }
                default:
                    out.append(.item(item))
                }
            }
            turn.append(item)
        }
        if !run.isEmpty { out.append(.activity(run)) }
        closeTurn()
        layout.rows = out
        return layout
    }
}

/// The chat's rows, and what the rows of a long message stand for.
struct TranscriptLayout {
    var rows: [TranscriptRow] = []
    /// Row id → the whole reply it is (a piece of).
    var replies: [Int: String] = [:]
    /// Row id → the long message of yours it shows (in part).
    var longUsers: [Int: LongUserMessage] = [:]
}

/// A message of yours too long to show whole (see `TranscriptRow.userCollapses`).
struct LongUserMessage: Equatable {
    /// The transcript item it is (the expand/collapse key).
    let itemID: Int
    /// All of it, as the chat shows it (Copy, Edit).
    let whole: String
    /// Its length in characters.
    let total: Int
    let expanded: Bool
    /// The row that carries Show all / Show less (the preview, or the last piece).
    let controls: Bool
}

/// Under a long message of yours: how much shows, Show all / Show less, Copy.
struct LongUserMessageBar: View {
    let message: LongUserMessage
    let onToggle: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: message.expanded
                        ? NSLocalizedString("%@ characters", comment: "long message of yours: its length")
                        : NSLocalizedString("Showing the start of %@ characters", comment: "long message of yours, collapsed"),
                        Self.number(message.total)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(message.expanded
                   ? NSLocalizedString("Show less", comment: "long message of yours")
                   : NSLocalizedString("Show all", comment: "long message of yours"),
                   action: onToggle)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
            Button {
                platformCopyToPasteboard(message.whole)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
            } label: {
                Label(NSLocalizedString("Copy message", comment: "long message of yours"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// What one turn changed: the files the agent's edits touched and the lines
/// they added and removed — counted from its own edit calls.
struct TurnChanges: Equatable {
    var files: [String] = []
    var added = 0
    var removed = 0
    /// When the turn began: its review diffs from the last commit before it,
    /// so the changes show even once the agent has committed them.
    var since: Date?

    static func of(_ items: [TranscriptItem]) -> TurnChanges? {
        var c = TurnChanges()
        c.since = items.compactMap(\.timestamp).min()
        for (i, item) in items.enumerated() {
            guard case .toolUse(let name, _, let detail) = item.kind,
                  ActivitySummary.category(name) == .edit,
                  !isUnsettledEdit(at: i, in: items) else { continue }
            c.add(detail)
        }
        return c.files.isEmpty && c.added == 0 && c.removed == 0 ? nil : c
    }

    /// An edit that hasn't happened (yet): nothing after it so far — the
    /// agent is waiting for its approval, or still applying it — or its
    /// result says it failed (refused).
    static func isUnsettledEdit(at i: Int, in items: [TranscriptItem]) -> Bool {
        guard case .toolUse(let name, _, _) = items[i].kind else { return false }
        let after = items[(i + 1)...].filter {
            if case .thinking = $0.kind { return false }
            return true
        }
        guard !after.isEmpty else { return true }
        for item in after {
            if case .toolResult(let tool, _, let isError) = item.kind, tool == name { return isError }
        }
        return false
    }

    private static func lines(_ s: String) -> Int {
        let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
        return t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// An edit's old → new text counted as the review's diff counts it:
    /// lines kept on both sides are no change. (Counting every line of each
    /// side made "+12 −3" of an edit the review showed as "+9 −0".)
    private mutating func count(_ old: String, _ new: String) {
        let d = Self.lineDiff(old, new)
        added += d.added; removed += d.removed
    }

    /// Lines added and removed between `old` and `new` (a longest common
    /// subsequence of lines; past a size cap, every differing line between
    /// the common head and tail).
    static func lineDiff(_ old: String, _ new: String) -> (added: Int, removed: Int) {
        func split(_ s: String) -> [Substring] {
            let t = s.hasSuffix("\n") ? Substring(s.dropLast()) : Substring(s)
            return t.isEmpty ? [] : t.split(separator: "\n", omittingEmptySubsequences: false)
        }
        var a = split(old)[...], b = split(new)[...]
        while let x = a.first, let y = b.first, x == y { a = a.dropFirst(); b = b.dropFirst() }
        while let x = a.last, let y = b.last, x == y { a = a.dropLast(); b = b.dropLast() }
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return (m, n) }
        guard n * m <= 1_000_000 else { return (m, n) }
        let aa = Array(a), bb = Array(b)
        var prev = [Int](repeating: 0, count: m + 1), cur = prev
        for i in 1...n {
            for j in 1...m {
                cur[j] = aa[i - 1] == bb[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        let common = prev[m]
        return (m - common, n - common)
    }

    private mutating func touch(_ path: String?) {
        guard let p = path?.trimmingCharacters(in: .whitespaces), !p.isEmpty, !files.contains(p) else { return }
        files.append(p)
    }

    /// One edit call's input: Claude/omp edits (old → new), whole-file
    /// writes, multi-edits, and patches (Codex apply_patch, unified diffs).
    private mutating func add(_ detail: String) {
        let json = (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any]
        guard let input = json else { patch(detail); return }
        let path = ["file_path", "path", "notebook_path", "filePath"].lazy
            .compactMap { input[$0] as? String }.first
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            touch(path); count(old, new)
        } else if let edits = input["edits"] as? [[String: Any]] {
            touch(path)
            for e in edits {
                count(e["old_string"] as? String ?? e["oldText"] as? String ?? "",
                      e["new_string"] as? String ?? e["newText"] as? String ?? "")
            }
        } else if let content = input["content"] as? String {
            touch(path); added += Self.lines(content)
        } else if let p = ["patch", "input", "diff"].lazy.compactMap({ input[$0] as? String }).first {
            patch(p, path: path)
        } else {
            touch(path)
        }
    }

    private mutating func patch(_ text: String, path: String? = nil) {
        touch(path)
        for line in text.components(separatedBy: "\n") {
            for header in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "+++ b/"]
            where line.hasPrefix(header) {
                touch(String(line.dropFirst(header.count)))
            }
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("***") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
    }
}

extension Notification.Name {
    /// "Show me the changes" ([String] of a turn's files, or nil): the key
    /// window opens the session's review.
    static let bromureShowChanges = Notification.Name("io.bromure.showChanges")
    /// Scroll the chat on stage to the first message with these words.
    static let bromureFindInChat = Notification.Name("io.bromure.findInChat")
}

/// The session a chat shows, for what its rows open (the review of a turn's
/// changes): set by the chat and the resting views; nil = the one on stage.
private struct ChangesSessionKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    var changesSessionID: UUID? {
        get { self[ChangesSessionKey.self] }
        set { self[ChangesSessionKey.self] = newValue }
    }
}

/// The end of a turn that edited files: "Changed 3 files  +120 −35" — a
/// click opens the review on those files; hover lists them.
struct TurnChangesView: View {
    let changes: TurnChanges
    @Environment(\.changesSessionID) private var sessionID
    @State private var hovering = false

    var body: some View {
        Button {
            // The turn's files, and whose they are: the key window opens that
            // session's review on them (in a room too, where no single session
            // is selected).
            var info: [String: Any] = [:]
            if let sessionID { info["session"] = sessionID }
            if let since = changes.since { info["since"] = since }
            NotificationCenter.default.post(name: .bromureShowChanges, object: changes.files,
                                            userInfo: info)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(changes.files.count == 1
                     ? NSLocalizedString("Changed 1 file", comment: "turn changes")
                     : String(format: NSLocalizedString("Changed %d files", comment: "turn changes"), changes.files.count))
                    .font(.system(size: 12, weight: .medium))
                if changes.added > 0 {
                    Text("+\(changes.added)").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if changes.removed > 0 {
                    Text("−\(changes.removed)").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(hovering ? 0.12 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(changes.files.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
    }
}

/// What a run of activity amounts to, in a few words.
enum ActivitySummary {
    enum Category: Int, CaseIterable {
        case command, read, edit, search, web, agent, other
        /// Bromure's delegation tools (hand work to another session, hear
        /// back) — not subagents of the agent's own.
        case delegation

        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .read:    return "doc.text"
            case .edit:    return "pencil"
            case .search:  return "magnifyingglass"
            case .web:     return "globe"
            case .agent:   return "person.2"
            case .other:   return "wrench.and.screwdriver"
            case .delegation: return "arrow.left.arrow.right"
            }
        }

        /// "3 commands", "1 file read"…
        func count(_ n: Int) -> String {
            switch self {
            case .command: return n == 1 ? NSLocalizedString("1 command", comment: "activity line")
                : String(format: NSLocalizedString("%d commands", comment: "activity line"), n)
            case .read: return n == 1 ? NSLocalizedString("1 file read", comment: "activity line")
                : String(format: NSLocalizedString("%d files read", comment: "activity line"), n)
            case .edit: return n == 1 ? NSLocalizedString("1 edit", comment: "activity line")
                : String(format: NSLocalizedString("%d edits", comment: "activity line"), n)
            case .search: return n == 1 ? NSLocalizedString("1 search", comment: "activity line")
                : String(format: NSLocalizedString("%d searches", comment: "activity line"), n)
            case .web: return n == 1 ? NSLocalizedString("1 web page", comment: "activity line")
                : String(format: NSLocalizedString("%d web pages", comment: "activity line"), n)
            case .agent: return n == 1 ? NSLocalizedString("1 subagent", comment: "activity line")
                : String(format: NSLocalizedString("%d subagents", comment: "activity line"), n)
            case .other: return n == 1 ? NSLocalizedString("1 tool call", comment: "activity line")
                : String(format: NSLocalizedString("%d tool calls", comment: "activity line"), n)
            case .delegation: return n == 1 ? NSLocalizedString("1 delegation call", comment: "activity line: Bromure delegation tool calls")
                : String(format: NSLocalizedString("%d delegation calls", comment: "activity line: Bromure delegation tool calls"), n)
            }
        }

        /// "Running npm test" — the step in progress.
        func doing(_ what: String) -> String {
            switch self {
            case .command: return String(format: NSLocalizedString("Running %@", comment: "activity line"), what)
            case .read:    return String(format: NSLocalizedString("Reading %@", comment: "activity line"), what)
            case .edit:    return String(format: NSLocalizedString("Editing %@", comment: "activity line"), what)
            case .search:  return String(format: NSLocalizedString("Searching %@", comment: "activity line"), what)
            case .web:     return String(format: NSLocalizedString("Fetching %@", comment: "activity line"), what)
            case .agent:   return String(format: NSLocalizedString("Delegating %@", comment: "activity line"), what)
            case .other, .delegation:
                return String(format: NSLocalizedString("Using %@", comment: "activity line"), what)
            }
        }
    }

    static func category(_ tool: String) -> Category {
        let t = tool.lowercased()
        if t.hasPrefix("mcp__") { return t.contains("delegat") ? .delegation : .other }
        switch t {
        case "bash", "shell", "exec_command", "exec", "run", "run_command", "terminal", "local_shell":
            return .command
        case "read", "read_file", "view", "cat", "notebookread", "read_many_files":
            return .read
        case "edit", "write", "multiedit", "apply_patch", "str_replace", "str_replace_editor", "create",
             "notebookedit", "write_file", "edit_file", "patch":
            return .edit
        case "grep", "glob", "find", "search", "ls", "list", "list_dir", "toolsearch", "codebase_search", "rg":
            return .search
        case "webfetch", "websearch", "fetch", "web_search", "browse", "web_fetch":
            return .web
        case "task", "agent", "subagent", "spawn_agent":
            return .agent
        default:
            return .other
        }
    }

    /// A tool name for people: "mcp__delegation__request" → "delegation
    /// request". A tool that already repeats its server's name says it once
    /// (B71): "mcp__browser__browser_evaluate" → "browser evaluate", not
    /// "browser browser evaluate".
    static func humanTool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let rest = name.dropFirst(5)
        var words: [Substring]
        if let sep = rest.range(of: "__") {
            let server = rest[..<sep.lowerBound]
            var tool = rest[sep.upperBound...]
            let s = server.lowercased(), t = tool.lowercased()
            if !s.isEmpty, t.count > s.count, t.hasPrefix(s),
               let next = t.dropFirst(s.count).first, next == "_" || next == "-" {
                tool = tool.dropFirst(s.count + 1)
            }
            words = server.split(whereSeparator: { $0 == "_" || $0 == "-" })
                + tool.split(separator: "_", omittingEmptySubsequences: true)
        } else {
            words = rest.split(separator: "_", omittingEmptySubsequences: true)
        }
        return words.joined(separator: " ")
    }

    /// What a lone tool result (its call shown elsewhere) answered.
    enum ResultKind: Hashable {
        case media, chart, file, other

        init(tool: String) {
            let t = tool.lowercased()
            let display = t.contains("display") || !t.contains("__")
            if display, t.hasSuffix("show_media") { self = .media }
            else if display, t.hasSuffix("show_chart") { self = .chart }
            else if display, t.hasSuffix("send_file") { self = .file }
            else { self = .other }
        }

        var symbol: String {
            switch self {
            case .media: return "photo"
            case .chart: return "chart.bar"
            case .file:  return "arrow.down.doc"
            case .other: return "wrench.and.screwdriver"
            }
        }

        func count(_ n: Int) -> String {
            switch self {
            case .media: return n == 1 ? NSLocalizedString("1 media item shown", comment: "activity line")
                : String(format: NSLocalizedString("%d media items shown", comment: "activity line"), n)
            case .chart: return n == 1 ? NSLocalizedString("1 chart shown", comment: "activity line")
                : String(format: NSLocalizedString("%d charts shown", comment: "activity line"), n)
            case .file: return n == 1 ? NSLocalizedString("1 file sent", comment: "activity line")
                : String(format: NSLocalizedString("%d files sent", comment: "activity line"), n)
            case .other: return n == 1 ? NSLocalizedString("1 tool result", comment: "activity line")
                : String(format: NSLocalizedString("%d tool results", comment: "activity line"), n)
            }
        }
    }

    struct Line {
        var text: String
        var symbols: [String]
        var failures: Int
    }

    /// The texts of a run made only of thinking (consecutive repeats — an
    /// agent journaling the same thought twice — once), else nil.
    static func thoughtsOnly(_ items: [TranscriptItem]) -> [String]? {
        var out: [String] = []
        for item in items {
            guard case .thinking(let t) = item.kind else { return nil }
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, out.last != text { out.append(text) }
        }
        return items.isEmpty ? nil : out
    }

    static func line(_ items: [TranscriptItem]) -> Line {
        var counts: [Category: Int] = [:]
        var order: [Category] = []
        var failures = 0
        var thought = false
        var calls: [(name: String, summary: String)] = []
        var results: [String] = []   // the tool each result answers
        for item in items {
            switch item.kind {
            case .toolUse(let name, let summary, _):
                let c = category(name)
                if counts[c] == nil { order.append(c) }
                counts[c, default: 0] += 1
                calls.append((name, summary))
            case .toolResult(let tool, _, let isError):
                if isError { failures += 1 }
                results.append(tool)
            case .thinking:
                thought = true
            default:
                break
            }
        }
        // Only results (B69): a display-MCP call is content — its card sits
        // in the chat, outside the run — so a run of show_media results has
        // no call to describe. Name what they answered instead of an
        // unlabeled chip.
        if calls.isEmpty, !results.isEmpty {
            var resultParts: [ResultKind: Int] = [:]
            var resultOrder: [ResultKind] = []
            for tool in results {
                let k = ResultKind(tool: tool)
                if resultParts[k] == nil { resultOrder.append(k) }
                resultParts[k, default: 0] += 1
            }
            var parts: [String] = []
            if thought { parts.append(NSLocalizedString("Thought", comment: "activity line")) }
            parts += resultOrder.map { $0.count(resultParts[$0] ?? 0) }
            return Line(text: parts.joined(separator: " · "),
                        symbols: Array(resultOrder.prefix(3).map(\.symbol)),
                        failures: failures)
        }
        var parts: [String] = []
        if thought { parts.append(NSLocalizedString("Thought", comment: "activity line")) }
        if calls.count == 1, let c = calls.first {
            // One step: say what it was.
            let tool = humanTool(c.name)
            parts.append(c.summary.isEmpty ? tool
                         : tool + " " + c.summary.replacingOccurrences(of: "\n", with: " "))
        } else {
            parts += order.map { $0.count(counts[$0] ?? 0) }
        }
        return Line(text: parts.joined(separator: " · "),
                    symbols: Array(order.prefix(3).map(\.symbol)),
                    failures: failures)
    }

    /// What the last step of a run in progress is doing.
    static func current(_ items: [TranscriptItem]) -> String {
        for item in items.reversed() {
            switch item.kind {
            case .toolUse(let name, let summary, _):
                let what = summary.isEmpty ? humanTool(name) : summary.replacingOccurrences(of: "\n", with: " ")
                return category(name).doing(what) + "…"
            case .toolResult:
                return NSLocalizedString("Thinking…", comment: "activity line")
            case .thinking:
                return NSLocalizedString("Thinking…", comment: "activity line")
            default:
                continue
            }
        }
        return NSLocalizedString("Working…", comment: "activity line")
    }
}

/// One folded run of activity: a quiet pill that opens to the detail.
struct ActivityGroupView: View {
    let items: [TranscriptItem]
    /// The run the agent is in right now.
    var live = false
    /// Debug/screenshot hook: new lines start open.
    nonisolated(unsafe) static var startOpen = false
    @State private var open = ActivityGroupView.startOpen
    @State private var hovering = false

    var body: some View {
        let line = ActivitySummary.line(items)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if live {
                        ProgressView().controlSize(.mini)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(line.symbols.isEmpty ? ["sparkle"] : line.symbols, id: \.self) {
                                Image(systemName: $0)
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    }
                    Text(live ? ActivitySummary.current(items) : line.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if line.failures > 0 {
                        Text(line.failures == 1
                             ? NSLocalizedString("1 failed", comment: "activity line")
                             : String(format: NSLocalizedString("%d failed", comment: "activity line"), line.failures))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(hovering || open ? 0.07 : 0.04)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(open ? NSLocalizedString("Hide the details", comment: "activity line")
                       : NSLocalizedString("Show what the agent did", comment: "activity line"))
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    if let thoughts = ActivitySummary.thoughtsOnly(items) {
                        // A run that is only thinking: the line already says
                        // "Thought" — its text, not a second "Thinking" row.
                        ForEach(Array(thoughts.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .font(.system(size: 11.5))
                                .italic()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(items) { TranscriptItemView(item: $0) }
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.08)).frame(width: 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A transcript as rows: messages on their own, activity folded.
struct TranscriptRowsView: View {
    let items: [TranscriptItem]
    /// Long messages of yours opened in full (item ids).
    @State private var expanded: Set<Int> = []
    var body: some View {
        let layout = TranscriptRow.layout(items, expanded: expanded)
        ForEach(layout.rows) { row in
            switch row {
            case .item(let item):
                if let long = layout.longUsers[item.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        TranscriptItemView(item: item)
                        if long.controls {
                            LongUserMessageBar(message: long) {
                                if long.expanded { expanded.remove(long.itemID) } else { expanded.insert(long.itemID) }
                            }
                        }
                    }
                    .id(row.id)
                } else {
                    TranscriptItemView(item: item).replyCopyMenu(layout.replies[item.id]).id(row.id)
                }
            case .activity(let run): ActivityGroupView(items: run).id(row.id)
            case .changes(let c, _): TurnChangesView(changes: c).id(row.id)
            }
        }
    }
}

// MARK: - Copying out

/// What leaves the chat on Copy: a whole reply (as markdown or as plain
/// text), and output the transcript shows only the start of.
enum TranscriptCopy {
    /// The most of a tool's output a result row shows (a giant `Text` stalls
    /// the layout); Copy full output takes the rest.
    static let outputLimit = 20_000
    /// The most of an error message an error row shows.
    static let errorLimit = 4_000

    /// `text` cut to `limit` characters, with its full length; `total` is
    /// nil when nothing was cut.
    static func clip(_ text: String, limit: Int) -> (shown: String, total: Int?) {
        let n = text.count
        guard n > limit else { return (text, nil) }
        return (String(text.prefix(limit)), n)
    }

    /// "Showing first 20,000 of 153,201 characters".
    static func truncationMarker(shown: Int, total: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return String(format: NSLocalizedString("Showing first %@ of %@ characters", comment: "truncated transcript output"),
                      f.string(from: NSNumber(value: shown)) ?? "\(shown)",
                      f.string(from: NSNumber(value: total)) ?? "\(total)")
    }

    /// A reply's markdown as plain text, line for line: fences, heading and
    /// quote markers, emphasis, code ticks and link targets dropped; list
    /// markers and code (the fence's contents) kept as they are.
    static func plainText(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { out.append(raw); continue }
            var line = raw
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s{0,3}(>\s?)+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\(([^)]*)\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "`", with: "")
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// Copy Reply / Copy as Markdown on a right-click of any row of a reply —
/// a selection stops at a paragraph (each markdown block is its own text).
struct ReplyCopyMenu: ViewModifier {
    /// The whole reply (markdown); nil adds nothing.
    let reply: String?
    func body(content: Content) -> some View {
        if let reply {
            content.contextMenu {
                Button(NSLocalizedString("Copy Reply", comment: "chat reply menu")) {
                    platformCopyToPasteboard(TranscriptCopy.plainText(reply))
                }
                Button(NSLocalizedString("Copy as Markdown", comment: "chat reply menu")) {
                    platformCopyToPasteboard(reply)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func replyCopyMenu(_ reply: String?) -> some View { modifier(ReplyCopyMenu(reply: reply)) }
}
