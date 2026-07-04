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

    @Test("Depth is cycle-safe and capped")
    func depthGuarded() {
        // A pathological self/mutual parent cycle must not hang; cap at 6.
        let tabs: [[String: Any]] = [
            ["isWorktree": true, "worktreeBranch": "wt/x", "parentBranch": "wt/y"],
            ["isWorktree": true, "worktreeBranch": "wt/y", "parentBranch": "wt/x"],
        ]
        #expect(RemoteMenuApp.worktreeDepth(tabs[0], in: tabs) <= 6)
    }
}
