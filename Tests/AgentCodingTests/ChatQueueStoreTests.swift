import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Messages queued in a chat while its agent works outlive the chat's view
/// model: a session switch used to drop them (and nothing said so).
@Suite("Chat queue store")
@MainActor
struct ChatQueueStoreTests {

    /// A chat's provider: records what it types, reports a scripted status.
    private final class Provider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        var window: Int? = 3
        var working = true
        /// What a typing command prints back ("" = typed).
        var typeReply = ""
        var typed: [String] = []
        func activeTabIndex() -> Int? { window }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("base64 -d") { typed.append(command) ; return typeReply }
            if command.contains("display-message -p -t bromure:") { return "@41\n" }
            return ""
        }
        func isWorking() -> Bool { working }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
    }

    private func held(_ text: String, target: PaneTarget? = .chat(window: 3, windowID: "@41", display: nil, worktree: nil))
        -> QueuedMessage {
        QueuedMessage(text: text, held: true, editable: true, baseline: 0, target: target)
    }

    private func fastStore(_ url: URL? = nil) -> ChatQueueStore {
        let s = ChatQueueStore(fileURL: url)
        s.pollInterval = 0.02
        s.idleBeforeDelivery = 0.05
        return s
    }

    private func waitUntil(_ cond: () -> Bool, timeout: TimeInterval = 30) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("a held message survives the chat going away and is typed once the agent is idle")
    func deliveredOffScreen() async {
        let store = fastStore()
        let p = Provider()
        let chat = BeautifiedSessionModel(provider: p)
        chat.queueStore = store
        chat.draftKey = "local:ws:3"
        chat.start()
        store.update("local:ws:3") { $0.append(held("Q2: then reply exactly Q2-OK")) }
        #expect(chat.queued.count == 1)
        // The user selects another session: the chat model is torn down.
        chat.stop()
        #expect(store.isDraining("local:ws:3"))
        // Still working: nothing typed, the message waits.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(p.typed.isEmpty)
        #expect(store.messages("local:ws:3").count == 1)
        // The turn ends: typed into the window it was queued for, guarded.
        p.working = false
        await waitUntil { store.messages("local:ws:3").isEmpty }
        #expect(store.messages("local:ws:3").isEmpty)
        #expect(p.typed.count == 1)
        let cmd = p.typed.first ?? ""
        #expect(cmd.contains("'@41'"))                           // the window's own id
        #expect(cmd.contains(PaneTypeGuard.refusedMarker))       // identity + foreground guard
        #expect(cmd.contains(Data("Q2: then reply exactly Q2-OK".utf8).base64EncodedString()))
    }

    @Test("a chat shown again lists what is still queued, and takes delivery back")
    func shownAgain() async {
        let store = fastStore()
        let p = Provider()
        let first = BeautifiedSessionModel(provider: p)
        first.queueStore = store
        first.draftKey = "local:ws:3"
        first.start()
        store.update("local:ws:3") { $0.append(held("later")) }
        first.stop()
        #expect(store.isDraining("local:ws:3"))
        let again = BeautifiedSessionModel(provider: p)
        again.queueStore = store
        again.draftKey = "local:ws:3"
        #expect(again.queued.map(\.text) == ["later"])
        again.start()
        #expect(!store.isDraining("local:ws:3"))      // the chat on screen delivers
        #expect(store.isOwner("local:ws:3", again))
        again.stop()
    }

    @Test("a refused delivery keeps the message, says why, and stops trying")
    func refusedIsShown() async {
        let store = fastStore()
        let p = Provider()
        p.working = false
        p.typeReply = PaneTypeGuard.refusedMarker + " identity"
        store.attach("k", owner: p, driver: nil)
        store.update("k") { $0.append(held("for the old tab")) }
        store.setDriver("k", ChatQueueStore.Driver(isWorking: { p.isWorking(window: 3) },
                                                   deliver: { await p.deliverQueued($0, target: $1) }))
        store.detach("k", owner: p)
        await waitUntil { store.messages("k").first?.failure != nil }
        let q = store.messages("k").first
        #expect(q?.failure == ChatQueueStore.failureText(.identity))
        #expect(q?.sending == false)
        #expect(!ChatQueueStore.deliverable(q!))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(p.typed.count == 1)                   // not retried into a stranger
    }

    @Test("a menu up in the tab holds the message for the next try")
    func heldByMenu() async {
        let store = fastStore()
        let p = Provider()
        p.working = false
        p.typeReply = CodingTaskEngine.typeHeldMarker
        let driver = ChatQueueStore.Driver(isWorking: { false }, deliver: { await p.deliverQueued($0, target: $1) })
        store.update("k") { $0.append(held("wait for the menu")) }
        let outcome = await store.deliverHeld("k", driver: driver, fallback: nil)
        #expect(outcome == .held)
        #expect(store.messages("k").count == 1)
        #expect(store.messages("k").first?.sending == false)
        #expect(store.messages("k").first?.failure == nil)
    }

    @Test("two held messages go in as one, in order")
    func batched() async {
        let store = fastStore()
        var got: [String] = []
        let driver = ChatQueueStore.Driver(isWorking: { false }, deliver: { t, _ in got.append(t); return .typed })
        store.update("k") { $0 += [held("one"), held("two")] }
        _ = await store.deliverHeld("k", driver: driver, fallback: nil)
        #expect(got == ["one\n\ntwo"])
        #expect(store.messages("k").isEmpty)
    }

    @Test("the queue persists across a relaunch: held kept, stale native and mid-send reset")
    func persists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ChatQueueStore(fileURL: url)
        var sending = held("mid-send")
        sending.sending = true
        a.update("local:ws:3") { $0 += [held("keep me"), sending] }
        a.update("ephemeral:x") { $0.append(held("demo only")) }
        let b = ChatQueueStore(fileURL: url)
        #expect(b.messages("local:ws:3").map(\.text) == ["keep me", "mid-send"])
        #expect(b.messages("local:ws:3").allSatisfy { !$0.sending })
        #expect(b.messages("local:ws:3").first?.target?.expectWindowID == "@41")
        #expect(b.messages("ephemeral:x").isEmpty)

        let now = Date()
        var oldNative = QueuedMessage(text: "in the agent's queue", held: false, editable: true, baseline: 0)
        oldNative.queuedAt = now.addingTimeInterval(-7_200)
        var oldHeld = held("ancient")
        oldHeld.queuedAt = now.addingTimeInterval(-8 * 86_400)
        let r = ChatQueueStore.restored(["k": [oldNative, oldHeld, held("fresh")]], now: now)
        #expect(r["k"]?.map(\.text) == ["fresh"])
    }
}

@Suite("Chat typing targets")
struct ChatTypingTargetTests {
    @Test("a chat's target pins the window id and the markers it carries")
    func chatTarget() {
        let t = PaneTarget.chat(window: 4, windowID: "@17", display: "K2", worktree: "wt/k2")
        #expect(t.ref == .windowID("@17"))
        #expect(t.expectWindowID == "@17")
        #expect(t.expectDisplay == "K2")
        #expect(t.expectWorktree == "wt/k2")
        #expect(t.foreground == .agent)
        let g = PaneTypeGuard.guardFunction(t)
        #expect(g.contains("'@17'") && g.contains("'K2'") && g.contains("'wt/k2'"))
        // No id known: the index, still checked against the markers.
        let byIndex = PaneTarget.chat(window: 4, windowID: nil, display: "", worktree: nil)
        #expect(byIndex.ref == .index(4))
        #expect(byIndex.expectDisplay == nil && byIndex.expectWindowID == nil)
        // A malformed id is never spliced.
        #expect(PaneTarget.chat(window: 4, windowID: "@1; rm", display: nil, worktree: nil).ref == .index(4))
    }

    @Test("keys and picker answers go through the guard, and nothing else is spliced")
    func guardedKeys() {
        let t = PaneTarget.chat(window: 2, windowID: "@9", display: nil, worktree: nil)
        let keys = PaneTypeGuard.keysCommand(target: t, keys: ["Down", "Enter", "; rm -rf /"])
        #expect(keys.hasPrefix(PaneTypeGuard.prelude(t)))
        #expect(keys.contains("_bg && tmux send-keys -t \"$_bt\" Down"))
        #expect(!keys.contains("rm -rf"))
        #expect(!keys.contains("bromure:2"))
        let answer = PaneTypeGuard.answerKeysCommand(target: t, keys: ["1", "Right", "Enter", "; rm -rf /"])
        #expect(answer.hasPrefix(PaneTypeGuard.prelude(t)))
        #expect(answer.contains("{ _bg || exit 1; \(PaneTypeGuard.pickerVisibleInTarget) && tmux send-keys -t \"$_bt\" -l 1; true; }"))
        #expect(answer.contains("{ _bg || exit 1; tmux send-keys -t \"$_bt\" Enter; }"))
        #expect(!answer.contains("rm -rf"))
        #expect(PaneTypeGuard.answerKeysCommand(target: t, keys: ["; rm -rf /"]).isEmpty)
        // The board's by-index entry point is guarded the same way.
        #expect(CodingTaskEngine.answerKeysCommand(tabIndex: 3, keys: ["1"])
                == PaneTypeGuard.answerKeysCommand(target: .index(3), keys: ["1"]))
    }

    @Test("a target round-trips through JSON (a queued message persists it)")
    func codable() throws {
        let t = PaneTarget.chat(window: 1, windowID: "@3", display: "x", worktree: nil)
        let back = try JSONDecoder().decode(PaneTarget.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
