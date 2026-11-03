import Foundation
import Testing

/// Finding (CWE-670): "Hard sentry wait runs inside the 60s strict boot script
/// and kills revocation". With `requirement: hard` the sentry loader waited
/// inline (up to 45 s) and then built a module locally (minutes) inside the
/// strict root script agentd runs with `timeout=60`; the timeout killed it
/// before the supervisor started and before sudo was revoked. The loader now
/// runs in its own unit and the hard requirement holds the session instead.
@Suite("Hard sentry: the loader never runs inside a timed root script", .serialized)
struct HardSentryBootTests {
    private static let python = "/usr/bin/python3"
    private static let vmSetup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")

    private func run(_ script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hard-sentry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = Self.vmSetup
        p.arguments = ["-c", "\(Self.python) - '\(dir.path)' <<'PY'\n"
            + "import importlib.util, sys, os, json, subprocess, threading, time\n"
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

    @Test("The strict root script starts the loader as a unit, before the supervisor and the revocation",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func strictScriptStartsUnit() throws {
        let out = try run("""
            open(m.OPENSHELL_SPEC, 'w').write('{}')
            m.strict_sandbox_requested = lambda: True
            m.strict_sandbox_applied = lambda: False
            m._have_sudo = lambda: True
            seen = []
            def spy(argv, **kw):
                seen.append((argv, kw)); return subprocess.CompletedProcess(argv, 0, '', '')
            m.subprocess.run = spy
            class Exit(Exception): pass
            def fake_exit(code): raise Exit()
            m.os._exit = fake_exit
            try: m.task_strict_sandbox()
            except Exit: pass
            argv, kw = [x for x in seen if x[0][:3] == ['sudo', '-n', 'sh']][0]
            script = argv[-1]
            lines = [l.strip() for l in script.splitlines()]
            unit = [i for i, l in enumerate(lines) if l.startswith('systemd-run --unit=bromure-sentryd ')]
            inline = [l for l in lines if 'bromure-sentryd' in l and not l.startswith(('systemd-run', 'systemctl', 'if ', '#'))]
            sandboxd = [i for i, l in enumerate(lines) if l.startswith('systemd-run --unit=bromure-sandboxd')]
            apply = [i for i, l in enumerate(lines) if l.endswith('apply >/dev/null 2>&1')]
            print('UNIT', len(unit) == 1)
            print('NOT_INLINE', inline == [])
            print('ORDER', bool(unit and sandboxd and apply) and unit[0] < sandboxd[0] < apply[0])
            """)
        for key in ["UNIT", "NOT_INLINE", "ORDER"] { #expect(out.contains("\(key) True"), Comment(rawValue: out)) }
    }

    @Test("Without strict the loader is started as a unit too, not waited on",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func nonStrictStartsUnit() throws {
        let out = try run("""
            open(m.OPENSHELL_SPEC, 'w').write('{}')
            m.strict_sandbox_requested = lambda: False
            m.META = d
            open(d + '/bromure-sentryd', 'w').write('')
            seen = []
            def spy(argv, **kw):
                seen.append((argv, kw)); return subprocess.CompletedProcess(argv, 0, '', '')
            m.subprocess.run = spy
            m.task_openshell_root_helpers()
            loader = [x for x in seen if '/usr/bin/python3' in x[0] and any(a.endswith('/bromure-sentryd') for a in x[0])]
            print('UNIT', len(loader) == 1 and '--unit=bromure-sentryd' in loader[0][0])
            print('SHORT', loader[0][1].get('timeout', 999) <= 120)
            """)
        for key in ["UNIT", "SHORT"] { #expect(out.contains("\(key) True"), Comment(rawValue: out)) }
    }

    @Test("A hard sentry holds the session until the loader settles; a dead loader doesn't hold it",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func sessionWaitsForHard() throws {
        let out = try run("""
            def status(state): json.dump({'sentry': state}, open(m.SENTRY_STATUS, 'w'))
            open(m.OPENSHELL_SPEC, 'w').write(json.dumps({'sentry': {'enabled': True, 'requirement': 'hard'}}))
            m._unit_active = lambda unit: True
            status('waiting')
            threading.Timer(1.0, lambda: status('running')).start()
            t = time.time(); r = m._await_hard_sentry(poll=0.05)
            print('WAITED', r == 'running' and time.time() - t >= 0.9)
            status('unavailable')
            print('UNAVAILABLE', m._await_hard_sentry(poll=0.05) == 'unavailable')
            status('waiting')
            m._unit_active = lambda unit: False
            print('DEAD_LOADER', m._await_hard_sentry(poll=0.05, grace=0.2) == 'waiting')
            m._unit_active = lambda unit: True
            print('BOUNDED', m._await_hard_sentry(deadline_s=0.3, poll=0.05) == 'waiting')
            open(m.OPENSHELL_SPEC, 'w').write(json.dumps({'sentry': {'enabled': True, 'requirement': 'best_effort'}}))
            t = time.time()
            print('BEST_EFFORT', m._await_hard_sentry(poll=0.05) is None and time.time() - t < 0.5)
            """)
        for key in ["WAITED", "UNAVAILABLE", "DEAD_LOADER", "BOUNDED", "BEST_EFFORT"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// The supervisor is what creates the session (its initial start), and
    /// what runs `vm exec` and interactive shells: the hold has to be there,
    /// not only in agentd.
    @Test("The supervisor starts no server and runs no exec while a hard sentry hasn't settled",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func supervisorHolds() throws {
        let out = try run("""
            import types, importlib.machinery
            os.uname = lambda: types.SimpleNamespace(sysname='Linux', nodename='t', release='6.8', version='', machine='aarch64')
            ld = importlib.machinery.SourceFileLoader('sandboxd', 'bromure-sandboxd')
            sd = importlib.util.module_from_spec(importlib.util.spec_from_loader('sandboxd', ld)); ld.exec_module(sd)
            sd.log = lambda *a: None
            st = d + '/sentry-status.json'
            def status(state): json.dump({'sentry': state}, open(st, 'w'))
            started = []
            sd.start_server = lambda plan, tgid: (started.append(1), (None, {'ok': True}))[1]
            sd.server_pid = lambda: None
            sd.write_status = lambda s: None
            status('waiting')
            hold = sd.SentryHold(True, unit_active=lambda u: True, status_path=st)
            sup = sd.Supervisor(types.SimpleNamespace(uid=1000, gid=1000, owner_uid=1000, owner_gid=1000, sandbox_cgroup=None),
                                {'warnings': []}, None, hold)
            sup.publish = lambda *a, **k: None
            ok, why = sup.start('initial')
            print('START_HELD', not ok and why == sd.WAITING_FOR_SENTRY and not started)
            class Conn:
                sent = b''
                def sendall(self, b): Conn.sent += b
            r, w = os.pipe()
            sup.handle_exec(Conn(), {'argv': ['/bin/true']}, [r, w])
            closed = all(not os.path.exists('/dev/fd/%d' % fd) for fd in (r, w))
            print('EXEC_HELD', b'waiting for the kernel sentry' in Conn.sent and closed)
            status('running')
            ok, why = sup.start('initial')
            print('START_AFTER', ok and started == [1])
            # A dead loader releases the hold; best effort never holds.
            status('waiting')
            dead = sd.SentryHold(True, unit_active=lambda u: False, grace_s=0, status_path=st)
            time.sleep(0.01)
            print('DEAD_RELEASES', not dead.held())
            print('BEST_EFFORT', not sd.SentryHold(False, status_path=st).held())
            """)
        for key in ["START_HELD", "EXEC_HELD", "START_AFTER", "DEAD_RELEASES", "BEST_EFFORT"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// Finding (CWE-362): "Hard-sentry settle and the boot start both launch
    /// tmux and unlink its socket". The settle thread's start and agentd's
    /// `start` landed together; start_server unlinks the socket first, so the
    /// second deleted the first one's live server's socket.
    @Test("Two starts at once launch one server; the second finds it running",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func oneStartAtATime() throws {
        let out = try run("""
            import types, importlib.machinery
            os.uname = lambda: types.SimpleNamespace(sysname='Linux', nodename='t', release='6.8', version='', machine='aarch64')
            ld = importlib.machinery.SourceFileLoader('sandboxd', 'bromure-sandboxd')
            sd = importlib.util.module_from_spec(importlib.util.spec_from_loader('sandboxd', ld)); ld.exec_module(sd)
            sd.log = lambda *a: None
            state = {'pid': None, 'starts': 0, 'overlap': False, 'inside': 0}
            lock = threading.Lock()
            def fake_start(plan, tgid):
                with lock:
                    state['inside'] += 1; state['starts'] += 1
                    if state['inside'] > 1: state['overlap'] = True
                time.sleep(0.3)                      # unlink, fork, wait for the socket
                with lock:
                    state['pid'] = 4242; state['inside'] -= 1
                return None, {'ok': True}
            sd.start_server = fake_start
            sd.server_pid = lambda: state['pid']
            sd.write_status = lambda s: None
            sup = sd.Supervisor(types.SimpleNamespace(uid=1000, gid=1000, owner_uid=1000, owner_gid=1000, sandbox_cgroup=None),
                                {'warnings': []}, None, sd.SentryHold(False))
            sup.publish = lambda *a, **k: None
            results = []
            ts = [threading.Thread(target=lambda r=r: results.append(sup.start(r)))
                  for r in ('initial, after the sentry', 'requested by pid 1')]
            for t in ts: t.start()
            for t in ts: t.join()
            print('ONE_START', state['starts'] == 1 and not state['overlap'])
            print('BOTH_OK', len(results) == 2 and all(ok for ok, _ in results))
            """)
        for key in ["ONE_START", "BOTH_OK"] { #expect(out.contains("\(key) True"), Comment(rawValue: out)) }
    }

    @Test("agentd asks again when its start loses to one in flight, and gets the server",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func ensureServerRetries() throws {
        let out = try run("""
            open(m.OPENSHELL_SPEC, 'w').write('{}')
            m._SANDBOX = {'tmux_socket': '/run/bromure-tmux/s'}
            replies = [{'ok': False, 'reason': 'busy'}, {'ok': True}]
            asked = []
            def ctl(op, **kw):
                asked.append(op); return replies.pop(0) if replies else {'ok': True}
            m._sandbox_ctl = ctl
            m._load_sandbox_status = lambda: m._SANDBOX
            sessions = iter([False, False, False, True])
            m._has_session = lambda: next(sessions, True)
            print('RETRIED', m.ensure_sandbox_server('session startup', timeout=5.0) and asked == ['start', 'start'])
            """)
        #expect(out.contains("RETRIED True"), Comment(rawValue: out))
    }

    /// Finding (CWE-670): "Hard-sentry hold fails unattended boots at 180s
    /// while the module is still loading". The supervisor published its
    /// socket paths during the hold, so agentd's gate took the VM for ready
    /// and every exec was refused (126) by the supervisor; host probes failed
    /// fast until the 180 s boot wait gave up.
    @Test("During a hold the gate isn't ready; an attach waits it out, an exec is told why",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func gateWaitsForHold() throws {
        let out = try run("""
            m.SANDBOX_STATUS = d + '/status.json'
            open(m.OPENSHELL_SPEC, 'w').write('{}')
            m.strict_sandbox_requested = lambda: False
            def publish(**kw): json.dump(dict({'tmux_socket': '/run/bromure-tmux/s', 'control_socket': '/run/c'}, **kw),
                                         open(m.SANDBOX_STATUS, 'w'))
            publish(sentry_hold=True)
            m._SANDBOX = {}; m._SANDBOX_READY.clear()
            ok, why = m.sandbox_gate(timeout=0.3)
            print('NOT_READY', not ok and 'kernel sentry' in (why or ''))
            # An attach waits through the hold, and gets in once it's over.
            threading.Timer(0.6, lambda: publish(sentry_hold=False)).start()
            t = time.time()
            ok, why = m.sandbox_gate(timeout=0.3, through_sentry_hold=True)
            print('ATTACH_WAITS', ok and time.time() - t >= 0.5)
            # Without a hold, the published server is ready at once (as before).
            m._SANDBOX_READY.clear(); m._SANDBOX = {}
            print('NO_HOLD', m.sandbox_gate(timeout=0.3)[0])
            """)
        for key in ["NOT_READY", "ATTACH_WAITS", "NO_HOLD"] { #expect(out.contains("\(key) True"), Comment(rawValue: out)) }
    }

    @Test("The supervisor's hold says so in its status, and clears it with the started server's publish")
    func supervisorSaysHold() throws {
        let src = try String(contentsOf: Self.vmSetup.appendingPathComponent("bromure-sandboxd"), encoding: .utf8)
        let hold = try #require(src.range(of: "if supervisor.sentry_hold.held():"))
        let block = String(src[hold.lowerBound...].prefix(1200))
        let set = try #require(block.range(of: "supervisor.status[\"sentry_hold\"] = True"))
        let publish = try #require(block.range(of: "supervisor.publish()"))
        #expect(set.lowerBound < publish.lowerBound)
        // Not cleared before the server exists (a republish in between would
        // announce it): in start(), after start_server, in the same publish.
        #expect(!block.contains("supervisor.status[\"sentry_hold\"] = False"))
        // (start() serializes; the work is in _start_locked.)
        let start = try #require(src.range(of: "    def _start_locked(self, reason):"))
        let body = String(src[start.lowerBound...].prefix(2000))
        let server = try #require(body.range(of: "start_server(self.plan"))
        let clear = try #require(body.range(of: "self.status[\"sentry_hold\"] = False"))
        let pub = try #require(body.range(of: "self.publish(outcome, report)"))
        #expect(server.lowerBound < clear.lowerBound && clear.lowerBound < pub.lowerBound)
    }
}
