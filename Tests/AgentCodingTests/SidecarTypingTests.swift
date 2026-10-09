import Foundation
import Testing
@testable import bromure_ac

// The chat's typing scripts as a Bromure Sidecar runs them: macOS's own
// /bin/bash (3.2) with `-c`, BSD userland (ps, grep, awk, base64, tail),
// tmux on a private socket — the way HostExec runs every client command.
// A fake agent (a `cat` named claude) holds the pane.
//
// And the case that broke chat on Sidecar sessions: a session renamed on
// the Sidecar has its tab's @display rewritten while its record keeps the
// old `launchDisplay`; the guard refused every send as another's tab.
// Skipped when no tmux binary is around.

@Suite("Typing into a Sidecar session (bash 3.2, BSD userland)", .serialized)
struct SidecarTypingTests {

    /// A real tmux binary — never the Sidecar's `bin/tmux` shim, which is
    /// pinned to the user's live server.
    private static func tmuxBinary() -> String? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
                          repo.appendingPathComponent(".build/arm64-apple-macosx/release/Bromure Sidecar.app/Contents/MacOS/tmux").path,
                          "/Applications/Bromure Sidecar.app/Contents/MacOS/tmux"]
        if let e = ProcessInfo.processInfo.environment["BROMURE_TEST_TMUX"] { candidates.insert(e, at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A scratch dir with a `tmux` wrapper on a private socket, first on
    /// PATH, then only the system's BSD tools (like the Sidecar's shims
    /// dir + the login PATH).
    private struct Rig {
        let dir: URL
        let env: [String: String]

        init?() {
            guard let tmux = SidecarTypingTests.tmuxBinary() else { return nil }
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sct-\(UUID().uuidString.prefix(8))")
            let bin = dir.appendingPathComponent("bin")
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let wrapper = "#!/bin/sh\nexec '\(tmux)' -L sidecar-typing-test -f /dev/null \"$@\"\n"
            let w = bin.appendingPathComponent("tmux")
            try? wrapper.write(to: w, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.path)
            env = ["TMUX_TMPDIR": dir.path, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                   "TERM": "xterm-256color", "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
        }

        /// What HostExec does: `/bin/bash -c <command>`; stdout, or nil on
        /// a non-zero exit (the client's guestExec throws then).
        @discardableResult
        func bash(_ command: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }

        func tearDown() {
            bash("tmux kill-server 2>/dev/null; true")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("/bin/bash on this Mac is the 3.2 the Sidecar runs")
    func bashIsOld() {
        // Not a requirement — a marker: if Apple ever ships a newer bash,
        // this suite stops proving 3.2 compatibility.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "echo $BASH_VERSION"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!v.isEmpty)
    }

    @Test("every generated typing script parses under /bin/bash 3.2")
    func scriptsParse() {
        let t = PaneTarget.chat(window: 3, windowID: "@7", display: "Old name", worktree: "wt/x",
                                alsoDisplay: "New name")
        let scripts = [
            PaneTypeGuard.typeCommand(target: t, text: "hello `rm -rf` $(x) 'q' \"d\"\nline 2"),
            PaneTypeGuard.typeCommand(target: .index(1, foreground: .shell), text: "ls"),
            PaneTypeGuard.enterCommand(t),
            PaneTypeGuard.boxProbeCommand(t),
            PaneTypeGuard.keysCommand(target: t, keys: ["Down", "Enter"]),
            PaneTypeGuard.answerKeysCommand(target: t, keys: ["1"]),
            CodingTaskEngine.guardedEnterCommand(target: t),
        ]
        for s in scripts where !s.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", "-c", s]
            let err = Pipe()
            p.standardError = err
            try? p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0,
                    "bash 3.2 rejects: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
    }

    @Test("a chat send types and submits through /bin/bash 3.2 + BSD tools")
    func typesUnderBash32() async throws {
        guard let rig = Rig() else { return }
        defer { rig.tearDown() }
        rig.bash("tmux new-session -d -s bromure -x 120 -y 30 \"bash -c 'exec -a claude cat'\"")
        try await Task.sleep(nanoseconds: 500_000_000)
        let id = (rig.bash("tmux display-message -p -t bromure:0 '#{window_id}'") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(PaneTypeGuard.isWindowID(id))

        let text = "hello from the Sidecar test — it's \"quoted\" & $HOME"
        let t = PaneTarget.chat(window: 0, windowID: id, display: nil, worktree: nil)
        let out = await PaneTypeGuard.runType(target: t, text: text) { rig.bash($0) }
        #expect(ChatQueueStore.Outcome.of(out) == .typed, "got \(out ?? "nil")")
        let screen = rig.bash("tmux capture-pane -p -t '\(id)'") ?? ""
        // cat echoes the submitted line: the paste went in AND its Enter.
        #expect(screen.components(separatedBy: text).count - 1 == 2, "screen: \(screen)")
    }

    @Test("a renamed Sidecar session still takes chat text; another tab's name is still refused")
    func renamedSessionTypes() async throws {
        guard let rig = Rig() else { return }
        defer { rig.tearDown() }
        // The tab as the Sidecar's rename leaves it: @display = the new
        // title; the session record still says the old launchDisplay.
        rig.bash("tmux new-session -d -s bromure -x 120 -y 30 \"bash -c 'exec -a claude cat'\" "
                 + "&& tmux set-option -w -t bromure:0 @display 'v5.0.1 hotfixes'")
        try await Task.sleep(nanoseconds: 500_000_000)
        let launch = "Create a worktree out of the main branch and call it hotf…"

        // What the client built before: refused as somebody else's tab.
        let old = PaneTarget.chat(window: 0, windowID: nil, display: launch, worktree: nil)
        let refused = await PaneTypeGuard.runType(target: old, text: "first") { rig.bash($0) }
        #expect(ChatQueueStore.Outcome.of(refused) == .refused(.identity))
        #expect(!(rig.bash("tmux capture-pane -p -t bromure:0") ?? "").contains("first"))

        // With the session's current title as the other name it may carry.
        let fixed = PaneTarget.chat(window: 0, windowID: nil, display: launch, worktree: nil,
                                    alsoDisplay: "v5.0.1 hotfixes")
        let typed = await PaneTypeGuard.runType(target: fixed, text: "second") { rig.bash($0) }
        #expect(ChatQueueStore.Outcome.of(typed) == .typed, "got \(typed ?? "nil")")
        #expect((rig.bash("tmux capture-pane -p -t bromure:0") ?? "").contains("second"))

        // A tab named for some other session is still refused.
        let other = PaneTarget.chat(window: 0, windowID: nil, display: launch, worktree: nil,
                                    alsoDisplay: "Some other session")
        let no = await PaneTypeGuard.runType(target: other, text: "third") { rig.bash($0) }
        #expect(ChatQueueStore.Outcome.of(no) == .refused(.identity))
        #expect(!(rig.bash("tmux capture-pane -p -t bromure:0") ?? "").contains("third"))
    }

    @Test("an old queued target (no alt display) still decodes")
    func targetDecodesWithoutAlt() throws {
        let json = #"{"expectDisplay":"x","ref":{"index":{"_0":2}},"foreground":{"agent":{}}}"#
        let t = try JSONDecoder().decode(PaneTarget.self, from: Data(json.utf8))
        #expect(t.expectDisplay == "x" && t.expectDisplayAlt == nil)
    }

    @Test("a session's typed notices accept its current title too (renamed Sidecar session)")
    @MainActor func sessionPaneTargetAcceptsRename() {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "v5.0.1 hotfixes", cwd: "/tmp/x")
        s.windowIndex = 1
        s.launchDisplay = "Create a worktree out of the main branch and call it hotf…"
        let t = AgentSessionEngine.paneTarget(s)
        #expect(t?.expectDisplay == s.launchDisplay)
        #expect(t?.expectDisplayAlt == "v5.0.1 hotfixes")
        // Not renamed: no second name.
        s.title = s.launchDisplay!
        #expect(AgentSessionEngine.paneTarget(s)?.expectDisplayAlt == nil)
    }
}
