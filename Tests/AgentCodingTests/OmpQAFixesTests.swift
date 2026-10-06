import Foundation
import Testing
@testable import bromure_ac

/// omp QA round: confirmed delivery (a paste chip swallowed the Enter), its
/// band composer read as an input box (the status bar was a "draft"), the
/// queue omp hands back on Esc, and resuming omp's own conversation by id.
@Suite("omp QA fixes")
@MainActor
struct OmpQAFixesTests {

    // MARK: Input box (omp's band composer)

    private let dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    /// omp 18.x band composer, as `capture-pane -e` returns it: the status
    /// bar on top, the `╰─ ` gutter row below it.
    private func band(_ input: String, above: [String] = []) -> String {
        (["● Done. The file is written."] + above + [
            "",
            " π > ⬢ GLM-5.3-Flash-EXL3 > 📁 ~/reply-word ▶────────────────────────────",
            "╰─ " + input,
        ]).joined(separator: "\n")
    }

    @Test("omp's status bar is never a draft; its empty band box is empty")
    func ompEmptyBox() {
        #expect(AgentInputBox.content(band("")) == .empty)
        // Its placeholder is dim.
        #expect(AgentInputBox.content(band("\(dim)Ask anything\(reset)")) == .empty)
        // The status bar alone (a capture cut above the gutter) is no box at all.
        let barOnly = " π > ⬢ GLM-5.3 > 📁 ~/x ▶──────────────"
        #expect(AgentInputBox.content(barOnly) == .unknown)
        #expect(AgentInputBox.isStatusBar(barOnly))
        #expect(!AgentInputBox.isStatusBar("> what does this do?"))
        #expect(!AgentInputBox.isStatusBar(String(repeating: "─", count: 30)))
    }

    @Test("Text behind omp's gutter is a draft; its queue above the bar is not")
    func ompDraft() {
        #expect(AgentInputBox.content(band("/exit")) == .text("/exit"))
        #expect(AgentInputBox.content(band("📄 #1 +182 lines")) == .text("📄 #1 +182 lines"))
        // The queue band sits above the status bar: not the input box.
        let queued = band("", above: ["Steering · 1", "  1. after that, say DONE", "  ╰─ ⌥↑ to edit"])
        #expect(AgentInputBox.content(queued) == .empty)
        // Esc put the queue back into the box: ours, recognized as such.
        if case .text(let d) = AgentInputBox.content(band("Queued: after that, say DONE")) {
            #expect(AgentInputBox.isOwn(d, of: "Queued: after that, say DONE"))
        } else {
            Issue.record("expected the restored text in the box")
        }
    }

    @Test("A cursor parked on omp's status bar says nothing about the input")
    func ompCursorOnStatusBar() {
        var screen = Array(repeating: "", count: 20)
        screen[17] = " π > ⬢ GLM-5.3 > 📁 ~/x ▶──────────────"
        screen[18] = "╰─ "
        let head = "1 \(screen[17].count) 17 20"
        #expect(AgentInputBox.cursorContent(([head] + screen).joined(separator: "\n")) == .unknown)
        // On the gutter row: empty, or what's typed after it.
        #expect(AgentInputBox.cursorContent((["1 3 18 20"] + screen).joined(separator: "\n")) == .empty)
        screen[18] = "╰─ hello"
        #expect(AgentInputBox.cursorContent((["1 8 18 20"] + screen).joined(separator: "\n")) == .text("hello"))
    }

    // MARK: Confirmed delivery

    @Test("A typed message settles, then its Enter is confirmed by the screen moving")
    func typeCommandConfirms() {
        let cmd = PaneTypeGuard.typeCommand(target: PaneTarget.index(2), text: "hi")
        #expect(cmd.contains("_bsettle"))
        #expect(cmd.contains(PaneTypeGuard.unconfirmedMarker))
        #expect(!cmd.contains("&& sleep 1 &&"))
        #expect(ChatQueueStore.Outcome.of("…\(PaneTypeGuard.unconfirmedMarker)") == .unconfirmed)
        #expect(ChatQueueStore.Outcome.of(PaneTypeGuard.typedMarker) == .typed)
        // A shell command line keeps its plain Enter.
        let shell = PaneTypeGuard.typeCommand(target: PaneTarget.index(2, foreground: .shell), text: "ls")
        #expect(!shell.contains("_bsettle"))
    }

    /// Runs `confirmedEnter` against a stub tmux whose screen changes on
    /// Enter unless it swallows the first `swallow` of them.
    private func runConfirm(swallow: Int) throws -> (out: String, keys: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omp-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state").path
        let sw = dir.appendingPathComponent("swallow").path
        let keys = dir.appendingPathComponent("keys").path
        try "╰─ 📄 #1 +182 lines\n".write(toFile: state, atomically: true, encoding: .utf8)
        try "\(swallow)\n".write(toFile: sw, atomically: true, encoding: .utf8)
        let stub = """
        #!/bin/bash
        case "$1" in
          capture-pane) cat "\(state)" ;;
          send-keys) echo k >> "\(keys)"; n=$(cat "\(sw)")
            if [ "$n" -gt 0 ]; then echo $((n-1)) > "\(sw)"; else echo "● RECEIVED" > "\(state)"; fi ;;
        esac
        """
        let tmux = dir.appendingPathComponent("tmux")
        try stub.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "_bt=x; _bg() { true; }; _bm() { false; }; "
                       + PaneTypeGuard.confirmFunctions + PaneTypeGuard.confirmedEnter]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let n = ((try? String(contentsOfFile: keys, encoding: .utf8)) ?? "").split(separator: "\n").count
        return (out, n)
    }

    @Test("An Enter the agent swallows is pressed once more; twice swallowed is not delivered")
    func confirmedEnterRetries() throws {
        let ok = try runConfirm(swallow: 0)
        #expect(ok.out.contains(PaneTypeGuard.typedMarker) && ok.keys == 1)
        let retried = try runConfirm(swallow: 1)
        #expect(retried.out.contains(PaneTypeGuard.typedMarker) && retried.keys == 2)
        let lost = try runConfirm(swallow: 5)
        #expect(lost.out.contains(PaneTypeGuard.unconfirmedMarker) && lost.keys == 2)
    }

    @Test("Esc hands omp's queue back to its input box: Bromure takes it back")
    func escapeRestoresQueue() {
        #expect(AgentQueueSupport.escapeRestoresQueue("omp"))
        #expect(!AgentQueueSupport.escapeRestoresQueue("claude"))
        #expect(!AgentQueueSupport.escapeRestoresQueue(nil))
    }

    // MARK: Resume by id

    private let id = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    @Test("omp's session id is read off its file name, path and exit line")
    func ompIDs() throws {
        let path = "/home/ubuntu/.omp/agent/sessions/--home-ubuntu-app--/2026-10-05T12-34-56-789Z_\(id).jsonl"
        #expect(AgentSessionEngine.ompConversationID(inPath: path) == id)
        #expect(AgentSessionEngine.transcriptID(fromFileName: "2026-10-05T12-34-56-789Z_\(id)") == id)
        #expect(AgentSessionEngine.ompConversationID(inPath: "/tmp/notes.jsonl") == nil)
        // uuidv7: its own clock.
        #expect(AgentSessionEngine.ompConversationStart(inPath: path) != nil)
        // A v4 id: the file name's timestamp.
        let v4 = "/h/.omp/agent/sessions/x/2026-10-05T12-34-56-789Z_3f2504e0-4f89-41d3-9a0c-0305e82c3301.jsonl"
        let d = try #require(AgentSessionEngine.ompConversationStart(inPath: v4))
        #expect(abs(d.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-10-05T12:34:56Z")!)) < 1)
        // The exit line.
        #expect(AgentSessionEngine.ompResumeID(inScreen: "Bye!\nResume with: omp --resume \(id)\n$ ") == id)
        #expect(AgentSessionEngine.ompResumeID(inScreen: "omp --profile work --resume \(id)") == id)
        #expect(AgentSessionEngine.ompResumeID(inScreen: "grok --resume \(id)") == nil)
    }

    @Test("A session that knows its omp conversation resumes it by id, and reads only its file")
    func ompResumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .omp, title: "Farewell", cwd: "~/app")
        #expect(AgentSessionEngine.resumeFlags(for: s) == "--continue")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = id
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "--resume \(id)")
        let pin = TranscriptPin.conversation(tool: "omp", id: id)
        #expect(pin.ompSession == id)
        #expect(AgentSessionLocator.ompPinnedFragment(id: id, into: "f").contains("_\(id).jsonl"))
        #expect(AgentSessionLocator.ompPinnedFragment(id: "x; rm -rf /", into: "f").isEmpty)
        var foreign = TranscriptPin()
        foreign.foreignConversations = [id]
        #expect(AgentSessionEngine.isForeignConversation(
            path: "/h/.omp/agent/sessions/x/2026-10-05T12-34-56-789Z_\(id).jsonl", agent: "omp", pin: foreign))
    }

    // MARK: omp's ask

    private let askScreen = """
     ● Thought
     ⎋ Asking user's preferred color
     ╭─ Ask ──────────────────────────────────────────╮
     │ Which color do you prefer?                     │
     ├────────────────────────────────────────────────┤
     │ ❯ ○ Red                                        │
     │       A warm color                             │
     │   ○ Green                                      │
     │       The color of plants                      │
     │   ○ Blue                                       │
     │   ○ Other                                      │
     ├────────────────────────────────────────────────┤
     │ enter select · n note · ↑/↓ scroll · esc cancel │
     ╰────────────────────────────────────────────────╯
    """

    @Test("omp's Ask dialog: the question, clean labels with their descriptions, no screen junk")
    func ompAskDialog() throws {
        guard case .prompt(let p)? = TerminalScan.classify(askScreen, agent: "omp") else {
            Issue.record("no prompt"); return
        }
        #expect(p.kind == .picker)
        #expect(p.title == "Which color do you prefer?")
        #expect(p.options.map(\.label) == ["Red", "Green", "Blue", "Other"])
        #expect(p.options.map(\.detail) == ["A warm color", "The color of plants", nil, nil])
        #expect(p.selectedOption == 1)
        #expect(!p.detail.contains("Ask ─"))
        #expect(!p.detail.contains("Asking user"))
    }

    @Test("omp's ask call becomes the answered question once its result is in")
    func ompAskTranscript() {
        let call = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"ask","arguments":{"questions":[{"id":"color","question":"Which color do you prefer?","options":[{"label":"Red","description":"warm"},{"label":"Green"}]}]},"intent":"Asking user's preferred color"}]}}"#
        let result = #"{"type":"message","message":{"role":"toolResult","toolName":"ask","toolCallId":"c1","isError":false,"content":[{"type":"text","text":"User selected: Green"}]}}"#
        // Open: a plain step (the dialog on screen is how it's answered).
        let open = AgentTranscript.parse(Data(call.utf8), agent: "omp")
        #expect(open.contains { if case .toolUse(let n, _, _) = $0.kind { return n == "ask" }; return false })
        #expect(!open.contains { if case .question = $0.kind { return true }; return false })
        // Answered: the question with the pick, no separate result row.
        let done = AgentTranscript.parse(Data((call + "\n" + result).utf8), agent: "omp")
        let qs = done.compactMap { if case .question(let q) = $0.kind { return q }; return nil }
        #expect(qs.count == 1)
        #expect(qs.first?.answer == "Green")
        #expect(qs.first?.options.first?.description == "warm")
        #expect(!done.contains { if case .toolResult = $0.kind { return true }; return false })
        // Esc: declined.
        let esc = result.replacingOccurrences(of: #""isError":false"#, with: #""isError":true"#)
            .replacingOccurrences(of: "User selected: Green", with: "Ask tool was cancelled by the user")
        let declined = AgentTranscript.parse(Data((call + "\n" + esc).utf8), agent: "omp")
            .compactMap { if case .question(let q) = $0.kind { return q }; return nil }
        #expect(declined.first?.declined == true)
        // Several questions: "<id>: answer".
        let two = OmpTranscriptParser.answeredAsk(
            [TranscriptQuestion(question: "A?", header: "a", multiSelect: false, options: []),
             TranscriptQuestion(question: "B?", header: "b", multiSelect: true, options: [])],
            result: "User answers:\na: Red\nb: [X, Y]", isError: false)
        #expect(two.map(\.answer) == ["Red", "X, Y"])
    }

    // MARK: Landing with pending comments

    @Test("Landing says when review comments never reached the agent")
    func pendingAtLanding() {
        #expect(TaskPlurals.pendingAtLanding(1).hasPrefix("1 review comment"))
        #expect(TaskPlurals.pendingAtLanding(3).hasPrefix("3 review comments"))
    }
}
