import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - tun2socks-style userspace TCP forwarder

/// Reads raw IPv4/TCP packets from a utun fd and, for each TCP flow to the routed
/// remote subnet, terminates the connection in userspace and splices it to a
/// `RemoteTransport.forwardDial` SSH channel. This is what actually carries the
/// system-wide tunnel: locally-originated traffic to `192.168.64.x` is routed to
/// the utun (kernel writes the packets to the fd), we speak TCP back to the local
/// kernel, and bridge the payload to the remote guest.
///
/// A pragmatic TCP for a LOSSLESS point-to-point utun: full 3-way handshake, data
/// both ways with the peer's receive window respected, FIN/RST teardown; no
/// retransmission timers (the utun doesn't drop) beyond re-ACKing duplicates.
/// Runs as the invoking user (the daemon only hands over the utun fd), so
/// `forwardDial` uses the user's SSH identity.
final class UtunForwarder {
    private let utunFD: Int32
    private let host: RemoteHost
    private let remoteCIDR: String?
    private let subnet: (net: UInt32, mask: UInt32)?
    /// Opens a byte stream to `(ip, port)` on the remote; default is the SSH
    /// forward channel. Injectable so the forwarder is testable without a remote.
    private let dial: (RemoteHost, String, Int) -> Int32?
    private var running = true
    private let writeLock = NSLock()
    private let flowsLock = NSLock()
    private var flows: [FlowKey: TCPFlow] = [:]

    /// utun frames are prefixed with the 4-byte address family (big-endian AF_INET).
    private static let afHeader: [UInt8] = [0, 0, 0, 2]

    init(utunFD: Int32, host: RemoteHost, localCIDR: String, remoteCIDR: String?,
         dial: @escaping (RemoteHost, String, Int) -> Int32? = { RemoteTransport.forwardDial(host: $0, ip: $1, port: $2) }) {
        self.utunFD = utunFD
        self.host = host
        self.remoteCIDR = remoteCIDR
        self.subnet = UtunForwarder.parseCIDR(localCIDR)
        self.dial = dial
    }

    /// Blocking read loop. Returns when the fd closes or `stop()` is called.
    func run() {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while running {
            let n = read(utunFD, &buf, buf.count)
            if n <= 4 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            guard let seg = UtunPacket.parse(Array(buf[4..<n])) else { continue }
            // Only handle flows into the routed subnet.
            if let s = subnet, (seg.dstIP & s.mask) != (s.net & s.mask) { continue }
            handle(seg)
        }
    }

    func stop() {
        running = false
        flowsLock.lock(); let all = Array(flows.values); flows.removeAll(); flowsLock.unlock()
        for f in all { f.close() }
    }

    // MARK: Packet handling

    private func handle(_ seg: UtunPacket.TCPSegment) {
        let key = FlowKey(seg)
        flowsLock.lock(); let flow = flows[key]; flowsLock.unlock()

        if flow == nil {
            // Only a bare SYN opens a flow; stray packets get a RST.
            if seg.flags & UtunPacket.SYN != 0 && seg.flags & UtunPacket.ACK == 0 {
                openFlow(key, seg)
            } else if seg.flags & UtunPacket.RST == 0 {
                sendRST(to: seg)
            }
            return
        }
        flow!.onInbound(seg)
    }

    private func openFlow(_ key: FlowKey, _ seg: UtunPacket.TCPSegment) {
        let target = UtunForwarder.aliasToRemote(UtunPacket.ipString(seg.dstIP), remoteCIDR: remoteCIDR)
        let flow = TCPFlow(key: key, clientISN: seg.seq, host: host, targetIP: target,
                           targetPort: Int(seg.dstPort), dial: dial,
                           send: { [weak self] s in self?.writePacket(s) },
                           onClosed: { [weak self] k in
                               self?.flowsLock.lock(); self?.flows.removeValue(forKey: k); self?.flowsLock.unlock()
                           })
        flowsLock.lock(); flows[key] = flow; flowsLock.unlock()
        flow.start()
    }

    private func writePacket(_ seg: UtunPacket.TCPSegment) {
        var out = UtunForwarder.afHeader
        out.append(contentsOf: UtunPacket.build(seg))
        writeLock.lock()
        _ = out.withUnsafeBytes { Darwin.write(utunFD, $0.baseAddress, out.count) }
        writeLock.unlock()
    }

    private func sendRST(to seg: UtunPacket.TCPSegment) {
        // Reflect a RST so the local kernel gives up on an unknown flow.
        let rst = UtunPacket.TCPSegment(
            srcIP: seg.dstIP, dstIP: seg.srcIP, srcPort: seg.dstPort, dstPort: seg.srcPort,
            seq: seg.ack, ack: seg.seq &+ UInt32(seg.payload.count),
            flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...])
        writePacket(rst)
    }

    // MARK: Helpers

    struct FlowKey: Hashable {
        let srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16
        init(_ s: UtunPacket.TCPSegment) { srcIP = s.srcIP; srcPort = s.srcPort; dstIP = s.dstIP; dstPort = s.dstPort }
    }

    static func parseCIDR(_ cidr: String) -> (net: UInt32, mask: UInt32)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let o = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard o.count == 4 else { return nil }
        let net = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0)) << (32 - prefix)
        return (net, mask)
    }

    /// Map a `100.64.<n>.x` alias back to the remote's real address (host octet
    /// preserved). Identity for a literal route.
    static func aliasToRemote(_ ip: String, remoteCIDR: String?) -> String {
        guard let rc = remoteCIDR, let (rNet, _) = FatClientPAC.parseCIDR(rc) else { return ip }
        let host = ip.split(separator: ".", omittingEmptySubsequences: false)
        let net = rNet.split(separator: ".")
        guard host.count == 4, net.count == 4 else { return ip }
        return "\(net[0]).\(net[1]).\(net[2]).\(host[3])"
    }
}
