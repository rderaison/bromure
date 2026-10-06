import Foundation
import Testing
@testable import bromure_ac

/// P0 (omp QA, round 5): a 21 KB ⌘V into the composer of a long omp chat
/// (a long-markdown reply, tool runs, earlier pastes) froze the app for
/// good — the main thread looped in ONE SwiftUI flush placing the chat's
/// LazyVStack (LazySubviewPlacements / placedAnchorTranslation / item
/// phase mutations / the selectable text's AppKit field re-measured).
/// The chat's rows are now an eager stack windowed by text; these guard
/// that, the window, and the row identities on a transcript of that shape.
/// The layout itself is exercised by `bromure-ac __bench-scroll <fixture>
/// --chat --switch 60 --composer --key --warm [--also <fixture>]…` (mount
/// / Working↔Ready / width / Show all / selection / ⌘V paste / tail
/// snaps, seeded; exits 3 on a hang).
@Suite("Chat layout: no lazy placement loop")
struct ChatLayoutLoopTests {

    // MARK: A transcript shaped like the QA's (omp JSONL)

    private static func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private static func message(_ id: Int, _ t: Double, role: String, _ content: [[String: Any]],
                                extra: [String: Any] = [:]) -> String {
        var m: [String: Any] = ["role": role, "content": content]
        m.merge(extra) { a, _ in a }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return line(["type": "message", "id": String(format: "%08x", id), "parentId": String(format: "%08x", id - 1),
                     "timestamp": iso.string(from: Date(timeIntervalSince1970: 1_791_000_000 + t)),
                     "message": m])
    }

    /// A long markdown reply: headings, prose, fenced code, a table.
    private static func longMarkdown(sections: Int) -> String {
        var s = "# Python generators\n\n"
        for k in 0..<sections {
            s += "## Part \(k)\n\nA generator function uses `yield` to hand values out one at a time, "
                + "pausing its frame between them, so a pipeline never holds the whole sequence.\n\n"
                + "```python\ndef count_up(n):\n    i = 0\n    while i < n:\n        yield i\n        i += 1\n```\n\n"
                + "| step | value |\n|---|---|\n| 1 | 0 |\n| 2 | 1 |\n\n"
        }
        return s
    }

    private static func pasteText(kb: Int) -> String {
        "Please reply only with the word RECEIVED and the number of lines starting with 'L' in this message. Data follows:\n"
            + ChatLayoutCheck.pasteFixture(kb: kb)
    }

    static func ompTranscript(turns: Int = 3) -> Data {
        var lines = [line(["type": "session", "version": 3, "id": "fixture", "cwd": "/home/ubuntu/omp2-long"])]
        var id = 1, t = 0.0
        func next() -> (Int, Double) { id += 1; t += 1; return (id, t) }
        for turn in 0..<turns {
            var (i, ts) = next()
            lines.append(message(i, ts, role: "user", [["type": "text", "text": "Explain generators, part \(turn)."]]))
            (i, ts) = next()
            lines.append(message(i, ts, role: "assistant", [
                ["type": "thinking", "thinking": String(repeating: "Thinking it over. ", count: 80)],
                ["type": "text", "text": longMarkdown(sections: 6 + turn * 4)],
            ]))
            // A run of tool calls and their results.
            for k in 0..<3 {
                (i, ts) = next()
                lines.append(message(i, ts, role: "assistant", [
                    ["type": "text", "text": "Running step \(k)."],
                    ["type": "toolCall", "id": "call_\(turn)_\(k)", "name": "bash",
                     "arguments": ["command": "python3 -m pytest -q demo/test_\(k).py"]],
                ]))
                (i, ts) = next()
                lines.append(message(i, ts, role: "toolResult", [["type": "text", "text": "\(k + 3) passed in 0.0\(k)s"]],
                                     extra: ["toolCallId": "call_\(turn)_\(k)", "toolName": "bash", "isError": false]))
            }
            // An earlier big paste of yours, and its short answer.
            (i, ts) = next()
            lines.append(message(i, ts, role: "user", [["type": "text", "text": pasteText(kb: 6 + turn * 10)]]))
            (i, ts) = next()
            lines.append(message(i, ts, role: "assistant", [["type": "text", "text": "RECEIVED \(60 + turn)"]]))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: The chat view

    @Test("The chat's rows are not a lazy stack (its placement looped forever)")
    func noLazyStack() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift")
        let code = try String(contentsOf: src, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("LazyVStack("))
        #expect(code.contains("Self.renderWindow(model.items"))
    }

    // MARK: The window

    private func text(_ id: Int, _ n: Int, user: Bool = false) -> TranscriptItem {
        let s = String(repeating: "x", count: n)
        return TranscriptItem(id: id, kind: user ? .userText(s) : .assistantText(s), timestamp: nil)
    }

    @Test("The window keeps the newest items within the text budget")
    func windowBudget() {
        let items = (0..<50).map { text($0, 1_000) }
        let w = BeautifiedSessionView.renderWindow(items, limit: 300, chars: 10_000)
        #expect(w.map(\.id) == Array(40..<50))
        // The item limit still applies.
        #expect(BeautifiedSessionView.renderWindow(items, limit: 4, chars: 1_000_000).map(\.id) == [46, 47, 48, 49])
        // Everything, when it all fits.
        #expect(BeautifiedSessionView.renderWindow(items, limit: 300, chars: 1_000_000).count == 50)
    }

    @Test("A reply bigger than the budget still shows whole, with the one before it")
    func windowHugeReply() {
        let items = [text(1, 500), text(2, 500), text(3, 200_000), text(4, 10)]
        let w = BeautifiedSessionView.renderWindow(items, limit: 300, chars: 30_000)
        #expect(w.map(\.id) == [3, 4])
        // It weighs what shows of it until opened.
        #expect(BeautifiedSessionView.renderWeight(items[2]) == TranscriptRow.expandedChars)
        #expect(BeautifiedSessionView.renderWeight(items[2], expanded: true) == 200_000)
        // At least two, whatever their size.
        let two = BeautifiedSessionView.renderWindow([text(1, 90_000), text(2, 90_000)], limit: 300, chars: 10)
        #expect(two.count == 2)
    }

    @Test("A long message of yours weighs what it shows: its preview, or its opened start")
    func windowUserWeight() {
        let paste = text(7, 200_000, user: true)
        #expect(BeautifiedSessionView.renderWeight(paste) == TranscriptRow.chunkChars * 3 / 2)
        #expect(BeautifiedSessionView.renderWeight(paste, expanded: true) == TranscriptRow.expandedChars)
        let tool = TranscriptItem(id: 8, kind: .toolResult(tool: "bash", content: String(repeating: "y", count: 90_000),
                                                         isError: false), timestamp: nil)
        #expect(BeautifiedSessionView.renderWeight(tool) < 1_000)
    }

    @Test("An opened 200 KB message of yours lays out its start only; Copy keeps all of it")
    func expandedCap() {
        let whole = Self.pasteText(kb: 200)
        let item = TranscriptItem(id: 42, kind: .userText(whole), timestamp: nil)
        let layout = TranscriptRow.layout([item], expanded: [42])
        let shown = layout.rows.reduce(0) { n, row -> Int in
            if case .item(let i) = row, case .userText(let t) = i.kind { return n + t.utf16.count }
            return n
        }
        #expect(shown <= TranscriptRow.expandedChars)
        #expect(shown > TranscriptRow.expandedChars / 2)
        let bars = layout.longUsers.values.filter(\.controls)
        #expect(bars.count == 1)
        #expect(bars.first?.partial == true)
        #expect(bars.first?.whole == CodingTask.displayPrompt(whole))
        // A message that fits opens whole.
        let small = TranscriptItem(id: 43, kind: .userText(Self.pasteText(kb: 8)), timestamp: nil)
        let opened = TranscriptRow.layout([small], expanded: [43])
        #expect(opened.longUsers.values.contains { $0.controls && $0.expanded && !$0.partial })
    }

    @Test("A reply of many screens shows its start, with Show all; opened, all of it")
    func replyCap() {
        var reply = ""
        while reply.utf16.count < 150_000 { reply += "A paragraph about generators and `yield`, long enough to wrap twice in the chat.\n\n" }
        let item = TranscriptItem(id: 9, kind: .assistantText(reply), timestamp: nil)
        func shown(_ l: TranscriptLayout) -> Int {
            l.rows.reduce(0) { n, row in
                if case .item(let i) = row, case .assistantText(let t) = i.kind { return n + t.utf16.count }
                return n
            }
        }
        let closed = TranscriptRow.layout([item])
        #expect(shown(closed) <= TranscriptRow.expandedChars + TranscriptRow.chunkChars * TranscriptRow.hardCap)
        let bar = closed.longUsers[closed.rows.last!.id]
        #expect(bar?.controls == true && bar?.expanded == false && bar?.whole == reply)
        // Copy on any piece still takes the whole reply.
        #expect(closed.rows.allSatisfy { closed.replies[$0.id] == reply })
        let open = TranscriptRow.layout([item], expanded: [9])
        #expect(shown(open) >= reply.utf16.count - 4_000)
        #expect(open.longUsers[open.rows.last!.id]?.expanded == true)
        // The rows shown closed keep their ids opened (no jump).
        #expect(Array(open.rows.map(\.id).prefix(closed.rows.count)) == closed.rows.map(\.id))
        // An ordinary long reply has no bar.
        let normal = TranscriptRow.layout([TranscriptItem(id: 10, kind: .assistantText(String(reply.prefix(20_000))), timestamp: nil)])
        #expect(normal.longUsers.isEmpty)
    }

    // MARK: Row identity

    @Test("Rows of a QA-shaped omp transcript have unique ids, at every width and expansion")
    func rowIDsUnique() {
        let items = AgentTranscript.parse(Self.ompTranscript(), agent: "omp")
        #expect(items.count > 20)
        #expect(Set(items.map(\.id)).count == items.count)
        let users = Set(items.compactMap { i -> Int? in if case .userText = i.kind { i.id } else { nil } })
        for width in [180.0, 300, 480, 965] as [CGFloat] {
            for expanded in [Set<Int>(), users] {
                let rows = TranscriptRow.layout(items, chunkLimit: TranscriptRow.chunkLimit(forWidth: width),
                                                expanded: expanded).rows
                #expect(Set(rows.map(\.id)).count == rows.count, "duplicate row id at \(width) pt")
                #expect(rows.count > items.count / 3)
            }
        }
    }

    @Test("Row ids hold as the transcript grows and is re-read")
    func rowIDsStable() {
        let data = Self.ompTranscript(turns: 3)
        let lines = data.split(separator: UInt8(ascii: "\n"))
        // The transcript as polled part-way, then whole (the head re-read).
        let partial = Data(lines.prefix(lines.count - 6).joined(separator: [UInt8(ascii: "\n")])) + Data([0x0a])
        let before = TranscriptRow.layout(AgentTranscript.parse(partial, agent: "omp")).rows
        let after = TranscriptRow.layout(AgentTranscript.parse(data, agent: "omp")).rows
        let reread = TranscriptRow.layout(AgentTranscript.parse(data, agent: "omp")).rows
        #expect(after.map(\.id) == reread.map(\.id))
        // Every message row seen before keeps its id (a turn's "changes"
        // row and the open activity run may move on).
        let messageIDs = { (rows: [TranscriptRow]) -> [Int] in
            rows.compactMap { if case .item = $0 { $0.id } else { nil } }
        }
        let old = messageIDs(before)
        #expect(!old.isEmpty)
        #expect(Array(messageIDs(after).prefix(old.count)) == old)
    }
}
