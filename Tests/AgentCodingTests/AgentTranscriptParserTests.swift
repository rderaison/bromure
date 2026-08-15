import Foundation
import Testing
@testable import bromure_ac

// Fixture lines below mirror the real on-disk shapes: Codex per its rollout
// writer (openai/codex, Aug 2026), Grok per its persisted ACP stream, Kimi
// verbatim from wire.jsonl files produced by the shipped @moonshot-ai/kimi-code.

@Suite("Multi-agent transcript parsing")
struct AgentTranscriptParserTests {

    // MARK: Codex

    private let codexRollout = """
    {"timestamp":"2026-08-15T10:23:45.123Z","type":"session_meta","payload":{"id":"u1","timestamp":"2026-08-15T10:23:45.123Z","cwd":"/home/ubuntu/proj","originator":"codex_cli_rs","cli_version":"0.99.0"}}
    {"timestamp":"2026-08-15T10:23:45.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>never mind me</user_instructions>"}]}}
    {"timestamp":"2026-08-15T10:23:45.600Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd dump</environment_context>"}]}}
    {"timestamp":"2026-08-15T10:23:46.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the flaky test"}]}}
    {"timestamp":"2026-08-15T10:23:50.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Looking for the test first."}],"content":null,"encrypted_content":"gAAAA"}}
    {"timestamp":"2026-08-15T10:23:52.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"pytest -k flaky\\"],\\"workdir\\":\\"/home/ubuntu/proj\\"}","call_id":"call_1"}}
    {"timestamp":"2026-08-15T10:23:57.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\\"output\\":\\"1 failed\\",\\"metadata\\":{\\"exit_code\\":1,\\"duration_seconds\\":4.2}}"}}
    {"timestamp":"2026-08-15T10:24:00.000Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"pytest flaky rerun"}}}
    {"timestamp":"2026-08-15T10:24:10.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The test races the pool teardown."}]}}
    {"timestamp":"2026-08-15T10:24:10.000Z","type":"event_msg","payload":{"type":"agent_message","message":"The test races the pool teardown."}}
    {"timestamp":"2026-08-15T10:24:11.000Z","type":"turn_context","payload":{"cwd":"/home/ubuntu/proj","model":"gpt-5"}}
    """

    @Test("Codex rollout: response items, synthetic-turn filtering, tool traffic")
    func codexParsing() {
        let items = CodexTranscriptParser.parse(Data(codexRollout.utf8))
        // user + thinking + tool_use(shell) + tool_result + web_search + assistant —
        // the <user_instructions>/<environment_context> turns, the event_msg
        // mirror of the assistant turn, and the plumbing lines all dropped.
        #expect(items.count == 6)
        guard items.count == 6 else { return }
        #expect(items[0].kind == .userText("fix the flaky test"))
        #expect(items[1].kind == .thinking("Looking for the test first."))
        guard case .toolUse(let name, let summary, let detail) = items[2].kind else {
            Issue.record("expected a shell tool_use"); return
        }
        #expect(name == "shell")
        #expect(summary == "pytest -k flaky")          // the bash -lc wrapper unwrapped
        #expect(detail.contains("workdir"))
        guard case .toolResult(let tool, let content, let isError) = items[3].kind else {
            Issue.record("expected a tool_result"); return
        }
        #expect(tool == "shell")
        #expect(content == "1 failed")                 // inner output unwrapped
        #expect(isError)                               // exit_code 1
        guard case .toolUse("web_search", let query, _) = items[4].kind else {
            Issue.record("expected a web_search row"); return
        }
        #expect(query == "pytest flaky rerun")
        #expect(items[5].kind == .assistantText("The test races the pool teardown."))
        #expect(items[0].timestamp != nil)
    }

    @Test("Codex event_msg mirror is the fallback when response items carry no conversation")
    func codexEventFallback() {
        let eventsOnly = """
        {"timestamp":"2026-08-15T10:23:46.000Z","type":"event_msg","payload":{"type":"user_message","message":"hello","kind":"plain"}}
        {"timestamp":"2026-08-15T10:23:47.000Z","type":"event_msg","payload":{"type":"user_message","message":"<user_instructions>x</user_instructions>","kind":"user_instructions"}}
        {"timestamp":"2026-08-15T10:23:48.000Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"thinking about it"}}
        {"timestamp":"2026-08-15T10:23:49.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hi there"}}
        """
        let items = CodexTranscriptParser.parse(Data(eventsOnly.utf8))
        #expect(items.map(\.kind) == [.userText("hello"),
                                      .thinking("thinking about it"),
                                      .assistantText("hi there")])
    }

    // MARK: Grok

    private let grokUpdates = """
    {"timestamp":1784388050,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"add a retry "}},"_meta":{"eventId":"e1"}}}
    {"timestamp":1784388050,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"to the uploader"}},"_meta":{"eventId":"e2"}}}
    {"timestamp":1784388052,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The uploader lives in sync.rs."}}}}
    {"timestamp":1784388053,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"run_shell","kind":"execute","status":"in_progress","rawInput":{"command":"cargo test uploader"}}}}
    {"timestamp":1784388054,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}}}
    {"timestamp":1784388059,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"test result: ok"}}]}}}
    {"timestamp":1784388061,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done — retry "}}}}
    {"timestamp":1784388061,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"added."}}}}
    {"timestamp":1784388062,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100}}}}
    """

    @Test("Grok ACP stream: chunk merging, tool lifecycle, plumbing dropped")
    func grokParsing() {
        let items = GrokTranscriptParser.parse(Data(grokUpdates.utf8))
        #expect(items.count == 5)
        guard items.count == 5 else { return }
        #expect(items[0].kind == .userText("add a retry to the uploader"))
        #expect(items[1].kind == .thinking("The uploader lives in sync.rs."))
        guard case .toolUse("run_shell", let summary, _) = items[2].kind else {
            Issue.record("expected the shell tool_call"); return
        }
        #expect(summary == "cargo test uploader")
        // Only the TERMINAL status yields a result row — the in_progress
        // update is dropped.
        guard case .toolResult("run_shell", "test result: ok", false) = items[3].kind else {
            Issue.record("expected the completed tool result"); return
        }
        #expect(items[4].kind == .assistantText("Done — retry added."))
        #expect(items[0].timestamp == Date(timeIntervalSince1970: 1_784_388_050))
    }

    @Test("Grok failed tool update carries the error flag")
    func grokFailedTool() {
        let jsonl = """
        {"timestamp":1,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"c","title":"edit_file","kind":"edit","rawInput":{"file_path":"/x/y.rs"}}}}
        {"timestamp":2,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"failed","rawOutput":"no such file"}}}
        """
        let items = GrokTranscriptParser.parse(Data(jsonl.utf8))
        #expect(items.count == 2)
        guard case .toolResult("edit_file", "no such file", true) = items.last?.kind else {
            Issue.record("expected a failed tool result"); return
        }
    }

    // MARK: Kimi

    /// Abridged from a real @moonshot-ai/kimi-code 0.36.1 wire.jsonl.
    private let kimiWire = """
    {"type":"metadata","protocol_version":"1.5","created_at":1786809539556}
    {"type":"permission.set_mode","mode":"auto","time":1786809539588}
    {"type":"turn.prompt","input":[{"type":"text","text":"run echo for me"}],"origin":{"kind":"user"},"time":1786809539589}
    {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"run echo for me"}],"toolCalls":[],"origin":{"kind":"user"},"id":"m1"},"time":1786809539590}
    {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>auto mode</system-reminder>"}],"toolCalls":[],"origin":{"kind":"injection","variant":"permission_mode"},"id":"m2"},"time":1786809539590}
    {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"s1","turnId":"0","step":1},"time":1786809539592}
    {"type":"llm.request","kind":"loop","provider":"openai","model":"m","time":1786809539600}
    {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p0","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"think","think":"Simple enough."}},"time":1786809539605}
    {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p1","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"text","text":"Let me "}},"time":1786809539606}
    {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p2","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"text","text":"run that."}},"time":1786809539606}
    {"type":"context.append_loop_event","event":{"type":"tool.call","uuid":"t1","turnId":"0","step":1,"stepUuid":"s1","toolCallId":"call_abc123","name":"Bash","args":{"command":"echo kimi-transcript-test"}},"time":1786809539616}
    {"type":"context.append_loop_event","event":{"type":"tool.result","parentUuid":"t1","toolCallId":"call_abc123","result":{"output":"kimi-transcript-test","isError":false}},"time":1786809539616}
    {"type":"context.append_loop_event","event":{"type":"step.end","uuid":"s1","turnId":"0","step":1,"finishReason":"tool_use"},"time":1786809539617}
    {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p3","turnId":"0","step":2,"stepUuid":"s2","part":{"type":"text","text":"Done."}},"time":1786809539622}
    {"type":"turn.ended","turnId":0,"reason":"completed","durationMs":32,"time":1786809539622}
    """

    @Test("Kimi wire journal: fold to conversation, injections and plumbing dropped")
    func kimiParsing() {
        let items = KimiTranscriptParser.parse(Data(kimiWire.utf8))
        #expect(items.count == 6)
        guard items.count == 6 else { return }
        // One user turn — turn.prompt and append_message carry the same
        // text, and the injection rides the user role with origin
        // "injection"; neither may duplicate or leak in.
        #expect(items[0].kind == .userText("run echo for me"))
        #expect(items[1].kind == .thinking("Simple enough."))
        // Streamed parts of the same step concatenate into one message.
        #expect(items[2].kind == .assistantText("Let me run that."))
        guard case .toolUse("Bash", let summary, _) = items[3].kind else {
            Issue.record("expected the Bash tool call"); return
        }
        #expect(summary == "echo kimi-transcript-test")
        guard case .toolResult("Bash", "kimi-transcript-test", false) = items[4].kind else {
            Issue.record("expected the Bash result"); return
        }
        // A new step is a new message — not merged across the tool call.
        #expect(items[5].kind == .assistantText("Done."))
        // time is epoch-milliseconds (tolerance: ms→s division vs literal
        // can differ in the last float ulp).
        let stamp = items[0].timestamp?.timeIntervalSince1970 ?? 0
        #expect(abs(stamp - 1_786_809_539.590) < 0.01)
    }

    // MARK: Sniffing + dispatch

    @Test("Format sniffing tells the four stores apart, defaulting to Claude")
    func sniffing() {
        #expect(AgentTranscript.sniff(Data(codexRollout.utf8)) == "codex")
        #expect(AgentTranscript.sniff(Data(grokUpdates.utf8)) == "grok")
        #expect(AgentTranscript.sniff(Data(kimiWire.utf8)) == "kimi")
        let claude = """
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        #expect(AgentTranscript.sniff(Data(claude.utf8)) == "claude")
        #expect(AgentTranscript.sniff(Data("garbage\n".utf8)) == "claude")
        // A tail-cut read starting mid-line still sniffs from the next line.
        let cut = "berish\"}}\n" + kimiWire
        #expect(AgentTranscript.sniff(Data(cut.utf8)) == "kimi")
        // Dispatch honors an explicit hint and sniffs unknown/absent ones.
        #expect(AgentTranscript.parse(Data(kimiWire.utf8), agent: "kimi").count == 6)
        #expect(AgentTranscript.parse(Data(kimiWire.utf8), agent: "goose").count == 6)
        #expect(AgentTranscript.parse(Data(claude.utf8)).count == 1)
    }
}

@Suite("Multi-agent transcript locator commands")
struct AgentTranscriptLocatorTests {

    /// Every generated command must at least be valid sh — the quoting in
    /// these lines is dense enough that a syntax check is worth a process.
    private func shSyntaxOK(_ cmd: String) throws -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loc-\(UUID().uuidString).sh")
        try cmd.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", url.path]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @Test("planTranscriptCommand: per-agent stores, union for unknown, pq stays Claude-only")
    func planCommandStores() throws {
        let cwd = "/home/ubuntu/proj"
        let claude = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 7,
                                                            agent: "claude")
        #expect(claude?.contains(".claude/projects") == true)
        #expect(claude?.contains("pq--home-ubuntu-proj.json") == true)
        #expect(claude?.contains(".codex/") == false)

        let codex = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 7,
                                                           agent: "codex")
        #expect(codex?.contains(".codex/sessions") == true)
        #expect(codex?.contains("rollout-*.jsonl") == true)
        // cwd matched against the session_meta head, logical AND resolved.
        #expect(codex?.contains("\\\"cwd\\\":\\\"$d\\\"") == true)
        #expect(codex?.contains("\\\"cwd\\\":\\\"$r\\\"") == true)
        #expect(codex?.contains("pq-") == false)

        let grok = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 7,
                                                          agent: "grok")
        // Host-side percent-encoding of the logical path ('/' → %2F).
        #expect(grok?.contains(".grok/sessions/%2Fhome%2Fubuntu%2Fproj") == true)
        #expect(grok?.contains("updates.jsonl") == true)
        #expect(grok?.contains("urllib.parse.quote") == true)   // resolved path, guest-side

        let kimi = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 7,
                                                          agent: "kimi")
        #expect(kimi?.contains(".kimi-code/sessions/wd_") == true)
        #expect(kimi?.contains("sha256sum") == true)
        #expect(kimi?.contains("agents/main/wire.jsonl") == true)

        // Unknown agent: all four stores probed, newest file wins.
        let union = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 7)
        for marker in [".claude/projects", ".codex/sessions", ".grok/sessions",
                       ".kimi-code/sessions", "pq--home-ubuntu-proj.json"] {
            #expect(union?.contains(marker) == true, "union misses \(marker)")
        }
        // Every store keeps the since-floor and the strict-decode guard.
        for cmd in [claude, codex, grok, kimi, union] {
            #expect(cmd?.contains("-newermt @7") == true)
            #expect(cmd?.contains("iconv -f UTF-8 -t UTF-8 -c") == true)
            #expect(try shSyntaxOK(cmd ?? ""), "sh -n rejected: \(cmd ?? "nil")")
        }
        // The quoting refusal is agent-independent.
        #expect(CodingTaskEngine.planTranscriptCommand(guestCwd: "/e'vil", since: 0,
                                                       agent: "codex") == nil)
    }

    @Test("Grok percent-encoding matches urllib.parse.quote(safe=\"\")")
    func grokEncoding() {
        // Unreserved chars stay literal; '/', '+', and space are escaped —
        // the exact python rule the guest-side fallback uses.
        let cmd = CodingTaskEngine.planTranscriptCommand(
            guestCwd: "/home/u/My_Repo.v2+x y", since: 0, agent: "grok")
        #expect(cmd?.contains(".grok/sessions/%2Fhome%2Fu%2FMy_Repo.v2%2Bx%20y") == true)
    }

    @Test("taskTranscriptCommand: per-tool store, slug + cwd fallbacks, syntax")
    func taskCommandStores() throws {
        let claude = CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-leak")
        #expect(claude?.contains(".claude/projects/*-fix-leak") == true)

        let kimi = CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-leak",
                                                          agent: .kimi)
        #expect(kimi?.contains("wd_fix-leak_*") == true)
        #expect(kimi?.contains("wd_fix-leak-[0-9]*_*") == true)   // guest-deduped worktree
        #expect(kimi?.contains("agents/main/wire.jsonl") == true)

        let codex = CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-leak",
                                                           agent: .codex)
        #expect(codex?.contains("rollout-*.jsonl") == true)
        // Slug fallback: the worktree's basename is the slug, so the
        // session_meta cwd ends in "/fix-leak" (or a deduped "-N").
        #expect(codex?.contains("/fix-leak(-[0-9]+)?") == true)

        let grok = CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-leak",
                                                          agent: .grok)
        #expect(grok?.contains("%2Ffix-leak") == true)
        #expect(grok?.contains("updates.jsonl") == true)

        for cmd in [claude, kimi, codex, grok] {
            #expect(cmd?.contains("head -c 25000000") == true)
            #expect(try shSyntaxOK(cmd ?? ""), "sh -n rejected: \(cmd ?? "nil")")
        }
        #expect(CodingTaskEngine.taskTranscriptCommand(branch: "fix-leak",
                                                       agent: .kimi) == nil)
        #expect(CodingTaskEngine.taskTranscriptCommand(branch: "wt/Bad'Slug",
                                                       agent: .codex) == nil)
    }
}
