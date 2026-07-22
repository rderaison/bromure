import Foundation
import Testing
@testable import bromure_ac

// The host-side archive finished tasks' transcripts land in — written at
// Done, read archive-first, removed with the card.

@Suite("Task transcript archive")
struct TaskTranscriptArchiveTests {

    private func withTempArchive(_ body: () throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-archive-\(UUID().uuidString)")
        TaskTranscriptArchive.directoryOverride = dir
        defer {
            TaskTranscriptArchive.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body()
    }

    @Test("save / load / remove roundtrip")
    func roundtrip() throws {
        try withTempArchive {
            let id = UUID()
            #expect(!TaskTranscriptArchive.has(id))
            #expect(TaskTranscriptArchive.load(id) == nil)

            let transcript = "{\"type\":\"user\",\"message\":\"do the thing\"}\n"
                + "{\"type\":\"assistant\",\"message\":\"done ✓\"}\n"
            TaskTranscriptArchive.save(transcript, taskID: id)
            #expect(TaskTranscriptArchive.has(id))
            #expect(TaskTranscriptArchive.load(id) == transcript)

            TaskTranscriptArchive.remove(id)
            #expect(!TaskTranscriptArchive.has(id))
            #expect(TaskTranscriptArchive.load(id) == nil)
        }
    }

    @Test("an empty transcript is never written")
    func emptyIgnored() throws {
        try withTempArchive {
            let id = UUID()
            TaskTranscriptArchive.save("", taskID: id)
            #expect(!TaskTranscriptArchive.has(id))
        }
    }

    @Test("removing a card drops its archived transcript with it")
    func storeRemoveCleansArchive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-archive-\(UUID().uuidString)")
        TaskTranscriptArchive.directoryOverride = dir
        defer {
            TaskTranscriptArchive.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = await CodingTaskStore(fileURL: storeURL)
        let task = CodingTask(profileID: UUID())
        await store.upsert(task)
        TaskTranscriptArchive.save("transcript body", taskID: task.id)
        await store.remove(task.id)
        #expect(!TaskTranscriptArchive.has(task.id))
    }
}
