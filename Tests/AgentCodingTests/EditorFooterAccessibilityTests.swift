import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// The workspace editor's Save / Cancel as UI scripting reads them. Out of
/// process, a SwiftUI Button's name is only an AXAttributedDescription:
/// System Events saw name "missing value", description "button" (the role
/// description) for both, whatever label modifiers the buttons had. Each
/// now has an AppKit element standing in for it with a PLAIN AXDescription.
@Suite("Editor footer accessibility")
@MainActor
struct EditorFooterAccessibilityTests {
    private func elements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let kids = ((root.accessibilityChildren?() ?? nil) ?? []).map { $0 as AnyObject }
        return kids + kids.flatMap { elements(under: $0, depth: depth + 1) }
    }

    @Test("Save and Cancel are buttons with a plain description, and pressable")
    func footerButtonsAreNamed() throws {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        app.finishLaunching()
        defer { if policy == .prohibited { app.setActivationPolicy(.prohibited) } }
        final class Calls { var save = 0; var cancel = 0 }
        let calls = Calls()
        let view = ProfileEditorView(profile: Profile(name: "QA-footer", tool: .claude, authMode: .token), isNew: false,
                                     terminalDefaults: .fallback, storageContext: nil,
                                     onSave: { _, _ in calls.save += 1 }, onCancel: { calls.cancel += 1 })
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "QA-footer-ax"
        win.contentView = host
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        _ = host.accessibilityChildren()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let all = elements(under: win)
        let plain = all.compactMap { $0 as? CardAXView }
        let save = try #require(plain.first { $0.accessibilityLabel() == "Save" }, "an AppKit Save element")
        let cancel = try #require(plain.first { $0.accessibilityLabel() == "Cancel" }, "an AppKit Cancel element")
        #expect(save.accessibilityRole() == .button)
        #expect(save.accessibilityIdentifier() == "profileEditor.save")
        #expect(cancel.accessibilityIdentifier() == "profileEditor.cancel")
        #expect(cancel.accessibilityHelp() == "Closes the editor without saving changes")
        // The SwiftUI copies are out of the tree: one "Save", not two.
        #expect(all.filter { (($0.accessibilityLabel?() ?? nil) ?? "") == "Save" }.count == 1)
        _ = cancel.accessibilityPerformPress()
        _ = save.accessibilityPerformPress()
        #expect(calls.cancel == 1)
        #expect(calls.save == 1)

        // As System Events reads it, when this runner may drive it.
        let js = """
        var se = Application('System Events');
        var p = se.processes.whose({unixId: \(getpid())})[0];
        var ws = p.windows(); var w = null;
        for (var j = 0; j < ws.length; j++) { try { if (ws[j].name() === 'QA-footer-ax') w = ws[j]; } catch (x) {} }
        var out = [];
        function walk(e, d) {
          try { if (e.role() === 'AXButton') { var t = e.description(); if (t === 'Save' || t === 'Cancel') out.push(t); } } catch (x) {}
          if (d > 40) return;
          var k = []; try { k = e.uiElements(); } catch (x) {}
          for (var i = 0; i < k.length; i++) walk(k[i], d + 1);
        }
        var res;
        try { if (!w) throw 'no window ' + ws.length; walk(w, 0); res = out.sort().join(','); } catch (x) { res = 'NONE ' + x; }
        res;
        """
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-l", "JavaScript", "-e", js]
        let pipe = Pipe()
        osa.standardOutput = pipe
        osa.standardError = Pipe()
        if (try? osa.run()) != nil {
            let deadline = Date().addingTimeInterval(40)
            while osa.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if osa.isRunning { osa.terminate() }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if osa.terminationStatus == 0, !out.isEmpty, !out.hasPrefix("NONE") {
                #expect(out == "Cancel,Save")
            }
        }
    }
}
