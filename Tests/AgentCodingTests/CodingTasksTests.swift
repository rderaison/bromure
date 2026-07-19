import Foundation
import Testing
@testable import bromure_ac

@Suite("Coding tasks")
struct CodingTasksTests {

    @Test("Task prompt carries title, details, and the commit directive")
    func prompt() {
        let task = CodingTask(title: "Fix the leak",
                              details: "## Context\nThe pool leaks fds.",
                              profileID: UUID())
        let p = CodingTaskEngine.prompt(for: task)
        #expect(p.hasPrefix("Fix the leak\n\n## Context"))
        #expect(p.contains("COMMIT all of your work"))
        #expect(p.contains("do not merge into any other branch"))
        // The explicit hand-to-review signal — same script the Stop hook
        // runs, so the transition doesn't depend on hook inference alone.
        #expect(p.contains("agent-status.sh done"))
        // Board MCP tools are announced.
        #expect(p.contains("board_ready_for_review"))
    }

    @Test("Planner prompt: visible, plans-only, files phases via the MCP")
    func plannerPrompt() {
        let task = CodingTask(title: "Create an EDR", details: "eBPF based",
                              profileID: UUID())
        let p = CodingTaskEngine.plannerPrompt(for: task)
        #expect(p.contains("PLANNING this task, not implementing"))
        #expect(p.contains("board_create_subtasks"))
        #expect(p.contains("dependsOn"))
        #expect(p.contains("board_set_plan"))
        #expect(p.contains("Do NOT write any code"))
        #expect(p.contains("agent-status.sh done"))
        #expect(p.contains("Create an EDR"))
    }

    @Test("Unmet dependencies: only non-Done deps block; deleted deps don't")
    func dependencies() {
        let pid = UUID()
        var dep = CodingTask(title: "one", profileID: pid)
        var mid = CodingTask(title: "two", profileID: pid)
        mid.dependsOn = [dep.id, UUID()]   // second id doesn't exist anywhere
        #expect(mid.unmetDependencies(in: [dep, mid]) == [dep.id])
        dep.stage = .done
        #expect(mid.unmetDependencies(in: [dep, mid]).isEmpty)
    }

    @Test("Feedback prompt lists unsent comments with file scopes")
    func feedback() {
        let comments = [
            ReviewComment(text: "Rename this", file: "src/pool.c"),
            ReviewComment(text: "Add a test"),
        ]
        let p = CodingTaskEngine.feedbackPrompt(comments: comments)
        #expect(p.contains("- [src/pool.c] Rename this"))
        #expect(p.contains("- Add a test"))
        #expect(p.contains("commit"))
    }

    @Test("Validation prompt is read-only, structured, and carries the brief")
    func validationPrompt() {
        let task = CodingTask(title: "Add caching",
                              details: "Use an LRU with 100 entries.",
                              profileID: UUID())
        let p = CodingTaskEngine.validationPrompt(for: task)
        #expect(p.contains("do NOT modify any files"))
        #expect(p.contains("## Questions"))
        #expect(p.contains("## Assumptions"))
        #expect(p.contains("## Risks"))
        #expect(p.contains("Add caching"))
        #expect(p.contains("LRU with 100 entries"))
    }

    @Test("validationInFlight: requested-and-unanswered only, bounded")
    func inFlight() {
        var task = CodingTask(title: "t", profileID: UUID())
        #expect(!task.validationInFlight)
        task.validationRequestedAt = Date()
        #expect(task.validationInFlight)
        task.validatedAt = Date()
        #expect(!task.validationInFlight)
        // A planning interview can legitimately run for a while — the bound
        // is an hour (the watchdog aborts dead sessions much sooner).
        task.validationRequestedAt = Date(timeIntervalSinceNow: -600)
        task.validatedAt = nil
        #expect(task.validationInFlight)
        task.validationRequestedAt = Date(timeIntervalSinceNow: -3700)  // stale
        #expect(!task.validationInFlight)
    }

    @Test("planTranscriptCommand: Claude project-dir encoding, since-gate, rejection")
    func transcriptCommand() {
        let cmd = CodingTaskEngine.planTranscriptCommand(
            guestCwd: "/home/ubuntu/edr/", since: 1_752_800_000)
        #expect(cmd?.contains("projects/-home-ubuntu-edr\"") == true)  // no trailing slash
        #expect(cmd?.contains("-newermt @1752800000") == true)
        // A dotted path is searched under BOTH encodings Claude has used.
        let dotted = CodingTaskEngine.planTranscriptCommand(
            guestCwd: "/home/u/my.app", since: 5)
        #expect(dotted?.contains("-home-u-my.app") == true)
        #expect(dotted?.contains("-home-u-my-app") == true)
        // Quotes and other unquotable characters refuse rather than escape.
        #expect(CodingTaskEngine.planTranscriptCommand(guestCwd: "/e'vil", since: 0) == nil)
        #expect(CodingTaskEngine.planTranscriptCommand(guestCwd: "", since: 0) == nil)
    }

    @Test("initRepoCommand: idempotent init with a root commit")
    func initRepoCmd() {
        let cmd = CodingTaskEngine.initRepoCommand(quotedPath: "'/home/ubuntu/new'")
        #expect(cmd.contains("mkdir -p '/home/ubuntu/new'"))
        #expect(cmd.contains("git init -q"))
        #expect(cmd.contains("--allow-empty"))   // worktrees need a HEAD
        #expect(cmd.contains("--show-toplevel")) // no nested repo when already a root
    }

    @Test("AskUserQuestion parses into question items with options")
    func questionParsing() {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which runtime?","header":"Runtime","multiSelect":false,"options":[{"label":"Python stdlib","description":"zero deps"},{"label":"Docker","description":""}]},{"question":"Which checks?","header":"Checks","multiSelect":true,"options":[{"label":"CVE match","description":"feed"}]}]}}]}}
        """
        let items = ClaudeTranscriptParser.parse(Data(line.utf8))
        #expect(items.count == 2)
        guard case .question(let q1) = items[0].kind,
              case .question(let q2) = items[1].kind else {
            Issue.record("expected question items"); return
        }
        #expect(q1.question == "Which runtime?")
        #expect(q1.header == "Runtime")
        #expect(!q1.multiSelect)
        #expect(q1.options.map(\.label) == ["Python stdlib", "Docker"])
        #expect(q2.multiSelect)
        // Malformed input degrades to a generic tool row, not a crash.
        let bad = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"AskUserQuestion","input":{"nope":1}}]}}
        """
        let fallback = ClaudeTranscriptParser.parse(Data(bad.utf8))
        #expect(fallback.count == 1)
        if case .question = fallback[0].kind { Issue.record("should be generic tool row") }
    }

    @Test("answerKeysCommand: literal digits, named keys, beats between")
    func answerKeys() {
        let cmd = CodingTaskEngine.answerKeysCommand(
            tabIndex: 3, keys: ["1", "Right", "Enter"])
        #expect(cmd == "tmux send-keys -t bromure:3 -l 1 && sleep 1 && "
            + "tmux send-keys -t bromure:3 Right && sleep 1 && "
            + "tmux send-keys -t bromure:3 Enter")
        // Anything not a digit or known key name is dropped, not injected.
        #expect(CodingTaskEngine.answerKeysCommand(tabIndex: 0, keys: ["; rm -rf /"]).isEmpty)
    }

    @Test("Tasks decode without optional fields (forward compat)")
    func decodeCompat() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","details":"","profileID":
         "\(UUID().uuidString)","repoPath":"~","tool":"claude","stage":"backlog",
         "comments":[],"createdAt":"2026-07-01T09:00:00Z","merged":false}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let task = try d.decode(CodingTask.self, from: Data(json.utf8))
        #expect(task.stage == .backlog)
        #expect(task.branch == nil)
    }
}

@Suite("Task diff parser")
struct TaskDiffParserTests {

    @Test("Unified diff splits into files with counted +/- lines")
    func basics() {
        let raw = """
        diff --git a/src/a.c b/src/a.c
        index 111..222 100644
        --- a/src/a.c
        +++ b/src/a.c
        @@ -1,3 +1,4 @@
         context
        -old line
        +new line
        +added line
        diff --git a/README.md b/README.md
        new file mode 100644
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1 @@
        +hello
        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.count == 2)
        guard files.count == 2 else { return }
        #expect(files[0].path == "src/a.c")
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        #expect(files[0].lines.first?.kind == .hunk)
        #expect(files[1].path == "README.md")
        #expect(files[1].added == 1)
    }

    @Test("Header noise (index/mode/rename/binary) never becomes diff lines")
    func noise() {
        let raw = """
        diff --git a/x b/x
        old mode 100644
        new mode 100755
        Binary files a/x and b/x differ
        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.count == 1)
        #expect(files.first?.lines.isEmpty == true)
    }

    @Test("Review data splits marker-delimited guest output")
    func reviewData() {
        let raw = """
        ===LOG===
        abc1234 add feature
        ===STATUS===
        ?? notes.txt
         M src/a.c
        ===DIFF===
        diff --git a/src/a.c b/src/a.c
        @@ -1 +1 @@
        -a
        +b
        """
        let data = TaskReviewData.parse(raw)
        #expect(data.logLines == ["abc1234 add feature"])
        #expect(data.statusLines.count == 2)
        #expect(data.files.count == 1)
        #expect(data.files.first?.added == 1)
    }
}
