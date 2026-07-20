import Foundation
import Testing
@testable import bromure_ac

/// The coding-board MCP server's JSON-RPC handling — transport-free, the
/// same way the vsock bridge drives it (one line in, one line out).
@Suite("Task board MCP")
@MainActor
struct TaskBoardMCPTests {

    private func makeFixture() -> (TaskBoardMCPServer, CodingTaskStore, UUID, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tasks-\(UUID().uuidString).json")
        let store = CodingTaskStore(fileURL: tmp)
        let engine = CodingTaskEngine(store: store, delegate: nil)
        let pid = UUID()
        let server = TaskBoardMCPServer(profileID: pid,
                                        store: { store }, engine: { engine })
        let task = CodingTask(title: "Fix the parser",
                              details: "handle empty hunks",
                              profileID: pid, repoPath: "~/repo",
                              stage: .inProgress,
                              branchSlug: "fix-the-parser-260718-1200",
                              comments: [ReviewComment(text: "note", file: "a.c")])
        store.upsert(task)
        return (server, store, task.id, "wt/fix-the-parser-260718-1200")
    }

    private func rpc(_ method: String, params: [String: Any] = [:],
                     id: Int = 1) -> String {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                  "method": method, "params": params]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        return String(data: data, encoding: .utf8)!
    }

    private func parse(_ line: String?) -> [String: Any] {
        guard let line, let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func resultText(_ resp: [String: Any]) -> String {
        let result = resp["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined()
    }

    private func isError(_ resp: [String: Any]) -> Bool {
        ((resp["result"] as? [String: Any])?["isError"] as? Bool) == true
    }

    @Test("initialize and tools/list expose the four board tools")
    func handshake() async {
        let (server, _, _, branch) = makeFixture()
        let ini = parse(await server.handle(line: rpc("initialize"), branch: branch))
        let iniResult = ini["result"] as? [String: Any]
        #expect((iniResult?["serverInfo"] as? [String: Any])?["name"] as? String == "bromure-board")
        let list = parse(await server.handle(line: rpc("tools/list"), branch: branch))
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(Set(tools.compactMap { $0["name"] as? String })
            == ["board_get_task", "board_set_plan",
                "board_create_subtasks", "board_ready_for_review"])
    }

    @Test("Tool calls without a bound task error instead of guessing")
    func unbound() async {
        let (server, _, _, _) = makeFixture()
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_get_task", "arguments": [:]]),
            branch: "wt/some-other-task"))
        #expect(isError(resp))
    }

    @Test("board_get_task returns the card; the -N dedup suffix still binds")
    func getTask() async {
        let (server, _, _, branch) = makeFixture()
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_get_task", "arguments": [:]]),
            branch: branch + "-2"))
        #expect(!isError(resp))
        let text = resultText(resp)
        #expect(text.contains("Fix the parser"))
        #expect(text.contains("empty hunks"))
        #expect(text.contains("reviewComments"))
    }

    @Test("board_set_plan lands the plan on the stored task")
    func setPlan() async {
        let (server, store, taskID, branch) = makeFixture()
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_set_plan",
                               "arguments": ["plan": "## Plan\n- step one"]]),
            branch: branch))
        #expect(!isError(resp))
        #expect(store.task(taskID)?.plan == "## Plan\n- step one")
    }

    @Test("board_create_subtasks files ordered Plan cards with dependencies")
    func subtasks() async {
        let (server, store, taskID, branch) = makeFixture()
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_create_subtasks",
                               "arguments": ["subtasks": [
                                   ["title": "Add tests", "details": "for hunks"],
                                   ["title": "Update docs", "dependsOn": [1]],
                               ]]]),
            branch: branch))
        #expect(!isError(resp))
        let subs = store.tasks.filter { $0.parentTaskID == taskID }
            .sorted { $0.createdAt < $1.createdAt }
        #expect(subs.count == 2)
        #expect(subs.allSatisfy { $0.stage == .planning && $0.repoPath == "~/repo" })
        #expect(subs[1].dependsOn == [subs[0].id])
        #expect(!subs[1].unmetDependencies(in: store.tasks).isEmpty)
    }

    @Test("A planner session binds its BACKLOG parent; filing phases clears the spinner")
    func plannerBinding() async {
        let (server, store, taskID, _) = makeFixture()
        // Reshape the fixture task into a backlog parent mid-planning.
        store.mutate(taskID) {
            $0.stage = .backlog
            $0.branchSlug = "plan-fix-the-parser-260718-1300"
            $0.validationRequestedAt = Date()
        }
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_create_subtasks",
                               "arguments": ["subtasks": [["title": "Phase A"]]]]),
            branch: "wt/plan-fix-the-parser-260718-1300"))
        #expect(!isError(resp), "planner session could not file phases: \(resultText(resp))")
        let parent = store.task(taskID)
        #expect(parent?.validatedAt != nil, "filing phases must clear the in-flight spinner")
        #expect(store.tasks.contains { $0.parentTaskID == taskID && $0.stage == .planning })
    }

    @Test("board_ready_for_review moves the task to Testing")
    func readyForReview() async {
        let (server, store, taskID, branch) = makeFixture()
        let resp = parse(await server.handle(
            line: rpc("tools/call",
                      params: ["name": "board_ready_for_review", "arguments": [:]]),
            branch: branch))
        #expect(!isError(resp), "ready_for_review errored: \(resultText(resp))")
        #expect(store.task(taskID)?.stage == .testing)
    }
}
