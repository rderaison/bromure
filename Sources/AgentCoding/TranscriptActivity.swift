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
    /// about `limit` characters (a fence is never cut).
    static func chunks(_ text: String, limit: Int = chunkChars) -> [String] {
        guard text.count > limit * 3 / 2 else { return [text] }
        var out: [String] = []
        var current = ""
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            // A break is a blank line outside a fence, once the piece is big enough.
            if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty, current.count >= limit {
                out.append(current)
                current = ""
                continue
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out.isEmpty ? [text] : out
    }

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

    static func rows(_ items: [TranscriptItem], chunked: Bool = true,
                     chunkLimit: Int = chunkChars) -> [TranscriptRow] {
        uniqued(buildRows(items, chunked: chunked, chunkLimit: chunkLimit))
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

    private static func buildRows(_ items: [TranscriptItem], chunked: Bool, chunkLimit: Int) -> [TranscriptRow] {
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
                if chunked { out += split(item, limit: chunkLimit).map { .item($0) } } else { out.append(.item(item)) }
            }
            turn.append(item)
        }
        if !run.isEmpty { out.append(.activity(run)) }
        closeTurn()
        return out
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
        for item in items {
            guard case .toolUse(let name, _, let detail) = item.kind,
                  ActivitySummary.category(name) == .edit else { continue }
            c.add(detail)
        }
        return c.files.isEmpty && c.added == 0 && c.removed == 0 ? nil : c
    }

    private static func lines(_ s: String) -> Int {
        let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
        return t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
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
            touch(path); removed += Self.lines(old); added += Self.lines(new)
        } else if let edits = input["edits"] as? [[String: Any]] {
            touch(path)
            for e in edits {
                removed += Self.lines(e["old_string"] as? String ?? e["oldText"] as? String ?? "")
                added += Self.lines(e["new_string"] as? String ?? e["newText"] as? String ?? "")
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

        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .read:    return "doc.text"
            case .edit:    return "pencil"
            case .search:  return "magnifyingglass"
            case .web:     return "globe"
            case .agent:   return "person.2"
            case .other:   return "wrench.and.screwdriver"
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
            case .other:   return String(format: NSLocalizedString("Using %@", comment: "activity line"), what)
            }
        }
    }

    static func category(_ tool: String) -> Category {
        let t = tool.lowercased()
        if t.hasPrefix("mcp__") { return t.contains("delegat") ? .agent : .other }
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
                    ForEach(items) { TranscriptItemView(item: $0) }
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
    var body: some View {
        ForEach(TranscriptRow.rows(items)) { row in
            switch row {
            case .item(let item): TranscriptItemView(item: item).id(row.id)
            case .activity(let run): ActivityGroupView(items: run).id(row.id)
            case .changes(let c, _): TurnChangesView(changes: c).id(row.id)
            }
        }
    }
}
