import MarkdownUI
import SwiftUI

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
                let shell = isShellTool(name)
                item.kind = .toolUse(name: name, summary: shell ? d(summary) : homeDisplay(d(summary)),
                                     detail: shell ? d(detail) : homeDisplay(d(detail)))
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

struct TranscriptItemView: View {
    let item: TranscriptItem
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
            // No role label — the filled card (against the assistant's plain
            // flowing prose) and the accent spine already read as "your turn",
            // the way Codex/Claude desktop distinguish input from output.
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
                VStack(alignment: .leading, spacing: 8) {
                    if !words.isEmpty {
                        Text(words)
                            .font(.system(size: Self.userTextSize))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !attachments.isEmpty { DropPictureStrip(images: attachments) }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
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

enum TodoStatus: Equatable { case pending, active, done, blocked
    static func parse(_ s: String?) -> TodoStatus {
        switch (s ?? "").lowercased() {
        case "completed", "complete", "done", "x": return .done
        case "in_progress", "inprogress", "active", "doing", "running": return .active
        case "blocked": return .blocked
        default: return .pending
        }
    }
    /// Canonical string for the fat-client wire codec (round-trips via `parse`).
    var wire: String {
        switch self {
        case .pending: return "pending"
        case .active:  return "in_progress"
        case .done:    return "completed"
        case .blocked: return "blocked"
        }
    }
}

struct TodoRowModel: Identifiable, Equatable {
    let text: String
    let status: TodoStatus
    let phase: String?
    /// Stable across polls (content-derived), so an in-place todo update only
    /// redraws changed rows and TranscriptItem equality works.
    var id: String { (phase ?? "") + "\u{1}" + text }
}

/// Normalizes a todo/plan tool call's arguments into checklist rows. Kept
/// separate from the view so it's unit-testable. Handles the three shapes seen
/// in practice (Claude `todos`, omp `list`, Codex `plan`); a delta op with no
/// item list yields no rows (the card shows a one-line status instead).
enum TodoParse {
    static func rows(from input: [String: Any]) -> [TodoRowModel] {
        if let todos = input["todos"] as? [[String: Any]] {          // Claude
            return todos.compactMap { t in
                let text = (t["content"] as? String) ?? (t["activeForm"] as? String) ?? ""
                return text.isEmpty ? nil
                    : TodoRowModel(text: text, status: .parse(t["status"] as? String), phase: nil)
            }
        }
        if let list = input["list"] as? [[String: Any]] {            // omp init
            var out: [TodoRowModel] = []
            for p in list {
                let phase = p["phase"] as? String
                for it in (p["items"] as? [String] ?? []) {
                    out.append(TodoRowModel(text: it, status: .pending, phase: phase))
                }
            }
            return out
        }
        if let plan = input["plan"] as? [[String: Any]] {            // Codex
            return plan.compactMap { p in
                guard let s = p["step"] as? String, !s.isEmpty else { return nil }
                return TodoRowModel(text: s, status: .parse(p["status"] as? String), phase: nil)
            }
        }
        return []
    }

    /// Per-item status read from omp's todo-tool RESULT text — its authoritative
    /// rendering (the call args don't carry live status, and its delta ops don't
    /// reliably mutate state). The text lists remaining items with a `[status]`
    /// tag, or all items as `- [X]`/`- [ ]`. An item ABSENT from the text is
    /// done: the "remaining items" form omits completed ones.
    static func statusFromResult(itemText: String, resultText: String) -> TodoStatus {
        for line in resultText.split(whereSeparator: \.isNewline) {
            guard line.contains(itemText) else { continue }
            let l = line.lowercased()
            if l.contains("[x]") { return .done }
            if l.contains("[in_progress]") || l.contains("[in progress]") { return .active }
            if l.contains("[blocked]") { return .blocked }
            if l.contains("[ ]") || l.contains("[pending]") { return .pending }
            return .pending                       // listed but untagged
        }
        return .done                              // absent → completed
    }

    /// The live checklist: the plan's full item list (from the `init` call) with
    /// each item's status taken from the latest result text. Without a result yet
    /// the plan shows as-is (all pending).
    static func merge(initRows: [TodoRowModel], resultText: String?) -> [TodoRowModel] {
        guard let resultText, !resultText.isEmpty else { return initRows }
        return initRows.map {
            TodoRowModel(text: $0.text,
                         status: statusFromResult(itemText: $0.text, resultText: resultText),
                         phase: $0.phase)
        }
    }
}

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
