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
        #expect(body.contains("Self.read(url, modified: date, known: known[id])"))
        #expect(!body.contains("Data(contentsOf"))
        for sig in ["nonisolated static func entry(of url: URL", "nonisolated static func read(_ url: URL"] {
            let reader = try #require(source.range(of: sig))
            #expect(source[reader.upperBound...].prefix(300).contains("autoreleasepool {"), Comment(rawValue: sig))
        }
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

@Suite("A transcript past the cap is read for its start and its end")
struct TranscriptIndexCapTests {
    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }
    private func user(_ t: String) -> String { #"{"type":"user","message":{"role":"user","content":"\#(t)"}}"# }
    private func reply(_ t: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(t)"}]}}"#
    }
    private func lines() -> [String] {
        var l = [user("first ask"), reply("first answer")]
        for i in 0..<400 { l += [user("middle ask \(i)"), reply(String(repeating: "padding ", count: 40))] }
        l += [#"{"type":"ai-title","aiTitle":"Late title"}"#, user("last ask"), reply("last answer")]
        return l
    }

    @Test("start and end are kept, the middle isn't, and no line is read in half")
    func headAndTail() throws {
        let url = try file(lines()); defer { try? FileManager.default.removeItem(at: url) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let e = try #require(TranscriptSearchIndex.entry(of: url, modified: Date(), cap: 8_000, head: 300))
        #expect(size > 8_000)
        #expect(e.firstPrompt == "first ask")
        #expect(e.text.contains("first ask") && e.text.contains("last ask") && e.text.contains("last answer"))
        #expect(!e.text.contains("middle ask 1\n") && !e.text.contains("middle ask 10\n"))
        #expect(e.lastReply == "last answer")
        #expect(e.agentTitle == "Late title")
        // Every paragraph is a whole message: none starts or ends mid-line.
        for p in e.text.components(separatedBy: "\n\n") where !p.isEmpty {
            #expect(p.hasPrefix("first") || p.hasPrefix("middle ask") || p.hasPrefix("padding") || p.hasPrefix("last"), Comment(rawValue: p))
        }
    }

    @Test("under the cap it's the same entry as reading the whole file")
    func underTheCap() throws {
        let url = try file(lines()); defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let capped = try #require(TranscriptSearchIndex.entry(of: url, modified: Date(timeIntervalSince1970: 5), cap: data.count, head: 300))
        let whole = TranscriptSearchIndex.entry(data, modified: Date(timeIntervalSince1970: 5))
        #expect(capped.text == whole.text && capped.firstPrompt == whole.firstPrompt && capped.lastReply == whole.lastReply)
        #expect(capped.turns == whole.turns && capped.agentTitle == whole.agentTitle && capped.tokens == whole.tokens)
    }

    /// The finding: a file of one record past the cap (a pasted prompt, a
    /// tool's output) had no whole line in either sample, and was indexed
    /// with nothing in it: not searchable, no prompt, no reply.
    @Test("one record past the cap is still indexed: its words, as prompt or reply")
    func degenerate() throws {
        typealias I = TranscriptSearchIndex
        let d0 = Date(timeIntervalSince1970: 0)
        let words = "needle-in-the-reply " + String(repeating: "x", count: 20_000)
        let long = try file([reply(words)]); defer { try? FileManager.default.removeItem(at: long) }
        let e = try #require(I.entry(of: long, modified: d0, cap: 4_000, head: 300))
        #expect(e.text.hasPrefix("needle-in-the-reply") && e.lastReply.hasPrefix("needle-in-the-reply"))
        let r = try #require(I.read(long, modified: d0, known: nil, cap: 4_000, head: 300))
        #expect(r.entry.text.hasPrefix("needle-in-the-reply"))
        // A pasted prompt: the user's words, and its first prompt.
        let prompt = try file([user("please review " + String(repeating: "y", count: 20_000))])
        defer { try? FileManager.default.removeItem(at: prompt) }
        let p = try #require(I.entry(of: prompt, modified: d0, cap: 4_000, head: 300))
        #expect(p.firstPrompt?.hasPrefix("please review") == true && p.lastReply.isEmpty)
        let tiny = try file([user("a"), reply("b")]); defer { try? FileManager.default.removeItem(at: tiny) }
        #expect(I.entry(of: tiny, modified: d0, cap: 40, head: 10)?.lastReply != nil)
    }

    @Test("a first record longer than the head, but under half the cap, is read whole")
    func longFirstRecord() throws {
        typealias I = TranscriptSearchIndex
        let d0 = Date(timeIntervalSince1970: 0)
        let first = user("the opening ask " + String(repeating: "z", count: 1_500))
        let rest = (0..<120).flatMap { [user("ask \($0) " + String(repeating: "p", count: 60)), reply("answer \($0)")] }
        let url = try file([first] + rest); defer { try? FileManager.default.removeItem(at: url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let cap = 8_000
        #expect(size > cap)
        for e in [try #require(I.entry(of: url, modified: d0, cap: cap, head: 300)),
                  try #require(I.read(url, modified: d0, known: nil, cap: cap, head: 300)).entry] {
            #expect(e.firstPrompt?.hasPrefix("the opening ask") == true)
            #expect(e.lastReply == "answer 119")
        }
        // The two samples stay within the cap.
        let data = try Data(contentsOf: url)
        let s = try #require(I.samples(size: UInt64(size), cap: cap, head: 300) { at, count in
            data.subdata(in: Int(at)..<min(data.count, Int(at) + count))
        })
        #expect(s.start.count + (size - Int(s.endAt)) <= cap)
    }

    @Test("the cap is 100 MB, with the first megabyte kept")
    func sizes() {
        #expect(TranscriptSearchIndex.indexCap == 100 * 1_048_576)
        #expect(TranscriptSearchIndex.indexHead == 1_048_576)
    }
}
