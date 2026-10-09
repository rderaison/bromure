import Foundation
import Testing
@testable import bromure_ac

/// QA round 4 (2026-10-05): omp's large paste confirmed by its input box,
/// held messages behind an Esc or a menu no card shows, the /model card's
/// title, compaction rows, header fit, omp's context window, Bromure
/// blocks shown once, review reports for no-code tasks.
@Suite("QA round 4 fixes")
@MainActor
struct QARound4FixesTests {

    // MARK: 1 — a large paste whose Enter didn't take

    /// The pane as QA captured it (shots/omp2/omp-pane-21k-stuck.txt): omp
    /// folded the 21 KB paste into a chip, and the chip still sits in its
    /// input band — the Enter never took.
    private let stuckPane = """
                                                                                             Python Generators Explained in Markdown
    ╭── 📄 #1 ───╮
    │Please repl…│
    │L0001 kemub…│
    │L0002 erdsj…│
    │L0003 sjqpk…│
    ╰ +182 lines ╯
     π > ⬢ GLM-5.3-Flash-EXL3 > 📁 ~/omp2-long > ⑂ main ?1 ▶──────────15%─────────────────────────────────────╎──────┃─────────128K─
    ╰─ 📄 #1
    """

    /// After omp took a turn: its band is empty again.
    private let emptyPane = """
     ↻ F5 to Retry
     π > ⬢ GLM-5.3-Flash-EXL3 > 📁 ~/omp2-long > ⑂ main ?1 ▶───────────────22%────────────────────────────────╎──────┃─────────128K─
    ╰─
    """

    @Test("The stuck pane's input box still holds the paste chip; an emptied band holds nothing")
    func boxHoldsChip() {
        #expect(PaneTypeGuard.boxHolds(stuckPane))
        #expect(!PaneTypeGuard.boxHolds(emptyPane))
        // Coloured, as tmux captures it with -e: still the chip.
        let coloured = stuckPane.replacingOccurrences(of: "╰─ 📄 #1", with: "╰─ \u{1B}[38;5;245m📄 #1\u{1B}[0m")
        #expect(PaneTypeGuard.boxHolds(coloured))
    }

    /// A fake guest: the box probe returns `screens` in turn (the last one
    /// repeats), every Enter command answers `enterOut`.
    private final class FakeGuest {
        var screens: [String]
        var enterOut: String
        var enters = 0
        var probes = 0
        init(screens: [String], enterOut: String = PaneTypeGuard.typedMarker) {
            self.screens = screens; self.enterOut = enterOut
        }
        func exec(_ cmd: String) -> String? {
            if cmd.contains("capture-pane -p -e") {
                probes += 1
                return screens.count > 1 ? screens.removeFirst() : screens.first
            }
            if cmd.contains("send-keys") { enters += 1; return enterOut }
            return ""
        }
    }

    @Test("A 'typed' whose paste still sits in the box is pressed again, then 'not delivered'")
    func screenMovedIsNotEnough() async {
        let g = FakeGuest(screens: [stuckPane])
        let out = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.typedMarker,
                                                   exec: { g.exec($0) }, pause: 0)
        #expect(PaneTypeGuard.unconfirmed(in: out))
        #expect(!PaneTypeGuard.typed(in: out))
        #expect(g.enters == 2)
        #expect(ChatQueueStore.Outcome.of(out) == .unconfirmed)
    }

    @Test("A second Enter that empties the box confirms the turn")
    func secondEnterTakes() async {
        let g = FakeGuest(screens: [stuckPane, emptyPane])
        let out = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.typedMarker,
                                                   exec: { g.exec($0) }, pause: 0)
        #expect(ChatQueueStore.Outcome.of(out) == .typed)
        #expect(g.enters == 1)
    }

    @Test("An empty box after 'typed' is delivered; after 'unconfirmed' it's dropped, never 'in the box'")
    func emptyBoxVerdicts() async {
        let ok = FakeGuest(screens: [emptyPane])
        let typed = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.typedMarker,
                                                     exec: { ok.exec($0) }, pause: 0)
        #expect(ChatQueueStore.Outcome.of(typed) == .typed)
        #expect(ok.enters == 0)
        let lost = FakeGuest(screens: [emptyPane])
        let dropped = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.unconfirmedMarker,
                                                       exec: { lost.exec($0) }, pause: 0)
        #expect(ChatQueueStore.Outcome.of(dropped) == .dropped)
        #expect(lost.enters == 0)
    }

    @Test("A box that can't be read leaves the guest's verdict; a menu coming up holds")
    func unreadableAndHeld() async {
        let out = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.typedMarker,
                                                   exec: { _ in nil }, pause: 0)
        #expect(ChatQueueStore.Outcome.of(out) == .typed)
        let g = FakeGuest(screens: [stuckPane], enterOut: PaneTypeGuard.heldMarker)
        let held = await PaneTypeGuard.confirmTaken(target: .index(0), out: PaneTypeGuard.typedMarker,
                                                    exec: { g.exec($0) }, pause: 0)
        #expect(ChatQueueStore.Outcome.of(held) == .held)
        // A refusal or a failure passes through untouched (no probe at all).
        let refused = "\(PaneTypeGuard.refusedMarker) gone"
        let r = await PaneTypeGuard.confirmTaken(target: .index(0), out: refused, exec: { _ in Issue.record("probed"); return nil }, pause: 0)
        #expect(r == refused)
    }

    @Test("runType confirms an agent's Enter by its box; a shell command line isn't probed")
    func runTypeConfirms() async {
        let g = FakeGuest(screens: [stuckPane])
        let out = await PaneTypeGuard.runType(target: .index(0), text: "hello") { cmd in
            cmd.contains("load-buffer") ? PaneTypeGuard.typedMarker : g.exec(cmd)
        }
        #expect(out.map { ChatQueueStore.Outcome.of($0) } == .unconfirmed)
        var probed = false
        let shell = await PaneTypeGuard.runType(target: .index(0, foreground: .shell), text: "ls") { cmd in
            if cmd.contains("capture-pane -p -e") { probed = true }
            return PaneTypeGuard.typedMarker
        }
        #expect(shell == PaneTypeGuard.typedMarker)
        #expect(!probed)
    }

    // MARK: 2 — a dropped held message is retried, never "in the box"

    @Test("A held message whose type was dropped is marked delivered (re-held if no turn comes of it)")
    func droppedHeldIsDelivered() async {
        let store = ChatQueueStore(fileURL: nil)
        let key = "ephemeral:round4-\(UUID().uuidString)"
        store.update(key) {
            $0.append(QueuedMessage(text: "after esc", held: true, editable: true, baseline: 0,
                                    target: .index(1)))
        }
        let driver = ChatQueueStore.Driver(isWorking: { false }, deliver: { _, _ in .dropped })
        let outcome = await store.deliverHeld(key, driver: driver, fallback: nil)
        #expect(outcome == .dropped)
        let q = store.messages(key).first
        #expect(q?.failure == nil)
        #expect(q?.isDelivered == true)
        #expect(q?.held == false)
    }

    // MARK: 5 — /model's card title, /compact

    @Test("Claude's /model picker is titled by its heading, not the wrapped explanation's tail")
    func modelPickerTitle() {
        let screen = """
         Select model
         Switch between Claude models. Your pick becomes the default for new sessions. For
         other/previous model names, specify with --model.

         ❯ 1. Default (recommended) ✔  Use the default model (currently Opus 5.5 (1M context))
           2. Opus (1M context)         Opus 5.5 with 1M context
           3. Sonnet                    Sonnet 5

         Enter to confirm · Esc to exit
        """
        let p = TerminalPrompt.detect(inScreen: screen, agent: "claude")
        #expect(p?.kind == .picker)
        #expect(p?.title == "Select model")
        #expect(p?.options.count == 3)
    }

    @Test("A compaction summary is one folded row, not a message of yours")
    func compactSummaryRow() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-10-05T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}"#,
            #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context. Summary: …"}}"#,
        ]
        let items = ClaudeTranscriptParser.parse(Data(lines.joined(separator: "\n").utf8))
        let users = items.filter { if case .userText = $0.kind { return true }; return false }
        #expect(users.count == 1)
        guard case .toolUse(let name, _, let detail)? = items.last?.kind else {
            Issue.record("no compaction row"); return
        }
        #expect(name == "Compact")
        #expect(detail.hasPrefix("This session is being continued"))
    }

    @Test("/compact (with instructions or not) is a turn of its own")
    func compactCommand() {
        #expect(BeautifiedSessionModel.isCompactCommand("/compact"))
        #expect(BeautifiedSessionModel.isCompactCommand("/compact keep the API notes"))
        #expect(!BeautifiedSessionModel.isCompactCommand("/compaction"))
        #expect(!BeautifiedSessionModel.isCompactCommand("/model"))
    }

    // MARK: 6 — header fit

    @Test("A tight header shortens the folder to its last part")
    func shortFolder() {
        #expect(SessionHeaderShort.short("~/.bromure/worktrees/qa-omp2-add-sub-261005-2007") == "…/qa-omp2-add-sub-261005-2007")
        #expect(SessionHeaderShort.short("~/cc-demo") == "…/cc-demo")
        #expect(SessionHeaderShort.short("/") == "/")
    }

    // MARK: 7 — omp's context window

    @Test("omp stages the window the Models pane shows for its model, even from another row")
    func ompContextFromAnyRow() {
        var s = ModelSettings()
        var big = ModelRef(source: .localServer, modelID: "GLM-5.3-Flash-EXL3")
        big.capabilities.contextWindow = 1_000_000
        s.agentTiers[.omp] = [.large: big]
        #expect(Profile.contextWindow(ofModel: "GLM-5.3-Flash-EXL3", in: s) == 1_000_000)
        #expect(Profile.contextWindow(ofModel: "other", in: s) == nil)
    }

    // MARK: 8 — Bromure blocks

    @Test("A Bromure block shows as its row, never as a red card too")
    func blockShownOnce() {
        let block = SessionFailure(kind: .blocked, detail: "API error (status 451)")
        #expect(BeautifiedSessionModel.cardFailure(block) == nil)
        let auth = SessionFailure(kind: .auth, detail: "401")
        #expect(BeautifiedSessionModel.cardFailure(auth) == auth)
        let err = AgentAPIError(kind: .other, status: 451, message: "API error (status 451 …): Request blocked")
        let items = [TranscriptItem(id: 0, kind: .userText("hi")), TranscriptItem(id: 1, kind: .agentError(err))]
        #expect(BeautifiedSessionModel.endsOnBlock(items))
        #expect(!BeautifiedSessionModel.endsOnBlock(Array(items.prefix(1))))
    }

    // MARK: 9 — the review's final report

    @Test("A no-code task's final report carries its last turn's messages, not only the wrap-up")
    func finalReportTurn() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Write a haiku"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Autumn moonlight—\na worm digs silently\ninto the chestnut."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I wrote the haiku in the chat above."}]}}"#,
        ]
        let report = TaskReviewSummary.finalReport(fromTranscript: lines.joined(separator: "\n"), agent: "claude")
        #expect(report?.contains("Autumn moonlight") == true)
        #expect(report?.hasSuffix("I wrote the haiku in the chat above.") == true)
    }
}

private enum SessionHeaderShort {
    static func short(_ p: String) -> String { SessionHeaderView.shortFolder(p) }
}
