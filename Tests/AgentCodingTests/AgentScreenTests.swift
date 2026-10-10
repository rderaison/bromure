import Foundation
import Testing
@testable import bromure_ac

// The beautified view's cards must not depend on what an agent's dialogs
// SAY: the wording drifts between versions, and whatever the agent shows in
// a dialog's body (a tool description, a provider's error message) can be
// in any language. These pin the two locale-proof layers — the agents' own
// typed errors in their transcripts, and the shapes of their dialogs — on
// real captures (claude 2.1.285, codex 0.155.1, kimi 2.0.2, grok 1.0.40,
// omp 18.2.8, taken under fr/de/ja/zh locales: the chrome stayed English,
// only model-written lines changed language).
@Suite("Agent screens: typed errors and dialog shapes")
struct AgentScreenTests {

    private func items(_ jsonl: String, agent: String) -> [TranscriptItem] {
        AgentTranscript.parse(Data(jsonl.utf8), agent: agent)
    }

    // MARK: Typed errors from transcripts

    @Test("Claude's API error line is a typed refusal, whatever its text says")
    func claudeTranscriptError() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"bonjour"},"timestamp":"2026-10-02T10:00:00.000Z"}
        {"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Please run /login · API Error: 401 API key is invalid."}]},"error":"authentication_failed","isApiErrorMessage":true,"apiErrorStatus":401,"timestamp":"2026-10-02T10:00:01.000Z"}
        """
        let parsed = items(jsonl, agent: "claude")
        guard case .agentError(let e)? = parsed.last?.kind else { Issue.record("\(parsed)"); return }
        #expect(e.kind == .auth)
        #expect(e.status == 401)
        let f = try #require(SessionFailure.recorded(in: parsed))
        #expect(f.kind == .auth)
        // The same refusal in any wording: only the tags are read.
        let reworded = jsonl.replacingOccurrences(of: "Please run /login · API Error: 401 API key is invalid.",
                                                  with: "Veuillez vous reconnecter.")
        #expect(SessionFailure.recorded(in: items(reworded, agent: "claude"))?.kind == .auth)
        // A rate limit is typed too.
        let limited = jsonl.replacingOccurrences(of: "authentication_failed", with: "rate_limit")
            .replacingOccurrences(of: "\"apiErrorStatus\":401", with: "\"apiErrorStatus\":429")
        #expect(SessionFailure.recorded(in: items(limited, agent: "claude"))?.kind == .quota)
    }

    @Test("A refusal is only the state until something follows it")
    func recordedFailureClearsOnNextTurn() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 401"}]},"error":"authentication_failed","isApiErrorMessage":true,"apiErrorStatus":401}
        {"type":"user","message":{"role":"user","content":"try again"}}
        """
        #expect(SessionFailure.recorded(in: items(jsonl, agent: "claude")) == nil)
    }

    @Test("Codex's task_complete error is typed by codex_error_info")
    func codexTranscriptError() {
        func line(_ info: String, _ message: String) -> String {
            #"{"timestamp":"2026-10-02T10:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":null,"error":{"message":"\#(message)","codex_error_info":"\#(info)"}}}"#
        }
        let user = #"{"timestamp":"2026-10-02T09:59:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"make hello"}]}}"#
        let quota = items(user + "\n" + line("usage_limit_exceeded", "You’ve hit your usage limit."), agent: "codex")
        #expect(SessionFailure.recorded(in: quota)?.kind == .quota)
        let dead = items(user + "\n" + line("unauthorized", "Your access token could not be refreshed."), agent: "codex")
        #expect(SessionFailure.recorded(in: dead)?.kind == .auth)
        // An API-key 401 comes through as "other": the status decides.
        let key = items(user + "\n" + line("other", "unexpected status 401 Unauthorized: Incorrect API key provided"),
                        agent: "codex")
        guard case .agentError(let e)? = key.last?.kind else { Issue.record("\(key)"); return }
        #expect(e.status == 401)
        #expect(e.kind == .auth)
    }

    @Test("Kimi's failed turn.ended is typed by its error code, not the provider's message")
    func kimiTranscriptError() {
        func ended(_ code: String, _ name: String, _ status: Int, _ msg: String) -> String {
            #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","error":{"code":"\#(code)","message":"\#(msg)","name":"\#(name)","details":{"statusCode":\#(status)},"retryable":false},"time":1790956947032}"#
        }
        #expect(SessionFailure.recorded(in: items(ended("provider.auth_error", "APIStatusError", 401, "身份验证无效"),
                                                  agent: "kimi"))?.kind == .auth)
        #expect(SessionFailure.recorded(in: items(ended("provider.api_error", "APIProviderQuotaExhaustedError", 429,
                                                        "账户余额不足"), agent: "kimi"))?.kind == .quota)
        #expect(SessionFailure.recorded(in: items(ended("provider.rate_limit", "APIProviderRateLimitError", 429, "x"),
                                                  agent: "kimi"))?.kind == .quota)
        // A completed turn is not a failure.
        let ok = #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"completed","time":1790956947032}"#
        #expect(SessionFailure.recorded(in: items(ok, agent: "kimi")) == nil)
    }

    @Test("Grok's retry_state that gave up is typed by error_type; retrying is not yet a failure")
    func grokTranscriptError() {
        func update(_ body: String) -> String {
            #"{"method":"_x.ai/session/update","params":{"update":{\#(body)}}}"#
        }
        let auth = update(#""sessionUpdate":"retry_state","type":"failed","error_type":"auth","message":"Unauthorized (401) from https://api.x.ai""#)
        #expect(SessionFailure.recorded(in: items(auth, agent: "grok"))?.kind == .auth)
        let limited = update(#""sessionUpdate":"retry_state","type":"exhausted","is_rate_limited":true"#)
        #expect(SessionFailure.recorded(in: items(limited, agent: "grok"))?.kind == .quota)
        let retrying = update(#""sessionUpdate":"retry_state","type":"retrying","attempt":1,"max_retries":15,"error_type":"rate_limited""#)
        #expect(SessionFailure.recorded(in: items(retrying, agent: "grok")) == nil)
    }

    @Test("omp's errored turn is typed by its classifier bits; Esc is not a failure")
    func ompTranscriptError() {
        func msg(_ id: Int, _ status: Int?) -> String {
            let st = status.map { #","errorStatus":\#($0)"# } ?? ""
            return #"{"type":"message","id":"a","message":{"role":"assistant","content":[],"stopReason":"error","errorId":\#(id)\#(st),"errorMessage":"Error"}}"#
        }
        #expect(SessionFailure.recorded(in: items(msg(16781312, 401), agent: "omp"))?.kind == .auth)      // AuthFailed
        #expect(SessionFailure.recorded(in: items(msg(659456, 429), agent: "omp"))?.kind == .quota)       // UsageLimit
        #expect(SessionFailure.recorded(in: items(msg(135168, 429), agent: "omp"))?.kind == .quota)       // Transient 429
        #expect(SessionFailure.recorded(in: items(msg(0x4000000 | 0x1000, nil), agent: "omp")) == nil)   // UserInterrupt
    }

    @Test("The HTTP status is read from numbers alone")
    func statusParsing() {
        #expect(AgentAPIError.status(in: "API Error: 401 API key is invalid.") == 401)
        #expect(AgentAPIError.status(in: "API error (status 429 Too Many Requests): rate_limit_error") == 429)
        #expect(AgentAPIError.status(in: "Unauthorized (401) from https://api.x.ai/v1") == 401)
        #expect(AgentAPIError.status(in: "listening on localhost:5432, attempt 10/10") == nil)
    }

    // MARK: Dialog shapes

    @Test("Claude's Write permission (real capture) is a card with the file in its detail")
    func claudeWritePermission() throws {
        let screen = """
        ❯ Use the Write tool to create /tmp/claude-work/bar.txt containing hi
        ● Write(bar.txt)
        ────────────────────────────────────────────────────────────
         Create file
         bar.txt
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
          1 hi
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to create bar.txt?
         ❯ 1. Yes
           2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)
           3. No
         Esc to cancel · Tab to amend
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "claude"))
        #expect(p.kind == .picker)
        #expect(p.title == "Do you want to create bar.txt?")
        #expect(p.options.count == 3)
        #expect(p.detail.contains("bar.txt"))
    }

    @Test("A dialog in wording we've never seen — any language — is still a card")
    func unknownWordingDialog() throws {
        // A hypothetical localized permission prompt: nothing in it is in
        // any phrase table.
        let screen = """
         Commande Bash
           touch /tmp/travail/foo.txt
         Voulez-vous continuer ?
         ❯ 1. Oui
           2. Oui, et toujours autoriser /tmp/travail
           3. Non
         Échap pour annuler
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen))
        #expect(p.kind == .picker)
        #expect(p.title == "Voulez-vous continuer ?")
        #expect(p.options.map(\.label) == ["Oui", "Oui, et toujours autoriser /tmp/travail", "Non"])
        #expect(p.keys(picking: 3) == ["Down", "Down", "Enter"])
        let zh = """
         运行此命令？
         $ echo hi > out.txt
         ▶ 1. 批准一次
           2. 本次会话批准
           3. 拒绝
        """
        let q = try #require(TerminalPrompt.detect(inScreen: zh))
        #expect(q.title == "运行此命令？")
        #expect(q.options.count == 3)
    }

    @Test("Kimi's approval panel (▶ cursor) becomes a card")
    func kimiApproval() throws {
        let screen = """
           ▶ Run this command?
           cwd: /tmp/kimi-inv/proj
           $ echo hi > /tmp/kimi-inv/proj/out.txt
           ▶ 1. Approve once
             2. Approve for this session
             3. Reject
             4. Reject with feedback
           ↑/↓ select · 1/2/3/4 choose · ↵ confirm
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "kimi"))
        #expect(p.kind == .picker)
        #expect(p.options.map(\.label) == ["Approve once", "Approve for this session", "Reject", "Reject with feedback"])
        #expect(p.selectedOption == 1)
    }

    @Test("B73: Kimi 2.1's command approval, as captured in a live session, becomes a card")
    func kimiApprovalLiveCapture() throws {
        // Exact text the tab showed (2.1.x), and the whole screen around it:
        // the conversation above, the rule, the status line below.
        let dialog = """
         ▶ Run this command?
           cwd: /home/ubuntu/qa
           $ sleep 1 && echo 1
           ▶ 1. Approve once
             2. Approve for this session
             3. Reject
             4. Reject with feedback
           ↑/↓ select · 1/2/3/4 choose · ↵ confirm
        """
        let full = """
         ● The user wants me to count slowly from 1 to 15, running `sleep 1 && echo N`
           for each number, one command per number. That's 15 separate bash commands,
           … (49 more lines, ctrl+o to expand)

         ● I'll run them one at a time so the counting stays slow — one number per
           second.

         ● Running a command · $ sleep 1 && echo 1
           Press Ctrl+B to run in background
         ──────────────────────────────────────────────────────────────────────────────
           ▶ Run this command?

           cwd: /home/ubuntu/qa
           $ sleep 1 && echo 1

           ▶ 1. Approve once
             2. Approve for this session
             3. Reject
             4. Reject with feedback

           ↑/↓ select · 1/2/3/4 choose · ↵ confirm
         ──────────────────────────────────────────────────────────────────────────────
         K2.8 Preview thinking: max  ~/qa  master [±]                     ctrl+o expand
                                                                 context: 3% (30.5k/1M)
        """
        for screen in [dialog, full] {
            let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "kimi"))
            #expect(p.kind == .picker)
            #expect(p.title == "Run this command?")
            #expect(p.options.map(\.label) == ["Approve once", "Approve for this session", "Reject", "Reject with feedback"])
            #expect(p.selectedOption == 1)
            #expect(p.detail.contains("sleep 1 && echo 1"))
            // Picking relays from the highlighted row.
            #expect(p.keys(picking: 1) == ["Enter"])
            #expect(p.keys(picking: 3) == ["Down", "Down", "Enter"])
            // And it is what the scan surfaces (not a failure banner).
            #expect(TerminalScan.classify(screen, agent: "kimi") == .prompt(p))
        }
    }

    @Test("Grok's radio approval: the preselected option is the cursor, never assumed to be 1's 'Yes'")
    func grokApproval() throws {
        let screen = """
        ┃  create marker
        ┃  curl -s -o /dev/null http://127.0.0.1:18555/v1/models
        ┃  ← → narrow scope
        ┃  1 (●) Yes, and don't ask again for anything (always-approve mode)
        ┃  2 (○) Yes, proceed
        ┃  3 (○) No, reject (type to add feedback)
        ┃  4 (○) Never allow: curl -s -o
          1/4:select  │  Tab:next option  │  ←/→:scope  │  Ctrl+o:always-approve  │  Ctrl+c:cancel
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "grok"))
        #expect(p.kind == .picker)
        #expect(p.options.count == 4)
        #expect(p.options[1].label == "Yes, proceed")
        #expect(p.selectedOption == 1)
        #expect(p.keys(picking: 2) == ["Down", "Enter"])
    }

    @Test("Grok 1.0.46's folder-trust gate is a trust card that waits on the user (never Ready)")
    @MainActor func grokTrustGate() throws {
        let screen = """
          Grok Build

          Do you trust the contents of this directory?
          /mnt/bromure-share-1
          Grok Build may run or modify contents in this directory,
          posing security risks.

          y  Yes, proceed
          n  No, quit

          Enter or y to trust
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "grok"))
        #expect(p.kind == .trust)
        #expect(p.detail == "/mnt/bromure-share-1")
        #expect(p.canAnswerTrust)
        #expect(p.trustKeys == ["Enter"])
        #expect(BeautifiedSessionModel.isDialog(p))
        // Typing into the tab would answer it: the composer holds messages.
        #expect(BeautifiedSessionModel.looksLikeMenu(screen))
        // Without knowing the agent (a scan that can't tell), still a dialog.
        #expect(TerminalPrompt.detect(inScreen: screen)?.kind == .trust)
    }

    @Test("omp's boxed approval (unnumbered, title in the box edge) becomes a card")
    func ompApproval() throws {
        let screen = """
          ⎋ Working…
        ╭─ Allow tool: bash ──────────────────────────────────────────
        │
        │ Command: echo hello-from-mock
        │
        │  ❯ Approve
        │    Deny
        │
        │ up/down navigate  enter select  esc cancel
        │
        ╰─────────────────────────────────────────────────────────────
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "omp"))
        #expect(p.kind == .picker)
        #expect(p.title == "Allow tool: bash")
        #expect(p.options.map(\.label) == ["Approve", "Deny"])
        #expect(p.selectedOption == 1)
        #expect(p.keys(picking: 2) == ["Down", "Enter"])
        #expect(p.detail.contains("Command: echo hello-from-mock"))
    }

    @Test("Kimi's trust dialog: options read from the screen, descriptions left out")
    func kimiTrustOptions() throws {
        let screen = """
          Trust this folder?
          ↑↓ navigate · Enter select · Esc exit
          /home/ubuntu/trustprobe
          Project-level MCP servers are disabled until you explicitly choose Trust.
           ❯ Trust this folder
             Enable project MCP servers. Remembered for this folder.
             Don't trust
             Exit Kimi Code. Asked again next launch.
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "kimi"))
        #expect(p.kind == .picker)
        #expect(p.detail == "/home/ubuntu/trustprobe")
        #expect(p.options.map(\.label) == ["Trust this folder", "Don't trust"])
        #expect(p.keys(picking: 1) == ["Enter"])
        #expect(p.keys(picking: 2) == ["Down", "Enter"])
    }

    @Test("The agent's input box is not a dialog, even with text typed in it")
    func inputBoxIsNotADialog() {
        let claude = """
        ● Done — the tests pass.
        ────────────────────────────────────────────────────────────
        ❯ now commit it
          and push
        ────────────────────────────────────────────────────────────
          ? for shortcuts
        """
        #expect(TerminalPrompt.detect(inScreen: claude, agent: "claude") == nil)
        let codex = """
        • Updated the parser.

        › Ask Codex to do anything

          ? for shortcuts                                100% context left
        """
        let c = TerminalPrompt.detect(inScreen: codex, agent: "codex")
        #expect(c == nil, "\(String(describing: c))")
    }

    @Test("The user's own wrapped message echoed above the input box is not a dialog (real capture)")
    func echoedQuestionIsNotADialog() {
        // Claude 2.1.276, first seconds of a turn: the question wraps onto an
        // aligned second line, and the input box below is a bare "❯" once
        // trailing blanks are trimmed. Read as a two-option menu, it raised a
        // card titled with the question on every turn.
        let screen = """
        ✻ Crunched for 9s · done 12:04 PM

        ❯ What is the difference between a process and a thread? Answer in about 200
          words.

        ✶ Wibbling… (3s · ↓ 1 tokens)
        ────────────────────────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents
        """
        #expect(TerminalPrompt.detect(inScreen: screen, agent: "claude") == nil)
        // The same, wrapped on a question mark — no sentence to tell the
        // continuation from an option.
        let question = screen.replacingOccurrences(
            of: "❯ What is the difference between a process and a thread? Answer in about 200\n  words.",
            with: "❯ Can you explain the difference between a process and a thread in this\n  codebase?")
        #expect(question.contains("  codebase?"))
        #expect(TerminalPrompt.detect(inScreen: question, agent: "claude") == nil)
        // A numbered message the user sent, echoed the same way.
        let numbered = """
        ❯ 1. rename the module
          2. update the tests

        ✶ Thinking…
        ────────────────────────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────────────────────────
          ? for shortcuts
        """
        #expect(TerminalPrompt.detect(inScreen: numbered, agent: "claude") == nil)
    }

    // MARK: Sign-in shapes

    @Test("A device-code sign-in (Grok) is a login card with its code, from shapes and Grok's words")
    func grokDeviceLogin() throws {
        let screen = """
        Approve in your browser to finish signing in.
        QZQD-KPB5
        Make sure your browser shows this code.
        If it doesn't open, click here to copy.
        Waiting for approval...
        ctrl+q  quit
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "grok"))
        #expect(p.kind == .login)
        #expect(p.deviceCode == "QZQD-KPB5")
        #expect(!p.awaitingCode)
    }

    @Test("A sign-in URL alone makes a login card, whatever the screen says around it")
    func signInURLShape() throws {
        let screen = """
          Melden Sie sich an, um fortzufahren
          https://auth.openai.com/codex/device
          Code: ABCD-12345
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen))
        #expect(p.kind == .login)
        #expect(p.authURL == "https://auth.openai.com/codex/device")
        #expect(p.deviceCode == "ABCD-12345")
        // Claude's code=true flow wants the code pasted back; a loopback
        // redirect doesn't.
        #expect(AgentScreen.wantsPastedCode("https://claude.com/cai/oauth/authorize?code=true&client_id=x"))
        #expect(!AgentScreen.wantsPastedCode(
            "https://claude.ai/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"))
    }

    @Test("Sign-in wording in what the agent printed — a diff, code, a chat answer — is no login card")
    func loginWordsInContent() {
        // The openshell false positive: a diff whose comment quotes Claude's banner.
        let diff = """
        ● Update(bromure-agentd.py)
          ⎿  Added 2 lines
             412 +        # tmux launcher's env. Without it the SDK's claude sits at
             413 +        # "Not logged in". Then exec the driver; argv passes via "$@".
        ❯
          ? for shortcuts
        """
        #expect(TerminalPrompt.detect(inScreen: diff, agent: "claude")?.kind != .login)
        // Code that names the dialog's wording, and a URL in a string.
        let code = """
            .login: ["select login method", "browser didn't open", "paste code here",
            let url = "https://claude.ai/oauth/authorize?client_id=x"
        """
        #expect(TerminalPrompt.detect(inScreen: code, agent: "claude")?.kind != .login)
        // A test string the TUI wrapped: its tail starts a line, unquoted.
        let wrapped = """
        ● Write(Tests/SessionFailureTests.swift)
             46 #expect(SessionFailure.detect(inScreen: "Not logged in — please
                run /login")?.kind == .auth)
        """
        #expect(TerminalPrompt.detect(inScreen: wrapped, agent: "claude")?.kind != .login)
        // Prose about someone else's login.
        let prose = "● You're not logged in to the registry yet; run /login there first."
        #expect(TerminalPrompt.detect(inScreen: prose, agent: "claude")?.kind != .login)
    }

    @Test("The agents' own logged-out lines still raise the login card")
    func loginStatusLines() {
        for (agent, line) in [("claude", "  ⎿  Not logged in · Please run /login"),
                              ("claude", "  ⎿  Invalid API key · Please run /login"),
                              ("claude", "API Error: 401 · Please run /login"),
                              ("grok", "Not signed in. Run grok login."),
                              ("kimi", "LLM not set, send \"/login\" to login"),
                              ("omp", "No API key found for anthropic. Set ANTHROPIC_API_KEY.")] {
            #expect(TerminalPrompt.detect(inScreen: line, agent: agent)?.kind == .login, "\(agent): \(line)")
        }
    }

    // MARK: Wording fallback

    @Test("Wording drift the old needles missed: curly apostrophes, per-agent phrasing")
    func refreshedWording() {
        #expect(SessionFailure.detect(inScreen: "■ You’ve hit your usage limit. Upgrade to Pro", agent: "codex")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "■ Your access token could not be refreshed. Please log out and sign in again.",
                                      agent: "codex")?.kind == .auth)
        #expect(SessionFailure.detect(inScreen: "Authentication required: your session has expired or your credentials were rejected. Run /login to re-authenticate, then resend your message.",
                                      agent: "grok")?.kind == .auth)
        #expect(SessionFailure.detect(inScreen: "Error: [provider.auth_error] 401 Invalid Authentication", agent: "kimi")?.kind == .auth)
        #expect(SessionFailure.detect(inScreen: "Error: [provider.api_error] 429 Your account is suspended due to insufficient balance",
                                      agent: "kimi")?.kind == .quota)
        // Claude's trust dialog, current wording, is still one-click.
        let trust = """
         Accessing workspace:
         /tmp/claude-work-frlang
         Quick safety check: Is this a project you created or one you trust? (Like your own code, a
         Security guide
         ❯ No, exit
           Yes, I trust this folder
         Enter to confirm · Esc to cancel
        """
        let p = TerminalPrompt.detect(inScreen: trust, agent: "claude")
        #expect(p?.kind == .trust)
        #expect(p?.canAnswerTrust == true)
        #expect(p?.detail == "/tmp/claude-work-frlang")
    }

    @Test("The guest's menu probe matches every agent's footer and highlighted rows")
    func menuOpenRegex() throws {
        let regex = try Regex(AgentPhrases.menuOpenRegex.replacingOccurrences(of: "'\\''", with: "'"))
        for line in ["esc to cancel · tab to amend", "press enter to confirm or esc to cancel",
                     "↑/↓ select · 1/2/3/4 choose · ↵ confirm", "up/down navigate  enter select  esc cancel",
                     "1/4:select  │  tab:next option  │  ctrl+c:cancel", " ❯ 1. yes", "┃  1 (●) yes"] {
            #expect(line.contains(regex), "\(line)")
        }
        for line in ["  ? for shortcuts", "› 1. fix the parser", "⏵⏵ auto mode on (shift+tab to cycle)"] {
            #expect(!line.contains(regex), "\(line)")
        }
    }
}
