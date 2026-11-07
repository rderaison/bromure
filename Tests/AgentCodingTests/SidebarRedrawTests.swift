import Foundation
import Testing
import SwiftUI
import AppKit
@testable import bromure_ac

@Suite("What animates in the sidebar doesn't make it re-measure")
struct SidebarRedrawTests {
    /// Counts how often SwiftUI measures what it wraps.
    final class Count: @unchecked Sendable { var n = 0 }
    struct Probe: Layout {
        let count: Count
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            count.n += 1
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
        }
    }

    /// Measure passes over 1.5 s of `rows` rows, each showing `v`, hosted with default sizing like the sidebar.
    @MainActor private func measures<V: View>(_ v: V, rows: Int = 20) async -> Int {
        let count = Count()
        let host = NSHostingView(rootView: Probe(count: count) {
            VStack { ForEach(0..<rows, id: \.self) { _ in HStack { v; Text("a session row") } } }
        })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let start = count.n
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return count.n - start
    }

    @MainActor @Test("the unread orb turns without SwiftUI: no measure pass while it does")
    func unreadOrb() async {
        // The old orb, a 20 fps TimelineView, as the reference that this measures anything.
        struct TimelineOrb: View {
            var body: some View {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { t in
                    Circle().fill(AngularGradient(colors: [.blue, .purple], center: .center,
                                                  angle: .degrees(t.date.timeIntervalSinceReferenceDate * 60)))
                        .frame(width: 9, height: 9)
                }
            }
        }
        let reference = await measures(TimelineOrb())
        let orb = await measures(UnreadMark())
        let working = await measures(AgentStatusDot(status: .working))
        // Hundreds alone; far fewer while a full suite keeps the main thread
        // busy. Only proves the probe catches a per-frame redraw at all.
        #expect(reference > 5, "the probe measures a per-frame redraw: \(reference)")
        #expect(orb == 0, "UnreadMark: \(orb) measure passes")
        #expect(working == 0, "AgentStatusDot: \(working) measure passes")
    }

    /// Board finding: "Restored sidebar sizing makes working-status animation
    /// saturate the main thread", read off this file's old comment. Measured:
    /// a full sidebar of working dots, hosted with the default sizing the main
    /// window's sidebar has (it must, or the window can't be resized), isn't
    /// re-measured while they pulse.
    @MainActor @Test("a sidebar full of working dots, at default sizing, isn't re-measured while they pulse")
    func workingDotsAtDefaultSizing() async throws {
        let working = await measures(AgentStatusDot(status: .working), rows: 60)
        #expect(working == 0, "AgentStatusDot × 60: \(working) measure passes")
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let w = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/UnifiedSessionWindow.swift"), encoding: .utf8)
        let host = try #require(w.range(of: "let sidebarHost = NonMovableHostingView(rootView: sidebar)"))
        #expect(!w[host.upperBound...].prefix(900).contains("sidebarHost.sizingOptions = []"))
        #expect(!w.contains("every frame of a working dot's pulse\n        // re-measures"))
    }
}
