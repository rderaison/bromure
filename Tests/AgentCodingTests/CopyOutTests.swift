import Foundation
import Testing
@testable import bromure_ac

@Suite("Copy-out")
struct CopyOutTests {
    private func item(_ id: Int, _ k: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: id, kind: k, timestamp: nil) }

    private func longReply(paragraphs: Int) -> String {
        (0..<paragraphs).map { "Paragraph \($0): " + String(repeating: "word ", count: 120) }
            .joined(separator: "\n\n")
    }

    @Test("Every piece of a long reply copies the whole reply", arguments: [500, 900, 1400, 2000])
    func everyPieceCopiesWhole(limit: Int) {
        let text = longReply(paragraphs: 40)
        let items = [item(1, .userText("hi")), item(7, .assistantText(text))]
        let rows = TranscriptRow.rows(items, chunkLimit: limit)
        let replies = TranscriptRow.replyTexts(items, chunkLimit: limit)
        let pieces = rows.compactMap { r -> TranscriptItem? in
            if case .item(let i) = r, case .assistantText = i.kind { return i } else { return nil }
        }
        #expect(pieces.count > 1)
        for p in pieces { #expect(replies[p.id] == text) }
        #expect(replies[1] == nil)   // a user turn isn't a reply
    }

    @Test("A short reply maps only its own id")
    func shortReply() {
        let replies = TranscriptRow.replyTexts([item(3, .assistantText("short"))])
        #expect(replies == [3: "short"])
    }

    @Test("Clip keeps short output whole and marks the cut")
    func clip() {
        #expect(TranscriptCopy.clip("abc", limit: 5).total == nil)
        #expect(TranscriptCopy.clip("abcde", limit: 5).total == nil)
        let c = TranscriptCopy.clip(String(repeating: "x", count: 25_000), limit: TranscriptCopy.outputLimit)
        #expect(c.shown.count == 20_000)
        #expect(c.total == 25_000)
        let marker = TranscriptCopy.truncationMarker(shown: 20_000, total: 25_000)
        #expect(marker.contains("Showing first"))
        let digits = marker.filter(\.isNumber)
        #expect(digits == "2000025000")
    }

    @Test("Reply plain text drops markdown syntax but keeps code and lines")
    func plainText() {
        let md = """
        # Title
        Some **bold** and *em* with `code` and [a link](https://example.com).
        > quoted
        - item one
        ```swift
        let x = **y**
        ```
        """
        let plain = TranscriptCopy.plainText(md)
        #expect(plain == """
        Title
        Some bold and em with code and a link.
        quoted
        - item one
        let x = **y**
        """)
    }

    @Test("Diff files keep their git text for Copy Diff")
    func diffPatch() {
        let raw = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        diff --git a/b.txt b/b.txt
        new file mode 100644
        --- /dev/null
        +++ b/b.txt
        @@ -0,0 +1 @@
        +hello

        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.count == 2)
        #expect(files[0].raw.hasPrefix("diff --git a/a.txt b/a.txt\nindex 1..2"))
        #expect(files[0].raw.hasSuffix("+new\n"))
        #expect(files[1].raw.contains("--- /dev/null"))
        #expect(TaskDiffFile.patch(of: files) == raw)
        // Built by hand (no git text): a minimal header over the lines.
        let bare = TaskDiffFile(path: "c.txt", lines: [.init(id: 1, kind: .added, text: "+x", newLine: 1)])
        #expect(bare.patch == "diff --git a/c.txt b/c.txt\n--- a/c.txt\n+++ b/c.txt\n+x\n")
    }

    @Test("Pane history capture reads the whole tmux history into a file")
    func captureCommand() {
        let path = PaneHistory.capturePath(token: "t1")
        #expect(path == "/tmp/bromure-pane-history-t1.txt")
        #expect(PaneHistory.captureCommand(window: 3, path: path)
                == "tmux capture-pane -p -J -S - -t 'bromure:3' > '/tmp/bromure-pane-history-t1.txt' 2>/dev/null && wc -c < '/tmp/bromure-pane-history-t1.txt'")
        #expect(PaneHistory.cleanupCommand(path: path) == "rm -f '/tmp/bromure-pane-history-t1.txt'")
    }

    @Test("Pane history drops the blank screen rows and counts lines")
    func normalizeAndCount() {
        let t = PaneHistory.normalized("a\nb\n\n   \n\n")
        #expect(t == "a\nb\n")
        #expect(PaneHistory.lineCount(t) == 2)
        #expect(PaneHistory.lineCount("") == 0)
        #expect(PaneHistory.lineCount("one") == 1)
        #expect(PaneHistory.normalized("\n\n") == "")
        #expect(PaneHistory.copiedMessage(lines: 1) == "Copied 1 line")
    }

    @Test("Pane history comes over the file channel, then the file is removed")
    func captureFlow() async {
        var commands: [String] = []
        let body = String(repeating: "line\n", count: 10)
        let text = await PaneHistory.capture(window: 2, exec: { cmd in
            commands.append(cmd); return "50\n"
        }, fileOp: { op in
            #expect(op["op"] as? String == "read")
            return ["data": Data(body.utf8).base64EncodedString(), "eof": true, "size": 50]
        })
        #expect(text == body)
        #expect(commands.count == 2)
        #expect(commands[0].hasPrefix("tmux capture-pane -p -J -S - -t 'bromure:2'"))
        #expect(commands[1].hasPrefix("rm -f '/tmp/bromure-pane-history-"))
    }

    @Test("Without a file channel, the capture is read with cat")
    func captureFallback() async {
        var commands: [String] = []
        let text = await PaneHistory.capture(window: 0, exec: { cmd in
            commands.append(cmd); return cmd.hasPrefix("cat ") ? "hello\n" : "6\n"
        }, fileOp: { _ in throw CancellationError() })
        #expect(text == "hello\n")
        #expect(commands.count == 3)
    }
}
