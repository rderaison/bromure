import Foundation
import Testing

/// Finding (CWE-400): agentd read a command's whole output into memory. Since
/// a confined command's pipes are drained while it runs, `vm exec` of one that
/// prints without end grew the unconfined agentd until it died, taking every
/// shell and tab service in the VM with it (and the unconfined path's
/// `subprocess.run(capture_output=True)` held all of it too). Each stream now
/// keeps CAPTURE_LIMIT and reads the rest to /dev/null, so the writer never
/// blocks; `vm exec` answers an error for cut output, and a reply the host
/// would refuse (MAX_RESPONSE_SIZE) becomes one too.
@Suite("agentd keeps a command's output within a limit")
struct AgentdCaptureLimitTests {
    /// Runs `body` with agentd loaded as `m`; its stdout, or nil if it hung.
    private func run(_ body: String) throws -> String? {
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, json, subprocess, time
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m.log = lambda *a: None
            m.CAPTURE_LIMIT = 100000
            out = {}
            \(body)
            print(json.dumps(out))
            """, agentd.path]
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = FileHandle.nullDevice
        try py.run()
        // Blocking on a full pipe is one of the failures: don't hang the suite.
        let deadline = Date().addingTimeInterval(30)
        while py.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if py.isRunning { py.terminate(); return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func json(_ s: String?) throws -> [String: Any] {
        let s = try #require(s, "the run hung")
        return try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], "\(s)")
    }

    @Test("a confined command's output past the limit is read and dropped, and says so",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func confined() throws {
        let out = try json(try run("""
            m._SANDBOX = {"control_socket": "/nonexistent/ctl.sock"}
            def fake(argv, cwd=None, env=None, fds=(), pty=False, timeout=None):
                # 3 MB: far past the limit and any pipe. Returning at all means
                # every byte was read.
                for _ in range(30):
                    data = b"x" * 100000
                    while data:
                        n = os.write(fds[1], data); data = data[n:]
                os.write(fds[2], b"done")
                return {"ok": True, "exit": 0}
            m._sandbox_exec = fake
            r = m._ws_run(["/bin/sh", "-c", "true"], capture_output=True, text=True, timeout=10)
            out["big"] = [r.returncode, len(r.stdout), r.stderr, r.truncated]
            def small(argv, cwd=None, env=None, fds=(), pty=False, timeout=None):
                os.write(fds[1], b"hello")
                return {"ok": True, "exit": 3}
            m._sandbox_exec = small
            r = m._ws_run(["/bin/sh", "-c", "true"], capture_output=True, text=True, timeout=10)
            out["small"] = [r.returncode, r.stdout, r.truncated]
            """))
        #expect(out["big"] as? [AnyHashable] == [0, 100000, "done", true])
        #expect(out["small"] as? [AnyHashable] == [3, "hello", false])
    }

    @Test("without a sandbox too: capped, whole when small, and a timeout still a timeout",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func unconfined() throws {
        let out = try json(try run("""
            m._SANDBOX = {}
            m.openshell_requested = lambda: False
            r = m._ws_run(["/bin/sh", "-c", "head -c 3000000 /dev/zero; printf err >&2; exit 4"],
                          capture_output=True, text=True, timeout=20)
            out["big"] = [r.returncode, len(r.stdout), r.stderr, r.truncated]
            r = m._ws_run(["/bin/sh", "-c", "printf 'h\\\\303llo'"], capture_output=True, text=True, timeout=20)
            out["small"] = [r.returncode, r.stdout, r.truncated]
            r = m._ws_run(["/bin/sh", "-c", "printf raw"], capture_output=True, text=False, timeout=20)
            out["bytes"] = r.stdout == b"raw"
            def timed(cmd):
                t = time.monotonic()
                try:
                    m._ws_run(["/bin/sh", "-c", cmd], capture_output=True, timeout=1)
                    return "no timeout"
                except subprocess.TimeoutExpired:
                    return time.monotonic() - t < 5
            out["timeout"] = timed("sleep 10")
            # A child left behind holds the pipe open: still within the deadline.
            out["orphan"] = timed("sleep 10 & echo started")
            """))
        #expect(out["big"] as? [AnyHashable] == [4, 100000, "err", true])
        #expect(out["small"] as? [AnyHashable] == [0, "h\u{FFFD}llo", false])
        #expect(out["bytes"] as? Bool == true)
        #expect(out["timeout"] as? Bool == true)
        #expect(out["orphan"] as? Bool == true)
    }

    @Test("vm exec answers an error for cut output, and for a reply the host would refuse",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func execReply() throws {
        let out = try json(try run("""
            ok = {"stdout": "x" * 10, "stderr": "", "exit_code": 0}
            out["ok"] = json.loads(m._exec_response_bytes(ok)) == ok
            m.MAX_RESPONSE_SIZE = 1000
            big = json.loads(m._exec_response_bytes({"stdout": "\\"" * 600, "stderr": "", "exit_code": 0}))
            out["big"] = [big["stdout"], big["exit_code"], big["truncated"], "too large" in big["stderr"]]
            """))
        #expect(out["ok"] as? Bool == true)
        #expect(out["big"] as? [AnyHashable] == ["", -1, true, true])
        // The exec handler sends through it, and refuses a truncated result.
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py"), encoding: .utf8)
        #expect(src.contains("resp_data = _exec_response_bytes(response)"))
        #expect(src.contains("if getattr(result, \"truncated\", False):"))
        #expect(!src.contains("resp_data = json.dumps(response).encode(\"utf-8\")"))
    }
}
