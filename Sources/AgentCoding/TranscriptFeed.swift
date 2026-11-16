import Foundation

// MARK: - A transcript read incrementally

/// One transcript file read the way the desktop's chat reads it
/// (`CodingTaskEngine.transcriptChunkCommand`): a first window from the
/// end, then only the bytes appended since, and earlier history on
/// demand. The old reader re-tailed the last 300 KB every poll -- which
/// tool output fills, so a phone showed only the last few messages and
/// had no way to reach the rest.
///
/// What's held is bounded, as the desktop's buffer is (`trimHead`): past
/// `budget` the head is dropped (it stays loadable from the file), so a
/// long-running session neither grows a phone's memory without end nor
/// makes every poll's parse longer. "Load earlier" raises the budget so
/// what the user asked for isn't trimmed straight away, but never past
/// `maxBudget`.
@MainActor
final class TranscriptFeed {
    static let windowBytes = 1_000_000

    /// One read's window, the held bytes before the head is trimmed, and
    /// the most "load earlier" may raise that to.
    let windowBytes: Int
    let maxBudget: Int
    private let baseBudget: Int
    private(set) var budget: Int
    /// While "load earlier" holds the budget up: the file offset where the
    /// history it brought in ends. Once the head trim passes it, that
    /// history has aged out and the budget comes back down.
    private var raisedUntil: Int?

    private var path: String?
    private var data = Data()
    private var base = 0
    private var end = 0
    private var pq = Data()
    private var generation = 0
    private(set) var items: [TranscriptItem] = []
    /// The bytes held now (tests, diagnostics).
    var heldBytes: Int { data.count }
    var canLoadEarlier: Bool { path != nil && base > 0 && data.count + windowBytes <= maxBudget }

    init(windowBytes: Int = TranscriptFeed.windowBytes) {
        self.windowBytes = windowBytes
        baseBudget = windowBytes * 3
        budget = baseBudget
        maxBudget = windowBytes * 8
    }

    /// Builds the guest command: known path, offset, window bytes, earlier.
    typealias Command = (String?, Int, Int, Bool) -> String?
    typealias Exec = (String) async -> String?

    private struct Fetch { let path: String; let pq: Data; let start: Int; let end: Int; let chunk: Data }

    /// Header = 5 lines (path, pending question, size, start, end), then
    /// the bytes. nil for empty output (no transcript file).
    private static func parse(_ raw: String) -> Fetch? {
        let d = Data(raw.utf8)
        var cuts: [Int] = []
        var i = d.startIndex
        while cuts.count < 5, i < d.endIndex, let nl = d[i...].firstIndex(of: 0x0A) {
            cuts.append(nl)
            i = nl + 1
        }
        guard cuts.count == 5 else { return nil }
        func field(_ k: Int) -> Data { Data(d[(k == 0 ? d.startIndex : cuts[k - 1] + 1)..<cuts[k]]) }
        func int(_ k: Int) -> Int? { Int(String(decoding: field(k), as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
        let path = String(decoding: field(0), as: UTF8.self)
        guard !path.isEmpty, let start = int(3), let end = int(4) else { return nil }
        return Fetch(path: path, pq: field(1), start: start, end: end, chunk: Data(d[(cuts[4] + 1)...]))
    }

    /// The new bytes since the last read. nil when the read failed (keep
    /// what's on show); otherwise the conversation.
    func refresh(agent: String?, command: Command, exec: Exec) async -> [TranscriptItem]? {
        let knownPath = path, knownEnd = end
        guard let cmd = command(knownPath, knownEnd, windowBytes, false), let raw = await exec(cmd) else { return nil }
        // Another read (a send's refresh beside the poll) landed meanwhile:
        // this one's bytes are already held, or would be appended twice.
        guard path == knownPath, end == knownEnd else { return items }
        var changed = false
        if let f = Self.parse(raw) {
            if f.pq != pq { pq = f.pq; changed = true }
            if path == f.path, f.start == end {
                if !f.chunk.isEmpty {
                    data.append(f.chunk); end = f.end; changed = true
                    if data.count > budget { trimHead() }
                }
            } else {
                // First read, another file, or too far behind: start over.
                path = f.path; data = f.chunk; base = f.start; end = f.end
                budget = baseBudget; raisedUntil = nil
                changed = true
            }
        } else if path != nil || !items.isEmpty {
            path = nil; data = Data(); pq = Data(); base = 0; end = 0
            budget = baseBudget; raisedUntil = nil
            changed = true
        }
        if changed { await reparse(agent: agent) }
        return items
    }

    /// The conversation before what's held, put in front. False when
    /// nothing came (or the history moved meanwhile).
    @discardableResult
    func loadEarlier(agent: String?, command: Command, exec: Exec) async -> Bool {
        guard canLoadEarlier, let held = path, let cmd = command(held, base, windowBytes, true),
              let raw = await exec(cmd), let f = Self.parse(raw),
              f.path == path, f.end == base, !f.chunk.isEmpty
        else { return false }
        var joined = f.chunk
        joined.append(data)
        data = joined
        // The first load of a raise marks the newest history it holds up.
        raisedUntil = max(raisedUntil ?? 0, base)
        base = f.start
        // What was asked for survives a couple of windows of new output.
        // (One line longer than a window may take it past `maxBudget`; the
        // next append trims it.)
        budget = min(maxBudget, max(budget, data.count + windowBytes * 2))
        await reparse(agent: agent)
        return true
    }

    /// Drop the head down to the budget's worth less a window (so a trim
    /// happens once per window of growth, not on every poll), from the
    /// start of the line the cut lands in -- never forward: one giant last
    /// line would then be the whole history. Copies, so the dropped bytes
    /// are freed. A raised budget is trimmed to, not past: what "load
    /// earlier" brought in goes oldest first, a window at a time, and the
    /// budget is back to its base only once all of it has (Finding
    /// "Transcript trim discards loaded earlier history when the raised
    /// budget is reached").
    private func trimHead() {
        let keep = max(windowBytes, budget - windowBytes)
        guard data.count > keep else { return }
        let cut = data.startIndex + (data.count - keep)
        guard let nl = data[..<cut].lastIndex(of: 0x0A) else { return }
        let keepFrom = data.index(after: nl)
        guard keepFrom > data.startIndex else { return }
        base += keepFrom - data.startIndex
        data = Data(data[keepFrom...])
        if let r = raisedUntil, base >= r { budget = baseBudget; raisedUntil = nil }
    }

    private func reparse(agent: String?) async {
        generation &+= 1
        let gen = generation
        var input = data
        if !pq.isEmpty { input.append(0x0A); input.append(pq); input.append(0x0A) }
        let parsed = await Task.detached(priority: .userInitiated) {
            AgentTranscript.parse(input, agent: agent)
        }.value
        // A later read parsed newer history meanwhile: it wins.
        guard gen == generation else { return }
        TranscriptMarkdownCache.prewarm(parsed)
        items = parsed
    }
}
