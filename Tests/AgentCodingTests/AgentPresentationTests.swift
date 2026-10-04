import Foundation
import Testing
@testable import bromure_ac

/// Header meta, titles and code fences for every agent (Kimi, Codex, Grok,
/// omp as much as Claude).
@Suite("Agent presentation")
@MainActor
struct AgentPresentationTests {

    /// A Kimi wire journal, trimmed from a real `kimi` 2.1 session.
    private func kimiWire(ended: Bool, at ms: Double = 1_791_064_104_438) -> Data {
        var lines = [
            #"{"type":"metadata","protocol_version":"1.5","created_at":1791064091551}"#,
            #"{"type":"profile.bind","agentId":"main","modelAlias":"kimi-code/kimi-for-coding","profileName":"agent"}"#,
            #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"hi"}],"turnId":0,"time":1791064091633}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/kimi-for-coding","usage":{"inputOther":17050,"output":94,"inputCacheRead":13568,"inputCacheCreation":0},"usageScope":"turn","time":1791064097949}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/kimi-for-coding","usage":{"inputOther":124,"output":49,"inputCacheRead":30720,"inputCacheCreation":0},"usageScope":"turn","time":1791064104436}"#,
            #"{"message":{"message":{"role":"assistant","content":[]},"meta":{"model":{"provider":"agent-loop","model":"agent-loop"},"source":"llm"}},"type":"agent.message.appended","time":\#(Int(ms)),"kind":"event"}"#,
        ]
        if ended {
            lines.append(#"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"completed","time":1791064104453}"#)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    @Test("Kimi's model: its alias, never the internal \"agent-loop\"")
    func kimiModel() {
        let m = TranscriptSearchIndex.model(in: kimiWire(ended: true))
        #expect(m == "kimi-code/kimi-for-coding")
        #expect(TranscriptSearchIndex.prettyModel(m!) == "Kimi for Coding")
        #expect(TranscriptSearchIndex.prettyModel("claude-opus-4-5-20251101") == "Opus 4.5")
        #expect(TranscriptSearchIndex.model(in: Data(#"{"model":"agent-loop"}"#.utf8)) == nil)
    }

    @Test("Kimi's tokens: the last call's context")
    func kimiTokens() {
        let t = TranscriptSearchIndex.tokens(in: kimiWire(ended: true))
        #expect(t.input == 124 && t.cached == 30720 && t.output == 49)
        #expect(t.total == 30893)   // = Kimi's own token_counting for that turn
    }

    @Test("Kimi's journal says when a turn is under way")
    func kimiTurn() {
        let at = Date(timeIntervalSince1970: 1_791_064_104_438 / 1000 + 5)
        #expect(KimiTranscriptParser.turnInProgress(kimiWire(ended: false), now: at))
        #expect(!KimiTranscriptParser.turnInProgress(kimiWire(ended: true), now: at))
        // A crashed agent's turn stays open: stale after a while.
        #expect(!KimiTranscriptParser.turnInProgress(kimiWire(ended: false), now: at.addingTimeInterval(600)))
        #expect(!KimiTranscriptParser.turnInProgress(Data()))
    }

    @Test("Kimi's opening message is typed into the TUI, not passed one-shot")
    func kimiOpening() {
        #expect(AgentSessionEngine.typesOpeningMessage(.kimi))
        for t in [Profile.Tool.claude, .codex, .grok, .omp] { #expect(!AgentSessionEngine.typesOpeningMessage(t)) }
    }

    @Test("Agent terminal titles: no agent suffix, no folder stub, cut on a word")
    func agentTitles() {
        #expect(SessionHome.cleanAgentTitle("Slow Sequential Shell Sleep Echo Countin… - grok", agent: "grok", cwd: "/tmp/qtest-grok")
                == "Slow Sequential Shell Sleep Echo…")
        #expect(SessionHome.cleanAgentTitle("run-this-exact-shell-...", agent: "codex",
                                            cwd: "~/run-this-exact-shell-command-261002-1339") == nil)
        #expect(SessionHome.cleanAgentTitle("claude · resume", agent: "claude", cwd: "~/x") == nil)
        #expect(SessionHome.cleanAgentTitle("✳ Fixing the login flow", agent: "claude", cwd: "~/x") == "Fixing the login flow")
        let long = SessionHome.cleanAgentTitle(String(repeating: "word ", count: 20), agent: "omp", cwd: nil)!
        #expect(long.hasSuffix("…") && long.count <= 61 && !long.contains("wor…"))
    }

    @Test("An agent echoing the cut-off prompt gets the first-request title")
    func cutPrompt() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "x", cwd: "/tmp/qtest-kimi")
        s.openingMessage = "Count slowly from 1 to 30: for each number run sleep 1 and echo it"
        let t = AgentSession.title(fromAgent: "Count slowly from 1 to 30: for e", of: s)
        #expect(t == AgentSession.title(fromMessage: s.openingMessage!))
        #expect(t?.hasSuffix("for e") == false)
        // Without an opening message, the transcript's first prompt makes it a placeholder.
        let bare = AgentSession(profileID: UUID(), tool: .kimi, title: "Count slowly from 1 to 30: for e", cwd: "/tmp/q")
        #expect(AgentSession.isPlaceholderTitle(bare.title, of: bare, firstPrompt: s.openingMessage))
        #expect(!AgentSession.isPlaceholderTitle("Counting demo", of: bare, firstPrompt: s.openingMessage))
    }

    @Test("Code fences without a language carry no label")
    func fenceLabel() {
        #expect(CodeFenceLabel.text(nil) == nil)
        #expect(CodeFenceLabel.text("") == nil)
        #expect(CodeFenceLabel.text(" text ") == nil)
        #expect(CodeFenceLabel.text("Swift") == "swift")
    }

    @Test("Header model while starting: the agent's last on that machine")
    func modelFallback() {
        let ws = UUID()
        let s = AgentSession(profileID: ws, tool: .kimi, title: "new", cwd: "~")
        // Nothing known anywhere: nothing shown.
        #expect(TranscriptSearchIndex.shared.model(for: s, among: [s]) == nil)
    }
}
