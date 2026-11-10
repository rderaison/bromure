import Foundation

/// Host-side archive of finished tasks' session transcripts, one file per
/// task at ~/Library/Application Support/BromureAC/task-transcripts/<taskID>.jsonl.
///
/// Written when a card reaches Done (merge verified, PR opened, closed
/// without merge) — strictly BEFORE the worktree cleanup that follows — so
/// the record of what the agent did survives the branch, the workspace's
/// home image, and the VM itself. Reads go archive-first
/// (`fetchTaskTranscriptRaw`), with the guest/ext4 lookups as the fallback
/// for cards that predate archiving.
enum TaskTranscriptArchive {
    /// Where a finished task's transcript is read from.
    enum Source: Equatable { case archive, session, guest }

    /// The lookup order. On demand: the archive, then the task session's
    /// host copy (it outlives the worktree), then the guest/ext4 file. For
    /// the archive itself: the full file first -- the session copy may be a
    /// tail-seeded cache missing the conversation's start, and an archive is
    /// read first forever after -- and the session copy only as a fallback.
    static func readOrder(forArchive: Bool) -> [Source] {
        forArchive ? [.guest, .session] : [.archive, .session, .guest]
    }

    /// The full read's cap (`head -c 25000000`, the ext4 read's limit).
    static let fullReadCap = 25_000_000

    /// A full read this long may have stopped at the cap, short of the
    /// file's end (UTF-8 repair can drop a few bytes, hence the margin).
    static func mayBeCapped(_ text: String) -> Bool {
        text.utf8.count >= fullReadCap - 65_536
    }

    /// A capped archive read goes on: the file re-read whole, in exact
    /// chunks, up to this much (Finding "Capped transcript head is archived
    /// when the session tail does not overlap").
    static let wholeReadCeiling = 128_000_000
    static let wholeReadChunk = 16_000_000

    /// Shell that prints `bytes` bytes of `$f` from `offset`, base64 (exact:
    /// a chunk cut inside a character survives, where the full read's UTF-8
    /// repair would drop it).
    static func chunkEmit(offset: Int, bytes: Int) -> String {
        "if [ -n \"$f\" ]; then tail -c +\(max(0, offset) + 1) \"$f\" | head -c \(max(0, bytes)) | base64 | tr -d '\\n'; fi"
    }

    /// A whole re-read is of the file the capped read came from: the same
    /// first 4 KB. (The capped read's UTF-8 repair could only make a file
    /// with a bad byte that early differ: then the re-read isn't used.)
    static func samePrefix(_ head: String, _ whole: Data) -> Bool {
        let n = min(4_096, head.utf8.count, whole.count)
        return n > 0 && Data(head.utf8.prefix(n)) == whole.prefix(n)
    }

    /// What the archive keeps of a full read (`whole`: it reached the file's
    /// end unless `complete` is false) and the session copy's tail: joined
    /// where they share records; when they share none and the read stopped
    /// short, both -- the head, then the tail (the end, with the final
    /// report) -- rather than the head alone.
    static func archiveJoin(whole: Data, complete: Bool, sessionTail: Data?) -> Data {
        guard let tail = sessionTail, !tail.isEmpty else { return whole }
        if let joined = SessionTranscriptCache.merge(history: whole, incoming: tail, mode: .overlapOnly) {
            return joined
        }
        if !complete, let both = SessionTranscriptCache.merge(history: whole, incoming: tail, mode: .continuation) {
            return both
        }
        return whole
    }

    /// Overridable for tests (a temp dir); nil = the real location.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("task-transcripts", isDirectory: true)
    }

    static func url(for taskID: UUID) -> URL {
        directory.appendingPathComponent("\(taskID.uuidString).jsonl")
    }

    static func has(_ taskID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: taskID).path)
    }

    /// Atomic write, backup-excluded (transcripts are large derived state).
    static func save(_ text: String, taskID: UUID) {
        guard !text.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        try? Data(text.utf8).write(to: url(for: taskID), options: .atomic)
    }

    static func load(_ taskID: UUID) -> String? {
        guard let data = try? Data(contentsOf: url(for: taskID)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Called when the card itself is deleted from the board.
    static func remove(_ taskID: UUID) {
        try? FileManager.default.removeItem(at: url(for: taskID))
    }
}
