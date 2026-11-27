import Testing
import Foundation

// Regression: Docker starts on demand (docker.socket); a container with a
// restart policy is brought back by task_docker_autostart after the shell.
// Under the strict sandbox that task runs in the incarnation after the sudo
// revocation, where it can do nothing, so such a container never came back
// after a reboot. The strict root script, the last thing with root, now
// schedules that start itself, before the revocation.
@Suite("Strict workspaces bring restart-policy containers back")
struct StrictDockerAutostartTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    @Test("The strict root script schedules dockerd for restart-policy containers, before the revocation",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func strictScriptSchedulesDocker() throws {
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, subprocess
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m.strict_sandbox_requested = lambda: True
            m.strict_sandbox_applied = lambda: False
            m._have_sudo = lambda probe=False: True
            m.log = lambda *a, **k: None
            seen = []
            class Done(Exception): pass
            def run(args, **kw):
                if args[:3] == ['sudo', '-n', 'sh']:
                    seen.append(args[4]); raise Done()
                return subprocess.CompletedProcess(args, 0, '', '')
            m.subprocess.run = run
            try:
                m.task_strict_sandbox()
            except Done:
                pass
            script = seen[0]
            start = script.index('systemd-run --unit=bromure-docker-autostart')
            revoke = script.index(' apply >/dev/null')
            assert start < revoke, 'scheduled after the revocation'
            assert m._DOCKER_RESTART_POLICY_SCRIPT in script
            assert '--on-active=5' in script and 'start --no-block docker.service' in script
            r = subprocess.run(['sh', '-n', '-c', script])
            assert r.returncode == 0, 'shell syntax'
            """, Self.agentd.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(py.terminationStatus == 0, "\(msg)")
    }
}
