import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// A board card, hosted in a real window, as assistive technology sees it:
/// one button element carrying the card's label, which presses the card.
@Suite("Board card accessibility")
@MainActor
struct CardAccessibilityTests {
    final class Pressed { var count = 0 }

    struct Card: View {
        let pressed: Pressed
        var body: some View {
            Button(action: {}) {
                VStack { Text("Workspace"); Text("Fix the login bug"); Text("Couldn't start") }
            }
            .buttonStyle(.plain)
            .modifier(CardAccessibility(label: "Fix the login bug, Workspace, Couldn't start",
                                        hint: "Open the task's live session",
                                        onPress: { pressed.count += 1 }))
        }
    }

    /// Every accessibility element under `root` (the informal protocol, as
    /// SwiftUI's nodes aren't all typed NSAccessibilityElements).
    private func elements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 12 else { return [] }
        let kids = ((root.accessibilityChildren?() ?? nil) ?? []).map { $0 as AnyObject }
        return kids + kids.flatMap { elements(under: $0, depth: depth + 1) }
    }

    @Test("the card is one button element named by its label, and pressing it opens the card")
    func cardIsNamedButton() throws {
        let app = NSApplication.shared
        // SwiftUI builds its accessibility tree only once an assistive
        // client asks for it — these are the attributes such clients set.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        // A window System Events can list (a test runner starts as a
        // background-only process).
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { if policy == .prohibited { app.setActivationPolicy(.prohibited) } }
        let pressed = Pressed()
        let host = NSHostingView(rootView: Card(pressed: pressed))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        _ = host.accessibilityChildren()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let all = elements(under: host)
        let labelled = all.filter { (($0.accessibilityLabel?() ?? nil) ?? "").contains("Fix the login bug") }
        try #require(labelled.count == 1, "one element carries the card's label, got \(all.count) elements")
        let card = labelled[0]
        #expect((card.accessibilityLabel?() ?? nil) == "Fix the login bug, Workspace, Couldn't start")
        #expect((card.accessibilityRole?() ?? nil) == .button)
        // Its texts are folded into the one element, not separate children.
        #expect(!all.contains { (($0.accessibilityLabel?() ?? nil) ?? "") == "Workspace" })
        _ = card.accessibilityPerformPress?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(pressed.count == 1)
        // An AppKit element, so the label is the PLAIN description
        // (AXDescription), not only an attributed one.
        let view = try #require(card as? CardAXView)
        #expect(view.accessibilityHelp() == "Open the task's live session")
        // Clicks go to the card underneath, not to the element.
        #expect(view.hitTest(NSPoint(x: 5, y: 5)) == nil)

        // Through the AX API, as System Events reads it — when this process
        // may use it (an untrusted test runner can't; skipped then).
        let axApp = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(axApp, 2)
        func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        func find(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if (attr(el, kAXDescriptionAttribute) as? String)?.contains("Fix the login bug") == true { return el }
            guard depth < 14, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for k in kids { if let hit = find(k, depth: depth + 1) { return hit } }
            return nil
        }
        // And as System Events reads it (osascript, when this runner may
        // drive it): a button whose plain description is the label.
        let js = """
        var se = Application('System Events');
        var p = se.processes.whose({unixId: \(getpid())})[0];
        function walk(e, d) {
          try { var t = e.description(); if (t && t.indexOf('Fix the login bug') >= 0) return e.role() + '|' + t; } catch (x) {}
          if (d > 14) return null;
          var k = []; try { k = e.uiElements(); } catch (x) {}
          for (var i = 0; i < k.length; i++) { var r = walk(k[i], d + 1); if (r) return r; }
          return null;
        }
        var w = p.windows(); if (!w.length) w = p.uiElements(); var out = null;
        for (var i = 0; i < w.length && !out; i++) out = walk(w[i], 0);
        out || ('NONE ' + w.length + ' ' + p.name() + ' ' + p.backgroundOnly());
        """
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-l", "JavaScript", "-e", js]
        let pipe = Pipe(), errPipe = Pipe()
        osa.standardOutput = pipe
        osa.standardError = errPipe
        if (try? osa.run()) != nil {
            let deadline = Date().addingTimeInterval(25)
            while osa.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if osa.isRunning { osa.terminate() }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if osa.terminationStatus == 0, !out.hasPrefix("NONE") {
                #expect(out == "AXButton|Fix the login bug, Workspace, Couldn't start")
            }
        }
        var probe: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(axApp, kAXRoleAttribute as CFString, &probe)
        if rc == .success {
            let el = try #require(find(axApp), "the card's AXDescription is readable through the AX API")
            #expect(attr(el, kAXRoleAttribute) as? String == kAXButtonRole)
            var names: CFArray?
            if AXUIElementCopyActionNames(el, &names) == .success {
                #expect((names as? [String] ?? []).contains(kAXPressAction))
            }
        }
    }
}
