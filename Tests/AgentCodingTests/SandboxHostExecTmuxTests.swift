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
}
