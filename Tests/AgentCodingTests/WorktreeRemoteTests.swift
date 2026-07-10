import Foundation
import Testing
@testable import bromure_ac

// MARK: - SSH/remote worktree helpers
//
// The remote (RemoteMenu) worktree UI reconstructs the nesting tree and the
// branch slug from the automation API's tab dicts. These must match the GUI's
// logic so a worktree looks/merges the same over SSH as in the app.

@MainActor
@Suite("WorktreeRemote")
struct WorktreeRemoteTests {

    @Test("Slug is branch/dir-safe and matches the GUI shape")
    func slug() {
        #expect(RemoteMenuApp.slug("Website refactoring") == "website-refactoring")
        #expect(RemoteMenuApp.slug("Fix bug #123!!!") == "fix-bug-123")
        #expect(RemoteMenuApp.slug("  leading/trailing  ") == "leading-trailing")
        #expect(RemoteMenuApp.slug("$((id))") == "id")        // the injection-probe name
        #expect(RemoteMenuApp.slug("") == "worktree")          // never empty
        #expect(RemoteMenuApp.slug("!!!") == "worktree")       // all-punctuation → fallback
    }

    @Test("Nesting depth follows parentBranch up the tab chain")
    func depth() {
        // A three-level tree: root repo tab, worktree A off it, worktree B off A.
        let tabs: [[String: Any]] = [
            ["index": 0, "title": "claude", "isGitRepo": true],
            ["index": 1, "title": "A", "isWorktree": true,
             "worktreeBranch": "wt/a", "parentBranch": "main"],
            ["index": 2, "title": "B", "isWorktree": true,
             "worktreeBranch": "wt/b", "parentBranch": "wt/a"],
        ]
        #expect(RemoteMenuApp.worktreeDepth(tabs[0], in: tabs) == 0)  // ordinary tab
        #expect(RemoteMenuApp.worktreeDepth(tabs[1], in: tabs) == 1)  // off the repo root
        #expect(RemoteMenuApp.worktreeDepth(tabs[2], in: tabs) == 2)  // off worktree A
    }

    @Test("Attached terminal nests one step under its worktree")
    func attachedTerminalDepth() {
        // "Attach terminal" tabs carry parentBranch (the worktree they were
        // opened in) but no worktreeBranch — they indent one past the worktree.
        let tabs: [[String: Any]] = [
            ["index": 0, "title": "claude", "isGitRepo": true],
            ["index": 1, "title": "A", "isWorktree": true,
             "worktreeBranch": "wt/a", "parentBranch": "main"],
            ["index": 2, "title": "bash", "isGitRepo": true, "parentBranch": "wt/a"],
            ["index": 3, "title": "B", "isWorktree": true,
             "worktreeBranch": "wt/b", "parentBranch": "wt/a"],
            ["index": 4, "title": "htop", "isGitRepo": true, "parentBranch": "wt/b"],
        ]
        #expect(RemoteMenuApp.worktreeDepth(tabs[2], in: tabs) == 2)  // under A (depth 1)
        #expect(RemoteMenuApp.worktreeDepth(tabs[4], in: tabs) == 3)  // under B (depth 2)
        // An ordinary tab (no parentBranch) stays at the top level.
        #expect(RemoteMenuApp.worktreeDepth(tabs[0], in: tabs) == 0)
    }

    @Test("Depth is cycle-safe and capped")
    func depthGuarded() {
        // A pathological self/mutual parent cycle must not hang; cap at 6.
        let tabs: [[String: Any]] = [
            ["isWorktree": true, "worktreeBranch": "wt/x", "parentBranch": "wt/y"],
            ["isWorktree": true, "worktreeBranch": "wt/y", "parentBranch": "wt/x"],
        ]
        #expect(RemoteMenuApp.worktreeDepth(tabs[0], in: tabs) <= 6)
    }

    @Test("Display order pulls a late worktree under its repo tab")
    func orderedUnderRepoTab() {
        // tmux appends new windows last: repo tab, unrelated tab, THEN the
        // worktree. Display order must move the worktree under the repo tab.
        let tabs: [[String: Any]] = [
            ["index": 0, "title": "claude", "isGitRepo": true,
             "cwd": "/home/ubuntu/repo/sub", "repoRoot": "/home/ubuntu/repo"],
            ["index": 1, "title": "shell"],
            ["index": 2, "title": "A", "isWorktree": true,
             "worktreeBranch": "wt/a", "parentBranch": "main",
             "rootRepo": "/home/ubuntu/repo"],
        ]
        let ordered = RemoteMenuApp.worktreeOrdered(tabs).map { $0["index"] as? Int }
        #expect(ordered == [0, 2, 1])
    }

    @Test("Display order keeps whole subtrees together, cwd fallback works")
    func orderedSubtrees() {
        // No repoRoot on the repo tab (older app) → cwd prefix match. The
        // chain repo → A → terminal-under-A → B stays contiguous even though
        // the roster interleaves an unrelated tab.
        let tabs: [[String: Any]] = [
            ["index": 0, "title": "claude", "isGitRepo": true,
             "cwd": "/home/ubuntu/repo"],
            ["index": 1, "title": "other"],
            ["index": 2, "title": "A", "isWorktree": true,
             "worktreeBranch": "wt/a", "parentBranch": "main",
             "rootRepo": "/home/ubuntu/repo"],
            ["index": 3, "title": "bash", "isGitRepo": true, "parentBranch": "wt/a"],
            ["index": 4, "title": "B", "isWorktree": true,
             "worktreeBranch": "wt/b", "parentBranch": "wt/a",
             "rootRepo": "/home/ubuntu/repo"],
        ]
        let ordered = RemoteMenuApp.worktreeOrdered(tabs).map { $0["index"] as? Int }
        #expect(ordered == [0, 2, 3, 4, 1])
    }

    @Test("Display order is cycle-safe — every tab appears exactly once")
    func orderedGuarded() {
        let tabs: [[String: Any]] = [
            ["index": 0, "isWorktree": true, "worktreeBranch": "wt/x", "parentBranch": "wt/y"],
            ["index": 1, "isWorktree": true, "worktreeBranch": "wt/y", "parentBranch": "wt/x"],
            ["index": 2, "title": "plain"],
        ]
        let ordered = RemoteMenuApp.worktreeOrdered(tabs)
        #expect(ordered.count == 3)
        #expect(Set(ordered.compactMap { $0["index"] as? Int }) == [0, 1, 2])
    }
}
