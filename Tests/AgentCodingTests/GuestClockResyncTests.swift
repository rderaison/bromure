import Foundation
import Testing

/// Issue #64: the guest's clock stood still while the Mac slept, and nothing
/// set it right on wake. The host now writes `.resume-signal` on wake as well as
/// after a restore. On a strict workspace agentd has no sudo to apply it, so the
/// root attestor does, and it restarts itself on a newly staged copy so that a
/// workspace restored from an older snapshot gets the watcher too.
@Suite("Guest clock resync: wake signal, strict attestor", .serialized)
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

    private func runAttestd(_ script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attestd-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = Self.vmSetup
        p.arguments = ["-c", "\(Self.python) - '\(dir.path)' --selftest <<'PY'\n"
            + "import importlib.util, sys, os, json, shutil\n"
            + "s = importlib.util.spec_from_file_location('attestd', 'bromure-attestd.py')\n"
            + "m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
            + "d = os.path.realpath(sys.argv[1])\n"
            + "m.log = lambda *a: None\n"
            + script + "\nPY"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("attestd steps the clock forward only, once per signal, without exec",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func attestdClockForwardOnly() throws {
        let out = try runAttestd("""
            sig = d + '/sig'
            now = [1000.0]
            set_to = []
            # Signals seen on successive polls: ahead, the same again, behind,
            # garbage, ahead again.
            seq = ['1806', '1806', '900', 'x12', '2000']
            polls = [0]
            def sleep(_):
                polls[0] += 1
                if polls[0] < len(seq): open(sig, 'w').write(seq[polls[0]])
            def settime(clk, t):
                set_to.append(t); now[0] = t
            open(sig, 'w').write(seq[0])
            m.clock_watcher(path=sig, sleep=sleep, now=lambda: now[0], settime=settime,
                            running=lambda: polls[0] < len(seq))
            print(json.dumps({"set": set_to}))
            """)
        #expect(out.contains(#"{"set": [1806.0, 2000.0]}"#), "\(out)")
    }

    @Test("attestd exits for a newly staged copy of itself, not for a byte-identical rewrite",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func attestdUpgradesOnNewCopy() throws {
        let out = try runAttestd("""
            f = d + '/bromure-attestd.py'
            shutil.copy('bromure-attestd.py', f)
            body = open(f).read()
            # Poll 1: rewritten identically (new mtime). Poll 2: a new version.
            steps = [lambda: open(f, 'w').write(body),
                     lambda: open(f, 'w').write(body + '\\n# v2\\n')]
            polls = [0]; exits = []
            class Exited(Exception): pass
            def sleep(_):
                if polls[0] < len(steps):
                    steps[polls[0]]()
                    st = os.stat(f); os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9 * (polls[0] + 1)))
                polls[0] += 1
            def exit(code):
                exits.append(polls[0]); raise Exited()
            try: m.upgrade_watcher(path=f, sleep=sleep, exit=exit, running=lambda: polls[0] < 5)
            except Exited: pass
            print(json.dumps({"exits": exits}))
            """)
        // No exit after the identical rewrite (poll 1); exit after the new copy (poll 2).
        #expect(out.contains(#"{"exits": [2]}"#), "\(out)")
    }

    @Test("attestd's main starts the clock and upgrade watchers",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func attestdMainStartsWatchers() throws {
        let out = try runAttestd("""
            started = []
            class T:
                def __init__(self, target=None, daemon=None): self.t = target
                def start(self): started.append(self.t.__name__)
            m.threading.Thread = T
            m.os.geteuid = lambda: 0
            class Stop(Exception): pass
            def boom(): raise Stop()
            m.load_secret = boom
            m.time.sleep = lambda _: (_ for _ in ()).throw(Stop())
            try: m.main()
            except Stop: pass
            print(json.dumps({"started": sorted(started)}))
            """)
        #expect(out.contains(#"{"started": ["clock_watcher", "upgrade_watcher"]}"#), "\(out)")
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
