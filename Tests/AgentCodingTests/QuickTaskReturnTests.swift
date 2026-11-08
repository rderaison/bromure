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

    /// Lets the panel settle. Awaited: a nested run loop would hold the main
    /// queue, and every main-actor test in the run, for as long as it spins.
    private func spin(_ s: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private func key(_ p: NSWindow, _ ch: String, code: UInt16, mods: NSEvent.ModifierFlags = []) async {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: 0,
                                     windowNumber: p.windowNumber, context: nil, characters: ch,
                                     charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
        }
        await spin(0.1)
    }

    /// Summoned from another app, the list spans machines (QuickTaskMachinesTests):
    /// a machine's name narrows it to that machine's sessions. Here, as its
    /// keys mustn't race this suite's.
    @Test("typing a machine's name narrows the @ list to its sessions; ↩ picks one there")
    func pickOnHost() async {
        _ = NSApplication.shared
        func session(_ label: String, _ ws: String) -> TaskAssigneeChoices.Session {
            .init(id: UUID(), label: label, workspace: ws, busy: false, profileID: UUID())
        }
        func target(_ key: String, _ machine: String, _ s: [TaskAssigneeChoices.Session]) -> QuickTaskPanel.Target {
            QuickTaskPanel.Target(key: key, machine: machine, profiles: [],
                                  choices: TaskAssigneeChoices(sessions: s, rooms: []), current: nil,
                                  label: { $0.title }, save: { _ in }, assign: { _, _ in }, plan: { _ in })
        }
        let lux = session("@lux", "Storefront"), mine = session("@notes", "Personal")
        let all = QuickTaskPanel.merged([target("local", "This Mac", [mine]), target("host-1", "Mac Studio", [lux])])
        var added: [(String, TaskAssignment?)] = []
        let view = QuickTaskView(choices: all, here: nil, folder: "~", workspaceName: "Personal",
                                 initialAssignment: nil,
                                 onAdd: { t, _, a, _ in added.append((t, a)) }, onClose: {})
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view.padding(.top, 16)
            .frame(width: 800, height: 700, alignment: .top))
        p.makeKeyAndOrderFront(nil)
        await spin(0.5)
        for c in "ship it @studio" { await key(p, String(c), code: c == " " ? 49 : 0) }
        await key(p, "\r", code: 36)    // picks the highlighted row: the host's only session
        await key(p, "\r", code: 36)    // adds
        #expect(added.count == 1)
        #expect(added.first?.0 == "ship it")
        #expect(added.first?.1?.id == lux.id)
        p.orderOut(nil)
    }

    @Test("typed title + ↩ reaches onAdd")
    func returnAdds() async {
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
        await spin(0.5)
        for c in "fix it" { await key(p, String(c), code: 0) }
        await key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["fix it"])
        p.orderOut(nil)
    }

    /// Board report: one ⇥ opens Details, and ↩ there did nothing — the
    /// only way on was ⇥⇥ into the full editor.
    @Test("↩ in Details adds the task; ⌘↩ adds and keeps going; ⌥↩ is a new line")
    func returnInDetailsAdds() async {
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
        await spin(0.5)
        for c in "one" { await key(p, String(c), code: 0) }
        await key(p, "\t", code: 48)
        await spin(0.3)
        for c in "a" { await key(p, String(c), code: 0) }
        await key(p, "\r", code: 36, mods: .option)
        for c in "b" { await key(p, String(c), code: 0) }
        await key(p, "\r", code: 36, mods: .command)
        // Kept open, title focused again: a second one, details and ↩.
        for c in "two" { await key(p, String(c), code: 0) }
        await key(p, "\t", code: 48)
        await spin(0.3)
        for c in "c" { await key(p, String(c), code: 0) }
        // An input method still composing: its ↩ is the IME's, not an add.
        let editor = p.firstResponder as? NSTextView
        editor?.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(QuickTaskView.composing(in: p))
        editor?.unmarkText()
        #expect(!QuickTaskView.composing(in: p))
        await key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["one", "two"])
        #expect(added.map(\.1) == ["a\nb", "cか"])
        #expect(added.map(\.2) == [true, false])
        p.orderOut(nil)
    }

    /// Review: with the title's @ list still open, ↩ in Details filed the
    /// task with "@" left in its title instead of picking.
    @Test("↩ in Details with the @ list open picks the assignee first")
    func returnInDetailsPicksSuggestion() async {
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
        await spin(0.5)
        for c in "one" { await key(p, String(c), code: 0) }
        await key(p, "\t", code: 48)
        await spin(0.3)
        func fields(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields)
        }
        let all = fields(p.contentView!).filter(\.isEditable)
        #expect(all.count == 2)
        guard all.count == 2 else { return }
        // Back to the title for an @ (the list opens), then a click into
        // Details. (Focusing the title selects it: type it whole.)
        p.makeFirstResponder(all[0])
        await spin(0.2)
        for c in "one @" { await key(p, String(c), code: 0) }
        p.makeFirstResponder(all[1])
        await spin(0.2)
        await key(p, "\r", code: 36)
        #expect(added.isEmpty)
        await key(p, "\r", code: 36)
        #expect(added.map(\.0) == ["one"])
        #expect(added.first?.1 == .newAgent)
        p.orderOut(nil)
    }

    /// Finding (CWE-670): ↩ in Details filed the task under the old chip
    /// while the @ list was open — and ⌘↩ in the title still did: neither
    /// picked the highlighted row, the "@" left in the title.
    @Test("⌘↩ in the title with the @ list open picks first, like ↩")
    func commandReturnInTitlePicksSuggestion() async {
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
        await spin(0.5)
        for c in "one @" { await key(p, String(c), code: 0) }
        await key(p, "\r", code: 36, mods: .command)
        #expect(added.isEmpty)
        await key(p, "\r", code: 36, mods: .command)
        #expect(added.map(\.0) == ["one"])
        #expect(added.first?.1 == .newAgent)
        #expect(added.first?.2 == true)
        p.orderOut(nil)
    }
}
