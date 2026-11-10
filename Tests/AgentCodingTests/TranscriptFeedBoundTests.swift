import Foundation
import Testing
@testable import bromure_ac

/// The iOS readers' transcript feed holds a bounded window of the file:
/// a long-running session's appends trim the head (still loadable on
/// demand), "load earlier" stops at a ceiling, and a closed window's feed
/// is dropped. Finding: "iOS transcript feed retains and reparses
/// unbounded conversation data".
@MainActor
@Suite("TranscriptFeed bounds")
struct TranscriptFeedBoundTests {
    /// An in-memory guest transcript answering the chunk command's contract:
    /// `path\npq\nsize\nstart\nend\n` then the bytes [start, end), whole lines.
    final class FakeGuest {
        let path = "/home/ubuntu/.claude/projects/x/s.jsonl"
        var file = Data()
        var n = 0

        func append(_ count: Int) {
            for _ in 0..<count {
                n += 1
                let pad = String(repeating: "x", count: 150)
                let line = #"{"type":"user","message":{"role":"user","content":"msg \#(n) \#(pad)"},"uuid":"u\#(n)","timestamp":"2026-09-19T20:00:00.000Z","sessionId":"s1"}"#
                file.append(Data((line + "\n").utf8))
            }
        }

        let command: TranscriptFeed.Command = { known, offset, bytes, earlier in
            "\(known ?? "-")|\(offset)|\(bytes)|\(earlier)"
        }

        private func lineStart(atOrBefore i: Int) -> Int {
            guard i > 0 else { return 0 }
            return (file[..<i].lastIndex(of: 0x0A)).map { $0 + 1 } ?? 0
        }

        func exec(_ cmd: String) -> String? {
            let f = cmd.split(separator: "|").map(String.init)
            let known = f[0] == "-" ? nil : f[0], offset = Int(f[1])!, bytes = Int(f[2])!
            let size = file.count
            let start: Int, end: Int
            if f[3] == "true" {
                end = offset
                start = lineStart(atOrBefore: max(0, offset - bytes))
            } else if known == nil || offset > size {
                start = lineStart(atOrBefore: max(0, size - bytes))
                end = size
            } else {
                start = offset
                end = size
            }
            let head = "\(path)\n\n\(size)\n\(start)\n\(end)\n"
            return head + String(decoding: file[start..<end], as: UTF8.self)
        }
    }

    private func refresh(_ feed: TranscriptFeed, _ g: FakeGuest) async -> [TranscriptItem]? {
        await feed.refresh(agent: "claude", command: g.command, exec: { g.exec($0) })
    }

    @Test("A long-running session's appends keep the held bytes within the budget")
    func appendsStayBounded() async {
        let g = FakeGuest()
        let feed = TranscriptFeed(windowBytes: 4_096)
        g.append(10)
        _ = await refresh(feed, g)
        for _ in 0..<200 {
            g.append(3)
            _ = await refresh(feed, g)
            #expect(feed.heldBytes <= feed.budget)
        }
        #expect(g.file.count > 10 * feed.budget)
        #expect(feed.heldBytes <= 3 * 4_096)
        // The newest message is still on show; earlier is still reachable.
        let last = feed.items.last.map { "\($0.kind)" } ?? ""
        #expect(last.contains("msg \(g.n) "))
        #expect(feed.canLoadEarlier)
    }

    @Test("Load earlier brings trimmed history back, survives the next append, and stops at a ceiling")
    func loadEarlierBounded() async {
        let g = FakeGuest()
        let feed = TranscriptFeed(windowBytes: 4_096)
        g.append(600)
        _ = await refresh(feed, g)
        let before = feed.items.count
        #expect(await feed.loadEarlier(agent: "claude", command: g.command, exec: { g.exec($0) }))
        #expect(feed.items.count > before)
        let loaded = feed.items.count
        g.append(1)
        _ = await refresh(feed, g)
        #expect(feed.items.count == loaded + 1)   // what was asked for wasn't trimmed away

        var loads = 0
        while feed.canLoadEarlier, loads < 100 {
            await feed.loadEarlier(agent: "claude", command: g.command, exec: { g.exec($0) })
            loads += 1
        }
        #expect(loads < 100)
        #expect(!feed.canLoadEarlier)
        #expect(feed.heldBytes <= feed.maxBudget + 4_096)
        #expect(g.file.count > feed.maxBudget)
    }

    @Test("A closed window's feed and a room's evicted session drop their transcripts")
    func closedFeedsAreDropped() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ios = top.appendingPathComponent("ios/BromureRemote/Sources/BromureRemote")
        let ws = try String(contentsOf: ios.appendingPathComponent("WorkspaceScreen.swift"), encoding: .utf8)
        #expect(ws.contains("func drop(_ window: Int) {\n            feeds[window] = nil"))
        #expect(ws.contains("store.map[closing] = nil\n                transcripts.drop(closing)"))
        #expect(ws.contains("transcripts.drop(w)"))
        let room = try String(contentsOf: ios.appendingPathComponent("RoomScreens.swift"), encoding: .utf8)
        #expect(room.contains("feeds.removeValue(forKey: old)\n            items.removeValue(forKey: old)"))
    }
}
