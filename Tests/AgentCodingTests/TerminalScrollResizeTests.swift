import Foundation
import Testing

/// Issue #51: switching between terminal windows scrolled a scrolled-back
/// terminal to the bottom. Each switch moves size authority between tmux
/// clients of different sizes, so the window resizes; on a resize tmux keeps
/// the copy cursor's line and puts it on row 0, and the wheel left that
/// cursor on the bottom row — every switch dropped the view a whole screen.
/// The wheel bindings now park the cursor on the view's top line. This runs
/// bromure-agentd's own `create_session` bindings on a real tmux, feeds the
/// host's wheel sequences through an attached client, and resizes the way
/// window switches do.
@Suite("Terminal: a scrolled-back view survives window switches")
struct TerminalScrollResizeTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var tmux: String? {
        [root.appendingPathComponent("vendor/tmux/bin/tmux").path,
         "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var runnable: Bool {
        tmux != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
    }

    private static let driver = #"""
        import importlib.util, json, os, pty, select, struct, subprocess, sys, tempfile, time
        import fcntl, termios
        agentd, tmux = sys.argv[1], sys.argv[2]
        d = tempfile.mkdtemp()
        sock = os.path.join(d, "s")
        with open(os.path.join(d, "tmux"), "w") as f:
            f.write('#!/bin/sh\nexec "%s" -S "%s" -f /dev/null "$@"\n' % (tmux, sock))
        os.chmod(os.path.join(d, "tmux"), 0o755)
        os.environ["PATH"] = d + ":" + os.environ["PATH"]
        spec = importlib.util.spec_from_file_location("agentd", agentd)
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        def tm(*a): return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout.strip()
        out = {}
        try:
            m.HOME = d
            m.create_session()
            tm("respawn-pane", "-k", "-t", "bromure:0", "sh -c 'seq 1 2000; exec sleep 1000'")
            pid, fd = pty.fork()
            if pid == 0:
                os.environ["TERM"] = "xterm-256color"
                os.execvp("tmux", ["tmux", "attach", "-t", "bromure"])
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
            def pump(t):
                end = time.time() + t
                while time.time() < end:
                    if select.select([fd], [], [], 0.05)[0]:
                        try: os.read(fd, 65536)
                        except OSError: return
            def wheel(seq, n):
                for _ in range(n):
                    os.write(fd, seq); pump(0.02)
                pump(0.3)
            def top():
                return int(tm("display", "-p", "-t", "bromure:0",
                              "#{e|-:#{history_size},#{scroll_position}}"))
            def mode(): return tm("display", "-p", "-t", "bromure:0", "#{pane_in_mode}")
            pump(0.8)
            if sys.argv[3] == "selection":
                # A keyboard selection made in wheel-entered copy-mode, then
                # one more wheel tick: the copy must still be the marked lines.
                for keys in ("emacs", "vi"):
                    tm("set-option", "-g", "mode-keys", keys)
                    wheel(b"\x1b[1000001~", 30)
                    # The line's first word: the view's position overlay follows it.
                    start = tm("display", "-p", "-t", "bromure:0", "#{copy_cursor_line}").split()[0]
                    tm("send-keys", "-t", "bromure:0", "-X", "begin-selection")
                    for _ in range(3):
                        tm("send-keys", "-t", "bromure:0", "-X", "cursor-down")
                    wheel(b"\x1b[1000001~", 1)
                    tm("send-keys", "-t", "bromure:0", "-X", "copy-selection-no-clear")
                    out[keys] = {"start": start, "copied": tm("show-buffer").splitlines()}
                    tm("send-keys", "-t", "bromure:0", "-X", "cancel")
                    pump(0.2)
                print(json.dumps(out))
                sys.exit(0)
            tm("set-option", "-g", "window-size", "manual")
            wheel(b"\x1b[1000001~", 30)
            out["scrolled"] = mode() == "1"
            out["before"] = top()
            for x, y in [(120, 40), (100, 30), (80, 24), (100, 30)] * 3:
                tm("resize-window", "-t", "bromure:0", "-x", str(x), "-y", str(y))
            out["after"] = top()
            wheel(b"\x1b[1000002~", 5)
            out["down5"] = top()
            wheel(b"\x1b[1000002~", 100)
            out["leftAtBottom"] = mode() == "0"
        finally:
            subprocess.run(["tmux", "kill-server"], capture_output=True)
        print(json.dumps(out))
        """#

    private static func drive(_ scenario: String) throws -> [String: Any] {
        let agentd = root.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-I", "-c", driver, agentd.path, try #require(tmux), scenario]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the top line stays put across resizes; the wheel still scrolls and leaves at the bottom",
          .enabled(if: TerminalScrollResizeTests.runnable))
    func scrollPositionKept() throws {
        let r = try Self.drive("resize")
        #expect(r["scrolled"] as? Bool == true)
        let before = try #require(r["before"] as? Int)
        #expect(r["after"] as? Int == before, "view moved from line \(before) to \(r["after"] ?? "?")")
        #expect(r["down5"] as? Int == before + 5)
        #expect(r["leftAtBottom"] as? Bool == true)
    }

    @Test("a wheel tick leaves a keyboard selection's end where it was (emacs and vi keys)",
          .enabled(if: TerminalScrollResizeTests.runnable))
    func wheelKeepsSelection() throws {
        let r = try Self.drive("selection")
        for keys in ["emacs", "vi"] {
            let run = try #require(r[keys] as? [String: Any], "\(keys): no result")
            let start = try #require(run["start"] as? String)
            let copied = try #require(run["copied"] as? [String])
            #expect(copied.first == start, "\(keys): copy starts at \(copied.first ?? "-"), selection began at \(start)")
            // Three lines down, one back with the wheel's scroll-up: the
            // marked line and the next (emacs keys stop short of the cursor).
            #expect(copied.prefix(2) == [start, String(Int(start)! + 1)], "\(keys): selection collapsed to \(copied)")
        }
    }
}
