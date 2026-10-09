import Foundation
import Testing
@testable import bromure_ac

@Suite("Task landing QA fixes")
@MainActor
struct TaskQAFixesTests {

    // MARK: Brief roll-up (L3)

    private func brief(planned: Int? = nil, plan: String? = nil, complete: Bool = true) -> CodingTask {
        var b = CodingTask(title: "Brief", profileID: UUID(), tool: .kimi)
        b.stage = .backlog
        b.plan = plan
        b.plannedPhases = planned
        b.planCompletedAt = complete ? Date() : nil
        return b
    }

    private func phase(of parent: CodingTask, done: Bool) -> CodingTask {
        var p = CodingTask(title: "Phase", profileID: parent.profileID, tool: .kimi)
        p.parentTaskID = parent.id
        p.stage = done ? .done : .planning
        return p
    }

    @Test("a brief rolls up only when its whole plan is filed and done")
    func rollUpComplete() {
        let b = brief(planned: 2)
        let p1 = phase(of: b, done: true), p2 = phase(of: b, done: true)
        #expect(CodingTaskEngine.briefRollUp([b, p1, p2], phaseDone: p2.id) == b.id)
    }

    @Test("a brief with unfiled phases never rolls up (2 filed of 6 planned)")
    func rollUpUnfiled() {
        let declared = brief(planned: 6)
        let a1 = phase(of: declared, done: true), a2 = phase(of: declared, done: true)
        #expect(CodingTaskEngine.briefRollUp([declared, a1, a2], phaseDone: a2.id) == nil)
        // Not declared, but the plan text numbers six phases.
        let numbered = brief(plan: "## Phase 1 — scaffold\n## Phase 2 — api\n…\n## Phase 6 — docs")
        let b1 = phase(of: numbered, done: true), b2 = phase(of: numbered, done: true)
        #expect(CodingTaskEngine.briefRollUp([numbered, b1, b2], phaseDone: b2.id) == nil)
    }

    @Test("no roll-up without a completed plan (old data), or with a phase not done")
    func rollUpIncomplete() {
        let old = brief(complete: false)
        let o1 = phase(of: old, done: true)
        #expect(CodingTaskEngine.briefRollUp([old, o1], phaseDone: o1.id) == nil)
        let b = brief(planned: 2)
        let p1 = phase(of: b, done: true), p2 = phase(of: b, done: false)
        #expect(CodingTaskEngine.briefRollUp([b, p1, p2], phaseDone: p1.id) == nil)
    }

    @Test("pumping the queue never rewrites a brief (no roll-up on load)")
    func pumpDoesNotRollUp() {
        let s = CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
        let b = brief(planned: 1)
        s.upsert(b)
        s.upsert(phase(of: b, done: true))
        let engine = CodingTaskEngine(store: s, delegate: nil)
        engine.pumpQueue()
        #expect(s.task(b.id)?.stage == .backlog)
    }

    @Test("the highest Phase N a plan names")
    func phaseNumbers() {
        #expect(CodingTaskEngine.phaseNumbersMentioned(in: "Phase 1, phase #3 and PHASE 12") == 12)
        #expect(CodingTaskEngine.phaseNumbersMentioned(in: "three steps") == 0)
    }

    // MARK: Live agent line (L9)

    @Test("the landing card's line: markdown and ANSI stripped, cut at a word")
    func agentLineClean() {
        let pane = "\u{1B}[1m● Rebased onto `main` — **checks pass**, now [merging](x)\u{1B}[0m\n$ \n"
        #expect(CodingTaskEngine.agentLine(fromPane: pane) == "Rebased onto main — checks pass, now merging")
        let long = "● " + String(repeating: "word ", count: 60)
        let line = CodingTaskEngine.agentLine(fromPane: long, limit: 40) ?? ""
        #expect(line.hasSuffix("…"))
        #expect(line.count <= 41)
        #expect(!line.contains("wor…"))
    }

    // MARK: Landing confirm (L5)

    private func summary(ahead: Int = 1, behind: Int = 0, uncommitted: Int = 0,
                         targetDirty: Int? = 0) -> TaskReviewSummary {
        var s = TaskReviewSummary()
        s.ahead = ahead; s.behind = behind; s.uncommitted = uncommitted
        s.files = 1; s.targetDirty = targetDirty
        return s
    }

    @Test("the confirm says what will actually happen")
    func confirmText() {
        let ff = LandingConfirmSheet.describe(mode: .merge, summary: summary(), target: "main",
                                              branch: "wt/x", agent: "Kimi Code")
        #expect(ff.text.contains("Bromure merges it directly"))
        #expect(ff.warning == nil)
        let rebase = LandingConfirmSheet.describe(mode: .merge, summary: summary(behind: 2), target: "main",
                                                  branch: "wt/x", agent: "Kimi Code")
        #expect(rebase.text.contains("rebase onto main"))
        let commit = LandingConfirmSheet.describe(mode: .merge, summary: summary(uncommitted: 1), target: "main",
                                                  branch: "wt/x", agent: "Kimi Code")
        #expect(commit.text.contains("commit what's left uncommitted"))
        #expect(!commit.text.contains("rebase"))
        let dirty = LandingConfirmSheet.describe(mode: .merge, summary: summary(behind: 1, targetDirty: 3),
                                                 target: "main", branch: "wt/x", agent: "Kimi Code")
        #expect(dirty.warning?.contains("Kimi Code can't merge") == true)
    }

    // MARK: Litter (L11) and empty branches (L10)

    private func sh(_ c: String, in dir: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", c]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("untracked build/cache litter isn't a change; an empty branch is seen as empty",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func litterAndEmptyBranch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("litter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = sh("git init -q -b main && echo a > a && git add a && git commit -qm a && git branch wt/x "
               + "&& mkdir -p pkg/__pycache__ && touch pkg/__pycache__/m.cpython-312.pyc x.pyc .DS_Store", in: dir)
        let q = CodingTaskEngine.shellQuote(dir.path)
        #expect(sh(TaskLitter.status(q), in: dir).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let empty = CodingTaskEngine.emptyBranchCommand(root: dir.path, branch: "wt/x", parent: "main",
                                                        worktreeDir: dir.path)
        #expect(sh(empty, in: dir).contains("EMPTY"))
        // A real untracked file is a change.
        _ = sh("touch notes.txt", in: dir)
        #expect(sh(TaskLitter.status(q), in: dir).contains("notes.txt"))
        #expect(!sh(empty, in: dir).contains("EMPTY"))
    }
}
