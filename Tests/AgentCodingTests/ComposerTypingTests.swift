import Combine
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: typing in the chat has a small lag. A keystroke ran SwiftUI's graph
/// over the composer and the chat around it, growing with the transcript. The
/// text view had already drawn the letter: nothing should update unless what
/// the chat shows has changed.
@Suite("Typing in the composer")
@MainActor
struct ComposerTypingTests {
    /// How many times the store told SwiftUI to update during `body`.
    private func updates(_ store: ComposerTextStore, during body: () -> Void) -> Int {
        var n = 0
        let sub = store.objectWillChange.sink { n += 1 }
        body()
        sub.cancel()
        return n
    }

    @Test("ordinary typing updates nothing")
    func ordinary() {
        let s = ComposerTextStore()
        s.typed("h")
        let n = updates(s) { for t in ["he", "hel", "hell", "hello", "hello ", "hello w"] { s.typed(t) } }
        #expect(n == 0)
        #expect(s.text == "hello w")
    }

    @Test("the send button hears when there's something to send, and when there's nothing again")
    func sendButton() {
        let s = ComposerTextStore()
        #expect(s.shape.blank)
        #expect(updates(s) { s.typed("  ") } == 0, "only spaces: still nothing to send")
        #expect(updates(s) { s.typed("  a") } == 1)
        #expect(!s.shape.blank)
        #expect(updates(s) { s.typed("") } == 1)
        #expect(s.shape.blank)
    }

    @Test("the palettes follow what's typed, each key, while they're up")
    func palettes() {
        let s = ComposerTextStore()
        s.typed("/")
        #expect(s.shape.palette == "")
        #expect(updates(s) { s.typed("/co") } == 1)
        #expect(s.shape.palette == "co")
        s.typed("/compact now")
        #expect(s.shape.palette == nil, "the command is chosen")
        s.typed("ask @sec")
        #expect(s.shape.mention == "sec")
        s.typed("ask @sec to")
        #expect(s.shape.mention == nil)
        s.typed("line\n/not")
        #expect(s.shape.palette == nil)
        s.typed("/co\nmore")
        #expect(s.shape.palette == nil, "a newline closes the palette")
    }

    @Test("text replaced from outside always reaches the field, even with the same shape")
    func replaced() {
        let s = ComposerTextStore()
        s.typed("abc")
        #expect(updates(s) { s.replace("def") } >= 1, "same shape, different words")
        #expect(s.text == "def")
        let before = s.replacements
        s.typed("defg")
        #expect(s.replacements == before, "typing isn't a replacement")
    }

    private final class Provider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        func activeTabIndex() -> Int? { nil }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? { nil }
    }

    @Test("what's typed goes in the draft, and setting the text replaces it")
    func model() {
        let m = BeautifiedSessionModel(provider: Provider())
        let key = "composer-typing-\(UUID().uuidString)"
        m.draftKey = key
        m.composerTyped("hello")
        #expect(m.composerText == "hello")
        #expect(ComposerDrafts[key].text == "hello")
        let n = updates(m.composer) { m.composerText = "other" }
        #expect(n >= 1)
        #expect(ComposerDrafts[key].text == "other")
        m.composerText = ""
    }

    @Test("a key typed isn't taken for a drop; a path dropped is, wherever and over whatever it lands")
    func dropDetection() {
        let drop = { ComposerText.mayBeDrop(from: $0, to: $1) }
        #expect(!drop("hell", "hello"))
        #expect(!drop("hello", "hell"), "backspace")
        #expect(!drop("hllo", "hello"), "typed in the middle")
        #expect(!drop("aaaa", "aaaaa"), "repeats don't confuse it")
        #expect(!drop("cafe", "café"))
        #expect(!drop("hi", "hi🙂"))
        #expect(drop("", "/tmp/a.png"))
        #expect(drop("look at  now", "look at /tmp/a.png now"))
        #expect(drop("a very long selection replaced by a short path", "/tmp/a"), "the text got shorter")
        #expect(!drop("same", "same"))
    }

    /// The real chat view in a window: the field and the store stay in step
    /// though typing no longer re-renders anything.
    @Test("the real field: typing reaches the model, and replacing reaches the field")
    func realField() throws {
        let m = BeautifiedSessionModel(provider: Provider())
        let host = NSHostingView(rootView: BeautifiedSessionView(model: m))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func pump() {
            for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
        }
        func field(_ v: NSView) -> ComposerNSTextView? {
            if let t = v as? ComposerNSTextView { return t }
            for sub in v.subviews { if let t = field(sub) { return t } }
            return nil
        }
        pump()
        let tv = try #require(field(host))
        tv.insertText("hello", replacementRange: tv.selectedRange())
        pump()
        #expect(m.composerText == "hello")
        tv.insertText(" world", replacementRange: tv.selectedRange())
        #expect(m.composerText == "hello world", "the model knows at once, with no update pass")
        // Same shape as before: only the replacement can tell the field.
        m.composerText = "replaced text"
        pump()
        #expect(tv.string == "replaced text")
        m.composerText = ""
        pump()
        #expect(tv.string.isEmpty)
    }
}
