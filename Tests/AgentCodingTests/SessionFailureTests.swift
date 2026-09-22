import Foundation
import Testing
@testable import bromure_ac

// The beautified view can't see the agent's terminal by default, so a failure
// (bad key / expired sub) or a blocking prompt (folder-trust, /login) leaves it
// hung or desynced. These pin the terminal sniff against REAL captured output —
// the Claude `401 API key is invalid` banner and the actual trust dialog — plus
// the other supported agents' auth wording.
@Suite("Beautified terminal-state detection")
struct SessionFailureTests {

    // Verbatim from `sub` (claude, no key): the exact banner the first cut MISSED
    // because it read "invalid api key" and Claude says "API key is invalid".
    private let claude401 = """


        ✻ 401 API key is invalid. · Retrying in 8s · attempt 10/10

        ──────────────────────────────────────────────────────────────
        ❯
        ──────────────────────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt
        """

    @Test("Claude 401 retry banner (real capture) is an auth failure")
    func claudeAuth() {
        let f = SessionFailure.detect(inScreen: claude401)
        #expect(f?.kind == .auth)
        #expect(f?.detail.contains("API key is invalid") == true)
    }

    @Test("Every supported agent's auth wording is covered")
    func crossAgentAuth() {
        // Codex / OpenAI
        #expect(SessionFailure.detect(inScreen: "Incorrect API key provided: sk-***.")?.kind == .auth)
        #expect(SessionFailure.detect(inScreen: "stream error: unexpected status 401 Unauthorized")?.kind == .auth)
        // xAI / Grok
        #expect(SessionFailure.detect(inScreen: "Error: invalid api key for x.ai")?.kind == .auth)
        // Kimi / Moonshot
        #expect(SessionFailure.detect(inScreen: "Invalid Authentication (401)")?.kind == .auth)
        // omp (Anthropic provider) — same shape as Claude
        #expect(SessionFailure.detect(inScreen: "authentication_error: x-api-key header is invalid")?.kind == .auth)
        // subscription / login
        #expect(SessionFailure.detect(inScreen: "Your subscription has expired.")?.kind == .auth)
        #expect(SessionFailure.detect(inScreen: "Not logged in — please run /login")?.kind == .auth)
        // Kimi Code's startup warning when its credential slot is empty — the
        // beautified view stalled on "Thinking…" until this was recognized.
        #expect(SessionFailure.detect(inScreen:
            "Skipped refreshing managed:kimi-code: OAuth provider \"managed:kimi-code\" requires login before it can be used.")?.kind == .auth)
    }

    @Test("Kimi's one-shot 'folder is not trusted' warning is not a trust prompt — the error after it is the state")
    func kimiWarningIsNotATrustDialog() {
        // Real capture from a worktree run: the warning mentions "Trust this
        // folder" and the screen's only /path is the LOG file. The old code
        // showed a trust card pointing at kimi-code.log and told the user to
        // go answer it in Linux — there was nothing to answer.
        let screen = """
        [bromure-ac] starting kimi in worktree…
        kimi version 2.0.2
        Warning: this folder is not trusted; skipped 1 project-level MCP server: bromure-delegation (stdio: python3 /mnt/bromure-meta/bromure-delegation-mcp.py).
          Run `kimi` here and choose "Trust this folder" to enable them.

        error: failed to run prompt: No model configured. Run `kimi` and use /login to sign in, then retry; or set default_model in config.toml.
        See log: /home/ubuntu/.kimi-code/logs/kimi-code.log
        [bromure-ac] kimi exited with status 133
        ubuntu@defaultworkspace:~/hello-260922-0813$
        """
        #expect(TerminalPrompt.detect(inScreen: screen, agent: "kimi") == nil)
        let state = TerminalScan.classify(screen, agent: "kimi")
        guard case .failure(let f)? = state else { Issue.record("expected a failure, got \(String(describing: state))"); return }
        #expect(f.kind == .generic)
        // Bottom-up scan: the launcher's exit line is the latest state and wins
        // over the "No model configured" error above it — either is the right
        // headline; what matters is that neither reads as a trust dialog.
        let d = f.detail.lowercased()
        #expect(d.contains("exited with status") || d.contains("no model configured"))
    }

    @Test("Kimi's real trust dialog IS a trust prompt, answerable inline with Enter")
    func kimiTrustDialogIsAnswerable() throws {
        // Real capture (kimi 2.0.2) of the interactive dialog.
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
        #expect(p.kind == .trust)
        #expect(p.detail == "/home/ubuntu/trustprobe")
        #expect(p.canAnswerTrust)
        #expect(p.trustKeys == ["Enter"])
    }

    @Test("Credit/usage banners are read as a quota failure")
    func quotaBanner() {
        #expect(SessionFailure.detect(inScreen: "Credit balance is too low.")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "You've reached your usage limit for this session.")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "429 Too Many Requests")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "Error: rate_limit_error — try again later")?.kind == .quota)
        // An answer that merely talks about a rate limit is not a banner.
        #expect(SessionFailure.detect(inScreen:
            "4. Sets logging to high, which removes the 3-per-minute rate limit. That also fixes the block undercount.") == nil)
    }

    @Test("Healthy output that merely mentions 'error' is NOT a failure")
    func noFalsePositive() {
        let screen = """
        ⏺ I've updated the config and the tests pass.
          The new error-handling path covers the timeout case now.
        >
        """
        #expect(SessionFailure.detect(inScreen: screen) == nil)
        #expect(TerminalScan.classify(screen) == nil)
    }

    @Test("An old banner scrolled out of the terminal tail is not the current state")
    func onlyTailCounts() {
        let filler = (1...50).map { "line \($0): all good, working…" }.joined(separator: "\n")
        let screen = "401 API key is invalid\n" + filler
        #expect(SessionFailure.detect(inScreen: screen) == nil)
    }

    // Verbatim from a fresh `claude` launch: the folder-trust dialog.
    private let trustDialog = """
         Accessing workspace:
         /tmp/trustprobe
         Quick safety check: Is this a project you created or one you trust? (Like your own code, a
         well-known open source project, or work from your team). If not, review what's in this folder.
         Claude Code'll be able to read, edit, and execute files here.
         Security guide
         ❯ No, exit
           Yes, I trust this folder
         Enter to confirm · Esc to cancel
        """

    @Test("Claude trust dialog (real capture) is a trust prompt answerable inline")
    func trustPrompt() {
        let p = TerminalPrompt.detect(inScreen: trustDialog)
        #expect(p?.kind == .trust)
        #expect(p?.canAnswerTrust == true)                 // "Yes, I trust this folder" present
        #expect(p?.detail == "/tmp/trustprobe")            // folder pulled from the dialog
        // And the classifier prioritizes the prompt over anything else.
        #expect(TerminalScan.classify(trustDialog) == .prompt(p!))
    }

    // Verbatim from a fresh install's first turn (2.1.258): the fullscreen
    // renderer upsell — a modal the chat used to hide entirely.
    private let fullscreenUpsell = """
        ∗ Churned for 2s · done 10:42 AM
        ────────────────────────────────────────────────────────────
         Try the new fullscreen renderer?

         · Flicker-free output — fixes the flashing you see during long responses
         · Mouse support — click to move your cursor or expand results
         · Selected text auto-copies to your clipboard

         ❯ 1. Yes, try it
           2. Not now

         Enter to confirm · Esc to cancel
        """

    @Test("An unknown modal picker (real capture) becomes a generic picker prompt")
    func genericPicker() {
        let p = TerminalPrompt.detect(inScreen: fullscreenUpsell)
        #expect(p?.kind == .picker)
        #expect(p?.title == "Try the new fullscreen renderer?")
        #expect(p?.options.map(\.label) == ["Yes, try it", "Not now"])
        #expect(p?.selectedOption == 1)
        #expect(p?.keys(picking: 2) == ["Down", "Enter"])   // from the highlighted row
        #expect(p?.keys(picking: 1) == ["Enter"])
        #expect(TerminalScan.classify(fullscreenUpsell) == .prompt(p!))
    }

    @Test("AskUserQuestion and permission pickers are not generic picker prompts")
    func genericPickerExclusions() {
        // AskUserQuestion's own card answers these ("Enter to select" footer).
        let question = """
         Which database should the service use?
         ❯ 1. Postgres
           2. SQLite
         Enter to select · Esc to cancel
        """
        #expect(TerminalPrompt.detect(inScreen: question) == nil)
        // A tool-permission prompt is never decided from a card.
        let permission = """
         Bash command: rm -rf build
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for rm commands
           3. No
         Enter to confirm · Esc to cancel
        """
        #expect(TerminalPrompt.detect(inScreen: permission) == nil)
    }

    // Verbatim `/login` method menu from a real `claude` run.
    private let loginMenu = """
           Login
           Claude Code can be used with your Claude subscription or billed based on API usage through your Console account.
           Select login method:
           ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise
             2. Anthropic Console account · API usage billing
             3. 3rd-party platform · Amazon Bedrock, Microsoft Foundry, or Vertex AI
           Esc to cancel
        """

    @Test("/login method menu is parsed into selectable options")
    func loginMethods() {
        let p = TerminalPrompt.detect(inScreen: loginMenu)
        #expect(p?.kind == .login)
        #expect(p?.loginMethods.map(\.index) == [1, 2, 3])
        #expect(p?.loginMethods.first?.label == "Claude account with subscription")   // tagline dropped
        #expect(p?.loginMethods[1].label == "Anthropic Console account")
        #expect(p?.authURL == nil)
        #expect(TerminalScan.classify(loginMenu) == .prompt(p!))
    }

    // Verbatim authorize stage — the OAuth URL (tmux -J joins the wrap) + the
    // "Paste code here" prompt.
    private let loginAuthorize = """
           Login
           Browser didn't open? Use the url below to sign in (c to copy)
        https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key&code_challenge=DepSMeJQ&code_challenge_method=S256&state=bA6KkQ
           Hold Shift while selecting to use your terminal's native copy
           Paste code here if prompted >
           Esc to cancel
        """

    @Test("/login authorize stage exposes the OAuth URL and the code field")
    func loginAuthorizeStage() {
        let p = TerminalPrompt.detect(inScreen: loginAuthorize)
        #expect(p?.kind == .login)
        #expect(p?.loginMethods.isEmpty == true)
        #expect(p?.awaitingCode == true)
        // Picks the leading https:// (not the encoded redirect_uri) and keeps the
        // whole joined URL through to the trailing &state=… .
        #expect(p?.authURL?.hasPrefix("https://claude.com/cai/oauth/authorize?code=true") == true)
        #expect(p?.authURL?.hasSuffix("state=bA6KkQ") == true)
    }
}
