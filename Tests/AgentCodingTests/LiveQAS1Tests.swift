import Foundation
import Testing
@testable import bromure_ac

/// Live-QA round S1: transcript parsing and reply rendering.
@Suite("Live QA S1 — transcript")
struct LiveQAS1TranscriptTests {

    private func userLine(_ content: Any) -> Data {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test("S1-2: a pasted_content wrapper is stripped from the user's turn, the text kept")
    func pastedWrapperStripped() {
        let body = String(repeating: "x", count: 20_045)
        let wrapped = "<pasted_content id=\"a1b2c3d4e5f6a7b8\">" + body + "</pasted_content>"
        for content: Any in [wrapped, [["type": "text", "text": wrapped]]] {
            let items = ClaudeTranscriptParser.parse(userLine(content))
            guard case .userText(let t)? = items.first?.kind else { Issue.record("no user turn"); continue }
            #expect(t == body)
            #expect(t.count == 20_045)
        }
    }

    @Test("S1-2: text around a paste is kept; a malformed wrapper is left as written")
    func pastedWrapperInContext() {
        #expect(ClaudeTranscriptParser.unwrapPasted(
            "look at this:\n<pasted_content id=\"p1\">line 1\nline 2</pasted_content>\nthanks")
            == "look at this:\nline 1\nline 2\nthanks")
        #expect(ClaudeTranscriptParser.unwrapPasted("<pasted_content id=\"p1\">no end")
            == "<pasted_content id=\"p1\">no end")
        #expect(ClaudeTranscriptParser.unwrapPasted("plain") == "plain")
    }

    @Test("S1-2: the composer's echo matches the recorded (wrapped, CRLF) turn")
    @MainActor
    func echoReconciles() {
        let sent = "a\r\nb\r\nc "
        #expect(BeautifiedSessionModel.echoMatches(sent, recorded: "<pasted_content id=\"z\">a\nb\nc</pasted_content>"))
        #expect(!BeautifiedSessionModel.echoMatches("a", recorded: "b"))
    }

    @Test("S1-8: single newlines in prose become hard breaks")
    func hardBreaksInProse() {
        #expect(MarkdownHardBreaks.apply("one\ntwo\nthree") == "one\\\ntwo\\\nthree")
        // A paragraph break stays one.
        #expect(MarkdownHardBreaks.apply("one\n\ntwo") == "one\n\ntwo")
        // Already a hard break: untouched.
        #expect(MarkdownHardBreaks.apply("one  \ntwo") == "one  \ntwo")
    }

    @Test("S1-8: code, lists, tables and headings keep their Markdown meaning")
    func hardBreaksLeaveStructure() {
        let code = "```swift\nlet a = 1\nlet b = 2\n```"
        #expect(MarkdownHardBreaks.apply(code) == code)
        let indented = "text\n\n    code 1\n    code 2"
        #expect(MarkdownHardBreaks.apply(indented) == indented)
        let list = "- one\n  continued\n- two\n1. a\n2. b"
        #expect(MarkdownHardBreaks.apply(list) == list)
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        #expect(MarkdownHardBreaks.apply(table) == table)
        let bare = "a | b\n--|--\n1 | 2"
        #expect(MarkdownHardBreaks.apply(bare) == bare)
        let setext = "Title\n====="
        #expect(MarkdownHardBreaks.apply(setext) == setext)
        // Prose right before a list or a fence doesn't get a stray backslash.
        #expect(MarkdownHardBreaks.apply("intro\n- item") == "intro\n- item")
        #expect(MarkdownHardBreaks.apply("intro\n```\nx\n```") == "intro\n```\nx\n```")
        // A heading followed by prose: the heading line is left alone.
        #expect(MarkdownHardBreaks.apply("# H\nline\nline2") == "# H\nline\\\nline2")
    }
}

@Suite("Live QA S1 — Kimi titles")
struct LiveQAS1KimiTitleTests {
    /// Kimi's terminal title: its session title (the first message as
    /// written) trimmed and cut at 32 UTF-16 units (JS `slice(0, 32)`),
    /// shown by the terminal with newlines as spaces.
    private func kimiTitle(_ prompt: String) -> String {
        let units = Array(prompt.trimmingCharacters(in: .whitespacesAndNewlines).utf16.prefix(32))
        let s = String(decoding: units, as: UTF16.self)   // a split pair → U+FFFD
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    private func session() -> AgentSession {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "Kimi Code in qa")
        s.cwd = "/home/ubuntu/qa"
        return s
    }

    @Test("S1-7: a multi-line first message matches Kimi's space-joined title")
    func multiLine() {
        let prompt = "Refactor the parser\nthen run the tests\nand report back"
        let t = kimiTitle(prompt)
        #expect(t == "Refactor the parser then run the")
        #expect(AgentSession.isCutPrompt(t, of: prompt))
        // Newlines dropped instead of shown as spaces: still the prompt.
        #expect(AgentSession.isCutPrompt("Refactor the parserthen run", of: prompt))
        var s = session()
        s.openingMessage = prompt
        #expect(AgentSession.title(fromAgent: t, of: s) == "Refactor the parser")
    }

    @Test("S1-7: a CJK title cut at 32 units ends with an ellipsis")
    func cjk() {
        let prompt = String(repeating: "请帮我重构这个解析器然后运行测试", count: 3)
        let t = kimiTitle(prompt)
        #expect(t.count == 32)
        #expect(AgentSession.isKimiTitleCut(t))
        let named = AgentSession.title(fromAgent: t, of: session())
        #expect(named?.hasSuffix("…") == true)
    }

    @Test("S1-7: an emoji title (fewer graphemes than units, a split emoji) is still a cut")
    func emoji() {
        // 15 ASCII + emoji pairs: the 32nd unit splits an emoji.
        let prompt = "Fix the build 🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀 please"
        let t = kimiTitle(prompt)
        #expect(t.count < 32)
        #expect(AgentSession.isKimiTitleCut(t))
        let named = AgentSession.title(fromAgent: t, of: session())
        #expect(named?.hasSuffix("…") == true)
        #expect(named?.contains("\u{FFFD}") == false)
        var s = session()
        s.openingMessage = prompt
        #expect(AgentSession.isCutPrompt(t, of: prompt))
        // A title Kimi didn't cut is left as it is.
        #expect(!AgentSession.isKimiTitleCut("Short title"))
    }
}

@Suite("Live QA S1 — a workspace's own local engine wins")
@MainActor
struct LiveQAS1LocalEngineTests {
    /// The global Models settings: a custom server on :8001, omp on deepseek.
    private func global() -> ModelSettings {
        var g = ModelSettings()
        g.localServer = LocalServer(baseURL: "http://10.163.12.57:8001/")
        g.agentTiers[.omp] = [.medium: ModelRef(source: .localServer, modelID: "deepseek-v4-flash")]
        g.tiers[.medium] = ModelRef(source: .localServer, modelID: "deepseek-v4-flash")
        return g
    }

    /// QA-omp: its record names its own engine and model.
    private func qaOmp() -> Profile {
        var p = Profile(name: "QA-omp", tool: .omp, authMode: .local)
        p.modelRouting = .local
        p.localEngineURL = "http://10.163.12.57:8888"
        p.activeModelID = "GLM-5.3-Flash-EXL3"
        return p
    }

    @Test("S1-3: the workspace's engine and model win over the global default")
    func workspaceEngineWins() {
        let p = qaOmp()
        let eff = ModelSettingsStore.effective(for: p, global: global())
        #expect(eff.ref(for: .omp, tier: .medium)?.modelID == "GLM-5.3-Flash-EXL3")
        #expect(eff.localServer?.baseURL == "http://10.163.12.57:8888")
        let launched = p.overlaidWithGlobalModels(eff)
        #expect(launched.localEngineURL == "http://10.163.12.57:8888")
        #expect(launched.activeModelID == "GLM-5.3-Flash-EXL3")
        #expect(launched.authMode == .local)
        // What the repair proxy is pointed at.
        #expect(launched.localEngineBaseURL?.port == 8888)
    }

    @Test("S1-3: an explicit workspace override is the choice; the old fields don't count")
    func explicitOverrideWins() {
        var p = qaOmp()
        p.modelOverride = ModelOverride(inheritsGlobal: true)
        let eff = ModelSettingsStore.effective(for: p, global: global())
        #expect(eff.ref(for: .omp, tier: .medium)?.modelID == "deepseek-v4-flash")
    }

    @Test("S1-3: old fields that just repeat the global settings follow the global settings")
    func sameAsGlobal() {
        var p = qaOmp()
        p.localEngineURL = "http://10.163.12.57:8001/v1"
        p.activeModelID = "deepseek-v4-flash"
        #expect(p.legacyLocalEngine(global: global()) == .sameAsGlobal)
        #expect(p.legacyLocalEngineOverride(global: global()) == nil)
        // Migrated: the stale copy is cleared, so a later global change applies.
        let moved = p.migratedLegacyLocalEngine(global: global())
        #expect(moved?.localEngineURL == nil)
        #expect(moved?.modelOverride == nil)
    }

    @Test("S1-3: the migration writes the workspace's engine as its override and clears the old fields")
    func migrationPersists() {
        let moved = qaOmp().migratedLegacyLocalEngine(global: global())
        #expect(moved?.localEngineURL == nil)
        let eff = ModelSettingsStore.effective(for: moved!, global: global())
        #expect(eff.ref(for: .omp, tier: .medium)?.modelID == "GLM-5.3-Flash-EXL3")
        #expect(eff.localServer?.baseURL == "http://10.163.12.57:8888")
        // Idempotent.
        #expect(moved!.migratedLegacyLocalEngine(global: global()) == nil)
    }

    @Test("S1-3: a cloud workspace with a leftover engine URL is left to the global settings")
    func cloudLeftover() {
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        p.modelRouting = .local
        p.localEngineURL = "http://x:1"
        p.activeModelID = "m"
        #expect(p.legacyLocalEngine(global: global()) == nil)
    }
}
