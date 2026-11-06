import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Over a fat client the main thread was nearly saturated applying the server's
/// snapshots, which made everything slow: switching conversations most of all.
@Suite("Applying the server's snapshots")
struct SnapshotCostTests {
    private func frame(_ s: String, compressed: Bool = false) -> [UInt8] {
        let body = Array(s.utf8)
        let len = body.count + 1
        return [UInt8(len >> 24 & 255), UInt8(len >> 16 & 255), UInt8(len >> 8 & 255), UInt8(len & 255),
                compressed ? 1 : 0] + body
    }

    @Test("of the frames that have arrived, only the newest is taken, and all of them leave the buffer")
    func newest() {
        var buf = frame("one") + frame("two", compressed: true) + frame("three")
        let r = SnapshotFrames.takeLatest(from: &buf)
        #expect(r.latest?.payload == Data("three".utf8))
        #expect(r.latest?.compressed == false)
        #expect(!r.bogus)
        #expect(buf.isEmpty)
    }

    @Test("a frame still arriving stays for the next read, the newest complete one is taken")
    func partial() {
        let next = frame("next one")
        var buf = frame("done", compressed: true) + next.prefix(6)
        let r = SnapshotFrames.takeLatest(from: &buf)
        #expect(r.latest?.payload == Data("done".utf8))
        #expect(r.latest?.compressed == true)
        #expect(buf == Array(next.prefix(6)))
        buf += next.dropFirst(6)
        #expect(SnapshotFrames.takeLatest(from: &buf).latest?.payload == Data("next one".utf8))
        #expect(buf.isEmpty)
    }

    @Test("too little for a length, or nothing, takes nothing")
    func nothing() {
        var empty: [UInt8] = []
        #expect(SnapshotFrames.takeLatest(from: &empty).latest == nil)
        var short: [UInt8] = [0, 0]
        #expect(SnapshotFrames.takeLatest(from: &short).latest == nil)
        #expect(short == [0, 0])
    }

    @Test("a length no frame could have is reported; good frames before it still count")
    func bogus() {
        var buf = frame("good") + [0, 0, 0, 0, 9]
        let r = SnapshotFrames.takeLatest(from: &buf)
        #expect(r.bogus)
        #expect(r.latest?.payload == Data("good".utf8))
        var huge: [UInt8] = [0xFF, 0, 0, 0, 1]
        #expect(SnapshotFrames.takeLatest(from: &huge).bogus)
    }

    private struct Rec: Decodable, Equatable { var id: String; var v: Int; var note: String? }
    /// Counts decodes through a type that can tell: its `n` is stamped when decoded.
    private final class Counter: @unchecked Sendable { nonisolated(unsafe) static var n = 0 }
    private struct Counted: Decodable, Equatable {
        var id: String; var v: Int; var stamp: Int
        enum K: String, CodingKey { case id, v }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: .id)
            v = try c.decode(Int.self, forKey: .v)
            Counter.n += 1
            stamp = Counter.n
        }
    }

    @Test("gives what a fresh decode gives: order, new, changed, removed and undecodable records")
    func sameAsFresh() {
        let memo = SnapshotDecodeMemo<Rec>()
        let a: [[String: Any]] = [["id": "a", "v": 1], ["id": "b", "v": 2, "note": "x"]]
        #expect(memo.decode(a) == [Rec(id: "a", v: 1), Rec(id: "b", v: 2, note: "x")])
        #expect(memo.decode(a) == [Rec(id: "a", v: 1), Rec(id: "b", v: 2, note: "x")])
        let reordered: [[String: Any]] = [["id": "b", "v": 2, "note": "x"], ["id": "a", "v": 1]]
        #expect(memo.decode(reordered).map(\.id) == ["b", "a"])
        let changed: [[String: Any]] = [["id": "a", "v": 9], ["id": "c", "v": 3], ["id": "bad"], ["v": 4, "id": "d"]]
        #expect(memo.decode(changed) == [Rec(id: "a", v: 9), Rec(id: "c", v: 3), Rec(id: "d", v: 4)])
        #expect(memo.decode([]) == [])
        #expect(memo.decode(a).count == 2, "what left and came back is decoded anew")
    }

    @Test("a nested change is a change; an unchanged record isn't decoded again")
    func nestedAndReuse() throws {
        let memo = SnapshotDecodeMemo<Counted>()
        func snapshot(_ v: Int, extra: String) -> [[String: Any]] {
            [["id": "a", "v": v, "messages": [["text": extra]]], ["id": "b", "v": 1]]
        }
        let first = memo.decode(snapshot(1, extra: "x"))
        let second = memo.decode(snapshot(1, extra: "x"))
        #expect(first[0].stamp == second[0].stamp, "same raw record: not decoded again")
        #expect(first[1].stamp == second[1].stamp)
        // Raw differs only deep inside: decoded again, even though `v` is the same.
        let third = memo.decode(snapshot(1, extra: "y"))
        #expect(third[0].stamp != second[0].stamp)
        #expect(third[1].stamp == second[1].stamp, "only what changed")
    }

    @Test("records with no id are always decoded")
    func noID() {
        let memo = SnapshotDecodeMemo<Counted>()
        struct NoID: Decodable { var v: Int }
        let m = SnapshotDecodeMemo<NoID>()
        #expect(m.decode([["v": 1]]).first?.v == 1)
        #expect(m.decode([["v": 2]]).first?.v == 2)
        _ = memo
    }

    @Test("the chat's body reads no store for threading: that re-ran the transcript on every snapshot")
    func threadedReadsNoStore() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift")
        let code = try String(contentsOf: src, encoding: .utf8)
        let a = try #require(code.range(of: "private var threaded: ThreadedConversation? {"))
        let b = try #require(code.range(of: "private func refreshThreading()"))
        let body = code[a.upperBound..<b.lowerBound]
        #expect(!body.contains("sessionStore"))
        #expect(!body.contains("currentSession"))
        #expect(!code.contains("(model.sessionStore?.sessions ?? []).filter"), "the bar's waiting list too")
    }
}

@Suite("Tabs closed here")
struct TabDropsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("hidden while a stale snapshot still lists it; gone from the list ends it")
    func usual() {
        let p = [3: t0]
        #expect(TabDrops.stillPending(p, listed: [1, 3], now: t0.addingTimeInterval(1)) == p)
        #expect(TabDrops.stillPending(p, listed: [1], now: t0.addingTimeInterval(1)).isEmpty)
    }

    @Test("a new tab that took the closed one's number shows, even if no snapshot without it was ever applied")
    func reusedIndex() {
        let p = [3: t0]
        #expect(TabDrops.stillPending(p, listed: [1, 3], now: t0.addingTimeInterval(TabDrops.patience)).isEmpty)
    }

    @Test("each is judged on its own")
    func separately() {
        let p = [3: t0, 5: t0.addingTimeInterval(7)]
        #expect(TabDrops.stillPending(p, listed: [3, 5], now: t0.addingTimeInterval(TabDrops.patience)).keys.sorted() == [5])
    }
}

@Suite("Preloading conversations")
@MainActor
struct ChatPreloadTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func live(_ at: TimeInterval, window: Int? = 1) -> (AgentSession, Date) {
        (AgentSession(profileID: UUID(), tool: .claude, title: "t", windowIndex: window), t0.addingTimeInterval(at))
    }
    private func next(_ rows: [(AgentSession, Date)], done: [UUID: ChatPreload.Done] = [:], skipping: Set<UUID> = [],
                      now: Date? = nil) -> UUID? {
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.0.id, $0.1) })
        return ChatPreload.next(rows.map(\.0), done: done, skipping: skipping, activity: { map[$0.id]! },
                                now: now ?? t0.addingTimeInterval(1_000))?.id
    }

    @Test("the most recently active comes first, then the next, then nothing")
    func order() {
        let a = live(10), b = live(20)
        #expect(next([a, b]) == b.0.id)
        let doneB = [b.0.id: ChatPreload.Done(activity: b.1, at: t0)]
        #expect(next([a, b], done: doneB) == a.0.id)
        let both = doneB.merging([a.0.id: ChatPreload.Done(activity: a.1, at: t0)]) { x, _ in x }
        #expect(next([a, b], done: both) == nil, "nothing's changed: no traffic")
    }

    @Test("a session with new activity is fetched again, but not more often than the interval")
    func again() {
        let a = live(100)
        let old = ChatPreload.Done(activity: t0, at: t0.addingTimeInterval(95))
        #expect(next([a], done: [a.0.id: old], now: t0.addingTimeInterval(100)) == nil, "too soon")
        #expect(next([a], done: [a.0.id: old], now: t0.addingTimeInterval(95 + ChatPreload.minimumInterval)) == a.0.id)
    }

    @Test("what's on show or warm is skipped; a session with no tab or that has ended isn't read")
    func skipped() {
        let a = live(10), noTab = live(30, window: nil)
        #expect(next([a], skipping: [a.0.id]) == nil)
        #expect(next([noTab]) == nil)
        var ended = live(40); ended.0.endedAt = t0; ended.0.windowIndex = nil
        #expect(next([ended]) == nil)
    }

    @Test("only the most recent few are kept ready")
    func bounded() {
        let rows = (0..<(ChatPreload.candidates + 3)).map { live(TimeInterval($0)) }
        var done: [UUID: ChatPreload.Done] = [:]
        var fetched = 0
        while let id = next(rows, done: done) {
            done[id] = ChatPreload.Done(activity: t0.addingTimeInterval(9_999), at: t0)
            fetched += 1
            if fetched > 50 { break }
        }
        #expect(fetched == ChatPreload.candidates)
    }

    private final class Provider: BeautifiedTranscriptProvider {
        var file: Data; let key: String; var reads = 0; var asks: [String] = []
        init(_ s: String, key: String) { file = Data(s.utf8); self.key = key }
        var accent: Color { .blue }
        var historyCacheKey: String? { key }
        func activeTabIndex() -> Int? { 2 }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            asks.append(String(command.prefix(40)))
            if command.contains("pane_current_path") { return "/home/ubuntu/w\n0\n" }
            guard command.hasPrefix("f=\"\";") else { return "" }
            reads += 1
            return "/home/ubuntu/.claude/projects/p/s.jsonl\n\n\(file.count)\n0\n\(file.count)\n" + String(decoding: file, as: UTF8.self)
        }
    }
    static let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"from the preload"}]},"timestamp":"2026-10-20T16:24:01Z"}"# + "\n"

    @Test("a preloaded conversation is on show the moment its chat opens, and the preload touches nothing else")
    func opensAtOnce() async {
        let key = "preload-\(UUID().uuidString)"
        let p = Provider(Self.line, key: key)
        let ok = await BeautifiedSessionModel.preloadHistory(provider: p, agent: "claude", profileID: nil)
        #expect(ok)
        #expect(!p.asks.contains { $0.contains("capture-pane") }, "no terminal scan")
        let m = BeautifiedSessionModel(provider: p)
        m.start()
        #expect(m.items.count == 1, "in the same frame")
        m.stop()
    }

    /// A chat with a question up (the guest's pending-question line, beside the
    /// file) leaves; the question is answered; the chat opens again from its cache.
    @Test("a question answered while away doesn't stick from the cache, holding messages back")
    func answeredWhileAway() async {
        final class Asking: BeautifiedTranscriptProvider {
            let key: String; var pq: String
            init(_ k: String, pq: String) { key = k; self.pq = pq }
            var accent: Color { .blue }
            var historyCacheKey: String? { key }
            func activeTabIndex() -> Int? { 2 }
            func isWorking() -> Bool { false }
            func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
            func execGuest(_ command: String, timeout: Int) async -> String? {
                if command.hasPrefix("f=\"\";") {
                    let n = ChatPreloadTests.line.utf8.count
                    // Known to the end: nothing new in the file, as on a real reopen.
                    if command.contains(" \(n) ") {
                        return "/home/ubuntu/.claude/projects/p/s.jsonl\n\(pq)\n\(n)\n\(n)\n\(n)\n"
                    }
                    return "/home/ubuntu/.claude/projects/p/s.jsonl\n\(pq)\n\(n)\n0\n\(n)\n" + ChatPreloadTests.line
                }
                if command.contains("pane_current_path") { return "/home/ubuntu/w\n0\n" }
                return ""
            }
        }
        func wait(_ cond: () -> Bool) async {
            let end = Date().addingTimeInterval(20)
            while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        let pq = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"A"}]}]}}"#
        let key = "pq-\(UUID().uuidString)"
        let first = BeautifiedSessionModel(provider: Asking(key, pq: pq))
        first.start()
        await wait { !first.pendingQuestionItems.isEmpty }
        #expect(!first.pendingQuestionItems.isEmpty, "the question is up")
        first.stop()
        let again = BeautifiedSessionModel(provider: Asking(key, pq: ""))
        again.start()
        await wait { again.pendingQuestionItems.isEmpty && !again.catchingUp }
        #expect(again.pendingQuestionItems.isEmpty, "answered: the card goes, and with it what held messages back")
        #expect(!again.dialogOpen)
        #expect(!again.items.isEmpty)
        again.stop()
    }

    @Test("nothing to read, or a machine that can't be asked: nothing is cached")
    func failed() async {
        final class Dead: BeautifiedTranscriptProvider {
            let key: String; init(_ k: String) { key = k }
            var accent: Color { .blue }
            var historyCacheKey: String? { key }
            func activeTabIndex() -> Int? { 2 }
            func isWorking() -> Bool { false }
            func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
            func execGuest(_ command: String, timeout: Int) async -> String? { nil }
        }
        let d = Dead("preload-\(UUID().uuidString)")
        #expect(await BeautifiedSessionModel.preloadHistory(provider: d, agent: nil, profileID: nil) == false)
        let m = BeautifiedSessionModel(provider: d)
        m.start()
        #expect(m.items.isEmpty)
        m.stop()
    }
}
