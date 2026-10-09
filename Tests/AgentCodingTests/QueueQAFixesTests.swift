import Foundation
import Testing
@testable import bromure_ac

/// Live-QA round on the chat queue and task sessions (J2, J4, J5).
@Suite("Queue QA fixes")
@MainActor
struct QueueQAFixesTests {

    // MARK: J2 — Start inside the Stop grace never reuses the closing tab

    @Test("A Start waits for a put-away registered before its branch was even known")
    func startWaitsForPutAway() async {
        let work = PendingWork()
        var log: [String] = []
        let token = UUID()
        // Stop: the put-away is registered at once; its branch resolves and
        // the tab is killed a moment later.
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            log.append("old tab killed")
            work.finish("task", token: token)
        }
        work.register("task", token: token, task: task)
        #expect(work.isPending("task"))
        // Start, inside the grace: it waits, then opens its own tab.
        await work.wait("task")
        log.append("new tab opened")
        #expect(log == ["old tab killed", "new tab opened"])
        #expect(!work.isPending("task"))
    }

    @Test("A close scheduled while waiting is waited for too; a finished older one doesn't clear a newer")
    func newerWorkWaited() async {
        let work = PendingWork()
        var done: [Int] = []
        let t1 = UUID(), t2 = UUID()
        work.register("k", token: t1, task: Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            done.append(1)
            work.register("k", token: t2, task: Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                done.append(2)
                work.finish("k", token: t2)
            })
            work.finish("k", token: t1)       // the older one finishing leaves the newer
        })
        await work.wait("k")
        #expect(done == [1, 2])
    }

    // MARK: J4 — a paused session's held messages: listed, and taken over

    @Test("A paused session's messages are found by session, and its new chat takes them over")
    func adoptAfterResume() {
        let store = ChatQueueStore(fileURL: nil)
        let sid = UUID()
        var held = QueuedMessage(text: "after the pause", held: true, editable: true, baseline: 0,
                                 target: .chat(window: 3, windowID: "@7", display: nil, worktree: nil))
        held.sessionID = sid
        held.failure = ChatQueueStore.failureText(.gone)
        var other = QueuedMessage(text: "someone else's", held: true, editable: true, baseline: 0)
        other.sessionID = UUID()
        store.update("local:ws:3") { $0 += [held, other] }
        #expect(store.messages(session: sid).map(\.message.text) == ["after the pause"])
        // Back, in another tab: its chat adopts it, aimed at the new window,
        // and the old "tab is gone" mark goes.
        let target = PaneTarget.chat(window: 5, windowID: "@9", display: nil, worktree: nil)
        store.adopt(session: sid, into: "local:ws:5", target: target)
        let moved = store.messages("local:ws:5")
        #expect(moved.map(\.text) == ["after the pause"])
        #expect(moved.first?.target == target)
        #expect(moved.first?.failure == nil)
        #expect(ChatQueueStore.deliverable(moved.first!))
        #expect(store.messages("local:ws:3").map(\.text) == ["someone else's"])
        // Drop from the paused view.
        store.remove(moved.first!.id)
        #expect(store.messages(session: sid).isEmpty)
    }

    // MARK: J5 — Kimi's 32-character title cut

    @Test("Kimi's title cut at 32 characters never becomes the name; a fuller one stays")
    func kimiTitleCut() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "Kimi Code in qa")
        s.cwd = "/home/ubuntu/qa"
        let cut = String("QH4-second: reply exactly SECOND-SESSION, no tools".prefix(32))
        #expect(cut == "QH4-second: reply exactly SECOND")
        let alone = AgentSession.title(fromAgent: cut, of: s)
        #expect(alone == "QH4-second: reply exactly…")
        s.title = "QH4-second: reply exactly SECOND-SESSION, no tools"
        #expect(AgentSession.title(fromAgent: cut, of: s) == s.title)
        // Its opening message known: the first-request title.
        s.title = "Kimi Code in qa"
        s.openingMessage = "QH4-second: reply exactly SECOND-SESSION, no tools"
        #expect(AgentSession.title(fromAgent: cut, of: s) == "QH4-second: reply exactly SECOND-SESSION, no tools")
        // A hyphenated word in a message title is kept whole.
        #expect(AgentSession.title(fromMessage: "QH4-second: reply exactly SECOND-SESSION, no tools")
                == "QH4-second: reply exactly SECOND-SESSION, no tools")
    }
}
