import Foundation
import Testing
@testable import bromure_ac

/// The index saves what each session said (your messages, the agent's
/// replies) to `transcript-index/<session>.json` for the next launch. A
/// removed session's copy was deleted only by the first pass after a launch:
/// with the app left open, the conversation stayed readable on disk (CWE-459).
@Suite("A removed session's conversation leaves the index's files too")
@MainActor
struct TranscriptIndexForgetTests {
    private func user(_ t: String) -> String { #"{"type":"user","timestamp":"2026-11-05T10:00:00.000Z","message":{"role":"user","content":"\#(t)"}}"# }
    private func reply(_ t: String) -> String {
        #"{"type":"assistant","timestamp":"2026-11-05T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(t)"}]}}"#
    }
    private func write(_ id: UUID, _ said: String, in dir: URL) throws {
        let lines = (0..<210).map { _ in #"{"type":"mode","mode":"default"}"# } + [user(said), reply("ok")]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("\(id.uuidString).jsonl"), options: .atomic)
    }
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tif-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("transcripts"), store = root.appendingPathComponent("transcript-index")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir, store)
    }
    private func until(_ cond: () -> Bool) async throws {
        for _ in 0..<250 where !cond() { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func pass(_ index: TranscriptSearchIndex, then cond: () -> Bool) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        index.refresh()
        try await until(cond)
    }

    @Test("a transcript gone while the app runs: the next pass deletes its saved record")
    func laterPass() async throws {
        let (root, dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID()
        try write(a, "the secret plan", in: dir)
        try write(b, "keep me", in: dir)
        let index = TranscriptSearchIndex(dir: dir, storeDir: store)
        index.refresh()
        try await until { index.entries.count == 2 }
        let recA = TranscriptSearchIndex.recordURL(a, in: store)
        #expect(exists(recA) && index.entries[a]?.text.contains("the secret plan") == true)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(a.uuidString).jsonl"))
        try await pass(index) { index.entries[a] == nil && !exists(recA) }
        #expect(index.entries[a] == nil)
        #expect(!exists(recA), "the removed conversation is still on disk")
        #expect(exists(TranscriptSearchIndex.recordURL(b, in: store)) && index.entries[b] != nil)
    }

    @Test("removing a session forgets it at once, and a pass doesn't put it back")
    func forgetNow() async throws {
        let (root, dir, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID()
        try write(a, "the secret plan", in: dir)
        let index = TranscriptSearchIndex(dir: dir, storeDir: store)
        index.refresh()
        try await until { index.entries[a] != nil }
        let recA = TranscriptSearchIndex.recordURL(a, in: store)
        index.forget(a)
        #expect(index.entries[a] == nil)
        try await until { !exists(recA) }
        #expect(!exists(recA))
        // Its transcript isn't deleted yet (that's queued), and it changed:
        // a pass reads it again, and must not bring it back.
        try write(a, "the secret plan, again", in: dir)
        try await pass(index) { exists(recA) }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(index.entries[a] == nil)
        #expect(!exists(recA))
    }

    @Test("the session store's removal reaches the index")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AgentSessionEngine.swift"), encoding: .utf8)
        #expect(engine.contains("TranscriptSearchIndex.shared.forget(id)"))
        let index = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/TranscriptSearchIndex.swift"), encoding: .utf8)
        #expect(!index.contains("if firstPass {\n                // Records of transcripts that are gone."))
    }
}
