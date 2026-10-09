import Foundation
import Testing
@testable import bromure_ac

@Suite("Beautified transcript history")
struct TranscriptHistoryTests {

    private func claudeLine(_ role: String, _ text: String, at stamp: String) -> String {
        #"{"type":"\#(role)","timestamp":"\#(stamp)","message":{"role":"\#(role)","content":"\#(text)"}}"#
    }

    @Test("Item ids survive the lines in front of them going away")
    func stableIDsAcrossWindowSlide() {
        let lines = [
            claudeLine("user", "one", at: "2026-09-20T10:00:00.000Z"),
            claudeLine("assistant", "two", at: "2026-09-20T10:00:01.000Z"),
            claudeLine("user", "three", at: "2026-09-20T10:00:02.000Z"),
        ]
        let full = AgentTranscript.parse(Data(lines.joined(separator: "\n").utf8))
        let slid = AgentTranscript.parse(Data(lines.dropFirst().joined(separator: "\n").utf8))
        #expect(full.count == 3 && slid.count == 2)
        #expect(Array(full.dropFirst().map(\.id)) == slid.map(\.id))
        #expect(Set(full.map(\.id)).count == 3)
    }

    @Test("Equal items in one turn get distinct, order-stable ids")
    func stableIDsRankEquals() {
        let items = [
            TranscriptItem(id: 0, kind: .assistantText("a"), timestamp: Date(timeIntervalSince1970: 1)),
            TranscriptItem(id: 1, kind: .assistantText("b"), timestamp: Date(timeIntervalSince1970: 1)),
        ]
        let a = AgentTranscript.stableIDs(items)
        let b = AgentTranscript.stableIDs(items)
        #expect(a[0].id != a[1].id)
        #expect(a.map(\.id) == b.map(\.id))
        // A streaming turn keeps its id as its text grows.
        let grown = AgentTranscript.stableIDs([TranscriptItem(id: 0, kind: .assistantText("a more"),
                                                              timestamp: Date(timeIntervalSince1970: 1))])
        #expect(grown[0].id == a[0].id)
    }

    @Test("The chunk reply header parses and the bytes follow it")
    func fetchParse() {
        let body = "{\"a\":1}\n{\"b\":2}\n"
        let raw = "/home/u/.claude/projects/x/s.jsonl\n\n1234\n1000\n1016\n" + body
        let f = TranscriptFetch.parse(Data(raw.utf8))
        #expect(f?.path == "/home/u/.claude/projects/x/s.jsonl")
        #expect(f?.pq.isEmpty == true)
        #expect(f?.size == 1234 && f?.start == 1000 && f?.end == 1016)
        #expect(f.map { String(decoding: $0.chunk, as: UTF8.self) } == body)
        #expect(TranscriptFetch.parse(Data()) == nil)
        #expect(TranscriptFetch.parse(Data("only\ntwo\n".utf8)) == nil)
        let pq = TranscriptFetch.parse(Data("p\n{\"tool_name\":\"AskUserQuestion\"}\n1\n0\n1\n".utf8))
        #expect(pq.map { String(decoding: $0.pq, as: UTF8.self) } == "{\"tool_name\":\"AskUserQuestion\"}")
    }

    private func tempCache() -> (SessionTranscriptCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-tests-\(UUID().uuidString)", isDirectory: true)
        return (SessionTranscriptCache(directory: dir), dir)
    }

    private func text(_ d: Data?) -> String { d.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// A Claude record with a uuid and a timestamp.
    private func rec(_ n: Int, _ role: String = "assistant", minute: Int? = nil) -> String {
        let m = String(format: "%02d", minute ?? n)
        return #"{"message":{"content":"msg \#(n)","role":"\#(role)"},"timestamp":"2026-10-03T10:\#(m):00.000Z","type":"\#(role)","uuid":"00000000-0000-0000-0000-\#(String(format: "%012d", n))"}"#
            + "\n"
    }

    @Test("A shorter tail snapshot merges into the longer history it came from")
    func cacheSplice() {
        let l1 = "{\"n\":1,\"pad\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}\n"
        let l2 = "{\"n\":2,\"pad\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}\n"
        let l3 = "{\"n\":3,\"pad\":\"cccccccccccccccccccccccccccc\"}\n"
        let l4 = "{\"n\":4,\"pad\":\"dddddddddddddddddddddddddddd\"}\n"
        let history = Data((l1 + l2 + l3).utf8)
        // A byte-cap cut mid-l2, then l3 and a new l4.
        let tail = Data((String(l2.dropFirst(5)) + l3 + l4).utf8)
        let merged = SessionTranscriptCache.merge(history: history, incoming: tail, mode: .related)
        #expect(text(merged) == l1 + l2 + l3 + l4)

        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        cache.save(id, history)
        cache.save(id, tail)
        #expect(text(cache.load(id)) == l1 + l2 + l3 + l4)
        // An exact suffix of what's held changes nothing.
        cache.save(id, Data((l3 + l4).utf8))
        #expect(text(cache.load(id)) == l1 + l2 + l3 + l4)
    }

    @Test("A read that starts mid-record drops the cut line, and an unfinished last one")
    func partialEdgesDropped() {
        let full = rec(1) + rec(2) + rec(3)
        // B49: a byte window that began inside a record's base64.
        let cut = "QUFBQUFBQUFBQUFB\"}}]}}\n" + rec(2) + rec(3) + String(rec(4).prefix(30))
        let rs = SessionTranscriptCache.records(Data(cut.utf8))
        #expect(rs.count == 2)
        #expect(text(rs.first) + "\n" == rec(2))
        // Whole input is left as it is.
        #expect(SessionTranscriptCache.records(Data(full.utf8)).count == 3)
    }

    @Test("The copy never shrinks: a later tail with nothing in common is appended, not swapped in")
    func neverShrinks() {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let history = (1...10).map { rec($0, $0 % 2 == 1 ? "user" : "assistant") }.joined()
        cache.save(id, Data(history.utf8))
        // The engine's old 300 KB window, after a screenshot pushed records
        // 11–12 out of reach: starts mid-line, shares nothing with the copy.
        let tail = "iVBORw0KGgoAAAANSUhEUgAA\"}}]}}\n" + rec(13) + rec(14)
        cache.save(id, Data(tail.utf8))
        let after = text(cache.load(id))
        #expect(after == history + rec(13) + rec(14))
        // Another conversation's (older) records with nothing in common: refused.
        let foreign = #"{"type":"user","timestamp":"2026-10-03T09:00:00.000Z","uuid":"ffffffff-0000-0000-0000-000000000001","message":{"role":"user","content":"other"}}"# + "\n"
        cache.save(id, Data(foreign.utf8))
        #expect(text(cache.load(id)) == after)
        // …and a read that may be another session's is only merged when it overlaps.
        #expect(SessionTranscriptCache.merge(history: Data(after.utf8), incoming: Data(rec(20).utf8),
                                             mode: .overlapOnly) == nil)
        // A known continuation (the engine's incremental read) is appended as is.
        cache.append(id, Data(rec(15).utf8))
        #expect(text(cache.load(id)) == after + rec(15))
        // The beautified view's whole buffer, re-sent grown: only the growth lands.
        cache.save(id, Data((history + rec(13) + rec(14) + rec(15) + rec(16)).utf8))
        #expect(text(cache.load(id)) == after + rec(15) + rec(16))
    }

    @Test("Records are matched by uuid, and earlier ones go in front")
    func mergeByUUID() {
        let history = rec(3) + rec(4)
        // A "load earlier" window: records 1–2 the copy never had, then 3–5.
        let incoming = rec(1) + rec(2) + rec(3) + rec(4) + rec(5)
        let merged = SessionTranscriptCache.merge(history: Data(history.utf8), incoming: Data(incoming.utf8),
                                                  mode: .related)
        #expect(text(merged) == incoming)
        // A resume's copy of the same records, serialized differently: same uuids, no duplicates.
        let reserialized = rec(4).replacingOccurrences(of: "\"timestamp\"", with: "\"sessionId\":\"x\",\"timestamp\"")
        let again = SessionTranscriptCache.merge(history: Data(incoming.utf8),
                                                 incoming: Data((reserialized + rec(6)).utf8), mode: .related)
        #expect(text(again) == incoming + rec(6))
    }

    @Test("Image payloads are stripped to a placeholder, the record kept")
    func imagesStripped() throws {
        let b64 = String(repeating: "iVBORw0KGgoAAAANSUhEUgAAB9AAAAWW", count: 400)   // ~12.8 KB
        let line = #"{"type":"user","timestamp":"2026-10-03T10:01:00.000Z","uuid":"00000000-0000-0000-0000-000000000042","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64)"}}]}]},"toolUseResult":{"type":"image","file":{"base64":"\#(b64)","type":"image/png"}}}"#
        let use = #"{"type":"assistant","timestamp":"2026-10-03T10:00:00.000Z","uuid":"00000000-0000-0000-0000-000000000041","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"browser_screenshot","input":{}}]}}"#
        let rs = SessionTranscriptCache.records(Data((use + "\n" + line + "\n").utf8))
        #expect(rs.count == 2)
        let stripped = try #require(rs.last)
        #expect(stripped.count < 1_000)
        #expect(!text(stripped).contains(b64))
        // Same record (its uuid still matches), and the chat says what was there.
        #expect(SessionTranscriptCache.key(stripped) == .uuid("00000000-0000-0000-0000-000000000042"))
        let items = AgentTranscript.parse(SessionTranscriptCache.merge(history: Data(), incoming: Data((use + "\n" + line + "\n").utf8), mode: .related)!, agent: "claude")
        let results = items.compactMap { item -> String? in
            if case .toolResult(_, let content, _) = item.kind { return content }
            return nil
        }
        #expect(results == [SessionTranscriptCache.imagePlaceholder])
        // A short record goes through byte for byte.
        #expect(SessionTranscriptCache.records(Data((use + "\n").utf8)).first == Data(use.utf8))
    }

    @Test("The chunk command carries the host's cursor and the reader script")
    func chunkCommand() throws {
        let cmd = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/proj", since: 42, pinnedWindow: 3,
            knownPath: "/home/ubuntu/.claude/projects/-home-ubuntu-proj/s.jsonl", knownOffset: 1234,
            bytes: 24_000_000, earlier: false))
        #expect(cmd.contains("transcript-3.path"))
        #expect(cmd.contains("'/home/ubuntu/.claude/projects/-home-ubuntu-proj/s.jsonl' 1234 24000000 tail"))
        #expect(cmd.contains("<<'BROMURE_PY'") && cmd.hasSuffix("BROMURE_PY\nfi"))
        #expect(cmd.contains("iconv -f UTF-8 -t UTF-8 -c"))
        #expect(cmd.contains("pq-"))   // the pending-question line for Claude
        let earlier = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/proj", since: 0, agent: "omp", knownPath: nil, knownOffset: -1,
            bytes: 8_000_000, earlier: true))
        #expect(earlier.contains("'' -1 8000000 earlier"))
        #expect(!earlier.contains("pq-"))
    }

    @Test("A named agent scopes the locator to that agent's store only")
    func locatorScopesToAgent() throws {
        // The beautified view passes the tab's own agent so a kimi tab and an
        // omp tab sharing one cwd don't cross-read (the "wrong session, then it
        // switches" bug): agent: nil took the newest write across ALL stores.
        let kimi = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/proj", since: 0, agent: "kimi",
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(kimi.contains(".kimi-code/sessions"))
        #expect(!kimi.contains("PI_CODING_AGENT_DIR"))   // omp's store marker
        #expect(!kimi.contains(".claude/projects"))

        let omp = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/proj", since: 0, agent: "omp",
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(omp.contains("PI_CODING_AGENT_DIR"))
        #expect(!omp.contains(".kimi-code/sessions"))

        // No agent → the legacy probe-every-store fallback (safety net for a
        // tab whose agent didn't resolve).
        let any = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/proj", since: 0, agent: nil,
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(any.contains(".kimi-code/sessions"))
        #expect(any.contains("PI_CODING_AGENT_DIR"))
        #expect(any.contains(".claude/projects"))
    }

    /// Runs `pinnedTranscriptBlock` under bash against a temp HOME holding
    /// `record` (nil = no file) and a stub `tmux` whose tab is pane %5.
    private func pinned(_ record: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        let bromure = dir.appendingPathComponent(".bromure", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bromure, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tmux = bin.appendingPathComponent("tmux")
        try "#!/bin/sh\necho %5\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        if let record {
            try record.write(to: bromure.appendingPathComponent("transcript-3.path"),
                             atomically: true, encoding: .utf8)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", AgentSessionLocator.pinnedTranscriptBlock(window: "3", into: "c")
                          + "printf '%s' \"$c\""]
        proc.environment = ["HOME": dir.path, "PATH": bin.path + ":/usr/bin:/bin"]
        let out = Pipe(); proc.standardOutput = out
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("a window's transcript record is dropped once its index is reused")
    func pinnedRecordIsPaneScoped() throws {
        let path = "/home/ubuntu/.claude/projects/-home-ubuntu-x/abc.jsonl"
        // Written from this tab's pane (the boot id reads empty off-Linux,
        // on both sides): taken.
        #expect(try pinned(path + "\n%5 \n") == path)
        // Written from the tab that held index 3 before: not this tab's.
        #expect(try pinned(path + "\n%4 \n") == "")
        // An unstamped one-line record predates the stamp — an earlier
        // life of the index, left on /home: ignored.
        #expect(try pinned(path) == "")
        #expect(try pinned(nil) == "")
    }
}
