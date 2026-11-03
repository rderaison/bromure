#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Board report: a 24-task batch merge listed every title in its
/// confirmation alert, which grew past the screen — Merge & Push out of
/// sight, and no key for it. The sheet's list scrolls, so its height is
/// bounded however many tasks are approved.
@Suite("Batch merge sheet")
@MainActor
struct BatchMergeSheetTests {
    static let english = (cancel: "Cancel", merge: "Merge", push: "Merge & Push")
    static let german = (cancel: "Abbrechen", merge: "Zusammenführen", push: "Zusammenführen & pushen")

    private func size(_ n: Int, labels: (cancel: String, merge: String, push: String) = english) -> NSSize {
        let titles = (1...n).map { "Fix: task number \($0) with a title long enough to wrap onto a second line in the list" }
        let view = NSHostingView(rootView: BatchMergeSheet(titles: titles, targets: ["main"], agentName: "Agent",
                                                           onCancel: {}, onConfirm: { _ in }, labels: labels))
        return view.fittingSize
    }
    private func height(_ n: Int) -> CGFloat { size(n).height }

    @Test("a long batch doesn't grow the sheet past a screen; a short one still shows its list")
    func bounded() {
        let few = height(3), many = height(24), huge = height(200)
        #expect(few > 150)            // title, text, three rows, buttons
        #expect(many < 600)
        #expect(abs(huge - many) < 1) // capped: more titles scroll, they don't grow it
        #expect(many > few)
    }

    /// Review: three buttons in one row ran past the sheet's 460 points in
    /// German, Merge & Push the one clipped.
    @Test("labels too long for one row stack instead of running off the sheet")
    func longLabelsStack() {
        let en = size(3), de = size(3, labels: Self.german)
        #expect(de.width == en.width)   // still the sheet's width: nothing pushed past it
        #expect(de.height > en.height + 30)   // the buttons went to their own lines
    }
}
#endif
