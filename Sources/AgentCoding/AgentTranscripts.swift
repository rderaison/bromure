import Foundation

// The agents' transcript models and parsers (Claude, Codex, Grok, Kimi,
// omp): what a transcript says, without SwiftUI. The views that render them
// are in ClaudeTranscriptView.swift.

// MARK: - Transcript model + parser

/// One rendered element of a Claude Code session transcript.
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
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
        /// A consolidated todo/plan checklist that updates IN PLACE as the agent
        /// ticks items off (rather than one card per update). Emitted by the omp
        /// parser, which merges the plan's items with the latest todo-tool
        /// result (its authoritative per-item status).
        case todo(title: String, rows: [TodoRowModel])
        /// A turn the provider refused (bad sign-in, quota, overload),
        /// as the agent itself recorded it.
        case agentError(AgentAPIError)
    }
    let id: Int
    var kind: Kind
    var timestamp: Date?
}

/// An API failure read from the agent's own transcript, typed by what the
/// agent wrote down — an error enum, an HTTP status — never by its wording,
/// which is English today, changes between versions, and on some agents
/// is the provider's message passed through in any language.
struct AgentAPIError: Equatable {
    /// `blocked`: Bromure's own proxy refused the request (its 451) — not
    /// the provider, which was never reached.
    enum Kind: String, Equatable { case auth, quota, rateLimit, overloaded, other, blocked }
    let kind: Kind
    let status: Int?
    /// What the agent showed for it, for the card's detail line.
    let message: String

    init(kind: Kind, status: Int?, message: String) {
        self.kind = Self.isBromureBlock(status: status, message: message) ? .blocked : kind
        self.status = status
        self.message = message
    }

    /// Which of Bromure's engines blocked it, when `kind == .blocked`.
    var blockedBy: BromureBlock? { kind == .blocked ? (BromureBlock.of(message) ?? .unknown) : nil }

    var headline: String {
        switch kind {
        case .auth: NSLocalizedString("The agent couldn't authenticate", comment: "failure")
        case .quota, .rateLimit: NSLocalizedString("The agent hit a usage limit", comment: "failure")
        case .overloaded, .other: NSLocalizedString("The agent stopped with an error", comment: "failure")
        case .blocked: (blockedBy ?? .unknown).headline
        }
    }

    /// Bromure's proxy answers a request it blocks with a 451 and a body
    /// naming itself ("Bromure blocked this request: possible prompt
    /// injection…"): the agent then reports an API error that is NOT the
    /// provider's — it read as "Provider unreachable" (S3-4).
    static func isBromureBlock(status: Int?, message: String) -> Bool {
        status == 451 || BromureBlock.of(message) != nil
            || (Self.status(in: message) == 451)
    }

    /// When the agent's own enum says nothing more specific: the HTTP status.
    /// 403 stays `.other` — a refused permission on some providers, an empty
    /// balance on others.
    static func kind(forStatus status: Int?) -> Kind {
        switch status {
        case 401: .auth
        case 402: .quota
        case 429: .rateLimit
        case 503, 529: .overloaded
        default: .other
        }
    }

    /// The first HTTP-looking status in an agent's error message — "API
    /// Error: 401 …", "unexpected status 401 Unauthorized", "(status 429 Too
    /// Many Requests)", "Unauthorized (401) from …". Numbers only, so it
    /// reads the same whatever language the rest is in.
    static func status(in message: String) -> Int? {
        let pattern = #"(?<![\d.])(40[0-9]|42[0-9]|451|5[0-9]{2})(?![\d.])"#
        guard let r = message.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(message[r])
    }

    /// Claude Code: `error` on an `isApiErrorMessage` line (also the
    /// StopFailure hook's enum).
    static func claude(error: String?, status: Int?, message: String) -> AgentAPIError {
        let kind: Kind
        switch error ?? "" {
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold",
             "verification_required", "cloud_credential_error": kind = .auth
        case "billing_error": kind = .quota
        case "rate_limit": kind = .rateLimit
        case "overloaded", "server_error": kind = .overloaded
        default: kind = Self.kind(forStatus: status ?? Self.status(in: message))
        }
        return AgentAPIError(kind: kind, status: status ?? Self.status(in: message), message: message)
    }

    /// Codex: `codex_error_info` (rollout, snake_case) / `codexErrorInfo`
    /// (app-server, camelCase). An API-key 401 comes through as "other".
    static func codex(info: String?, message: String) -> AgentAPIError {
        let status = Self.status(in: message)
        let kind: Kind
        switch (info ?? "").replacingOccurrences(of: "_", with: "").lowercased() {
        case "unauthorized": kind = .auth
        case "usagelimitexceeded", "sessionbudgetexceeded": kind = .quota
        case "ratelimitexceeded": kind = .rateLimit
        case "serveroverloaded": kind = .overloaded
        default: kind = Self.kind(forStatus: status)
        }
        return AgentAPIError(kind: kind, status: status, message: message)
    }

    /// Kimi Code: `turn.ended` error `code` + class `name` + `statusCode`.
    static func kimi(code: String?, name: String?, status: Int?, message: String) -> AgentAPIError {
        let code = code ?? ""
        let kind: Kind
        if code == "provider.auth_error" || code.hasPrefix("auth.") {
            kind = .auth
        } else if name == "APIProviderQuotaExhaustedError" {
            kind = .quota
        } else if code == "provider.rate_limit" || name == "APIProviderRateLimitError" {
            kind = .rateLimit
        } else {
            kind = Self.kind(forStatus: status ?? Self.status(in: message))
        }
        return AgentAPIError(kind: kind, status: status ?? Self.status(in: message), message: message)
    }

    /// Grok: `retry_state.error_type` (auth / rate_limited / api).
    static func grok(errorType: String?, rateLimited: Bool, message: String) -> AgentAPIError {
        let status = Self.status(in: message)
        let kind: Kind
        switch errorType ?? "" {
        case "auth": kind = .auth
        case "rate_limited": kind = .rateLimit
        default: kind = rateLimited ? .rateLimit : Self.kind(forStatus: status)
        }
        return AgentAPIError(kind: kind, status: status, message: message)
    }

    /// Oh My Pi: the `errorId` classifier bitfield (pi-ai error/flags.ts)
    /// and `errorStatus`.
    static func omp(errorID: Int?, status: Int?, message: String) -> AgentAPIError {
        let id = errorID ?? 0
        let kind: Kind
        if id & 0x1000000 != 0 || id & 0x40000000 != 0 { kind = .auth }        // AuthFailed, OAuthExpiry
        else if id & 0x80000 != 0 { kind = .quota }                              // UsageLimit
        else { kind = Self.kind(forStatus: status ?? Self.status(in: message)) }
        return AgentAPIError(kind: kind, status: status ?? Self.status(in: message), message: message)
    }
}

/// Which Bromure engine blocked a request, from the body it answered with.
enum BromureBlock: String, Equatable {
    case promptInjection, rulesInjection, credentialLeak, supplyChain, clientCertificate, unknown

    static func of(_ message: String) -> BromureBlock? {
        let m = message.lowercased()
        if m.contains("bromure blocked this request") || m.contains("bromure blocked: possible") {
            return m.contains("rogue instructions") ? .rulesInjection : .promptInjection
        }
        if m.contains("bromure: outbound request blocked") { return .credentialLeak }
        if m.contains("bromure supply-chain security blocked") { return .supplyChain }
        if m.contains("bromure: client-certificate use denied") { return .clientCertificate }
        return nil
    }

    /// The card's headline.
    var headline: String {
        switch self {
        case .promptInjection:
            NSLocalizedString("Blocked by Bromure — prompt injection", comment: "failure: Bromure's proxy blocked the request")
        case .rulesInjection:
            NSLocalizedString("Blocked by Bromure — rogue instructions", comment: "failure: Bromure's proxy blocked the request")
        case .credentialLeak:
            NSLocalizedString("Blocked by Bromure — credential leak", comment: "failure: Bromure's proxy blocked the request")
        case .supplyChain:
            NSLocalizedString("Blocked by Bromure — supply chain", comment: "failure: Bromure's proxy blocked the request")
        case .clientCertificate:
            NSLocalizedString("Blocked by Bromure — client certificate", comment: "failure: Bromure's proxy blocked the request")
        case .unknown:
            NSLocalizedString("Blocked by Bromure", comment: "failure: Bromure's proxy blocked the request")
        }
    }

    /// What the user can do next, when there's more to say than "send
    /// again": a blocked tool output stays in the agent's conversation and is
    /// resent every turn — Bromure now takes it out of later requests.
    var recoveryHint: String? {
        switch self {
        case .promptInjection:
            NSLocalizedString(
                "Nothing reached the provider. Bromure removes the blocked tool output from this conversation's later requests, so you can send your next message. If the agent keeps failing, rewind the conversation past that step or start a new session.",
                comment: "failure hint: a prompt-injection block, and how to go on")
        default: nil
        }
    }
}

extension TranscriptItem.Kind {
    /// The case alone, for identity (see `AgentTranscript.stableIDs`).
    var stableTag: Int {
        switch self {
        case .userText: 1
        case .assistantText: 2
        case .thinking: 3
        case .toolUse: 4
        case .toolResult: 5
        case .question: 6
        case .todo: 7
        case .agentError: 8
        }
    }
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
    /// What the user picked, once the transcript records the answer (""
    /// when answered but the pick isn't recorded); nil while unanswered.
    var answer: String? = nil
    /// The user dismissed the question instead of answering.
    var declined = false

    var isResolved: Bool { answer != nil || declined }

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
        /// AskUserQuestion tool_use id → its question items, so the
        /// result can mark them answered.
        var questionItems: [String: [Int]] = [:]
        /// Question texts of the last AskUserQuestion seen in the
        /// transcript proper — a pq hook dump matching that round is
        /// stale or already displayed, not pending.
        var lastAskedQuestions: [String] = []
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

            // `/compact`'s summary is written as a user message ("This
            // session is being continued from a previous conversation…"):
            // not something the user said — one folded row, the summary
            // behind its disclosure.
            if type == "user", obj["isCompactSummary"] as? Bool == true {
                add(compactSummaryItem(resultText(message["content"])))
                continue
            }

            // A refused API call ("Please run /login · API Error: 401 …"),
            // written as a synthetic assistant turn but tagged with its enum
            // and status — the tags are the signal, the text only the detail.
            if type == "assistant", obj["isApiErrorMessage"] as? Bool == true {
                let text = resultText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                add(.agentError(.claude(error: obj["error"] as? String,
                                        status: obj["apiErrorStatus"] as? Int, message: text)))
                continue
            }

            // content is either a bare string or an array of typed blocks.
            if let s = message["content"] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if type == "user", isLocalRecord(trimmed) {
                    // `/clear` empties the conversation on screen; older
                    // Claude Codes kept writing to the same file after it.
                    if isClearCommand(trimmed) { items.removeAll() }
                    continue
                }
                if !trimmed.isEmpty {
                    add(type == "user" ? .userText(unwrapPasted(trimmed)) : .assistantText(trimmed))
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
                    if type == "user", isLocalRecord(s) {
                        if isClearCommand(s) { items.removeAll() }
                        continue
                    }
                    add(type == "user" ? .userText(unwrapPasted(s)) : .assistantText(s))
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
                        let first = items.count
                        questions.forEach { add(.question($0)) }
                        if let id = block["id"] as? String {
                            questionItems[id] = Array(first..<items.count)
                        }
                    } else {
                        add(.toolUse(name: name,
                                     summary: toolSummary(name: name, input: input),
                                     detail: prettyJSON(input)))
                    }
                case "tool_result":
                    let useID = block["tool_use_id"] as? String
                    if let useID, let idxs = questionItems.removeValue(forKey: useID) {
                        // The question's answer (Claude records the picks
                        // by question text) or its dismissal.
                        let declined = block["is_error"] as? Bool ?? false
                        let answers = (obj["toolUseResult"] as? [String: Any])?["answers"]
                            as? [String: String] ?? [:]
                        for i in idxs where items.indices.contains(i) {
                            guard case .question(var q) = items[i].kind else { continue }
                            if declined { q.declined = true } else { q.answer = answers[q.question] ?? "" }
                            items[i].kind = .question(q)
                        }
                    }
                    let tool = useID.flatMap { toolNames[$0] } ?? "tool"
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

    /// Claude Code records what happened in the terminal as user turns
    /// wrapped in its own tags — a slash command (`<command-name>`), what
    /// it printed (`<local-command-stdout>`), a `!` shell line and its
    /// output (`<bash-input>`, `<bash-stdout>`), plus the reminders it
    /// slips in for the model (`<system-reminder>`). None of it is
    /// something the user said; the chat has its own command card.
    private static let localTags = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-caveat>",
        "<bash-input>", "<bash-stdout>", "<bash-stderr>",
        "<system-reminder>",
    ]
    static func isLocalRecord(_ text: String) -> Bool {
        localTags.contains { text.hasPrefix($0) }
    }

    /// Claude Code (2.1.28x) records a paste as
    /// `<pasted_content id="…">the text</pasted_content>` inside the user's
    /// turn. The user wrote the text, not the wrapper: the bubble shows
    /// (and counts) the text alone. Only well-formed pairs are unwrapped.
    /// The closing tag may repeat the id (`</pasted_content id="11de">`,
    /// seen live) or be bare; both close the paste.
    static func unwrapPasted(_ text: String) -> String {
        guard text.contains("<pasted_content") else { return text }
        /// The end of a tag that starts at `start` (after its name): the
        /// `>` on the same line, with no other tag opening before it.
        func tagEnd(_ s: Substring, from start: Substring.Index) -> Substring.Index? {
            guard let end = s[start...].firstIndex(of: ">"),
                  s[start..<end].allSatisfy({ $0 != "<" && $0 != "\n" }) else { return nil }
            // Right after the name: either the end or an attribute.
            if let first = s[start..<end].first, first != " " { return nil }
            return end
        }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<pasted_content") {
            guard let openEnd = tagEnd(rest, from: open.upperBound) else { break }
            let bodyStart = rest.index(after: openEnd)
            var search = bodyStart
            var closeRange: Range<Substring.Index>?
            while let c = rest[search...].range(of: "</pasted_content") {
                if let cEnd = tagEnd(rest, from: c.upperBound) {
                    closeRange = c.lowerBound..<rest.index(after: cEnd)
                    break
                }
                search = c.upperBound
            }
            guard let close = closeRange else { break }
            out += rest[..<open.lowerBound]
            out += rest[bodyStart..<close.lowerBound]
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `/clear` record — the point where the conversation on screen
    /// starts over.
    static func isClearCommand(_ text: String) -> Bool {
        text.contains("<command-name>/clear</command-name>")
    }

    /// The one-liner shown on a collapsed tool call — the command for shells,
    /// the path for file tools, the first primitive value otherwise.
    /// (fileprivate: the Codex/Grok/Kimi parsers below reuse it.)
    fileprivate static func toolSummary(name: String, input: [String: Any]) -> String {
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
    /// The folded row a compaction summary becomes.
    static func compactSummaryItem(_ summary: String) -> TranscriptItem.Kind {
        .toolUse(name: "Compact",
                 summary: NSLocalizedString("Conversation compacted", comment: "transcript: /compact summary row"),
                 detail: summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    fileprivate static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    fileprivate static func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Shared-folder paths

/// A shared Mac folder is mounted in the guest at `/mnt/bromure-share-N` and
/// linked as `~/<name>`. Agents that resolve symlinks (Grok) name the mount
/// in every path they log; the chat shows the folder the user knows.
enum GuestSharePaths {
    /// Workspace → its share roots and how they read ("/mnt/bromure-share-1"
    /// → "~/gk-demo"), set by the app that knows the workspaces (macOS).
    @MainActor static var resolver: ((UUID) -> [String: String])?

    @MainActor static func names(profileID: UUID) -> [String: String] {
        resolver?(profileID) ?? [:]
    }

    /// `/mnt/bromure-share-<i+1>` → `~/<name>` for each share name in order.
    static func names(mountNames: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (i, n) in mountNames.enumerated() where !n.isEmpty { out["/mnt/bromure-share-\(i + 1)"] = "~/" + n }
        return out
    }

    /// `text` with each share root (a whole path component — "-1" never
    /// matches "-10") read as its folder.
    static func display(_ text: String, names: [String: String]) -> String {
        // A tool call's detail is JSON that Foundation wrote with its
        // slashes escaped ("\/mnt\/bromure-share-1"): the card's header
        // reads its path from there, so that form is rewritten too.
        let escaped = text.contains(#"\/mnt\/bromure-share-"#)
        guard !names.isEmpty, text.contains("/mnt/bromure-share-") || escaped else { return text }
        var out = text
        // Longest first, so "-12" is replaced before "-1" could be tried.
        for (root, shown) in names.sorted(by: { $0.key.count > $1.key.count }) {
            // Never something that would break the JSON a detail holds.
            guard !shown.contains("\""), !shown.contains("\\") else { continue }
            let pattern = NSRegularExpression.escapedPattern(for: root) + "(?![0-9A-Za-z_-])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: shown),
                                           options: .regularExpression)
            if escaped {
                let eRoot = root.replacingOccurrences(of: "/", with: #"\/"#)
                let eShown = shown.replacingOccurrences(of: "/", with: #"\/"#)
                out = out.replacingOccurrences(
                    of: NSRegularExpression.escapedPattern(for: eRoot) + "(?![0-9A-Za-z_-])",
                    with: NSRegularExpression.escapedTemplate(for: eShown), options: .regularExpression)
            }
        }
        return out
    }

    /// The guest's home ("/home/ubuntu") as "~" — a whole leading path
    /// component only ("/home/ubuntu2", "/x/home/ubuntu" stay).
    static let guestHome = "/home/ubuntu"
    static func homeDisplay(_ text: String) -> String {
        var out = text
        if out.contains(guestHome) {
            out = out.replacingOccurrences(
                of: #"(?<![0-9A-Za-z_.~/\-])/home/ubuntu(?![0-9A-Za-z_.-])"#, with: "~", options: .regularExpression)
        }
        // A detail's JSON, slashes escaped ("\/home\/ubuntu\/x").
        if out.contains(#"\/home\/ubuntu"#) {
            out = out.replacingOccurrences(
                of: #"(?<![0-9A-Za-z_.~/-])\\/home\\/ubuntu(?![0-9A-Za-z_.-])"#, with: "~", options: .regularExpression)
        }
        return out
    }

    /// A tool whose summary is a command line.
    static func isShellTool(_ name: String) -> Bool {
        ["bash", "shell", "exec_command", "local_shell", "run_terminal_command", "terminal"].contains(name.lowercased())
    }

    /// The items with their share paths read as folders (tool calls,
    /// results, the agent's prose — never what the user typed).
    static func rewrite(_ items: [TranscriptItem], names: [String: String]) -> [TranscriptItem] {
        func d(_ s: String) -> String { names.isEmpty ? s : display(s, names: names) }
        return items.map { item in
            var item = item
            switch item.kind {
            case .toolUse(let name, let summary, let detail):
                // The card's header reads the guest home as "~" ("Read
                // ~/inj.txt", not "/home/ubuntu/inj.txt"); a command line
                // stays as it runs (it's copied from there), and so does
                // the call's detail.
                // A display-MCP call's detail is what its card reads the file
                // from: "~/shot.png" isn't a path the machine can open, and the
                // card refused it -- the chat drew a bare "display show media"
                // row instead of the picture.
                let shell = isShellTool(name)
                let shownDetail = DisplayRequest.parse(name: name, detail: detail) != nil ? detail
                    : shell ? d(detail) : homeDisplay(d(detail))
                item.kind = .toolUse(name: name, summary: shell ? d(summary) : homeDisplay(d(summary)),
                                     detail: shownDetail)
            case .toolResult(let tool, let content, let isError):
                item.kind = .toolResult(tool: tool, content: d(content), isError: isError)
            case .assistantText(let t): item.kind = .assistantText(d(t))
            case .thinking(let t): item.kind = .thinking(d(t))
            default: break
            }
            return item
        }
    }
}

// MARK: - Multi-agent dispatch

/// Entry point for every transcript render: picks the parser matching the
/// agent that wrote the file. `agent` is a canonical `BromureIcons` agent
/// kind ("claude" / "codex" / "grok" / "kimi") when the caller knows it —
/// a tab label, a task's tool — and nil (or an agent without a reader)
/// sniffs the format from the lines themselves, so archived transcripts
/// keep rendering after the caller lost track of which tool wrote them.
enum AgentTranscript {
    static func parse(_ data: Data, agent: String? = nil) -> [TranscriptItem] {
        let kind: String
        if let agent, ["claude", "codex", "grok", "kimi", "omp"].contains(agent) {
            kind = agent
        } else {
            kind = sniff(data)
        }
        let items: [TranscriptItem]
        switch kind {
        case "codex": items = CodexTranscriptParser.parse(data)
        case "grok": items = GrokTranscriptParser.parse(data)
        case "kimi": items = KimiTranscriptParser.parse(data)
        case "omp": items = OmpTranscriptParser.parse(data)
        default: items = ClaudeTranscriptParser.parse(data)
        }
        return stableIDs(items)
    }

    /// Re-key items so an item keeps its id when the bytes in front of it
    /// change — the parsers number items by position, and a transcript read
    /// as a moving window (or trimmed at the head) renumbered every row: the
    /// list lost its identity, the lazy stack rebuilt from estimates, and the
    /// scroll offset was left past the end (a blank page). The key is what
    /// the item IS (kind + when it was written) plus its rank among equals,
    /// not what it says — a streaming assistant turn keeps its id as it grows.
    static func stableIDs(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var rank: [Int: Int] = [:]
        return items.map { item in
            var h = Hasher()
            h.combine(item.kind.stableTag)
            h.combine(item.timestamp?.timeIntervalSince1970 ?? -1)
            let key = h.finalize()
            let n = rank[key, default: 0]
            rank[key] = n + 1
            var h2 = Hasher()
            h2.combine(key)
            h2.combine(n)
            return TranscriptItem(id: h2.finalize(), kind: item.kind, timestamp: item.timestamp)
        }
    }

    /// Which agent wrote this file, from line shapes alone. Scans until a
    /// line is decisive; Claude is the default (it was the only format for
    /// a long time, so undecidable files are overwhelmingly Claude's).
    /// A tail-cut read may start mid-line — unparseable lines are skipped,
    /// exactly as the parsers themselves do.
    static func sniff(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "claude" }
        for line in text.split(whereSeparator: \.isNewline).prefix(200) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            // Grok: persisted ACP notifications — {"method":"session/update",
            // "params":{"update":{...}}} (or the "_x.ai/…" extension form).
            if let method = obj["method"] as? String,
               method.hasSuffix("session/update") { return "grok" }
            if let params = obj["params"] as? [String: Any],
               params["update"] is [String: Any] { return "grok" }
            let type = obj["type"] as? String ?? ""
            // omp: session-log lines are typed ("session"/"model_change"/
            // "message"). Decisive shapes: a `session` line carrying `cwd` +
            // `version`, a `model_change` line, or a `message` line whose
            // `message` object holds the role (Claude puts the role in `type`).
            if type == "session", obj["cwd"] != nil, obj["version"] != nil { return "omp" }
            if type == "model_change", obj["model"] != nil { return "omp" }
            if type == "message", let m = obj["message"] as? [String: Any],
               m["role"] is String { return "omp" }
            // Kimi: wire-journal op types are dotted ("turn.prompt",
            // "context.append_message"); line 1 is a protocol_version stamp.
            if type.contains(".") { return "kimi" }
            if type == "metadata", obj["protocol_version"] != nil { return "kimi" }
            // Codex: {timestamp, type, payload} rollout envelope.
            if obj["payload"] is [String: Any],
               ["session_meta", "response_item", "event_msg", "turn_context",
                "compacted"].contains(type) { return "codex" }
            // Claude: {type: user|assistant, message: {...}}.
            if type == "user" || type == "assistant", obj["message"] != nil {
                return "claude"
            }
            // Pre-envelope Codex rollouts: bare ResponseItem objects.
            if type == "message", obj["role"] is String, obj["message"] == nil {
                return "codex"
            }
        }
        return "claude"
    }
}

// MARK: - omp parser

/// Tolerant reader for Oh My Pi (`omp`) session files
/// (`~/.omp/agent/sessions/<slug>/<timestamp>_<uuid>.jsonl`). Each line is a
/// typed record; the conversation lives in `{"type":"message","message":{...}}`
/// lines. `session`/`model_change`/`thinking_level_change`/`title`/`custom`
/// lines are metadata and skipped.
///
/// omp's message shapes have drifted from the Anthropic-messages layout the
/// first cut assumed, so both are handled:
///   • text/thinking blocks — unchanged.
///   • a tool CALL is a `toolCall` block (current: `arguments` + a human
///     `intent`) OR a `tool_use` block (older/Anthropic: `input`).
///   • a tool RESULT is its OWN message with `role:"toolResult"` carrying
///     `toolName`/`isError`/`content` (current) OR an inline `tool_result`
///     block in a user message (older). The role gate must let "toolResult"
///     through, or every tool result silently vanishes.
/// Unknown lines/blocks are skipped.
enum OmpTranscriptParser {
    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [TranscriptItem] = []
        var toolNames: [String: String] = [:]
        // Consolidated todo checklist: omp emits one `todo` call per change and
        // reports live per-item status in the tool RESULT (not the call), so we
        // fold them into ONE .todo item that ticks in place instead of many
        // cards. `todoInit` = the plan's full item list (from the init call),
        // `todoResult` = the latest result text (current status), `todoAnchor` =
        // where the .todo item sits in `items`.
        var todoInit: [TodoRowModel] = []
        var todoResult: String?
        var todoAnchor: Int?
        // omp's own `ask` calls by id: where the call's card sits and what it
        // asked. Once its result is in, the card turns into the answered
        // question (the answer stays in the chat); while it's open, the
        // dialog on screen is the way to answer it.
        var askAnchors: [String: (at: Int, questions: [TranscriptQuestion])] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            guard obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let isUser = role == "user"
            let stamp = (obj["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            }
            func add(_ kind: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: items.count, kind: kind, timestamp: stamp))
            }

            // Current omp records each tool result as its own message
            // (role "toolResult") with the tool name + result at the message
            // level. (Older omp inlined a `tool_result` block in a user
            // message — still handled in the block loop below.)
            if role == "toolResult" {
                // The call's name as the chat knows it first: an `xd://` device
                // write was renamed to the tool it ran (its result says "write").
                let tool = (message["toolCallId"] as? String).flatMap { toolNames[$0] }
                    ?? message["toolName"] as? String
                    ?? "tool"
                let content = ClaudeTranscriptParser.resultText(message["content"])
                // The todo result is the authoritative per-item status — fold it
                // into the consolidated checklist (once a plan is anchored)
                // instead of rendering its verbose text.
                if tool == "todo", todoAnchor != nil {
                    todoResult = content
                    continue
                }
                if tool == "ask", let callID = message["toolCallId"] as? String,
                   let anchor = askAnchors.removeValue(forKey: callID) {
                    let answered = Self.answeredAsk(anchor.questions, result: content,
                                                    isError: message["isError"] as? Bool ?? false)
                    if let first = answered.first {
                        items[anchor.at].kind = .question(first)
                        answered.dropFirst().forEach { add(.question($0)) }
                        continue
                    }
                }
                add(.toolResult(tool: tool, content: content,
                                isError: message["isError"] as? Bool ?? false))
                continue
            }
            guard role == "user" || role == "assistant" else { continue }

            // A turn the provider refused: omp records the HTTP status and
            // its classifier bits next to the (provider-worded) message.
            if role == "assistant", message["stopReason"] as? String == "error" {
                let text = (message["errorMessage"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let status = message["errorStatus"] as? Int
                let errorID = message["errorId"] as? Int
                // A user's Esc is an "error" stop too — not a failure.
                if errorID.map({ $0 & (0x4000000 | 0x8000000) != 0 }) != true,
                   status != nil || errorID != nil || !text.isEmpty {
                    add(.agentError(.omp(errorID: errorID, status: status, message: text)))
                }
            }

            // content: a bare string or an array of blocks.
            if let s = message["content"] as? String {
                let t = (isUser ? Self.unwrapAttachments(s) : s).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { add(isUser ? .userText(t) : .assistantText(t)) }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let raw = block["text"] as? String ?? ""
                    let s = (isUser ? Self.unwrapAttachments(raw) : raw)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { add(isUser ? .userText(s) : .assistantText(s)) }
                case "thinking":
                    let s = (block["thinking"] as? String ?? block["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { add(.thinking(s)) }
                // Current omp: `toolCall` (args in `arguments`, plus a human
                // `intent`). Older omp / Anthropic: `tool_use` (`input`).
                case "toolCall", "tool_use":
                    var name = block["name"] as? String ?? "tool"
                    var input = Self.toolInput(block)
                    // omp drives MCP / mounted tools through read/write on
                    // `xd://<tool>` and pages spilled output via
                    // `artifact://N`: the tool it really ran, not a file edit.
                    var virtualSummary: String?
                    if let v = Self.virtualCall(name: name, input: input) {
                        name = v.name
                        input = v.input
                        virtualSummary = v.summary
                    }
                    if let id = block["id"] as? String { toolNames[id] = name }
                    // omp's todo list → one consolidated, live-ticking .todo item
                    // (its per-item status is folded in from the result above).
                    if name == "todo" {
                        let rows = TodoParse.rows(from: input)   // non-empty only for the `init` op
                        if !rows.isEmpty { todoInit = rows }
                        if !todoInit.isEmpty, todoAnchor == nil {
                            todoAnchor = items.count
                            add(.todo(title: NSLocalizedString("To-dos", comment: "todo card"),
                                      rows: todoInit))
                        }
                        continue   // delta ops carry no list; the merge handles them
                    }
                    let questions = name == "AskUserQuestion"
                        ? TranscriptQuestion.parse(input) : []
                    if !questions.isEmpty {
                        questions.forEach { add(.question($0)) }
                    } else {
                        if name == "ask", let id = block["id"] as? String {
                            let asked = Self.askQuestions(input)
                            if !asked.isEmpty { askAnchors[id] = (items.count, asked) }
                        }
                        // Prefer omp's own one-line `intent` ("Writing foo.html")
                        // as the summary; fall back to the derived one.
                        let intent = (block["intent"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let summary = (intent?.isEmpty == false) ? intent!
                            : virtualSummary ?? ClaudeTranscriptParser.toolSummary(name: name, input: input)
                        add(.toolUse(name: name, summary: summary,
                                     detail: ClaudeTranscriptParser.prettyJSON(input)))
                    }
                case "tool_result":
                    let tool = (block["tool_use_id"] as? String)
                        .flatMap { toolNames[$0] } ?? "tool"
                    add(.toolResult(tool: tool,
                                    content: ClaudeTranscriptParser.resultText(block["content"]),
                                    isError: block["is_error"] as? Bool ?? false))
                default:
                    continue
                }
            }
        }
        // Fold the latest todo result's status into the anchored checklist, so
        // the items tick to done in place as omp reports progress.
        if let a = todoAnchor {
            items[a].kind = .todo(title: NSLocalizedString("To-dos", comment: "todo card"),
                                  rows: TodoParse.merge(initRows: todoInit, resultText: todoResult))
        }
        return items
    }

    /// omp's `ask` arguments: `questions: [{id, question, options: [{label,
    /// description?}], multi?}]`.
    static func askQuestions(_ input: [String: Any]) -> [TranscriptQuestion] {
        guard let qs = input["questions"] as? [[String: Any]] else { return [] }
        return qs.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> TranscriptQuestion.Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return .init(label: label, description: o["description"] as? String ?? "")
            }
            return TranscriptQuestion(question: text, header: q["id"] as? String ?? "",
                                      multiSelect: q["multi"] as? Bool ?? false, options: opts)
        }
    }

    /// The questions with what the user answered, from omp's result text:
    /// "User selected: Green", "User provided custom input: teal", or for
    /// several questions "User answers:\n<id>: Green". An error result (Esc:
    /// "cancelled") is a declined question.
    static func answeredAsk(_ questions: [TranscriptQuestion], result: String,
                            isError: Bool) -> [TranscriptQuestion] {
        var out = questions
        let lines = result.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func value(after prefix: String) -> String? {
            lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        let cancelled = isError || result.contains("User cancelled the selection")
            || result.contains("User did not select any options")
        for i in out.indices {
            if cancelled { out[i].declined = true; continue }
            var answer: String?
            if questions.count == 1 {
                answer = value(after: "User selected:") ?? value(after: "User provided custom input:")
            }
            if answer == nil, !out[i].header.isEmpty {
                answer = value(after: out[i].header + ":").map {
                    var a = $0
                    if a.hasPrefix("["), a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
                    if a.hasPrefix("\""), a.hasSuffix("\""), a.count >= 2 { a = String(a.dropFirst().dropLast()) }
                    return a
                }
            }
            if answer == "(cancelled)" { out[i].declined = true; continue }
            out[i].answer = answer ?? ""
        }
        return out
    }

    /// A paste omp wrapped for the model (`<attachment>\n…\n</attachment>`,
    /// its large-paste marker): the words the user pasted, unwrapped — the
    /// chat folds a long one like any long message.
    static func unwrapAttachments(_ text: String) -> String {
        guard text.contains("<attachment>") else { return text }
        return text.replacingOccurrences(
            of: #"<attachment>\r?\n?([\s\S]*?)\r?\n?</attachment>"#, with: "$1", options: .regularExpression)
    }

    /// A read/write that isn't a file: omp's `xd://<tool>` devices (a write
    /// RUNS the tool with `content` as its JSON arguments, a read fetches
    /// its docs) and `artifact://N` (an earlier command's spilled output).
    struct VirtualCall {
        let name: String
        let summary: String?
        let input: [String: Any]
    }

    /// Tool name for a docs lookup of an `xd://` device.
    static let toolLookupName = "tool_lookup"
    /// Tool name for a read of spilled output (`artifact://N`).
    static let readOutputName = "read_output"

    static func virtualCall(name: String, input: [String: Any]) -> VirtualCall? {
        let n = name.lowercased()
        guard n == "read" || n == "write",
              let path = (input["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let lower = path.lowercased()
        if lower.hasPrefix("xd://") {
            let tool = path.dropFirst(5)
                .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" })
                .first.map(String.init) ?? ""
            if n == "write" {
                guard !tool.isEmpty else { return nil }
                var args: [String: Any] = [:]
                if let d = input["content"] as? [String: Any] {
                    args = d
                } else if let c = input["content"] as? String,
                          let d = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any] {
                    args = d
                }
                return VirtualCall(name: tool, summary: nil, input: args)
            }
            let label = tool.isEmpty
                ? NSLocalizedString("Listing its tools", comment: "omp step: read of xd:// (the agent lists the tools it can call)")
                : String(format: NSLocalizedString("Looking up %@", comment: "omp step: read of a tool's docs (xd://tool); %@ = tool"),
                         ActivitySummary.humanTool(tool))
            return VirtualCall(name: toolLookupName, summary: label, input: tool.isEmpty ? [:] : ["tool": tool])
        }
        if n == "read", lower.hasPrefix("artifact://") {
            let rest = String(path.dropFirst("artifact://".count))
            let id = String(rest.prefix { $0.isNumber })
            let label = id.isEmpty
                ? NSLocalizedString("Reading earlier output", comment: "omp step: read of a spilled command output (artifact://)")
                : String(format: NSLocalizedString("Reading earlier output #%@", comment: "omp step: read of spilled command output N (artifact://N)"), id)
            return VirtualCall(name: readOutputName, summary: label, input: ["artifact": rest])
        }
        return nil
    }

    /// A tool call's arguments as a dict: `input` (Anthropic/older omp) or
    /// `arguments` (current omp), tolerating a JSON-encoded string (and the
    /// streamed `partialArgs` as a last resort).
    private static func toolInput(_ block: [String: Any]) -> [String: Any] {
        if let d = block["input"] as? [String: Any] { return d }
        if let d = block["arguments"] as? [String: Any] { return d }
        for key in ["arguments", "input", "partialArgs"] {
            if let s = block[key] as? String,
               let data = s.data(using: .utf8),
               let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return d
            }
        }
        return [:]
    }
}

// MARK: - Codex parser

/// Tolerant reader for Codex CLI rollout files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). Lines are
/// `{timestamp, type, payload}` envelopes; the conversation lives in
/// `response_item` payloads. `event_msg` lines mirror the same turns for
/// the UI — parsing both would duplicate every message, so they're kept
/// only as a fallback for files that carry no response_item conversation
/// (newer "paginated" history mode). Unknown types are skipped, not fatal.
enum CodexTranscriptParser {
    /// What the reader carries from line to line: tool names by call id,
    /// and the calls a Codex code-mode script made (`exec` custom tool,
    /// Codex ≥ 0.157) — its output arrives later as one list for the whole
    /// script, or, for a script still running when its call returned,
    /// through `wait` calls naming its cell.
    struct State {
        var toolNames: [String: String] = [:]
        var scripts: [String: [CodexCodeMode.Call]] = [:]
        /// call id → the cell a `wait` call polls.
        var waits: [String: String] = [:]
        /// cell id → the calls of a script still running.
        var runningCells: [String: [CodexCodeMode.Call]] = [:]
        /// Code-mode scripts that only looked at the tool list: neither the
        /// script nor its output is something the user asked to see.
        var hidden: Set<String> = []
    }

    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var primary: [TranscriptItem.Kind] = []
        var fallback: [TranscriptItem.Kind] = []
        var stamps: [Date?] = []
        var fallbackStamps: [Date?] = []
        var state = State()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            let stamp = (obj["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            }
            switch obj["type"] as? String ?? "" {
            case "response_item":
                guard let payload = obj["payload"] as? [String: Any] else { continue }
                for kind in responseItemKinds(payload, state: &state) {
                    primary.append(kind)
                    stamps.append(stamp)
                }
            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any] else { continue }
                // A failed turn: the error rides on its task_complete, typed
                // by codex_error_info. Not mirrored by any response_item, so
                // it belongs in both lists.
                if let error = Self.turnError(payload) {
                    primary.append(error); stamps.append(stamp)
                    fallback.append(error); fallbackStamps.append(stamp)
                    continue
                }
                for kind in eventKinds(payload) {
                    fallback.append(kind)
                    fallbackStamps.append(stamp)
                }
            case "message", "reasoning", "function_call", "function_call_output",
                 "local_shell_call", "custom_tool_call", "custom_tool_call_output",
                 "web_search_call":
                // Early-2025 rollouts: bare ResponseItems, no envelope.
                guard obj["payload"] == nil else { continue }
                for kind in responseItemKinds(obj, state: &state) {
                    primary.append(kind)
                    stamps.append(stamp)
                }
            default:
                continue
            }
        }
        let hasConversation = primary.contains {
            if case .userText = $0 { return true }
            if case .assistantText = $0 { return true }
            return false
        }
        let (kinds, dates) = hasConversation || fallback.isEmpty
            ? (primary, stamps) : (fallback, fallbackStamps)
        return kinds.enumerated().map {
            TranscriptItem(id: $0.offset, kind: $0.element, timestamp: dates[$0.offset])
        }
    }

    /// The model Codex ran the conversation's latest turn on — its
    /// `turn_context` records (a mid-session `/model` changes it), nil when
    /// the rollout has none.
    static func latestModel(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        var model: String?
        for line in text.split(whereSeparator: \.isNewline) where line.contains("\"turn_context\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let p = obj["payload"] as? [String: Any] else { continue }
            if let m = p["model"] as? String, !m.isEmpty { model = m }
        }
        return model
    }

    private static func responseItemKinds(
        _ payload: [String: Any],
        state: inout State) -> [TranscriptItem.Kind] {
        switch payload["type"] as? String ?? "" {
        case "message":
            let role = payload["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { return [] }
            // Codex injects instructions (AGENTS.md) and an environment dump
            // as synthetic user turns — plumbing, not conversation. Dropped
            // per part: one message may carry both, or sit beside typed text.
            let text = (payload["content"] as? [[String: Any]] ?? [])
                .compactMap { block -> String? in
                    guard ["input_text", "output_text", "text"]
                        .contains(block["type"] as? String ?? "") else { return nil }
                    guard let t = block["text"] as? String else { return nil }
                    return role == "user" && Self.isInjectedContext(t) ? nil : t
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [role == "user" ? .userText(text) : .assistantText(text)]
        case "reasoning":
            // Readable thinking is the summary; raw CoT is usually only an
            // opaque encrypted_content blob (plaintext content[] appears
            // for providers that return it — take it when present).
            var parts = (payload["summary"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
            parts += (payload["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.thinking(text)]
        case "function_call":
            let name = payload["name"] as? String ?? "tool"
            let callID = payload["call_id"] as? String
            let argsString = payload["arguments"] as? String ?? ""
            let args = (try? JSONSerialization.jsonObject(
                with: Data(argsString.utf8))) as? [String: Any]
            // Code mode's `wait`: polls a script that was still running when
            // its call returned. Plumbing — its output is the script's.
            if name == "wait", let callID, let cell = Self.cellID(args?["cell_id"]),
               state.runningCells[cell] != nil {
                state.waits[callID] = cell
                return []
            }
            if let callID { state.toolNames[callID] = name }
            let summary = args.flatMap { shellSummary($0["command"]) }
                ?? args.map { ClaudeTranscriptParser.toolSummary(name: name, input: $0) }
                ?? String(argsString.prefix(200))
            let detail = args.map { ClaudeTranscriptParser.prettyJSON($0) } ?? argsString
            return [.toolUse(name: name, summary: summary, detail: detail)]
        case "local_shell_call":
            if let id = payload["call_id"] as? String { state.toolNames[id] = "shell" }
            let action = payload["action"] as? [String: Any] ?? [:]
            return [.toolUse(name: "shell",
                             summary: shellSummary(action["command"]) ?? "",
                             detail: ClaudeTranscriptParser.prettyJSON(action))]
        case "custom_tool_call":
            let name = payload["name"] as? String ?? "tool"
            let callID = payload["call_id"] as? String
            let input = payload["input"] as? String ?? ""
            // Code mode (Codex ≥ 0.157): one `exec` call runs a script that
            // calls the real tools (`tools.exec_command({cmd})`,
            // `tools.apply_patch("…")`, MCP tools) — each its own card.
            if name == "exec" {
                let calls = CodexCodeMode.calls(in: input)
                if !calls.isEmpty {
                    if let callID { state.scripts[callID] = calls }
                    return calls.flatMap(\.kinds)
                }
                // A script that only reads the tool list.
                if input.contains("ALL_TOOLS"), let callID {
                    state.hidden.insert(callID)
                    return []
                }
            }
            if let callID { state.toolNames[callID] = name }
            // The freeform apply_patch: its input IS the patch.
            if name == "apply_patch" {
                return CodexCodeMode.Call(name: name, args: input).kinds
            }
            return [.toolUse(name: name, summary: String(input.prefix(200)),
                             detail: input)]
        case "function_call_output", "custom_tool_call_output":
            let callID = payload["call_id"] as? String
            if let callID, state.hidden.contains(callID) { return [] }
            if let callID, let cell = state.waits[callID] {
                return scriptResults(payload["output"], calls: state.runningCells[cell] ?? [],
                                     cell: cell, state: &state)
            }
            if let callID, let calls = state.scripts[callID] {
                return scriptResults(payload["output"], calls: calls, cell: nil, state: &state)
            }
            let tool = callID.flatMap { state.toolNames[$0] } ?? "tool"
            let (content, isError) = outputText(payload["output"])
            return [.toolResult(tool: tool, content: content, isError: isError)]
        case "web_search_call":
            let action = payload["action"] as? [String: Any] ?? [:]
            return [.toolUse(name: "web_search",
                             summary: action["query"] as? String ?? "",
                             detail: "")]
        default:
            return []
        }
    }

    /// A user-message part Codex wrote, not the user: the AGENTS.md block
    /// (`# AGENTS.md instructions for …`, older `<user_instructions>`), the
    /// `<environment_context>` dump, and similar tagged plumbing.
    static func isInjectedContext(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("# AGENTS.md instructions for ")
            || t.hasPrefix("<user_instructions>")
            || t.hasPrefix("<environment_context>")
            || t.hasPrefix("<INSTRUCTIONS>")
    }

    private static func cellID(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? Int { return String(n) }
        return nil
    }

    /// A code-mode script's output → one result per tool call it made. The
    /// output is a list: a header ("Script completed" / "Script running
    /// with cell ID N"), then what the script printed, one item per
    /// `text(…)` — in practice each call's own result, in call order. Each
    /// call takes the next result of its shape (a command's carries
    /// exit_code, an MCP tool's a content list); prints of anything else
    /// (the tool list) are left over and dropped.
    private static func scriptResults(_ output: Any?, calls: [CodexCodeMode.Call], cell: String?,
                                      state: inout State) -> [TranscriptItem.Kind] {
        var texts: [String] = []
        if let blocks = output as? [[String: Any]] {
            texts = blocks.compactMap { $0["text"] as? String }
        } else if let s = output as? String {
            texts = [s]
        }
        let header = texts.first ?? ""
        let printed = Array(texts.dropFirst())
        if header.hasPrefix("Script running") {
            // Still running: its results come through `wait`.
            if let id = CodexCodeMode.runningCell(header) {
                state.runningCells[id] = calls
            }
            return []
        }
        if let cell { state.runningCells[cell] = nil }
        var out: [TranscriptItem.Kind] = []
        var used = Set<Int>()
        let results = printed.map(CodexCodeMode.Result.init)
        for call in calls {
            guard let i = results.indices.first(where: { !used.contains($0) && results[$0].fits(call) })
                ?? results.indices.first(where: { !used.contains($0) && results[$0].fits(call, strict: false) })
            else { continue }
            used.insert(i)
            if let r = results[i].kind(for: call) { out.append(r) }
        }
        // The script itself failed (a thrown error, a syntax error): say so
        // on the call it was making.
        if !header.hasPrefix("Script completed"), !header.isEmpty {
            let body = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(.toolResult(tool: calls.last?.displayName ?? "exec", content: body, isError: true))
        }
        return out
    }

    /// `task_complete` (or a bare `error` event) carrying the turn's failure.
    private static func turnError(_ payload: [String: Any]) -> TranscriptItem.Kind? {
        let type = payload["type"] as? String ?? ""
        let error: [String: Any]?
        switch type {
        case "task_complete", "turn_complete": error = payload["error"] as? [String: Any]
        case "error": error = payload
        default: return nil
        }
        guard let error else { return nil }
        let message = (error["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let info = error["codex_error_info"] ?? error["codexErrorInfo"]
        // The plain variants are strings; the http ones are a one-key object.
        let infoName = (info as? String) ?? (info as? [String: Any])?.keys.first
        guard !message.isEmpty || infoName != nil else { return nil }
        return .agentError(.codex(info: infoName, message: message))
    }

    /// The legacy-mode UI mirror of the same conversation (fallback only).
    private static func eventKinds(_ payload: [String: Any]) -> [TranscriptItem.Kind] {
        switch payload["type"] as? String ?? "" {
        case "user_message":
            // kind "user_instructions"/"environment_context" mark the same
            // synthetic turns the response_item path filters by prefix.
            let kind = payload["kind"] as? String ?? "plain"
            guard kind == "plain" else { return [] }
            let text = (payload["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.userText(text)]
        case "agent_message":
            let text = (payload["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.assistantText(text)]
        case "agent_reasoning":
            let text = (payload["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.thinking(text)]
        default:
            return []
        }
    }

    /// Codex shell commands are argv arrays, usually ["bash","-lc","…"] —
    /// show the actual command line, not the wrapper.
    private static func shellSummary(_ command: Any?) -> String? {
        guard let argv = (command as? [Any])?.compactMap({ $0 as? String }),
              !argv.isEmpty else { return nil }
        let line: String
        if argv.count >= 3, ["bash", "sh", "zsh"].contains(argv[0]),
           ["-lc", "-c"].contains(argv[1]) {
            line = argv[2...].joined(separator: " ")
        } else {
            line = argv.joined(separator: " ")
        }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// function_call_output "output": a plain string, an array of content
    /// blocks, or a JSON-encoded {"output": …, "metadata": {exit_code}}.
    private static func outputText(_ output: Any?) -> (String, Bool) {
        if let blocks = output as? [[String: Any]] {
            return (blocks.compactMap { $0["text"] as? String }
                .joined(separator: "\n"), false)
        }
        guard let s = output as? String else { return ("", false) }
        if let obj = (try? JSONSerialization.jsonObject(
                with: Data(s.utf8))) as? [String: Any],
           let inner = obj["output"] as? String {
            let exit = (obj["metadata"] as? [String: Any])?["exit_code"] as? Int
            return (inner, (exit ?? 0) != 0)
        }
        return (s, false)
    }
}

// MARK: - Codex code mode

/// Codex ≥ 0.157 "code mode": the model calls ONE tool, `exec`, with a
/// JavaScript snippet that calls the real tools —
/// `text(await tools.exec_command({cmd:"ls"}))`,
/// `tools.apply_patch("*** Begin Patch…")`, `tools.mcp__server__tool({…})`.
/// The calls are recovered from the source (their arguments are literals in
/// practice); anything that isn't a literal is kept as raw text.
enum CodexCodeMode {
    struct Call {
        var name: String
        /// The first argument, decoded (`[String: Any]`, `String`, …); nil
        /// when it wasn't a literal.
        var args: Any?
        var raw: String = ""

        /// The name the transcript shows: a command is a shell call.
        var displayName: String {
            switch name {
            case "exec_command", "shell", "shell_command", "local_shell": return "shell"
            default: return name
            }
        }

        /// The command a shell call runs.
        var command: String? {
            if let s = args as? String, displayName == "shell" { return s }
            guard let d = args as? [String: Any] else { return nil }
            for k in ["cmd", "command"] {
                if let s = d[k] as? String { return s }
                if let a = d[k] as? [Any] {
                    let argv = a.compactMap { $0 as? String }
                    if argv.count >= 3, ["bash", "sh", "zsh"].contains(argv[0]),
                       ["-lc", "-c"].contains(argv[1]) { return argv[2...].joined(separator: " ") }
                    return argv.joined(separator: " ")
                }
            }
            return nil
        }

        var patch: String? {
            if let s = args as? String { return s }
            let d = args as? [String: Any]
            return d?["input"] as? String ?? d?["patch"] as? String
        }

        /// The call's cards: one, except a patch touching several files —
        /// one diff card per file, each with only its own hunks.
        var kinds: [TranscriptItem.Kind] {
            guard name == "apply_patch", let patch else { return [kind] }
            let sections = CodexCodeMode.patchSections(patch)
            guard sections.count > 1 else { return [kind] }
            return sections.map { Call(name: name, args: $0).kind }
        }

        var kind: TranscriptItem.Kind {
            func clip(_ s: String) -> String { s.count > 200 ? String(s.prefix(200)) + "…" : s }
            if displayName == "shell", let cmd = command {
                var input: [String: Any] = (args as? [String: Any]) ?? [:]
                input["cmd"] = nil
                input["command"] = cmd
                return .toolUse(name: "shell", summary: clip(cmd),
                                detail: ClaudeTranscriptParser.prettyJSON(input))
            }
            if name == "apply_patch", let patch {
                let files = CodexCodeMode.patchFiles(patch)
                var input: [String: Any] = ["patch": patch]
                if let f = files.first { input["path"] = f }
                return .toolUse(name: "apply_patch", summary: clip(files.joined(separator: ", ")),
                                detail: ClaudeTranscriptParser.prettyJSON(input))
            }
            if let d = args as? [String: Any] {
                return .toolUse(name: name, summary: ClaudeTranscriptParser.toolSummary(name: name, input: d),
                                detail: ClaudeTranscriptParser.prettyJSON(d))
            }
            if let s = args as? String {
                return .toolUse(name: name, summary: clip(s), detail: s)
            }
            return .toolUse(name: name, summary: clip(raw), detail: raw)
        }
    }

    /// The files a Codex patch touches ("*** Update File: path").
    static func patchFiles(_ patch: String) -> [String] {
        var files: [String] = []
        for line in patch.split(separator: "\n") {
            for p in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
            where line.hasPrefix(p) {
                let f = line.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                if !f.isEmpty, !files.contains(f) { files.append(f) }
            }
        }
        return files
    }

    /// A multi-file Codex patch split per file: each `*** Update File:` /
    /// `*** Add File:` / `*** Delete File:` section (with its `*** Move to:`
    /// and hunks) re-wrapped as a patch of its own. A single-file patch comes
    /// back as one section.
    static func patchSections(_ patch: String) -> [String] {
        let heads = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        var sections: [[Substring]] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.hasSuffix("\r") ? line.dropLast() : line
            if l.hasPrefix("*** Begin Patch") || l.hasPrefix("*** End Patch") { continue }
            if heads.contains(where: { l.hasPrefix($0) }) {
                sections.append([l])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(l)
            }
        }
        guard !sections.isEmpty else { return [patch] }
        return sections.map { body in
            var lines = body
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            return (["*** Begin Patch"] + lines.map(String.init) + ["*** End Patch"]).joined(separator: "\n")
        }
    }

    /// "Script running with cell ID 10…" → "10".
    static func runningCell(_ header: String) -> String? {
        guard let r = header.range(of: "cell ID ") else { return nil }
        let id = header[r.upperBound...].prefix(while: { !$0.isWhitespace })
        return id.isEmpty ? nil : String(id)
    }

    /// One printed result of a script.
    struct Result {
        enum Shape { case command, mcp, empty, list, other }
        let text: String
        let value: Any?
        let rejected: Bool
        let shape: Shape

        init(_ text: String) {
            self.text = text
            var v = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
            var rejected = false
            // Promise.allSettled's {status, value | reason}.
            if let d = v as? [String: Any], let st = d["status"] as? String,
               st == "fulfilled" || st == "rejected", d.count <= 2 {
                rejected = st == "rejected"
                v = d["value"] ?? d["reason"]
            }
            self.value = v
            self.rejected = rejected
            if let d = v as? [String: Any] {
                if d["exit_code"] != nil || d["chunk_id"] != nil
                    || (d["session_id"] != nil && d["output"] != nil) { shape = .command }
                else if d["content"] is [Any] { shape = .mcp }
                else if d.isEmpty { shape = .empty }
                else { shape = .other }
            } else if v is [Any] {
                shape = .list
            } else {
                shape = .other
            }
        }

        /// `strict`: an MCP call only takes an MCP-shaped result (a second,
        /// lenient pass lets it take any printed value).
        func fits(_ call: Call, strict: Bool = true) -> Bool {
            if rejected { return true }
            switch call.displayName {
            case "shell", "write_stdin": return shape == .command
            default:
                if call.name.hasPrefix("mcp__") { return shape == .mcp || (!strict && shape == .other) }
                return shape == .empty || shape == .other
            }
        }

        /// The call's result row; nil for an empty success (a patch applied
        /// says nothing).
        func kind(for call: Call) -> TranscriptItem.Kind? {
            let tool = call.displayName
            if rejected {
                let msg = (value as? [String: Any])?["message"] as? String
                    ?? (value as? String) ?? text
                return .toolResult(tool: tool, content: msg, isError: true)
            }
            switch shape {
            case .command:
                let d = value as? [String: Any] ?? [:]
                var out = d["output"] as? String ?? ""
                let exit = (d["exit_code"] as? NSNumber)?.intValue
                if let exit, exit != 0 {
                    out += (out.isEmpty || out.hasSuffix("\n") ? "" : "\n")
                        + String(format: NSLocalizedString("(exit code %d)", comment: "transcript: a command's nonzero exit status"), exit)
                }
                return .toolResult(tool: tool, content: out.trimmingCharacters(in: .newlines),
                                   isError: (exit ?? 0) != 0)
            case .mcp:
                let d = value as? [String: Any] ?? [:]
                let content = ClaudeTranscriptParser.resultText(d["content"])
                return .toolResult(tool: tool, content: content, isError: d["isError"] as? Bool ?? false)
            case .empty:
                return nil
            case .list, .other:
                let s = (value as? String) ?? text
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return .toolResult(tool: tool, content: s, isError: false)
            }
        }
    }

    // MARK: Source scanning

    /// The `tools.<name>(…)` calls in a script, in source order. String
    /// literals and comments are skipped, so a command that merely mentions
    /// `tools.` isn't one.
    static func calls(in script: String) -> [Call] {
        let s = Array(script.unicodeScalars)
        var out: [Call] = []
        var i = 0
        func isIdent(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$"
        }
        let word = Array("tools.".unicodeScalars)
        while i < s.count {
            let c = s[i]
            if c == "\"" || c == "'" || c == "`" { skipString(s, &i); continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "t", i + word.count < s.count, Array(s[i..<(i + word.count)]) == word,
               i == 0 || (!isIdent(s[i - 1]) && s[i - 1] != ".") {
                var j = i + word.count
                let nameStart = j
                while j < s.count, isIdent(s[j]) { j += 1 }
                let name = String(String.UnicodeScalarView(s[nameStart..<j]))
                var k = j
                skipSpace(s, &k)
                guard !name.isEmpty, k < s.count, s[k] == "(" else { i = j; continue }
                k += 1
                let argStart = k
                skipSpace(s, &k)
                var call = Call(name: name, args: nil)
                if k < s.count, s[k] == ")" {
                    call.args = [String: Any]()
                    i = k + 1
                } else {
                    var m = k
                    if let v = literal(s, &m) {
                        var n = m
                        skipSpace(s, &n)
                        if n < s.count, s[n] == ")" || s[n] == "," {
                            call.args = v
                        }
                    }
                    // Raw text up to the matching parenthesis.
                    var depth = 1, e = argStart
                    while e < s.count, depth > 0 {
                        let ch = s[e]
                        if ch == "\"" || ch == "'" || ch == "`" { skipString(s, &e); continue }
                        if ch == "(" || ch == "{" || ch == "[" { depth += 1 }
                        if ch == ")" || ch == "}" || ch == "]" { depth -= 1 }
                        e += 1
                    }
                    let end = max(argStart, min(s.count, e - 1))
                    call.raw = String(String.UnicodeScalarView(s[argStart..<end]))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    i = call.args != nil ? m : argStart
                }
                out.append(call)
                continue
            }
            i += 1
        }
        return out
    }

    private static func skipSpace(_ s: [Unicode.Scalar], _ i: inout Int) {
        while i < s.count, CharacterSet.whitespacesAndNewlines.contains(s[i]) { i += 1 }
    }

    /// Past a string literal starting at `i` (its quote).
    private static func skipString(_ s: [Unicode.Scalar], _ i: inout Int) {
        let q = s[i]
        i += 1
        while i < s.count {
            if s[i] == "\\" { i += 2; continue }
            if s[i] == q { i += 1; return }
            i += 1
        }
    }

    /// A JavaScript literal at `i` — object, array, string, number,
    /// true/false/null/undefined — as Foundation values (undefined/null →
    /// NSNull). nil (and `i` unspecified) when it isn't one.
    static func literal(_ s: [Unicode.Scalar], _ i: inout Int) -> Any? {
        skipSpace(s, &i)
        guard i < s.count else { return nil }
        let c = s[i]
        switch c {
        case "{":
            i += 1
            var d: [String: Any] = [:]
            while true {
                skipSpace(s, &i)
                guard i < s.count else { return nil }
                if s[i] == "}" { i += 1; return d }
                let key: String
                if s[i] == "\"" || s[i] == "'" {
                    guard let k = string(s, &i) else { return nil }
                    key = k
                } else {
                    let st = i
                    while i < s.count, CharacterSet.alphanumerics.contains(s[i]) || s[i] == "_" || s[i] == "$" { i += 1 }
                    guard i > st else { return nil }
                    key = String(String.UnicodeScalarView(s[st..<i]))
                }
                skipSpace(s, &i)
                guard i < s.count, s[i] == ":" else { return nil }
                i += 1
                guard let v = literal(s, &i) else { return nil }
                d[key] = v
                skipSpace(s, &i)
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "}" { i += 1; return d }
                return nil
            }
        case "[":
            i += 1
            var a: [Any] = []
            while true {
                skipSpace(s, &i)
                guard i < s.count else { return nil }
                if s[i] == "]" { i += 1; return a }
                guard let v = literal(s, &i) else { return nil }
                a.append(v)
                skipSpace(s, &i)
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "]" { i += 1; return a }
                return nil
            }
        case "\"", "'", "`":
            return string(s, &i)
        default:
            let st = i
            while i < s.count, CharacterSet.alphanumerics.contains(s[i]) || "+-.".unicodeScalars.contains(s[i]) { i += 1 }
            let w = String(String.UnicodeScalarView(s[st..<i]))
            switch w {
            case "true": return true
            case "false": return false
            case "null", "undefined": return NSNull()
            default:
                if let n = Int(w) { return n }
                if let d = Double(w) { return d }
                return nil
            }
        }
    }

    /// A quoted string literal, escapes decoded. A template literal with a
    /// `${…}` substitution isn't a literal (nil).
    private static func string(_ s: [Unicode.Scalar], _ i: inout Int) -> String? {
        let q = s[i]
        i += 1
        var out = String.UnicodeScalarView()
        func hex(_ n: Int) -> Unicode.Scalar? {
            guard i + n <= s.count,
                  let v = UInt32(String(String.UnicodeScalarView(s[i..<(i + n)])), radix: 16) else { return nil }
            i += n
            return Unicode.Scalar(v)
        }
        while i < s.count {
            let c = s[i]
            if c == q { i += 1; return String(out) }
            if q == "`", c == "$", i + 1 < s.count, s[i + 1] == "{" { return nil }
            if c == "\\", i + 1 < s.count {
                let e = s[i + 1]
                i += 2
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "0": out.append("\u{00}")
                case "\n": break                      // line continuation
                case "x": guard let h = hex(2) else { return nil }; out.append(h)
                case "u":
                    if i < s.count, s[i] == "{" {
                        i += 1
                        let st = i
                        while i < s.count, s[i] != "}" { i += 1 }
                        guard i < s.count, let v = UInt32(String(String.UnicodeScalarView(s[st..<i])), radix: 16),
                              let u = Unicode.Scalar(v) else { return nil }
                        i += 1
                        out.append(u)
                    } else {
                        guard i + 4 <= s.count,
                              let v = UInt32(String(String.UnicodeScalarView(s[i..<(i + 4)])), radix: 16) else { return nil }
                        i += 4
                        // A surrogate pair: \uD83D\uDE00.
                        if (0xD800...0xDBFF).contains(v), i + 6 <= s.count, s[i] == "\\", s[i + 1] == "u",
                           let lo = UInt32(String(String.UnicodeScalarView(s[(i + 2)..<(i + 6)])), radix: 16),
                           (0xDC00...0xDFFF).contains(lo) {
                            i += 6
                            if let u = Unicode.Scalar(0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)) { out.append(u) }
                        } else if let u = Unicode.Scalar(v) {
                            out.append(u)
                        }
                    }
                default: out.append(e)
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return nil
    }
}

// MARK: - Grok parser

/// Tolerant reader for Grok CLI session files
/// (`~/.grok/sessions/<pct-encoded-cwd>/<uuid>/updates.jsonl`) — a persisted
/// ACP `session/update` stream. Message text arrives in chunks; consecutive
/// chunks of the same kind are one message and get concatenated raw (chunk
/// boundaries can fall mid-word). Unknown update kinds are skipped.
enum GrokTranscriptParser {
    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [TranscriptItem] = []
        var toolNames: [String: String] = [:]
        // The previous record's sessionUpdate kind, and the promptIndex of
        // the last user chunk (see the user_message_chunk case).
        var recordKind = ""
        var lastUserPromptIndex: Int?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                  let params = obj["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String else { continue }
            let stamp = (obj["timestamp"] as? Double)
                .map { Date(timeIntervalSince1970: $0) }

            func add(_ kind: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: items.count, kind: kind,
                                            timestamp: stamp))
            }
            let prevRecordKind = recordKind
            recordKind = kind

            switch kind {
            case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
                guard let chunk = chunkText(update["content"]), !chunk.isEmpty
                else { continue }
                // A user message continues only in the very next record: a
                // prompt that was cancelled before the agent said anything
                // is followed by the next prompt with nothing but a
                // hook_execution between them (even the same promptIndex,
                // after a cancel-and-send) — two messages, never one
                // "…in the chat.Create a file…" bubble.
                let promptIndex = (update["_meta"] as? [String: Any])?["promptIndex"] as? Int
                let newPrompt = kind == "user_message_chunk"
                    && (prevRecordKind != "user_message_chunk"
                        || (promptIndex != nil && lastUserPromptIndex != nil && promptIndex != lastUserPromptIndex))
                if kind == "user_message_chunk" { lastUserPromptIndex = promptIndex }
                if !newPrompt, let last = items.last,
                   let merged = mergedKind(last.kind, chunkKind: kind, text: chunk) {
                    items[items.count - 1].kind = merged
                } else if kind == "user_message_chunk" {
                    add(.userText(chunk))
                } else if kind == "agent_message_chunk" {
                    add(.assistantText(chunk))
                } else {
                    add(.thinking(chunk))
                }
            case "tool_call":
                let raw = update["title"] as? String
                    ?? update["kind"] as? String ?? "tool"
                let meta = (update["_meta"] as? [String: Any])?["x.ai/tool"] as? [String: Any]
                let name = displayName(raw, kind: meta?["kind"] as? String,
                                       builtIn: meta?["namespace"] as? String == "grok_build")
                if let id = update["toolCallId"] as? String { toolNames[id] = name }
                let input = (update["rawInput"] as? [String: Any]).map(canonicalInput)
                add(.toolUse(
                    name: name,
                    summary: input.map {
                        ClaudeTranscriptParser.toolSummary(name: name, input: $0)
                    } ?? "",
                    detail: input.map { ClaudeTranscriptParser.prettyJSON($0) } ?? ""))
            case "tool_call_update":
                // Streams keep updating a call until it settles; only the
                // terminal status carries a result worth showing.
                let status = update["status"] as? String ?? ""
                guard status == "completed" || status == "failed" else { continue }
                let tool = (update["toolCallId"] as? String)
                    .flatMap { toolNames[$0] } ?? "tool"
                var content = (update["content"] as? [[String: Any]] ?? [])
                    .compactMap { item -> String? in
                        switch item["type"] as? String ?? "" {
                        case "content":
                            return (item["content"] as? [String: Any])?["text"] as? String
                        case "diff":
                            return (item["path"] as? String).map { "diff: \($0)" }
                        default:
                            return nil
                        }
                    }
                    .joined(separator: "\n")
                if content.isEmpty {
                    if let raw = update["rawOutput"] as? String {
                        content = raw
                    } else if let raw = update["rawOutput"] as? [String: Any] {
                        content = ClaudeTranscriptParser.prettyJSON(raw)
                    }
                }
                add(.toolResult(tool: tool, content: content,
                                isError: status == "failed"))
            case "retry_state":
                // The turn's request gave up — "failed" (not retryable, e.g.
                // auth) or "exhausted" (retries spent). Typed by error_type;
                // "retrying" is still in flight and says nothing yet.
                let state = update["type"] as? String ?? ""
                guard state == "failed" || state == "exhausted" else { continue }
                var text = (update["message"] as? String ?? update["reason"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A request Bromure's proxy blocked: Grok's message is the
                // status line ("API error (status 451 …): Request failed …").
                // Bromure's own words, wherever else the record carries them,
                // say which engine and what next — the card Codex gets.
                if BromureBlock.of(text) == nil,
                   let bromure = Self.strings(in: update).first(where: { BromureBlock.of($0) != nil }) {
                    text = bromure.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                add(.agentError(.grok(errorType: update["error_type"] as? String,
                                      rateLimited: update["is_rate_limited"] as? Bool ?? false,
                                      message: text)))
            default:
                continue    // plan, turn_completed, hook_execution, …
            }
        }
        return trimmedTextItems(items)
    }

    /// Every string in a JSON value, depth-first.
    static func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let s = value as? String { return [s] }
        if let a = value as? [Any] { return a.flatMap { strings(in: $0, depth: depth + 1) } }
        if let d = value as? [String: Any] {
            return d.keys.sorted().flatMap { strings(in: d[$0]!, depth: depth + 1) }
        }
        return []
    }

    /// Grok's built-in tools by the names the cards know (Claude's): a
    /// shell card for `run_terminal_command`, a diff for `search_replace`…
    /// Anything else (an MCP tool) keeps its own name.
    static func displayName(_ name: String, kind: String? = nil, builtIn: Bool = false) -> String {
        switch name {
        case "run_terminal_command", "run_command", "terminal": return "Bash"
        case "search_replace", "edit_file", "str_replace", "multi_edit": return "Edit"
        case "write_file", "create_file", "write": return "Write"
        case "read_file", "view_file", "read": return "Read"
        case "list_dir", "list_directory", "ls": return "LS"
        case "grep", "grep_search", "search_files": return "Grep"
        case "glob", "find_files", "file_search": return "Glob"
        case "web_fetch", "fetch_url": return "WebFetch"
        case "web_search": return "WebSearch"
        case "todo_write", "update_todos", "todo": return "TodoWrite"
        default: break
        }
        guard builtIn else { return name }
        switch kind {
        case "execute": return "Bash"
        case "fetch": return "WebFetch"
        default: return name
        }
    }

    /// Grok's input keys under the names the cards read (`target_file` →
    /// `file_path`, `target_directory` → `path`).
    static func canonicalInput(_ input: [String: Any]) -> [String: Any] {
        var out = input
        for (from, to) in [("target_file", "file_path"), ("target_directory", "path"),
                           ("directory", "path"), ("relative_workspace_path", "path")]
        where out[to] == nil {
            if let v = out.removeValue(forKey: from) { out[to] = v }
        }
        return out
    }

    /// ACP message chunks wrap text as {"type":"text","text":…}.
    private static func chunkText(_ content: Any?) -> String? {
        guard let block = content as? [String: Any],
              block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }

    /// The continuation of the immediately-preceding item, or nil when the
    /// chunk starts a new message.
    private static func mergedKind(_ last: TranscriptItem.Kind, chunkKind: String,
                                   text: String) -> TranscriptItem.Kind? {
        switch (last, chunkKind) {
        case (.userText(let s), "user_message_chunk"): return .userText(s + text)
        case (.assistantText(let s), "agent_message_chunk"): return .assistantText(s + text)
        case (.thinking(let s), "agent_thought_chunk"): return .thinking(s + text)
        default: return nil
        }
    }

    /// Chunked accumulation can leave stray edge whitespace — trim the text
    /// kinds once assembled (mid-message whitespace is untouched).
    fileprivate static func trimmedTextItems(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var out = items
        var i = 0
        while i < out.count {
            switch out[i].kind {
            case .userText(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { out.remove(at: i); continue }
                out[i].kind = .userText(t)
            case .assistantText(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { out.remove(at: i); continue }
                out[i].kind = .assistantText(t)
            case .thinking(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { out.remove(at: i); continue }
                out[i].kind = .thinking(t)
            default:
                break
            }
            i += 1
        }
        return out.enumerated().map {
            TranscriptItem(id: $0.offset, kind: $0.element.kind,
                           timestamp: $0.element.timestamp)
        }
    }
}

// MARK: - Kimi parser

/// Tolerant reader for Kimi Code wire journals
/// (`~/.kimi-code/sessions/wd_*/session_*/agents/main/wire.jsonl`). The file
/// is an op journal, not a message list: user turns arrive as whole
/// `context.append_message` records, assistant output as streamed
/// `context.append_loop_event` content parts and tool calls. Everything
/// else (llm.request, usage.record, permission.*, …) is plumbing.
enum KimiTranscriptParser {
    /// Whether the journal's tail shows a turn under way: a turn started
    /// (`turn.prompt` / `agent.turn.started`) with no `turn.ended` after it,
    /// and the journal written within `freshFor` of `now` (a crashed agent
    /// leaves its turn open forever). Kimi's status hooks drive the
    /// working cue; this is the transcript's own word for it, so the chat
    /// shows the agent at work even when a hook doesn't fire.
    /// `notBefore`: when the agent process now running started — a turn
    /// begun before it (the process was killed or restarted since) is
    /// interrupted, not in progress.
    static func turnInProgress(_ data: Data, now: Date = Date(), freshFor: TimeInterval = 180,
                               notBefore: Date? = nil) -> Bool {
        let tail = data.suffix(256_000)
        let text = String(decoding: tail, as: UTF8.self)
        var lastTime: Double?
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"type\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if lastTime == nil, let t = obj["time"] as? Double { lastTime = t }
            switch obj["type"] as? String ?? "" {
            case "turn.ended", "agent.turn.ended", "prompt.completed": return false
            case "turn.prompt", "agent.turn.started":
                guard let t = lastTime else { return false }
                if let notBefore, let began = obj["time"] as? Double,
                   Date(timeIntervalSince1970: began / 1000) < notBefore.addingTimeInterval(-2) { return false }
                return now.timeIntervalSince(Date(timeIntervalSince1970: t / 1000)) < freshFor
            default: continue
            }
        }
        return false
    }

    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [TranscriptItem] = []
        var toolNames: [String: String] = [:]
        /// tool.result events already shown, so a folded duplicate in a
        /// later append_message (role "tool") isn't shown twice.
        var seenResults: Set<String> = []
        /// The step whose content parts the last text/thinking item is
        /// accumulating — parts of the same step and type concatenate.
        var lastPartStep: String?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            let stamp = (obj["time"] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) }

            func add(_ kind: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: items.count, kind: kind,
                                            timestamp: stamp))
            }

            switch obj["type"] as? String ?? "" {
            case "context.append_message":
                lastPartStep = nil
                guard let message = obj["message"] as? [String: Any] else { continue }
                let parts = message["content"] as? [[String: Any]] ?? []
                switch message["role"] as? String ?? "" {
                case "user":
                    // Injections (system reminders, hook notices, compaction
                    // summaries) share the user role; origin tells them apart.
                    let origin = (message["origin"] as? [String: Any])?["kind"] as? String
                    guard origin == nil || origin == "user" else { continue }
                    let text = parts
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !text.hasPrefix("<system-reminder>")
                    else { continue }
                    add(.userText(text))
                case "assistant":
                    // Normally reconstructed from loop events, but tolerate
                    // whole appended assistant messages (compacted files).
                    for part in parts {
                        if let think = part["think"] as? String, !think.isEmpty {
                            add(.thinking(think))
                        } else if let text = part["text"] as? String, !text.isEmpty {
                            add(.assistantText(text))
                        }
                    }
                    for call in message["toolCalls"] as? [[String: Any]] ?? [] {
                        let name = call["name"] as? String ?? "tool"
                        if let id = call["id"] as? String { toolNames[id] = name }
                        let args = call["arguments"] as? String ?? ""
                        add(.toolUse(name: name, summary: String(args.prefix(200)),
                                     detail: args))
                    }
                case "tool":
                    guard let id = message["toolCallId"] as? String,
                          !seenResults.contains(id) else { continue }
                    seenResults.insert(id)
                    let text = parts.compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                    add(.toolResult(tool: toolNames[id] ?? "tool", content: text,
                                    isError: message["isError"] as? Bool ?? false))
                default:
                    continue
                }
            case "context.append_loop_event":
                guard let event = obj["event"] as? [String: Any] else { continue }
                switch event["type"] as? String ?? "" {
                case "content.part":
                    guard let part = event["part"] as? [String: Any] else { continue }
                    let step = event["stepUuid"] as? String
                    if let think = part["think"] as? String, !think.isEmpty {
                        if step != nil, step == lastPartStep,
                           case .thinking(let s) = items.last?.kind {
                            items[items.count - 1].kind = .thinking(s + think)
                        } else {
                            add(.thinking(think))
                        }
                    } else if let text = part["text"] as? String, !text.isEmpty {
                        if step != nil, step == lastPartStep,
                           case .assistantText(let s) = items.last?.kind {
                            items[items.count - 1].kind = .assistantText(s + text)
                        } else {
                            add(.assistantText(text))
                        }
                    } else {
                        continue    // image/audio parts — nothing to show
                    }
                    lastPartStep = step
                case "tool.call":
                    lastPartStep = nil
                    let name = event["name"] as? String ?? "tool"
                    if let id = event["toolCallId"] as? String { toolNames[id] = name }
                    let args = event["args"] as? [String: Any]
                    add(.toolUse(
                        name: name,
                        summary: args.map {
                            ClaudeTranscriptParser.toolSummary(name: name, input: $0)
                        } ?? "",
                        detail: args.map { ClaudeTranscriptParser.prettyJSON($0) } ?? ""))
                case "tool.result":
                    lastPartStep = nil
                    let result = event["result"] as? [String: Any] ?? [:]
                    let id = event["toolCallId"] as? String
                    if let id { seenResults.insert(id) }
                    add(.toolResult(
                        tool: id.flatMap { toolNames[$0] } ?? "tool",
                        content: ClaudeTranscriptParser.resultText(result["output"]),
                        isError: result["isError"] as? Bool ?? false))
                default:
                    continue    // step.begin / step.end / …
                }
            case "turn.ended":
                // A failed turn carries Kimi's own error code and the HTTP
                // status; the message after it is the provider's, any language.
                lastPartStep = nil
                guard obj["reason"] as? String == "failed",
                      let error = obj["error"] as? [String: Any] else { continue }
                let details = error["details"] as? [String: Any]
                add(.agentError(.kimi(code: error["code"] as? String, name: error["name"] as? String,
                                      status: details?["statusCode"] as? Int,
                                      message: (error["message"] as? String ?? "")
                                          .trimmingCharacters(in: .whitespacesAndNewlines))))
            default:
                // metadata, profile.bind, llm.*, usage.record, turn.*, … —
                // plumbing. turn.prompt duplicates the user append_message.
                lastPartStep = nil
                continue
            }
        }
        return GrokTranscriptParser.trimmedTextItems(items)
    }
}
