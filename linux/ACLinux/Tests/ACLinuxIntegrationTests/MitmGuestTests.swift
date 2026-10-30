import Foundation
import Testing
import ACLinux

/// The Phase 4 TLS-interception spike on the real path: a guest behind passt,
/// trusting the spike CA, uses linux/spike/mitm's proxy (on the host's LAN
/// address, as http(s)_proxy) for real HTTPS. Needs BROMURE_MITM_PROXY = the
/// built mitm-proxy binary, and Internet access.
enum MitmEnv {
    static var proxyBinary: String? { ProcessInfo.processInfo.environment["BROMURE_MITM_PROXY"] }
    static var ready: Bool { NetEnv.passtReady && proxyBinary.map { FileManager.default.isExecutableFile(atPath: $0) } == true }
}

@Suite("TLS interception from a guest (spike)", .serialized, .enabled(if: MitmEnv.ready))
struct MitmGuestTests {
    @Test("curl (h2, http/1.1), Python urllib and a WebSocket upgrade through the intercepting proxy")
    func guestThroughProxy() async throws {
        let dir = "/tmp/acl-mitm-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/ca", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lan = try #require(hostLANAddress())
        let port = 42_000 + Int.random(in: 0..<2000)

        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: MitmEnv.proxyBinary!)
        proxy.arguments = ["--listen", "\(lan):\(port)", "--ca-dir", dir + "/ca"]
        proxy.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proxy.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try proxy.run()
        defer { stopHelper(proxy) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir + "/ca/ca.pem") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let caPEM = try String(contentsOfFile: dir + "/ca/ca.pem", encoding: .utf8)

        let passt = try await PasstUplink.start(.init())
        let sw = TestSwitch(uplink: passt, gateway: "192.168.64.1", dns: "192.168.64.1")
        let listener = try await VsockListener.shared(port: agentPort)
        let v = try await SwitchedVM.make(.microvm, mac: "52:54:00:d0:00:01", on: sw, listener: listener,
                                          tag: "mitm", mtu: passt.mtu)
        _ = try await v.boot()

        // Trust the spike CA system-wide in the guest (what the real image does
        // for the Bromure CA).
        let trust = try await shell(v.conns, """
            sudo tee /usr/local/share/ca-certificates/bromure-spike.crt >/dev/null <<'PEM'
            \(caPEM)
            PEM
            sudo update-ca-certificates 2>&1 | tail -1
            """)
        #expect(trust.exitCode == 0, "\(trust.output)")

        let px = "http://\(lan):\(port)"
        let r = try await shell(v.conns, """
            for u in https://example.com/ https://pypi.org/simple/requests/ https://github.com/; do
              curl -sS -o /dev/null -x \(px) -w "CURL %{http_version} %{http_code} %{time_appconnect}s $u\\n" $u
            done
            curl -sS -o /dev/null --http1.1 -x \(px) -w "CURL-H1 %{http_version} %{http_code}\\n" https://example.com/
            curl -sS -o /dev/null -x \(px) -w "ISSUER " https://example.com/ -v 2>&1 | grep -m1 'issuer:' || true
            https_proxy=\(px) python3 - <<'PY'
            import urllib.request, ssl, socket
            r = urllib.request.urlopen("https://pypi.org/simple/requests/", timeout=20)
            print("PYTHON", r.status, len(r.read()), "bytes")
            # WebSocket upgrade through the CONNECT tunnel (the bytes are relayed untouched).
            for host, path in (("echo.websocket.org", "/"), ("ws.postman-echo.com", "/raw")):
                try:
                    s = socket.create_connection(("\(lan)", \(port)), timeout=10)
                    s.sendall(f"CONNECT {host}:443 HTTP/1.1\\r\\nHost: {host}:443\\r\\n\\r\\n".encode())
                    assert b" 200 " in s.recv(4096)
                    t = ssl.create_default_context().wrap_socket(s, server_hostname=host)
                    t.sendall((f"GET {path} HTTP/1.1\\r\\nHost: {host}\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
                               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n").encode())
                    print("WEBSOCKET", host, t.recv(4096).split(b"\\r\\n")[0].decode())
                    break
                except Exception as e:
                    print("WEBSOCKET", host, "error", type(e).__name__, e)
            PY
            """, timeout: 120)
        print("MITM \(v.label)\n" + r.output)
        #expect(r.output.components(separatedBy: "CURL 2 200").count >= 2, "h2 through the proxy")
        #expect(r.output.contains("CURL-H1 1.1 200"))
        #expect(r.output.contains("Bromure Spike CA"), "the guest saw the minted leaf")
        #expect(r.output.contains("PYTHON 200"))
        #expect(r.output.contains("101 Switching Protocols"))

        await v.tearDown(listener)
        sw.stop()
        await passt.close()
    }
}
