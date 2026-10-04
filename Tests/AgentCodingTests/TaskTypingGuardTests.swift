import Foundation
import Testing
@testable import bromure_ac

// Host → tmux typing never lands in the wrong tab or a bare shell: the
// target is resolved in the guest to a stable window id at send time, its
// markers (@worktree / @display / the id) must still name the intended task
// or session, and an AGENT must hold the pane's foreground. A task's resume
// brief was once typed into another task's bash prompt at a reused index.

@Suite("Guarded host typing: window identity and foreground agent")
struct TaskTypingGuardTests {

    // MARK: Command construction

    @Test("A task's tab is targeted by its @worktree, resolved to a window id; never by index")
    func taskTargetCommand() {
        let cmd = CodingTaskEngine.typeCommand(target: .task(branch: "wt/fix-login-261004-1352"),
                                               text: "hello `rm -rf /`")
        #expect(cmd.contains("list-windows -t bromure -F '#{window_id} #{@worktree}'"))
        #expect(cmd.contains("awk -v b='wt/fix-login-261004-1352'"))
        // Every send goes to the resolved id, literally (`-l --`).
        #expect(cmd.contains("tmux send-keys -t \"$_bt\" -l --"))
        #expect(cmd.contains("tmux send-keys -t \"$_bt\" Enter"))
        #expect(!cmd.contains("bromure:"))
        // The text only ever travels base64: no backtick reaches a shell.
        #expect(!cmd.contains("`rm"))
        // Identity re-checked: the window's @worktree must still be the task's.
        #expect(cmd.contains("'#{@worktree}'"))
        // And the foreground must be an agent.
        #expect(cmd.contains("-o tty= -o tpgid= -o pgid= -o args="))
        #expect(cmd.contains("\(PaneTypeGuard.refusedMarker) shell"))
        // Checked before the text AND again before Enter.
        #expect(cmd.components(separatedBy: "if _bg; then").count - 1 == 2)
    }

    @Test("An index target is resolved once to its window id; a stamped id is checked")
    func indexAndWindowIDTargets() {
        let byIndex = CodingTaskEngine.guardedTypeCommand(tabIndex: 3, text: "x")
        #expect(byIndex.hasPrefix("_bt=$(tmux display-message -p -t bromure:3 '#{window_id}'"))
        #expect(byIndex.components(separatedBy: "bromure:3").count - 1 == 1)
        let t = PaneTarget(ref: .windowID("@12"), expectDisplay: "Fix it", expectWindowID: "@12")
        let byID = CodingTaskEngine.guardedTypeCommand(target: t, text: "x")
        #expect(byID.contains("display-message -p -t '@12' '#{window_id}'"))
        #expect(byID.contains("[ \"$_bt\" = '@12' ]"))
        #expect(byID.contains("'#{@display}'") && byID.contains("'Fix it'"))
        // A bogus id is never interpolated.
        let bad = PaneTypeGuard.resolve(PaneTarget(ref: .windowID("@1; rm -rf ~")))
        #expect(!bad.contains("rm -rf"))
    }

    @Test("A relaunch command line wants a SHELL in front, not an agent")
    func shellLineGuard() {
        let cmd = CodingTaskEngine.shellLineCommand(target: .index(2), line: "kimi -S abc")
        #expect(cmd.contains("\(PaneTypeGuard.refusedMarker) agent"))
        #expect(!cmd.contains("\(PaneTypeGuard.refusedMarker) shell"))
    }

    @Test("Refusals are read back off the output")
    func refusalParse() {
        #expect(PaneTypeGuard.refusal(in: "\(PaneTypeGuard.refusedMarker) shell\n") == .shell)
        #expect(PaneTypeGuard.refusal(in: "noise\n\(PaneTypeGuard.refusedMarker) identity") == .identity)
        #expect(PaneTypeGuard.refusal(in: "\(PaneTypeGuard.refusedMarker) gone") == .gone)
        #expect(PaneTypeGuard.refusal(in: "") == nil)
        #expect(PaneTypeGuard.refusal(in: CodingTaskEngine.typeHeldMarker) == nil)
        #expect(PaneTypeGuard.isWindowID("@7") && !PaneTypeGuard.isWindowID("7") && !PaneTypeGuard.isWindowID("@"))
    }

    // MARK: Against a real tmux

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
         NSHomeDirectory() + "/Library/Application Support/BromureSidecar/bin/tmux",
         NSHomeDirectory() + "/Library/Application Support/BromureNative/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func sh(_ command: String, env: [String: String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var e = ProcessInfo.processInfo.environment
        e.removeValue(forKey: "TMUX")
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("Live tmux: agent in front → typed; shell in front, wrong marker, reused index → refused, nothing typed")
    func liveDecisions() throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }

        // Window 0: an "agent" (a process named claude) on task A's branch.
        // Window 1: a bare shell on task B's branch (its agent died).
        Self.sh("tmux new-session -d -s bromure -x 120 -y 20 \"bash -c 'exec -a claude cat'\" "
                + "&& tmux set-option -w -t bromure:0 @worktree wt/task-a "
                + "&& tmux new-window -t bromure:1 '/bin/sh' "
                + "&& tmux set-option -w -t bromure:1 @worktree wt/task-b", env: env)
        Thread.sleep(forTimeInterval: 0.6)
        func pane(_ i: Int) -> String { Self.sh("tmux capture-pane -p -t bromure:\(i)", env: env) }

        // Agent in front, right marker: typed (cat echoes it, then again on Enter).
        let ok = Self.sh(CodingTaskEngine.guardedTypeCommand(target: .task(branch: "wt/task-a"),
                                                             text: "brief for A"), env: env)
        #expect(PaneTypeGuard.refusal(in: ok) == nil)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(pane(0).components(separatedBy: "brief for A").count - 1 == 2)

        // Shell in front: refused, the brief never reaches the prompt.
        let brief = "This session was RESTARTED — run `git status`"
        let shell = Self.sh(CodingTaskEngine.guardedTypeCommand(target: .task(branch: "wt/task-b"),
                                                                text: brief), env: env)
        #expect(PaneTypeGuard.refusal(in: shell) == .shell)
        #expect(!pane(1).contains("RESTARTED"))
        // The unguarded-looking API is guarded too.
        let plain = Self.sh(CodingTaskEngine.typeCommand(tabIndex: 1, text: brief), env: env)
        #expect(PaneTypeGuard.refusal(in: plain) == .shell)
        #expect(!pane(1).contains("RESTARTED"))

        // The intended task's marker isn't on the window at that index.
        var wrong = PaneTarget.index(0)
        wrong.expectWorktree = "wt/task-b"
        let mismatch = Self.sh(CodingTaskEngine.guardedTypeCommand(target: wrong, text: "for B"), env: env)
        #expect(PaneTypeGuard.refusal(in: mismatch) == .identity)
        #expect(!pane(0).contains("for B"))

        // A stamped window id, then the tab closes and another opens at the
        // same index: the newcomer is refused.
        let oldID = Self.sh("tmux display-message -p -t bromure:0 '#{window_id}'", env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Self.sh("tmux kill-window -t bromure:0 && tmux new-window -t bromure:0 \"bash -c 'exec -a kimi cat'\"", env: env)
        Thread.sleep(forTimeInterval: 0.5)
        let stale = PaneTarget(ref: .windowID(oldID))
        #expect(PaneTypeGuard.refusal(in: Self.sh(
            CodingTaskEngine.guardedTypeCommand(target: stale, text: "late"), env: env)) == .gone)
        let pinned = PaneTarget(ref: .index(0), expectWindowID: oldID)
        #expect(PaneTypeGuard.refusal(in: Self.sh(
            CodingTaskEngine.guardedTypeCommand(target: pinned, text: "late"), env: env)) == .identity)
        #expect(!pane(0).contains("late"))
        // Gone altogether.
        #expect(PaneTypeGuard.refusal(in: Self.sh(
            CodingTaskEngine.guardedTypeCommand(target: .task(branch: "wt/nobody"), text: "x"), env: env)) == .gone)
    }

    // MARK: Archived sessions vs. a task's relaunched tab

    @Test("Reap decision: only a provably-own tab is ended; a newcomer at the index is let go")
    func archivedVerdict() {
        func v(boot: String? = "b1", probeBoot: String? = "b1", wid: String? = "@4", probeWid: String? = "@4",
               display: String? = "Task", tabDisplay: String? = "Task", owned: Bool = false)
            -> AgentSessionEngine.ArchivedTabVerdict {
            AgentSessionEngine.archivedTabVerdict(sessionBoot: boot, probeBoot: probeBoot,
                                                  sessionWindowID: wid, probeWindowID: probeWid,
                                                  sessionDisplay: display, tabDisplay: tabDisplay,
                                                  taskOwned: owned)
        }
        #expect(v() == .end)
        // Stop & Return to Backlog then Start: same index, same title, new window.
        #expect(v(probeWid: "@9") == .unbind)
        #expect(v(owned: true) == .unbind)
        #expect(v(wid: nil) == .unbind)
        #expect(v(boot: "b0") == .unbind)
        #expect(v(tabDisplay: "Other") == .unbind)
        #expect(v(probeBoot: nil) == .wait)
        #expect(v(probeWid: nil) == .wait)
    }

    @Test("A live task owns its tab by branch; a done or stopped one doesn't")
    func taskOwnership() {
        let ws = UUID()
        var live = CodingTask(title: "A", profileID: ws, tool: .kimi)
        live.stage = .inProgress
        live.branch = "wt/a-261004-1352"
        var done = CodingTask(title: "B", profileID: ws, tool: .kimi)
        done.stage = .done
        done.branch = "wt/b-261004-1352"
        var stopped = CodingTask(title: "C", profileID: ws, tool: .kimi)
        stopped.resumeBranch = "wt/c-261004-1352"
        let all = [live, done, stopped]
        #expect(CodingTaskEngine.taskOwnsTab(all, profileID: ws, branch: "wt/a-261004-1352"))
        #expect(!CodingTaskEngine.taskOwnsTab(all, profileID: UUID(), branch: "wt/a-261004-1352"))
        #expect(!CodingTaskEngine.taskOwnsTab(all, profileID: ws, branch: "wt/b-261004-1352"))
        #expect(!CodingTaskEngine.taskOwnsTab(all, profileID: ws, branch: "wt/c-261004-1352"))
    }

    @Test("Probe window ids: stamped once, a different id unbinds; archived ones are never stamped")
    @MainActor
    func windowIDBinding() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString).json")
        let store = AgentSessionStore(fileURL: url)
        let ws = UUID()
        let live = AgentSession(profileID: ws, tool: .claude, title: "Live", windowIndex: 2)
        store.upsert(live)
        #expect(store.checkWindow(live.id, windowID: "@5"))
        #expect(store.session(live.id)?.windowID == "@5")
        #expect(store.checkWindow(live.id, windowID: "@5"))
        #expect(!store.checkWindow(live.id, windowID: "@8"))
        #expect(store.session(live.id)?.windowIndex == nil)
        #expect(store.session(live.id)?.windowID == nil)

        var archived = AgentSession(profileID: ws, tool: .kimi, title: "Task", windowIndex: 3)
        archived.archivedAt = Date()
        store.upsert(archived)
        #expect(!store.checkWindow(archived.id, windowID: "@9"))
        #expect(store.session(archived.id)?.windowID == nil)
        #expect(store.session(archived.id)?.windowIndex == 3)
        // The live session at an index wins over an archived one still holding it.
        let newcomer = AgentSession(profileID: ws, tool: .kimi, title: "Task", windowIndex: 3)
        store.upsert(newcomer)
        #expect(store.session(profileID: ws, windowIndex: 3)?.id == newcomer.id)
        // Rebinding forgets the old window's id.
        store.mutate(newcomer.id) { $0.windowID = "@3" }
        store.mutate(newcomer.id) { $0.windowIndex = 4 }
        #expect(store.session(newcomer.id)?.windowID == nil)
    }

    @Test("The liveness probe carries each window's id")
    @MainActor
    func probeWindowIDs() {
        let cmd = AgentSessionEngine.probeCommand(window: "")
        #expect(cmd.contains("#{window_id}"))
        let out = "boot\tb1\nwin\t0\t@3\n0\tclaude\t\tTitle\nwin\t2\t@11\n2\tnone\t\t\n"
        #expect(AgentSessionEngine.parseWindowIDs(out) == [0: "@3", 2: "@11"])
        #expect(AgentSessionEngine.parseProbe(out).map(\.index) == [0, 2])
    }

    @Test("A launch that died reads as needing the user, not Paused")
    @MainActor
    func failedStartBucket() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "QA")
        s.endedAt = Date()
        s.lastError = "Kimi exited right after it started (status 127)"
        let model = SessionListModel()
        #expect(SessionHome.bucket(for: s, in: model) == .needsYou)
        s.lastError = nil
        #expect(SessionHome.bucket(for: s, in: model) == .ended)
    }
}
