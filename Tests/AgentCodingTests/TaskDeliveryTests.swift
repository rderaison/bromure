import Foundation
import Testing
@testable import bromure_ac

/// Board tasks talking to their agent: is it alive (process tree, not
/// tmux's foreground command), where does a message go, and what happens to
/// review comments that never got there.
@Suite("Task delivery and agent liveness")
@MainActor
struct TaskDeliveryTests {

    // MARK: Liveness probe

    @Test("probe answers parse to running / shell / gone, anything else is unknown")
    func parseProbe() {
        #expect(AgentPaneProbe.parse("pane kimi\n") == .running("kimi"))
        #expect(AgentPaneProbe.parse("pane claude") == .running("claude"))
        #expect(AgentPaneProbe.parse("pane none") == .shell)
        #expect(AgentPaneProbe.parse("pane ") == .shell)
        #expect(AgentPaneProbe.parse("pane gone") == .gone)
        #expect(AgentPaneProbe.parse("") == nil)
        #expect(AgentPaneProbe.parse("bash: tmux: command not found") == nil)
    }

    @Test("the probe reads the pane's processes, never tmux's foreground command")
    func probeCommandShape() {
        let cmd = AgentPaneProbe.command(window: 4)
        #expect(cmd.contains("bromure:4"))
        #expect(cmd.contains("#{pane_tty}"))
        #expect(cmd.contains("ps -t"))
        #expect(!cmd.contains("pane_current_command"))
    }

    /// Run the probe's filter over sample `ps -o args=` lines.
    private func filter(_ lines: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let input = lines.joined(separator: "\n") + "\n"
        let b64 = Data(input.utf8).base64EncodedString()
        p.arguments = ["-c", "echo \(b64) | base64 -D | \(AgentPaneProbe.agentFilter)"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("a Kimi started from .bashrc (same process group as bash) is seen running")
    func kimiInShellGroup() throws {
        #expect(try filter(["-bash", "bash -l",
                            "/home/ubuntu/.local/share/uv/tools/kimi-cli/bin/python /home/ubuntu/.local/bin/kimi --auto"]) == "kimi")
        #expect(try filter(["bash -l", "/usr/bin/node /usr/local/bin/claude --dangerously-skip-permissions"]) == "claude")
        #expect(try filter(["bash -l", "bun /home/ubuntu/.bun/bin/omp --auto-approve"]) == "omp")
    }

    @Test("only shells, helpers and look-alike words are no agent")
    func noAgent() throws {
        #expect(try filter(["-bash", "bash -l"]) == "")
        #expect(try filter(["bash -l", "sh /home/ubuntu/.bromure/agent-status.sh done"]) == "")
        #expect(try filter(["bash -l", "make compile", "vim example.txt"]) == "")
    }

    // MARK: Delivery decision

    @Test("a message is typed only into a running agent; a bare shell or no tab resumes; unknown never kills")
    func route() {
        #expect(AgentPaneProbe.route(window: 3, state: .running("kimi")) == .type(window: 3))
        #expect(AgentPaneProbe.route(window: 3, state: .shell) == .relaunch(closeWindow: 3))
        #expect(AgentPaneProbe.route(window: 3, state: .gone) == .relaunch(closeWindow: nil))
        #expect(AgentPaneProbe.route(window: nil, state: nil) == .relaunch(closeWindow: nil))
        #expect(AgentPaneProbe.route(window: 3, state: nil) == .undecided)
    }

    @Test("Kimi's opening message is typed by the host; the others take it at launch")
    func typedOpening() {
        #expect(AgentPaneProbe.typesOpeningMessage(.kimi))
        #expect(!AgentPaneProbe.typesOpeningMessage(.claude))
        #expect(!AgentPaneProbe.typesOpeningMessage(.codex))
        #expect(!AgentPaneProbe.typesOpeningMessage(.omp))
    }

    // MARK: Landing hand-over

    @Test("until the landing brief is delivered the card says Handing over, with no live line")
    func handingOverLine() {
        var t = CodingTask(title: "x", profileID: UUID(), tool: .kimi)
        t.stage = .testing
        t.branch = "wt/x"; t.parentBranch = "main"; t.codeChanges = 1
        t.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date())
        t.landing?.handingOver = true
        t.landing?.agentLine = "old line"
        #expect(TaskLandingLine.of(t) == .handingOver(agent: "Kimi Code"))
        #expect(TaskLandingText.line(for: t) == "Handing over to Kimi Code…")
        t.landing?.handingOver = nil
        #expect(TaskLandingText.line(for: t) == "Landing — Kimi Code is merging into main…")
    }

    // MARK: Undelivered review comments

    private func store() -> CodingTaskStore {
        CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
    }

    @Test("handed back to Review: pending comments are flagged undelivered, sent ones untouched")
    func flagsUndelivered() throws {
        let s = store()
        var t = CodingTask(title: "x", profileID: UUID(), tool: .kimi)
        t.stage = .inProgress
        t.comments = [ReviewComment(text: "pending"), ReviewComment(text: "sent", sentAt: Date())]
        s.upsert(t)
        s.mutate(t.id) { $0.stage = .testing }
        let got = try #require(s.task(t.id))
        #expect(got.comments.first { $0.text == "pending" }?.undelivered == true)
        #expect(got.comments.first { $0.text == "sent" }?.undelivered == nil)
    }

    @Test("Done drops comments that never reached the agent")
    func doneDropsPending() throws {
        let s = store()
        var t = CodingTask(title: "x", profileID: UUID(), tool: .kimi)
        t.stage = .testing
        t.comments = [ReviewComment(text: "pending"), ReviewComment(text: "sent", sentAt: Date())]
        s.upsert(t)
        s.mutate(t.id) { $0.stage = .done }
        let got = try #require(s.task(t.id))
        #expect(got.comments.map(\.text) == ["sent"])
    }

    @Test("a comment sent again loses its undelivered flag")
    func resentClearsFlag() throws {
        let s = store()
        var t = CodingTask(title: "x", profileID: UUID(), tool: .kimi)
        t.stage = .testing
        var c = ReviewComment(text: "pending")
        c.undelivered = true
        t.comments = [c]
        s.upsert(t)
        let engine = CodingTaskEngine(store: s, delegate: nil)
        engine.markCommentsSent(t.id, [c.id])
        let got = try #require(s.task(t.id)?.comments.first)
        #expect(got.sentAt != nil)
        #expect(got.undelivered == nil)
    }

    // MARK: vm edit: a deleted key clears the field

    @Test("a key deleted in the editor is sent as null and clears the field; --from-json absence keeps it")
    func editorDeletionClears() throws {
        var base = Profile(name: "ws", tool: .claude, authMode: .subscription)
        base.taskFinish = .pullRequest
        let fetched: [String: Any] = ["name": "ws", "taskFinish": "pullRequest", "memoryGB": 8]
        let edited: [String: Any] = ["name": "ws", "memoryGB": 8]
        let doc = ProfileDocument.editedDocument(fetched: fetched, edited: edited)
        #expect(doc["taskFinish"] is NSNull)
        let cleared = try ProfileDocument.merge(doc, over: base).get()
        #expect(cleared.taskFinish == nil)
        // A partial document that just doesn't mention it leaves it alone.
        let kept = try ProfileDocument.merge(["memoryGB": 8], over: base).get()
        #expect(kept.taskFinish == .pullRequest)
    }
}
