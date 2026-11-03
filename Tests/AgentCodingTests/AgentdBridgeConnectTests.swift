import Foundation
import Testing

/// agentd's vm-bridge (the guest's 127.0.0.1:65534 proxy and its unix-socket
/// bridges) against a host that accepts vsock connections slowly. It used to
/// give up at the kernel's 2 s connect timeout and close the client with its
/// CONNECT line unread — a reset ("connection reset by peer", curl 56) under
/// any parallel load (docker push, API discovery).
@Suite("agentd bridge connect")
struct AgentdBridgeConnectTests {
    /// agentd's bridge helpers, from `_bridge_log` up to `_BridgeConn`,
    /// extracted from the shipped script.
    private func bridgeHelpers() throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let src = try String(contentsOf: script, encoding: .utf8)
        let start = try #require(src.range(of: "def _bridge_log("))
        let end = try #require(src.range(of: "class _BridgeConn(", range: start.upperBound..<src.endIndex))
        return String(src[start.lowerBound..<end.lowerBound])
    }

    /// Runs `body` after the helpers; nil when this host has no python3.
    private func run(_ body: String) throws -> [String: Any]? {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let py = """
            import errno, json, socket, struct, sys, threading, time
            HOST_CID = 2
            BRIDGE_LOG_PATH = \(String(reflecting: log))
            \(try bridgeHelpers())

            class Clock(object):
                def __init__(self): self.t = 0.0
                def now(self): return self.t
                def sleep(self, d): self.t += d

            class FakeVsock(object):
                # `script`: a list of (errno or None, seconds the connect takes).
                def __init__(self, script, clock, made):
                    self.script, self.clock = script, clock
                    made.append(self)
                def setsockopt(self, *a): pass
                def close(self): pass
                def connect(self, addr):
                    err, took = self.script.pop(0) if self.script else (None, 0.0)
                    self.clock.t += took
                    if err is not None:
                        raise OSError(err, "fake")

            def connect_with(script, **kw):
                clock, made = Clock(), []
                try:
                    _vsock_connect(8443, "http", make_socket=lambda: FakeVsock(script, clock, made),
                                   sleep=clock.sleep, clock=clock.now, **kw)
                    return {"ok": True, "tries": len(made), "t": clock.t}
                except OSError as e:
                    return {"ok": False, "errno": e.errno, "tries": len(made), "t": clock.t}

            out = {}
            \(body)
            out["log"] = open(BRIDGE_LOG_PATH).read() if __import__("os").path.exists(BRIDGE_LOG_PATH) else ""
            print(json.dumps(out))
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", "-c", py]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return nil }   // no python3 on this host
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(errText)")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("a slow host accept is waited out: timed-out connects retry until one lands")
    func timeoutsRetry() throws {
        guard let out = try run("""
            out["r"] = connect_with([(errno.ETIMEDOUT, 15.0), (None, 4.0)])
            """) else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["ok"] as? Bool == true)
        #expect(r["tries"] as? Int == 2)
        let log = out["log"] as? String ?? ""
        #expect(log.contains("attempt 1 failed"))
        #expect(log.contains("took 19.05s (2 attempts)"))
    }

    @Test("a host that never accepts fails at the deadline, not at 2 s")
    func timeoutsStopAtDeadline() throws {
        guard let out = try run("""
            out["r"] = connect_with([(errno.ETIMEDOUT, 15.0)] * 10)
            """) else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["ok"] as? Bool == false)
        #expect(r["errno"] as? Int == Int(ETIMEDOUT))
        let t = try #require(r["t"] as? Double)
        #expect(t >= 30 && t < 31)
    }

    @Test("nothing listening is reported within the short refused window")
    func refusedStopsEarly() throws {
        guard let out = try run("""
            out["r"] = connect_with([(errno.ECONNRESET, 0.0)] * 100)
            """) else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["ok"] as? Bool == false)
        #expect(r["errno"] as? Int == Int(ECONNRESET))
        let t = try #require(r["t"] as? Double)
        #expect(t < 2.5)
    }

    @Test("an unexpected error is not retried")
    func otherErrorsRaise() throws {
        guard let out = try run("""
            out["r"] = connect_with([(errno.EACCES, 0.0)])
            """) else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["ok"] as? Bool == false)
        #expect(r["tries"] as? Int == 1)
    }

    /// The client half of a loopback TCP pair whose server half was refused
    /// with `label`: what the client read, and whether it saw a reset.
    private let refusedPair = """
        def refused(label):
            ls = socket.socket(); ls.bind(("127.0.0.1", 0)); ls.listen(1)
            c = socket.create_connection(ls.getsockname())
            s, _ = ls.accept()
            c.sendall(b"CONNECT registry.example:443 HTTP/1.1\\r\\nHost: registry.example:443\\r\\n\\r\\n")
            time.sleep(0.05)   # the request sits unread in the bridge's queue
            done = threading.Thread(target=_bridge_refuse, args=(s, label, "connect failed", 0.5))
            done.start()
            got, reset = b"", False
            c.settimeout(3)
            try:
                while True:
                    chunk = c.recv(65536)
                    if not chunk: break
                    got += chunk
            except ConnectionResetError:
                reset = True
            c.close(); done.join(); ls.close()
            return {"got": got.decode("utf-8", "replace"), "reset": reset}
        """

    @Test("a proxy client the host couldn't take reads a 503, not a reset")
    func httpGets503() throws {
        guard let out = try run(refusedPair + "\nout['r'] = refused('http')") else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["reset"] as? Bool == false)
        let got = r["got"] as? String ?? ""
        #expect(got.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        #expect(got.contains("Retry-After: 1\r\n"))
        #expect(got.contains("Connection: close\r\n"))
    }

    @Test("an ssh-agent client the host couldn't take sees a clean close")
    func sshGetsCleanClose() throws {
        guard let out = try run(refusedPair + "\nout['r'] = refused('ssh')") else { return }
        let r = try #require(out["r"] as? [String: Any])
        #expect(r["reset"] as? Bool == false)
        #expect(r["got"] as? String == "")
    }

    @Test("bridge log lines carry a UTC timestamp")
    func logTimestamped() throws {
        guard let out = try run("_bridge_log('[http] hello')") else { return }
        let log = out["log"] as? String ?? ""
        #expect(log.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \[http\] hello\n$"#,
                          options: .regularExpression) != nil)
    }
}
