import Foundation
import Testing
@testable import bromure_ac

/// The Done archive is read first forever after, so it must come from the
/// guest's full transcript, not the session's tail-seeded cache. Finding:
/// "Finished tasks can permanently archive a truncated session transcript".
@Suite("Task transcript archive: read order")
struct TaskTranscriptArchiveOrderTests {
    @Test("The archive reads the full file first; the session copy is only its fallback")
    func archiveOrder() {
        #expect(TaskTranscriptArchive.readOrder(forArchive: true) == [.guest, .session])
    }

    @Test("On demand: the archive, then the session copy, then the guest")
    func onDemandOrder() {
        #expect(TaskTranscriptArchive.readOrder(forArchive: false) == [.archive, .session, .guest])
    }

    @Test("Reaching Done archives with the full-read order")
    func doneUsesArchiveOrder() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tasks = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/CodingTasks.swift"), encoding: .utf8)
        let fn = try #require(tasks.range(of: "func archiveTranscriptThenCleanup("))
        let body = tasks[fn.upperBound...].prefix(1500)
        #expect(body.contains("delegate.fetchTaskTranscriptRaw(task, forArchive: true)"))
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("for source in TaskTranscriptArchive.readOrder(forArchive: forArchive) {"))
    }
}

@Suite("Task transcript archive: a capped full read")
struct TaskTranscriptArchiveCapTests {
    @Test("A read at the cap may be short of the end; a shorter one is whole")
    func capped() {
        #expect(TaskTranscriptArchive.mayBeCapped(String(repeating: "a", count: TaskTranscriptArchive.fullReadCap)))
        #expect(!TaskTranscriptArchive.mayBeCapped(String(repeating: "a", count: 1_000_000)))
    }

    @Test("The capped head and the session tail join into the whole conversation")
    func headAndTailJoin() throws {
        func line(_ n: Int) -> String {
            #"{"type":"user","message":{"role":"user","content":"m\#(n)"},"uuid":"u\#(n)","timestamp":"2026-09-19T20:00:\#(String(format: "%02d", n % 60)).000Z","sessionId":"s1"}"#
        }
        let head = (1...40).map(line).joined(separator: "\n") + "\n"
        let tail = (30...60).map(line).joined(separator: "\n") + "\n"
        let joined = try #require(SessionTranscriptCache.merge(history: Data(head.utf8), incoming: Data(tail.utf8), mode: .overlapOnly))
        let text = String(decoding: joined, as: UTF8.self)
        #expect(text.contains(#""uuid":"u1""#))
        #expect(text.contains(#""uuid":"u60""#))
        #expect(text.components(separatedBy: #""uuid":"u35""#).count == 2)   // once
    }
}

/// Finding "Archiving can save a newer conversation from the same
/// worktree": the full read took the worktree's newest transcript, so a
/// conversation started there before the Done archive ran was saved as
/// the task's, and read first forever after.
@Suite("Task transcript archive: the task's own conversation")
struct TaskTranscriptArchiveOwnConversationTests {
    let mine = "11111111-2222-4333-8444-555555555555"
    let theirs = "99999999-8888-4777-8666-555555555555"

    @Test("The pinned read takes the task's conversation by id, not the folder's newest")
    func pinnedReadTakesOwnFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ttao-\(UUID().uuidString)")
        let proj = home.appendingPathComponent(".claude/projects/-home-ubuntu-proj-wt-x")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let own = proj.appendingPathComponent("\(mine).jsonl"), other = proj.appendingPathComponent("\(theirs).jsonl")
        try Data("own\n".utf8).write(to: own)
        try Data("other\n".utf8).write(to: other)
        // The other conversation is the newer one.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: own.path)
        let cmd = "f=\"\"; " + AgentSessionLocator.pinnedFragment(tool: "claude", id: mine, into: "f") + "cat \"$f\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "own\n")
        // No file named by a non-id; every tool with ids has a pinned read.
        #expect(AgentSessionLocator.pinnedFragment(tool: "claude", id: "../x", into: "f").isEmpty)
        for t in ["claude", "codex", "grok", "omp"] {
            #expect(!AgentSessionLocator.pinnedFragment(tool: t, id: mine, into: "f").isEmpty)
        }
        #expect(!AgentSessionLocator.pinnedFragment(tool: "kimi", id: "session_" + mine, into: "f").isEmpty)
    }

    @Test("A newest-file fallback that is another session's conversation isn't the task's")
    func fallbackOwnership() {
        let line = #"{"type":"user","sessionId":"\#(theirs)","message":{"role":"user","content":"hi"}}"# + "\n"
        #expect(TaskTranscriptArchive.claudeConversationID(line) == theirs)
        #expect(!TaskTranscriptArchive.fallbackBelongs(line, tool: "claude", otherConversationIDs: [theirs]))
        #expect(TaskTranscriptArchive.fallbackBelongs(line, tool: "claude", otherConversationIDs: [mine]))
        #expect(TaskTranscriptArchive.fallbackBelongs("no id here\n", tool: "claude", otherConversationIDs: [theirs]))
        #expect(TaskTranscriptArchive.fallbackBelongs(line, tool: "codex", otherConversationIDs: [theirs]))
    }

    @Test("With its session's id the full read never falls back to the folder's newest")
    func ownIDFirst() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let fn = try #require(ac.range(of: "private func fullTaskTranscript("))
        let body = String(ac[fn.upperBound...].prefix(5000))
        let pinned = try #require(body.range(of: "AgentSessionLocator.pinnedFragment(tool: task.tool.rawValue, id: id, into: \"f\")"))
        let newest = try #require(body.range(of: "CodingTaskEngine.taskTranscriptCommand(branch: branch,"))
        #expect(pinned.lowerBound < newest.lowerBound)
        #expect(body.contains("Self.ext4Transcript(imagePath: img.path, conversationID: id)"))
        #expect(body.contains("return mine(out)"))
        #expect(body.contains("}.value.flatMap(mine)"))
        #expect(body.contains("if task.tool == .kimi, task.sessionID == nil {"))
    }
}
