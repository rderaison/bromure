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
    /// What an asleep member's transcript reads (nil: nothing to show).
    var transcript: Data?
    init(store: AgentRoomStore) { roomStore = store }
    func chatKey(for s: AgentSession) -> String? { nil }
    func makeChat(for s: AgentSession) -> BeautifiedSessionModel? { nil }
    func startSwitchboard(_ room: AgentRoom) {}
    func setLayout(_ room: UUID, _ layout: String) {}
    func wake(_ s: AgentSession, with text: String) {}
    func restingTranscript(for s: AgentSession, ended: Bool) async -> Data? { transcript }
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

    /// Finding (CWE-670): "Reading a session inside a room never clears its
    /// unread mark". What a room shows is what's read: the page's cells (or
    /// the zoomed one), and the Switchboard while its chat is on show.
    @Test("a room's on-screen chats: the page, the zoomed cell, none behind the 1x1 Switchboard tab")
    func onScreen() async throws {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .claude, title: "a"); a.roomID = room.id
        var b = AgentSession(profileID: ws, tool: .claude, title: "b"); b.roomID = room.id
        b.createdAt = a.createdAt.addingTimeInterval(10)
        let backend = FakeRoomBackend(store: store)
        backend.roomSessions = [a, b]
        backend.transcript = Self.reply
        let c = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        // Asleep members: on screen once their transcript tail is up.
        #expect(c.onScreenIDs.isEmpty)
        for s in [a, b] { c.loadResting(s) }
        try await Self.until { c.resting[a.id]?.isEmpty == false && c.resting[b.id]?.isEmpty == false }
        var told = 0
        c.onShownChanged = { told += 1 }
        #expect(Set(c.onScreenIDs) == [a.id, b.id])
        c.zoomedID = b.id
        #expect(c.onScreenIDs == [b.id] && told == 1)
        c.zoomedID = nil
        c.cellsHidden = true                       // the 1x1 Switchboard tab is up
        #expect(c.onScreenIDs.isEmpty && told == 3)
        #expect(c.switchboardOnScreen)              // a grid opens with the dock open
        c.switchboardOnScreen = false               // folded
        c.switchboardOnScreen = true                // a sleeping Switchboard (no chat): nothing read
        #expect(c.onScreenIDs.isEmpty && told == 5)
        c.switchboardOnScreen = true                // no change, no call
        #expect(told == 5)
        // A member joins the page on show: a refresh says so (once).
        c.cellsHidden = false
        told = 0
        var d = AgentSession(profileID: ws, tool: .claude, title: "d"); d.roomID = room.id
        d.createdAt = b.createdAt.addingTimeInterval(10)
        backend.roomSessions = [a, b, d]
        c.loadResting(d)
        try await Self.until { c.resting[d.id]?.isEmpty == false }
        c.refresh()
        #expect(c.onScreenIDs.contains(d.id) && told == 1)
        c.refresh()
        #expect(told == 1)
        c.stop()

        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let stage = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/RoomStage.swift"), encoding: .utf8)
        #expect(stage.contains("if switchboardOnScreen, let sb = switchboard, models[sb.id] != nil { ids.append(sb.id) }"))
        #expect(stage.contains(".onChange(of: switchboardShown, initial: true) { _, v in controller.switchboardOnScreen = v }"))
        #expect(stage.contains(".onChange(of: singleLayout && switchboardTab, initial: true) { _, v in controller.cellsHidden = v }"))
        #expect(stage.contains(".onAppear { controller.onShownChanged?() }"))
        #expect(stage.contains("_switchboardTab = State(initialValue: controller.target == .switchboard)"))
        let ios = try String(contentsOf: top.appendingPathComponent("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift"), encoding: .utf8)
        #expect(ios.contains("if dockOpen, zoomedID == nil, let sb = switchboard, MobileRooms.isLive(sb, controller) { shown.append(sb) }"))
        #expect(ios.contains("for s in onScreen where s.isUnread { controller.markRead(s.id) }"))
    }

    /// Finding (CWE-670): "Room read-state marks the hidden 1×1 session and
    /// skips the Switchboard". Before the view reports its tab and dock, the
    /// controller already reads what the stage opens on.
    @Test("a room opens reading what it shows: the 1x1 Switchboard tab (not the cell), else the grid and the dock")
    func opensOnWhatItShows() async throws {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .claude, title: "a"); a.roomID = room.id
        let backend = FakeRoomBackend(store: store)
        backend.roomSessions = [a]
        let one = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        #expect(one.layout.size == 1 && one.target == .switchboard)
        #expect(one.cellsHidden && one.switchboardOnScreen)
        #expect(!one.onScreenIDs.contains(a.id))                 // the cell is behind the tab
        one.stop()
        var b = AgentSession(profileID: ws, tool: .claude, title: "b"); b.roomID = room.id
        b.createdAt = a.createdAt.addingTimeInterval(10)
        backend.roomSessions = [a, b]
        backend.transcript = Self.reply
        let grid = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        #expect(grid.layout.size > 1 && !grid.cellsHidden && grid.switchboardOnScreen)
        for s in [a, b] { grid.loadResting(s) }
        try await Self.until { grid.resting[a.id]?.isEmpty == false && grid.resting[b.id]?.isEmpty == false }
        #expect(Set(grid.onScreenIDs) == [a.id, b.id])
        grid.stop()
    }

    /// A Claude transcript (the members that read one are Claude sessions).
    static let reply = Data((#"{"type":"user","message":{"role":"user","content":"Go."},"uuid":"u0","timestamp":"2026-09-19T20:00:00.000Z","sessionId":"s1"}"#
        + "\n" + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"uuid":"a0","timestamp":"2026-09-19T20:00:05.000Z","sessionId":"s1"}"# + "\n").utf8)

    static func until(_ ok: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !ok() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Finding (CWE-670): "iOS room marks asleep sessions read without
    /// showing the replies". A cell that shows a placeholder -- no chat, no
    /// transcript to show -- isn't reading anything.
    @Test("a member whose cell shows no conversation isn't on screen, here or on iOS")
    func placeholderIsNotRead() async throws {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        var a = AgentSession(profileID: UUID(), tool: .claude, title: "a"); a.roomID = room.id
        var b = AgentSession(profileID: UUID(), tool: .omp, title: "b"); b.roomID = room.id
        b.createdAt = a.createdAt.addingTimeInterval(10)
        let backend = FakeRoomBackend(store: store)
        backend.roomSessions = [a, b]
        let c = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        // Nothing to show for either (no chat, no transcript): nothing read.
        #expect(c.onScreenIDs.isEmpty)
        c.zoomedID = a.id
        #expect(c.onScreenIDs.isEmpty)
        c.stop()

        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ios = try String(contentsOf: top.appendingPathComponent("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift"), encoding: .utf8)
        #expect(ios.contains("shown = shown.filter { MobileRooms.isLive($0, controller) && zoomMoving != $0.id }"))
    }

    /// Finding (CWE-670): "A room page that gains a session is not marked
    /// read". A fifth session turns the auto 2×2 into 3×2: same page index,
    /// one more chat on it -- the owner is told.
    @Test("a session that joins the page on show (auto layout growing) is reported once")
    func pageGainsASession() async throws {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        let ws = UUID()
        var all: [AgentSession] = []
        for i in 0..<5 {
            var m = AgentSession(profileID: ws, tool: .claude, title: "m\(i)"); m.roomID = room.id
            m.createdAt = Date(timeIntervalSince1970: 1_000 + Double(i))
            all.append(m)
        }
        let backend = FakeRoomBackend(store: store)
        backend.transcript = Self.reply
        backend.roomSessions = Array(all.prefix(4))
        let c = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        for m in all { c.loadResting(m) }
        try await Self.until { all.allSatisfy { c.resting[$0.id]?.isEmpty == false } }
        c.refresh()
        #expect(c.layout.size == 4 && c.page == 0 && c.onScreenIDs.count == 4)
        var told = 0
        c.onShownChanged = { told += 1 }
        backend.roomSessions = all
        c.refresh()
        #expect(c.layout.size >= 5 && c.page == 0)
        #expect(c.onScreenIDs.contains(all[4].id) && told == 1)
        c.refresh()
        #expect(told == 1)                                // nothing new: no call
        c.stop()

        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/RoomStage.swift"), encoding: .utf8)
        #expect(src.contains("noteShown()   // same page, different cells"))
        #expect(src.contains("ACDefaults.standard.set(hideEnded, forKey: Self.hideEndedKey(roomID))\n            noteShown()"))
    }
}
