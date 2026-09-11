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
    }

    @Test("Credit/usage banners are read as a quota failure")
    func quotaBanner() {
        #expect(SessionFailure.detect(inScreen: "Credit balance is too low.")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "You've reached your usage limit for this session.")?.kind == .quota)
        #expect(SessionFailure.detect(inScreen: "429 Too Many Requests")?.kind == .quota)
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
