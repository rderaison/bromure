import Foundation
import Testing
@testable import bromure_ac

/// P0 (omp QA): a 5–20 KB paste into the chat composer, or a send, froze the
/// app — the transcript's `defaultScrollAnchor(.bottom)` looped placing its
/// lazy rows whenever the content or the viewport changed size. The layout
/// itself is checked by `bromure-ac __bench-scroll <fixture> --chat --composer
/// --working --paste 20 --send` (exits 3 on a hang); these guard the rest of
/// what a big paste and its send cost on the main thread.
@Suite("Composer: a big paste and its send stay cheap")
struct ComposerPasteFreezeTests {
    private static func paste(kb: Int) -> String {
        ChatLayoutCheck.pasteFixture(kb: kb)
    }

    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func seconds(_ body: () -> Void) -> Double {
        let t0 = Date()
        body()
        return Date().timeIntervalSince(t0)
    }

    @Test("The chat transcript never sets a bottom scroll anchor (the layout loop)")
    func noBottomAnchor() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift")
        let code = try String(contentsOf: src, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains(".defaultScrollAnchor("))
        // The caret blinks off a timeline, not a repeat-forever animation
        // (it re-laid the whole lazy transcript out every frame).
        #expect(!code.contains("repeatForever"))
    }

    @Test("A 200 KB paste naming no offered file is left alone at once")
    func bigPasteNoOfferedName() throws {
        let file = try tempFile("dropped-shot.png")
        let text = Self.paste(kb: 200)
        var result: (text: String, files: [DroppedFile]) = ("", [])
        let t = seconds { result = DroppedFile.absorbHostPaths(in: text, offered: [file.path]) }
        #expect(result.files.isEmpty)
        #expect(result.text.utf8.count == text.utf8.count)
        #expect(DroppedFile.pathCandidates(in: text, offered: [file.path]).isEmpty)
        #expect(t < 0.5, "absorbHostPaths took \(t) s on 200 KB")
    }

    @Test("A path dropped into a 200 KB text is still found, fast")
    func bigPasteWithPath() throws {
        let file = try tempFile("dropped-shot.png")
        let text = Self.paste(kb: 100) + "look at " + file.path + "\n" + Self.paste(kb: 100)
        var result: (text: String, files: [DroppedFile]) = ("", [])
        let t = seconds { result = DroppedFile.absorbHostPaths(in: text, offered: [file.path]) }
        #expect(result.files.map(\.name) == ["dropped-shot.png"])
        #expect(!result.text.contains(file.path))
        #expect(t < 2, "absorbHostPaths took \(t) s on 200 KB with a path")
    }

    @Test("A file:// URL with an escaped name still counts as naming the file")
    func escapedName() throws {
        let file = try tempFile("red square.png")
        let url = URL(fileURLWithPath: file.path).absoluteString
        let (text, files) = DroppedFile.absorbHostPaths(in: "see " + url, offered: [file.path])
        #expect(files.map(\.name) == ["red square.png"])
        #expect(text == "see")
    }

    @Test("The pasteboards are read again only when one of them changed")
    func offeredPathsCached() {
        let cache = DroppedFile.OfferedPathsCache()
        var reads = 0
        let read = { () -> Set<String> in reads += 1; return ["/tmp/a.png"] }
        #expect(cache.get(counts: [3, 7], read: read) == ["/tmp/a.png"])
        for _ in 0..<1000 { _ = cache.get(counts: [3, 7], read: read) }
        #expect(reads == 1)
        _ = cache.get(counts: [3, 8], read: read)   // a copy elsewhere
        #expect(reads == 2)
        _ = cache.get(counts: [4, 8], read: read)   // a drag
        #expect(reads == 3)
    }

    @Test("Composer text compares byte for byte, fast, on a 200 KB accented paste")
    func composerTextCompare() {
        let a = Self.paste(kb: 200)
        // As NSTextView hands it over: bridged from its (mutable) storage.
        let bridged = NSMutableString(string: a) as String
        let native = ComposerText.native(bridged)
        #expect(ComposerText.same(a, native))
        #expect(!ComposerText.same(a, native + "x"))
        #expect(!ComposerText.same(a, String(a.dropLast()) + "y"))
        #expect(ComposerText.same("", ""))
        // Composed vs decomposed "é": a different text for the field.
        #expect(!ComposerText.same("caf\u{e9}", "cafe\u{301}"))
        var same = true
        let t = seconds { for _ in 0..<50 { same = same && ComposerText.same(a, native) } }
        #expect(same)
        #expect(t < 0.5, "50 compares of 200 KB took \(t) s")
    }

    @Test("A sent 200 KB echo is matched against a long conversation in one pass")
    func echoKeysOncePerText() {
        let echo = Self.paste(kb: 200)
        let turns = (0..<200).map { "turn \($0): " + String(repeating: "word ", count: 200) }
        let key = BeautifiedSessionModel.EchoKey(echo)
        let keys = (turns + [echo]).map(BeautifiedSessionModel.EchoKey.init)
        var hit = false
        let t = seconds { hit = keys.contains { key.matches($0) } }
        #expect(hit)
        #expect(t < 0.5, "matching took \(t) s")
        // The rules are echoMatches' own.
        #expect(BeautifiedSessionModel.echoMatches("a\r\nb", recorded: "a\nb"))
        #expect(BeautifiedSessionModel.echoMatches("caf\u{e9}", recorded: "cafe\u{301}"))
        #expect(!BeautifiedSessionModel.echoMatches("hello world", recorded: "hello"))
    }
}
