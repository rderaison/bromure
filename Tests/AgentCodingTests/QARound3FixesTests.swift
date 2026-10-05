import Foundation
import Testing
@testable import bromure_ac

/// QA round 3 (2026-10-05): Grok's approval at a narrow pane, exact typing
/// past composer completions, consent routing, per-session transcripts and
/// status, Grok titles and blocks, models, home paths, the quit wording.
@Suite("QA round 3 fixes")
@MainActor
struct QARound3FixesTests {

    // MARK: 1 — Grok's approval card at the default pane width (52 columns)

    /// Grok's approval as a 52-column pane draws it: option 1 wraps after
    /// its "(", the key-hint footer wraps onto two lines.
    private let grokNarrow = [
        "┃  Remove the specified drop file",
        "┃  rm -f /home/ubuntu/.bromure/drops/0_20261005-15",
        "┃  5647-8b45_x",
        "┃  1 (●) Yes, and don't ask again for anything (",
        "┃  always-approve mode)",
        "┃  2 (○) Yes, proceed",
        "┃  3 (○) No, reject (type to add feedback)",
        "  1/3:select  │  Tab:next option  │  ←/→:scope  │",
        "  Ctrl+o:always-approve  │  Ctrl+c:cancel",
    ]

    @Test("Grok at 52 columns: every option, wrapped labels joined, footer wraps ignored")
    func grokNarrowApproval() throws {
        let p = try #require(TerminalPrompt.detect(tail: grokNarrow, agent: "grok"))
        #expect(p.kind == .picker)
        #expect(p.options.map(\.label) == [
            "Yes, and don't ask again for anything (always-approve mode)",
            "Yes, proceed",
            "No, reject (type to add feedback)",
        ])
        #expect(p.selectedOption == 1)
        // Keys still count from Grok's own cursor.
        #expect(p.keys(picking: 2) == ["Down", "Enter"])
        #expect(p.keys(picking: 3) == ["Down", "Down", "Enter"])
    }

    @Test("A wrapped continuation indented under the label, and a longer footer, read the same")
    func grokNarrowVariants() throws {
        var screen = grokNarrow
        screen[4] = "┃        always-approve mode)"
        screen[6] = "┃  3 (○) No, reject (type to add"
        screen.insert("┃        feedback)", at: 7)
        screen += ["  Esc:cancel"]
        let p = try #require(TerminalPrompt.detect(tail: screen, agent: "grok"))
        #expect(p.options.count == 3)
        #expect(p.options[0].label.hasSuffix("(always-approve mode)"))
        #expect(p.options[2].label == "No, reject (type to add feedback)")
    }

    @Test("The same dialog at 120 columns gives the same options")
    func grokWideApproval() throws {
        let wide = [
            "┃  Remove the specified drop file",
            "┃  1 (●) Yes, and don't ask again for anything (always-approve mode)",
            "┃  2 (○) Yes, proceed",
            "┃  3 (○) No, reject (type to add feedback)",
            "  1/3:select  │  Tab:next option  │  ←/→:scope  │  Ctrl+o:always-approve  │  Ctrl+c:cancel",
        ]
        let narrow = try #require(TerminalPrompt.detect(tail: grokNarrow, agent: "grok"))
        let p = try #require(TerminalPrompt.detect(tail: wide, agent: "grok"))
        #expect(p.options == narrow.options)
    }

    @Test("A description line under a whole label is not joined into it")
    func descriptionsStayApart() {
        let lines = [
            "Pick one?",
            "❯ 1. Yes",
            "     Runs the command now.",
            "  2. No",
        ]
        let menu = AgentScreen.liveMenu(lines, after: -1)
        #expect(menu?.options.map(\.label) == ["Yes", "No"])
    }

    @Test("The card lists one-off answers first and never marks a blanket approval as the default")
    func cardOrdering() throws {
        let p = try #require(TerminalPrompt.detect(tail: grokNarrow, agent: "grok"))
        #expect(p.cardOptions.map(\.index) == [2, 3, 1])
        #expect(p.cardHighlight == 2)     // Yes, proceed — not always-approve
        // Four options with "allow once": that one is the marked default.
        let four = TerminalPrompt(kind: .picker, options: [
            LoginOption(index: 1, label: "Yes, and don't ask again for anything (always-approve mode)"),
            LoginOption(index: 2, label: "Yes, always allow neverssl.com for this project"),
            LoginOption(index: 3, label: "Yes, allow once"),
            LoginOption(index: 4, label: "No, reject (type to add feedback)"),
        ], selectedOption: 1)
        #expect(four.cardOptions.map(\.index) == [3, 4, 1, 2])
        #expect(four.cardHighlight == 3)
        // An ordinary picker keeps its cursor row as the default.
        let plain = TerminalPrompt(kind: .picker, options: [LoginOption(index: 1, label: "Yes"),
                                                            LoginOption(index: 2, label: "No")],
                                   selectedOption: 2)
        #expect(plain.cardHighlight == 2)
        #expect(plain.cardOptions.map(\.index) == [1, 2])
    }

    // MARK: 2 — typed text delivered exactly

    @Test("A message ending in a path or slash token gets a space: no completion popup takes the Enter")
    func completionSafe() {
        #expect(PaneTypeGuard.completionSafe("Run this shell command: touch /tmp/x && ls /tmp")
            == "Run this shell command: touch /tmp/x && ls /tmp ")
        #expect(PaneTypeGuard.completionSafe("look at @src/main.swift") == "look at @src/main.swift ")
        #expect(PaneTypeGuard.completionSafe("open src/app.py") == "open src/app.py ")
        // Already safe, or a sole slash command, or nothing to complete.
        #expect(PaneTypeGuard.completionSafe("ls /tmp ") == "ls /tmp ")
        #expect(PaneTypeGuard.completionSafe("/model") == "/model")
        #expect(PaneTypeGuard.completionSafe("Reply with ALPHA.") == "Reply with ALPHA.")
        // Idempotent.
        let once = PaneTypeGuard.completionSafe("cd /tmp")
        #expect(PaneTypeGuard.completionSafe(once) == once)
    }

    @Test("The agent type command pastes the safe text; a shell line is typed as is")
    func typeCommandUsesSafeText() {
        let text = "touch /tmp/x && ls /tmp"
        let agent = PaneTypeGuard.typeCommand(target: .index(1), text: text)
        #expect(agent.contains(Data((text + " ").utf8).base64EncodedString()))
        var shell = PaneTarget.index(1)
        shell.foreground = .shell
        let sh = PaneTypeGuard.typeCommand(target: shell, text: text)
        #expect(sh.contains(Data(text.utf8).base64EncodedString()))
    }

    @Test("A delivered message the agent recorded a little changed still resolves its row")
    func deliveredRowResolves() {
        #expect(BeautifiedSessionModel.typedBecame("Run this shell command: touch /tmp/x && ls /tmp",
                                                   turn: "Run this shell command: touch /tmp/x && ls /timestamps"))
        #expect(!BeautifiedSessionModel.typedBecame("Run this shell command: touch /tmp/x && ls /tmp",
                                                    turn: "Reply with the single word BETA-grok"))
        #expect(!BeautifiedSessionModel.typedBecame("ok", turn: "ok then"))
    }

    // MARK: 4 — consent routing

    @Test("Only a fat client counts as a remote listener — not any /state reader")
    func fatClientOnly() {
        PendingPromptBroker.resetFatClientContact()
        defer { PendingPromptBroker.resetFatClientContact() }
        _ = PendingPromptBroker.shared.pendingList()   // a script polling /state
        #expect(!PendingPromptBroker.hasLiveListener())
        #expect(RemoteConsent.route(for: UUID()) == .localAlert)
        PendingPromptBroker.recordFatClientContact()
        #expect(PendingPromptBroker.hasLiveListener())
        #expect(RemoteConsent.route(for: UUID()) == .fatClient)
    }

    // MARK: 5 — countdown wording

    @Test("The countdown says what no answer does in the deny button's own words")
    func countdownWording() {
        let req = ConsentPanelPresenter.Request(
            profileID: UUID(), title: "t", message: "", choices: ["Block this request", "Allow this request"],
            denyIndex: 0, style: .warning, detailText: nil, timeout: 120)
        #expect(ConsentPanelWindow.countdownLine(secondsLeft: 9, request: req)
            == "No answer within 9 s means “Block this request”.")
    }

    // MARK: 6 / 7 — a session reads its own conversation

    @Test("Grok and Codex sessions read their own conversation's file, never the folder's newest")
    func pinnedConversations() throws {
        let gid = "019a1b2c-3d4e-7f00-8a9b-0c1d2e3f4a5b"
        let grok = TranscriptPin.conversation(tool: "grok", id: gid)
        #expect(grok.grokSession == gid)
        let g = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/gk-demo", since: 0, agent: "grok", pinnedWindow: 2, pin: grok,
            knownPath: nil, knownOffset: -1, bytes: 1000, earlier: false))
        #expect(g.contains("/.grok/sessions/*/\(gid)/updates.jsonl"))
        // Missing yet: nothing is read (no fall back to the newest).
        #expect(g.contains("[ -z \"$f\" ] && pe=1"))
        #expect(!g.contains("transcript-2.path"))

        let cid = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"
        let codex = TranscriptPin.conversation(tool: "codex", id: cid)
        #expect(codex.codexSession == cid)
        let c = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/qa", since: 0, agent: "codex", pinnedWindow: 1, pin: codex,
            knownPath: nil, knownOffset: -1, bytes: 1000, earlier: false))
        #expect(c.contains("rollout-*\(cid).jsonl"))
        // Not a uuid: no pin.
        #expect(TranscriptPin.conversation(tool: "grok", id: "x; rm -rf /") == TranscriptPin())
        #expect(TranscriptPin.conversation(tool: "codex", id: nil) == TranscriptPin())
    }

    private let ws = UUID()
    private let rolloutA = "0199aaaa-0000-7000-8000-00000000000a"
    private let rolloutB = "0199bbbb-0000-7000-8000-00000000000b"

    @Test("A Codex status report goes to the session whose conversation it names")
    func statusRouting() {
        var idle = AgentSession(profileID: ws, tool: .codex, title: "first", cwd: "~/qa", windowIndex: 1)
        idle.agentTranscriptID = rolloutA
        let fresh = AgentSession(profileID: ws, tool: .codex, title: "second", cwd: "~/qa", windowIndex: 2)
        let all = [idle, fresh]
        // The shared server filed the second session's turn under tab 1.
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: rolloutB, profileID: ws, sessions: all) == 2)
        // Its own conversation: its own tab.
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: rolloutA, profileID: ws, sessions: all) == 1)
        // No id (an older reporter, a non-uuid): as filed.
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: nil, profileID: ws, sessions: all) == 1)
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: "", profileID: ws, sessions: all) == 1)
        // Once pinned, the second's reports find it by id from any tab.
        var pinned = fresh
        pinned.agentTranscriptID = rolloutB
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: rolloutB, profileID: ws,
                                               sessions: [idle, pinned]) == 2)
        // Ambiguous (two unpinned Codex beside it): dropped, never stamped on the idle one.
        let third = AgentSession(profileID: ws, tool: .codex, title: "third", cwd: "~/qa", windowIndex: 3)
        #expect(AgentSessionStore.statusWindow(index: 1, conversation: rolloutB, profileID: ws,
                                               sessions: [idle, fresh, third]) == nil)
    }

    @Test("A Codex tab's hook record naming another session's rollout doesn't re-pin it")
    func probedConversationGuard() {
        var idle = AgentSession(profileID: ws, tool: .codex, title: "first", cwd: "~/qa", windowIndex: 1)
        idle.agentTranscriptID = rolloutA
        let fresh = AgentSession(profileID: ws, tool: .codex, title: "second", cwd: "~/qa", windowIndex: 2)
        #expect(!AgentSessionEngine.acceptsProbedConversation(rolloutB, for: idle, sessions: [idle, fresh]))
        // Alone, a new conversation in the same tab (/new) is taken.
        #expect(AgentSessionEngine.acceptsProbedConversation(rolloutB, for: idle, sessions: [idle]))
        // Never one another session owns.
        var owner = fresh
        owner.agentTranscriptID = rolloutB
        let unpinned = AgentSession(profileID: ws, tool: .codex, title: "u", cwd: "~/qa", windowIndex: 3)
        #expect(!AgentSessionEngine.acceptsProbedConversation(rolloutB, for: unpinned, sessions: [owner, unpinned]))
        // Other agents: as before.
        let claude = AgentSession(profileID: ws, tool: .claude, title: "c", cwd: "~/qa", windowIndex: 4)
        #expect(AgentSessionEngine.acceptsProbedConversation(rolloutB, for: claude, sessions: [owner, claude]))
    }

    @Test("The status reporter's second line (the conversation) doesn't change the signal")
    func statusSignalWithConversation() {
        #expect(AgentStatus(signal: "working\n\(rolloutA)") == .working)
        #expect(AgentStatus(signal: "done\n") == .done)
        #expect(AgentStatus(signal: "needsInput") == .needsInput)
    }

    // MARK: 8 — Grok's title while an approval waits

    @Test("Grok's pending action beside the cut title never becomes the session's name")
    func grokApprovalTitle() {
        let raw = "Remove the specified drop file… - Single-word ALPHA and…"
        var s = AgentSession(profileID: ws, tool: .grok, title: "Single-word ALPHA and BETA reply test",
                             cwd: "/home/ubuntu/gk-demo")
        #expect(AgentSession.title(fromAgent: raw, of: s) == "Single-word ALPHA and BETA reply test")
        // While the dialog is up, no title update at all.
        s.awaitingAnswer = true
        #expect(AgentSession.title(fromAgent: "Some other thing", of: s) == nil)
        // A real rename still goes through once the dialog is answered.
        s.awaitingAnswer = nil
        #expect(AgentSession.title(fromAgent: "Add a mul function - grok", of: s) == "Add a mul function")
    }

    // MARK: 9 — Grok's blocked request

    @Test("Grok's 451 reads as Bromure's prompt-injection block, like Codex's")
    func grokBlocked() throws {
        let line = #"{"method":"session/update","params":{"update":{"sessionUpdate":"retry_state","type":"failed","error_type":"api_error","message":"API error (status 451 Unavailable For Legal Reasons - Bromure blocked: possible prompt injection): Request failed (HTTP 451)"}}}"#
        let items = GrokTranscriptParser.parse(Data(line.utf8))
        guard case .agentError(let e)? = items.last?.kind else { Issue.record("no error item"); return }
        #expect(e.kind == .blocked)
        #expect(e.blockedBy == .promptInjection)
        // The body's words elsewhere in the record are taken as the message.
        let withBody = #"{"method":"session/update","params":{"update":{"sessionUpdate":"retry_state","type":"failed","message":"API error (status 451 Unavailable For Legal Reasons): Request failed","details":{"body":"Bromure blocked this request: possible prompt injection detected in tool output."}}}}"#
        guard case .agentError(let e2)? = GrokTranscriptParser.parse(Data(withBody.utf8)).last?.kind else {
            Issue.record("no error item"); return
        }
        #expect(e2.blockedBy == .promptInjection)
        #expect(e2.message.hasPrefix("Bromure blocked this request"))
        // The proxy's reply names the block in its status line.
        let resp = String(decoding: HTTPMitmConnection.injectionBlockResponse(detector: "prompt injection", source: "tool output"),
                          as: UTF8.self)
        let status = try #require(resp.split(separator: "\r\n").first)
        #expect(status == "HTTP/1.1 451 Unavailable For Legal Reasons - Bromure blocked: possible prompt injection")
        #expect(BromureBlock.of(String(status)) == .promptInjection)
        #expect(BromureBlock.of(HTTPMitmConnection.injectionReasonPhrase(detector: "rogue instructions")) == .rulesInjection)
    }

    // MARK: 10 — the model in the header

    @Test("A model only named at a long journal's start is still found; a live chat's model stands in")
    func kimiModel() {
        var data = Data(#"{"type":"profile.bind","agentId":"main","modelAlias":"kimi-code/kimi-for-coding"}"#.utf8 + [0x0A])
        let filler = Data((String(repeating: "x", count: 1000)).utf8)
        while data.count < 2_100_000 {
            data.append(Data(#"{"type":"context.append_message","text":""#.utf8))
            data.append(filler)
            data.append(Data("\"}\n".utf8))
        }
        #expect(TranscriptSearchIndex.model(in: data) == "kimi-code/kimi-for-coding")
        let s = AgentSession(profileID: UUID(), tool: .kimi, title: "k", cwd: "~/k")
        let index = TranscriptSearchIndex.shared
        #expect(index.model(for: s, among: []) == nil)
        index.noteLiveModel(s.id, "kimi-code/kimi-for-coding")
        #expect(index.model(for: s, among: []) == "Kimi for Coding")
        #expect(TranscriptSearchIndex.liveModel(in: Data(#"{"type":"llm.request","model":"k2","modelAlias":"kimi-code/kimi-for-coding"}"#.utf8)) == "kimi-code/kimi-for-coding")
    }

    // MARK: 11 — the guest home in card headers

    @Test("Card headers read the guest home as ~; a command line and what the user typed stay")
    func homePaths() {
        #expect(GuestSharePaths.homeDisplay("/home/ubuntu/inj.txt") == "~/inj.txt")
        #expect(GuestSharePaths.homeDisplay("/home/ubuntu") == "~")
        #expect(GuestSharePaths.homeDisplay("/home/ubuntu2/x") == "/home/ubuntu2/x")
        #expect(GuestSharePaths.homeDisplay("/srv/home/ubuntu/x") == "/srv/home/ubuntu/x")
        #expect(GuestSharePaths.homeDisplay(#"{"file_path":"\/home\/ubuntu\/a.txt"}"#) == #"{"file_path":"~\/a.txt"}"#)
        let items = [
            TranscriptItem(id: 0, kind: .userText("read /home/ubuntu/inj.txt"), timestamp: nil),
            TranscriptItem(id: 1, kind: .toolUse(name: "Read", summary: "/home/ubuntu/inj.txt",
                                                 detail: #"{"file_path":"/home/ubuntu/inj.txt"}"#), timestamp: nil),
            TranscriptItem(id: 2, kind: .toolUse(name: "Bash", summary: "ls -la /home/ubuntu/inj.txt",
                                                 detail: #"{"command":"ls -la /home/ubuntu/inj.txt"}"#), timestamp: nil),
        ]
        let out = GuestSharePaths.rewrite(items, names: [:])
        #expect(out[0].kind == items[0].kind)
        #expect(out[1].kind == .toolUse(name: "Read", summary: "~/inj.txt", detail: #"{"file_path":"~/inj.txt"}"#))
        #expect(out[2].kind == items[2].kind)
    }

    // MARK: 13 — one /model picker, not two

    @Test("The printed snapshot hides while a choice card shows the same dialog")
    func commandSnapshotRedundant() {
        let out = BeautifiedSessionModel.CommandOutput(command: "/model", lines: ["› 1. gpt-5"], menu: true,
                                                       live: false, settled: true)
        let picker = TerminalPrompt(kind: .picker, options: [LoginOption(index: 1, label: "gpt-5")])
        #expect(out.isRedundant(with: picker))
        #expect(!out.isRedundant(with: nil))
        #expect(!out.isRedundant(with: TerminalPrompt.privacyCard("x")))
        var live = out
        live.live = true
        #expect(!live.isRedundant(with: picker))
    }
}

// MARK: 4 — the fat-client race (serialized with the other presenter tests)

extension ConsentPromptTests {
    final class RaceStub: ConsentPanelUI { func dismiss() {} }

    @Test("Fat client connected: the local panel shows too, and the first answer wins")
    func fatClientRace() async {
        let p = ConsentPanelPresenter.shared
        // The local user answers first: the remote surface gave nothing.
        p.makeUI = { req, answer in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                answer(0)
            }
            return RaceStub()
        }
        let pid = UUID()
        let local = await ConsentPrompt.race(
            remote: { nil },
            local: { token in
                await ConsentPanelPresenter.shared.present(
                    profileID: pid, title: "inj", message: "", choices: ["Block", "Allow"], denyIndex: 0,
                    style: .warning, detailText: nil, timeout: 30, token: token)
            })
        #expect(local == 0)

        // The fat client answers first: the local panel is withdrawn.
        var shown = 0
        p.makeUI = { _, _ in shown += 1; return RaceStub() }
        let remote = await ConsentPrompt.race(
            remote: {
                try? await Task.sleep(nanoseconds: 80_000_000)
                return 1
            },
            local: { token in
                await ConsentPanelPresenter.shared.present(
                    profileID: pid, title: "inj2", message: "", choices: ["Block", "Allow"], denyIndex: 0,
                    style: .warning, detailText: nil, timeout: 30, token: token)
            })
        #expect(remote == 1)
        #expect(shown == 1)
        #expect(p.openCount == 0)
    }
}
