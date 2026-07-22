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
