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

/// Finding "Capped transcript head is archived when the session tail does
/// not overlap": over ~33 MB the capped read (first 25 MB) and the session
/// copy (tail-seeded) shared no record, and the head alone was archived.
@Suite("Task transcript archive: past the cap")
struct TaskTranscriptArchivePastCapTests {
    func rec(_ n: Int) -> String {
        #"{"type":"user","uuid":"u\#(n)","parentUuid":"#
            + (n == 1 ? "null" : #""u\#(n - 1)""#)
            + #","timestamp":"2026-11-10T10:00:\#(String(format: "%02d", n % 60)).000Z","message":{"role":"user","content":"m\#(n)"}}"#
            + "\n"
    }
    func recs(_ r: ClosedRange<Int>) -> Data { Data(r.map(rec).joined().utf8) }

    @Test("No shared record and a read short of the end: the head and the tail both, not the head alone")
    func headAndTail() {
        let head = recs(1...5), tail = recs(50...55)
        let kept = String(decoding: TaskTranscriptArchive.archiveJoin(whole: head, complete: false, sessionTail: tail),
                          as: UTF8.self)
        #expect(kept.contains(#""content":"m1""#))
        #expect(kept.contains(#""content":"m55""#))   // the end, where the final report is
        #expect(kept.range(of: #""content":"m1""#)!.lowerBound < kept.range(of: #""content":"m50""#)!.lowerBound)
    }

    @Test("A whole read stands; a shared record joins the newer tail")
    func wholeAndOverlap() {
        let whole = recs(1...20)
        // Complete and nothing shared (another conversation's tail): the file as read.
        #expect(TaskTranscriptArchive.archiveJoin(whole: whole, complete: true, sessionTail: recs(50...55)) == whole)
        // Shared records: the tail's newer ones join after.
        let joined = String(decoding: TaskTranscriptArchive.archiveJoin(whole: whole, complete: true, sessionTail: recs(18...25)),
                            as: UTF8.self)
        #expect(joined.contains(#""content":"m25""#) && joined.contains(#""content":"m1""#))
        #expect(TaskTranscriptArchive.archiveJoin(whole: whole, complete: false, sessionTail: nil) == whole)
    }

    @Test("The re-read is checked against the capped read, in exact chunks")
    func reread() throws {
        let head = String(decoding: recs(1...3), as: UTF8.self)
        #expect(TaskTranscriptArchive.samePrefix(head, recs(1...9)))
        #expect(!TaskTranscriptArchive.samePrefix(head, recs(4...9)))
        #expect(!TaskTranscriptArchive.samePrefix(head, Data()))
        #expect(TaskTranscriptArchive.chunkEmit(offset: 16, bytes: 8)
                == #"if [ -n "$f" ]; then tail -c +17 "$f" | head -c 8 | base64 | tr -d '\n'; fi"#)
        // Run: chunks cut inside a character join back to the exact file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ttapc-\(UUID().uuidString).jsonl")
        let bytes = Data("héllo wörld — ✓ done\n".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var got = Data()
        while true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "f='\(file.path)'; " + TaskTranscriptArchive.chunkEmit(offset: got.count, bytes: 5)]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let d = try #require(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            got.append(d)
            if d.count < 5 { break }
        }
        #expect(got == bytes)
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("let whole = await wholeGuestTranscript(task, head: text)"))
        #expect(ac.contains("TaskTranscriptArchive.archiveJoin("))
    }
}
