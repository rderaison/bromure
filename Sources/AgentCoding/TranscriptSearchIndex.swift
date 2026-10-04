#if os(macOS)
import Foundation
import Observation

/// What was said in every session on this Mac — your messages and the
/// agent's replies — read from the local transcript copies, so the sidebar
/// search and ⌘K find conversations by their content, a row can preview its
/// last reply, and the header can say how many tokens a session has used.
///
/// Built off the main thread and refreshed by file date: a transcript is
/// re-read only when its copy changed.
@MainActor
@Observable
final class TranscriptSearchIndex {
    static let shared = TranscriptSearchIndex()

    struct Entry: Sendable {
        /// The conversation's words, one message per paragraph.
        var text: String
        /// The agent's last reply, one line.
        var lastReply: String
        var tokens: TokenUsage
        /// The model the agent last answered with, as it logged it.
        var model: String? = nil
        /// Each turn, from the user's message to the agent's last event
        /// before the next one — the time the agent spent working. Kept per
        /// turn (not just summed) for a timeline of where the time went.
        var turns: [Turn] = []
        /// Turns with their tool calls and model time (the flamegraph).
        var timeline = SessionTimeline(turns: [])
        /// The agent's own name for the conversation: Claude's `/rename`
        /// (custom-title), else the title it generated (ai-title).
        var agentTitle: String? = nil
        /// The user's first real request (no notices, no host asides).
        var firstPrompt: String? = nil
        var modified: Date
    }

    struct Turn: Sendable, Equatable {
        var start: Date
        var end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct TokenUsage: Sendable, Equatable {
        var input = 0
        var cached = 0
        var output = 0
        var total: Int { input + cached + output }
    }

    private(set) var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/transcripts", isDirectory: true)
    }

    /// Start keeping up (idempotent).
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Re-read the transcripts whose copies changed since the last pass.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let known = entries.mapValues(\.modified)
        let dir = self.dir
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var updates: [UUID: Entry] = [:]
            var present: Set<UUID> = []
            for url in files where url.pathExtension == "jsonl" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                present.insert(id)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if let k = known[id], k >= date { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                updates[id] = Self.entry(data, modified: date)
            }
            await MainActor.run {
                for (id, e) in updates { self.entries[id] = e }
                for id in self.entries.keys where !present.contains(id) { self.entries[id] = nil }
                self.refreshing = false
                if !updates.isEmpty { self.onUpdate?(Array(updates.keys)) }
            }
        }
    }

    /// Called with the sessions whose entries were just re-read.
    @ObservationIgnored var onUpdate: (([UUID]) -> Void)?

    /// Claude's own title for the conversation, the latest one it logged:
    /// a `/rename` (custom-title) wins over the generated ai-title.
    nonisolated static func agentTitle(in data: Data) -> String? {
        let raw = String(decoding: data, as: UTF8.self)
        func last(_ type: String, _ key: String) -> String? {
            guard let r = raw.range(of: "\"type\":\"\(type)\"", options: .backwards) else { return nil }
            let start = raw[..<r.lowerBound].lastIndex(of: "\n").map { raw.index(after: $0) } ?? raw.startIndex
            let end = raw[r.upperBound...].firstIndex(of: "\n") ?? raw.endIndex
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw[start..<end].utf8)) as? [String: Any],
                  let t = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return String(t.prefix(60))
        }
        return last("custom-title", "customTitle") ?? last("ai-title", "aiTitle")
    }

    /// A user message that is the user's own words — not a notice typed in
    /// by the host, a relayed delegation, or a tool/system tag.
    nonisolated static func isOwnWords(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && !s.hasPrefix("<") && !s.hasPrefix("[")
            && !DelegationNotice.isHostAside(s) && DelegationNotice.strip(s) == nil
    }

    nonisolated static func entry(_ data: Data, modified: Date) -> Entry {
        let items = AgentTranscript.parse(data)
        var firstPrompt: String?
        var parts: [String] = []
        var last = ""
        var turns: [Turn] = []
        var open: Turn?
        for item in items {
            switch item.kind {
            case .userText(let t):
                parts.append(t)
                if firstPrompt == nil, isOwnWords(t) { firstPrompt = t }
                if let o = open, o.end > o.start { turns.append(o) }
                open = item.timestamp.map { Turn(start: $0, end: $0) }
                continue
            case .assistantText(let t): parts.append(t); last = t
            default: break
            }
            if let ts = item.timestamp, let o = open, ts > o.end { open?.end = ts }
        }
        if let o = open, o.end > o.start { turns.append(o) }
        let oneLine = last.split(whereSeparator: \.isNewline).map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return Entry(text: parts.joined(separator: "\n\n"),
                     lastReply: String(oneLine.prefix(160)),
                     tokens: tokens(in: data), model: model(in: data),
                     turns: turns, timeline: SessionTimeline.build(items),
                     agentTitle: agentTitle(in: data), firstPrompt: firstPrompt, modified: modified)
    }

    /// The last model the agent logged: Claude's per-message `"model"`,
    /// Codex's turn context, Kimi's `modelAlias`. Placeholders an agent
    /// logs in the model slot (Claude's `<synthetic>`, Kimi's internal
    /// "agent-loop") are skipped.
    nonisolated static func model(in data: Data) -> String? {
        let raw = String(decoding: data.suffix(2_000_000), as: UTF8.self)
        func last(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let all = re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            for m in all.reversed() {
                guard let r = Range(m.range(at: 1), in: raw) else { continue }
                let v = String(raw[r])
                if !placeholderModels.contains(v.lowercased()) { return v }
            }
            return nil
        }
        // An assistant message's own model first: a bare "model" key can
        // just as well sit in a tool's input or a file the agent read.
        return last(#""message"\s*:\s*\{\s*"model"\s*:\s*"([^"<]{2,80})""#)
            ?? last(#""modelAlias"\s*:\s*"([^"<]{2,80})""#)
            ?? last(#""model"\s*:\s*"([^"<]{2,80})""#)
    }

    /// Values agents put in a model field that name no model.
    nonisolated static let placeholderModels: Set<String> = ["agent-loop", "synthetic", "unknown", "default"]

    /// "claude-opus-4-5-20251101" → "Opus 4.5"; "kimi-code/kimi-for-coding"
    /// → "Kimi for Coding"; anything else as logged (minus a provider prefix).
    nonisolated static func prettyModel(_ m: String) -> String {
        var m = m
        // "provider/model" (Kimi's alias, OpenRouter ids): the model part.
        if let slash = m.lastIndex(of: "/"), m.index(after: slash) < m.endIndex {
            m = String(m[m.index(after: slash)...])
        }
        if m.lowercased().hasPrefix("kimi-") {
            let small: Set<String> = ["for", "with", "and", "of"]
            return m.split(separator: "-").enumerated().map { i, w in
                let s = String(w)
                if i > 0, small.contains(s.lowercased()) { return s.lowercased() }
                return s.prefix(1).uppercased() + s.dropFirst()
            }.joined(separator: " ")
        }
        guard m.hasPrefix("claude-") else { return m }
        let parts = m.dropFirst("claude-".count).split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map(\.capitalized)
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
        return name.isEmpty ? m : name
    }

    func model(_ id: UUID) -> String? { entries[id]?.model.map(Self.prettyModel) }

    /// The session's model; before its transcript names one (a session
    /// still starting), the one its agent last used on the same machine —
    /// so the header doesn't gain the model only once the agent is ready.
    func model(for s: AgentSession, among sessions: [AgentSession]) -> String? {
        if let m = model(s.id) { return m }
        return sessions
            .filter { $0.id != s.id && $0.profileID == s.profileID && $0.tool == s.tool }
            .compactMap { o in entries[o.id].flatMap { e in e.model.map { (e.modified, $0) } } }
            .max { $0.0 < $1.0 }
            .map { Self.prettyModel($0.1) }
    }

    func timeline(_ id: UUID) -> SessionTimeline? {
        entries[id].flatMap { $0.timeline.turns.isEmpty ? nil : $0.timeline }
    }

    /// Time the agent spent working in a session, turn by turn.
    func turns(_ id: UUID) -> [Turn] { entries[id]?.turns ?? [] }

    /// "2h 05m", "14m", "40s".
    nonisolated static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// How full the conversation's context is, as the agent last logged it:
    /// the LATEST model call's prompt (fresh input + cache writes + cache
    /// reads) plus its reply — not a running sum. Summing per-message usage
    /// counted the cached prefix again on every call, so a one-line turn
    /// could add 180k "tokens".
    ///   - Claude: the last `usage` with `input_tokens`
    ///   - Codex: `last_token_usage` (its `input_tokens` include the cached)
    ///   - Kimi: the last `usage` with `inputOther` / `inputCacheRead`
    ///   - omp (pi): the last `usage` with `cacheRead`
    nonisolated static func tokens(in data: Data) -> TokenUsage {
        let raw = String(decoding: data.suffix(4_000_000), as: UTF8.self)
        func int(_ key: String, in s: Substring) -> Int {
            guard let r = s.range(of: "\"\(key)\"") else { return 0 }
            var rest = s[r.upperBound...].drop(while: { $0 == " " || $0 == ":" })
            rest = rest.prefix(while: \.isNumber)
            return Int(rest) ?? 0
        }
        /// The text after the last `anchor` in `line` up to the end of the
        /// object holding it (braces balanced, so a nested object inside —
        /// Claude's `cache_creation` — doesn't cut it short).
        func object(after anchor: String, in line: Substring) -> Substring? {
            guard let r = line.range(of: anchor, options: .backwards) else { return nil }
            let tail = line[r.upperBound...]
            // The anchor is either a key whose value is the object
            // (`"usage":{…}`) or a key inside it (`"inputOther":1,…}`): stop
            // where that object closes.
            var depth = 0
            for i in tail.indices {
                switch tail[i] {
                case "{": depth += 1
                case "}":
                    if depth == 0 { return tail[..<i] }
                    depth -= 1
                    if depth == 0 { return tail[...i] }
                default: break
                }
            }
            return tail
        }
        for line in raw.split(whereSeparator: \.isNewline).reversed() {
            if line.contains("\"last_token_usage\""),
               let u = object(after: "\"last_token_usage\"", in: line) {
                let input = int("input_tokens", in: u), cached = int("cached_input_tokens", in: u)
                return TokenUsage(input: max(0, input - cached), cached: cached, output: int("output_tokens", in: u))
            }
            if line.contains("\"inputOther\""), let u = object(after: "\"inputOther\"", in: line) {
                let full = "\"inputOther\"" + u
                return TokenUsage(input: int("inputOther", in: Substring(full)) + int("inputCacheCreation", in: Substring(full)),
                                  cached: int("inputCacheRead", in: Substring(full)),
                                  output: int("output", in: Substring(full)))
            }
            // An assistant message's own usage — a Task tool's result (a
            // user line) carries its subagent's.
            if line.contains("\"input_tokens\""), line.contains("\"usage\""),
               !line.contains("\"type\":\"user\""),
               let u = object(after: "\"usage\"", in: line), u.contains("\"input_tokens\"") {
                return TokenUsage(input: int("input_tokens", in: u) + int("cache_creation_input_tokens", in: u),
                                  cached: int("cache_read_input_tokens", in: u),
                                  output: int("output_tokens", in: u))
            }
            if line.contains("\"cacheRead\""), line.contains("\"usage\""),
               let u = object(after: "\"usage\"", in: line), u.contains("\"cacheRead\"") {
                return TokenUsage(input: int("input", in: u) + int("cacheWrite", in: u),
                                  cached: int("cacheRead", in: u), output: int("output", in: u))
            }
        }
        return TokenUsage()
    }

    /// Sessions whose conversation mentions `query`, each with the words
    /// around the first mention.
    func matches(_ query: String) -> [UUID: String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [:] }
        var out: [UUID: String] = [:]
        for (id, e) in entries {
            guard let r = e.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            out[id] = Self.snippet(e.text, around: r)
        }
        return out
    }

    nonisolated static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        // A short lead-in, so the match stays in view in a narrow row.
        let start = text.index(r.lowerBound, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    func lastReply(_ id: UUID) -> String? { entries[id].map(\.lastReply).flatMap { $0.isEmpty ? nil : $0 } }
    func tokens(_ id: UUID) -> TokenUsage? { entries[id].map(\.tokens).flatMap { $0.total > 0 ? $0 : nil } }

    /// "1.2M", "34k", "812".
    nonisolated static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:    return "\(n / 1000)k"
        case 1000...:      return String(format: "%.1fk", Double(n) / 1000)
        default:           return "\(n)"
        }
    }
}
#endif
