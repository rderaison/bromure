import Foundation
import Testing
@testable import bromure_ac

/// Column logic for the automation kanban board, plus the run archive and
/// the transcript parser it leans on.
@Suite("Automation kanban board")
struct AutomationBoardTests {

    private func run(_ outcome: AutomationRunRecord.Outcome,
                     firedAt: Date = Date(),
                     slug: String? = "job-260718-0900",
                     completedAt: Date? = nil,
                     acknowledgedAt: Date? = nil) -> AutomationRunRecord {
        AutomationRunRecord(automationID: UUID(), firedAt: firedAt,
                            outcome: outcome, detail: "d", branchSlug: slug,
                            completedAt: completedAt,
                            acknowledgedAt: acknowledgedAt)
    }

    @Test("Launched runs with a live tab are In Progress; completed or tab-less ones are Done")
    func liveSplit() {
        let live = run(.launched)
        let ended = run(.launched)                        // live tab gone
        let completed = run(.launched, completedAt: Date())
        let cols = AutomationBoard.classify(runs: [live, ended, completed]) {
            $0.id == live.id
        }
        #expect(cols.inProgress.map(\.id) == [live.id])
        #expect(Set(cols.done.map(\.id)) == [ended.id, completed.id])
        #expect(cols.needsAttention.isEmpty)
    }

    @Test("Failed and blocked runs need attention until acknowledged")
    func attention() {
        let failed = run(.failed)
        let blocked = run(.blocked)
        let dismissed = run(.failed, acknowledgedAt: Date())
        let cols = AutomationBoard.classify(runs: [failed, blocked, dismissed]) { _ in false }
        #expect(Set(cols.needsAttention.map(\.id)) == [failed.id, blocked.id])
        #expect(cols.done.map(\.id) == [dismissed.id])
    }

    @Test("Skipped runs land in Done")
    func skipped() {
        let cols = AutomationBoard.classify(runs: [run(.skipped)]) { _ in true }
        #expect(cols.inProgress.isEmpty)
        #expect(cols.done.count == 1)
    }

    @Test("Done sorts by completion (falling back to fire time), newest first")
    func doneOrder() {
        let old = run(.launched, firedAt: Date(timeIntervalSinceNow: -3600))
        let recent = run(.launched, firedAt: Date(timeIntervalSinceNow: -7200),
                         completedAt: Date())
        let cols = AutomationBoard.classify(runs: [old, recent]) { _ in false }
        #expect(cols.done.map(\.id) == [recent.id, old.id])
    }

    @Test("Branch matching accepts the exact slug and the guest's -N dedup suffix")
    func branchMatch() {
        let slug = "nightly-260718-0300"
        #expect(AutomationBoard.branchMatches("wt/\(slug)", slug: slug))
        #expect(AutomationBoard.branchMatches("wt/\(slug)-2", slug: slug))
        #expect(!AutomationBoard.branchMatches("wt/\(slug)-fix", slug: slug))
        #expect(!AutomationBoard.branchMatches("wt/other", slug: slug))
        #expect(!AutomationBoard.branchMatches(slug, slug: slug))   // no wt/ prefix
        #expect(!AutomationBoard.branchMatches(nil, slug: slug))
    }

    @Test("Run records without the new fields still decode (pre-kanban files)")
    func decodeCompat() throws {
        let json = """
        {"id":"\(UUID().uuidString)","automationID":"\(UUID().uuidString)",
         "firedAt":"2026-07-01T09:00:00Z","outcome":"launched","detail":"old"}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let run = try d.decode(AutomationRunRecord.self, from: Data(json.utf8))
        #expect(run.completedAt == nil)
        #expect(run.acknowledgedAt == nil)
    }
}

// Serialized: the tests repoint the archive's global directory override.
@Suite("Automation run archive", .serialized)
struct AutomationRunArchiveTests {
    /// Point the archive at a scratch dir for the duration of one test.
    private func withScratch<T>(_ body: () throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-run-archive-\(UUID().uuidString)")
        AutomationRunArchive.directoryOverride = dir
        defer {
            AutomationRunArchive.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        return try body()
    }

    @Test("Archive round-trips records, newest first")
    func roundTrip() throws {
        try withScratch {
            let a = AutomationRunRecord(automationID: UUID(),
                                        firedAt: Date(timeIntervalSinceNow: -60),
                                        outcome: .launched, detail: "older")
            let b = AutomationRunRecord(automationID: UUID(), firedAt: Date(),
                                        outcome: .skipped, detail: "newer")
            AutomationRunArchive.archive(a)
            AutomationRunArchive.archive(b)
            let loaded = AutomationRunArchive.loadArchivedRuns()
            #expect(loaded.map(\.detail) == ["newer", "older"])
            #expect(loaded.first?.outcome == .skipped)
        }
    }

    @Test("Transcripts save and resolve per run")
    func transcript() throws {
        try withScratch {
            let id = UUID()
            #expect(!AutomationRunArchive.hasTranscript(id))
            try AutomationRunArchive.saveTranscript(Data("{}\n".utf8), runID: id)
            #expect(AutomationRunArchive.hasTranscript(id))
            let read = try Data(contentsOf: AutomationRunArchive.transcriptURL(for: id))
            #expect(String(data: read, encoding: .utf8) == "{}\n")
        }
    }

    @Test("Deleting an automation removes its archived runs and stray transcript dirs")
    func removal() throws {
        try withScratch {
            let automationID = UUID()
            let archivedRun = AutomationRunRecord(
                automationID: automationID, firedAt: Date(),
                outcome: .launched, detail: "archived")
            AutomationRunArchive.archive(archivedRun)
            let inStoreRunID = UUID()   // never archived, but holds a transcript
            try AutomationRunArchive.saveTranscript(Data("x".utf8), runID: inStoreRunID)
            let other = AutomationRunRecord(automationID: UUID(), firedAt: Date(),
                                            outcome: .launched, detail: "other")
            AutomationRunArchive.archive(other)

            AutomationRunArchive.removeRuns(automationID: automationID,
                                            alsoIDs: [inStoreRunID])
            #expect(AutomationRunArchive.loadArchivedRuns().map(\.detail) == ["other"])
            #expect(!AutomationRunArchive.hasTranscript(inStoreRunID))
        }
    }
}

@Suite("Claude transcript parser")
struct ClaudeTranscriptParserTests {

    @Test("Text, thinking, tool use, and tool results parse into items")
    func basics() {
        let jsonl = """
        {"type":"user","timestamp":"2026-07-18T09:00:00Z","message":{"role":"user","content":"Fix the bug"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file.txt"}]}]}}
        {"type":"summary","summary":"ignored"}
        not json at all
        """
        let items = ClaudeTranscriptParser.parse(Data(jsonl.utf8))
        #expect(items.count == 5)
        guard items.count == 5 else { return }
        if case .userText(let t) = items[0].kind { #expect(t == "Fix the bug") }
        else { Issue.record("expected userText") }
        if case .thinking(let t) = items[1].kind { #expect(t == "hmm") }
        else { Issue.record("expected thinking") }
        if case .assistantText(let t) = items[2].kind { #expect(t == "On it.") }
        else { Issue.record("expected assistantText") }
        if case .toolUse(let name, let summary, _) = items[3].kind {
            #expect(name == "Bash")
            #expect(summary == "ls -la")
        } else { Issue.record("expected toolUse") }
        if case .toolResult(let tool, let content, let isError) = items[4].kind {
            #expect(tool == "Bash")
            #expect(content == "file.txt")
            #expect(!isError)
        } else { Issue.record("expected toolResult") }
    }

    @Test("Meta lines and empty blocks are skipped")
    func metaSkipped() {
        let jsonl = """
        {"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"   "}]}}
        """
        #expect(ClaudeTranscriptParser.parse(Data(jsonl.utf8)).isEmpty)
    }
}
