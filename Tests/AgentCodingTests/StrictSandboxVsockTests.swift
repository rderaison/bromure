import Foundation
import Testing
@testable import bromure_ac

/// Under the strict sandbox (OpenShell's process layer) the main seccomp filter
/// refuses `socket(AF_VSOCK, …)`, as OpenShell's does: with vsock, a confined
/// process could reach every port the host listens on — the shell pool whose
/// connections carry the host's commands, the attestor, the sentry's stream —
/// and pose as the guest's own services. The helpers the agent starts that must
/// reach the host (its Bromure MCP servers, the plan driver) ask agentd instead,
/// which runs outside the sandbox and relays those ports only.
@Suite("The strict sandbox bans vsock; agentd relays Bromure's helpers")
struct StrictSandboxVsockTests {
    private static let setup = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.setup.appendingPathComponent(name), encoding: .utf8)
    }
    private static let python = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    /// The relay on a temporary socket, a fake host behind it (a TCP echo per
    /// port; those in DOWN refuse), then `body`. Prints what `body` prints.
    private func harness(_ body: String, args: [String] = [], env: [String: String] = [:]) throws -> String {
        let prelude = """
            import importlib.util, sys, os, socket, threading, json, errno, tempfile, time, subprocess
            def load(name, path):
                s = importlib.util.spec_from_file_location(name, path)
                m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
                return m
            m = load('agentd', sys.argv[1])
            m._bridge_log = lambda *a: None
            srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(16)
            def serve():
                while True:
                    c, _ = srv.accept()
                    def echo(c):
                        while True:
                            d = c.recv(65536)
                            if not d:
                                break
                            c.sendall(d)
                        c.close()
                    threading.Thread(target=echo, args=(c,), daemon=True).start()
            threading.Thread(target=serve, daemon=True).start()
            asked = []
            DOWN = set()
            def fake_connect(port, label, **kw):
                asked.append(port)
                if port in DOWN:
                    raise OSError(errno.ECONNREFUSED, "refused")
                return socket.create_connection(srv.getsockname())
            m._vsock_connect = fake_connect
            RELAY = tempfile.mktemp(prefix="bvr", dir="/tmp")
            threading.Thread(target=m.vsock_relay_service, args=(RELAY,), daemon=True).start()
            for _ in range(100):
                if os.path.exists(RELAY):
                    break
                time.sleep(0.02)
            def ask(header, payload=b""):
                c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(10)
                c.connect(RELAY); c.sendall(header + payload)
                if payload:
                    c.shutdown(socket.SHUT_WR)
                out = b""
                while True:
                    d = c.recv(65536)
                    if not d:
                        break
                    out += d
                c.close()
                return out.decode()

            """
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", prelude + body, Self.setup.appendingPathComponent("bromure-agentd.py").path] + args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        py.environment = environment
        let pipe = Pipe()
        py.standardOutput = pipe
        py.standardError = FileHandle.nullDevice
        try py.run()
        let killer = DispatchWorkItem { if py.isRunning { py.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        py.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the sandbox bans AF_VSOCK, as OpenShell does")
    func vsockBanned() throws {
        let osh = try source("bromure_openshell.py")
        #expect(osh.contains("def build_main_filter_rules(allow_inet=True, allow_vsock=False):"))
        #expect(osh.contains("blocked_domains = [AF_PACKET, AF_BLUETOOTH]\n    if not allow_vsock:\n        blocked_domains.append(AF_VSOCK)"))
        #expect(osh.contains("child_hardening=True, allow_vsock=False):"))
        #expect(osh.contains("build_main_filter_rules(allow_inet, allow_vsock)"))
        #expect(osh.contains("child_hardening=True, allow_inet=True, allow_vsock=False):"))
        #expect(osh.contains("allow_vsock=allow_vsock)"))
        let sandboxd = try source("bromure-sandboxd")
        let call = try #require(sandboxd.range(of: "osh.enforce(prepared, outcome, supervisor_tgid=tgid,"))
        #expect(sandboxd[call.upperBound...].prefix(400).contains("allow_vsock=False)"))
        #expect(!sandboxd.contains("allow_vsock=True"))
        #expect(!osh.contains("allow_vsock=True"))
        // The other socket bans stay.
        #expect(osh.contains("entry(SYS[\"socket\"]).append([(0, OP_EQ, AF_NETLINK), (2, OP_NE, NETLINK_ROUTE)])"))
    }

    @Test("agentd relays exactly the MCP and plan-stream ports, none of the guest's own services",
          .enabled(if: python))
    func relayPorts() throws {
        let out = try harness("print(json.dumps(sorted(m.VSOCK_RELAY_PORTS)))")
        let ports = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Int])
        let mcp: [UInt32] = [SessionDisk.browserMCPVsockPort, SessionDisk.taskBoardMCPVsockPort,
                             SessionDisk.planStreamVsockPort, SessionDisk.automationMCPVsockPort,
                             SessionDisk.kubeMCPVsockPort, SessionDisk.delegationMCPVsockPort,
                             SessionDisk.switchboardMCPVsockPort]
        #expect(Set(ports) == Set(mcp.map(Int.init)))
        // Shell pool, attestor, sentry, MITM and token channels, loopback relay.
        for never in [5800, 5840, 5841, 5000, 5010, 5100, 8443, 8444, 8445, 8446, 8447] {
            #expect(!ports.contains(never), "\(never) must not be relayed")
        }
        #expect(try source("bromure-agentd.py").contains("(\"vsock-relay\", vsock_relay_service),"))
    }

    @Test("the relay splices an allowed port both ways; anything else gets an error line and nothing else",
          .enabled(if: python))
    func relayServes() throws {
        let out = try harness("""
            r = {}
            r["ok"] = ask(b"bromure-vsock 5835\\n", b"ping\\n" + b"x" * 200000)
            r["shell"] = ask(b"bromure-vsock 5800\\n", b"hello\\n")
            r["attestor"] = ask(b"bromure-vsock 5840\\n")
            r["malformed"] = ask(b"GET / HTTP/1.1\\n")
            r["long"] = ask(b"bromure-vsock " + b"9" * 100 + b"\\n")
            DOWN.add(5831)
            r["down"] = ask(b"bromure-vsock 5831\\n")
            r["asked"] = asked
            r["mode"] = oct(os.stat(RELAY).st_mode & 0o777)
            r["ok"] = [r["ok"][:8], len(r["ok"])]
            print(json.dumps(r))
            """)
        let r = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let ok = try #require(r["ok"] as? [Any])
        #expect(ok.first as? String == "ok\nping\n")
        #expect(ok.last as? Int == 3 + 5 + 200_000)
        #expect(r["shell"] as? String == "err port not relayed\n")
        #expect(r["attestor"] as? String == "err port not relayed\n")
        #expect(r["malformed"] as? String == "err malformed request\n")
        #expect(r["long"] as? String == "err malformed request\n")
        #expect(r["down"] as? String == "err host unreachable\n")
        // Refused ports never reach the host.
        #expect(r["asked"] as? [Int] == [5835, 5831])
        #expect(r["mode"] as? String == "0o666")
    }

    @Test("the Swift-built MCP shims reach the host through the relay when AF_VSOCK is refused",
          .enabled(if: python))
    func shimsUseRelay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vsock-shims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scripts = ["browser": SessionDisk.browserMCPShimScript, "task": SessionDisk.taskMCPShimScript,
                       "delegation": SessionDisk.delegationMCPShimScript,
                       "switchboard": SessionDisk.switchboardMCPShimScript,
                       "automations": SessionDisk.automationMCPShimScript, "infra": SessionDisk.kubeMCPShimScript]
        var paths: [String] = []
        for (name, text) in scripts.sorted(by: { $0.key < $1.key }) {
            #expect(!text.contains("socket.socket(socket.AF_VSOCK"), "\(name) opens vsock by itself")
            let url = dir.appendingPathComponent("\(name).py")
            try text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let out = try harness("""
            r = {}
            for path in sys.argv[2:]:
                env = dict(os.environ, BROMURE_VSOCK_RELAY=RELAY)
                env.pop("TMUX_PANE", None)
                # The sandbox's seccomp answer to socket(AF_VSOCK), then the shim as is.
                seccomp = ("import errno, runpy, socket, sys\\n"
                           "real = socket.socket\\n"
                           "def refused(family=-1, *a, **k):\\n"
                           "    if family == 40:\\n"
                           "        raise PermissionError(errno.EPERM, 'Operation not permitted')\\n"
                           "    return real(family, *a, **k)\\n"
                           "socket.socket = refused\\n"
                           "sys.argv = sys.argv[1:]\\n"
                           "runpy.run_path(sys.argv[0], run_name='__main__')\\n")
                p = subprocess.run([sys.executable, "-I", "-c", seccomp, path, "w7"], input=b'{"jsonrpc":"2.0","id":1}\\n',
                                   capture_output=True, env=env, timeout=15)
                r[os.path.basename(path)] = p.stdout.decode()
            r["asked"] = sorted(set(asked))
            print(json.dumps(r))
            """, args: paths)
        let r = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        // The echo host returns what the shim sent: its hello (the window or
        // branch it was given), then the request.
        #expect(r["browser.py"] as? String == "{\"jsonrpc\":\"2.0\",\"id\":1}\n")
        for name in ["task", "delegation", "switchboard", "automations", "infra"] {
            #expect(r["\(name).py"] as? String == "bromure-hello w7\n{\"jsonrpc\":\"2.0\",\"id\":1}\n", "\(name)")
        }
        #expect((r["asked"] as? [Int]).map(Set.init) == [5830, 5831, 5833, 5834, 5835, 5836])
    }

    @Test("the plan driver and browser MCP go direct when vsock is allowed, through the relay when it's refused",
          .enabled(if: python))
    func helpersFallBack() throws {
        let out = try harness("""
            real = socket.socket
            calls = []
            class Direct:
                family = 40
                def __init__(self, *a, **k): pass
                def connect(self, addr): calls.append(addr)
                def close(self): pass
            def allowed(family=-1, *a, **k):
                return Direct() if family == 40 else real(family, *a, **k)
            def refused(family=-1, *a, **k):
                if family == 40:
                    raise PermissionError(errno.EPERM, "Operation not permitted")
                return real(family, *a, **k)
            r = {}
            for name, path, port in (("plan", sys.argv[2], 5832), ("browser", sys.argv[3], 5830)):
                h = load(name, path)
                h.VSOCK_RELAY = RELAY
                h.socket.socket = allowed
                d = h.vsock_connect(port)
                r[name + "_direct"] = [type(d).__name__, list(calls[-1])]
                h.socket.socket = refused
                s = h.vsock_connect(port)
                s.sendall(b"hi\\n"); r[name + "_relay"] = s.recv(16).decode(); s.close()
                h.socket.socket = refused
                try:
                    h.vsock_connect(5800)
                    r[name + "_shell"] = "connected"
                except OSError as e:
                    r[name + "_shell"] = [errno.errorcode.get(e.errno), str(e)]
                h.socket.socket = real
            r["asked"] = asked
            print(json.dumps(r))
            """, args: [Self.setup.appendingPathComponent("bromure-plan-driver.py").path,
                        Self.setup.appendingPathComponent("bromure-browser-mcp.py").path])
        let r = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(r["plan_direct"] as? [AnyHashable] == ["Direct", [2, 5832]])
        #expect(r["browser_direct"] as? [AnyHashable] == ["Direct", [2, 5830]])
        #expect(r["plan_relay"] as? String == "hi\n")
        #expect(r["browser_relay"] as? String == "hi\n")
        for name in ["plan", "browser"] {
            let shell = r["\(name)_shell"] as? [String]
            #expect(shell?.first == "ECONNREFUSED", "\(name): \(String(describing: r["\(name)_shell"]))")
            #expect(shell?.last?.contains("port not relayed") == true)
        }
        #expect(r["asked"] as? [Int] == [5832, 5830])
        // Nothing else in them opens vsock by itself.
        for file in ["bromure-plan-driver.py", "bromure-browser-mcp.py"] {
            #expect(!(try source(file)).contains("socket.socket(socket.AF_VSOCK"), "\(file)")
        }
    }
}
