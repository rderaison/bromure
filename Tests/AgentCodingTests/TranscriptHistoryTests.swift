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

    @Test("A shorter tail snapshot splices into the longer history it came from")
    func cacheSplice() {
        let l1 = "{\"n\":1,\"pad\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}\n"
        let l2 = "{\"n\":2,\"pad\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}\n"
        let l3 = "{\"n\":3,\"pad\":\"cccccccccccccccccccccccccccc\"}\n"
        let l4 = "{\"n\":4,\"pad\":\"dddddddddddddddddddddddddddd\"}\n"
        let history = Data((l1 + l2 + l3).utf8)
        // A byte-cap cut mid-l2, then l3 and a new l4.
        let tail = Data((String(l2.dropFirst(5)) + l3 + l4).utf8)
        let merged = SessionTranscriptCache.splice(history: history, tail: tail)
        #expect(merged.map { String(decoding: $0, as: UTF8.self) } == l1 + l2 + l3 + l4)
        // Unrelated content: no splice.
        #expect(SessionTranscriptCache.splice(history: history, tail: Data("x\n{\"z\":9,\"pad\":\"zzzzzzzzzzzzzzzzzzzz\"}\n".utf8)) == nil)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-tests-\(UUID().uuidString)", isDirectory: true)
        let cache = SessionTranscriptCache(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        cache.save(id, history)
        cache.save(id, tail)
        #expect(cache.load(id).map { String(decoding: $0, as: UTF8.self) } == l1 + l2 + l3 + l4)
        // An exact suffix of what's held changes nothing.
        cache.save(id, Data((l3 + l4).utf8))
        #expect(cache.load(id).map { String(decoding: $0, as: UTF8.self) } == l1 + l2 + l3 + l4)
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
}
