import Foundation
import NIOCore
import Testing
import ACLinux

/// Test stand-ins for the shared switch (VMNetSwitch, which comes through
/// ACCore): just enough L2/L3 to put several VMs behind one uplink.

func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }
func ipString(_ b: [UInt8]) -> String { b.map(String.init).joined(separator: ".") }
func macBytes(_ s: String) -> [UInt8] { s.split(separator: ":").map { UInt8($0, radix: 16)! } }

/// DHCP for the test subnet: a lease per client MAC (.2, .3, …), broadcast
/// replies, router = the gateway, a DNS server, and an MTU (option 26).
final class TestDHCP: Sendable {
    let server: [UInt8], dns: [UInt8], serverMAC: [UInt8]
    let mtu: @Sendable ([UInt8]) -> Int?
    private let leases = NIOLockedValueBoxShim<[[UInt8]: [UInt8]]>([:])
    private let acked = NIOLockedValueBoxShim<[[UInt8]: ContinuousClock.Instant]>([:])

    init(server: [UInt8], dns: [UInt8], serverMAC: [UInt8], mtu: @escaping @Sendable ([UInt8]) -> Int? = { _ in nil }) {
        self.server = server; self.dns = dns; self.serverMAC = serverMAC; self.mtu = mtu
    }

    func lease(for mac: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        leases.mutate { l in
            if let ip = l[mac] { out = ip; return }
            let ip = Array(server[0..<3]) + [UInt8(2 + l.count)]
            l[mac] = ip
            out = ip
        }
        return out
    }
    /// MAC -> IP of everyone leased so far.
    var table: [[UInt8]: [UInt8]] { leases.value }
    func ackedAt(_ mac: [UInt8]) -> ContinuousClock.Instant? { acked.value[mac] }

    /// The reply to `frame` if it's a DHCP request from a client, else nil.
    func handle(_ f: Data) -> Data? {
        let b = [UInt8](f)
        guard b.count >= 14 + 20 + 8 + 240, b[12] == 0x08, b[13] == 0x00, b[23] == 17 else { return nil }
        let udp = 14 + Int(b[14] & 0x0F) * 4
        guard b.count >= udp + 8 + 240, b[udp] == 0, b[udp + 1] == 68, b[udp + 2] == 0, b[udp + 3] == 67 else { return nil }
        let bootp = udp + 8
        guard b[bootp] == 1, Array(b[bootp + 236..<bootp + 240]) == [99, 130, 83, 99] else { return nil }
        var type: UInt8 = 0
        var i = bootp + 240
        while i + 1 < b.count, b[i] != 255 {
            if b[i] == 0 { i += 1; continue }
            if b[i] == 53, i + 2 < b.count { type = b[i + 2] }
            i += 2 + Int(b[i + 1])
        }
        let chaddr = Array(b[bootp + 28..<bootp + 34])
        let yiaddr = lease(for: chaddr)
        let reply: UInt8
        switch type {
        case 1: reply = 2                                     // DISCOVER -> OFFER
        case 3: reply = 5                                     // REQUEST -> ACK
            acked.mutate { if $0[chaddr] == nil { $0[chaddr] = .now } }
        default: return nil
        }
        var p = [UInt8](repeating: 0, count: 236)
        p[0] = 2; p[1] = 1; p[2] = 6
        p[4..<8] = b[bootp + 4..<bootp + 8]                   // xid
        p[10..<12] = b[bootp + 10..<bootp + 12]               // flags
        p[16..<20] = yiaddr[0..<4]
        p[20..<24] = server[0..<4]
        p[28..<44] = b[bootp + 28..<bootp + 44]               // chaddr
        p += [99, 130, 83, 99, 53, 1, reply, 54, 4] + server + [51, 4, 0, 0, 0x0E, 0x10,
              1, 4, 255, 255, 255, 0, 3, 4] + server + [6, 4] + dns
        if let m = mtu(chaddr) { p += [26, 2, UInt8(m >> 8), UInt8(m & 0xFF)] }
        p += [255]
        if p.count < 300 { p += [UInt8](repeating: 0, count: 300 - p.count) }
        let udpLen = 8 + p.count
        var ip: [UInt8] = [0x45, 0, UInt8((20 + udpLen) >> 8), UInt8((20 + udpLen) & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0]
            + server + [255, 255, 255, 255]
        var sum = 0
        for k in stride(from: 0, to: 20, by: 2) { sum += Int(ip[k]) << 8 | Int(ip[k + 1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        ip[10] = UInt8((~sum >> 8) & 0xFF); ip[11] = UInt8(~sum & 0xFF)
        let u: [UInt8] = [0, 67, 0, 68, UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]
        return Data([255, 255, 255, 255, 255, 255] + serverMAC + [0x08, 0x00] + ip + u + p)
    }
}

/// N VM ports and one uplink. VM -> uplink as is (DHCP answered locally);
/// uplink -> VM by destination IP (the uplink sees one "guest" MAC at most,
/// e.g. passt keeps only the last one it saw), ARP by target IP, broadcast to all.
final class TestSwitch: Sendable {
    let dhcp: TestDHCP
    let uplink: any Uplink
    private let ports = NIOLockedValueBoxShim<[(mac: [UInt8], port: StreamPort)]>([])
    private let tasks = NIOLockedValueBoxShim<[Task<Void, Never>]>([])

    init(uplink: any Uplink, gateway: String, dns: String, mtu: @escaping @Sendable ([UInt8]) -> Int? = { _ in nil }) {
        self.uplink = uplink
        dhcp = TestDHCP(server: ipv4(gateway), dns: ipv4(dns),
                        serverMAC: macBytes(uplink.gatewayMAC ?? "9a:55:9a:55:9a:55"), mtu: mtu)
        let t = Task { [ports, dhcp] in
            for await f in uplink.frames {
                let b = [UInt8](f)
                guard b.count >= 14 else { continue }
                let all = ports.value
                var target: [UInt8]?
                if b[12] == 0x08, b[13] == 0x00, b.count >= 34 { target = Array(b[30..<34]) }
                else if b[12] == 0x08, b[13] == 0x06, b.count >= 42 { target = Array(b[38..<42]) }
                if let target, let mac = dhcp.table.first(where: { $0.value == target })?.key,
                   let p = all.first(where: { $0.mac == mac }) {
                    var out = b
                    if b[0] & 1 == 0 { out.replaceSubrange(0..<6, with: mac) }
                    p.port.send(Data(out))
                } else {
                    for p in all { p.port.send(f) }
                }
            }
        }
        tasks.mutate { $0.append(t) }
    }

    func attach(_ port: StreamPort, mac: String) {
        ports.mutate { $0.append((macBytes(mac), port)) }
        let t = Task { [dhcp, uplink] in
            for await f in port.frames {
                if let r = dhcp.handle(f) { port.send(r) } else { uplink.send(f) }
            }
        }
        tasks.mutate { $0.append(t) }
    }

    func stop() { for t in tasks.value { t.cancel() } }
}

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
func probeScript(host: String, base: Int, mib: Int = 1024) -> String {
    """
    python3 - <<'PY'
    import socket, time
    H, B = "\(host)", \(base)
    print("HELLO", socket.create_connection((H, B + 2), timeout=5).recv(100).decode().strip())
    s = socket.create_connection((H, B), timeout=30); buf = bytes(1 << 20); t = time.time()
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ip")
    p.arguments = ["-4", "-o", "route", "get", "1.1.1.1"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")
    guard let i = s.firstIndex(of: "src"), i + 1 < s.count else { return nil }
    return String(s[i + 1])
}
