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
            // Most specific first: the read and the probe hold the window-id
            // check's words too.
            if command.hasPrefix("f=\"\";") {
                guard let turn else { return "" }
                let line = #"{"type":"user","message":{"role":"user","content":"\#(turn)"},"timestamp":"2026-11-04T16:24:00Z"}"# + "\n"
                return "/home/ubuntu/.claude/projects/p/s.jsonl\n\n\(line.utf8.count)\n0\n\(line.utf8.count)\n" + line
            }
            if command.contains("pane_current_path") { return "/home/ubuntu/w\n0\n" }
            if command.contains("display-message -p -t bromure:") { return "@41\n" }
            return ""
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

    @Test("the row stays until its turn is in the transcript, then goes")
    func resolves() async {
        let p = Provider()
        let key = "handed-turn-\(UUID().uuidString)"
        let (m, store) = chat(p, agent: "claude", key: key)
        m.composerText = "the message I just sent"
        m.send()
        // On the strip first: empty before the send has even queued it proves nothing.
        await waitUntil { store.messages(key).first?.agentHasIt == true && !m.sending }
        #expect(store.messages(key).count == 1)
        #expect(p.typed == 1)
        // The turn appears; `working` holds, so only the transcript can clear it.
        p.turn = "the message I just sent"
        m.start()
        await waitUntil { store.messages(key).isEmpty }
        #expect(store.messages(key).isEmpty, "\(m.items.count) items")
        #expect(m.items.contains { if case .userText(let t) = $0.kind { return t == "the message I just sent" } else { return false } })
        m.stop()
    }

    @Test("a turn that came out altered still resolves it, once the agent has it")
    func altered() {
        var q = QueuedMessage(text: "please look at the login page and fix the redirect", held: false, editable: true, baseline: 0)
        #expect(!q.agentHasIt)
        q.handedOver = true
        #expect(q.agentHasIt)
        // Taken back (omp's Esc) or found lost: on hold here again, and it says so.
        q.held = true
        #expect(!q.agentHasIt)
        q.held = false
        q.delivered = true
        q.handedOver = nil
        #expect(q.agentHasIt)
        q.held = true
        #expect(!q.agentHasIt)
        q.held = false
        #expect(BeautifiedSessionModel.typedBecame(q.text, turn: "please look at the login page and fix the redirect[Pasted text]"))
    }

    @Test("a message sent with files resolves once its turn is in, though the paths became attachments")
    func withFiles() {
        typealias M = BeautifiedSessionModel
        let dir = GuestDrop.baseDir
        let typed = "look at this screenshot \(dir)/20261105_shot.png \(dir)/20261105_log.txt"
        // Claude's turn: the image as a placeholder, the other path kept or dropped.
        #expect(M.attachmentTurnArrived(typed, since: ["look at this screenshot [Image #1] \(dir)/20261105_log.txt"][...]))
        #expect(M.attachmentTurnArrived(typed, since: ["look at this screenshot"][...]))
        // Not a turn that says something else, nor no turn at all.
        #expect(!M.attachmentTurnArrived(typed, since: ["something else entirely"][...]))
        #expect(!M.attachmentTurnArrived(typed, since: [][...]))
        // Only files: any turn since is it.
        let onlyFiles = "\(dir)/20261105_shot.png"
        #expect(M.attachmentTurnArrived(onlyFiles, since: ["[Image #1]"][...]))
        #expect(!M.attachmentTurnArrived(onlyFiles, since: [][...]))
        // A message without files is matched as before, not by this.
        #expect(!M.attachmentTurnArrived("look at this screenshot", since: ["look at this screenshot"][...]))
        #expect(M.withoutAttachments("a [Image #12] b \(dir)/x.png  c") == "a b c")
    }

        @Test("the While you were away panel goes by itself after 3 s, not while the pointer is on it")
    func awayPanelTimesOut() throws {
        #expect(BeautifiedSessionView.whileAwayShownNanos == 3_000_000_000)
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        let panel = try #require(v.range(of: "WhileAwayPanel(summary: summary,"))
        let around = v[panel.upperBound...].prefix(1_200)
        #expect(around.contains(".onHover { hoveringAway = $0 }"))
        #expect(around.contains(".task(id: summary) {") && around.contains("while hoveringAway, !Task.isCancelled {"))
        #expect(around.contains("guard !Task.isCancelled, whileAway == summary else { return }"))
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
