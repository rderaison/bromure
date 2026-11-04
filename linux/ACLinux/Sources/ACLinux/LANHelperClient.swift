import Foundation
import Glibc
import SandboxEngine

/// A shared server's daemon side of bromure-lan (LANHelper): the load
/// balancer's KubeLANPublishing (macOS: KubeLANAnnouncer). Publishing asks
/// the helper over its socket; the connections the helper hands back are
/// checked against what this daemon published (anything else is closed) and
/// relayed into the cluster's node over vsock 5010, as the load balancer's
/// host listeners are. A dropped helper connection is re-made every 2 s and
/// everything published again (the helper withdrew it when we went away).
// @port-skip linux-only: the daemon's client of the multi-user LAN helper
final class LANHelperClient: KubeLANPublishing, @unchecked Sendable {
    /// Opens a vsock relay into a node (the engine's openRelay).
    typealias Opener = (UUID, String, @escaping @Sendable (Int32) -> Void) -> Void

    private let socketPath: String
    private let opener: Opener
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 0
    private var waiting: [Int: (DispatchSemaphore, [String: Any]?)] = [:]
    /// (ip, service) → what was published: its owner and ports → targets.
    private var published: [Pub: (owner: UUID, ports: [KubeLANPortKey: KubeLANTarget])] = [:]
    struct Pub: Hashable { let ip: UInt32; let service: String }
    /// Relayed connections by node (closeRelays).
    private var relays: [UUID: Set<Int32>] = [:]
    /// The UDP sockets the helper handed over, by publication; a withdrawn
    /// one's loop sees it in `closedUDP` and ends (closing it).
    private var udpSockets: [Pub: [Int32]] = [:]
    private var closedUDP: Set<Int32> = []

    // @port-skip linux-only: LAN helper client
    init(socketPath: String = LANHelper.defaultSocket, opener: @escaping Opener) {
        self.socketPath = socketPath
        self.opener = opener
        Thread.detachNewThread { [weak self] in self?.reconnectLoop() }
    }

    // MARK: KubeLANPublishing

    /// Publishes `ip`'s Service ports through the helper.
    ///
    /// KubeLoadBalancer calls this on every probe and takes any error as a
    /// lasting refusal of the address; macOS's announcer only refuses a
    /// first publish for good. So:
    /// - the helper refusing for good (`grantMiss`, a port it can't bind…)
    ///   is an error, and ends the publication here too (the helper already
    ///   withdrew it);
    /// - what passes (the helper down or not answering, the file missing,
    ///   `retryAfter`: the pools just changed, the address still held by
    ///   another connection) keeps a live publication as it is (the helper
    ///   still serves it; the next probe or reconnect sends it again), and
    ///   for a new one reports every port as a conflict: not bound, tried
    ///   again on the next probe, never a lasting refusal;
    /// - a `retryAfter` of up to 5 s is waited out once first.
    // @port-skip linux-only: KubeLANAnnouncer.publish over the LAN helper
    func publish(ip: UInt32, ports: [KubeLANPortKey: KubeLANTarget], owner: UUID, service: String) throws -> [KubeLANPortKey] {
        let key = Pub(ip: ip, service: service)
        lock.lock()
        let prev = published[key]
        // Recorded first: the helper hands the UDP sockets over before its reply.
        published[key] = (owner, ports)
        lock.unlock()
        let passing = prev == nil ? Array(ports.keys) : []
        func keep() -> [KubeLANPortKey] {
            lock.lock(); published[key] = prev; lock.unlock()
            return passing
        }
        let body: [String: Any] = ["op": "publish", "ip": VMNetSwitch.ipString(ip), "service": service,
                                   "owner": owner.uuidString, "ports": ports.keys.map { ["port": Int($0.port), "udp": $0.udp] }]
        var reply: [String: Any]
        do { reply = try request(body) } catch { return keep() }
        if reply["ok"] as? Bool != true, let wait = reply["retryAfter"] as? Double, wait > 0, wait <= 5 {
            Thread.sleep(forTimeInterval: wait)
            do { reply = try request(body) } catch { return keep() }
        }
        if reply["ok"] as? Bool == true {
            return ((reply["conflicts"] as? [[String: Any]]) ?? []).compactMap { c in
                (c["port"] as? Int).map { KubeLANPortKey(port: UInt16($0), udp: (c["udp"] as? Bool) ?? false) }
            }
        }
        if reply["transient"] as? Bool == true || reply["retryAfter"] != nil { return keep() }
        end(key)
        throw LANHelperError.refused((reply["error"] as? String) ?? "refused")
    }

    /// A publication over (refused for good, or revoked by the helper): its
    /// record and its UDP sockets go; the next probe's publish is new.
    // @port-skip linux-only: LAN helper client
    private func end(_ key: Pub) {
        lock.lock()
        published[key] = nil
        closedUDP.formUnion(udpSockets.removeValue(forKey: key) ?? [])
        lock.unlock()
    }

    // @port-skip linux-only: KubeLANAnnouncer.withdraw over the LAN helper
    func withdraw(ip: UInt32, owner: UUID, service: String) {
        lock.lock()
        published[Pub(ip: ip, service: service)] = nil
        closedUDP.formUnion(udpSockets.removeValue(forKey: Pub(ip: ip, service: service)) ?? [])
        lock.unlock()
        _ = try? request(["op": "withdraw", "ip": VMNetSwitch.ipString(ip), "service": service])
    }

    // @port-skip linux-only: KubeLANAnnouncer.withdrawAll over the LAN helper
    func withdrawAll(owner: UUID) {
        lock.lock()
        for (pub, v) in published where v.owner == owner { closedUDP.formUnion(udpSockets.removeValue(forKey: pub) ?? []) }
        published = published.filter { $0.value.owner != owner }
        lock.unlock()
        _ = try? request(["op": "withdrawAll", "owner": owner.uuidString])
    }

    // @port-skip linux-only: KubeLANAnnouncer.closeRelays
    func closeRelays(nodeID: UUID) {
        lock.lock()
        let fds = relays.removeValue(forKey: nodeID) ?? []
        lock.unlock()
        for fd in fds { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    // MARK: The helper connection

    enum LANHelperError: Error, LocalizedError {
        case unavailable, refused(String)
        // @port-skip linux-only: LAN helper client
        var errorDescription: String? {
            switch self {
            case .unavailable: return "the LAN address helper (bromure-lan) isn't running"
            case .refused(let why): return why
            }
        }
    }

    /// One request and its reply (5 s at most).
    // @port-skip linux-only: LAN helper client
    private func request(_ body: [String: Any]) throws -> [String: Any] {
        lock.lock()
        if fd < 0 { connectLocked() }
        let sock = fd
        nextID += 1
        let id = nextID
        let sem = DispatchSemaphore(value: 0)
        waiting[id] = (sem, nil)
        lock.unlock()
        guard sock >= 0, var line = try? JSONSerialization.data(withJSONObject: body.merging(["id": id]) { a, _ in a }) else {
            lock.lock(); waiting[id] = nil; lock.unlock()
            throw LANHelperError.unavailable
        }
        line.append(0x0A)
        _ = LANFD.send(sock, line, fd: nil)
        let ok = sem.wait(timeout: .now() + 5) == .success
        lock.lock()
        let reply = waiting.removeValue(forKey: id)?.1
        lock.unlock()
        guard ok, let reply else { throw LANHelperError.unavailable }
        return reply
    }

    /// Connects (lock held); on success starts the reader.
    // @port-skip linux-only: LAN helper client
    private func connectLocked() {
        let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in
            for (i, c) in socketPath.utf8.prefix(b.count - 1).enumerated() { b[i] = c }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(s); return }
        fd = s
        Thread.detachNewThread { [weak self] in self?.readLoop(s) }
    }

    /// Re-connects a dropped helper connection every 2 s, then publishes
    /// everything again.
    // @port-skip linux-only: LAN helper client
    private func reconnectLoop() {
        while true {
            Thread.sleep(forTimeInterval: 2)
            lock.lock()
            let need = fd < 0 && !published.isEmpty
            if need { connectLocked() }
            let again = need && fd >= 0 ? published : [:]
            lock.unlock()
            for (pub, v) in again {
                _ = try? request(["op": "publish", "ip": VMNetSwitch.ipString(pub.ip), "service": pub.service,
                                  "owner": v.owner.uuidString, "ports": v.ports.keys.map { ["port": Int($0.port), "udp": $0.udp] }])
            }
        }
    }

    // @port-skip linux-only: LAN helper client
    private func readLoop(_ s: Int32) {
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 16 << 10)
        var pendingFDs: [Int32] = []
        while true {
            let (n, fds) = LANFD.receive(s, &buf)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            pendingFDs += fds
            acc.append(contentsOf: buf[0..<n])
            while let nl = acc.firstIndex(of: 0x0A) {
                let line = acc[acc.startIndex..<nl]
                acc = Data(acc[(nl + 1)...])
                guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if let id = msg["id"] as? Int {
                    lock.lock()
                    if let w = waiting[id] { waiting[id] = (w.0, msg); w.0.signal() }
                    lock.unlock()
                } else if msg["revoked"] as? Bool == true {
                    // The grant went (or moved): the helper withdrew it.
                    if let t = msg["ip"] as? String, let ip = VMNetSwitch.parseIPv4(t), let svc = msg["service"] as? String {
                        end(Pub(ip: ip, service: svc))
                        FileHandle.standardError.write(Data("bromure-ac: LAN address \(t) for \(svc) withdrawn: \((msg["error"] as? String) ?? "revoked")\n".utf8))
                    }
                } else if !pendingFDs.isEmpty {
                    handOver(msg, fd: pendingFDs.removeFirst())
                }
            }
        }
        for f in pendingFDs { close(f) }
        lock.lock()
        if fd == s { fd = -1 }
        // The helper withdrew everything of ours; republishing hands new sockets.
        for (_, fds) in udpSockets { closedUDP.formUnion(fds) }
        udpSockets.removeAll()
        for (_, w) in waiting { w.0.signal() }
        lock.unlock()
        close(s)
    }

    /// A connection (or UDP socket) the helper handed over: only for an
    /// address, port and Service this daemon published; else closed.
    // @port-skip linux-only: LAN helper client
    private func handOver(_ msg: [String: Any], fd: Int32) {
        guard let ipText = msg["ip"] as? String, let ip = VMNetSwitch.parseIPv4(ipText),
              let port = msg["port"] as? Int, let service = msg["service"] as? String else { close(fd); return }
        let udp = msg["udp"] as? Bool == true
        lock.lock()
        let target = published[Pub(ip: ip, service: service)]?.ports[KubeLANPortKey(port: UInt16(port), udp: udp)]
        lock.unlock()
        guard let target else { close(fd); return }
        if udp {
            lock.lock(); udpSockets[Pub(ip: ip, service: service), default: []].append(fd); lock.unlock()
            serveUDP(fd, target: target)
            return
        }
        let opener = self.opener
        Thread.detachNewThread { [weak self] in
            let vfd = KubeLANRelay.open(opener, nodeID: target.nodeID, header: target.tcpTarget)
            guard vfd >= 0 else { close(fd); return }
            self?.track(target.nodeID, vfd, add: true)
            LBSocket.splice(vfd, fd)
            self?.track(target.nodeID, vfd, add: false)
            KubeRelayRetain.release(fd: vfd)
        }
    }

    /// A published UDP port's socket: each datagram rides the node's UDP
    /// relay; replies go back from the same socket.
    // @port-skip linux-only: LAN helper client
    private func serveUDP(_ sock: Int32, target: KubeLANTarget) {
        let opener = self.opener
        let relay = KubeUDPRelay(
            dial: {
                let fd = KubeLANRelay.open(opener, nodeID: target.nodeID, header: "UDP \(target.nodeIP)")
                return fd >= 0 ? fd : nil
            },
            onReply: { srcIP, srcPort, _, payload in
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = srcIP.bigEndian
                addr.sin_port = in_port_t(srcPort.bigEndian)
                payload.withUnsafeBytes { raw in
                    _ = withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            LBSocket.sendto(sock, raw.baseAddress, raw.count, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            },
            onClosed: { fd in if fd >= 0 { KubeRelayRetain.release(fd: fd) } })
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                // Withdrawn: stop (polled, as a blocked recvfrom doesn't wake on close).
                var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 500)
                if self.isClosed(sock) { break }
                if ready <= 0 { continue }
                var addr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue }; break }
                guard n > 0 else { continue }
                relay.send(srcIP: UInt32(bigEndian: addr.sin_addr.s_addr), srcPort: UInt16(bigEndian: addr.sin_port),
                           dstPort: target.nodePort, payload: Array(buf[0..<n])[...])
            }
            relay.close()
            self.forget(sock)
            close(sock)
        }
    }

    // @port-skip linux-only: LAN helper client
    private func isClosed(_ sock: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return closedUDP.contains(sock) }

    // @port-skip linux-only: LAN helper client
    private func forget(_ sock: Int32) { lock.lock(); closedUDP.remove(sock); lock.unlock() }

    // @port-skip linux-only: LAN helper client
    private func track(_ node: UUID, _ fd: Int32, add: Bool) {
        lock.lock()
        if add { relays[node, default: []].insert(fd) } else { relays[node]?.remove(fd) }
        lock.unlock()
    }
}
