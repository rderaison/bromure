import Foundation
import Testing
@testable import ACLinux

/// The /state and board lists through EncodedRowMemo (macOS: encodedRows):
/// an unchanged item's row is reused, not encoded again, and an edited,
/// added or removed one shows at once.
@Suite("Row memo for the state lists")
@MainActor
struct RowMemoTests {
    @Test func theBoardsRowsAreReusedAndStayCurrent() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let stores = SessionStores(stateDir: d)
        stores.codingTaskEngine = CodingTaskEngine(store: stores.codingTasks, delegate: nil)
        var a = CodingTask(title: "first", profileID: UUID())
        let b = CodingTask(title: "second", profileID: UUID())
        stores.codingTasks.upsert(a)
        stores.codingTasks.upsert(b)
        func titles() -> [String] {
            ((stores.taskList()["tasks"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }.sorted()
        }
        #expect(titles() == ["first", "second"])

        // The list just built is in the memo: nothing left to encode.
        var encoded = 0
        _ = stores.encodedRowMemo.rows(stores.codingTasks.tasks, "dict:tasks") { _ -> [String: Any]? in
            encoded += 1; return nil
        }
        #expect(encoded == 0)

        a.title = "edited"
        stores.codingTasks.upsert(a)
        #expect(titles() == ["edited", "second"], "an edit shows at once")
        stores.codingTasks.upsert(CodingTask(title: "third", profileID: UUID()))
        #expect(titles() == ["edited", "second", "third"])
        _ = stores.taskCommand(b.id, "delete", [:])
        #expect(titles() == ["edited", "third"])
        // The board's state entry is the same rows.
        guard case .object(let board) = stores.boardStateEntries()["tasks"] ?? .null,
              case .array(let rows) = board["tasks"] ?? .null else { Issue.record("no tasks entry"); return }
        #expect(rows.count == 2)
    }

    @Test func theStateEntriesAreMemoedToo() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let stores = SessionStores(stateDir: d)
        guard case .array(let none) = stores.stateEntries()["agentSessions"] ?? .null else { Issue.record("no list"); return }
        #expect(none.isEmpty)
        // JSONValue rows and the board's dictionaries never share a key.
        let tasks = [CodingTask(title: "x", profileID: UUID())]
        let rows = stores.encodedRows(tasks, "tasks")
        let dicts = stores.encodedDicts(tasks, "tasks")
        guard case .object(let o) = rows.first ?? .null else { Issue.record("\(rows)"); return }
        #expect(o["title"] == .string("x") && dicts.first?["title"] as? String == "x")
        var encoded = 0
        _ = stores.encodedRowMemo.rows(tasks, "tasks") { _ -> JSONValue? in encoded += 1; return nil }
        #expect(encoded == 0)
    }
}
