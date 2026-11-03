import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Issue #52: the session view's input box "violently vibrated" — with
/// legacy scroll bars (shown "Always", or a mouse attached) it flipped
/// between two heights on every layout pass. The scroller, kept on below
/// the line cap, took width from the text: a line more wanted, the frame
/// grew, the scroller left, a line less wanted, the frame shrank, the
/// scroller came back. It now shows only once the text is past the cap.
@Suite("Composer: a steady height with legacy scroll bars", .serialized)
@MainActor
struct ComposerHeightJitterTests {
    private final class Probe: ObservableObject {
        @Published var text = ""
        var changes = 0
    }

    private struct Host: View {
        @ObservedObject var probe: Probe
        @State private var height: CGFloat = 24
        @State private var focused = false
        var body: some View {
            ComposerTextView(text: $probe.text, placeholder: "Ask", height: $height, focused: $focused)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .onChange(of: height) { _ in probe.changes += 1 }
                .frame(width: 396)
        }
    }

    /// Runs the run loop and lets the main queue drain too: the composer
    /// moves its height and scroller from `DispatchQueue.main.async`, which
    /// a nested run loop inside a main-queue test never reaches.
    private func spin(_ s: TimeInterval) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView is ComposerNSTextView { return s }
        for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }

    @Test("no word count near the line cap sets the height flipping; past it, the text scrolls")
    func steadyHeight() async throws {
        _ = NSApplication.shared
        let probe = Probe()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Host(probe: probe))
        w.orderFrontRegardless()
        await spin(0.3)
        let scroll = try #require(scrollView(in: w.contentView!))
        scroll.scrollerStyle = .legacy   // what a mouse or "Always" gives

        let vocab = ["alpha", "be", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"]
        let words = (0..<260).map { vocab[$0 % vocab.count] }
        var flipping: [Int] = []
        // 1 to 12 lines and past them, at this width (the issue's range sits
        // just under the cap).
        for n in stride(from: 80, through: 140, by: 2) {
            probe.text = words.prefix(n).joined(separator: " ")
            await spin(0.12)
            probe.changes = 0
            await spin(0.2)
            if probe.changes > 2 { flipping.append(n) }
        }
        #expect(flipping.isEmpty, "height kept changing at \(flipping) words")
        #expect(scroll.frame.height > 200)   // the sweep did grow the box

        probe.text = words.joined(separator: " ")
        await spin(0.3)
        #expect(scroll.hasVerticalScroller)
        #expect((scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height)
        probe.text = "short"
        await spin(0.3)
        #expect(!scroll.hasVerticalScroller)
        w.orderOut(nil)
    }
}
