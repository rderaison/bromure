import Foundation
import NIOConcurrencyHelpers

/// STAND-IN for the shared switch. The real one is VMNetSwitch (MAC learning,
/// its own DHCP, DNS snoop, the MITM interceptor hook), which arrives on Linux
/// through the ACCore carve-out. Until then this does just enough L2/L3 to put
/// VMs behind one uplink:
/// - VM -> uplink as is, except DHCP, which is answered here (a lease per MAC);
/// - uplink -> VM by destination IP (passt keeps a single guest MAC), ARP by
///   target IP, broadcast to every port.
/// No VM-to-VM traffic, no DNS snoop, no egress policy. Don't build on it.
// @port-skip linux-only: interim stand-in for VMNetSwitch until ACCore ships it
public final class InterimSwitch: Sendable {
    public let dhcp: InterimDHCP
    public let uplink: any Uplink
    private let ports = NIOLockedValueBox<[(mac: [UInt8], port: StreamPort, task: Task<Void, Never>)]>([])
    private let downTask: NIOLockedValueBox<Task<Void, Never>?> = .init(nil)

    // @port-skip linux-only: interim switch
    public init(uplink: any Uplink, gateway: String = "192.168.64.1", dns: String = "192.168.64.1",
                mtu: @escaping @Sendable ([UInt8]) -> Int? = { _ in nil }) {
        self.uplink = uplink
        dhcp = InterimDHCP(server: Self.ipv4(gateway), dns: Self.ipv4(dns),
                           serverMAC: Self.mac(uplink.gatewayMAC ?? "9a:55:9a:55:9a:55"), mtu: mtu)
        let t = Task { [ports, dhcp] in
            for await f in uplink.frames {
                let b = [UInt8](f)
                guard b.count >= 14 else { continue }
                let all = ports.withLockedValue { $0 }
                var target: [UInt8]?
                if b[12] == 0x08, b[13] == 0x00, b.count >= 34 { target = Array(b[30..<34]) }
                else if b[12] == 0x08, b[13] == 0x06, b.count >= 42 { target = Array(b[38..<42]) }
                if let target, let mac = dhcp.mac(for: target), let p = all.first(where: { $0.mac == mac }) {
                    var out = b
                    if b[0] & 1 == 0 { out.replaceSubrange(0..<6, with: mac) }
                    p.port.send(Data(out))
                } else {
                    for p in all { p.port.send(f) }
                }
            }
        }
        downTask.withLockedValue { $0 = t }
    }

    /// Plugs a VM's stream port in.
    // @port-skip linux-only: interim switch
    public func attach(_ port: StreamPort, mac: String) {
        let m = Self.mac(mac)
        let t = Task { [dhcp, uplink] in
            for await f in port.frames {
                if let r = dhcp.handle(f) { port.send(r) } else { uplink.send(f) }
            }
        }
        ports.withLockedValue { $0.append((m, port, t)) }
    }

    // @port-skip linux-only: interim switch
    public func detach(mac: String) {
        let m = Self.mac(mac)
        ports.withLockedValue { ps in
            for p in ps where p.mac == m { p.task.cancel() }
            ps.removeAll { $0.mac == m }
        }
    }

    // @port-skip linux-only: interim switch
    public func stop() {
        downTask.withLockedValue { $0?.cancel() }
        ports.withLockedValue { ps in for p in ps { p.task.cancel() } }
    }

    // @port-skip linux-only: interim switch
    static func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").compactMap { UInt8($0) } }
    // @port-skip linux-only: interim switch
    static func mac(_ s: String) -> [UInt8] { s.split(separator: ":").compactMap { UInt8($0, radix: 16) } }
}

/// The interim switch's DHCP server: a lease per client MAC (.2, .3, …),
/// broadcast replies, router = the gateway, a DNS server, an optional MTU.
// @port-skip linux-only: interim stand-in for VMNetSwitch's DHCP
public final class InterimDHCP: Sendable {
    let server: [UInt8], dns: [UInt8], serverMAC: [UInt8]
    let mtu: @Sendable ([UInt8]) -> Int?
    private let leases = NIOLockedValueBox<[[UInt8]: [UInt8]]>([:])
    private let acked = NIOLockedValueBox<[[UInt8]: ContinuousClock.Instant]>([:])

    // @port-skip linux-only: interim DHCP
    init(server: [UInt8], dns: [UInt8], serverMAC: [UInt8], mtu: @escaping @Sendable ([UInt8]) -> Int?) {
        self.server = server; self.dns = dns; self.serverMAC = serverMAC; self.mtu = mtu
    }

    /// The lease for `mac`, assigned on first sight.
    // @port-skip linux-only: interim DHCP
    public func lease(for mac: [UInt8]) -> [UInt8] {
        leases.withLockedValue { l in
            if let ip = l[mac] { return ip }
            let used = Set(l.values.map { $0[3] })
            var host: UInt8 = 2
            while used.contains(host) { host += 1 }
            let ip = Array(server[0..<3]) + [host]
            l[mac] = ip
            return ip
        }
    }

    /// The lease for `mac` as a dotted quad, if one was handed out.
    // @port-skip linux-only: interim DHCP
    public func leasedIP(for mac: String) -> String? {
        leases.withLockedValue { $0[InterimSwitch.mac(mac)] }.map { $0.map(String.init).joined(separator: ".") }
    }

    // @port-skip linux-only: interim DHCP
    public func release(mac: String) { _ = leases.withLockedValue { $0.removeValue(forKey: InterimSwitch.mac(mac)) } }

    // @port-skip linux-only: interim DHCP
    func mac(for ip: [UInt8]) -> [UInt8]? { leases.withLockedValue { $0.first(where: { $0.value == ip })?.key } }

    // @port-skip linux-only: interim DHCP
    public func ackedAt(_ mac: [UInt8]) -> ContinuousClock.Instant? { acked.withLockedValue { $0[mac] } }

    /// The reply to `frame` if it's a DHCP request from a client, else nil.
    // @port-skip linux-only: interim DHCP
    public func handle(_ f: Data) -> Data? {
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
            acked.withLockedValue { if $0[chaddr] == nil { $0[chaddr] = .now } }
        default: return nil
        }
        var p = [UInt8](repeating: 0, count: 236)
        p[0] = 2; p[1] = 1; p[2] = 6
        p[4..<8] = b[bootp + 4..<bootp + 8]
        p[10..<12] = b[bootp + 10..<bootp + 12]
        p[16..<20] = yiaddr[0..<4]
        p[20..<24] = server[0..<4]
        p[28..<44] = b[bootp + 28..<bootp + 44]
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
