import Foundation
import Testing
@testable import bromure_ac

/// Live-QA round: launch watch fail-fast, post-landing report grace, the
/// input-box guard, plurals.
@Suite("Task board live-QA fixes")
@MainActor
struct TaskLiveQAFixesTests {
    private func store() -> CodingTaskStore {
        CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
    }

    // MARK: Launch watch (F3)

    @Test("The launcher's death marker is read off the pane")
    func exitMarker() {
        let out = "pane none\n\u{1B}[31m[bromure-ac] kimi exited with status 127\u{1B}[0m"
        #expect(AgentPaneProbe.exitStatus(out) == 127)
        #expect(AgentPaneProbe.exitStatus("pane kimi") == nil)
        #expect(AgentPaneProbe.exitStatus("exited with status 1\nexited with status 2") == 2)
        #expect(AgentPaneProbe.parse(out) == .shell)
    }

    @Test("Launch verdict: up at once, died at once on a marker, died after a grace on a bare shell")
    func launchVerdicts() {
        #expect(AgentPaneProbe.launchVerdict(state: .running("kimi"), exitStatus: nil, window: 3,
                                             elapsed: 2, grace: 20, shellStreak: 0) == .up(window: 3))
        // Died within seconds: no need to wait out the grace.
        #expect(AgentPaneProbe.launchVerdict(state: .shell, exitStatus: 127, window: 3,
                                             elapsed: 3, grace: 20, shellStreak: 1) == .died(status: 127))
        // A bare shell early on is just the launch getting there.
        #expect(AgentPaneProbe.launchVerdict(state: .shell, exitStatus: nil, window: 3,
                                             elapsed: 6, grace: 20, shellStreak: 2) == nil)
        #expect(AgentPaneProbe.launchVerdict(state: .shell, exitStatus: nil, window: 3,
                                             elapsed: 30, grace: 20,
                                             shellStreak: AgentPaneProbe.shellProbesToFail) == .died(status: nil))
        // Couldn't ask / tab gone: keep watching.
        #expect(AgentPaneProbe.launchVerdict(state: nil, exitStatus: 1, window: 3,
                                             elapsed: 60, grace: 20, shellStreak: 9) == nil)
        #expect(AgentPaneProbe.launchVerdict(state: .gone, exitStatus: nil, window: 3,
                                             elapsed: 60, grace: 20, shellStreak: 9) == nil)
    }

    @Test("A failed launch says why, with the exit status")
    func launchFailureText() {
        let died = CodingTaskEngine.launchFailure(worker: "Kimi Code", .died(status: 127))
        #expect(died.contains("127") && died.contains("Kimi Code"))
        let quit = CodingTaskEngine.launchFailure(worker: "Kimi Code", .died(status: nil))
        #expect(quit.contains("Kimi Code") && !quit.contains("%"))
        let slow = CodingTaskEngine.launchFailure(worker: "Kimi Code", .timedOut)
        #expect(slow.contains("didn't start"))
    }

    @Test("The launcher prints a real ESC for its red error line, not a literal 033")
    func launcherEscape() {
        let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)) ?? ""
        #expect(!src.isEmpty)
        // In Swift source, a shell "\033" must be written "\\033".
        #expect(!src.contains("printf '\\033[31m"))
    }

    // MARK: Post-landing grace (F4)

    @Test("A verified landing keeps the agent's report working: a late 'merged' is a no-op success")
    func lateReportAfterVerifiedLanding() async {
        let s = store()
        let engine = CodingTaskEngine(store: s, delegate: nil)
        var t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        t.stage = .testing
        t.branch = "wt/fix"
        t.branchSlug = "fix"
        t.parentBranch = "main"
        t.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date())
        s.upsert(t)
        engine.finishLanding(t.id, verified: true, by: nil, grace: 60)
        #expect(s.task(t.id)?.stage == .done)
        #expect(engine.inLandingGrace(t.id))
        let r = await engine.reportLanding(t.id, status: "merged", summary: "in main", prURL: nil)
        #expect(r.ok)
        #expect(r.message.contains("Already recorded"))
        #expect(s.task(t.id)?.completion == .merged(target: "main", verified: true, by: nil))
        #expect(engine.landingGraceEnded.contains(t.id))
    }

    @Test("The board MCP still answers a just-landed task's report")
    func mcpReportDuringGrace() async throws {
        let s = store()
        let engine = CodingTaskEngine(store: s, delegate: nil)
        let pid = UUID()
        let server = TaskBoardMCPServer(profileID: pid, store: { s }, engine: { engine })
        var t = CodingTask(title: "Fix it", profileID: pid, tool: .claude)
        t.stage = .testing
        t.branch = "wt/fix-1"
        t.branchSlug = "fix-1"
        t.parentBranch = "main"
        t.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date())
        s.upsert(t)
        engine.finishLanding(t.id, verified: true, by: nil, grace: 60)
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": "board_report_landing",
                                             "arguments": ["status": "merged", "summary": "done"]]]
        let line = String(data: try JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!
        let out = await server.handle(line: line, branch: "wt/fix-1") ?? ""
        #expect(!out.contains("isn't bound"), Comment(rawValue: out))
        #expect(out.contains("Already recorded"))
    }

    // MARK: Input box (F8)

    @Test("An empty input box between rules reads as empty — placeholder and cursor aside")
    func inputBoxEmpty() {
        let rule = String(repeating: "─", count: 40)
        let bare = "some output\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"
        #expect(AgentInputBox.content(bare) == .empty)
        // Placeholder in dim, cursor in inverse video.
        let placeholder = "\(rule)\n❯ \u{1B}[7mT\u{1B}[27m\u{1B}[2mry \"refactor the parser\"\u{1B}[22m\n\(rule)"
        #expect(AgentInputBox.content(placeholder) == .empty)
        // Grey truecolor placeholder (Codex-style).
        let grey = "\(rule)\n› \u{1B}[38;2;128;128;128mAsk Codex to do anything\u{1B}[39m\n\(rule)"
        #expect(AgentInputBox.content(grey) == .empty)
    }

    @Test("Text in the box is a draft; Bromure's own earlier text is recognized as ours")
    func inputBoxDraft() {
        let rule = String(repeating: "─", count: 40)
        let draft = "\(rule)\n❯ /exit\u{1B}[7m \u{1B}[27m\n\(rule)"
        #expect(AgentInputBox.content(draft) == .text("/exit"))
        #expect(!AgentInputBox.isOwn("/exit", of: "Please continue with this task"))
        let ours = "\(rule)\n│ > Please continue with this task from where   │\n\(rule)"
        if case .text(let d) = AgentInputBox.content(ours) {
            #expect(AgentInputBox.isOwn(d, of: "Please continue with this task from where you left off"))
        } else {
            Issue.record("expected our text in the box")
        }
    }

    @Test("No recognizable box (a busy screen, an echoed message) is unknown, not a draft")
    func inputBoxUnknown() {
        #expect(AgentInputBox.content("") == .unknown)
        #expect(AgentInputBox.content("> what does this do?\n\nIt parses the file.\n") == .unknown)
    }

    // MARK: Plurals (F9)

    @Test("Comment counts have a real singular")
    func plurals() {
        #expect(TaskPlurals.comments(1) == "1 comment")
        #expect(TaskPlurals.comments(2) == "2 comments")
        #expect(TaskPlurals.commentsDrafted(1) == "1 comment drafted")
        #expect(TaskPlurals.undeliveredBanner(3).hasPrefix("3 comments"))
        var t = CodingTask(title: "x", profileID: UUID())
        #expect(TaskPlurals.droppedSuffix(t).isEmpty)
        t.comments = [ReviewComment(text: "a"), ReviewComment(text: "b")]
        #expect(TaskPlurals.droppedSuffix(t).contains("2 review comments"))
    }

    // MARK: Card menus (F5)

    @Test("Card menu items get stable positional ids")
    func cardMenuIDs() {
        var hit = ""
        let items = CardMenuItem.list([
            .init(title: "Open") { hit = "open" },
            .divider,
            .init(title: "Remove", role: .destructive) { hit = "rm" },
        ])
        #expect(items.map(\.id) == [0, 1, 2])
        #expect(items[1].role == .divider)
        items[2].action()
        #expect(hit == "rm")
    }
}

@Suite("Input box via the terminal cursor")
struct InputCursorProbeTests {
    private func probe(_ flag: Int, _ x: Int, _ y: Int, _ h: Int, _ screen: [String]) -> String {
        "\(flag) \(x) \(y) \(h)\n" + screen.joined(separator: "\n")
    }

    @Test("A prompt with nothing typed is empty; typed text left of the cursor is a draft")
    func cursorDraft() {
        var screen = Array(repeating: "", count: 20)
        screen[18] = "> "
        #expect(AgentInputBox.cursorContent(probe(1, 2, 18, 20, screen)) == .empty)
        screen[18] = "> /exit"
        #expect(AgentInputBox.cursorContent(probe(1, 7, 18, 20, screen)) == .text("/exit"))
        // A placeholder to the right of the cursor doesn't count.
        screen[18] = "> Ask anything"
        #expect(AgentInputBox.cursorContent(probe(1, 2, 18, 20, screen)) == .empty)
    }

    @Test("Hidden cursor or a cursor up the screen says nothing")
    func cursorUnknown() {
        var screen = Array(repeating: "", count: 20)
        screen[2] = "> /exit"
        #expect(AgentInputBox.cursorContent(probe(0, 7, 18, 20, screen)) == .unknown)
        #expect(AgentInputBox.cursorContent(probe(1, 7, 2, 20, screen)) == .unknown)
        #expect(AgentInputBox.cursorContent("") == .unknown)
    }
}
