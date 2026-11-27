import Foundation
import Testing
@testable import bromure_ac

// "Shift-Option-Space: list of agents seems limited": the quick task's
// "@" list held only a machine's 40 most recently active sessions, so a
// session past them (@morefixes, on a host with many agents) couldn't be
// found even by typing its name. Every session is a candidate now, and a
// name match comes before workspace matches in the few rows shown.
@Suite("Quick task: @ suggestions")
struct QuickTaskAssigneeTests {
    typealias S = TaskAssigneeChoices.Session
    private func s(_ label: String, _ workspace: String = "ws", machine: String? = nil) -> S {
        var x = S(id: UUID(), label: label, workspace: workspace, busy: false)
        x.machine = machine
        return x
    }

    @Test("a session far down the recency list is found by its name")
    func farDown() {
        let many = (0..<200).map { s("@agent-\($0)") } + [s("@morefixes")]
        let hit = QuickTaskView.matching(many, "morefixes")
        #expect(hit.map(\.label) == ["@morefixes"])
    }

    @Test("names starting with the query, then names holding it, then workspace or machine matches")
    func ranking() {
        let list = [s("@infra", "fixes-ws"), s("@hotfixes"), s("@fixer"), s("@other", machine: "fixbox"), s("@fix")]
        #expect(QuickTaskView.matching(list, "fix").map(\.label) == ["@fixer", "@fix", "@hotfixes", "@infra", "@other"])
    }

    @Test("an empty query keeps the recency order; no match is empty")
    func emptyAndNone() {
        let list = [s("@b"), s("@a")]
        #expect(QuickTaskView.matching(list, "").map(\.label) == ["@b", "@a"])
        #expect(QuickTaskView.matching(list, "zzz").isEmpty)
    }

    @Test("no assignee list is cut to the most recent sessions")
    func uncapped() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ f: String) throws -> String {
            try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/" + f), encoding: .utf8)
        }
        let dispatch = try src("TaskDispatch.swift")
        let choices = try #require(dispatch.range(of: "func choices() -> TaskAssigneeChoices {"))
        #expect(!dispatch[choices.upperBound...].prefix(1200).contains(".prefix("))
        #expect(!(try src("QuickTask.swift")).contains(".prefix(40)"))
        let fc = try src("FatClientController.swift")
        let assignees = try #require(fc.range(of: "assignees: {\n                        TaskAssigneeChoices("))
        #expect(!fc[assignees.upperBound...].prefix(600).contains(".prefix("))
    }
}
