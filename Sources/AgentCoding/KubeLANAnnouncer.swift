#if os(macOS)
import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

// MARK: - LAN service IPs, MetalLB-style
//
// Gives Services of type LoadBalancer their OWN addresses on the physical LAN
// without touching the Mac's network stack. One bridged vmnet tap (`LANTap`)
// puts this process on the wire with its own MAC; for every published IP the
// announcer answers ARP ("10.163.15.22 is at <tap MAC>") and terminates the
// TCP flows that arrive for it in userspace (`TCPFlow`, the same stack the
// switch MITM uses), splicing each one over vsock into the cluster's
// control-plane node and on to the Service's NodePort. UDP datagrams ride a
// framed vsock relay per node (`KubeUDPRelay`) and their replies are
// rebuilt into packets from the service address. Ports that aren't published
// get a RST; ICMP echo is answered so `ping` works; everything else is
// dropped. The kernel never learns these IPs, so nothing else on this Mac
// becomes reachable through them.

final class KubeLANAnnouncer: @unchecked Sendable {
    static let shared = KubeLANAnnouncer()

    struct PortKey: Hashable {
        let port: UInt16
        let udp: Bool
    }

    struct Target: Equatable {
        let nodeID: UUID
        /// The node's LAN address (the guest-side relay connects from here).
        let nodeIP: String
        let nodePort: UInt16
        /// TCP relay header: "<node ip>:<nodePort>".
        var tcpTarget: String { "\(nodeIP):\(nodePort)" }
    }

    /// Set by the cluster engine: opens a vsock relay into `nodeID` with the
    /// given header line ("<ip>:<port>" for TCP, "UDP <ip>" for the datagram
    /// mux); hands back the host fd (or -1).
    var relayOpener: ((_ nodeID: UUID, _ header: String, _ completion: @escaping @Sendable (Int32) -> Void) -> Void)?

    private let lock = NSLock()
    private var tap: LANTap?
    private var startFailed = false
    /// ip (host order) → (port, proto) → target — the union of every
    /// Service published on that address.
    private var table: [UInt32: [PortKey: Target]] = [:]
    /// ip → service key → its ports (several Services may share an address
    /// as long as their ports don't collide, like MetalLB's IP sharing).
    private var services: [UInt32: [String: [PortKey: Target]]] = [:]
    private var owners: [UInt32: UUID] = [:]
    /// Inbound IPv4 fragments being reassembled: (src, dst, id, proto) → parts.
    private struct FragKey: Hashable { let src: UInt32, dst: UInt32, id: UInt16, proto: UInt8 }
    private struct FragBuffer { var header: [UInt8]; var parts: [(offset: Int, bytes: [UInt8])]; var total: Int?; var started: Date }
    private var fragments: [FragKey: FragBuffer] = [:]
    private var nextIPID: UInt16 = UInt16.random(in: 1...60000)
    private var flows: [UtunForwarder.FlowKey: TCPFlow] = [:]
    private var clientMACs: [UtunForwarder.FlowKey: [UInt8]] = [:]
    private var relayFDs: [UtunForwarder.FlowKey: Int32] = [:]
    /// ARP probes in flight: ip → the MAC that claimed it (if any).
    private var probes: [UInt32: [UInt8]] = [:]
    private var probeWaiters: [UInt32: DispatchSemaphore] = [:]
    /// UDP: one relay per (node, node IP) shared by every client + service.
    private var udpRelays: [String: KubeUDPRelay] = [:]
    /// UDP: (client ip, client port, nodePort) → where the reply goes.
    private struct UDPSessionKey: Hashable { let clientIP: UInt32, clientPort: UInt16, nodePort: UInt16 }
    private struct UDPSession { let serviceIP: UInt32; let servicePort: UInt16; let clientMAC: [UInt8]; var lastSeen: Date }
    private var udpSessions: [UDPSessionKey: UDPSession] = [:]
    private var lastUDPSweep = Date()
    private static let mss = 1460   // Ethernet MTU 1500 − IP − TCP

    private init() {}

    /// The tap's MAC once it's up.
    var macString: String? { lock.lock(); defer { lock.unlock() }; return tap?.macString }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    /// Bring the tap up on the Mac's primary interface (once). False when
    /// vmnet bridged mode isn't available here.
    @discardableResult
    func ensureStarted() -> Bool {
        lock.lock()
        if tap != nil { lock.unlock(); return true }
        if startFailed { lock.unlock(); return false }
        lock.unlock()
        guard let ifName = HostNetwork.primaryInterfaceName() else { return false }
        let tap = LANTap(interfaceName: ifName) { [weak self] frame in self?.handleFrame(frame) }
        lock.lock()
        if let tap { self.tap = tap } else { startFailed = true }
        lock.unlock()
        return tap != nil
    }

    // MARK: Publishing

    enum PublishError: LocalizedError {
        case tapUnavailable
        case inUse(String)
        var errorDescription: String? {
            switch self {
            case .tapUnavailable: return "bridged networking isn't available on this Mac"
            case .inUse(let who): return "already answered by \(who) on the LAN"
            }
        }
    }

    /// Announce `ip` for `service` (an "ns/name" key) of `owner` with its
    /// ports. Re-publishing replaces that Service's ports; other Services on
    /// the same address keep theirs. A first publish of an address probes the
    /// LAN so one somebody else owns is refused. Returns the ports that
    /// couldn't be taken because another Service on this address already
    /// answers on them.
    @discardableResult
    func publish(ip: UInt32, ports: [PortKey: Target], owner: UUID, service: String) throws -> [PortKey] {
        guard ensureStarted(), let tap = currentTap() else { throw PublishError.tapUnavailable }
        lock.lock()
        let firstTime = owners[ip] == nil
        if let o = owners[ip], o != owner { lock.unlock(); throw PublishError.inUse("another cluster") }
        lock.unlock()
        if firstTime, let claimant = probeInUse(ip) {
            throw PublishError.inUse(LANTap.macString(claimant))
        }
        lock.lock()
        var perService = services[ip] ?? [:]
        // Ports another Service on this address already holds stay with it.
        var conflicts: [PortKey] = []
        var mine: [PortKey: Target] = [:]
        for (k, t) in ports {
            if perService.contains(where: { $0.key != service && $0.value[k] != nil }) { conflicts.append(k) }
            else { mine[k] = t }
        }
        perService[service] = mine
        services[ip] = perService
        table[ip] = perService.values.reduce(into: [:]) { acc, p in acc.merge(p) { old, _ in old } }
        owners[ip] = owner
        lock.unlock()
        if firstTime {
            // Gratuitous ARP (twice, like the speakers do) so caches flip now.
            let garp = Self.arpFrame(op: 2, senderMAC: tap.macAddress, senderIP: ip,
                                     targetMAC: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff], targetIP: ip,
                                     dstMAC: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
            tap.write(garp)
            tap.write(garp)
        }
        return conflicts
    }

    /// Stop answering for one Service. The address itself is withdrawn once
    /// no Service is left on it.
    func withdraw(ip: UInt32, owner: UUID, service: String) {
        lock.lock()
        guard owners[ip] == owner, var perService = services[ip] else { lock.unlock(); return }
        perService[service] = nil
        if perService.isEmpty {
            lock.unlock()
            withdraw(ip: ip, owner: owner)
            return
        }
        services[ip] = perService
        table[ip] = perService.values.reduce(into: [:]) { acc, p in acc.merge(p) { old, _ in old } }
        lock.unlock()
    }

    func withdraw(ip: UInt32, owner: UUID) {
        lock.lock()
        guard owners[ip] == owner else { lock.unlock(); return }
        owners[ip] = nil
        table[ip] = nil
        services[ip] = nil
        let victims = flows.filter { $0.key.dstIP == ip }
        for (k, _) in victims { flows[k] = nil; clientMACs[k] = nil }
        udpSessions = udpSessions.filter { $0.value.serviceIP != ip }
        lock.unlock()
        for (_, f) in victims { f.close() }
    }

    func withdrawAll(owner: UUID) {
        lock.lock()
        let ips = owners.filter { $0.value == owner }.map(\.key)
        lock.unlock()
        for ip in ips { withdraw(ip: ip, owner: owner) }
    }

    /// Drop the UDP relays into a node that's going away.
    func closeRelays(nodeID: UUID) {
        lock.lock()
        let victims = udpRelays.filter { $0.key.hasPrefix(nodeID.uuidString) }
        for (k, _) in victims { udpRelays[k] = nil }
        lock.unlock()
        for (_, r) in victims { r.close() }
    }

    /// Ask the LAN who owns `ip` (ARP probe, ~600 ms). nil = nobody answered.
    func probeInUse(_ ip: UInt32) -> [UInt8]? {
        guard let tap = currentTap() else { return nil }
        let sem = DispatchSemaphore(value: 0)
        lock.lock()
        probes[ip] = nil
        probeWaiters[ip] = sem
        lock.unlock()
        let req = Self.arpFrame(op: 1, senderMAC: tap.macAddress, senderIP: 0,
                                targetMAC: [0, 0, 0, 0, 0, 0], targetIP: ip,
                                dstMAC: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        tap.write(req)
        tap.write(req)
        _ = sem.wait(timeout: .now() + 0.6)
        lock.lock()
        let who = probes[ip]
        probes[ip] = nil
        probeWaiters[ip] = nil
        lock.unlock()
        return who
    }

    private func currentTap() -> LANTap? { lock.lock(); defer { lock.unlock() }; return tap }

    // MARK: Frames

    private func handleFrame(_ frame: [UInt8]) {
        guard frame.count >= 14 else { return }
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        switch etherType {
        case 0x0806: handleARP(frame)
        case 0x0800: handleIPv4(frame)
        default: break
        }
    }

    private func handleARP(_ f: [UInt8]) {
        // Ethernet(14) + ARP: htype(2) ptype(2) hlen(1) plen(1) op(2) sha(6) spa(4) tha(6) tpa(4)
        guard f.count >= 42, f[14] == 0, f[15] == 1, f[16] == 8, f[17] == 0, f[18] == 6, f[19] == 4 else { return }
        let op = UInt16(f[20]) << 8 | UInt16(f[21])
        let senderMAC = Array(f[22..<28])
        let senderIP = UInt32(f[28]) << 24 | UInt32(f[29]) << 16 | UInt32(f[30]) << 8 | UInt32(f[31])
        let targetIP = UInt32(f[38]) << 24 | UInt32(f[39]) << 16 | UInt32(f[40]) << 8 | UInt32(f[41])
        guard let tap = currentTap() else { return }
        if op == 1 {
            // Who-has one of ours? Reply with the tap's MAC. (Ignore our own
            // probes, whose sender IP is 0.)
            lock.lock()
            let mine = table[targetIP] != nil && senderIP != 0 && senderMAC != tap.macAddress
            lock.unlock()
            guard mine else { return }
            tap.write(Self.arpFrame(op: 2, senderMAC: tap.macAddress, senderIP: targetIP,
                                    targetMAC: senderMAC, targetIP: senderIP, dstMAC: senderMAC))
        } else if op == 2 {
            // Someone answering a probe: that IP is taken.
            lock.lock()
            if let sem = probeWaiters[senderIP], senderMAC != tap.macAddress {
                probes[senderIP] = senderMAC
                lock.unlock()
                sem.signal()
            } else {
                lock.unlock()
            }
        }
    }

    private func handleIPv4(_ f: [UInt8]) {
        var ip = Array(f[14...])
        guard ip.count >= 20, (ip[0] >> 4) == 4 else { return }
        // Datagrams bigger than the MTU arrive in pieces; put them back
        // together before looking at the transport header.
        let flagsOff = UtunPacket.u16(ip, 6)
        if flagsOff & 0x3FFF != 0 {
            guard let whole = reassemble(ip, flagsOff: flagsOff) else { return }
            ip = whole
        }
        let dstIP = UtunPacket.u32(ip, 16)
        lock.lock()
        let ports = table[dstIP]
        lock.unlock()
        guard let ports, let tap = currentTap() else { return }
        let clientMAC = Array(f[6..<12])
        switch ip[9] {
        case 6:
            guard let seg = UtunPacket.parse(ip) else { return }
            handleTCP(seg, ports: ports, clientMAC: clientMAC, tap: tap)
        case 17:
            guard let d = UtunPacket.parseUDP(ip) else { return }
            handleUDP(d, ports: ports, clientMAC: clientMAC)
        case 1:
            handleICMP(ip, clientMAC: clientMAC, tap: tap)
        default:
            break
        }
    }

    // MARK: TCP

    private func handleTCP(_ seg: UtunPacket.TCPSegment, ports: [PortKey: Target], clientMAC: [UInt8], tap: LANTap) {
        let key = UtunForwarder.FlowKey(seg)
        lock.lock()
        let existing = flows[key]
        lock.unlock()
        if let existing {
            existing.onInbound(seg)
            return
        }
        // Only a bare SYN to a published port opens a flow.
        guard seg.flags & UtunPacket.SYN != 0, seg.flags & UtunPacket.ACK == 0,
              let target = ports[PortKey(port: seg.dstPort, udp: false)] else {
            if seg.flags & UtunPacket.RST == 0 {
                let rst = UtunPacket.TCPSegment(
                    srcIP: seg.dstIP, dstIP: seg.srcIP, srcPort: seg.dstPort, dstPort: seg.srcPort,
                    seq: seg.ack, ack: seg.seq &+ UInt32(seg.payload.count) &+ ((seg.flags & UtunPacket.SYN) != 0 ? 1 : 0),
                    flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...])
                tap.write(Self.ethernet(dst: clientMAC, src: tap.macAddress, type: 0x0800, payload: UtunPacket.build(rst)))
            }
            return
        }
        guard let opener = relayOpener else { return }
        let nodeID = target.nodeID, header = target.tcpTarget
        let flow = TCPFlow(
            key: key, clientISN: seg.seq, mss: Self.mss,
            dial: { [weak self] in
                // Off-thread (TCPFlow.start detaches); the VZ vsock connect must
                // run on main — wait for its completion here.
                let fd = Self.openRelay(opener, nodeID: nodeID, header: header)
                guard fd >= 0 else { return nil }
                self?.lock.lock(); self?.relayFDs[key] = fd; self?.lock.unlock()
                return fd
            },
            send: { [weak self] s in
                guard let self, let tap = self.currentTap() else { return }
                self.lock.lock()
                let mac = self.clientMACs[key] ?? clientMAC
                self.lock.unlock()
                tap.write(Self.ethernet(dst: mac, src: tap.macAddress, type: 0x0800, payload: UtunPacket.build(s)))
            },
            onClosed: { [weak self] k in
                guard let self else { return }
                self.lock.lock()
                self.flows[k] = nil
                self.clientMACs[k] = nil
                let fd = self.relayFDs.removeValue(forKey: k)
                self.lock.unlock()
                if let fd { KubeRelayRetain.release(fd: fd) }
            })
        lock.lock()
        flows[key] = flow
        clientMACs[key] = clientMAC
        lock.unlock()
        flow.start()
    }

    /// Open a vsock relay synchronously from a non-main thread (the VZ
    /// connect runs on main; we wait up to 20 s for its completion).
    static func openRelay(_ opener: @escaping (UUID, String, @escaping @Sendable (Int32) -> Void) -> Void,
                          nodeID: UUID, header: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        let box = FDBox()
        DispatchQueue.main.async {
            opener(nodeID, header) { fd in box.fd = fd; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 20)
        return box.fd
    }

    // MARK: UDP

    private func handleUDP(_ d: UtunPacket.UDPDatagram, ports: [PortKey: Target], clientMAC: [UInt8]) {
        guard let target = ports[PortKey(port: d.dstPort, udp: true)] else { return }
        let key = UDPSessionKey(clientIP: d.srcIP, clientPort: d.srcPort, nodePort: target.nodePort)
        lock.lock()
        udpSessions[key] = UDPSession(serviceIP: d.dstIP, servicePort: d.dstPort, clientMAC: clientMAC, lastSeen: Date())
        if Date().timeIntervalSince(lastUDPSweep) > 60 {
            lastUDPSweep = Date()
            let cutoff = Date().addingTimeInterval(-300)
            udpSessions = udpSessions.filter { $0.value.lastSeen > cutoff }
        }
        lock.unlock()
        udpRelay(for: target).send(srcIP: d.srcIP, srcPort: d.srcPort, dstPort: target.nodePort, payload: d.payload)
    }

    private func udpRelay(for target: Target) -> KubeUDPRelay {
        let relayKey = "\(target.nodeID.uuidString)|\(target.nodeIP)"
        lock.lock()
        if let r = udpRelays[relayKey] { lock.unlock(); return r }
        let nodeID = target.nodeID, header = "UDP \(target.nodeIP)"
        let relay = KubeUDPRelay(
            dial: { [weak self] in
                guard let opener = self?.relayOpener else { return nil }
                let fd = Self.openRelay(opener, nodeID: nodeID, header: header)
                return fd >= 0 ? fd : nil
            },
            onReply: { [weak self] srcIP, srcPort, dstPort, payload in
                self?.deliverUDPReply(clientIP: srcIP, clientPort: srcPort, nodePort: dstPort, payload: payload)
            },
            onClosed: { [weak self] fd in
                guard let self else { return }
                self.lock.lock()
                if self.udpRelays[relayKey]?.isClosed == true { self.udpRelays[relayKey] = nil }
                self.lock.unlock()
                if fd >= 0 { KubeRelayRetain.release(fd: fd) }
            })
        udpRelays[relayKey] = relay
        lock.unlock()
        return relay
    }

    private func deliverUDPReply(clientIP: UInt32, clientPort: UInt16, nodePort: UInt16, payload: ArraySlice<UInt8>) {
        let key = UDPSessionKey(clientIP: clientIP, clientPort: clientPort, nodePort: nodePort)
        lock.lock()
        let session = udpSessions[key]
        lock.unlock()
        guard let session, let tap = currentTap() else { return }
        let pkt = UtunPacket.buildUDP(.init(srcIP: session.serviceIP, dstIP: clientIP,
                                            srcPort: session.servicePort, dstPort: clientPort, payload: payload))
        emitIPv4(pkt, to: session.clientMAC, tap: tap)
    }

    // MARK: IPv4 fragments

    /// Collect one fragment; return the full packet once every byte is in.
    private func reassemble(_ ip: [UInt8], flagsOff: UInt16) -> [UInt8]? {
        let ihl = Int(ip[0] & 0x0F) * 4
        let total = Int(UtunPacket.u16(ip, 2))
        guard ihl >= 20, total >= ihl, total <= ip.count else { return nil }
        let more = flagsOff & 0x2000 != 0
        let offset = Int(flagsOff & 0x1FFF) * 8
        let key = FragKey(src: UtunPacket.u32(ip, 12), dst: UtunPacket.u32(ip, 16),
                          id: UtunPacket.u16(ip, 4), proto: ip[9])
        let payload = Array(ip[ihl..<total])
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if fragments.count > 64 || fragments.values.contains(where: { now.timeIntervalSince($0.started) > 30 }) {
            fragments = fragments.filter { now.timeIntervalSince($0.value.started) <= 30 }
        }
        var buf = fragments[key] ?? FragBuffer(header: [], parts: [], total: nil, started: now)
        if offset == 0 { buf.header = Array(ip[0..<ihl]) }
        buf.parts.append((offset, payload))
        if !more { buf.total = offset + payload.count }
        guard let want = buf.total, want <= 65535, !buf.header.isEmpty else {
            fragments[key] = buf
            return nil
        }
        var body = [UInt8](repeating: 0, count: want)
        var have = [Bool](repeating: false, count: want)
        for (o, bytes) in buf.parts {
            guard o + bytes.count <= want else { continue }
            body.replaceSubrange(o..<(o + bytes.count), with: bytes)
            for i in o..<(o + bytes.count) { have[i] = true }
        }
        guard have.allSatisfy({ $0 }) else { fragments[key] = buf; return nil }
        fragments[key] = nil
        var packet = buf.header
        let hlen = packet.count
        UtunPacket.putU16(&packet, 2, UInt16(hlen + want))
        UtunPacket.putU16(&packet, 6, 0x4000)   // reassembled: DF, no offset
        packet[10] = 0; packet[11] = 0
        let sum = UtunPacket.ipChecksum(packet, 0, hlen)
        packet[10] = UInt8(sum >> 8); packet[11] = UInt8(sum & 0xff)
        packet.append(contentsOf: body)
        return packet
    }

    /// Write an IPv4 packet to the wire, split into MTU-sized fragments
    /// when it doesn't fit one frame (a big UDP reply).
    private func emitIPv4(_ packet: [UInt8], to mac: [UInt8], tap: LANTap) {
        let mtu = 1500
        guard packet.count > mtu else {
            tap.write(Self.ethernet(dst: mac, src: tap.macAddress, type: 0x0800, payload: packet))
            return
        }
        let ihl = Int(packet[0] & 0x0F) * 4
        let body = Array(packet[ihl...])
        let chunk = ((mtu - ihl) / 8) * 8
        lock.lock()
        nextIPID &+= 1
        if nextIPID == 0 { nextIPID = 1 }
        let id = nextIPID
        lock.unlock()
        var off = 0
        while off < body.count {
            let n = min(chunk, body.count - off)
            let last = off + n >= body.count
            var frag = Array(packet[0..<ihl])
            UtunPacket.putU16(&frag, 2, UInt16(ihl + n))
            UtunPacket.putU16(&frag, 4, id)
            UtunPacket.putU16(&frag, 6, UInt16(off / 8) | (last ? 0 : 0x2000))
            frag[10] = 0; frag[11] = 0
            let sum = UtunPacket.ipChecksum(frag, 0, ihl)
            frag[10] = UInt8(sum >> 8); frag[11] = UInt8(sum & 0xff)
            frag.append(contentsOf: body[off..<(off + n)])
            tap.write(Self.ethernet(dst: mac, src: tap.macAddress, type: 0x0800, payload: frag))
            off += n
        }
    }

    // MARK: ICMP

    private func handleICMP(_ ip: [UInt8], clientMAC: [UInt8], tap: LANTap) {
        let ihl = Int(ip[0] & 0x0F) * 4
        let total = Int(UtunPacket.u16(ip, 2))
        guard ip.count >= total, total > ihl + 8, ip[ihl] == 8 /* echo request */ else { return }
        var reply = Array(ip[0..<total])
        // Swap addresses, reset TTL/checksum, flip type to echo reply.
        let src = Array(ip[12..<16]), dst = Array(ip[16..<20])
        reply.replaceSubrange(12..<16, with: dst)
        reply.replaceSubrange(16..<20, with: src)
        reply[8] = 64
        reply[10] = 0; reply[11] = 0
        let ipSum = UtunPacket.ipChecksum(reply, 0, ihl)
        reply[10] = UInt8(ipSum >> 8); reply[11] = UInt8(ipSum & 0xff)
        reply[ihl] = 0          // type 0
        reply[ihl + 2] = 0; reply[ihl + 3] = 0
        let icmpSum = UtunPacket.ipChecksum(reply, ihl, total - ihl)
        reply[ihl + 2] = UInt8(icmpSum >> 8); reply[ihl + 3] = UInt8(icmpSum & 0xff)
        emitIPv4(reply, to: clientMAC, tap: tap)
    }

    // MARK: Frame builders

    static func ethernet(dst: [UInt8], src: [UInt8], type: UInt16, payload: [UInt8]) -> [UInt8] {
        var f = [UInt8]()
        f.reserveCapacity(14 + payload.count)
        f.append(contentsOf: dst)
        f.append(contentsOf: src)
        f.append(UInt8(type >> 8)); f.append(UInt8(type & 0xff))
        f.append(contentsOf: payload)
        return f
    }

    static func arpFrame(op: UInt16, senderMAC: [UInt8], senderIP: UInt32,
                         targetMAC: [UInt8], targetIP: UInt32, dstMAC: [UInt8]) -> [UInt8] {
        var arp: [UInt8] = [0, 1, 8, 0, 6, 4, UInt8(op >> 8), UInt8(op & 0xff)]
        arp.append(contentsOf: senderMAC)
        arp.append(contentsOf: [UInt8(senderIP >> 24), UInt8((senderIP >> 16) & 0xff), UInt8((senderIP >> 8) & 0xff), UInt8(senderIP & 0xff)])
        arp.append(contentsOf: targetMAC)
        arp.append(contentsOf: [UInt8(targetIP >> 24), UInt8((targetIP >> 16) & 0xff), UInt8((targetIP >> 8) & 0xff), UInt8(targetIP & 0xff)])
        return ethernet(dst: dstMAC, src: senderMAC, type: 0x0806, payload: arp)
    }

    final class FDBox: @unchecked Sendable { var fd: Int32 = -1 }
}

// MARK: - UDP over a vsock relay

/// All UDP toward one node rides a single vsock relay ("UDP <node ip>\n"
/// header; the guest relay keeps a socket per (srcIP, srcPort, dstPort)
/// connected to <node ip>:<dstPort> and frames replies back):
///
///   frame = [u16 bodyLen][u32 srcIP][u16 srcPort][u16 dstPort][payload]
///
/// Same framing as the fat-client `UDPChannel`, minus its SSH plumbing.
/// Dials lazily on the first datagram (queued meanwhile); a dropped relay
/// closes the channel so the next datagram re-dials.
final class KubeUDPRelay: @unchecked Sendable {
    typealias Reply = (_ srcIP: UInt32, _ srcPort: UInt16, _ dstPort: UInt16, _ payload: ArraySlice<UInt8>) -> Void

    private let dial: () -> Int32?
    private let onReply: Reply
    private let onClosed: (Int32) -> Void
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var rfd: Int32 = -1
    private var connecting = false
    private var closed = false
    private var pending: [[UInt8]] = []

    init(dial: @escaping () -> Int32?, onReply: @escaping Reply, onClosed: @escaping (Int32) -> Void) {
        self.dial = dial
        self.onReply = onReply
        self.onClosed = onClosed
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func send(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) {
        let frame = Self.frame(srcIP: srcIP, srcPort: srcPort, dstPort: dstPort, payload: payload)
        lock.lock()
        if closed { lock.unlock(); return }
        if rfd >= 0 {
            let fd = rfd; lock.unlock()
            writeFrame(fd, frame)
            return
        }
        pending.append(frame)
        if pending.count > 256 { pending.removeFirst(pending.count - 256) }
        let startDial = !connecting
        connecting = true
        lock.unlock()
        if startDial { dialAsync() }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let fd = rfd; rfd = -1
        lock.unlock()
        if fd >= 0 { writeLock.lock(); Darwin.close(fd); writeLock.unlock() }
        onClosed(fd)
    }

    private func writeFrame(_ fd: Int32, _ frame: [UInt8]) {
        writeLock.lock(); _ = writeAll(fd, frame); writeLock.unlock()
    }

    private func dialAsync() {
        Thread.detachNewThread { [weak self] in
            let fd = self?.dial() ?? -1
            guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
            self.lock.lock()
            if self.closed || fd < 0 {
                self.connecting = false
                self.closed = true
                self.lock.unlock()
                if fd >= 0 { Darwin.close(fd) }
                self.onClosed(-1)
                return
            }
            self.rfd = fd
            let queued = self.pending; self.pending = []
            self.lock.unlock()
            for f in queued { self.writeFrame(fd, f) }
            self.readLoop(fd)
        }
    }

    private func readLoop(_ fd: Int32) {
        var acc = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            acc.append(contentsOf: buf[0..<n])
            while acc.count >= 2 {
                let bodyLen = (Int(acc[0]) << 8) | Int(acc[1])
                guard acc.count >= 2 + bodyLen else { break }
                let body = Array(acc[2..<(2 + bodyLen)])
                acc.removeFirst(2 + bodyLen)
                guard body.count >= 8 else { continue }
                onReply(UtunPacket.u32(body, 0), UtunPacket.u16(body, 4), UtunPacket.u16(body, 6), body[8...])
            }
        }
        lock.lock()
        let alive = !closed
        if alive { closed = true; rfd = -1 }
        lock.unlock()
        if alive {
            writeLock.lock(); Darwin.close(fd); writeLock.unlock()
            onClosed(fd)
        }
    }

    static func frame(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) -> [UInt8] {
        let bodyLen = 8 + payload.count
        var f = [UInt8](); f.reserveCapacity(2 + bodyLen)
        f.append(UInt8(bodyLen >> 8)); f.append(UInt8(bodyLen & 0xff))
        f.append(UInt8(srcIP >> 24)); f.append(UInt8((srcIP >> 16) & 0xff))
        f.append(UInt8((srcIP >> 8) & 0xff)); f.append(UInt8(srcIP & 0xff))
        f.append(UInt8(srcPort >> 8)); f.append(UInt8(srcPort & 0xff))
        f.append(UInt8(dstPort >> 8)); f.append(UInt8(dstPort & 0xff))
        f.append(contentsOf: payload)
        return f
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int {
        var off = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while off < bytes.count {
                let n = Darwin.write(fd, base + off, bytes.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
        return off
    }
}

// MARK: - LAN IP pools

enum KubeLANPool {
    /// Parse "a.b.c.d-a.b.c.e", "a.b.c.d/28" or a single "a.b.c.d" into host-order
    /// addresses (network/broadcast excluded for CIDRs). nil on garbage.
    static func parse(_ text: String) -> [UInt32]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var out: [UInt32] = []
        for part in t.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let dash = p.firstIndex(of: "-") {
                guard let a = UtunForwarder.parseCIDR(String(p[..<dash]) + "/32")?.net,
                      let b = UtunForwarder.parseCIDR(String(p[p.index(after: dash)...]) + "/32")?.net,
                      a <= b, b - a < 1024 else { return nil }
                out.append(contentsOf: a...b)
            } else if p.contains("/") {
                guard let (net, mask) = UtunForwarder.parseCIDR(p), mask != 0 else { return nil }
                let base = net & mask
                let last = base | ~mask
                guard last - base < 1024 else { return nil }
                let lo = mask == 0xFFFFFFFF ? base : base + 1
                let hi = mask == 0xFFFFFFFF ? base : last - 1
                if lo <= hi { out.append(contentsOf: lo...hi) }
            } else {
                guard let a = UtunForwarder.parseCIDR(p + "/32")?.net else { return nil }
                out.append(a)
            }
        }
        return out.isEmpty ? nil : out
    }
}
#endif
