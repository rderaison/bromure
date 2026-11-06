import Foundation
import Testing
@testable import bromure_ac

@Suite("The index reads only what a transcript gained, and remembers it across launches")
struct TranscriptIndexLiveTests {
    typealias I = TranscriptSearchIndex
    private let d0 = Date(timeIntervalSince1970: 0)
    private func user(_ t: String) -> String { #"{"type":"user","timestamp":"2026-11-05T10:00:00.000Z","message":{"role":"user","content":"\#(t)"}}"# }
    private func reply(_ t: String) -> String {
        #"{"type":"assistant","timestamp":"2026-11-05T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(t)"}]}}"#
    }
    /// Enough lines that the format is settled from the first read.
    private func opening() -> [String] { (0..<210).map { _ in #"{"type":"mode","mode":"default"}"# } }
    private func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).jsonl") }

    @Test("turn after turn it carries on from the last turn's start, and ends where a fresh read does")
    func growing() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        var lines = opening() + [user("first ask"), reply("first answer")]
        try write(lines, to: url)
        var rec = try #require(I.read(url, modified: d0, known: nil))
        var offsets = [rec.resume?.offset ?? 0]
        for i in 1...4 {
            lines += [user("ask \(i)"), reply("answer \(i)")]
            try write(lines, to: url)
            rec = try #require(I.read(url, modified: d0, known: rec))
            offsets.append(rec.resume?.offset ?? 0)
        }
        #expect(offsets == offsets.sorted() && Set(offsets).count == offsets.count)   // moves on each turn
        let fresh = try #require(I.read(url, modified: d0, known: nil))
        #expect(rec.entry.text == fresh.entry.text && rec.entry.turns == fresh.entry.turns)
        #expect(rec.entry.firstPrompt == "first ask" && rec.entry.lastReply == "answer 4")
        #expect(rec.entry.text.contains("first answer") && rec.entry.text.contains("ask 3"))
    }

    @Test("a rewrite of what came before (records put in front, or in between) is read anew")
    func rewrite() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = (0..<40).flatMap { [user("middle \($0)"), reply("m\($0)")] }
        let lines = opening() + [user("old ask"), reply("old answer")] + mid + [user("second"), reply("two")]
        try write(lines, to: url)
        let rec = try #require(I.read(url, modified: d0, known: nil))
        // An older record put in front, as "load earlier" merges one.
        var front = lines
        front.insert(user("earlier ask"), at: opening().count)
        try write(front + [user("third"), reply("three")], to: url)
        let a = try #require(I.read(url, modified: d0, known: rec))
        #expect(a.entry.text.contains("earlier ask") && a.entry.firstPrompt == "earlier ask")
        // A record put in between, past the start.
        var between = lines
        between.insert(user("slipped in"), at: opening().count + 30)
        try write(between + [user("third"), reply("three")], to: url)
        let b = try #require(I.read(url, modified: d0, known: rec))
        #expect(b.entry.text.contains("slipped in"))
        #expect(b.entry == (try #require(I.read(url, modified: d0, known: nil))).entry)
    }

    @Test("a /clear in what it gained drops what came before, as the chat does")
    func clearLater() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        var lines = opening() + [user("before the clear"), reply("old")]
        try write(lines, to: url)
        let rec = try #require(I.read(url, modified: d0, known: nil))
        lines += [#"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
                  user("after the clear"), reply("new")]
        try write(lines, to: url)
        let next = try #require(I.read(url, modified: d0, known: rec))
        let fresh = try #require(I.read(url, modified: d0, known: nil))
        #expect(!next.entry.text.contains("before the clear") && next.entry.text.contains("after the clear"))
        #expect(next.entry.text == fresh.entry.text && next.entry.firstPrompt == fresh.entry.firstPrompt)
    }

    @Test("a file too short for its format to be settled is read anew each time")
    func unsettledFormat() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try write([user("a"), reply("b")], to: url)
        let rec = try #require(I.read(url, modified: d0, known: nil))
        #expect(rec.resume?.agentSettled == false)
        try write([user("a"), reply("b"), user("c"), reply("d")], to: url)
        let next = try #require(I.read(url, modified: d0, known: rec))
        #expect(next.entry == (try #require(I.read(url, modified: d0, known: nil))).entry)
    }

    @Test("records are saved and loaded back; another version's are ignored")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try write(opening() + [user("kept"), reply("across launches")], to: url)
        let rec = try #require(I.read(url, modified: d0, known: nil))
        let id = UUID(), other = UUID()
        I.save(rec, id: id, in: dir)
        var old = rec; old.version = I.Record.currentVersion + 1
        I.save(old, id: other, in: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        let loaded = I.loadRecords(from: dir)
        #expect(loaded[id] == rec)
        #expect(loaded[other] == nil && loaded.count == 1)
    }

    @Test("joining the entry before a turn start with the rest gives the whole one")
    func joinIsWhole() throws {
        let lines = opening() + [user("one"), reply("first"), user("two"), reply("second"), user("three"), reply("third")]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let cut = try #require(I.turnStart(in: data, agent: "claude"))
        let a = I.entry(Data(data[..<cut]), modified: d0, agent: "claude")
        let b = I.entry(Data(data[cut...]), modified: d0, agent: "claude")
        let whole = I.entry(data, modified: d0, agent: "claude")
        let joined = I.joined(a, b)
        #expect(joined.text == whole.text && joined.turns == whole.turns && joined.lastReply == whole.lastReply)
        #expect(joined.firstPrompt == whole.firstPrompt)
        // Timeline ids stay unique across the join.
        let ids = joined.timeline.turns.map(\.id) + joined.timeline.turns.flatMap { $0.segments.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }
}
