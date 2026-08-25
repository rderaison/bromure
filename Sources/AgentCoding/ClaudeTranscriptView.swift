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
        switch kind {
        case "codex": return CodexTranscriptParser.parse(data)
        case "grok": return GrokTranscriptParser.parse(data)
        case "kimi": return KimiTranscriptParser.parse(data)
        case "omp": return OmpTranscriptParser.parse(data)
        default: return ClaudeTranscriptParser.parse(data)
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
/// lines whose `message` is an Anthropic-messages object (`role` +
/// `content` blocks) — the same block shapes Claude uses — so this reuses
/// `ClaudeTranscriptParser`'s block helpers. `session`/`model_change`/
/// `thinking_level_change`/`title`/`custom` lines are metadata and skipped.
/// Tool calls are read from the assistant `content` blocks (not the parallel
/// `custom` tool entries) to avoid double-counting. Unknown lines are skipped.
enum OmpTranscriptParser {
    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [TranscriptItem] = []
        var toolNames: [String: String] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            guard obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "user" || role == "assistant" else { continue }
            let isUser = role == "user"
            let stamp = (obj["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            }
            func add(_ kind: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: items.count, kind: kind, timestamp: stamp))
            }

            // content: a bare string or an array of Anthropic-style blocks.
            if let s = message["content"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { add(isUser ? .userText(t) : .assistantText(t)) }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let s = (block["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { add(isUser ? .userText(s) : .assistantText(s)) }
                case "thinking":
                    let s = (block["thinking"] as? String ?? block["text"] as? String ?? "")
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
                                     summary: ClaudeTranscriptParser.toolSummary(name: name, input: input),
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
        return items
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
    static func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var primary: [TranscriptItem.Kind] = []
        var fallback: [TranscriptItem.Kind] = []
        var stamps: [Date?] = []
        var fallbackStamps: [Date?] = []
        var toolNames: [String: String] = [:]
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
                for kind in responseItemKinds(payload, toolNames: &toolNames) {
                    primary.append(kind)
                    stamps.append(stamp)
                }
            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any] else { continue }
                for kind in eventKinds(payload) {
                    fallback.append(kind)
                    fallbackStamps.append(stamp)
                }
            case "message", "reasoning", "function_call", "function_call_output",
                 "local_shell_call", "custom_tool_call", "custom_tool_call_output",
                 "web_search_call":
                // Early-2025 rollouts: bare ResponseItems, no envelope.
                guard obj["payload"] == nil else { continue }
                for kind in responseItemKinds(obj, toolNames: &toolNames) {
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

    private static func responseItemKinds(
        _ payload: [String: Any],
        toolNames: inout [String: String]) -> [TranscriptItem.Kind] {
        switch payload["type"] as? String ?? "" {
        case "message":
            let role = payload["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { return [] }
            let text = (payload["content"] as? [[String: Any]] ?? [])
                .compactMap { block -> String? in
                    guard ["input_text", "output_text", "text"]
                        .contains(block["type"] as? String ?? "") else { return nil }
                    return block["text"] as? String
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex injects instructions and an environment dump as
            // synthetic user turns — plumbing, not conversation.
            guard !text.isEmpty, !text.hasPrefix("<user_instructions>"),
                  !text.hasPrefix("<environment_context>") else { return [] }
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
            if let id = payload["call_id"] as? String { toolNames[id] = name }
            let argsString = payload["arguments"] as? String ?? ""
            let args = (try? JSONSerialization.jsonObject(
                with: Data(argsString.utf8))) as? [String: Any]
            let summary = args.flatMap { shellSummary($0["command"]) }
                ?? args.map { ClaudeTranscriptParser.toolSummary(name: name, input: $0) }
                ?? String(argsString.prefix(200))
            let detail = args.map { ClaudeTranscriptParser.prettyJSON($0) } ?? argsString
            return [.toolUse(name: name, summary: summary, detail: detail)]
        case "local_shell_call":
            if let id = payload["call_id"] as? String { toolNames[id] = "shell" }
            let action = payload["action"] as? [String: Any] ?? [:]
            return [.toolUse(name: "shell",
                             summary: shellSummary(action["command"]) ?? "",
                             detail: ClaudeTranscriptParser.prettyJSON(action))]
        case "custom_tool_call":
            let name = payload["name"] as? String ?? "tool"
            if let id = payload["call_id"] as? String { toolNames[id] = name }
            let input = payload["input"] as? String ?? ""
            return [.toolUse(name: name, summary: String(input.prefix(200)),
                             detail: input)]
        case "function_call_output", "custom_tool_call_output":
            let tool = (payload["call_id"] as? String)
                .flatMap { toolNames[$0] } ?? "tool"
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

            switch kind {
            case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
                guard let chunk = chunkText(update["content"]), !chunk.isEmpty
                else { continue }
                if let last = items.last,
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
                let name = update["title"] as? String
                    ?? update["kind"] as? String ?? "tool"
                if let id = update["toolCallId"] as? String { toolNames[id] = name }
                let input = update["rawInput"] as? [String: Any]
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
            default:
                continue    // plan, turn_completed, hook_execution, retry_state, …
            }
        }
        return trimmedTextItems(items)
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
                // Sniffed, not assumed: archived runs may have been driven
                // by any of the supported agents.
                return AgentTranscript.parse(data)
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
        .background(Color.platformWindowBackground)
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
            .fill(Color.platformTextBackground)
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

    #if os(iOS) || os(visionOS)
    private static let userTextSize: CGFloat = 16
    #else
    private static let userTextSize: CGFloat = 12.5
    #endif

    var body: some View {
        switch item.kind {
        case .userText(let text):
            VStack(alignment: .leading, spacing: 4) {
                Label(NSLocalizedString("Prompt", comment: "transcript role"),
                      systemImage: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: Self.userTextSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
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
        let bodySize: CGFloat = 13.5   // a dense dev tool on the Mac
        let serif = false
        #endif
        Markdown(text)
            .markdownTheme(.claudeReader(bodySize: bodySize, serif: serif))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            ScrollView(.horizontal, showsIndicators: false) {
                c.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(bodySize * 0.86) }
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.10)))
            .markdownMargin(top: .em(0.4), bottom: .em(0.85))
        }
        return t
    }
}
