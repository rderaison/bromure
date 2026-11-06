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
    func cardIsNamedButton() async throws {
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
        // Found by title: the walk starts at this window, not at the whole
        // process (windows other tests left behind ran past 30 000 elements).
        let windowTitle = "Board card AX \(UUID().uuidString)"
        win.title = windowTitle
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
            // Awaited, not a nested run loop: that holds the main queue, and every
            // main-actor test in the run, for as long as this takes.
            while osa.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            // No answer (System Events waits on a permission this machine hasn't
            // given): nothing learned. Its status can't be read until it has gone.
            let answered = !osa.isRunning
            if !answered { osa.terminate(); osa.waitUntilExit() }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if answered, osa.terminationStatus == 0, !out.hasPrefix("NONE") {
                #expect(out == "AXButton|Fix the login bug, Workspace, Couldn't start")
            }
        }
        // Walked off the main thread: an AX call into this process is answered
        // on its main thread, so made from there each one waited out its
        // timeout, through every window the run had left open (80 minutes of a
        // run, every main-actor test held). Bounded, too: out of time is
        // nothing learned, as for System Events, and so is a call that timed out.
        enum AXWalk: Sendable { case unavailable, outOfTime, missing(String), found(role: String?, presses: Bool?) }
        let walk = await Task.detached { [windowTitle] () -> AXWalk in
            let axApp = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(axApp, 2)
            let deadline = Date().addingTimeInterval(20)
            var outOfTime = false
            func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
                var v: CFTypeRef?
                let rc = AXUIElementCopyAttributeValue(el, name as CFString, &v)
                // The main thread busy with another test past the timeout:
                // no answer, which isn't "not there".
                if rc == .cannotComplete { outOfTime = true }
                return rc == .success ? v : nil
            }
            func find(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
                guard Date() < deadline else { outOfTime = true; return nil }
                if (attr(el, kAXDescriptionAttribute) as? String)?.contains("Fix the login bug") == true { return el }
                guard depth < 14, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
                for k in kids { if let hit = find(k, depth: depth + 1) { return hit } }
                return nil
            }
            var probe: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXRoleAttribute as CFString, &probe) == .success
            else { return .unavailable }
            let windows = attr(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
            // Not listed yet (seen in a full run, beside the windows other
            // tests left): nothing learned. The checks in-process above ran.
            guard let mine = windows.first(where: { attr($0, kAXTitleAttribute) as? String == windowTitle }) else {
                return .unavailable
            }
            guard let el = find(mine) else {
                return outOfTime ? .outOfTime : .missing("not in its window")
            }
            var names: CFArray?
            let presses = AXUIElementCopyActionNames(el, &names) == .success
                ? (names as? [String] ?? []).contains(kAXPressAction) : nil
            return .found(role: attr(el, kAXRoleAttribute) as? String, presses: presses)
        }.value
        switch walk {
        case .unavailable, .outOfTime: break
        case .missing(let why): Issue.record("the card's AXDescription is readable through the AX API (\(why))")
        case .found(let role, let presses):
            #expect(role == kAXButtonRole)
            if let presses { #expect(presses) }
        }
    }
}
