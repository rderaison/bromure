import Foundation
import NIOCore
import Testing
import ACLinux

/// StreamPort <-> TapUplink with a two-port forwarder standing in for the
/// switch, and a minimal DHCP server standing in for the switch's own.
/// Needs the tap that linux/setup-network.sh makes, in a network namespace:
/// linux/test-network.sh sets that up (as root) and runs this with
/// BROMURE_NET_TEST=1.
enum NetEnv {
    static let env = ProcessInfo.processInfo.environment
    static var ready: Bool { Env.ready && env["BROMURE_NET_TEST"] == "1" }
    static var tap: String { env["BROMURE_TAP"] ?? "bromure0" }
    /// The DNS server handed out: a listener on the far side of the uplink
    /// proves forwarding + masquerade (test-network.sh checks its log).
    static var dns: [UInt8] { ipv4(env["BROMURE_TEST_DNS"] ?? "192.168.64.1") }
    static var wanLog: String? { env["BROMURE_WAN_LOG"] }

    static func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }
}

/// Answers DHCPDISCOVER with an OFFER and DHCPREQUEST with an ACK: one
/// fixed lease, broadcast replies (RFC 2131 §4.1 lets any client take them).
final class TestDHCP: Sendable {
    let server: [UInt8], offer: [UInt8], router: [UInt8], dns: [UInt8], serverMAC: [UInt8]
    private let acked = NIOLockedValueBoxShim<ContinuousClock.Instant?>(nil)

    init(server: [UInt8], offer: [UInt8], dns: [UInt8], serverMAC: [UInt8]) {
        self.server = server; self.offer = offer; self.router = server; self.dns = dns; self.serverMAC = serverMAC
    }

    var ackedAt: ContinuousClock.Instant? { acked.value }

    /// The reply to `frame` if it's a DHCP request from a client, else nil.
    func handle(_ f: Data) -> Data? {
        let b = [UInt8](f)
        guard b.count >= 14 + 20 + 8 + 240, b[12] == 0x08, b[13] == 0x00, b[23] == 17 else { return nil }
        let ihl = Int(b[14] & 0x0F) * 4
        let udp = 14 + ihl
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
        let reply: UInt8
        switch type {
        case 1: reply = 2        // DISCOVER -> OFFER
        case 3: reply = 5        // REQUEST -> ACK
            acked.mutate { if $0 == nil { $0 = .now } }
        default: return nil
        }
        var p = [UInt8](repeating: 0, count: 236)
        p[0] = 2; p[1] = 1; p[2] = 6
        p[4..<8] = b[bootp + 4..<bootp + 8]              // xid
        p[10..<12] = b[bootp + 10..<bootp + 12]          // flags
        p[16..<20] = offer[0..<4]                        // yiaddr
        p[20..<24] = server[0..<4]                       // siaddr
        p[28..<44] = b[bootp + 28..<bootp + 44]          // chaddr
        p += [99, 130, 83, 99,
              53, 1, reply, 54, 4] + server + [51, 4, 0, 0, 0x0E, 0x10,
              1, 4, 255, 255, 255, 0, 3, 4] + router + [6, 4] + dns + [255]
        if p.count < 300 { p += [UInt8](repeating: 0, count: 300 - p.count) }
        let udpLen = 8 + p.count
        var ip: [UInt8] = [0x45, 0, UInt8((20 + udpLen) >> 8), UInt8((20 + udpLen) & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0]
            + server + [255, 255, 255, 255]
        var sum = 0
        for k in stride(from: 0, to: 20, by: 2) { sum += Int(ip[k]) << 8 | Int(ip[k + 1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        ip[10] = UInt8((~sum >> 8) & 0xFF); ip[11] = UInt8(~sum & 0xFF)
        let u: [UInt8] = [0, 67, 0, 68, UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]   // no UDP checksum
        return Data([255, 255, 255, 255, 255, 255] + serverMAC + [0x08, 0x00] + ip + u + p)
    }
}

@Suite("Network bridge: stream port <-> tap", .serialized, .enabled(if: NetEnv.ready))
struct BridgeTests {
    @Test("the guest leases an address over the stream port, is pingable from the host, and agentd dials promptly",
          arguments: [QEMUMachineConfig.MachineType.q35, .microvm])
    func bridge(machine: QEMUMachineConfig.MachineType) async throws {
        var ws = try BootTests.Workspace(machine: machine)
        defer { ws.cleanUp() }
        let label = "[bridge \(machine.rawValue) cid \(ws.cid)]"
        let netSock = ws.dir + "/run/net.sock"
        ws.config.network = .stream(socketPath: netSock)
        ws.config.macAddress = "52:54:00:b0:00:\(String(format: "%02x", ws.cid & 0xFF))"

        let port = try await StreamPort.listen(path: netSock)
        let tap = try TapUplink.open(name: NetEnv.tap)
        defer { tap.close() }
        let mac = try #require(tap.hostMAC).split(separator: ":").map { UInt8($0, radix: 16)! }
        let guestIP: [UInt8] = [192, 168, 64, 2]
        let dhcp = TestDHCP(server: [192, 168, 64, 1], offer: guestIP, dns: NetEnv.dns, serverMAC: mac)

        // The two-port "switch": DHCP is answered here, everything else crosses.
        let up = Task {
            for await f in port.frames {
                if let r = dhcp.handle(f) { port.send(r) } else { tap.send(f) }
            }
        }
        let down = Task { for await f in tap.frames { port.send(f) } }
        defer { up.cancel(); down.cancel() }

        let wanBefore = NetEnv.wanLog.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.count ?? 0
        let listener = try await VsockListener.shared(port: agentPort)
        let cid = ws.cid
        let conns = await listener.connections(from: cid)
        defer { Task { await listener.forget(cid: cid) } }
        let vm = QEMUMachine(config: ws.config)
        let t0 = ContinuousClock.now
        try await vm.start()
        let dial = await next(conns, timeout: .seconds(150))
        let tDial = ContinuousClock.now - t0
        try #require(dial != nil, "\(label) agentd never dialed")
        let acked = try #require(dhcp.ackedAt, "\(label) no DHCPREQUEST answered")
        print("TIMING \(label) DHCP ACK at \(ms(acked - t0)), agentd dial on :\(agentPort) at \(ms(tDial)) (stream netdev, \(port.connects) QEMU connect(s))")
        #expect(tDial < .seconds(30), "\(label) agentd dial took \(ms(tDial)): the network-online stall is back")

        // Host -> guest over the tap and the stream port.
        let ping = Process()
        ping.executableURL = URL(fileURLWithPath: "/usr/bin/ping")
        ping.arguments = ["-c", "3", "-i", "0.2", "-W", "2", guestIP.map(String.init).joined(separator: ".")]
        let out = Pipe()
        ping.standardOutput = out
        ping.standardError = out
        try ping.run()
        ping.waitUntilExit()
        let pingText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(ping.terminationStatus == 0, "\(label) ping failed:\n\(pingText)")
        if let rtt = pingText.split(separator: "\n").last(where: { $0.contains("rtt") }) {
            print("TIMING \(label) ping 192.168.64.2: \(rtt)")
        }

        // Guest -> uplink, forwarded and masqueraded: through agentd's shell
        // (the 5800 connection it just dialed), the guest sends a DNS-shaped
        // UDP datagram to the listener test-network.sh runs beyond the uplink.
        if let wanLog = NetEnv.wanLog, let shell = dial {
            let dnsIP = NetEnv.dns.map(String.init).joined(separator: ".")
            let r = try await guestShell(shell, """
                ip -4 -br addr show scope global; ip -4 route show default; \
                python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); \
                s.sendto(b'\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x08bromure1\\x04test\\x00\\x00\\x01\\x00\\x01', ('\(dnsIP)', 53))"
                """)
            print("GUEST \(label) exit \(r.exitCode): \(r.output.replacingOccurrences(of: "\n", with: " | "))")
            #expect(r.exitCode == 0)
            #expect(r.output.contains("192.168.64.2/24"), "\(label) guest address: \(r.output)")
            #expect(r.output.contains("default via 192.168.64.1"), "\(label) guest route: \(r.output)")
            var seen = ""
            for _ in 0..<300 where seen.isEmpty {
                seen = String(((try? String(contentsOfFile: wanLog, encoding: .utf8)) ?? "").dropFirst(wanBefore))
                if seen.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(!seen.isEmpty, "\(label) no guest DNS query reached the far side of the uplink")
            print("NAT \(label) beyond the uplink: \(seen.split(separator: "\n").first ?? "")")
        }

        #expect(port.dropped == 0)
        #expect(tap.sendErrors == 0)
        await vm.stop(timeout: .seconds(20))
        await port.close()
    }
}

/// Runs `cmd` in the guest over one of agentd's 5800 pool connections (the
/// ShellBridge protocol: u32 big-endian length + JSON each way).
func guestShell(_ conn: VsockConnection, _ cmd: String, timeout: Int = 20) async throws -> (exitCode: Int, output: String) {
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
