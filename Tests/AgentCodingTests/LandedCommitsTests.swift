import Foundation
import Testing
@testable import bromure_ac

/// The commit trigger listed every commit reachable from the branch tip, so
/// merging a feature branch into main fired one review per commit of the
/// branch — reporting bugs a later commit of that branch had already fixed,
/// which never reached main. It now walks main's first-parent chain: a
/// merged branch is one landing, its merge, reviewed against main before it.
@Suite("Commit trigger: what landed on the branch")
struct LandedCommitsTests {
    /// A throwaway repository; `git` runs in it.
    private final class Repo {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("landed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "T")
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func git(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = root
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func commit(_ file: String, _ msg: String) -> String {
            let url = root.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data(msg.utf8).write(to: url)
            git("add", "-A")
            git("commit", "-q", "-m", msg)
            return git("rev-parse", "HEAD")
        }

        /// What GitHub's commit listing gives for one commit.
        func lookup(_ sha: String) -> GitHubPRPoller.BranchCommit {
            let f = git("log", "-1", "--format=%H%n%P%n%s", sha).components(separatedBy: "\n")
            return GitHubPRPoller.BranchCommit(
                sha: f[0], parents: f[1].split(separator: " ").map(String.init),
                message: f[2], author: "T", url: "", date: Date())
        }
    }

    @Test("a merged four-commit branch lands once, as its merge, whose diff is the branch")
    func mergeLandsOnce() async throws {
        let r = try Repo()
        let a0 = r.commit("app/main.c", "a0")
        r.git("checkout", "-q", "-b", "feature")
        let branch = [r.commit("app/x.c", "b0 adds a bug"), r.commit("app/x.c", "b1"),
                      r.commit("app/x.c", "b2 fixes b0's bug"), r.commit("app/y.c", "b3")]
        r.git("checkout", "-q", "main")
        r.git("merge", "-q", "--no-ff", "-m", "Merge feature", "feature")
        let a1 = r.git("rev-parse", "HEAD")

        var looked: [String] = []
        let landed = try await GitHubPRPoller.landedCommits(head: a1, since: a0) { sha in
            looked.append(sha); return r.lookup(sha)
        }
        #expect(landed.commits.map(\.sha) == [a1] && landed.reached)
        #expect(Set(looked).isDisjoint(with: branch))   // never even read
        // What the review reads: main before → main after, the whole branch.
        #expect(r.git("diff", "--name-only", "\(a1)^1", a1) == "app/x.c\napp/y.c")
    }

    @Test("commits made on the branch itself each land, oldest first")
    func directCommitsLand() async throws {
        let r = try Repo()
        let a0 = r.commit("a", "a0")
        let c1 = r.commit("a", "c1"), c2 = r.commit("b", "c2")
        let landed = try await GitHubPRPoller.landedCommits(head: c2, since: a0) { r.lookup($0) }.commits
        #expect(landed.map(\.sha) == [c1, c2])
        #expect(landed.map(\.item.identifier) == [String(c1.prefix(7)), String(c2.prefix(7))])
    }

    @Test("a first walk stops at the limit, or at the root")
    func firstWalk() async throws {
        let r = try Repo()
        let shas = (0..<5).map { r.commit("f", "c\($0)") }
        let two = try await GitHubPRPoller.landedCommits(head: shas[4], since: nil, limit: 2) { r.lookup($0) }
        #expect(two.commits.map(\.sha) == [shas[3], shas[4]] && !two.reached)
        let all = try await GitHubPRPoller.landedCommits(head: shas[4], since: nil, limit: 30) { r.lookup($0) }
        #expect(all.commits.map(\.sha) == shas && !all.reached)
        let none = try await GitHubPRPoller.landedCommits(head: shas[4], since: shas[4]) { r.lookup($0) }
        #expect(none.commits.isEmpty && none.reached)
    }

    @Test("a known tip is walked back to however far it is; a lost one is not reached")
    func longGapAndRewrite() async throws {
        let r = try Repo()
        let tip = r.commit("f", "tip")
        let after = (0..<35).map { r.commit("f", "c\($0)") }
        let gap = try await GitHubPRPoller.landedCommits(
            head: after.last!, since: tip, limit: GitHubPRPoller.landedCommitSearch) { r.lookup($0) }
        #expect(gap.commits.map(\.sha) == after && gap.reached)   // all 35, none skipped
        let lost = try await GitHubPRPoller.landedCommits(
            head: after.last!, since: "0000000000000000000000000000000000000000",
            limit: GitHubPRPoller.landedCommitSearch) { r.lookup($0) }
        #expect(!lost.reached)   // walked to the root: the history was rewritten
    }

    @Test("an upgraded poll walks back to the newest commit it fired")
    func upgradeStopsAtKnown() async throws {
        let r = try Repo()
        _ = r.commit("f", "old")
        let fired = r.commit("f", "fired by the old listing")
        let new1 = r.commit("f", "landed since"), new2 = r.commit("f", "and this")
        let walk = try await GitHubPRPoller.landedCommits(
            head: new2, since: nil, isKnown: { $0 == fired }) { r.lookup($0) }
        #expect(walk.commits.map(\.sha) == [new1, new2])
        // The tip it takes from then on: where it stopped — the next poll
        // walks from there like any other, not as an upgrade again.
        #expect(walk.commits.first?.parents.first == fired)
        // …and leaves out a merge whose branch the old listing reviewed
        // commit by commit (it fired for the branch's tip), not one it didn't.
        var merge = landed("m"); merge.mergedTip = "b3"
        #expect(merge.reviewedBefore { $0 == "b3" })
        #expect(!merge.reviewedBefore { $0 == "other" })
        #expect(!landed("c").reviewedBefore { _ in true })
    }

    private func landed(_ sha: String, touches: Bool = true) -> GitHubPRPoller.LandedCommit {
        .init(sha: sha, item: TriggerItem(number: 0, title: sha, url: "", branch: "main", author: "",
                                          body: "", createdAt: Date(), identifier: sha),
              touchesSubfolder: touches)
    }

    @Test("the tip settles past handled commits, never past one still to fire")
    func settledTip() {
        let commits = [landed("c1"), landed("c2", touches: false), landed("c3"), landed("c4")]
        let handled: Set<String> = ["c1"]
        let tip = GitHubPRPoller.settledTip(after: commits, from: "a0") { c in
            !c.touchesSubfolder || handled.contains(c.sha)
        }
        #expect(tip == "c2")   // c3 is waiting for a run slot, or its launch failed
        #expect(GitHubPRPoller.settledTip(after: commits, from: "a0") { _ in true } == "c4")
        #expect(GitHubPRPoller.settledTip(after: [], from: "a0") { _ in true } == "a0")
    }

    @Test("a change touches a subfolder by its paths, a capped list always")
    func touchesSubfolder() {
        #expect(GitHubPRPoller.touches(["src/a.c"], subfolder: "src", listCapped: false))
        #expect(GitHubPRPoller.touches(["src/a.c"], subfolder: "/src/", listCapped: false))
        #expect(!GitHubPRPoller.touches(["srcx/a.c", "docs/src"], subfolder: "src", listCapped: false))
        #expect(GitHubPRPoller.touches(["docs/a"], subfolder: "src", listCapped: true))
        #expect(GitHubPRPoller.touches([], subfolder: "", listCapped: false))
    }

    @Test("the reviews read what landed, a merge as one change")
    func prompts() {
        let w = WatchedRepo(repo: "acme/api", profileID: UUID(), commitBranch: "main")
        let commit = RepoWatchPrompts.commitScan(w)
        #expect(commit.contains("git diff {{commit.key}}^1 {{commit.key}}"))
        #expect(!commit.contains("git show"))
        let range = RepoWatchPrompts.scheduledReview(w, plan: .range(base: "aaa", head: "bbb"), tool: .claude)
        #expect(range.contains("git log --oneline --first-parent aaa..bbb"))
        #expect(range.contains("git diff aaa..bbb"))
        #expect(!range.contains("commit by commit"))
        let recent = RepoWatchPrompts.scheduledReview(w, plan: .recent(count: 20, head: nil), tool: .claude)
        #expect(recent.contains("git log --oneline --first-parent -20 origin/main"))
        #expect(!recent.contains("commit by commit"))
    }
}
