import Foundation

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
        switch name {
        case OmpTranscriptParser.toolLookupName:
            return NSLocalizedString("tool lookup", comment: "activity line: omp read a tool's docs (xd://)")
        case OmpTranscriptParser.readOutputName:
            return NSLocalizedString("earlier output", comment: "activity line: omp read a spilled command output (artifact://)")
        default: break
        }
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
            case .toolResult(let tool, let content, let isError):
                if isError, !isProbeExit(tool: tool, content: content) { failures += 1 }
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
            // One step: say what it was. A summary that is already a phrase
            // (omp's "Confirming the file exists") reads alone — "bash
            // Confirming…" mixed a raw tool name into the sentence.
            let tool = humanTool(c.name)
            let summary = c.summary.replacingOccurrences(of: "\n", with: " ")
            parts.append(summary.isEmpty ? tool : isPhrase(summary) ? summary : tool + " " + summary)
        } else {
            parts += order.map { $0.count(counts[$0] ?? 0) }
        }
        return Line(text: parts.joined(separator: " · "),
                    symbols: Array(order.prefix(3).map(\.symbol)),
                    failures: failures)
    }

    /// A step summary written as a sentence (omp's tool `intent`, a Claude
    /// Bash description), not a command line or a path: a capital first
    /// letter, a second word, no shell or path punctuation up front.
    static func isPhrase(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
              let space = t.firstIndex(of: " ") else { return false }
        let head = t[..<space]
        // "Makefile:12", "README.md", "/Users/x", "FOO=1 make", "Rscript x.R"
        if head.contains(where: { "/.=:_$\\-".contains($0) }) { return false }
        let words = t.split(separator: " ")
        guard words.count >= 2 else { return false }
        // A sentence's second word is lowercase or a short word; a command's
        // is a flag or a path.
        let second = words[1]
        return !(second.hasPrefix("-") || second.contains("/"))
    }

    /// A shell step that only came back with exit status 1 — grep finding
    /// nothing, `test`/`[ -f … ]` saying no: the agent probing, not a
    /// failure worth a red "failed" on the line. Other codes still count.
    static func isProbeExit(tool: String, content: String) -> Bool {
        guard category(tool) == .command else { return false }
        let tail = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n").lowercased()
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map { $0.lowercased() } ?? ""
        for s in [tail, head] {
            if s.range(of: #"(exited with code|exit code:?|exit status:?|process exited with code) 1(?![0-9])"#,
                       options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// What the last step of a run in progress is doing.
    static func current(_ items: [TranscriptItem]) -> String {
        for item in items.reversed() {
            switch item.kind {
            case .toolUse(let name, let summary, _):
                let what = summary.isEmpty ? humanTool(name) : summary.replacingOccurrences(of: "\n", with: " ")
                // "Running Confirming the file…" — a phrase says it already.
                if isPhrase(what) { return what.hasSuffix("…") ? what : what + "…" }
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
