import Foundation
import Testing

/// Issue #64: the guest's clock stood still while the Mac slept, and nothing
/// set it right on wake. The host now writes `.resume-signal` on wake as well as
/// after a restore. On a strict workspace agentd has no sudo to apply it, so a
/// root watcher started before the revocation does.
@Suite("Guest clock resync: wake signal, strict root watcher", .serialized)
struct GuestClockResyncTests {
    private static let python = "/usr/bin/python3"
    private static let vmSetup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")

    private func run(_ script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = Self.vmSetup
        p.arguments = ["-c", "\(Self.python) - '\(dir.path)' <<'PY'\n"
            + "import importlib.util, sys, os, json, subprocess, shlex, time, types\n"
            + "s = importlib.util.spec_from_file_location('agentd', 'bromure-agentd.py')\n"
            + "m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
            + "d = os.path.realpath(sys.argv[1])\n"
            + "m.OPENSHELL_SPEC = d + '/spec.json'; m.SENTRY_STATUS = d + '/sentry.json'\n"
            + "m.log = lambda *a: None\n"
            + script + "\nPY"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The strict root script starts the clock watcher before sudo is revoked",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func strictScriptStartsWatcher() throws {
        let out = try run("""
            m.strict_sandbox_requested = lambda: True
            m.strict_sandbox_applied = lambda: False
            m._have_sudo = lambda: True
            seen = []
            def spy(argv, **kw):
                seen.append(argv); return subprocess.CompletedProcess(argv, 0, '', '')
            m.subprocess.run = spy
            class Exit(Exception): pass
            def fake_exit(code): raise Exit()
            m.os._exit = fake_exit
            try: m.task_strict_sandbox()
            except Exit: pass
            script = [a for a in seen if a[:3] == ['sudo', '-n', 'sh']][0][-1]
            lines = script.splitlines()
            run_at = [i for i, l in enumerate(lines) if l.startswith('systemd-run --unit=bromure-clockd ')]
            revoke_at = [i for i, l in enumerate(lines) if 'apply' in l and l.startswith('/usr/bin/python3')]
            # The watcher's code is one shell word; parse the whole script to get it.
            words = shlex.split(script, comments=True)
            code = words[words.index('-c', words.index('--unit=bromure-clockd')) + 1]
            print(json.dumps({"one": len(run_at) == 1,
                              "before": bool(run_at and revoke_at and run_at[0] < revoke_at[0]),
                              "code": code == m.CLOCK_WATCH_CODE}))
            """)
        #expect(out.contains(#""one": true"#), "\(out)")
        #expect(out.contains(#""before": true"#), "\(out)")
        #expect(out.contains(#""code": true"#), "\(out)")
    }

    @Test("The root watcher steps the clock forward only, once per signal, without exec",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func watcherForwardOnly() throws {
        let out = try run("""
            sig = d + '/sig'
            now = [1000.0]
            set_to = []
            # Signals seen on successive polls: ahead, the same again, behind,
            # garbage, ahead again.
            seq = ['1806', '1806', '900', 'x12', '2000']
            polls = [0]
            class Stop(Exception): pass
            def sleep(_):
                polls[0] += 1
                if polls[0] >= len(seq): raise Stop()
                open(sig, 'w').write(seq[polls[0]])
            def settime(clk, t):
                set_to.append(t); now[0] = t
            fake = types.SimpleNamespace(time=lambda: now[0], sleep=sleep,
                                         clock_settime=settime, CLOCK_REALTIME=0)
            sys.modules['time'] = fake
            open(sig, 'w').write(seq[0])
            code = m.CLOCK_WATCH_CODE.replace('/mnt/bromure-meta/.resume-signal', sig)
            g = {}
            try: exec(code, g)
            except Stop: pass
            print(json.dumps({"set": set_to}))
            """)
        #expect(out.contains(#"{"set": [1806.0, 2000.0]}"#), "\(out)")
    }

    @Test("Under strict, agentd's own watcher runs no sudo",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func agentdSkipsSudoUnderStrict() throws {
        let out = try run("""
            m.META = d
            open(d + '/.resume-signal', 'w').write(str(int(time.time()) + 600))
            m._have_sudo = lambda probe=False: False
            calls = []
            m._sudo = lambda args, **kw: calls.append(args)
            def sleep(_): m._RUNNING.clear()
            m.time.sleep = sleep
            m._RUNNING.set()
            m.resume_watcher_service()
            print(json.dumps({"sudo": calls}))
            """)
        #expect(out.contains(#"{"sudo": []}"#), "\(out)")
    }
}
