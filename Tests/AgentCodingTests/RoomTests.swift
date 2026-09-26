import Foundation
import Testing
@testable import bromure_ac

@Suite("Rooms")
@MainActor
struct RoomTests {

    private func tempStore() -> (AgentRoomStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json")
        return (AgentRoomStore(fileURL: url), url)
    }

    @Test("Room names are made unique, case-insensitively; blank gets a default")
    func uniqueNames() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.create(name: "Payments").name == "Payments")
        #expect(store.create(name: "payments").name == "payments 2")
        #expect(store.create(name: "  Payments ").name == "Payments 3")
        #expect(!store.create(name: "   ").name.isEmpty)
    }

    @Test("Rooms persist across stores; rename and color stick; remove drops")
    func persistence() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = store.create(name: "Infra")
        store.rename(r.id, to: "Infra v2")
        store.rename(r.id, to: "   ")   // ignored
        store.setColor(r.id, "#EF4444")
        let again = AgentRoomStore(fileURL: url)
        #expect(again.room(r.id)?.name == "Infra v2")
        #expect(again.room(r.id)?.colorHex == "#EF4444")
        again.remove(r.id)
        #expect(AgentRoomStore(fileURL: url).rooms.isEmpty)
    }

    @Test("Slugs are folder-safe")
    func slug() {
        #expect(AgentRoom(name: "Payments v2!", colorHex: "#000000").slug == "payments-v2")
        #expect(AgentRoom(name: "  --  ", colorHex: "#000000").slug.count == 8)
    }

    @Test("Members leave out the room's Switchboard, archived and other rooms' sessions")
    func members() {
        let room = AgentRoom(name: "R", colorHex: "#000000")
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .claude, title: "a")
        a.roomID = room.id
        var sb = AgentSession(profileID: ws, tool: .claude, title: "sb")
        sb.roomID = room.id
        sb.role = AgentSession.switchboardRole
        var elsewhere = AgentSession(profileID: ws, tool: .claude, title: "b")
        elsewhere.roomID = UUID()
        let loose = AgentSession(profileID: ws, tool: .claude, title: "c")
        let all = [a, sb, elsewhere, loose]
        #expect(RoomTally.members(room, in: all).map(\.id) == [a.id])
        #expect(RoomTally.switchboard(of: room, in: all)?.id == sb.id)
    }

    @Test("An archived room keeps its archived sessions; a live one shows only live ones")
    func archivedMembers() {
        var room = AgentRoom(name: "R", colorHex: "#000000")
        let ws = UUID()
        var live = AgentSession(profileID: ws, tool: .claude, title: "live")
        live.roomID = room.id
        var put = AgentSession(profileID: ws, tool: .claude, title: "put")
        put.roomID = room.id
        put.archivedAt = Date()
        #expect(RoomTally.members(room, in: [live, put]).map(\.id) == [live.id])
        room.archivedAt = Date()
        #expect(Set(RoomTally.members(room, in: [live, put]).map(\.id)) == [live.id, put.id])
    }

    @Test("Archived rooms are set apart and persist")
    func archivedRooms() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = store.create(name: "A")
        let b = store.create(name: "B")
        store.setArchived(b.id, true)
        #expect(store.activeRooms.map(\.id) == [a.id])
        #expect(store.archivedRooms.map(\.id) == [b.id])
        #expect(AgentRoomStore(fileURL: url).room(b.id)?.isArchived == true)
        store.setArchived(b.id, false)
        #expect(store.archivedRooms.isEmpty)
    }

    @Test("The global Switchboard is never a room's")
    func globalSwitchboard() {
        let ws = UUID()
        var roomSB = AgentSession(profileID: ws, tool: .claude, title: "room")
        roomSB.role = AgentSession.switchboardRole
        roomSB.roomID = UUID()
        #expect(SwitchboardGate.switchboard(in: [roomSB]) == nil)
        var global = AgentSession(profileID: ws, tool: .claude, title: "global")
        global.role = AgentSession.switchboardRole
        #expect(SwitchboardGate.switchboard(in: [roomSB, global])?.id == global.id)
    }
}

@Suite("Room layouts")
struct RoomLayoutTests {
    @Test("Pages chunk by the grid's size; 1×1 = one tab per session")
    func paging() {
        let items = Array(0..<20)
        #expect(RoomLayout(cols: 4, rows: 4).pages(items).map(\.count) == [16, 4])
        #expect(RoomLayout(cols: 1, rows: 1).pages(items).count == 20)
        #expect(RoomLayout(cols: 2, rows: 2).pages([Int]()).isEmpty)
    }

    @Test("Sized to fit when unset; strings round-trip; junk rejected")
    func fitting() {
        #expect(RoomLayout.fitting(1) == RoomLayout(cols: 1, rows: 1))
        #expect(RoomLayout.fitting(3) == RoomLayout(cols: 2, rows: 2))
        #expect(RoomLayout.fitting(7) == RoomLayout(cols: 3, rows: 3))
        #expect(RoomLayout.fitting(40) == RoomLayout(cols: 4, rows: 4))
        #expect(RoomLayout("3x2") == RoomLayout(cols: 3, rows: 2))
        #expect(RoomLayout("0x2") == nil)
        #expect(RoomLayout("banana") == nil)
    }
}

@Suite("Session titles")
@MainActor
struct SessionTitleTests {
    @Test("Titles: first sentence, no preamble, capitalized, short")
    func titles() {
        #expect(AgentSession.title(fromMessage: "please fix the login redirect loop on staging") == "Fix the login redirect loop on staging")
        #expect(AgentSession.title(fromMessage: "You are a test parent. Reply with exactly the word ready, then stop.") == "You are a test parent")
        #expect(AgentSession.title(fromMessage: "Can you add a dark mode toggle to the settings page? It should persist.") == "Add a dark mode toggle to the settings page")
        #expect(AgentSession.title(fromMessage: "# Plan\nstuff") == "Plan")
        let long = AgentSession.title(fromMessage: "Refactor the entire authentication module so that every provider shares the same token cache and refresh logic")
        #expect(long.count <= 57 && long.hasSuffix("…"))
    }

    @Test("Duplicate titles get what tells them apart")
    func distinct() {
        let model = SessionListModel()
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .claude, title: "Delegation MCP tool request", cwd: "~/dtest-peer")
        var b = AgentSession(profileID: ws, tool: .claude, title: "Delegation MCP tool request", cwd: "~/dtest-parent")
        b.nickname = "parent"
        a.nickname = nil
        #expect(SessionHome.distinctTitle(a, among: [a, b], in: model) == "Delegation MCP tool request · dtest-peer")
        #expect(SessionHome.distinctTitle(b, among: [a, b], in: model) == "Delegation MCP tool request · @parent")
        #expect(SessionHome.distinctTitle(a, among: [a], in: model) == "Delegation MCP tool request")
    }
}
