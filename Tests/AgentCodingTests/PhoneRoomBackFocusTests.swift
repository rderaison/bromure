import Foundation
import Testing

/// Back from a session pushed over a room puts the shared fold focus back
/// on the room; the iPad-layout teardown's pops still publish nothing.
/// Finding: "Returning from a room session leaves fold focus on the closed
/// session".
@Suite("Phone: Back to a room restores its focus")
struct PhoneRoomBackFocusTests {
    static func src() throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(
            "ios/BromureRemote/Sources/BromureRemote/HostMirrorScreen.swift"), encoding: .utf8)
    }

    @Test("A session pop over an open room publishes the room, only on the phone layout")
    func sessionPopPublishesRoom() throws {
        let s = try Self.src()
        #expect(s.contains("""
                .onChange(of: openSessionID) { old, id in
                    if let id {
                        publishFocus(.session(id))
                    } else if Self.backToRoom(closedSession: old, openRoom: openRoomID,
                                              sizeClass: stackSizeClass), let room = openRoomID {
                        publishFocus(.room(room))
                    }
                }
        """))
        #expect(s.contains("closedSession != nil && openRoom != nil && sizeClass == .compact"))
        #expect(s.contains("@Environment(\\.horizontalSizeClass) private var stackSizeClass"))
        // The room still pushes sessions over itself.
        #expect(s.contains("onOpenSession: { openSessionID = $0 },"))
    }
}
