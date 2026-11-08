import Foundation
import Testing
@testable import bromure_ac

/// Board report: the composer's Stop didn't always stop the agent. It sent
/// Esc, once, to every agent; Grok stops on Ctrl-C, and Claude running a
/// command can need a second Esc. Stop now sends the key the agent's own busy
/// line names (else its kind's), and once more while that line is still up.
@Suite("Stop sends the key each agent stops on")
struct StopKeyTests {
    typealias M = BeautifiedSessionModel

    @Test("the busy line says which key; else the agent's kind")
    func keys() {
        #expect(M.interruptKey(screen: "  ✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)\n", agent: "claude") == "Escape")
        #expect(M.interruptKey(screen: "◆ Run npm test 1m22s ↓20.6k [↓][stop]\n", agent: "grok") == "C-c")
        #expect(M.interruptKey(screen: "Thinking… (ctrl+c to interrupt)\n", agent: "kimi") == "C-c")
        #expect(M.interruptKey(screen: "• Working (5s • Esc to interrupt)\n", agent: "codex") == "Escape")
        // Nothing on screen says: the kind's.
        #expect(M.interruptKey(screen: "", agent: "grok") == "C-c")
        for kind in ["claude", "codex", "kimi", "omp", nil] as [String?] {
            #expect(M.interruptKey(screen: "> \n", agent: kind) == "Escape")
        }
        // The latest line wins (an old hint in the scrollback doesn't).
        #expect(M.interruptKey(screen: "esc to interrupt\n…\n◆ Run make [stop]\n", agent: "claude") == "C-c")
    }

    @Test("Stop and the Switchboard's phone STOP use it; a second press only while still busy")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        let start = try #require(v.range(of: "    func interrupt() {"))
        let body = v[start.upperBound...].prefix(2600)
        #expect(body.contains("let key = Self.interruptKey(screen: await self.paneTail(), agent: kind)"))
        #expect(!body.contains(#"pressKeys(["Escape"])"#))
        let again = try #require(body.range(of: "if self.stoppedTurnStillCurrent(turn), Self.screenShowsBusy(await self.paneTail()),"))
        #expect(body[again.upperBound...].prefix(400).contains("await self.provider.pressKeys([key])"))
        // omp's queue comes back on Esc only.
        #expect(body.contains(#"if key == "Escape", AgentQueueSupport.escapeRestoresQueue(kind)"#))
        let sb = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Switchboard.swift"), encoding: .utf8)
        #expect(sb.contains("let key = AgentInterrupt.key(screen: screen, agent: tool)"))
        #expect(M.screenShowsBusy("Thinking… (ctrl-c to interrupt)"))
        #expect(!sb.contains(#"send-keys -t bromure:\(w) Escape"#))
    }

    /// The finding (CWE-367): Stop drops the cue at once, so a message can go
    /// in before the second press is due; the new turn's busy line read as the
    /// old one still going, and the second Esc / Ctrl-C interrupted the new
    /// request. The second press (and omp's queue reclaim) is for the turn
    /// the Stop was for, only.
    @Test("a turn started after Stop is never hit by Stop's second press")
    func secondPressOnlyForTheStoppedTurn() throws {
        var gate = WorkingGate()
        gate.interrupt()
        let turn = gate.turns
        #expect(gate.sameTurn(as: turn))
        gate.userSent()                    // a send (or a held message typed in)
        #expect(!gate.sameTurn(as: turn))
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        let start = try #require(v.range(of: "    func interrupt() {"))
        let body = v[start.upperBound...].prefix(2200)
        let taken = try #require(body.range(of: "let turn = StopTurn(gate: gate.turns,"))
        let task = try #require(body.range(of: "Task { [weak self] in"))
        #expect(taken.lowerBound < task.lowerBound, "the turn is taken when Stop is pressed, not later")
        #expect(body.contains("await self.reclaimAfterEscape(restoring, turn: turn)"))
        let check = try #require(v.range(of: "private func stoppedTurnStillCurrent(_ turn: StopTurn) -> Bool {"))
        #expect(v[check.upperBound...].prefix(300).contains("guard gate.sameTurn(as: turn.gate), !sending else { return false }"))
        #expect(v[check.upperBound...].prefix(400).contains("queueStartedTurn(queueStore.messages(queueKey), since: turn.delivered)"))
        #expect(check.lowerBound < v.endIndex)
        let reclaim = try #require(v.range(of: "private func reclaimAfterEscape(_ restored: [QueuedMessage], turn: StopTurn) async {"))
        let rb = v[reclaim.upperBound...].prefix(2400)
        let guardAt = try #require(rb.range(of: "guard stoppedTurnStillCurrent(turn) else {"))
        let clear = try #require(rb.range(of: #"await runKeys(Array(repeating: ["C-u"]"#))
        #expect(guardAt.lowerBound < clear.lowerBound)
        // Off stage, the store's drain types held messages without the gate:
        // one delivered since the Stop (or being typed) is a new turn too.
        typealias M = BeautifiedSessionModel
        let old = QueuedMessage(text: "already in", held: false, editable: false, baseline: 0)
        var delivered = old; delivered.delivered = true
        var fresh = QueuedMessage(text: "typed since", held: true, editable: true, baseline: 0)
        #expect(!M.queueStartedTurn([delivered, fresh], since: [delivered.id]))
        fresh.delivered = true
        #expect(M.queueStartedTurn([delivered, fresh], since: [delivered.id]))
        var typing = QueuedMessage(text: "going in", held: true, editable: true, baseline: 0)
        typing.sending = true
        #expect(M.queueStartedTurn([typing], since: []))
        // Every turn start counts: a held one typed in (userSent), the
        // composer's send once typed (turnStarted).
        #expect(v.contains("self.gate.userSent()"))
        #expect(v.components(separatedBy: "self.gate.turnStarted()").count - 1 >= 2)
    }

    /// The finding: the composer's send counted a turn before it was typed.
    /// A send during omp's reclaim wait that failed, or was held, started no
    /// turn, yet the reclaim saw one and left the restored box alone — and
    /// the queue rows, never held, aged out of the strip undelivered.
    @Test("a send that fails or is held during the reclaim wait doesn't strand omp's queue")
    func failedSendKeepsTheStoppedTurn() throws {
        var gate = WorkingGate()
        gate.interrupt()
        let turn = gate.turns
        gate.userSending()                 // under way: the cue shows…
        #expect(!gate.interrupted)
        #expect(gate.sameTurn(as: turn))   // …but no turn yet (it may fail)
        gate.turnStarted()                 // typed in
        #expect(!gate.sameTurn(as: turn))

        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        // The composer's send: no turn counted up front, only once typed.
        #expect(!v.contains("        gate.userSent()                   // a fresh send"))
        #expect(v.contains("        gate.userSending()                // a fresh send supersedes any prior stop"))
        #expect(v.contains("if native, outcome == .typed {\n                    self.gate.turnStarted()"))
        #expect(v.contains("case .typed:\n                self.gate.turnStarted()\n            }"))
        // The reclaim waits out a send under way, then looks at the box again.
        let reclaim = try #require(v.range(of: "private func reclaimAfterEscape(_ restored: [QueuedMessage], turn: StopTurn) async {"))
        let rb = v[reclaim.upperBound...].prefix(3200)
        let wait = try #require(rb.range(of: "for _ in 0..<300 where sending {"))
        let again = try #require(rb.range(of: "if stoppedTurnStillCurrent(turn) { stillInBox = await ownInBox() }"))
        let guardAt = try #require(rb.range(of: "guard stoppedTurnStillCurrent(turn) else {"))
        #expect(wait.lowerBound < again.lowerBound && again.lowerBound < guardAt.lowerBound)
        // Seen in the box once, the queue is held even if that send left the
        // box empty or its own (.dropped, .unconfirmed); only C-u waits on
        // the box still showing it.
        let seen = try #require(rb.range(of: "guard inBox || stillInBox else {"))
        let clearIf = try #require(rb.range(of: "if stillInBox {"))
        let clear = try #require(rb.range(of: #"await runKeys(Array(repeating: ["C-u"]"#))
        let hold = try #require(rb.range(of: "l[i].held = true"))
        #expect(seen.lowerBound < clearIf.lowerBound && clearIf.lowerBound < clear.lowerBound)
        #expect(clear.lowerBound < hold.lowerBound)
        #expect(!rb[clearIf.upperBound..<hold.lowerBound].contains("return"), "holding never depends on the C-u")
    }
}
