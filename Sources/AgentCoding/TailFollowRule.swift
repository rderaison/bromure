import Foundation

/// When a chat that follows its end lets go, and when it takes up again --
/// the iOS chats' `TailFollowingScroll`, kept here (shared, plain values) so
/// it can be tested on the Mac.
///
/// The end marker below the viewport during a scroll isn't enough to say
/// the user scrolled away: a streaming row grows without the user moving
/// anything, and pushes the end down just as a scroll up does. Only the
/// scroll offset tells them apart -- content growing below leaves it where
/// it was. (Finding "Streaming content can detach tail following during an
/// active scroll".)
enum TailFollowRule {
    /// A scroll position change lets go: the user is scrolling, the offset
    /// moved toward the top, and the end is now below the view's bottom
    /// edge (an overscroll bouncing back at the end isn't away).
    static func releases(userScrolling: Bool, offsetDelta: CGFloat, tailY: CGFloat?, viewport: CGFloat) -> Bool {
        guard userScrolling, viewport > 0, offsetDelta < -1 else { return false }
        return (tailY ?? .infinity) > viewport + 2
    }

    enum AtRest: Equatable { case none, follow, snap }

    /// The user's scroll came to rest: at the end, follow again; still
    /// following but the end moved off screen meanwhile (a row grew while
    /// the finger or wheel was busy), go back to it.
    static func atRest(sticky: Bool, atBottom: Bool) -> AtRest {
        if !sticky { return atBottom ? .follow : .none }
        return atBottom ? .none : .snap
    }
}
