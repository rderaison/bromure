import Foundation
import NIOCore
import Testing
@testable import ACLinux

/// Test stand-ins for the shared switch (VMNetSwitch, which comes through
/// ACCore): just enough L2/L3 to put several VMs behind one uplink.

func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }
func ipString(_ b: [UInt8]) -> String { b.map(String.init).joined(separator: ".") }
func macBytes(_ s: String) -> [UInt8] { s.split(separator: ":").map { UInt8($0, radix: 16)! } }

/// The tests use the library's interim switch (a stand-in for VMNetSwitch).
typealias TestSwitch = InterimSwitch

/// Runs `cmd` in the guest over one of agentd's 5800 pool connections (the
/// ShellBridge protocol: u32 big-endian length + JSON each way).
func guestShell(_ conn: VsockConnection, _ cmd: String, timeout: Int = 60) async throws -> (exitCode: Int, output: String) {
    try await conn.withStreams { inbound, outbound in
        let req = try JSONSerialization.data(withJSONObject: ["cmd": cmd, "timeout": timeout])
        var buf = ByteBuffer()
        buf.writeInteger(UInt32(req.count))
        buf.writeBytes(req)
        try await outbound.write(buf)
        var acc = ByteBuffer()
        for try await chunk in inbound {
            var c = chunk
            acc.writeBuffer(&c)
            if let n = acc.getInteger(at: acc.readerIndex, as: UInt32.self), acc.readableBytes >= 4 + Int(n) {
                let body = Data(acc.getBytes(at: acc.readerIndex + 4, length: Int(n))!)
                let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                let out = (obj["stdout"] as? String ?? "") + (obj["stderr"] as? String ?? "")
                return ((obj["exit_code"] as? Int) ?? -1, out + (obj["output"] as? String ?? ""))
            }
        }
        return (-1, "connection closed")
    }
}

/// The next connection from `stream` for a shell request (agentd's pool
/// refills itself; each connection serves one request). A pooled connection
/// agentd has since dropped (it recycles idle ones) is skipped.
/// NOTE: this test helper retries even after a request was written, so a
/// command can run twice. Fine for the idempotent probes here; production
/// exec (GuestShell.exec) never retries a written request.
func shell(_ stream: ConnQueue, _ cmd: String, timeout: Int = 60) async throws -> (exitCode: Int, output: String) {
    var lastError: Error?
    for _ in 0..<32 {
        guard let c = await next(stream, timeout: .seconds(30)) else { return (-1, "no pool connection") }
        if !c.channel.channel.isActive { await c.close(); continue }
        do {
            let r = try await guestShell(c, cmd, timeout: timeout)
            if r.exitCode == -1 && r.output == "connection closed" { continue }
            return r
        } catch {
            lastError = error
        }
    }
    throw lastError ?? ChannelError.alreadyClosed
}

/// Guest-side probe against net-test-services.py on host:base: throughput
/// (MB/s over `mib` MiB), TCP request/response RTT (µs), reachability.
func probeScript(host: String, base: Int, mib: Int = 1024, timeout: Int = 120) -> String {
    """
    python3 - <<'PY'
    import socket, time
    H, B = "\(host)", \(base)
    print("HELLO", socket.create_connection((H, B + 2), timeout=5).recv(100).decode().strip())
    s = socket.create_connection((H, B), timeout=\(timeout)); buf = bytes(1 << 20); t = time.time()
    for _ in range(\(mib)): s.sendall(buf)
    s.shutdown(socket.SHUT_WR); got = int(s.recv(64)); dt = time.time() - t
    print("THROUGHPUT_MBPS %.0f (%d bytes in %.2fs)" % (got / dt / 1e6, got, dt))
    e = socket.create_connection((H, B + 1), timeout=5); e.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    for _ in range(100): e.sendall(b"x"); e.recv(1)
    t = time.time(); N = 2000
    for _ in range(N): e.sendall(b"x"); e.recv(1)
    print("RTT_US %.1f" % ((time.time() - t) / N * 1e6))
    PY
    """
}

/// A process's CPU seconds (user + system) from /proc.
func cpuSeconds(pid: Int32) -> Double {
    guard let s = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
          let close = s.lastIndex(of: ")") else { return 0 }
    let f = s[s.index(after: close)...].split(separator: " ")
    let ticks = (Double(f[11]) ?? 0) + (Double(f[12]) ?? 0)      // utime, stime
    return ticks / Double(sysconf(Int32(_SC_CLK_TCK)))
}

func selfCPUSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF.rawValue, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
        + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

/// Stops a helper started with Foundation's Process. SIGKILL: Foundation
/// starts children with nearly every signal blocked, SIGTERM included.
func stopHelper(_ p: Process) {
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
}

/// Starts linux/net-test-services.py on ip:base (as this user) and waits for it.
func startServices(ip: String, base: Int) async throws -> Process {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("net-test-services.py").path
    let ready = "/tmp/acl-svc-\(UUID().uuidString.prefix(8))"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", script, ip, "\(base)", ready]
    // Not the test runner's stdout: a service outliving a failed test would
    // hold swift test's pipe open, and it would wait for EOF forever.
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try p.run()
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready) { try await Task.sleep(for: .milliseconds(20)) }
    try? FileManager.default.removeItem(atPath: ready)
    return p
}

/// The host's IPv4 source address toward the outside (its LAN address).
func hostLANAddress() -> String? {
    guard let out = try? ChildProcess.capture("/usr/sbin/ip", ["-4", "-o", "route", "get", "1.1.1.1"], input: nil) else { return nil }
    let s = String(decoding: out, as: UTF8.self).split(separator: " ")
    guard let i = s.firstIndex(of: "src"), i + 1 < s.count else { return nil }
    return String(s[i + 1])
}
