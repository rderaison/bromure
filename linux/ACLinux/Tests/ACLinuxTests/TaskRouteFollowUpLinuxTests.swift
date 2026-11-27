import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// What main's client-side fixes need from the server's routes (macOS:
    /// onTaskCommand and watchesCommand): a Merge that starts nothing says
    /// why instead of answering ok, and a finding handed to a session twice
    /// with one key is one task.
    @Suite("Task and finding routes: refusals and resends", .serialized)
    @MainActor
    struct TaskRouteFollowUpLinuxTests {
        static func stores() throws -> (SessionStores, String, SessionStores?) {
            let dir = try shortTempDir()
            let stores = SessionStores(stateDir: dir)
            let prior = SessionStores.shared
            SessionStores.shared = stores
            stores.codingTaskEngine = CodingTaskEngine(store: stores.codingTasks, delegate: nil)
            return (stores, dir, prior)
        }

        @Test func aMergeThatStartsNothingSaysWhy() throws {
            let (stores, dir, prior) = try Self.stores()
            defer { SessionStores.shared = prior; try? FileManager.default.removeItem(atPath: dir) }
            let pid = UUID()
            var backlog = CodingTask(title: "not started", profileID: pid)
            backlog.stage = .backlog
            var review = CodingTask(title: "in review", profileID: pid)
            review.stage = .testing
            for t in [backlog, review] { stores.codingTasks.upsert(t) }

            for action in ["merge", "land"] {
                let r = stores.taskCommand(backlog.id, action, ["mode": "merge"])
                #expect(r["ok"] as? Bool == false, "\(action): \(r)")
                #expect((r["error"] as? String)?.isEmpty == false, "\(action): \(r)")
            }
            // A batch with nothing in Review is refused the same way.
            let batch = stores.taskCommand(backlog.id, "merge-batch", ["with": [UUID().uuidString]])
            #expect(batch["ok"] as? Bool == false && batch["error"] as? String != nil, "\(batch)")
            // One in Review starts (no refusal): the answer is the usual ok.
            #expect(CodingTaskEngine.landRefusal([review]) == nil)
            #expect(stores.taskCommand(review.id, "merge", ["mode": "merge"])["ok"] as? Bool == true)
        }

        @Test func aResentHandOverIsTheSameTask() {
            let f = UUID(), t1 = UUID()
            var l = HandOverLedger()
            #expect(l.task(f, "k1", exists: { _ in true }) == nil)
            l.record(f, "k1", task: t1)
            #expect(l.task(f, "k1", exists: { _ in true }) == t1)
            // Another key, another finding, or no key: a new ask.
            #expect(l.task(f, "k2", exists: { _ in true }) == nil)
            #expect(l.task(UUID(), "k1", exists: { _ in true }) == nil)
            #expect(l.task(f, nil, exists: { _ in true }) == nil)
            // A task that left the board isn't handed back.
            #expect(l.task(f, "k1", exists: { _ in false }) == nil)
            // Without a key nothing is remembered.
            l.record(f, nil, task: UUID())
            #expect(l.task(f, nil, exists: { _ in true }) == nil)
        }

        /// The route hands the client's key to the engine (as macOS's
        /// HandOverLedgerTests checks RepoWatchWiring).
        @Test func theRoutePassesTheClientsKeyOn() throws {
            let src = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ACLinux/DaemonWatches.swift").path, encoding: .utf8)
            #expect(src.contains("body[\"handOver\"]"))
            #expect(src.contains("routeFindingToSession(id, session: sid, confirmed: true, handOver: key)"))
            #expect(src.contains("watchEngine?.fix(findingID, by: s, handOver: handOver)"))
        }
    }
}
