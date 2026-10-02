import Foundation
import Testing
@testable import bromure_ac

@Suite("Assignee workspace")
struct AssigneeWorkspaceTests {
    @Test("a task queued for a session belongs to that session's workspace")
    func sessionWorkspace() {
        let ws = UUID(), sid = UUID()
        let choices = TaskAssigneeChoices(
            sessions: [.init(id: sid, label: "@hotfixes", workspace: "Platform", busy: false, profileID: ws)],
            rooms: [.init(id: UUID(), name: "payments")])
        #expect(choices.workspace(for: TaskAssignment(kind: .session, id: sid, label: "@hotfixes")) == ws)
        // Not a session (a room, a new agent), or a session it doesn't know: the task's own.
        #expect(choices.workspace(for: TaskAssignment(kind: .room, id: UUID(), label: "#payments")) == nil)
        #expect(choices.workspace(for: .newAgent) == nil)
        #expect(choices.workspace(for: TaskAssignment(kind: .session, id: UUID(), label: "@gone")) == nil)
        #expect(choices.workspace(for: nil) == nil)
    }
}
