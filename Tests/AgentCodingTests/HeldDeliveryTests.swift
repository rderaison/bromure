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
