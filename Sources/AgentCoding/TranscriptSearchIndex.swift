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

    struct Entry: Sendable, Codable, Equatable {
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
        /// `agentTitle` is the user's `/rename`, not one the agent generated:
        /// it wins over a generated one from any other part of the file.
        /// Optional, so a record saved before it decodes (as generated).
        var agentTitleIsCustom: Bool? = nil
        /// The user's first real request (no notices, no host asides).
        var firstPrompt: String? = nil
        var modified: Date
        /// The conversation the copy holds, when it says (Codex's
        /// `session_meta` id): a copy that took another session's
        /// conversation in is never counted as this one's.
        var conversationID: String? = nil
        /// The conversation started over in these bytes (Claude's `/clear`):
        /// nothing of what came before belongs to it (`joined`).
        var startsOver = false
    }

    /// This entry, for the bytes up to a turn's start, then `later`'s, for the
    /// bytes from there: the entry of both (see `turnStart`).
    nonisolated static func joined(_ a: Entry, _ b: Entry) -> Entry {
        var e = b
        // Read off the bytes, whatever the conversation did: the latest one
        // wins, or the first.
        e.tokens = b.tokens.total == 0 ? a.tokens : b.tokens
        e.model = b.model ?? a.model
        (e.agentTitle, e.agentTitleIsCustom) = mergedTitle(a, b)
        e.conversationID = a.conversationID ?? b.conversationID
        e.startsOver = a.startsOver || b.startsOver
        // What the conversation said: none of `a` if it started over in `b`.
        guard !b.startsOver else { return e }
        e.text = a.text.isEmpty ? b.text : b.text.isEmpty ? a.text : a.text + "\n\n" + b.text
        if b.lastReply.isEmpty { e.lastReply = a.lastReply }
        e.turns = a.turns + b.turns
        e.timeline = SessionTimeline.joined(a.timeline, b.timeline)
        e.firstPrompt = a.firstPrompt ?? b.firstPrompt
        return e
    }

    struct Turn: Sendable, Equatable, Codable {
        var start: Date
        var end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct TokenUsage: Sendable, Equatable, Codable {
        var input = 0
        var cached = 0
        var output = 0
        var total: Int { input + cached + output }
    }

    private(set) var entries: [UUID: Entry] = [:]
    /// What each transcript was read to: where to carry on from.
    @ObservationIgnored private var records: [UUID: Record] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let storeDir: URL

    /// Sessions removed since a pass last saw their transcript gone: a pass
    /// already under way when one was removed read it, and mustn't put it back.
    @ObservationIgnored private var forgotten: Set<UUID> = []

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(dir: support.appendingPathComponent("BromureAC/transcripts", isDirectory: true),
                  storeDir: support.appendingPathComponent("BromureAC/transcript-index", isDirectory: true))
    }

    init(dir: URL, storeDir: URL) {
        self.dir = dir
        self.storeDir = storeDir
    }

    nonisolated static func recordURL(_ id: UUID, in storeDir: URL) -> URL {
        storeDir.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// A session was removed: what the index kept of its conversation (your
    /// messages and the agent's replies, saved to disk for the next launch)
    /// goes now, not at that launch.
    func forget(_ id: UUID) {
        forgotten.insert(id)
        entries[id] = nil
        records[id] = nil
        liveModels[id] = nil
        let url = Self.recordURL(id, in: storeDir)
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }

    /// Start keeping up (idempotent).
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Read what the transcripts gained since the last pass: only the turn
    /// each was last in, and for one not seen before (or rewritten), all of it.
    /// The first pass after a launch starts from what the last run saved.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let known = records
        let firstPass = !loaded
        let dir = self.dir, storeDir = self.storeDir
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var known = known
            if firstPass { known = Self.loadRecords(from: storeDir) }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var updates: [UUID: Record] = [:]
            var present: Set<UUID> = []
            for url in files where url.pathExtension == "jsonl" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                present.insert(id)
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = rv?.contentModificationDate ?? Date()
                let size = UInt64(rv?.fileSize ?? 0)
                if let k = known[id], k.modified == date, k.size == size {
                    if firstPass { updates[id] = k }   // as saved: nothing to read
                    continue
                }
                if let r = Self.read(url, modified: date, known: known[id]) {
                    updates[id] = r
                    Self.save(r, id: id, in: storeDir)
                }
            }
            // Records of transcripts that are gone, on every pass: what a
            // session said stays on disk no longer than its transcript.
            for (id, _) in known where !present.contains(id) {
                try? fm.removeItem(at: Self.recordURL(id, in: storeDir))
            }
            let found = updates, seen = present
            await MainActor.run {
                // Removed while this pass read it: not back in, and its record
                // (saved just now) goes again.
                let back = Set(found.keys).intersection(self.forgotten)
                for id in back {
                    let url = Self.recordURL(id, in: storeDir)
                    DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
                }
                self.forgotten.formIntersection(seen)   // its transcript gone from disk: done
                for (id, r) in found where !back.contains(id) { self.records[id] = r; self.entries[id] = r.entry }
                for id in self.entries.keys where !seen.contains(id) { self.entries[id] = nil; self.records[id] = nil }
                if firstPass {
                    for id in self.records.keys where !seen.contains(id) { self.records[id] = nil }
                    self.loaded = true
                }
                self.refreshing = false
                let updated = Set(found.keys).subtracting(back)
                if !updated.isEmpty { self.onUpdate?(Array(updated)) }
            }
        }
    }

    /// What the index keeps of a transcript between passes and launches.
    struct Record: Codable, Sendable, Equatable {
        static let currentVersion = 1
        var version = Record.currentVersion
        var size: UInt64
        var modified: Date
        var entry: Entry
        var resume: Resume?
    }

    /// Where the transcript's last turn starts, and the entry of everything
    /// before it (`turnStart`, `joined`). The copies are rewritten whole
    /// (`SessionTranscriptCache`), appended to or with older records put in
    /// front, so a rewrite of what came before shifts it: `head`, `before` and
    /// the `probes` spread over it then differ, and it's all read again. An
    /// edit that kept every byte's place wouldn't be seen; the copies never
    /// make one.
    struct Resume: Codable, Sendable, Equatable {
        var offset: UInt64
        var prefix: Entry
        var head: Data
        var before: Data
        var probes: [Data]
        var agent: String
        /// The format was read off all the lines `sniff` reads: a longer copy
        /// of the file reads as the same one. Not settled, the file is read
        /// anew, as it is small.
        var agentSettled: Bool
    }

    nonisolated static let fingerprint = 64
    nonisolated static let probeCount = 16

    /// `probeCount` small reads spread evenly over the first `end` bytes.
    nonisolated static func probes(upTo end: UInt64, using read: (UInt64, Int) -> Data?) -> [Data] {
        guard end > UInt64(fingerprint) else { return [] }
        let span = end - UInt64(fingerprint)
        return (0..<probeCount).map { i in read(span * UInt64(i) / UInt64(probeCount), 16) ?? Data() }
    }

    /// A transcript's record: carried on from `known` when the file still
    /// starts and runs up to its resume point the same, else read anew.
    nonisolated static func read(_ url: URL, modified: Date, known: Record?,
                                 cap: Int = indexCap, head: Int = indexHead) -> Record? {
        autoreleasepool {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd() else { return nil }
            func bytes(at offset: UInt64, _ count: Int) -> Data? {
                guard (try? h.seek(toOffset: offset)) != nil else { return nil }
                return (try? h.read(upToCount: count)) ?? Data()
            }
            let fileHead = bytes(at: 0, fingerprint) ?? Data()
            // Carry on: only what's after the last turn's start.
            if let k = known, k.version == Record.currentVersion, let r = k.resume, r.agentSettled,
               size >= r.offset, size - r.offset <= UInt64(cap), fileHead == r.head,
               r.offset < UInt64(r.before.count) || bytes(at: r.offset - UInt64(r.before.count), r.before.count) == r.before,
               probes(upTo: r.offset, using: bytes) == r.probes,
               let rest = bytes(at: r.offset, Int(size - r.offset)) {
                return record(prefix: r.prefix, offset: r.offset, bytes: rest, agent: r.agent, settled: true,
                              size: size, modified: modified, head: fileHead, handle: h)
            }
            // Anew: all of it, or past the cap its start and its end.
            guard size > UInt64(cap) else {
                guard let data = bytes(at: 0, Int(size)) else { return nil }
                return record(prefix: nil, offset: 0, bytes: data, agent: AgentTranscript.sniff(data),
                              settled: AgentTranscript.sniffIsSettled(data),
                              size: size, modified: modified, head: fileHead, handle: h)
            }
            guard let s = samples(size: size, cap: cap, head: head, read: bytes) else { return nil }
            let start = s.start, end = s.end
            // The format comes from the start: the end of a file can look like
            // another agent's lines.
            let agent = AgentTranscript.sniff(start.isEmpty ? end : start)
            let front = start.isEmpty && end.isEmpty
                ? salvagedEntry(s.rawHead, modified: modified) : entry(start, modified: modified, agent: agent)
            return record(prefix: front, offset: s.endAt, bytes: end,
                          agent: agent, settled: AgentTranscript.sniffIsSettled(start.isEmpty ? end : start),
                          size: size, modified: modified, head: fileHead, handle: h)
        }
    }

    /// The record of `prefix` (the entry of what's before `offset`, nil for
    /// nothing) followed by `bytes`, resuming next time at the last turn
    /// start found in them.
    nonisolated private static func record(prefix: Entry?, offset: UInt64, bytes: Data, agent: String,
                                           settled: Bool, size: UInt64, modified: Date, head: Data,
                                           handle: FileHandle) -> Record {
        var front = prefix
        var resumeAt = offset
        var rest = bytes
        if let t = turnStart(in: bytes, agent: agent), t > 0 {
            let before = entry(Data(bytes[bytes.startIndex ..< bytes.startIndex + t]), modified: modified, agent: agent)
            front = front.map { joined($0, before) } ?? before
            resumeAt = offset + UInt64(t)
            rest = Data(bytes[(bytes.startIndex + t)...])
        }
        let last = entry(rest, modified: modified, agent: agent)
        var whole = front.map { joined($0, last) } ?? last
        whole.modified = modified
        let fp = Int(min(UInt64(fingerprint), resumeAt))
        var before = Data()
        if fp > 0, (try? handle.seek(toOffset: resumeAt - UInt64(fp))) != nil {
            before = (try? handle.read(upToCount: fp)) ?? Data()
        }
        let empty = Entry(text: "", lastReply: "", tokens: TokenUsage(), modified: modified)
        let marks = probes(upTo: resumeAt) { at, count in
            guard (try? handle.seek(toOffset: at)) != nil else { return nil }
            return (try? handle.read(upToCount: count)) ?? Data()
        }
        return Record(size: size, modified: modified, entry: whole,
                      resume: Resume(offset: resumeAt, prefix: front ?? empty, head: head,
                                     before: before, probes: marks, agent: agent, agentSettled: settled))
    }

    nonisolated static func save(_ r: Record, id: UUID, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(r) else { return }
        try? data.write(to: recordURL(id, in: dir), options: .atomic)
    }

    nonisolated static func loadRecords(from dir: URL) -> [UUID: Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [UUID: Record] = [:]
        for url in files where url.pathExtension == "json" {
            autoreleasepool {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let data = try? Data(contentsOf: url),
                      let r = try? JSONDecoder().decode(Record.self, from: data),
                      r.version == Record.currentVersion else { return }
                out[id] = r
            }
        }
        return out
    }

    /// One transcript's entry, leaving nothing behind but the entry. Parsing
    /// autoreleases Foundation objects by the million, and a detached task's
    /// loop never drains them by itself: after a launch, with every transcript
    /// to read, they piled up to several times the transcripts' own size before
    /// the pass ended and they all went at once.
    nonisolated static func entry(of url: URL, modified: Date,
                                  cap: Int = indexCap, head: Int = indexHead) -> Entry? {
        autoreleasepool {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd(), (try? h.seek(toOffset: 0)) != nil else { return nil }
            guard size > UInt64(cap) else {
                guard let data = try? h.readToEnd() else { return nil }
                return entry(data, modified: modified)
            }
            // Its start, for what only the start says, and its end.
            guard let s = samples(size: size, cap: cap, head: head, read: { at, count in
                guard (try? h.seek(toOffset: at)) != nil else { return nil }
                return (try? h.read(upToCount: count)) ?? Data()
            }) else { return nil }
            let start = s.start, end = s.end
            if start.isEmpty && end.isEmpty { return salvagedEntry(s.rawHead, modified: modified) }
            // The format comes from the start: the end of a file can look like
            // another agent's lines.
            let agent = AgentTranscript.sniff(start.isEmpty ? end : start)
            let first = entry(start, modified: modified, agent: agent)
            var e = entry(end, modified: modified, agent: agent)
            e.text = first.text + "\n\n" + e.text
            e.firstPrompt = first.firstPrompt ?? e.firstPrompt
            e.conversationID = first.conversationID ?? e.conversationID
            (e.agentTitle, e.agentTitleIsCustom) = mergedTitle(first, e)
            e.model = e.model ?? first.model
            return e
        }
    }

    /// A file past the cap, sampled: `start` its first `head` bytes cut back to
    /// the last whole line, `end` the rest of the cap from its end after the
    /// first line break (`endAt` where that is). A first record longer than
    /// `head` is read whole when it fits in half the cap (the end then gets
    /// what's left, so the two stay within the cap): it left the start empty,
    /// and a file of one long record (a pasted prompt, a tool's output) had
    /// nothing indexed at all. `rawHead`: the first `head` bytes, for
    /// `salvagedEntry` when neither sample holds a whole line.
    nonisolated static func samples(size: UInt64, cap: Int, head: Int,
                                    read: (UInt64, Int) -> Data?) -> (start: Data, end: Data, endAt: UInt64, rawHead: Data)? {
        guard let raw = read(0, head) else { return nil }
        var start = Data(), took = head
        if let nl = raw.lastIndex(of: 0x0A) {
            start = Data(raw[...nl])
        } else if cap / 2 > head, let longer = read(0, cap / 2), let nl = longer.firstIndex(of: 0x0A) {
            start = Data(longer[...nl])
            took = start.count
        }
        let tailAt = size - UInt64(cap - took)
        guard var end = read(tailAt, Int(size - tailAt)) else { return nil }
        var endAt = tailAt
        if let nl = end.firstIndex(of: 0x0A) {
            endAt += UInt64(nl - end.startIndex + 1)
            end = Data(end[(nl + 1)...])
        } else {
            endAt = size
            end = Data()
        }
        return (start, end, endAt, raw)
    }

    /// What one record too long to parse says, from its first bytes: the words
    /// of its `text` and `content` strings, in order (the last one cut where
    /// the bytes end), as a user's prompt or the agent's reply.
    nonisolated static func salvagedEntry(_ data: Data, modified: Date) -> Entry {
        let s = String(decoding: data, as: UTF8.self)
        var found: [(String.Index, String)] = []
        for key in ["\"text\":\"", "\"content\":\""] {
            var from = s.startIndex
            while let r = s.range(of: key, range: from..<s.endIndex) {
                var i = r.upperBound, raw = "", escaped = false, closed = false
                while i < s.endIndex {
                    let c = s[i]
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { closed = true; break }
                    raw.append(c)
                    i = s.index(after: i)
                }
                // Cut mid-escape (a lone "\" or a short "\u12"): drop it.
                var value: String?
                for drop in 0...6 where value == nil && raw.count >= drop {
                    value = try? JSONSerialization.jsonObject(with: Data(("\"" + raw.dropLast(drop) + "\"").utf8),
                                                              options: .fragmentsAllowed) as? String
                }
                if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { found.append((r.lowerBound, v)) }
                from = closed ? s.index(after: i) : s.endIndex
            }
        }
        let texts = found.sorted { $0.0 < $1.0 }.map(\.1)
        let text = texts.joined(separator: "\n\n")
        let lead = s.prefix(4096)
        let isUser = lead.contains("\"type\":\"user\"") || lead.contains("\"role\":\"user\"")
        let first = texts.first ?? ""
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Entry(text: text, lastReply: isUser ? "" : String(line.prefix(160)), tokens: TokenUsage(),
                     firstPrompt: isUser && isOwnWords(first) ? first : nil, modified: modified)
    }

    /// Past this, a transcript is read for its first `indexHead` bytes and the
    /// rest of the cap from its end. Search, the timeline and the time worked
    /// then cover those parts only. A 944 MB transcript peaked at 2.2 GB while
    /// parsed, and kept 22 MB of text.
    nonisolated static let indexCap = 100 * 1_048_576
    nonisolated static let indexHead = 1_048_576

    /// Where the last turn starts: the byte offset of the last line that opens
    /// one (a prompt), or nil. Everything a turn carries (open tool calls, a
    /// question waiting on the user) ends at a prompt, so the entry of what's
    /// before it and the entry of the rest, joined with `followed(by:)`, are the
    /// entry of the whole: what's before never has to be read again.
    nonisolated private static let userWord = Data("user".utf8)

    nonisolated static func turnStart(in data: Data, agent: String) -> Int? {
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[start..<end]
            // Every agent's prompt line names the user; most lines don't, and
            // parsing each one is what this costs.
            if line.count > 2, line.count < 4_000_000, line.range(of: Self.userWord) != nil,
               let first = AgentTranscript.parse(Data(line), agent: agent).first,
               case .userText = first.kind {
                return start - data.startIndex
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return nil
    }

    /// Called with the sessions whose entries were just re-read.
    @ObservationIgnored var onUpdate: (([UUID]) -> Void)?

    /// Claude's own title for the conversation, the latest one it logged:
    /// a `/rename` (custom-title) wins over the generated ai-title.
    /// The title of `earlier` then `later` parts of one file, as `agentTitle`
    /// picks it in one: the last rename, else the last generated title. A part
    /// was read on its own, so a generated title in the later one mustn't hide
    /// a rename in the earlier.
    nonisolated static func mergedTitle(_ earlier: Entry, _ later: Entry) -> (String?, Bool?) {
        if later.agentTitleIsCustom == true { return (later.agentTitle, true) }
        if earlier.agentTitleIsCustom == true { return (earlier.agentTitle, true) }
        if let t = later.agentTitle { return (t, later.agentTitleIsCustom) }
        return (earlier.agentTitle, earlier.agentTitleIsCustom)
    }

    nonisolated static func agentTitle(in data: Data) -> String? { agentTitleRecord(in: data)?.title }

    /// The title and whether it's a rename (`custom-title`) or generated.
    nonisolated static func agentTitleRecord(in data: Data) -> (title: String, custom: Bool)? {
        // In the bytes: the title is one line, and a string of the whole file
        // to find it cost more than parsing the transcript did.
        func last(_ type: String, _ key: String) -> String? {
            guard let r = data.range(of: Data("\"type\":\"\(type)\"".utf8), options: .backwards) else { return nil }
            let start = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            guard let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                  let t = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return String(t.prefix(60))
        }
        if let t = last("custom-title", "customTitle") { return (t, true) }
        return last("ai-title", "aiTitle").map { ($0, false) }
    }

    /// A user message that is the user's own words — not a notice typed in
    /// by the host, a relayed delegation, or a tool/system tag.
    nonisolated static func isOwnWords(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && !s.hasPrefix("<") && !s.hasPrefix("[")
            && !DelegationNotice.isHostAside(s) && DelegationNotice.strip(s) == nil
    }

    nonisolated static func entry(_ data: Data, modified: Date, agent: String? = nil) -> Entry {
        let (items, cleared) = AgentTranscript.parseNotingClear(data, agent: agent)
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
        let title = agentTitleRecord(in: data)
        var e = Entry(text: parts.joined(separator: "\n\n"),
                     lastReply: String(oneLine.prefix(160)),
                     tokens: tokens(in: data), model: codexModel(data) ?? model(in: data),
                     turns: turns, timeline: SessionTimeline.build(items),
                     agentTitle: title?.title, agentTitleIsCustom: title?.custom,
                     firstPrompt: firstPrompt, modified: modified,
                     conversationID: conversationID(in: data))
        e.startsOver = cleared
        return e
    }

    /// Codex's conversation id, from the copy's `session_meta` record (the
    /// rollout's first line; a copy keeps it when it holds the whole file).
    nonisolated static func conversationID(in data: Data) -> String? {
        let head = data.prefix(262_144)
        for line in head.split(separator: 0x0A, maxSplits: 64) {
            guard line.count < 200_000,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let p = obj["payload"] as? [String: Any],
                  let id = (p["id"] as? String) ?? (p["session_id"] as? String),
                  UUID(uuidString: id) != nil else { continue }
            return id.lowercased()
        }
        return nil
    }

    /// The entry for `s`, unless its copy holds a conversation that isn't
    /// the session's own (`agentTranscriptID`).
    private func ownEntry(_ s: AgentSession) -> Entry? {
        guard let e = entries[s.id], Self.holdsOwnConversation(e, of: s) else { return nil }
        return e
    }

    /// Whether `e` (the session's copy) holds the session's own conversation
    /// — or can't tell (no id on either side).
    nonisolated static func holdsOwnConversation(_ e: Entry, of s: AgentSession) -> Bool {
        guard let own = s.agentTranscriptID?.lowercased(), UUID(uuidString: own) != nil,
              let held = e.conversationID else { return true }
        return held == own
    }

    /// The session's token use, read only from its own conversation.
    func tokens(for s: AgentSession) -> TokenUsage? {
        ownEntry(s).map(\.tokens).flatMap { $0.total > 0 ? $0 : nil }
    }

    /// The last model the agent logged: Claude's per-message `"model"`,
    /// Codex's turn context, Kimi's `modelAlias`. Placeholders an agent
    /// logs in the model slot (Claude's `<synthetic>`, Kimi's internal
    /// "agent-loop") are skipped.
    nonisolated static func model(in data: Data) -> String? {
        if let m = model(inText: String(decoding: data.suffix(2_000_000), as: UTF8.self)) { return m }
        // A long journal whose model is only named at its start (Kimi's
        // `profile.bind`): its head.
        guard data.count > 2_000_000 else { return nil }
        return model(inText: String(decoding: data.prefix(512_000), as: UTF8.self))
    }

    nonisolated private static func model(inText raw: String) -> String? {
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
            // Grok: its turn's usage, keyed by model ("modelUsage":{"grok-4.7-build":…}).
            ?? last(#""modelUsage"\s*:\s*\{\s*"([^"<]{2,80})"\s*:"#)
            ?? last(#""modelAlias"\s*:\s*"([^"<]{2,80})""#)
            ?? last(#""model"\s*:\s*"([^"<]{2,80})""#)
    }

    /// Codex: the model of its latest `turn_context` (a mid-session
    /// `/model` starts a new one) — never a "model" key in a tool's input.
    nonisolated static func codexModel(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(65_536), as: UTF8.self)
        guard ["\"type\":\"session_meta\"", "\"type\":\"turn_context\"", "\"type\":\"response_item\""]
            .contains(where: head.contains) else { return nil }
        return CodexTranscriptParser.latestModel(data.suffix(4_000_000))
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
        // "grok-4.7-build" → "Grok 4.7 Build".
        if m.lowercased().hasPrefix("grok-") {
            return m.split(separator: "-").map { w in
                let s = String(w)
                return s.first?.isLetter == true ? s.prefix(1).uppercased() + s.dropFirst() : s
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

    /// The model a live chat read off its own copy of the transcript, by
    /// session: the header's source while the app's copy has no entry for
    /// it (a restored Kimi session showed no model — nothing in the copy
    /// named one yet, while the chat on screen did).
    private(set) var liveModels: [UUID: String] = [:]

    func noteLiveModel(_ id: UUID, _ raw: String) {
        if liveModels[id] != raw { liveModels[id] = raw }
    }

    /// The model `data` (a chat's buffer) last names, as the index reads it.
    nonisolated static func liveModel(in data: Data) -> String? {
        codexModel(data) ?? model(in: data)
    }

    /// The session's model; before its transcript names one (a session
    /// still starting), the one its agent last used on the same machine —
    /// so the header doesn't gain the model only once the agent is ready.
    func model(for s: AgentSession, among sessions: [AgentSession]) -> String? {
        if let m = ownEntry(s)?.model.map(Self.prettyModel) { return m }
        if let live = liveModels[s.id] { return Self.prettyModel(live) }
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
    ///   - Grok: the last `turn_completed` usage (`inputTokens`, which
    ///     include `cachedReadTokens`). It sums the turn's model calls, so
    ///     it's divided by `modelCalls`: an estimate of one call's prompt.
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
            if line.contains("\"turn_completed\""), line.contains("\"cachedReadTokens\""),
               let u = object(after: "\"usage\"", in: line), u.contains("\"inputTokens\"") {
                // Only the usage's own fields, not its per-model breakdown.
                let own = u.range(of: "\"modelUsage\"").map { u[..<$0.lowerBound] } ?? u
                let calls = max(1, int("modelCalls", in: own))
                let input = int("inputTokens", in: own), cached = int("cachedReadTokens", in: own)
                return TokenUsage(input: max(0, input - cached) / calls, cached: cached / calls,
                                  output: int("outputTokens", in: own) / calls)
            }
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
