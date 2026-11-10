import Foundation
import Testing

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
        #expect(ws.contains(".modifier(UserScrollPhase { scrolling in"))
        // tailMoved lets go on a user scroll away from the end BEFORE the
        // sticky branch's snap.
        let moved = try #require(ws.range(of: "private func tailMoved("))
        let body = ws[moved.upperBound...]
        let release = try #require(body.range(of: "if follow.userScrolling {"))
        let snapBranch = try #require(body.range(of: "if follow.sticky {"))
        #expect(release.lowerBound < snapBranch.lowerBound)
        #expect(body[release.lowerBound..<snapBranch.lowerBound].contains("if y > viewport + 2 { follow.sticky = false }"))
        // Both chats use the shared view.
        let room = try Self.src("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift")
        #expect(room.contains("TailFollowingScroll("))
    }
}
