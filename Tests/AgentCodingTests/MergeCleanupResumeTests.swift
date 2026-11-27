import Foundation
import Testing
@testable import bromure_ac

/// Regression (CWE-362): after a merge, the session's checkout was removed
/// two seconds later whatever happened meanwhile. A resume in that window
/// relaunched the agent in the folder about to go, and the cleanup then
/// removed it under the agent and archived the running session.
@MainActor
@Suite("A merged session's delayed cleanup never outruns a resume", .serialized)
struct MergeCleanupResumeTests {
    final class Calls { var removes = 0 }

    private func setUp() -> (AgentSessionStore, AgentSessionEngine, AgentSession, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json")
        let store = AgentSessionStore(fileURL: url)
        let engine = AgentSessionEngine(store: store, delegate: nil)
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "/w/b", windowIndex: nil)
        s.worktreeBranch = "wt/b"; s.branchRoot = "/w/repo"; s.endedAt = Date()
        store.upsert(s)
        return (store, engine, s, url)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    @Test("left alone, the checkout goes and the session is archived")
    func untouched() async {
        let (store, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 10_000_000) { _ in
            calls.removes += 1; return true
        }
        await settle()
        #expect(calls.removes == 1)
        #expect(store.session(s.id)?.folderMissing == true)
        #expect(store.session(s.id)?.isArchived == true)
        #expect(engine.checkoutCleanups[s.id] == nil)
    }

    @Test("a resume in the window calls the cleanup off")
    func resumedBeforeRemoval() async {
        let (store, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 50_000_000) { _ in
            calls.removes += 1; return true
        }
        engine.resume(s.id)
        await settle()
        #expect(calls.removes == 0)
        #expect(store.session(s.id)?.folderMissing != true)
        #expect(store.session(s.id)?.isArchived == false)
    }

    @Test("a session relaunched by another path (no longer ended) keeps its checkout")
    func relaunchedOtherwise() async {
        let (store, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 30_000_000) { _ in
            calls.removes += 1; return true
        }
        store.mutate(s.id) { $0.launchingSince = Date() }
        await settle()
        #expect(calls.removes == 0)
        #expect(store.session(s.id)?.isArchived == false)
        #expect(engine.checkoutCleanups[s.id] == nil)
    }

    @Test("once the removal runs, a resume is refused with the reason, and the session is put away")
    func resumeDuringRemoval() async {
        let (store, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 1_000_000) { _ in
            calls.removes += 1
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(engine.checkoutCleanups[s.id]?.removing == true)
        engine.resume(s.id)
        #expect(store.session(s.id)?.lastError != nil)
        #expect(store.session(s.id)?.isLaunching == false)
        await settle()
        #expect(calls.removes == 1)
        #expect(store.session(s.id)?.folderMissing == true)
        #expect(store.session(s.id)?.isArchived == true)
        // Now gone: a resume says so rather than relaunching in nothing.
        #expect(engine.cancelCheckoutCleanup(s.id) == nil)
    }

    @Test("a second merge's cleanup replaces the first's")
    func latestWins() async {
        let (_, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 10_000_000) { _ in
            calls.removes += 10; return true
        }
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 40_000_000) { _ in
            calls.removes += 1; return true
        }
        await settle()
        #expect(calls.removes == 1)
    }

    @Test("a second merge while the first's removal runs doesn't drop its guard")
    func secondMergeDuringRemoval() async {
        let (store, engine, s, url) = setUp(); defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 1_000_000) { _ in
            calls.removes += 1
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        engine.scheduleCheckoutCleanup(s.id, root: "/w/repo", branch: "wt/b", afterNanoseconds: 1_000_000) { _ in
            calls.removes += 10; return true
        }
        #expect(engine.checkoutCleanups[s.id]?.removing == true)
        engine.resume(s.id)
        #expect(store.session(s.id)?.lastError == AgentSessionEngine.checkoutBeingRemoved)
        await settle()
        #expect(calls.removes == 1)
    }

    @Test("a Done task: a Resume calls its pending cleanup off, and is refused while the removal runs")
    func taskResume() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CodingTaskStore(fileURL: url)
        let engine = CodingTaskEngine(store: store, delegate: nil)
        let t = CodingTask(profileID: UUID(), stage: .done, branchSlug: "task-x")
        store.upsert(t)
        engine.checkoutCleanups[t.id] = .init(token: UUID(), removing: true)
        engine.resumeSession(t.id)
        #expect(store.task(t.id)?.lastError == AgentSessionEngine.checkoutBeingRemoved)
        #expect(engine.checkoutCleanups[t.id] != nil)
        engine.checkoutCleanups[t.id] = .init(token: UUID())
        engine.resumeSession(t.id)
        #expect(engine.checkoutCleanups[t.id] == nil)
    }
}
