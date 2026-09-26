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
        var modified: Date
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
            }
        }
    }

    nonisolated static func entry(_ data: Data, modified: Date) -> Entry {
        let items = AgentTranscript.parse(data)
        var parts: [String] = []
        var last = ""
        for item in items {
            switch item.kind {
            case .userText(let t): parts.append(t)
            case .assistantText(let t): parts.append(t); last = t
            default: break
            }
        }
        let oneLine = last.split(whereSeparator: \.isNewline).map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return Entry(text: parts.joined(separator: "\n\n"),
                     lastReply: String(oneLine.prefix(160)),
                     tokens: tokens(in: data), modified: modified)
    }

    /// Token use as the agent logged it: Claude's per-message `usage`
    /// summed; Codex's running `total_token_usage`, its last value.
    nonisolated static func tokens(in data: Data) -> TokenUsage {
        let raw = String(decoding: data, as: UTF8.self)
        func ints(_ pattern: String, in s: String) -> [Int] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).flatMap { Int(s[$0]) }
            }
        }
        if let r = raw.range(of: "\"total_token_usage\"", options: .backwards) {
            let tail = String(raw[r.lowerBound...].prefix(400))
            let input = ints(#""input_tokens":\s*(\d+)"#, in: tail).first ?? 0
            let cached = ints(#""cached_input_tokens":\s*(\d+)"#, in: tail).first ?? 0
            let output = ints(#""output_tokens":\s*(\d+)"#, in: tail).first ?? 0
            return TokenUsage(input: max(0, input - cached), cached: cached, output: output)
        }
        return TokenUsage(
            input: ints(#""input_tokens":\s*(\d+)"#, in: raw).reduce(0, +)
                + ints(#""cache_creation_input_tokens":\s*(\d+)"#, in: raw).reduce(0, +),
            cached: ints(#""cache_read_input_tokens":\s*(\d+)"#, in: raw).reduce(0, +),
            output: ints(#""output_tokens":\s*(\d+)"#, in: raw).reduce(0, +))
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
