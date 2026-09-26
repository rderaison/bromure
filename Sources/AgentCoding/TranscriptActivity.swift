import SwiftUI

// MARK: - Activity lines
//
// A chat is the words — yours, the agent's, its questions. What the agent did
// between two of them (tool calls, their results, its thinking) is useful but
// secondary, so each run of it folds into one quiet line — "3 commands · 2
// files read · 1 edit" — that opens to the full detail on a click. Errors
// stay visible on the line; the run in progress shows what it's doing now.

/// A row of the chat: a message on its own, or a run of activity.
enum TranscriptRow: Identifiable {
    case item(TranscriptItem)
    case activity([TranscriptItem])

    /// The first item's id, so scroll anchors keep working.
    var id: Int {
        switch self {
        case .item(let i): return i.id
        case .activity(let a): return a.first?.id ?? 0
        }
    }

    static func isActivity(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .toolUse, .toolResult, .thinking: return true
        default: return false
        }
    }

    static func rows(_ items: [TranscriptItem]) -> [TranscriptRow] {
        var out: [TranscriptRow] = []
        var run: [TranscriptItem] = []
        for item in items {
            if isActivity(item) {
                run.append(item)
            } else {
                if !run.isEmpty { out.append(.activity(run)); run = [] }
                out.append(.item(item))
            }
        }
        if !run.isEmpty { out.append(.activity(run)) }
        return out
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

    /// A tool name for people: "mcp__delegation__request" → "delegation request".
    static func humanTool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst(5).split(separator: "_", omittingEmptySubsequences: true).joined(separator: " ")
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
        for item in items {
            switch item.kind {
            case .toolUse(let name, let summary, _):
                let c = category(name)
                if counts[c] == nil { order.append(c) }
                counts[c, default: 0] += 1
                calls.append((name, summary))
            case .toolResult(_, _, let isError):
                if isError { failures += 1 }
            case .thinking:
                thought = true
            default:
                break
            }
        }
        var parts: [String] = []
        if thought { parts.append(NSLocalizedString("Thought", comment: "activity line")) }
        if calls.count == 1, let c = calls.first {
            // One step: say what it was.
            let what = c.summary.isEmpty ? humanTool(c.name) : c.summary
            parts.append(humanTool(c.name) + " " + what.replacingOccurrences(of: "\n", with: " "))
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
    @State private var open = false
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
            case .item(let item): TranscriptItemView(item: item)
            case .activity(let run): ActivityGroupView(items: run)
            }
        }
    }
}
