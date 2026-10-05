import Foundation
import Testing
@testable import bromure_ac

/// S1-1: a 20 KB paste sent from the chat froze the app — the message was
/// ONE row thousands of points tall (only replies were ever cut), and the
/// lazy chat stack placing it never settled. No row may be that tall now.
@Suite("Long messages of yours are bounded rows")
struct LongMessageRowsTests {
    private func item(_ id: Int, _ k: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: id, kind: k, timestamp: nil) }

    /// 312 short lines, ~20 KB — the paste that froze the chat.
    private var paste: String {
        (["PASTE-20K START"] + (1...311).map { String(format: "M-%05d echo charlie india delta papa oscar papa mike #%d", $0, $0 * 7919) })
            .joined(separator: "\n")
    }

    private func userTexts(_ rows: [TranscriptRow]) -> [TranscriptItem] {
        rows.compactMap { r -> TranscriptItem? in
            if case .item(let i) = r, case .userText = i.kind { return i } else { return nil }
        }
    }

    @Test("A 20 KB paste shows its start, with what it stands for")
    func collapsed() {
        let text = paste
        #expect(text.utf8.count > 19_000)
        #expect(TranscriptRow.userCollapses(text))
        #expect(!TranscriptRow.userCollapses("a short question"))
        let layout = TranscriptRow.layout([item(1, .userText(text)), item(2, .assistantText("ok"))])
        let users = userTexts(layout.rows)
        #expect(users.count == 1)
        guard case .userText(let shown)? = users.first?.kind else { Issue.record("no user row"); return }
        #expect(shown.count < 2_000)
        #expect(shown.split(separator: "\n", omittingEmptySubsequences: false).count <= TranscriptRow.userPreviewLines)
        #expect(text.hasPrefix(shown))
        let long = layout.longUsers[1]
        #expect(long?.whole == text && long?.controls == true && long?.expanded == false)
        #expect(long?.total == text.count)
    }

    @Test("Opened in full it comes in bounded pieces; Copy takes all of it", arguments: [500, 900, 1400, 2000])
    func expanded(limit: Int) {
        let text = paste
        let layout = TranscriptRow.layout([item(5, .userText(text))], chunkLimit: limit, expanded: [5])
        let pieces = userTexts(layout.rows)
        #expect(pieces.count > 1)
        #expect(pieces.first?.id == 5)
        #expect(Set(layout.rows.map(\.id)).count == layout.rows.count)
        var joined: [String] = []
        for p in pieces {
            guard case .userText(let t) = p.kind else { continue }
            #expect(t.utf16.count <= limit)
            #expect(t.split(separator: "\n", omittingEmptySubsequences: false).count <= TranscriptRow.userLinesPerPiece)
            #expect(layout.longUsers[p.id]?.whole == text)
            joined.append(t)
        }
        #expect(joined.joined(separator: "\n") == text)
        // Show less sits on the last piece only.
        #expect(pieces.filter { layout.longUsers[$0.id]?.controls == true }.map(\.id) == [pieces.last!.id])
    }

    @Test("A 200 KB message with no line breaks is cut too")
    func oneGiantLine() {
        let text = String(repeating: "x", count: 200_000)
        let collapsed = userTexts(TranscriptRow.rows([item(9, .userText(text))]))
        guard case .userText(let shown)? = collapsed.first?.kind else { Issue.record("no user row"); return }
        #expect(shown.count <= TranscriptRow.chunkChars)
        let open = userTexts(TranscriptRow.rows([item(9, .userText(text))], expanded: [9]))
        #expect(open.count >= 100)
    }

    @Test("Short messages and host asides stay as they are")
    func shortStays() {
        let rows = TranscriptRow.layout([item(1, .userText("hello")), item(2, .userText(DelegationNotice.prefix + " " + paste))])
        #expect(rows.longUsers.isEmpty)                            // a delegation notice is its own line
        #expect(userTexts(rows.rows).first.map { if case .userText(let t) = $0.kind { t == "hello" } else { false } } == true)
    }

    @Test("A reply with no blank line is cut too, and a giant code block keeps its fences")
    func repliesHaveACap() {
        let prose = (0..<400).map { "Sentence \($0) goes on a while with words." }.joined(separator: " ")
        let pieces = TranscriptRow.chunks(prose)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.utf16.count <= TranscriptRow.chunkChars * TranscriptRow.hardCap })
        let code = "Here:\n\n```swift\n" + (0..<1500).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n```\n\nDone."
        let cut = TranscriptRow.chunks(code)
        #expect(cut.count > 1)
        for p in cut {
            #expect(p.components(separatedBy: "```").count % 2 == 1)        // fences balanced
            #expect(p.utf16.count <= TranscriptRow.chunkChars * TranscriptRow.hardCap + 40)
        }
        let body = cut.joined(separator: "\n").replacingOccurrences(of: "```swift", with: "").replacingOccurrences(of: "```", with: "")
        for i in [0, 700, 1499] { #expect(body.contains("let v\(i) = \(i)\n") || body.hasSuffix("let v\(i) = \(i)")) }
    }

    @Test("Every piece of a long reply still copies the whole reply")
    func replies() {
        let text = (0..<30).map { "Paragraph \($0): " + String(repeating: "word ", count: 120) }.joined(separator: "\n\n")
        let layout = TranscriptRow.layout([item(4, .assistantText(text))])
        #expect(layout.rows.count > 1)
        for r in layout.rows { #expect(layout.replies[r.id] == text) }
    }

    @Test("The chat reuses its rows until the items, width step or expanded set change")
    func memo() {
        let memo = TranscriptRowsMemo()
        let items = [item(1, .userText(paste))]
        let a = memo.layout(items, chunkLimit: 2000, expanded: [])
        let b = memo.layout(items, chunkLimit: 2000, expanded: [])
        #expect(a.rows.map(\.id) == b.rows.map(\.id))
        let c = memo.layout(items, chunkLimit: 2000, expanded: [1])
        #expect(c.rows.count > a.rows.count)
    }
}

/// S1-2: a queue row coming in pushed the approval card up a row, and a
/// click aimed at "Approve once" landed on "Reject".
@Suite("Approval cards ignore clicks right after they move")
struct LayoutShiftGuardTests {
    @Test("Appearing and moving each start a short no-click window")
    func guardWindow() {
        let g = LayoutShiftGuard()
        let t0 = Date()
        g.note(400, now: t0)                                       // appears
        #expect(!g.allows(now: t0.addingTimeInterval(0.1)))
        #expect(g.allows(now: t0.addingTimeInterval(LayoutShiftGuard.settle + 0.01)))
        let t1 = t0.addingTimeInterval(2)
        g.note(400.5, now: t1)                                     // sub-point wobble: not a move
        #expect(g.allows(now: t1))
        g.note(350, now: t1)                                       // pushed up a row
        #expect(!g.allows(now: t1.addingTimeInterval(0.2)))
        #expect(g.allows(now: t1.addingTimeInterval(LayoutShiftGuard.settle + 0.01)))
    }
}
