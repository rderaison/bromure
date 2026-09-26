import Foundation
import Testing
@testable import bromure_ac

@Suite("Session review")
@MainActor
struct SessionReviewTests {
    @Test("a new file's diff keeps a path with spaces")
    func pathWithSpaces() {
        let raw = """
        diff --git a/notes/todo list.md b/notes/todo list.md
        new file mode 100644
        --- /dev/null
        +++ b/notes/todo list.md\t
        @@ -0,0 +1,2 @@
        +a
        +b
        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.map(\.path) == ["notes/todo list.md"])
        #expect(files.first?.added == 2)
    }

    @Test("the review command reads what each base asks for")
    func sessionCommand() {
        let unc = TaskReviewData.sessionCommand(dir: "/home/ubuntu/it's", base: .uncommitted)
        #expect(unc.contains("cd '/home/ubuntu/it'\\''s'"))
        #expect(unc.contains("b=HEAD;"))
        #expect(unc.contains("ls-files --others --exclude-standard"))
        let br = TaskReviewData.sessionCommand(dir: "/x", base: .branch("main"))
        #expect(br.contains("git merge-base 'main' HEAD"))
        let last = TaskReviewData.sessionCommand(dir: "/x", base: .lastCommit)
        #expect(last.contains("b=HEAD~1") && last.contains("git diff \"$b\" HEAD --") && !last.contains("ls-files"))
    }

    @Test("parse picks up the base commit")
    func parseBase() {
        let d = TaskReviewData.parse("===BASE===\nab12cd3\n===LOG===\n===STATUS===\n?? x\n===DIFF===\n")
        #expect(d.baseRef == "ab12cd3")
        #expect(d.statusLines == ["?? x"])
    }

    @Test("viewed holds while the diff is the same")
    func fingerprint() {
        let a = TaskDiffParser.parse("diff --git a/f b/f\n@@ -1 +1 @@\n-x\n+y\n")[0]
        let b = TaskDiffParser.parse("diff --git a/f b/f\n@@ -1 +1 @@\n-x\n+y\n")[0]
        let c = TaskDiffParser.parse("diff --git a/f b/f\n@@ -1 +1 @@\n-x\n+z\n")[0]
        #expect(TaskReviewData.fingerprint(a) == TaskReviewData.fingerprint(b))
        #expect(TaskReviewData.fingerprint(a) != TaskReviewData.fingerprint(c))
    }

    @Test("a turn's absolute paths match the repo's relative ones")
    func samePath() {
        #expect(ReviewView.samePath("/home/ubuntu/wt-demo/greet.py", "greet.py"))
        #expect(ReviewView.samePath("./src/a.c", "src/a.c"))
        #expect(!ReviewView.samePath("/home/ubuntu/wt-demo/xgreet.py", "greet.py"))
    }

    @Test("comments go to the agent numbered, each with where it points")
    func message() {
        let m = AgentSessionEngine.reviewMessage([
            ReviewComment(text: "Keep the greeting", file: "greet.py", line: 2),
            ReviewComment(text: "Mention whisper", file: "README.md"),
            ReviewComment(text: "Looks good otherwise"),
        ])
        #expect(m.contains("1. `greet.py` line 2: Keep the greeting"))
        #expect(m.contains("2. `README.md`: Mention whisper"))
        #expect(m.contains("3. Looks good otherwise"))
    }

    @Test("the header grows for a merge request")
    func headerHeight() {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "~/p")
        #expect(SessionHome.headerHeight(s, base: 66) == 66)
        s.branchMerge = BranchMerge(target: "main", squash: false, removeAfter: true, startedAt: Date(), phase: .requested)
        #expect(SessionHome.headerHeight(s, base: 66) > 66)
    }
}

@Suite("Branches (pass 3)")
@MainActor
struct BranchesPass3Tests {
    @Test("the folder check reads repo, branches and .worktreeinclude")
    func folderState() {
        let st = GitFolderState.parse("repo main\n===BRANCHES===\nmain\nfeature-cli\n===INCLUDE===\n.env\nconfig/local.json\n")
        #expect(st?.kind == .repo && st?.branch == "main")
        #expect(st?.branches == ["main", "feature-cli"])
        #expect(st?.includes == [".env", "config/local.json"])
        #expect(GitFolderState.parse("none\n")?.kind == .notRepo)
        #expect(GitFolderState.parse("empty\n===BRANCHES===\n===INCLUDE===\n")?.kind == .noCommits)
        #expect(GitFolderState.parse("repo HEAD\n")?.branch == nil)   // detached
        #expect(GitFolderState.parse("") == nil)
    }

    @Test("an older server's answer still reads")
    func folderStateWire() {
        #expect(GitFolderState(json: ["repo": true, "branch": "main"])?.kind == .repo)
        #expect(GitFolderState(json: ["repo": false, "branch": ""])?.kind == .noCommits)
        #expect(GitFolderState(json: ["repo": false])?.kind == .notRepo)
        let st = GitFolderState(kind: .repo, branch: "main", branches: ["main", "x"], includes: [".env"])
        #expect(GitFolderState(json: st.json) == st)
    }

    @Test("the machine's worktrees parse, and find their session")
    func worktreeEntries() {
        let out = "/home/ubuntu/.bromure/worktrees/p/old\t/home/ubuntu/p\twt/old\tmaster\t2\t1\t1790000000\tOld experiment\n"
            + "garbage line\n"
        let e = WorktreeEntry.parse(out)
        #expect(e.count == 1)
        #expect(e.first?.branch == "wt/old" && e.first?.ahead == 2 && e.first?.changed == 1)
        #expect(e.first?.display == "Old experiment" && e.first?.lastCommit != nil)
        let machine = UUID()
        var s = AgentSession(profileID: machine, tool: .claude, title: "t", cwd: "~/p")
        s.worktreeBranch = "wt/old"
        #expect(e.first?.session(in: [s], profileID: machine)?.id == s.id)
        #expect(e.first?.session(in: [s], profileID: UUID()) == nil)
    }
}
