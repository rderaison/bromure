import Foundation
import Testing
@testable import bromure_ac

@Suite("Landing an approved task")
@MainActor
struct TaskLandingTests {
    private func store() -> CodingTaskStore {
        CodingTaskStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-\(UUID().uuidString).json"))
    }

    private func reviewTask(_ s: CodingTaskStore, branch: String? = "wt/fix") -> CodingTask {
        var t = CodingTask(title: "Fix it", profileID: UUID(), tool: .claude)
        t.stage = .testing
        t.branch = branch
        t.branchSlug = branch.map { String($0.dropFirst(3)) }
        t.parentBranch = "main"
        t.rootRepo = "/home/ubuntu/repo"
        s.upsert(t)
        return t
    }

    // MARK: Model / migration

    @Test("an old in-flight merge (mergingAt) decodes as an agent landing into the parent")
    func migratesMergingAt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        let id = UUID()
        let json = """
        {"tasks":[{"id":"\(id.uuidString)","title":"Old","details":"","profileID":"\(UUID().uuidString)",
        "repoPath":"~","tool":"claude","stage":"testing","branch":"wt/old","parentBranch":"dev",
        "comments":[],"createdAt":"2026-09-01T10:00:00Z","merged":false,"mergingAt":"2026-09-01T11:00:00Z"}]}
        """
        try Data(json.utf8).write(to: url)
        let s = CodingTaskStore(fileURL: url)
        let t = try #require(s.task(id))
        #expect(t.mergingAt == nil)
        #expect(t.landing?.phase == .agentLanding)
        #expect(t.landing?.target == "dev")
        #expect(t.landing?.mode == .merge)
    }

    @Test("Done provenance is derived for cards an older build finished")
    func derivedCompletion() {
        var t = CodingTask(title: "x", profileID: UUID())
        t.stage = .done
        t.parentBranch = "main"
        t.merged = true
        #expect(t.effectiveCompletion == .merged(target: "main", verified: true, by: nil))
        #expect(TaskLandingText.done(t) == "Merged into main")
        t.merged = false; t.prOpened = true; t.pullRequestURL = "https://github.com/o/r/pull/42"
        #expect(TaskLandingText.done(t) == "PR #42 opened")
        t.prOpened = nil
        #expect(t.effectiveCompletion == .closedWithoutMerge)
        t.completion = .markedDone(byUser: true)
        #expect(TaskLandingText.done(t) == "Marked done by you")
        t.completion = .merged(target: "release", verified: false, by: "Kimi Code")
        #expect(TaskLandingText.done(t).contains("Merged into release"))
        #expect(TaskLandingText.done(t).contains("not verified"))
    }

    @Test("the landing state machine drives the card line")
    func cardLines() {
        var t = CodingTask(title: "x", profileID: UUID(), tool: .kimi)
        t.stage = .testing
        t.branch = "wt/x"; t.parentBranch = "main"; t.codeChanges = 3
        #expect(TaskLandingLine.of(t) == .readyToLand)
        t.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date())
        #expect(TaskLandingText.line(for: t) == "Landing — Kimi Code is merging into main…")
        t.landing?.phase = .needsYou
        t.landing?.detail = "conflict in a.swift"
        #expect(TaskLandingText.line(for: t) == "Needs you — conflict in a.swift")
        t.landing = nil
        t.codeChanges = 0
        #expect(TaskLandingLine.of(t) == nil)   // no code: nothing to land
    }

    // MARK: Preference resolution

    @Test("finish preference: task over workspace over app")
    func preferenceResolution() {
        #expect(TaskFinish.resolve(task: nil, workspace: nil, app: .merge) == .merge)
        #expect(TaskFinish.resolve(task: nil, workspace: nil, app: .pullRequest) == .pullRequest)
        #expect(TaskFinish.resolve(task: nil, workspace: .pullRequest, app: .merge) == .pullRequest)
        #expect(TaskFinish.resolve(task: .merge, workspace: .pullRequest, app: .pullRequest) == .merge)
    }

    @Test("a workspace override round-trips; an absent one stays nil")
    func profileCodable() throws {
        var p = Profile(id: UUID(), name: "W", tool: .claude, authMode: .subscription)
        let plain = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(plain.taskFinish == nil)
        p.taskFinish = .pullRequest
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.taskFinish == .pullRequest)
    }

    // MARK: No-code detection

    @Test("no-code: no branch, a delegated delivery without a worktree, or zero changes")
    func noCode() {
        var t = CodingTask(title: "x", profileID: UUID())
        t.stage = .testing
        #expect(t.isNoCode)                       // no branch at all
        t.branch = "wt/x"; t.branchSlug = "x"
        #expect(!t.isNoCode)                      // unknown yet: assume code
        t.codeChanges = 0
        #expect(t.isNoCode)
        t.codeChanges = 2
        #expect(!t.isNoCode)
        t.delegationID = UUID(); t.worktreeDir = nil
        #expect(t.isNoCode)                       // delivered, worktree never found
        var s = TaskReviewSummary()
        #expect(s.isNoCode)
        s.ahead = 1; s.files = 1
        #expect(!s.isNoCode)
    }

    @Test("the review summary parses one guest command's output")
    func summaryParse() {
        let out = """
        AB 2\t5
        SS  4 files changed, 120 insertions(+), 7 deletions(-)
        UC 1
        TD /home/ubuntu/repo
        TC 0
        RM origin
        RU git@github.com:o/r.git
        """
        let s = TaskReviewSummary.parse(out)
        #expect(s.behind == 2 && s.ahead == 5)
        #expect(s.files == 4 && s.insertions == 120 && s.deletions == 7)
        #expect(s.uncommitted == 1)
        #expect(s.targetDir == "/home/ubuntu/repo" && s.targetDirty == 0)
        #expect(s.remote == "origin")
        #expect(!s.fastForward(squash: false))   // target moved + uncommitted
        let clean = TaskReviewSummary.parse("AB 0\t3\nSS 1 file changed, 1 insertion(+)\nUC 0\nTD \nRM \n")
        #expect(clean.remote == nil && clean.targetDirty == nil)
        #expect(clean.fastForward(squash: false))
        #expect(!clean.fastForward(squash: true))   // three commits to squash
        let cmd = TaskReviewSummary.command(root: "/r", worktreeDir: "/w", branch: "wt/x", target: "main")
        #expect(cmd.contains("rev-list --left-right --count 'main...wt/x'"))
        #expect(cmd.contains("remote get-url"))
    }

    // MARK: Prompts / guest commands

    @Test("merge landing prompt: commit, rebase, checks, ff-only, report via the board")
    func mergePrompt() {
        let p = CodingTaskEngine.landingPrompt(mode: .merge, branch: "wt/fix", target: "main",
                                               rootRepo: "/home/ubuntu/repo", title: "Fix it",
                                               remote: nil, viaBoard: true)
        #expect(p.contains("git rebase 'main'"))
        #expect(p.contains("git merge --ff-only 'wt/fix'"))
        #expect(p.contains("fetch . 'wt/fix:main'"))
        #expect(p.contains("Never touch, stash or discard uncommitted changes"))
        #expect(p.contains("board_report_landing") && p.contains("\"merged\"") && p.contains("\"blocked\""))
        #expect(p.contains("user.email=bromure@localhost"))
        #expect(!p.contains("git reset --soft"))
        let sq = CodingTaskEngine.landingPrompt(mode: .squash, branch: "wt/fix", target: "main",
                                                rootRepo: "/r", title: "Fix \"it\"", remote: nil, viaBoard: true)
        #expect(sq.contains("git reset --soft 'main' && git commit -m 'Fix \"it\"'"))
    }

    @Test("PR landing prompt: push to the remote, gh pr create against the target, report the URL")
    func prPrompt() {
        let p = CodingTaskEngine.landingPrompt(mode: .pr, branch: "wt/fix", target: "dev",
                                               rootRepo: "/r", title: "Fix", remote: "upstream", viaBoard: true)
        #expect(p.contains("git push -u 'upstream' 'wt/fix'"))
        #expect(p.contains("gh pr create --base 'dev'"))
        #expect(p.contains("## Test plan"))
        #expect(p.contains("\"pr_opened\"") && p.contains("prURL"))
    }

    @Test("the fast path never merges into another branch's checkout")
    func checkCommand() {
        let cmd = CodingTaskEngine.landingCheckCommand(root: "/r", branch: "wt/x", target: "main",
                                                       sourceDir: "/w", mode: .merge)
        #expect(cmd.contains("merge --ff-only"))
        #expect(cmd.contains("'branch refs/heads/main'"))
        #expect(cmd.contains("fetch -q . 'wt/x:main'"))
        #expect(cmd.contains("dirty-source"))
        let pr = CodingTaskEngine.landingCheckCommand(root: "/r", branch: "wt/x", target: "main",
                                                      sourceDir: nil, mode: .pr)
        #expect(!pr.contains("merge --ff-only"))
        #expect(CodingTaskEngine.parseLandingCheck("merged-now\n") == .mergedNow)
        #expect(CodingTaskEngine.parseLandingCheck("noise\ndiverged") == .diverged)
        #expect(CodingTaskEngine.parseLandingCheck(nil) == .failed)
    }

    @Test("the fast-path probe against a real repository", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func checkCommandLive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("land-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func sh(_ c: String) -> String {
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
        let r = dir.path
        _ = sh("git init -q -b main && echo a > a && git add a && git commit -qm a && git branch other "
               + "&& git worktree add -q -b wt/x ../\(dir.lastPathComponent)-wt && cd ../\(dir.lastPathComponent)-wt "
               + "&& echo b > b && git add b && git commit -qm b")
        let wt = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-wt").path
        defer { try? FileManager.default.removeItem(atPath: wt) }
        // `other` isn't checked out anywhere: the ref moves; main's checkout
        // (on main) is untouched by that.
        let out1 = sh(CodingTaskEngine.landingCheckCommand(root: r, branch: "wt/x", target: "other",
                                                           sourceDir: wt, mode: .merge))
        #expect(CodingTaskEngine.parseLandingCheck(out1) == .mergedNow)
        #expect(sh("git rev-parse other") == sh("git rev-parse wt/x"))
        #expect(sh("git rev-parse main") != sh("git rev-parse wt/x"))
        // main is checked out here: ff there.
        let out2 = sh(CodingTaskEngine.landingCheckCommand(root: r, branch: "wt/x", target: "main",
                                                           sourceDir: wt, mode: .merge))
        #expect(CodingTaskEngine.parseLandingCheck(out2) == .mergedNow)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b").path))
        // Already in: nothing to do.
        let out3 = sh(CodingTaskEngine.landingCheckCommand(root: r, branch: "wt/x", target: "main",
                                                           sourceDir: wt, mode: .merge))
        #expect(CodingTaskEngine.parseLandingCheck(out3) == .merged)
        #expect(sh(CodingTaskEngine.landingVerifyCommand(root: r, branch: "wt/x", target: "main", sourceDir: wt))
            .contains("LANDED"))
        // Uncommitted work in the task's checkout: the agent's job.
        try "c".write(toFile: wt + "/c", atomically: true, encoding: .utf8)
        let out4 = sh(CodingTaskEngine.landingCheckCommand(root: r, branch: "wt/x", target: "main",
                                                           sourceDir: wt, mode: .merge))
        #expect(CodingTaskEngine.parseLandingCheck(out4) == .dirtySource)
    }

    @Test("merge & push prompts: fetch and pull the remote first, push, never force")
    func pushPrompts() {
        let p = CodingTaskEngine.landingPrompt(mode: .merge, branch: "wt/fix", target: "main",
                                               rootRepo: "/r", title: "Fix", remote: "origin",
                                               viaBoard: true, push: true)
        #expect(p.contains("git fetch 'origin'"))
        #expect(p.contains("git pull --rebase 'origin' 'main'"))
        #expect(p.contains("git push 'origin' 'main'"))
        #expect(p.contains("Never force-push"))
        #expect(p.contains("'origin/main'"))
        let local = CodingTaskEngine.landingPrompt(mode: .merge, branch: "wt/fix", target: "main",
                                                   rootRepo: "/r", title: "Fix", remote: "origin", viaBoard: true)
        #expect(!local.contains("git push"))
        let sync = CodingTaskEngine.pushPrompt(branch: "wt/fix", target: "main", remote: "origin", viaBoard: false)
        #expect(sync.contains("git pull --rebase 'origin' 'main'") && sync.contains("git push 'origin' 'main'"))
        #expect(sync.contains("`deliver`"))
    }

    @Test("pushing the target after a local merge, against a real remote", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func pushLive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func sh(_ c: String) -> String {
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
        let r = dir.appendingPathComponent("work").path
        _ = sh("git init -q --bare -b main remote.git && git clone -q remote.git work 2>/dev/null; cd work "
               + "&& git checkout -q -b main && echo a > a && git add a && git commit -qm a && git push -q origin main "
               + "&& git branch wt/x && git checkout -q wt/x && echo b > b && git add b && git commit -qm b "
               + "&& git checkout -q main && git merge -q --ff-only wt/x")
        // Merged locally, not pushed yet: not landed on the remote.
        #expect(sh(CodingTaskEngine.landingVerifyCommand(root: r, branch: "wt/x", target: "main",
                                                         sourceDir: nil, remote: "origin")).contains("PENDING"))
        #expect(sh(CodingTaskEngine.pushTargetCommand(root: r, target: "main", remote: "origin"))
            .contains("pushed"))
        #expect(sh(CodingTaskEngine.landingVerifyCommand(root: r, branch: "wt/x", target: "main",
                                                         sourceDir: nil, remote: "origin")).contains("LANDED"))
        // Someone else pushed meanwhile: not a fast-forward — the agent's job.
        _ = sh("git clone -q remote.git other && cd other && echo c > c && git add c && git commit -qm c && git push -q origin main")
        _ = sh("cd work && echo d > d && git add d && git commit -qm d")
        #expect(sh(CodingTaskEngine.pushTargetCommand(root: r, target: "main", remote: "origin"))
            .contains("behind"))
    }

    @Test("the agent's latest message line is read off its pane")
    func agentLine() {
        let pane = "⏺ Rebasing onto main…\n  ⎿  ok\n⏺ Running the tests\n\n> \n"
        #expect(CodingTaskEngine.agentLine(fromPane: pane) == "Running the tests")
        #expect(CodingTaskEngine.agentLine(fromPane: "$ ls\n") == nil)
    }

    // MARK: board_report_landing

    @Test("board_report_landing outcomes: merged verified / unverified / not yet, blocked, pr_opened")
    func reportOutcomes() {
        #expect(LandingReportOutcome.decide(status: "merged", summary: "", prURL: nil, verified: true) == .finishVerified)
        #expect(LandingReportOutcome.decide(status: "merged", summary: "", prURL: nil, verified: nil) == .finishUnverified)
        #expect(LandingReportOutcome.decide(status: "merged", summary: "", prURL: nil, verified: false) == .notYet)
        #expect(LandingReportOutcome.decide(status: "blocked", summary: "tests fail", prURL: nil, verified: nil)
                == .blocked("tests fail"))
        #expect(LandingReportOutcome.decide(status: "pr_opened", summary: "see https://github.com/o/r/pull/7",
                                            prURL: nil, verified: nil) == .prOpened("https://github.com/o/r/pull/7"))
        if case .invalid = LandingReportOutcome.decide(status: "nope", summary: "", prURL: nil, verified: nil) {} else {
            Issue.record("an unknown status is refused")
        }
    }

    @Test("reports on the engine: blocked → needs you; pr_opened → Done with the URL; merged unverifiable → Done, not verified")
    func reportsOnEngine() async {
        let s = store()
        let engine = CodingTaskEngine(store: s, delegate: nil)
        var t = reviewTask(s)
        s.mutate(t.id) { $0.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date()) }
        let b = await engine.reportLanding(t.id, status: "blocked", summary: "main is dirty", prURL: nil)
        #expect(b.ok)
        #expect(s.task(t.id)?.landing?.phase == .needsYou)
        #expect(s.task(t.id)?.landing?.detail == "main is dirty")
        // No machine to look at (no delegate): recorded as reported.
        let m = await engine.reportLanding(t.id, status: "merged", summary: "in", prURL: nil)
        #expect(m.ok)
        #expect(s.task(t.id)?.stage == .done)
        #expect(s.task(t.id)?.completion == .merged(target: "main", verified: false, by: "Claude Code"))

        t = reviewTask(s, branch: "wt/pr")
        s.mutate(t.id) { $0.landing = TaskLanding(mode: .pr, target: "main", phase: .agentLanding, startedAt: Date()) }
        let p = await engine.reportLanding(t.id, status: "pr_opened", summary: "done",
                                           prURL: "https://github.com/o/r/pull/9")
        #expect(p.ok)
        let done = s.task(t.id)
        #expect(done?.stage == .done && done?.prOpened == true)
        #expect(done?.completion == .prOpened(url: "https://github.com/o/r/pull/9"))
        #expect(TaskLandingText.done(done!) == "PR #9 opened")
    }

    // MARK: Housekeeping

    @Test("Review sessions idle for over two hours are put away — not while landing or touched")
    func idleSweepSelection() {
        let now = Date()
        var idle = CodingTask(title: "a", profileID: UUID())
        idle.stage = .testing
        idle.testingAt = now.addingTimeInterval(-3 * 3600)
        idle.updatedAt = now.addingTimeInterval(-3 * 3600)
        var touched = idle
        touched.id = UUID()
        touched.updatedAt = now.addingTimeInterval(-600)
        var landing = idle
        landing.id = UUID()
        landing.landing = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: now)
        var parked = idle
        parked.id = UUID()
        parked.sessionParkedAt = now
        let picked = CodingTaskEngine.idleReviewTasks([idle, touched, landing, parked], now: now).map(\.id)
        #expect(picked == [idle.id])
    }

    @Test("Kimi's bucket name is the slug cut to 40 characters")
    func kimiSlug() {
        let slug = "add-a-multiply-function-to-calc-py-and-print-261004-0900"
        #expect(CodingTaskEngine.kimiSlug(slug) == "add-a-multiply-function-to-calc-py-and-p")
        #expect(CodingTaskEngine.kimiSlug("short-1") == "short-1")
        #expect(CodingTaskEngine.kimiSlug(String(repeating: "a", count: 39) + "-b") == String(repeating: "a", count: 39))
    }

    // MARK: Guest agent

    @Test("agentd refuses a merge into a branch that isn't checked out (no wrong-branch fallback)",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func agentdElsewhereGuard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", """
            cd '\(dir.path)' && git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a \
            && git branch other && cd '\(src.path)' && /usr/bin/python3 -c '
            import importlib.util, sys
            s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d, why = m._merge_target_dir(sys.argv[1], "other")
            print("other:", repr(d), "elsewhere" if "checked out" in why else why)
            d, why = m._merge_target_dir(sys.argv[1], "main")
            print("main:", d == sys.argv[1] or d.endswith(sys.argv[1].split("/")[-1]), repr(why))
            ' '\(dir.path)'
            """]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out.contains("other: '' elsewhere"), Comment(rawValue: out))
        #expect(out.contains("main: True ''"), Comment(rawValue: out))
    }
}

/// Finding: Merge & Push fed the raw remote name to `git push`, so a
/// remote named `--exec=./pwn.sh` ran that program.
@Suite("Landing: the remote is a name, never an option")
struct LandingRemoteNameTests {

    private func sh(_ cmd: String) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A repo with one commit on main whose remotes are `remotes` (all
    /// pointing at a bare repo next to it), and a pwn.sh that leaves a marker.
    private func repo(remotes: [String]) throws -> (root: String, marker: String) {
        let dir = "/tmp/bac-remote-\(UUID().uuidString.prefix(8))"
        let marker = dir + "/PWNED"
        var cmd = "set -e; mkdir -p \(dir); git init -q --bare \(dir)/bare.git; git init -q -b main \(dir)/w; cd \(dir)/w; "
            + "git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; "
            + "printf '#!/bin/sh\\ntouch \(marker)\\n' > pwn.sh; chmod +x pwn.sh; "
        for r in remotes { cmd += "git remote add -- \(CodingTaskEngine.shellQuote(r)) \(dir)/bare.git; " }
        _ = try sh(cmd)
        return (dir + "/w", marker)
    }

    @Test("only a plain token is a safe remote name")
    func safeNames() {
        for ok in ["origin", "upstream", "gitlab", "my-fork", "team/mirror", "a.b_c"] {
            #expect(CodingTaskEngine.isSafeRemoteName(ok), "\(ok)")
        }
        for bad in ["--exec=./pwn.sh", "--receive-pack=x", "-u", "origin;./pwn.sh", "a b", "..", "a/../b",
                    "a/", "", "$(id)", "`id`"] {
            #expect(!CodingTaskEngine.isSafeRemoteName(bad), "\(bad)")
        }
        #expect(CodingTaskEngine.pickRemote("--exec=./pwn.sh\nupstream\norigin\n") == "origin")
        #expect(CodingTaskEngine.pickRemote("--exec=./pwn.sh\nupstream\n") == "upstream")
        #expect(CodingTaskEngine.pickRemote("--exec=./pwn.sh\norigin;./pwn.sh\n") == nil)
    }

    @Test("the shell pick agrees, in a real repository listing an option first")
    func shellPick() throws {
        let a = try repo(remotes: ["--exec=./pwn.sh", "upstream", "origin"])
        #expect(try sh(CodingTaskEngine.pickRemoteShell(repo: CodingTaskEngine.shellQuote(a.root)))
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "origin")
        let b = try repo(remotes: ["--exec=./pwn.sh", "upstream"])
        #expect(try sh(CodingTaskEngine.pickRemoteShell(repo: CodingTaskEngine.shellQuote(b.root)))
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "upstream")
        let c = try repo(remotes: ["--exec=./pwn.sh"])
        #expect(try sh(CodingTaskEngine.pickRemoteShell(repo: CodingTaskEngine.shellQuote(c.root))).isEmpty)
    }

    @Test("pushing with an option-shaped remote runs nothing; a real remote still gets the push")
    func pushRunsNothing() throws {
        let r = try repo(remotes: ["--exec=./pwn.sh", "origin"])
        for bad in ["--exec=./pwn.sh", "--receive-pack=./pwn.sh"] {
            let out = try sh("cd \(r.root) && " + CodingTaskEngine.pushTargetCommand(root: r.root, target: "main", remote: bad))
            #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "push-failed")
            #expect(!FileManager.default.fileExists(atPath: r.marker))
            let verify = try sh("cd \(r.root) && " + CodingTaskEngine.landingVerifyCommand(
                root: r.root, branch: "main", target: "main", sourceDir: nil, remote: bad))
            #expect(verify.trimmingCharacters(in: .whitespacesAndNewlines) == "UNKNOWN")
            #expect(!FileManager.default.fileExists(atPath: r.marker))
        }
        let ok = try sh(CodingTaskEngine.pushTargetCommand(root: r.root, target: "main", remote: "origin"))
        #expect(ok.trimmingCharacters(in: .whitespacesAndNewlines) == "pushed")
    }

    @Test("the agent's briefs quote every name and never carry an unsafe remote")
    func briefsQuoted() {
        let push = CodingTaskEngine.pushPrompt(branch: "wt/x", target: "main", remote: "origin;./pwn.sh", viaBoard: false)
        #expect(!push.contains("pwn.sh"))
        #expect(push.contains("`git push 'origin' 'main'`"))
        let land = CodingTaskEngine.landingPrompt(mode: .squash, branch: "wt/x", target: "main", rootRepo: "/r",
                                                  title: "Fix: $(touch /tmp/p) \"q\"", remote: "--exec=./pwn.sh",
                                                  viaBoard: true, push: true)
        #expect(!land.contains("--exec"))
        #expect(land.contains("git commit -m 'Fix: $(touch /tmp/p) \"q\"'"))
        #expect(land.contains("`git merge --ff-only 'wt/x'`"))
    }
}
