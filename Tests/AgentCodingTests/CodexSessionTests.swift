import Foundation
import Testing
@testable import bromure_ac

/// Codex sessions: resumed by their own conversation id, launched without
/// the update prompt, and its dialogs read from their own lines.
@Suite("Codex sessions")
struct CodexSessionTests {
    private let uuid = "01a10cc6-661b-72c2-9263-8d83b3a2b2ca"

    @Test("A Codex session resumes its own conversation by id")
    @MainActor func resumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .codex, title: "t")
        // Unknown: the folder's latest — or a fresh start when another
        // session shares the folder (never its conversation).
        #expect(AgentSessionEngine.resumeFlags(for: s) == "resume --last")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = uuid
        #expect(AgentSessionEngine.resumeFlags(for: s) == "resume \(uuid)")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "resume \(uuid)")
        // Not an id (a Kimi session name, junk): not passed on.
        s.agentTranscriptID = "session_x"
        #expect(AgentSessionEngine.resumeFlags(for: s) == "resume --last")
    }

    @Test("The conversation id comes from the rollout's name, its first record, or the exit line")
    @MainActor func learnsID() {
        // The hook-pinned path, as the liveness probe reports it.
        let probe = "3\tcodex\trollout-2026-10-05T11-54-51-\(uuid)\tAdd subtract"
        #expect(AgentSessionEngine.parseProbe(probe).first?.transcriptID == uuid)
        #expect(AgentSessionEngine.parseProbe("3\tcodex\trollout-nope\tx").first?.transcriptID == nil)
        #expect(AgentSessionEngine.codexConversationID(
            inPath: "/home/ubuntu/.codex/sessions/2026/10/05/rollout-2026-10-05T11-54-51-\(uuid).jsonl") == uuid)
        #expect(AgentSessionEngine.codexConversationID(inPath: "/x/\(uuid).jsonl") == nil)
        let meta = #"{"timestamp":"2026-10-05T15:54:51.425Z","type":"session_meta","payload":{"id":"\#(uuid)","timestamp":"2026-10-05T15:54:51.298Z","cwd":"/home/ubuntu/cx-demo"}}"#
            + "\n{\"type\":\"turn_context\"}\n"
        let m = AgentSessionEngine.codexSessionMeta(Data(meta.utf8))
        #expect(m?.id == uuid)
        #expect(m?.started != nil)
        #expect(AgentSessionEngine.codexSessionMeta(Data("{\"type\":\"turn_context\"}\n".utf8)) == nil)
        let exit = "Token usage: total=14,021\nTo continue this session, run codex resume \(uuid)\n$ "
        #expect(AgentSessionEngine.codexResumeID(inScreen: exit) == uuid)
        #expect(AgentSessionEngine.codexResumeID(inScreen: "codex resume --last") == nil)
    }

    @Test("Bromure-launched Codex never stops on its update prompt")
    @MainActor func noUpdatePrompt() {
        let f = AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .codex, title: "t"))
        #expect(f.contains("--dangerously-bypass-approvals-and-sandbox"))
        // Off through config.toml — a `-c` override makes Codex drop its
        // shared background server (a permanent warning banner).
        #expect(!f.contains("-c "))
        #expect(SessionDisk.codexLocalProviderTOML(model: "m", contextWindow: 8192)
            .contains("\ncheck_for_update_on_startup = false\n"))
    }

    @Test("The update dialog's heading is its title, not the release-notes link")
    func updateDialogTitle() {
        let lines = [
            "",
            "  ✨ Update available! 0.157.0 -> 0.160.0",
            "",
            "  Release notes: https://github.com/openai/codex/releases/latest",
            "",
            "› 1. Update now (runs `npm install -g @openai/codex`)",
            "  2. Skip",
            "  3. Skip until next version",
            "",
            "  Press enter to continue",
        ]
        let menu = AgentScreen.liveMenu(lines, after: -1)
        #expect(menu?.options.count == 3)
        let title = AgentScreen.title(lines, before: menu?.firstOffset ?? 5)
        #expect(title.contains("Update available"))
        let body = AgentScreen.context(lines, before: menu?.firstOffset ?? 5, title: title)
        #expect(body == "Release notes: https://github.com/openai/codex/releases/latest")
    }

    @Test("An unboxed dialog's card body is its own lines, not the scrollback above it")
    func unboxedBody() {
        let lines = [
            "• Ran python3 -c \"import calc; print(calc.subtract(5,3))\"",
            "  └ 2",
            "",
            "• Added subtract(a, b) to calc.py. Your verification command printed 2.",
            "",
            "  11:50 AM",
            "",
            "",
            "  Select Model and Effort",
            "",
            "› 1. GPT-6-Astra (current)  Frontier intelligence for the most demanding work.",
            "  2. GPT-6-Sol              Previous generation workhorse model.",
            "",
            "  enter select · esc back",
        ]
        let menu = AgentScreen.liveMenu(lines, after: -1)
        #expect(menu?.firstOffset == 10)
        let title = AgentScreen.title(lines, before: 10)
        #expect(title == "Select Model and Effort")
        #expect(AgentScreen.context(lines, before: 10, title: title) == "")
    }

    @Test("A boxed dialog keeps what it shows above its question")
    func boxedBodyKept() {
        let lines = [
            "older output",
            "────────────────────────────────",
            " Bash command",
            "   rm -rf build",
            "   Remove the build folder",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No",
            "",
        ]
        let title = AgentScreen.title(lines, before: 6)
        #expect(title == "Do you want to proceed?")
        let body = AgentScreen.context(lines, before: 6, title: title)
        #expect(body.contains("rm -rf build"))
        #expect(!body.contains("older output"))
    }
}
