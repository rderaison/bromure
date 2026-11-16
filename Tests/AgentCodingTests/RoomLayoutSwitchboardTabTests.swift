import Foundation
import Testing

/// Choosing a room layout on the Switchboard tab stays on it; on a page of
/// sessions it moves to the focused session's page. Finding: "Changing room
/// layout exits the selected Switchboard tab".
@Suite("Room layout keeps the Switchboard tab")
struct RoomLayoutSwitchboardTabTests {
    @Test("The layout action keeps switchboardPage and recomputes only session pages")
    func layoutKeepsSwitchboard() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: top.appendingPathComponent(
            "ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift"), encoding: .utf8)
        #expect(s.contains("""
            static func page(afterLayout l: RoomLayout, current: Int, focusedIndex: Int?) -> Int {
                guard current != switchboardPage, let i = focusedIndex else { return current }
                return i / l.size
            }
        """))
        #expect(s.contains("page = Self.page(afterLayout: l, current: page,"))
        // The old unconditional assignment is gone.
        #expect(!s.contains("let i = members.firstIndex(where: { $0.id == f }) { page = i / l.size }"))
    }
}
