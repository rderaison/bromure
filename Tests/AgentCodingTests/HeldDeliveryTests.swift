import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Held messages across dialogs and fresh starts: Codex's update prompt
/// (CX-4) and a fresh Kimi session's opening message (stuck behind the
/// chat's own "thinking" seed).
@Suite("Held message delivery")
@MainActor
struct HeldDeliveryTests {

    private final class Provider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        var window: Int? = 3
        var working = false
        var typeReply = PaneTypeGuard.typedMarker
        var typed: [String] = []
        func activeTabIndex() -> Int? { window }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("base64 -d") { typed.append(command); return typeReply }
            if command.contains("display-message -p -t bromure:") { return "@41\n" }
            return ""
        }
        func isWorking() -> Bool { working }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
    }

    private func held(_ text: String) -> QueuedMessage {
        QueuedMessage(text: text, held: true, editable: true, baseline: 0,
                      target: .chat(window: 3, windowID: "@41", display: nil, worktree: nil))
    }

    private func fastStore() -> ChatQueueStore {
        let s = ChatQueueStore(fileURL: nil)
        s.pollInterval = 0.02
        s.idleBeforeDelivery = 0.05
        return s
    }

    private func waitUntil(_ cond: () -> Bool, timeout: TimeInterval = 20) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("A fresh session's held opening message goes in while the seed still shows thinking")
    func openingNotBlockedBySeed() async {
        let store = fastStore()
        let p = Provider()
        let chat = BeautifiedSessionModel(provider: p)
        chat.queueStore = store
        chat.draftKey = "local:ws:kimi-open"
        chat.start()
        chat.seedOpening("Reply with the single word READY.")
        #expect(chat.working)                    // the cue is up…
        store.update("local:ws:kimi-open") { $0.append(held("Reply with the single word READY.")) }
        // …but the agent has nothing yet: the message is typed, not held
        // until the seed's two minutes run out.
        await waitUntil({ store.messages("local:ws:kimi-open").first?.isDelivered == true }, timeout: 40)
        #expect(p.typed.count == 1)
        #expect(store.messages("local:ws:kimi-open").first?.isDelivered == true)
        chat.stop()
    }

    @Test("A message held by a dialog is typed once it closes, after a fresh idle stretch")
    func heldThenTyped() async {
        let store = fastStore()
        let p = Provider()
        p.typeReply = PaneTypeGuard.heldMarker          // Codex's update prompt is up
        store.update("k") { $0.append(held("HELDMSG reply BRAVO")) }
        store.setDriver("k", ChatQueueStore.Driver(isWorking: { p.working },
                                                   deliver: { await p.deliverQueued($0, target: $1) }))
        store.attach("k", owner: p, driver: nil)
        store.detach("k", owner: p)
        await waitUntil { store.messages("k").first?.waitingOnDialog == true }
        #expect(store.messages("k").first?.held == true)
        #expect(store.messages("k").first?.isDelivered == false)
        // The user answers "Skip": the dialog is gone.
        p.typeReply = PaneTypeGuard.typedMarker
        await waitUntil { store.messages("k").first?.isDelivered == true }
        #expect(store.messages("k").count == 1)          // never dropped on the way
        #expect(store.messages("k").first?.isDelivered == true)
    }

    @Test("Never delivered unless the guarded type said so")
    func onlyTypedCounts() async {
        let store = fastStore()
        store.update("k") { $0.append(held("x")) }
        for reply in ["", "garbage", PaneTypeGuard.heldMarker] {
            let d = ChatQueueStore.Driver(isWorking: { false }, deliver: { _, _ in ChatQueueStore.Outcome.of(reply) })
            _ = await store.deliverHeld("k", driver: d, fallback: nil)
            #expect(store.messages("k").first?.isDelivered == false)
            store.update("k") { l in for i in l.indices { l[i].failure = nil } }
        }
    }

    @Test("A queue saved before redeliveries existed still loads")
    func legacyDecodes() throws {
        let json = #"{"id":"7B1E5B4E-1C33-4D2B-9F62-0C2F7B1D7E11","text":"x","queuedAt":0,"held":true,"editable":true,"baseline":0,"offset":0,"sending":false,"delivered":true}"#
        let q = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(q.redeliveries == nil && q.isDelivered)
    }
}

/// Board: a message sent while the agent is busy reads "Queued" though the agent
/// already has it. Claude, omp and Codex take it into their own queue at once.
@Suite("A message sent to a busy agent says where it is")
@MainActor
struct HandedOverTests {
    private final class Provider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        var typeReply = PaneTypeGuard.typedMarker
        var typed = 0
        var turn: String?
        func activeTabIndex() -> Int? { 3 }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("base64 -d") { typed += 1; return typeReply }
            if command.contains("display-message -p -t bromure:") { return "@41\n" }
            if command.contains("pane_current_path") { return "/home/ubuntu/w\n0\n" }
            guard command.hasPrefix("f=\"\";"), let turn else { return "" }
            let line = #"{"type":"user","message":{"role":"user","content":"\#(turn)"},"timestamp":"2026-11-04T16:24:00Z"}"# + "\n"
            return "/home/ubuntu/.claude/projects/p/s.jsonl\n\n\(line.utf8.count)\n0\n\(line.utf8.count)\n" + line
        }
        func isWorking() -> Bool { true }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
    }

    private func chat(_ p: Provider, agent: String, key: String) -> (BeautifiedSessionModel, ChatQueueStore) {
        let store = ChatQueueStore(fileURL: nil)
        let m = BeautifiedSessionModel(provider: p)
        m.queueStore = store
        m.draftKey = key
        m.loadSlashCommands(agent: agent, cwd: nil)
        m.working = true
        return (m, store)
    }

    private func waitUntil(_ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(20)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("typed into the agent's own queue: the row says the agent has it")
    func handedOver() async {
        for agent in ["claude", "omp", "codex"] {
            let p = Provider()
            let key = "handed-\(agent)-\(UUID().uuidString)"
            let (m, store) = chat(p, agent: agent, key: key)
            m.composerText = "next please"
            m.send()
            await waitUntil { store.messages(key).first?.agentHasIt == true && !m.sending }
            let q = store.messages(key).first
            #expect(p.typed == 1, "\(agent)")
            #expect(q?.agentHasIt == true, "\(agent)")
            #expect(q?.handedOver == true && q?.isDelivered == false, "still recallable, never retyped: \(agent)")
            #expect(q?.held == false, "\(agent)")
            #expect(!m.sending)
            m.stop()
        }
    }

    @Test("not typed, or held for later: it doesn't claim the agent has it")
    func notHanded() async {
        // A menu came up: nothing went in.
        let p = Provider()
        p.typeReply = PaneTypeGuard.heldMarker
        let key = "handed-held-\(UUID().uuidString)"
        let (m, store) = chat(p, agent: "claude", key: key)
        m.composerText = "next please"
        m.send()
        await waitUntil { store.messages(key).first?.held == true }
        #expect(store.messages(key).first?.agentHasIt == false)
        m.stop()
        // An agent whose queue Bromure holds for it: not typed until it's idle.
        let p2 = Provider()
        let key2 = "handed-kimi-\(UUID().uuidString)"
        let (m2, store2) = chat(p2, agent: "kimi", key: key2)
        m2.composerText = "next please"
        m2.send()
        await waitUntil { !store2.messages(key2).isEmpty && !m2.sending }
        #expect(p2.typed == 0)
        #expect(store2.messages(key2).first?.agentHasIt == false)
        m2.stop()
    }

    @Test("the row goes as soon as the turn is there, without waiting for the next poll")
    func resolves() async {
        let p = Provider()
        let key = "handed-turn-\(UUID().uuidString)"
        let (m, store) = chat(p, agent: "claude", key: key)
        m.composerText = "the message I just sent"
        p.turn = "the message I just sent"
        m.send()
        await waitUntil { store.messages(key).isEmpty }
        #expect(store.messages(key).isEmpty)
        m.stop()
    }

    @Test("a turn that came out altered still resolves it, once the agent has it")
    func altered() {
        var q = QueuedMessage(text: "please look at the login page and fix the redirect", held: false, editable: true, baseline: 0)
        #expect(!q.agentHasIt)
        q.handedOver = true
        #expect(q.agentHasIt)
        #expect(BeautifiedSessionModel.typedBecame(q.text, turn: "please look at the login page and fix the redirect[Pasted text]"))
    }

    @Test("an old saved queue, with no such field, still loads")
    func oldRows() throws {
        let q = QueuedMessage(text: "x", held: true, editable: true, baseline: 0)
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: Any]
        o["handedOver"] = nil
        let back = try JSONDecoder().decode(QueuedMessage.self, from: JSONSerialization.data(withJSONObject: o))
        #expect(back.handedOver == nil && !back.agentHasIt)
    }
}
