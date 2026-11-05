import Foundation
import Testing
@testable import bromure_ac

@Suite("The transcript index doesn't hold what it only passes through")
struct TranscriptIndexMemoryTests {
    private let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A launch reads every transcript in one loop on a detached task, which
    /// drains nothing by itself: 1.1 GB of transcripts peaked at 2.2 GB, and
    /// 282 MB with this pool. Memory isn't measured here, as other tests share
    /// the process; this pins that the loop goes through the pool.
    @Test("each transcript is read inside its own autorelease pool")
    func readsThroughThePool() throws {
        let source = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/TranscriptSearchIndex.swift"), encoding: .utf8)
        let refresh = try #require(source.range(of: "    func refresh() {"))
        let body = source[refresh.upperBound...].prefix(1_400)
        #expect(body.contains("Self.entry(of: url, modified: date)"))
        #expect(!body.contains("Data(contentsOf"))
        let reader = try #require(source.range(of: "nonisolated static func entry(of url: URL"))
        #expect(source[reader.upperBound...].prefix(200).contains("autoreleasepool {"))
    }

    @Test("reading from a file gives the same entry, and nothing for a missing one")
    func entryFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(#"""
            {"type":"user","message":{"role":"user","content":"fix the parser"}}
            {"type":"ai-title","aiTitle":"Fixing the parser"}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}

            """#.utf8)
        try data.write(to: url)
        let date = Date(timeIntervalSince1970: 1_000)
        let e = try #require(TranscriptSearchIndex.entry(of: url, modified: date))
        let direct = TranscriptSearchIndex.entry(data, modified: date)
        #expect(e.text == direct.text && e.lastReply == direct.lastReply && e.modified == date)
        #expect(e.agentTitle == "Fixing the parser")
        #expect(TranscriptSearchIndex.entry(of: url.appendingPathExtension("gone"), modified: date) == nil)
    }

    @Test("the title comes from its own line: the latest, a rename first, wherever it sits")
    func titleInTheBytes() {
        func title(_ s: String) -> String? { TranscriptSearchIndex.agentTitle(in: Data(s.utf8)) }
        #expect(title("") == nil)
        #expect(title(#"{"type":"user"}"#) == nil)
        // No newline either side: the whole file is the line.
        #expect(title(#"{"type":"ai-title","aiTitle":"Only"}"#) == "Only")
        let many = """
            {"type":"ai-title","aiTitle":"First"}
            {"type":"user"}
            {"type":"ai-title","aiTitle":"Second é"}
            {"type":"user"}
            """
        #expect(title(many) == "Second é")
        #expect(title(many + "\n" + #"{"type":"custom-title","customTitle":"  Renamed  "}"#) == "Renamed")
        // A slice, as a mapped or trimmed buffer can be: indices aren't 0-based.
        let sliced = Data(("junk\n" + many).utf8).dropFirst(5)
        #expect(TranscriptSearchIndex.agentTitle(in: sliced) == "Second é")
        // A bad line isn't a title; nor is an empty one.
        #expect(title(#"{"type":"ai-title","aiTitle":"#) == nil)
        #expect(title(#"{"type":"ai-title","aiTitle":"   "}"#) == nil)
    }
}
