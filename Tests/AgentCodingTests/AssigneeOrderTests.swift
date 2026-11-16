import Foundation
import Testing
@testable import bromure_ac

/// Board: a quick task's "Assign to" menu listed the agents most recently
/// active first, which read as random once there were many. The pickers now
/// list them by name; the "@" suggestions keep the recent ones on top.
@Suite("Task pickers list agents by name")
struct AssigneeOrderTests {
    private func s(_ label: String, _ workspace: String = "ws", machine: String? = nil) -> TaskAssigneeChoices.Session {
        var x = TaskAssigneeChoices.Session(id: UUID(), label: label, workspace: workspace, busy: false)
        x.machine = machine
        return x
    }

    @Test("by name: case aside, numbers as numbers, a nickname's @ ignored")
    func byName() {
        let recent = [s("zeta"), s("@infra"), s("agent-10"), s("Beta"), s("agent-2"), s("alpha")]
        let c = TaskAssigneeChoices(sessions: recent, rooms: [])
        #expect(c.byName.sessions.map(\.label) == ["agent-2", "agent-10", "alpha", "Beta", "@infra", "zeta"])
        // The list underneath keeps its recency order (the "@" suggestions).
        #expect(c.sessions.map(\.label) == recent.map(\.label))
    }

    @Test("the same name twice: by workspace, then machine, always in the same order")
    func ties() {
        let a = s("build", "web", machine: "Mac mini"), b = s("build", "api", machine: "Mac mini")
        let c1 = s("build", "api", machine: "Laptop")
        let sorted = TaskAssigneeChoices(sessions: [a, b, c1], rooms: []).byName.sessions
        #expect(sorted.map(\.id) == [c1.id, b.id, a.id])
        #expect(TaskAssigneeChoices(sessions: [c1, a, b], rooms: []).byName.sessions.map(\.id) == sorted.map(\.id))
    }

    @Test("rooms too")
    func rooms() {
        let rooms = ["team-10", "Design", "team-2", "alpha"].map { TaskAssigneeChoices.Room(id: UUID(), name: $0) }
        let c = TaskAssigneeChoices(sessions: [], rooms: rooms)
        #expect(c.byName.rooms.map(\.name) == ["alpha", "Design", "team-2", "team-10"])
    }

    @Test("every picker lists the sorted copy")
    func pickersUseIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding")
        let quick = try String(contentsOf: root.appendingPathComponent("QuickTask.swift"), encoding: .utf8)
        let board = try String(contentsOf: root.appendingPathComponent("CodingKanbanView.swift"), encoding: .utf8)
        #expect(quick.contains("ForEach(choices.byName.sessions)") && quick.contains("ForEach(choices.byName.rooms)"))
        #expect(!board.contains("ForEach(choices.sessions)") && !board.contains("ForEach(assignees.sessions)"))
        #expect(!board.contains("ForEach(choices.rooms)") && !board.contains("ForEach(assignees.rooms)"))
    }
}
