import Foundation
import Testing

/// User report: with an OpenShell policy and the kernel sentry (what the
/// editor sets up), a session's chat stayed empty. The tmux server runs on
/// the sandbox's socket, and the host's commands run a bare `tmux`: the
/// check of the transcript a tab pinned (`tmux display-message`) found no
/// server, so the pin was discarded and the chat never found its
/// conversation -- and every other host-side tmux call failed the same way.
/// A confined non-interactive command now gets $TMUX naming the sandbox's
/// server, as tmux gives its own panes.
@Suite("Host commands in a sandbox reach its tmux server")
struct SandboxHostExecTmuxTests {
    @Test("a confined command gets TMUX for the sandbox's server; a pty, or a TMUX already set, doesn't",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func confinedEnv() throws {
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, json
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            out = {}
            m._SANDBOX = {"tmux_socket": "/run/bromure-sandbox/server/tmux.sock"}
            out["exec"] = m._confined_env({"A": "1"}, False)
            out["pty"] = m._confined_env({}, True)
            out["kept"] = m._confined_env({"TMUX": "/other,1,2"}, False)
            out["none"] = m._confined_env(None, False)
            m._SANDBOX = {}
            out["nosandbox"] = m._confined_env({}, False)
            print(json.dumps(out))
            """, agentd.path]
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = FileHandle.nullDevice
        try py.run(); py.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        #expect(out["exec"] == ["A": "1", "TMUX": "/run/bromure-sandbox/server/tmux.sock,0,0"])
        #expect(out["pty"] == [:])                                  // an interactive shell's attach would refuse to nest
        #expect(out["kept"] == ["TMUX": "/other,1,2"])
        #expect(out["none"]?["TMUX"] == "/run/bromure-sandbox/server/tmux.sock,0,0")
        #expect(out["nosandbox"] == [:])
        // Every confined exec goes through it.
        let src = try String(contentsOf: agentd, encoding: .utf8)
        #expect(src.contains(#""cwd": cwd, "env": _confined_env(env, pty),"#))
    }


    /// The session's chat stayed on "Loading transcript…" under the sentry
    /// with a real agent: its transcript is larger than a pipe holds. agentd
    /// read a confined command's output only after the supervisor replied, so
    /// a command writing more than 64 KiB blocked, never exited, and the read
    /// timed out (126). The pipes are now read while the command runs.
    @Test("a confined command's large output comes back whole, not a timeout",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func largeOutput() throws {
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m._SANDBOX = {"control_socket": "/nonexistent/ctl.sock"}
            m.log = lambda *a: None
            # The supervisor: the command writes its output, THEN the reply comes.
            def fake(argv, cwd=None, env=None, fds=(), pty=False, timeout=None):
                data = b"x" * 300000
                while data:
                    n = os.write(fds[1], data); data = data[n:]
                os.write(fds[2], b"done")
                return {"ok": True, "exit": 0}
            m._sandbox_exec = fake
            r = m._ws_run(["/bin/sh", "-c", "true"], capture_output=True, text=True, timeout=10)
            print(r.returncode, len(r.stdout), r.stderr)
            """, agentd.path]
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = FileHandle.nullDevice
        try py.run()
        // A deadlock is the failure: don't let it hang the suite.
        let deadline = Date().addingTimeInterval(20)
        while py.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if py.isRunning { py.terminate() }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "0 300000 done", "\(out)")
    }
}
