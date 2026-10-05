import Foundation
import Testing
@testable import bromure_ac

// `guardedTypeCommand` against a real tmux: a private server (its own socket
// dir), a "bromure" session whose window 0 shows a picker and window 1 a bare
// prompt. Skipped when tmux isn't installed.

@Suite("Guarded typing into agent tabs")
struct GuardedTypeTests {

    private static func tmuxPath() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
                          NSHomeDirectory() + "/Library/Application Support/BromureSidecar/bin/tmux",
                          NSHomeDirectory() + "/Library/Application Support/BromureNative/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    @Test("holds while a picker is open; types and presses Enter at a bare prompt")
    func holdsOnMenus() throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }

        // Both windows run an "agent" (a process named claude): the typing
        // guard types only into an agent's foreground.
        let picker = "printf 'Try auto mode?\\n\\n❯ 1. Yes, set it up\\n  2. Not now\\n\\nEnter to confirm · Esc to cancel\\n'; exec -a claude cat"
        Self.sh("tmux new-session -d -s bromure -x 100 -y 20 \"bash -c \\\"\(picker)\\\"\" "
                + "&& tmux new-window -t bromure:1 \"bash -c 'exec -a claude cat'\"", env: env)
        Thread.sleep(forTimeInterval: 0.5)

        let text = "[Delegation notice] @peer asks: 1. hello"
        let held = Self.sh(CodingTaskEngine.guardedTypeCommand(tabIndex: 0, text: text), env: env)
        #expect(held.contains(CodingTaskEngine.typeHeldMarker))
        #expect(!Self.sh("tmux capture-pane -p -t bromure:0", env: env).contains("Delegation notice"))

        let typed = Self.sh(CodingTaskEngine.guardedTypeCommand(tabIndex: 1, text: text), env: env)
        #expect(!typed.contains(CodingTaskEngine.typeHeldMarker))
        Thread.sleep(forTimeInterval: 0.3)
        // cat echoes the line once as typed and once more after Enter.
        let pane = Self.sh("tmux capture-pane -p -t bromure:1", env: env)
        #expect(pane.components(separatedBy: "Delegation notice").count - 1 == 2)
    }

    @Test("picker keys and chat keys go only to the window they're for")
    func keysFollowIdentity() throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }
        // Two "agents" with a picker footer on screen, tagged like two sessions.
        let picker = "printf 'Pick one\\n❯ 1. Yes\\n  2. No\\nEnter to select\\n'; exec -a claude cat"
        Self.sh("tmux new-session -d -s bromure -x 100 -y 20 \"bash -c \\\"\(picker)\\\"\" "
                + "&& tmux new-window -t bromure:1 \"bash -c \\\"\(picker)\\\"\" "
                + "&& tmux set-option -w -t bromure:0 @display K1 "
                + "&& tmux set-option -w -t bromure:1 @display K2", env: env)
        Thread.sleep(forTimeInterval: 0.5)
        let id1 = Self.sh("tmux display-message -p -t bromure:1 '#{window_id}'", env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Meant for K1 (window 0) by name, but aimed at index 1 (K2 took it): refused.
        let wrong = PaneTarget.chat(window: 1, windowID: nil, display: "K1", worktree: nil)
        let out = Self.sh(PaneTypeGuard.answerKeysCommand(target: wrong, keys: ["2"]), env: env)
        #expect(out.contains(PaneTypeGuard.refusedMarker + " identity"))
        let keysOut = Self.sh(PaneTypeGuard.keysCommand(target: wrong, keys: ["x"]), env: env)
        #expect(keysOut.contains(PaneTypeGuard.refusedMarker))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(Self.sh("tmux capture-pane -p -t bromure:1", env: env).components(separatedBy: "\n")
            .filter { ["2", "x"].contains($0.trimmingCharacters(in: .whitespaces)) }.isEmpty)

        // K2's own id and name: the digit goes in.
        let right = PaneTarget.chat(window: 1, windowID: id1, display: "K2", worktree: nil)
        let ok = Self.sh(PaneTypeGuard.answerKeysCommand(target: right, keys: ["2"]), env: env)
        #expect(!ok.contains(PaneTypeGuard.refusedMarker))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(Self.sh("tmux capture-pane -p -t bromure:1", env: env).components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "2" })
    }

    // MARK: J1 — the composer never types into an approval picker

    static let kimiApproval = """
      ▶ Run this command?
      cwd: /home/ubuntu/qa
      $ sleep 90
      ▶ 1. Approve once
        2. Approve for this session
        3. Reject
        4. Reject with feedback
      ↑/↓ select · 1/2/3/4 choose · ↵ confirm
    """
    static let claudePermission = """
     Bash command
       sleep 90
       Run sleep
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for sleep commands in /home/ubuntu/qa
       3. No, and tell Claude what to do differently (esc)
    """

    @Test("Host-side menu check: Kimi's and Claude's approval dialogs are open menus; a reply isn't")
    func hostMenuCheck() {
        #expect(AgentPhrases.menuOpen(Self.kimiApproval))
        #expect(AgentPhrases.menuOpen(Self.claudePermission))
        #expect(!AgentPhrases.menuOpen("● Done. Steps:\n  1. Install\n  2. Run\n\n❯ \n"))
    }

    @Test("Every agent-bound type command (the composer's too) holds on a menu, in the same guest command")
    func composerCommandIsMenuGuarded() {
        let t = PaneTarget.chat(window: 2, windowID: "@4", display: "QH1", worktree: nil)
        let cmd = CodingTaskEngine.typeCommand(target: t, text: "QH1-Q2: hi")
        #expect(cmd.contains("_bm()"))
        #expect(cmd.contains(PaneTypeGuard.heldMarker))
        // Checked before the text and again before the Enter.
        #expect(cmd.components(separatedBy: "if _bm; then").count - 1 == 2)
        // A relaunch command line (a shell in front) isn't.
        #expect(!CodingTaskEngine.shellLineCommand(target: .index(2), line: "kimi").contains("_bm()"))
    }

    @Test("Live tmux: a composer send into Kimi's picker or Claude's permission dialog types nothing")
    func composerRefusesPickers() throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }
        // Each window: the dialog's text on screen, then an "agent" (cat
        // under the agent's name) that would echo anything typed.
        func file(_ name: String, _ text: String) -> String {
            let url = dir.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let kimi = file("kimi.txt", Self.kimiApproval)
        let claude = file("claude.txt", Self.claudePermission)
        Self.sh("tmux new-session -d -s bromure -x 120 -y 30 \"bash -c 'cat \(kimi); exec -a kimi cat'\" "
                + "&& tmux new-window -t bromure:1 \"bash -c 'cat \(claude); exec -a claude cat'\"", env: env)
        Thread.sleep(forTimeInterval: 0.6)
        func pane(_ i: Int) -> String { Self.sh("tmux capture-pane -p -t bromure:\(i)", env: env) }

        for (w, text) in [(0, "QH1-Q2: after counting, reply QUEUED-ONE-OK"), (1, "1")] {
            let out = Self.sh(CodingTaskEngine.typeCommand(target: .index(w), text: text), env: env)
            #expect(PaneTypeGuard.held(in: out))
            #expect(PaneTypeGuard.refusal(in: out) == nil)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!pane(0).contains("QH1-Q2"))
        // Nothing reached Claude's dialog: not even the lone digit.
        #expect(!pane(1).components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "1" })

        // The dialog closes (the screen clears): the same send goes in.
        Self.sh("tmux send-keys -t bromure:0 C-l && tmux clear-history -t bromure:0", env: env)
        Self.sh("tmux kill-window -t bromure:0 && tmux new-window -t bromure:0 \"bash -c 'exec -a kimi cat'\"", env: env)
        Thread.sleep(forTimeInterval: 0.5)
        let ok = Self.sh(CodingTaskEngine.typeCommand(target: .index(0), text: "QH1-Q2: hi"), env: env)
        #expect(!PaneTypeGuard.held(in: ok))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(pane(0).contains("QH1-Q2: hi"))
    }

    // MARK: P2 — a message arrives whole: one paste, any size, CRLF or not

    @Test("Large text is staged in pieces under the argv cap; the type pastes it from the file")
    func stagingPlan() {
        let big = String(repeating: "abcdefghi\n", count: 20_000)   // 200 KB
        #expect(PaneTypeGuard.needsStaging(big))
        #expect(!PaneTypeGuard.needsStaging("short"))
        let path = PaneTypeGuard.newStagePath()
        let steps = PaneTypeGuard.stageCommands(big, path: path)
        #expect(steps.count > 2)
        #expect(steps.allSatisfy { $0.utf8.count < 100_000 })
        let cmd = PaneTypeGuard.typeCommand(target: .index(1), text: big, staged: path)
        #expect(cmd.utf8.count < 20_000)
        #expect(cmd.contains("paste-buffer -p -r -d"))
        #expect(cmd.contains("rm -f '\(path)'"))
        #expect(!cmd.contains("send-keys -t \"$_bt\" -l"))
        // A path that isn't ours is never interpolated.
        #expect(PaneTypeGuard.stageCommands("x", path: "/tmp/x; rm -rf ~").isEmpty)
    }

    @Test("Outcome: only the success marker is 'typed'; a type that ran and failed is a failure")
    @MainActor
    func outcomeParse() {
        #expect(ChatQueueStore.Outcome.of(PaneTypeGuard.typedMarker + "\n") == .typed)
        #expect(ChatQueueStore.Outcome.of("") == .failed)
        #expect(ChatQueueStore.Outcome.of("command too long\n") == .failed)
        #expect(ChatQueueStore.Outcome.of(nil) == .unreachable)
        #expect(ChatQueueStore.Outcome.of(PaneTypeGuard.heldMarker) == .held)
        #expect(ChatQueueStore.Outcome.of(PaneTypeGuard.refusedMarker + " shell") == .refused(.shell))
    }

    @Test("Live tmux: CRLF text is one message; 20 KB and 200 KB arrive byte for byte")
    func pasteWhole() async throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }
        let out = dir.appendingPathComponent("out")
        // The "agent": raw mode, no echo, every byte it gets into a file.
        let agent = "bash -c 'stty raw -echo; exec -a kimi cat > \(out.path)'"
        Self.sh("tmux new-session -d -s bromure -x 120 -y 30 \"\(agent)\"", env: env)
        Thread.sleep(forTimeInterval: 0.6)

        let crlf = "first line\r\nsecond line\r\nthird é 😀"
        let mid = String((0..<2_100).map { _ in "abcdefghi\n" }.joined().prefix(20_000))
        let huge = String(repeating: "0123456789abcdef é\r\n", count: 10_000)   // ~210 KB, CRLF
        for text in [crlf, mid, huge] {
            try? Data().write(to: out)
            Self.sh("tmux respawn-pane -k -t bromure:0 \"\(agent)\"", env: env)
            Thread.sleep(forTimeInterval: 0.5)
            let res = await PaneTypeGuard.runType(target: .index(0), text: text) { Self.sh($0, env: env) }
            #expect(res.map(PaneTypeGuard.typed(in:)) == true)
            var got = Data()
            for _ in 0..<50 {
                Thread.sleep(forTimeInterval: 0.1)
                got = (try? Data(contentsOf: out)) ?? Data()
                if got.last == 0x0D { break }
            }
            let want = Data(PaneTypeGuard.normalizedText(text).utf8) + Data([0x0D])
            #expect(got.count == want.count)
            #expect(got == want)
            // One message: the only Return is the final one.
            #expect(got.filter { $0 == 0x0D }.count == 1)
        }
        // No staged file left behind.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp"))?
            .filter { $0.hasPrefix("bromure-msg-") } ?? []
        #expect(left.isEmpty)
    }

    @Test("Live tmux: a type command that fails (no such server) is a failure, not a success")
    func failingTypeIsNotSuccess() async throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin"]
        let res = await PaneTypeGuard.runType(target: .index(0), text: "hello") { Self.sh($0, env: env) }
        #expect(ChatQueueStore.Outcome.of(res) != .typed)
    }
}
