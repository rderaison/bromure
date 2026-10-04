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
    }
}
