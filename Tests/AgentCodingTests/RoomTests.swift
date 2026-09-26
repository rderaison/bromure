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

    @Test("A folder named after the title doesn't tell twins apart")
    func folderEcho() {
        #expect(SessionHome.folderEchoesTitle("hello-260920-1412", "Hello"))
        #expect(SessionHome.folderEchoesTitle("fix-login-redirect", "Fix login redirect loop on staging"))
        #expect(!SessionHome.folderEchoesTitle("dtest-peer", "Delegation MCP tool request"))
        let model = SessionListModel()
        let ws = UUID()
        let a = AgentSession(profileID: ws, tool: .claude, title: "Hello", cwd: "~/hello-260920-1412")
        let b = AgentSession(profileID: ws, tool: .claude, title: "Hello", cwd: "~/hello-260921-0900")
        let t = SessionHome.distinctTitle(a, among: [a, b], in: model)
        #expect(t.hasPrefix("Hello · ") && !t.contains("260920"))
    }

    @Test("Titles cut from the first message are redone; renamed ones stay")
    func retitle() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let ws = UUID()
        var cut = AgentSession(profileID: ws, tool: .claude, title: "You are a test parent. Reply with exactly the word r...")
        cut.openingMessage = "You are a test parent. Reply with exactly the word ready, then stop."
        var mine = AgentSession(profileID: ws, tool: .claude, title: "You are a test")
        mine.openingMessage = "You are a test parent. Reply with exactly the word ready."
        mine.userTitled = true
        store.upsert(cut)
        store.upsert(mine)
        #expect(store.retitleFromOpeningMessages() == 1)
        #expect(store.session(cut.id)?.title == "You are a test parent")
        #expect(store.session(mine.id)?.title == "You are a test")
    }
}

@Suite("Transcript activity lines")
struct TranscriptActivityTests {
    private func item(_ id: Int, _ k: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: id, kind: k, timestamp: nil) }

    @Test("Runs of tool calls and thinking fold between messages")
    func grouping() {
        let rows = TranscriptRow.rows([
            item(1, .userText("go")),
            item(2, .thinking("hmm")),
            item(3, .toolUse(name: "Bash", summary: "ls", detail: "")),
            item(4, .toolResult(tool: "Bash", content: "a", isError: false)),
            item(5, .assistantText("done")),
            item(6, .toolUse(name: "Read", summary: "x.swift", detail: "")),
        ])
        #expect(rows.map(\.id) == [1, 2, 5, 6])
        if case .activity(let run) = rows[1] { #expect(run.count == 3) } else { Issue.record("not folded") }
    }

    @Test("The line counts by kind; one step says what it was; failures show")
    func summary() {
        let many = ActivitySummary.line([
            item(1, .toolUse(name: "Bash", summary: "npm test", detail: "")),
            item(2, .toolResult(tool: "Bash", content: "", isError: true)),
            item(3, .toolUse(name: "Read", summary: "a", detail: "")),
            item(4, .toolUse(name: "Read", summary: "b", detail: "")),
            item(5, .toolUse(name: "mcp__delegation__request", summary: "", detail: "")),
        ])
        #expect(many.text == "1 command · 2 files read · 1 subagent")
        #expect(many.failures == 1)
        let one = ActivitySummary.line([item(1, .thinking("…")), item(2, .toolUse(name: "Bash", summary: "npm test", detail: ""))])
        #expect(one.text == "Thought · Bash npm test")
        #expect(ActivitySummary.current([item(1, .toolUse(name: "Bash", summary: "npm test", detail: ""))]) == "Running npm test…")
    }
}
