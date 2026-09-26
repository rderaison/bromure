import Foundation
import Testing
@testable import bromure_ac

// "New worktree…" on a session: the record is minted before the guest has
// made anything, so it launches from the PARENT's folder; the guest then
// picks the worktree's path (unique suffixes and all) and branch, and the
// tab binder must take both from the tab it binds.

@Suite("Worktree sessions")
@MainActor
struct WorktreeSessionTests {
    private func tempStore() -> AgentSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-wt-\(UUID().uuidString).json")
        return AgentSessionStore(fileURL: url)
    }

    @Test("binding a worktree launch adopts the tab's folder and branch")
    func bindAdoptsWorktreeTab() {
        let store = tempStore()
        let machine = UUID()
        var parent = AgentSession(profileID: machine, tool: .claude, title: "Login flow",
                                  cwd: "~/proj", windowIndex: 1)
        parent.lastSeenAt = Date()
        store.upsert(parent)

        var child = AgentSession(profileID: machine, tool: .codex, title: "Redirect fix",
                                 cwd: parent.cwd)
        child.worktreeOf = parent.id
        child.launchingSince = Date()
        child.launchBaselineIndex = 1
        child.launchDisplay = child.title
        store.upsert(child)

        // The guest opened the worktree's tab past the baseline, named as we
        // asked, checked out in its own folder on its own branch.
        let model = TabsModel()
        model.tabs = [
            TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"),
            TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/proj"),
            TabsModel.Tab(label: "codex", index: 2, cwd: "/home/ubuntu/.bromure/worktrees/proj/redirect-fix",
                          worktreeBranch: "wt/redirect-fix", parentBranch: "main",
                          rootRepo: "/home/ubuntu/proj", display: "Redirect fix"),
        ]
        model.rosterLive = true
        store.reconcile(entries: [SessionListModel.VMEntry(id: machine, name: "ws",
                                                            accentHex: "#000000", model: model)])

        let bound = store.session(child.id)
        #expect(bound?.windowIndex == 2)
        #expect(bound?.isLaunching == false)
        #expect(bound?.cwd == "/home/ubuntu/.bromure/worktrees/proj/redirect-fix")
        #expect(bound?.worktreeBranch == "wt/redirect-fix")
        #expect(bound?.worktreeOf == parent.id)
        // The parent is untouched, and no twin was minted for the new tab.
        #expect(store.session(parent.id)?.cwd == "~/proj")
        #expect(store.sessions.count == 2)
    }

    @Test("worktree slugs are branch- and folder-safe")
    func slugs() {
        #expect(AgentSessionEngine.worktreeSlug("Login redirect fix") == "login-redirect-fix")
        #expect(AgentSessionEngine.worktreeSlug("  Fix: the /api (v2) bug!  ") == "fix-the-api-v2-bug")
        #expect(AgentSessionEngine.worktreeSlug("***") == "worktree")
        #expect(AgentSessionEngine.worktreeSlug(String(repeating: "a", count: 60)).count == 40)
    }

    @Test("only a session with a folder of its own can branch")
    func hasFolder() {
        let m = UUID()
        #expect(!SessionHome.hasFolder(AgentSession(profileID: m, tool: .claude, title: "t", cwd: "~")))
        #expect(!SessionHome.hasFolder(AgentSession(profileID: m, tool: .claude, title: "t", cwd: "/home/ubuntu")))
        #expect(SessionHome.hasFolder(AgentSession(profileID: m, tool: .claude, title: "t", cwd: "~/proj")))
        #expect(SessionHome.hasFolder(AgentSession(profileID: m, tool: .claude, title: "t", cwd: "/tmp/x")))
    }

    // MARK: Branch sessions

    private func branch(_ info: BranchInfo?, merge: BranchMerge? = nil) -> AgentSession {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "Cache", cwd: "~/.bromure/worktrees/p/cache")
        s.worktreeBranch = "wt/cache"
        s.branchParent = "main"
        s.branchInfo = info
        s.branchMerge = merge
        return s
    }

    @Test("a branch says what it holds, in words")
    func branchSummary() {
        let d = Date()
        #expect(SessionHome.branchSummary(branch(nil)) == nil)
        #expect(SessionHome.branchSummary(branch(BranchInfo(ahead: 0, behind: 0, changed: 0, checkedAt: d))) == "no changes yet")
        #expect(SessionHome.branchSummary(branch(BranchInfo(ahead: 1, behind: 0, changed: 0, checkedAt: d))) == "1 commit")
        #expect(SessionHome.branchSummary(branch(BranchInfo(ahead: 3, behind: 2, changed: 5, checkedAt: d)))
                == "3 commits · 5 uncommitted files · 2 behind")
        // Behind only is still "nothing to lose".
        #expect(BranchInfo(ahead: 0, behind: 4, changed: 0, checkedAt: d).isEmpty)
    }

    @Test("archiving or deleting a branch asks, until it's merged")
    func branchNeedsWord() {
        let merged = BranchMerge(target: "main", squash: false, removeAfter: true, startedAt: Date(), phase: .merged)
        #expect(SessionHome.branchNeedsWord(branch(nil)))
        #expect(!SessionHome.branchNeedsWord(branch(nil, merge: merged)))
        var plain = branch(nil); plain.worktreeBranch = nil
        #expect(!SessionHome.branchNeedsWord(plain))
        #expect(SessionHome.mergeLine(branch(nil, merge: merged)) == "Merged into main")
    }

    @Test("a merge phase this build doesn't know decodes as stalled")
    func unknownMergePhase() throws {
        let json = #"{"target":"main","squash":false,"removeAfter":true,"startedAt":0,"phase":"rebasing"}"#
        let m = try JSONDecoder().decode(BranchMerge.self, from: Data(json.utf8))
        #expect(m.phase == .failed)
        let req = #"{"target":"main","squash":true,"removeAfter":true,"startedAt":0,"phase":"requested"}"#
        #expect(try JSONDecoder().decode(BranchMerge.self, from: Data(req.utf8)).phase == .requested)
    }

    @Test("a branch session nests under the session it came from")
    func branchNests() {
        let machine = UUID()
        let parent = AgentSession(profileID: machine, tool: .claude, title: "Main", cwd: "~/p")
        var child = AgentSession(profileID: machine, tool: .claude, title: "Try", cwd: "~/p")
        child.worktreeOf = parent.id
        let other = AgentSession(profileID: machine, tool: .claude, title: "Other", cwd: "~/q")
        let order = SessionSectionsView.nested([child, other, parent])
        #expect(order.map(\.session.id) == [other.id, parent.id, child.id])
        #expect(order.last?.depth == 1)
        #expect(AgentSession.origin(of: child) == parent.id)
    }

    @Test("the slug lives on the session, for the sheet's branch preview")
    func slugOnSession() {
        #expect(AgentSession.worktreeSlug("Try SQLite for the cache") == "try-sqlite-for-the-cache")
        #expect(AgentSessionEngine.worktreeSlug("Try SQLite") == AgentSession.worktreeSlug("Try SQLite"))
    }
}
