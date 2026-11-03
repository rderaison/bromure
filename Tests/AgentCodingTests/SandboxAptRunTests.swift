import Foundation
import Testing

/// Finding (CWE-670): "Root apt install is reported failed while apt is
/// still running or has been SIGKILLed". Each apt step had its own 840 s
/// SIGKILL timeout (three steps against agentd's 900 s wait), so "failed"
/// reached the drawer while apt went on, and a kill mid-unpack left dpkg
/// interrupted. Now: one deadline, a SIGTERM stop of the whole group, a stop
/// when the caller goes away, and one install at a time.
@Suite("Sandbox: an approved apt install finishes or is stopped before it's reported", .serialized)
struct SandboxAptRunTests {
    private static let vmSetup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
    private static var runnable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    /// sandboxd with a fake `apt-get` first on PATH. The fake logs each call
    /// (and a SIGTERM) to `log`; `update` sleeps UPDATE_SLEEP seconds.
    private func run(_ script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apt-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = """
            #!/bin/sh
            log="$FAKE_LOG"
            trap 'echo TERM >> "$log"; exit 143' TERM
            echo "start $1" >> "$log"
            case "$1" in
              update) i=0; while [ $i -lt ${UPDATE_SLEEP:-0} ]; do sleep 1; i=$((i+1)); done
                      touch "$FAKE_DIR/lists"; echo "end update" >> "$log"; exit 0 ;;
              install) if [ ! -f "$FAKE_DIR/lists" ]; then echo "E: Unable to locate package curl"; echo "end install" >> "$log"; exit 100; fi
                       # DPKG: start dpkg in a session of its own and wait for
                       # it, as apt does; this apt-get dies at once on TERM.
                       if [ -n "${DPKG:-}" ]; then python3 "$FAKE_DIR/dpkg.py" & wait $!; fi
                       sleep ${INSTALL_SLEEP:-0}; echo "end install" >> "$log"; echo "installed"; exit 0 ;;
            esac
            """
        try fake.write(to: dir.appendingPathComponent("apt-get"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("apt-get").path, 0o755)
        let dpkg = """
            import os, signal, sys, time
            os.setsid()
            def note(s):
                with open(os.environ["FAKE_LOG"], "a") as h: h.write(s + "\\n")
            open(os.environ["FAKE_DIR"] + "/dpkg.pid", "w").write(str(os.getpid()))
            def term(*a):
                if os.environ.get("DPKG") == "stubborn":
                    note("dpkg-ignores-TERM"); return
                note("dpkg-TERM"); time.sleep(1); note("dpkg-END"); sys.exit(0)
            signal.signal(signal.SIGTERM, term)
            if os.environ.get("DPKG") == "script":
                # A maintainer script whose SIGTERM trap backgrounds a
                # subshell and exits: the subshell is init's at once.
                import subprocess
                subprocess.Popen(["sh", "-c", "trap '( sleep 30 ) & echo $! > $FAKE_DIR/bg.pid; exit 0' TERM; "
                                  "touch $FAKE_DIR/postinst.up; while :; do sleep 0.1; done"])
            if os.environ.get("DPKG") == "daemon":
                # The same, but what it backgrounds daemonizes: setsid, its
                # parent gone at once -- no group or session to follow.
                import subprocess
                subprocess.Popen(["sh", "-c", "trap 'setsid $FAKE_DIR/daemon.sh & exit 0' TERM; "
                                  "touch $FAKE_DIR/postinst.up; while :; do sleep 0.1; done"])
            if os.environ.get("DPKG") == "leaves":
                # A postinst that starts a daemon and is done: the install is.
                import subprocess
                subprocess.Popen(["python3", os.environ["FAKE_DIR"] + "/daemon.py"])
                note("dpkg-done"); sys.exit(0)
            note("dpkg-start")
            for _ in range(600): time.sleep(0.1)
            note("dpkg-ran-out")
            """
        try dpkg.write(to: dir.appendingPathComponent("dpkg.py"), atomically: true, encoding: .utf8)
        try """
            import os, time
            os.setsid()
            null = os.open(os.devnull, os.O_RDWR)    # a daemon lets go of apt's output
            for fd in (0, 1, 2): os.dup2(null, fd)
            open(os.environ["FAKE_DIR"] + "/bg.pid", "w").write(str(os.getpid()))
            time.sleep(60)
            """.write(to: dir.appendingPathComponent("daemon.py"), atomically: true, encoding: .utf8)
        // The same at once (setsid(1) execs it in a session of its own),
        // the way `setsid sleep 60 &` in a trap does it. Linux has setsid(1).
        try """
            #!/bin/sh
            echo $$ > "$FAKE_DIR/bg.pid"
            exec sleep 60 </dev/null >/dev/null 2>&1
            """.write(to: dir.appendingPathComponent("daemon.sh"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("daemon.sh").path, 0o755)
        // Knows every name once the lists exist (the exact-name check), logs nothing.
        let cache = """
            #!/bin/sh
            [ -f "$FAKE_DIR/lists" ] || { echo "E: No packages found"; exit 100; }
            for n; do :; done; echo "Package: $n"; echo "Version: 1"
            """
        try cache.write(to: dir.appendingPathComponent("apt-cache"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("apt-cache").path, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.currentDirectoryURL = Self.vmSetup
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin", "FAKE_DIR": dir.path,
                         "FAKE_LOG": dir.appendingPathComponent("log").path]
        p.arguments = ["-I", "-c", """
            import importlib.machinery, importlib.util, os, sys, threading, time, types
            os.uname = lambda: types.SimpleNamespace(sysname='Linux', nodename='t', release='6.8', version='', machine='aarch64')
            sys.path.insert(0, os.getcwd())
            ld = importlib.machinery.SourceFileLoader('sandboxd', 'bromure-sandboxd')
            m = importlib.util.module_from_spec(importlib.util.spec_from_loader('sandboxd', ld)); ld.exec_module(m)
            m.log = lambda *a: None
            D = os.environ['FAKE_DIR']; LOG = os.environ['FAKE_LOG']
            def calls(): return open(LOG).read().split() if os.path.exists(LOG) else []
            def reset():
                for f in (LOG, D + '/lists'):
                    if os.path.exists(f): os.remove(f)
            """ + "\n" + script]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Missing lists: update, then install, all within one call",
          .enabled(if: SandboxAptRunTests.runnable))
    func refreshThenInstall() throws {
        let out = try run("""
            code, text = m.apt_install(['curl'])
            print('OK', code == 0 and 'installed' in text and calls() == ['start', 'update', 'end', 'update', 'start', 'install', 'end', 'install'])
            """)
        #expect(out.contains("OK True"), Comment(rawValue: out))
    }

    @Test("Past the deadline, or with the caller gone, apt's group gets SIGTERM and the call reports it",
          .enabled(if: SandboxAptRunTests.runnable))
    func stopsGracefully() throws {
        let out = try run("""
            os.environ['UPDATE_SLEEP'] = '30'
            m.APT_DEADLINE_S = 2
            t = time.time(); code, text = m.apt_install(['curl'])
            print('DEADLINE', code != 0 and time.time() - t < 10 and 'TERM' in calls() and 'stopped' in text)
            reset(); m.APT_DEADLINE_S = 1800
            gone = time.time() + 1.5
            t = time.time(); code, text = m.apt_install(['curl'], cancelled=lambda: time.time() > gone)
            print('CANCELLED', code != 0 and time.time() - t < 10 and 'TERM' in calls() and 'abandoned' in text)
            """)
        #expect(out.contains("DEADLINE True"), Comment(rawValue: out))
        #expect(out.contains("CANCELLED True"), Comment(rawValue: out))
    }

    /// Finding (CWE-670): "apt stop signals only apt-get's process group,
    /// so dpkg and maintainer scripts keep running". apt starts dpkg with
    /// setsid; killpg of apt's group let apt die at once and returned while
    /// dpkg went on as root (and the install lock let the next apt in).
    @Test("A stop reaches the dpkg apt started in its own session, and returns only once it's gone",
          .enabled(if: SandboxAptRunTests.runnable))
    func stopsDpkgToo() throws {
        let out = try run("""
            import subprocess
            def alive(p):
                r = subprocess.run(['ps', '-o', 'stat=', '-p', str(p)], capture_output=True, text=True).stdout.strip()
                return bool(r) and not r.startswith('Z')
            open(D + '/lists', 'w').close()
            os.environ['DPKG'] = '1'
            gone = time.time() + 2.5
            code, text = m.apt_install(['curl'], cancelled=lambda: time.time() > gone)
            pid = int(open(D + '/dpkg.pid').read()); c = calls()
            print('GRACEFUL', code != 0 and 'dpkg-start' in c and 'dpkg-TERM' in c and 'dpkg-END' in c and not alive(pid))
            reset(); open(D + '/lists', 'w').close()
            os.environ['DPKG'] = 'stubborn'; m.APT_STOP_GRACE_S = 2
            gone = time.time() + 2.5
            t = time.time(); code, text = m.apt_install(['curl'], cancelled=lambda: time.time() > gone)
            pid = int(open(D + '/dpkg.pid').read()); c = calls()
            print('KILLED', code != 0 and 'dpkg-ignores-TERM' in c and 'dpkg-ran-out' not in c
                  and not alive(pid) and time.time() - t < 20)
            """)
        #expect(out.contains("GRACEFUL True"), Comment(rawValue: out))
        #expect(out.contains("KILLED True"), Comment(rawValue: out))
    }

    /// Finding (CWE-670): "apt stop misses root children reparented to init
    /// between process-tree scans". Membership was by parent alone, so a
    /// process forked after a scan by one that then exited (ppid 1 before
    /// any scan saw it) was never tracked or signalled, and the stop
    /// returned (dropping the install lock) with it still running as root.
    @Test("A stop doesn't return while a maintainer script's backgrounded subshell, reparented to init, still runs",
          .enabled(if: SandboxAptRunTests.runnable))
    func stopsReparentedChildren() throws {
        let out = try run("""
            import subprocess
            def alive(p):
                r = subprocess.run(['ps', '-o', 'stat=', '-p', str(p)], capture_output=True, text=True).stdout.strip()
                return bool(r) and not r.startswith('Z')
            open(D + '/lists', 'w').close()
            os.environ['DPKG'] = 'script'; m.APT_STOP_GRACE_S = 3
            gone = time.time() + 2.5
            t = time.time(); code, text = m.apt_install(['curl'], cancelled=lambda: time.time() > gone)
            up = os.path.exists(D + '/postinst.up')
            bg = int(open(D + '/bg.pid').read()) if os.path.exists(D + '/bg.pid') else None
            print('REPARENTED', code != 0 and up and bg is not None and not alive(bg) and time.time() - t < 20,
                  up, bg, bg and alive(bg))
            if bg and alive(bg): os.kill(bg, 9)
            """)
        #expect(out.contains("REPARENTED True"), Comment(rawValue: out))
    }

    /// Finding (CWE-670): "apt stop still returns while a setsid child
    /// reparented to init keeps running". A process that calls setsid and
    /// whose parent exits between two scans is in no tracked group or
    /// session and, its ppid 1, no one's child: the stop returned (the lock
    /// with it) while it ran on as root. apt now runs under a subreaper of
    /// its own, which such a process is reparented to -- Linux only.
    @Test("A stop doesn't return while a daemon a maintainer script started on SIGTERM still runs",
          .enabled(if: SandboxAptRunTests.runnable && FileManager.default.fileExists(atPath: "/proc/self/stat")))
    func stopsDaemonizedChildren() throws {
        let out = try run("""
            def alive(p):
                try: return open('/proc/%d/stat' % p).read().rsplit(')', 1)[1].split()[0] != 'Z'
                except OSError: return False
            open(D + '/lists', 'w').close()
            os.environ['DPKG'] = 'daemon'; m.APT_STOP_GRACE_S = 3
            gone = time.time() + 2.5
            t = time.time(); code, text = m.apt_install(['curl'], cancelled=lambda: time.time() > gone)
            bg = int(open(D + '/bg.pid').read()) if os.path.exists(D + '/bg.pid') else None
            print('DAEMON', code != 0 and bg is not None and not alive(bg) and time.time() - t < 20, bg, bg and alive(bg))
            if bg and alive(bg): os.kill(bg, 9)
            """)
        #expect(out.contains("DAEMON True"), Comment(rawValue: out))
    }

    /// The subreaper waits for everything only when stopping: an install
    /// whose postinst leaves a daemon running is over when apt is.
    @Test("A completed install whose postinst left a daemon returns at once", .enabled(if: SandboxAptRunTests.runnable))
    func completedInstallLeavesDaemon() throws {
        let out = try run("""
            open(D + '/lists', 'w').close()
            os.environ['DPKG'] = 'leaves'
            t = time.time(); code, text = m.apt_install(['curl'])
            for _ in range(50):
                if os.path.exists(D + '/bg.pid'): break
                time.sleep(0.1)
            bg = int(open(D + '/bg.pid').read())
            print('DONE', code == 0 and 'installed' in text and time.time() - t < 15)
            os.kill(bg, 9)
            """)
        #expect(out.contains("DONE True"), Comment(rawValue: out))
    }

    @Test("A second install waits for the one in flight instead of running beside it",
          .enabled(if: SandboxAptRunTests.runnable))
    func oneAtATime() throws {
        let out = try run("""
            open(D + '/lists', 'w').close()
            os.environ['INSTALL_SLEEP'] = '1'
            results = []
            ts = [threading.Thread(target=lambda: results.append(m.apt_install(['curl'])[0])) for _ in range(2)]
            for t in ts: t.start()
            for t in ts: t.join()
            c = calls()
            print('SERIAL', results == [0, 0] and c == ['start', 'install', 'end', 'install', 'start', 'install', 'end', 'install'])
            """)
        #expect(out.contains("SERIAL True"), Comment(rawValue: out))
    }

    @Test("The supervisor notices its caller hanging up", .enabled(if: SandboxAptRunTests.runnable))
    func peerGone() throws {
        let out = try run("""
            import socket
            a, b = socket.socketpair()
            print('ALIVE', not m._peer_gone(a))
            b.close()
            print('GONE', m._peer_gone(a))
            """)
        #expect(out.contains("ALIVE True") && out.contains("GONE True"), Comment(rawValue: out))
    }
}
