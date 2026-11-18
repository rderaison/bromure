import Foundation
import Testing

/// "No shell connection" on Ark's codereview: a burst of commit-review runs
/// started at once drained agentd's pool of idle host connections while the
/// host was slow to accept them. Each replacement was tried 20 times, 0.1 s
/// apart, then given up for good, and nothing tried again: no new terminal or
/// session until agentd was restarted. The pool now has one refiller that
/// keeps every slot filled, backing off, for as long as agentd runs.
@Suite("agentd keeps its shell pool full",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct AgentdShellPoolTests {
    /// Runs `body` with agentd loaded as `m` and its log captured in `logs`;
    /// prints `out` as JSON.
    private func run(_ body: String) throws -> [String: Any] {
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, json, threading, time
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            logs = []
            m.log = lambda tag, msg: logs.append(msg)
            out = {}
            def wait_for(cond, secs=10):
                end = time.time() + secs
                while time.time() < end and not cond():
                    time.sleep(0.005)
                return cond()
            \(body)
            out["logs"] = logs
            print(json.dumps(out))
            """, agentd.path]
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = FileHandle.nullDevice
        try py.run()
        let deadline = Date().addingTimeInterval(30)
        while py.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if py.isRunning { py.terminate() }
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], "\(s)")
    }

    @Test("a drained pool is refilled however long the host refuses: never given up")
    func refillsAfterAnOutage() throws {
        let out = try run("""
            state = {"fail": 0, "calls": 0}
            lock = threading.Lock()
            held = []
            def connect():
                with lock:
                    state["calls"] += 1
                    if state["fail"] > 0:
                        state["fail"] -= 1
                        return None
                return object()
            def handle(sock, replenish):
                held.append(replenish)   # an idle connection, until "claimed"
            sleeps = []
            def nap(x):
                sleeps.append(x); time.sleep(0.001)
            running = [True]
            pool = m._ShellPool(connect, handle, lambda: running[0], sleep=nap, size=4)
            t = threading.Thread(target=pool.run, daemon=True); t.start()
            out["filled"] = wait_for(lambda: pool.established == 4)
            # A burst claims all four, while the host refuses 200 attempts in a
            # row (the old code gave up after 20).
            state["fail"] = 200
            for r in list(held): r()
            out["refilled"] = wait_for(lambda: pool.established == 8 and pool.missing() == 0)
            out["failed_attempts"] = 200 - state["fail"]
            out["max_sleep"] = max(sleeps) if sleeps else 0
            out["min_sleep"] = min(sleeps) if sleeps else 0
            running[0] = False
            t.join(3)
            out["stopped"] = not t.is_alive()
            """)
        #expect(out["filled"] as? Bool == true)
        #expect(out["refilled"] as? Bool == true, "every slot is back after the outage")
        #expect(out["failed_attempts"] as? Int == 200)
        #expect((out["max_sleep"] as? Double ?? 0) <= 5.0, "backs off, capped")
        #expect((out["min_sleep"] as? Double ?? 1) >= 0.1)
        #expect(out["stopped"] as? Bool == true, "stops with agentd")
        let logs = out["logs"] as? [String] ?? []
        #expect(logs.contains("pool ready (4 connections)"))
        #expect(logs.filter { $0.hasPrefix("the host isn't taking pool connections") }.count == 1,
                "one line per outage, not one per attempt")
        #expect(logs.contains { $0.hasPrefix("pool connection to the host restored after 200 failed attempts") })
        #expect(!logs.contains { $0.contains("failed to replenish pool") })
    }

    @Test("each claim is replaced once: the pool never grows past its size")
    func neverOverfills() throws {
        let out = try run("""
            held = []
            running = [True]
            pool = m._ShellPool(lambda: object(), lambda s, r: held.append(r), lambda: running[0],
                                sleep=lambda x: None, size=4)
            t = threading.Thread(target=pool.run, daemon=True); t.start()
            wait_for(lambda: pool.established == 4)
            # Three claimed at once, from three threads, as parallel runs do.
            claims = [threading.Thread(target=held[i]) for i in range(3)]
            for c in claims: c.start()
            for c in claims: c.join()
            wait_for(lambda: pool.established == 7)
            time.sleep(0.2)
            out["established"] = pool.established
            out["missing"] = pool.missing()
            running[0] = False
            t.join(3)
            """)
        #expect(out["established"] as? Int == 7)
        #expect(out["missing"] as? Int == 0)
    }

    /// Review finding on d8685b65: a terminal requested before the sandbox was
    /// ready replenished twice (before the sandbox wait, then on claim), and
    /// each replenish is one more slot: the pool grew past its size.
    @Test("a terminal that waited for the sandbox is replaced once, not twice")
    func interactiveBeforeSandboxReplenishesOnce() throws {
        let out = try run("""
            import struct
            m._SANDBOX_READY.clear()
            m.sandbox_gate = lambda through_sentry_hold=False: (True, "")
            m._run_interactive = lambda sock, req: None
            m._version_mismatch = lambda req: False
            body = json.dumps({"interactive": True, "cmd": "bash"}).encode()
            class Sock:
                def __init__(self): self.buf = struct.pack(">I", len(body)) + body
                def recv(self, n):
                    b, self.buf = self.buf[:n], self.buf[n:]
                    return b
                def recv_into(self, view, n=0):
                    n = n or len(view)
                    b, self.buf = self.buf[:n], self.buf[n:]
                    view[:len(b)] = b
                    return len(b)
                def sendall(self, b): pass
                def close(self): pass
                def settimeout(self, t): pass
            calls = []
            m._shell_handle_connection(Sock(), lambda: calls.append(1))
            out["replenished"] = len(calls)
            """)
        #expect(out["replenished"] as? Int == 1)
    }

    /// Finding "Serial shell pool refill can time out concurrent guest
    /// operations": one refiller connected the replacements in turn, so four
    /// claimed at once behind a ~1 s connect() took ~4 s -- past the ~3 s the
    /// host waits for a pooled connection (guestExec, file ops: 30 x 100 ms).
    @Test("a burst's replacements connect side by side, within the host's 3 s wait")
    func burstRefillsConcurrently() throws {
        let out = try run("""
            held = []
            slow = [False]
            active = [0, 0]   # in connect() now, most at once
            lock = threading.Lock()
            def connect():
                if slow[0]:
                    with lock:
                        active[0] += 1; active[1] = max(active[1], active[0])
                    time.sleep(1.0)
                    with lock:
                        active[0] -= 1
                return object()
            running = [True]
            pool = m._ShellPool(connect, lambda s, r: held.append(r), lambda: running[0], size=4)
            t = threading.Thread(target=pool.run, daemon=True); t.start()
            wait_for(lambda: pool.established == 4)
            slow[0] = True
            started = time.time()
            for r in list(held[:4]): threading.Thread(target=r).start()
            out["refilled"] = wait_for(lambda: pool.established == 8, secs=10)
            out["took"] = time.time() - started
            out["most_at_once"] = active[1]
            out["missing"] = pool.missing()
            running[0] = False
            t.join(3)
            """)
        #expect(out["refilled"] as? Bool == true)
        #expect((out["took"] as? Double ?? 99) < 2.5, "all four back well inside the host's 3 s")
        #expect(out["most_at_once"] as? Int == 4, "one filler per missing slot, connecting at once")
        #expect(out["missing"] as? Int == 0)
    }

    @Test("the service runs the pool on the real connect and handler")
    func wired() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py"), encoding: .utf8)
        #expect(src.contains("_ShellPool(_shell_connect_to_host, _shell_handle_connection, _RUNNING.is_set).run()"))
        #expect(!src.contains("failed to replenish pool after 20 attempts"))
    }
}
