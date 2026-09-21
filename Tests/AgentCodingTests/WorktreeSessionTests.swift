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
}
