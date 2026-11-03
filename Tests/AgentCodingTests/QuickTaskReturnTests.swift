import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

@Suite("Quick task: Return adds", .serialized)
@MainActor
struct QuickTaskReturnTests {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func spin(_ s: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(s))
    }

    private func key(_ p: NSWindow, _ ch: String, code: UInt16, mods: NSEvent.ModifierFlags = []) {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: 0,
                                     windowNumber: p.windowNumber, context: nil, characters: ch,
                                     charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
        }
        spin(0.1)
    }

    @Test("typed title + ↩ reaches onAdd")
    func returnAdds() {
        _ = NSApplication.shared
        var added: [(String, Bool)] = []
        let view = QuickTaskView(choices: TaskAssigneeChoices(sessions: [], rooms: []), here: nil,
                                 folder: "~", workspaceName: "W", initialAssignment: nil,
                                 onAdd: { t, _, _, keep in added.append((t, keep)) }, onClose: {})
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view.padding(.top, 16)
            .frame(width: 800, height: 700, alignment: .top))
        p.makeKeyAndOrderFront(nil)
        spin(0.5)
        for c in "fix it" { key(p, String(c), code: 0) }
        key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["fix it"])
        p.orderOut(nil)
    }

    /// Board report: one ⇥ opens Details, and ↩ there did nothing — the
    /// only way on was ⇥⇥ into the full editor.
    @Test("↩ in Details adds the task; ⌘↩ adds and keeps going; ⌥↩ is a new line")
    func returnInDetailsAdds() {
        _ = NSApplication.shared
        var added: [(String, String, Bool)] = []
        let view = QuickTaskView(choices: TaskAssigneeChoices(sessions: [], rooms: []), here: nil,
                                 folder: "~", workspaceName: "W", initialAssignment: nil,
                                 onAdd: { t, d, _, keep in added.append((t, d, keep)) }, onClose: {})
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view.padding(.top, 16)
            .frame(width: 800, height: 700, alignment: .top))
        p.makeKeyAndOrderFront(nil)
        spin(0.5)
        for c in "one" { key(p, String(c), code: 0) }
        key(p, "\t", code: 48)
        spin(0.3)
        for c in "a" { key(p, String(c), code: 0) }
        key(p, "\r", code: 36, mods: .option)
        for c in "b" { key(p, String(c), code: 0) }
        key(p, "\r", code: 36, mods: .command)
        // Kept open, title focused again: a second one, details and ↩.
        for c in "two" { key(p, String(c), code: 0) }
        key(p, "\t", code: 48)
        spin(0.3)
        for c in "c" { key(p, String(c), code: 0) }
        // An input method still composing: its ↩ is the IME's, not an add.
        let editor = p.firstResponder as? NSTextView
        editor?.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(QuickTaskView.composing(in: p))
        editor?.unmarkText()
        #expect(!QuickTaskView.composing(in: p))
        key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["one", "two"])
        #expect(added.map(\.1) == ["a\nb", "cか"])
        #expect(added.map(\.2) == [true, false])
        p.orderOut(nil)
    }

    /// Review: with the title's @ list still open, ↩ in Details filed the
    /// task with "@" left in its title instead of picking.
    @Test("↩ in Details with the @ list open picks the assignee first")
    func returnInDetailsPicksSuggestion() {
        _ = NSApplication.shared
        var added: [(String, TaskAssignment?)] = []
        let view = QuickTaskView(choices: TaskAssigneeChoices(sessions: [], rooms: []), here: nil,
                                 folder: "~", workspaceName: "W", initialAssignment: nil,
                                 onAdd: { t, _, a, _ in added.append((t, a)) }, onClose: {})
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view.padding(.top, 16)
            .frame(width: 800, height: 700, alignment: .top))
        p.makeKeyAndOrderFront(nil)
        spin(0.5)
        for c in "one" { key(p, String(c), code: 0) }
        key(p, "\t", code: 48)
        spin(0.3)
        func fields(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields)
        }
        let all = fields(p.contentView!).filter(\.isEditable)
        #expect(all.count == 2)
        guard all.count == 2 else { return }
        // Back to the title for an @ (the list opens), then a click into
        // Details. (Focusing the title selects it: type it whole.)
        p.makeFirstResponder(all[0])
        spin(0.2)
        for c in "one @" { key(p, String(c), code: 0) }
        p.makeFirstResponder(all[1])
        spin(0.2)
        key(p, "\r", code: 36)
        #expect(added.isEmpty)
        key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["one"])
        #expect(added.first?.1 == .newAgent)
        p.orderOut(nil)
    }

    /// Finding (CWE-670): ↩ in Details filed the task under the old chip
    /// while the @ list was open — and ⌘↩ in the title still did: neither
    /// picked the highlighted row, the "@" left in the title.
    @Test("⌘↩ in the title with the @ list open picks first, like ↩")
    func commandReturnInTitlePicksSuggestion() {
        _ = NSApplication.shared
        var added: [(String, TaskAssignment?, Bool)] = []
        let view = QuickTaskView(choices: TaskAssigneeChoices(sessions: [], rooms: []), here: nil,
                                 folder: "~", workspaceName: "W", initialAssignment: nil,
                                 onAdd: { t, _, a, k in added.append((t, a, k)) }, onClose: {})
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view.padding(.top, 16)
            .frame(width: 800, height: 700, alignment: .top))
        p.makeKeyAndOrderFront(nil)
        spin(0.5)
        for c in "one @" { key(p, String(c), code: 0) }
        key(p, "\r", code: 36, mods: .command)
        #expect(added.isEmpty)
        key(p, "\r", code: 36, mods: .command)
        #expect(added.map(\.0) == ["one"])
        #expect(added.first?.1 == .newAgent)
        #expect(added.first?.2 == true)
        p.orderOut(nil)
    }
}
