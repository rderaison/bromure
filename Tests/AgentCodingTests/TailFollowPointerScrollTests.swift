import Foundation
import Testing
@testable import bromure_ac

/// iOS chats (sessions and rooms share `TailFollowingScroll`) let go of the
/// tail for any user scroll -- a trackpad or mouse wheel fires no drag.
/// Finding: "Pointer scrolling cannot leave the tail in iOS chats".
@Suite("Tail following: pointer scrolling")
struct TailFollowPointerScrollTests {
    static func src(_ rel: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("The scroll phase, not only a drag, releases the tail before a snap")
    func scrollPhaseReleases() throws {
        let ws = try Self.src("ios/BromureRemote/Sources/BromureRemote/WorkspaceScreen.swift")
        // User scrolling is read from the scroll phase (trackpad, wheel, touch).
        #expect(ws.contains("content.onScrollPhaseChange { _, phase in"))
        #expect(ws.contains("changed(phase == .interacting || phase == .decelerating)"))
        #expect(ws.contains(".modifier(UserScrollPhase(changed: { scrolling in"))
        // tailMoved lets go on a user scroll away from the end BEFORE the
        // sticky branch's snap.
        let moved = try #require(ws.range(of: "private func tailMoved("))
        let body = ws[moved.upperBound...]
        let release = try #require(body.range(of: "if follow.userScrolling {"))
        let snapBranch = try #require(body.range(of: "if follow.sticky {"))
        #expect(release.lowerBound < snapBranch.lowerBound)
        // ...by the offset, not the end's position (a row grows too).
        #expect(!body[release.lowerBound..<snapBranch.lowerBound].contains("follow.sticky = false"))
        #expect(ws.contains(".onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in"))
        #expect(ws.contains("follow.scrolledUp = TailFollowRule.upwardRun(follow.scrolledUp, adding: delta)\n                if TailFollowRule.releases(userScrolling: true, offsetDelta: follow.scrolledUp,"))
        #expect(ws.contains("if scrolling, !follow.userScrolling { follow.scrolledUp = 0 }"))
        #expect(ws.contains("switch TailFollowRule.atRest(sticky: follow.sticky, atBottom: atBottom(follow.tailY)) {"))
        // Both chats use the shared view.
        let room = try Self.src("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift")
        #expect(room.contains("TailFollowingScroll("))
    }
}

/// Finding "Streaming content can detach tail following during an active
/// scroll": mid-scroll, any end below the viewport let go -- a streaming row
/// growing included -- and the scroll's end at rest didn't take it up again.
@Suite("Tail following: a growing row mid-scroll")
struct TailFollowStreamingScrollTests {
    let vp: CGFloat = 600

    @Test("A row growing while the user scrolls doesn't let go; scrolling up does")
    func growthIsNotAScroll() {
        // The end pushed below the view by a growing row: the offset didn't move.
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: 0, tailY: vp + 300, viewport: vp))
        // Scrolling toward the end while it grows: the offset goes down the page.
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: 40, tailY: vp + 300, viewport: vp))
        // The user scrolled up, away from the end.
        #expect(TailFollowRule.releases(userScrolling: true, offsetDelta: -40, tailY: vp + 300, viewport: vp))
        // Not the user (a snap, a layout pass), or a bounce back at the end.
        #expect(!TailFollowRule.releases(userScrolling: false, offsetDelta: -40, tailY: vp + 300, viewport: vp))
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: -20, tailY: vp - 10, viewport: vp))
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: -0.5, tailY: vp + 300, viewport: vp))
    }

    @Test("At rest: still following with the end off screen goes back to it; let go at the end follows again")
    func atRest() {
        #expect(TailFollowRule.atRest(sticky: true, atBottom: false) == .snap)
        #expect(TailFollowRule.atRest(sticky: true, atBottom: true) == .none)
        #expect(TailFollowRule.atRest(sticky: false, atBottom: true) == .follow)
        #expect(TailFollowRule.atRest(sticky: false, atBottom: false) == .none)
    }
}

/// Finding "Reversing a wheel scroll can fail to detach tail following": in
/// one wheel or trackpad phase the rule was fed the NET offset since the phase
/// began, so scrolling down toward a streaming end and then back up to read
/// it stayed positive, never let go, and the chat snapped back at rest.
@Suite("Tail following: a wheel scroll that reverses")
struct TailFollowReversedScrollTests {
    let vp: CGFloat = 600

    /// The run after each frame's offset change, from the phase start.
    func run(_ deltas: [CGFloat]) -> CGFloat {
        deltas.reduce(0) { TailFollowRule.upwardRun($0, adding: $1) }
    }

    @Test("Down 80 then up 40 in one phase lets go once the end is below the view")
    func reversalReleases() {
        let deltas: [CGFloat] = [20, 20, 20, 20, -10, -10, -10, -10]
        #expect(deltas.reduce(0, +) == 40)                  // the net the old code used
        let up = run(deltas)
        #expect(up == -40)
        #expect(TailFollowRule.releases(userScrolling: true, offsetDelta: up, tailY: vp + 300, viewport: vp))
        // Released, so at rest away from the end nothing snaps back.
        #expect(TailFollowRule.atRest(sticky: false, atBottom: false) == .none)
    }

    @Test("Moving toward the end starts the run over; sub-point upward frames still add up")
    func runResets() {
        #expect(run([-30, 5]) == 0)
        #expect(run([-30, 5, -0.4, -0.4, -0.4]) < -1)
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: run([-30, 5, -0.5]),
                                         tailY: vp + 300, viewport: vp))
        // Scrolling only toward the end never lets go.
        #expect(!TailFollowRule.releases(userScrolling: true, offsetDelta: run([10, 10, 10]),
                                         tailY: vp + 300, viewport: vp))
    }
}
