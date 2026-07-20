import Foundation

/// Host-side per-run storage for scheduled automations, one directory per
/// run at ~/Library/Application Support/BromureAC/runs/<runID>/:
///
///   record.json       — the AutomationRunRecord, written when the run is
///                       evicted from the store's in-memory window (the
///                       store keeps the most recent 1000 in
///                       automations.json; nothing is ever dropped)
///   transcript.jsonl  — the Claude Code transcript, pulled from the guest
///                       when the run finishes — BEFORE automation-finish
///                       can remove an empty worktree, and independent of
///                       the VM or clone surviving
///
/// The kanban board's Done column reads the store's recent runs first and
/// loads this archive on demand; the run-detail window resolves transcripts
/// through `transcriptURL(for:)` regardless of where the record lives.
enum AutomationRunArchive {
    /// Overridable for tests (a temp dir); nil = the real location.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var runsDirectory: URL {
        if let directoryOverride { return directoryOverride }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    static func runDirectory(for runID: UUID) -> URL {
        runsDirectory.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func transcriptURL(for runID: UUID) -> URL {
        runDirectory(for: runID).appendingPathComponent("transcript.jsonl")
    }

    static func hasTranscript(_ runID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: runID).path)
    }

    private static func recordURL(for runID: UUID) -> URL {
        runDirectory(for: runID).appendingPathComponent("record.json")
    }

    // Same on-disk date convention as ScheduledAutomationStore.
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Ensure the run's directory exists (backup-excluded like the store's
    /// JSON — run history is derived state, and transcripts can be large).
    @discardableResult
    private static func ensureRunDirectory(_ runID: UUID) -> URL {
        let dir = runDirectory(for: runID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = runsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }

    /// Persist a record that's leaving the store's in-memory window.
    static func archive(_ run: AutomationRunRecord) {
        ensureRunDirectory(run.id)
        guard let data = try? encoder().encode(run) else { return }
        try? data.write(to: recordURL(for: run.id), options: .atomic)
    }

    /// Write a transcript pulled from the guest.
    static func saveTranscript(_ data: Data, runID: UUID) throws {
        ensureRunDirectory(runID)
        try data.write(to: transcriptURL(for: runID), options: .atomic)
    }

    /// Every archived record, newest first. Disk-touching — call it on
    /// demand (the Done column's "Load older runs"), not per redraw.
    static func loadArchivedRuns() -> [AutomationRunRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: nil) else { return [] }
        let dec = decoder()
        var out: [AutomationRunRecord] = []
        for dir in entries {
            let url = dir.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: url),
                  let run = try? dec.decode(AutomationRunRecord.self, from: data)
            else { continue }
            out.append(run)
        }
        return out.sorted { $0.firedAt > $1.firedAt }
    }

    /// Delete every run directory belonging to `automationID` — called when
    /// the automation itself is deleted. `alsoIDs` covers the runs still in
    /// the store's window (their directories may hold transcripts even
    /// though record.json was never written).
    static func removeRuns(automationID: UUID, alsoIDs: [UUID]) {
        let fm = FileManager.default
        for id in alsoIDs {
            try? fm.removeItem(at: runDirectory(for: id))
        }
        let dec = decoder()
        guard let entries = try? fm.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: nil) else { return }
        for dir in entries {
            let url = dir.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: url),
                  let run = try? dec.decode(AutomationRunRecord.self, from: data),
                  run.automationID == automationID
            else { continue }
            try? fm.removeItem(at: dir)
        }
    }
}
