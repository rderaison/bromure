import Foundation
import Testing
@testable import bromure_ac

// A room's focus must not jump to another member because the focused one
// went missing from a single snapshot (a failed poll, a restart): the user's
// typing then landed in someone else's chat.

@MainActor
private final class FakeRoomBackend: RoomStageBackend {
    let roomStore: AgentRoomStore
    var roomSessions: [AgentSession] = []
    init(store: AgentRoomStore) { roomStore = store }
    func chatKey(for s: AgentSession) -> String? { nil }
    func makeChat(for s: AgentSession) -> BeautifiedSessionModel? { nil }
    func startSwitchboard(_ room: AgentRoom) {}
    func setLayout(_ room: UUID, _ layout: String) {}
    func wake(_ s: AgentSession, with text: String) {}
    func restingTranscript(for s: AgentSession, ended: Bool) async -> Data? { nil }
    func peerMentions(for s: AgentSession) -> [PeerMention] { [] }
    func assignNickname(_ id: UUID, _ nick: String) {}
}

@Suite("Room focus")
@MainActor
struct RoomFocusTests {

    @Test("a member missing from one or two refreshes keeps focus and zoom; gone for good, focus moves")
    func focusSurvivesFlicker() {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .claude, title: "a")
        a.roomID = room.id
        var b = AgentSession(profileID: ws, tool: .claude, title: "b")
        b.roomID = room.id
        b.createdAt = a.createdAt.addingTimeInterval(10)
        let backend = FakeRoomBackend(store: store)
        backend.roomSessions = [a, b]
        let c = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        c.focus(b.id)
        c.zoomedID = b.id

        // b drops out of two snapshots: nothing moves.
        backend.roomSessions = [a]
        c.refresh(); c.refresh()
        #expect(c.focusedID == b.id)
        #expect(c.zoomedID == b.id)
        // Back again: the count starts over.
        backend.roomSessions = [a, b]
        c.refresh()
        backend.roomSessions = [a]
        c.refresh(); c.refresh()
        #expect(c.focusedID == b.id)
        // Really gone: focus moves to the first member, zoom ends.
        c.refresh()
        #expect(c.focusedID == a.id)
        #expect(c.zoomedID == nil)
        c.stop()
    }
}
