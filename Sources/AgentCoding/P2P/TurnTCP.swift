import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - STUN over UDP (Binding only)

/// One-shot STUN Binding over UDP — the classic, cheapest way to learn our
/// public address (no TCP handshake, one round trip). UDP is ONLY viable for
/// this discovery step: RFC 6062 TCP allocations and their control/data legs
/// must run over TCP, and the relayed payload is SSH — a byte stream.
enum STUNUDP {
    /// Send a Binding request with RFC 5389-style retransmits (500 ms initial
    /// RTO, doubling) until `deadline`. A connected UDP socket surfaces ICMP
    /// port-unreachable as a recv error, so a dead server fails fast instead
    /// of eating the whole budget.
    static func binding(host: String, port: Int, deadline: Date) -> (ip: String, port: Int)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        let rc = info.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, info.pointee.ai_addrlen)   // connected: errors surface
        }
        guard rc == 0 else { return nil }

        let req = STUNMessage(type: STUNMessage.bindingRequest)
        let bytes = req.encoded()
        var rto: TimeInterval = 0.5
        while Date() < deadline {
            guard bytes.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, bytes.count, 0) }) == bytes.count else {
                return nil
            }
            let wait = min(rto, deadline.timeIntervalSinceNow)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, wait * 1000)))
            if pr < 0 { if errno == EINTR { continue }; return nil }
            if pr > 0 {
                var buf = [UInt8](repeating: 0, count: 1500)
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return nil }   // ICMP unreachable → fall back to TCP
                if let resp = STUNMessage.decode(Array(buf[0..<n])),
                   resp.txid == req.txid, resp.isSuccess {
                    return resp.xorAddress(STUNMessage.attrXorMappedAddress)
                }
                continue   // garbage / stray datagram: keep waiting, resend on timeout
            }
            rto *= 2   // timed out this round → retransmit
        }
        return nil
    }
}

// MARK: - Blocking STUN-over-TCP plumbing

/// Framed STUN send/recv over blocking TCP fds (RFC 5389 §7.2.2 framing: the
/// 20-byte header's length field tells you exactly how much more to read, so
/// consecutive messages — and the raw peer bytes that follow a ConnectionBind
/// success — are never over-read).
enum STUNTCP {
    /// Resolve (DNS ok) and connect with a bounded timeout. Unlike
    /// `P2PTCP.connect` this accepts hostnames — the relay is `turn.bromure.io`,
    /// not a numeric candidate. Returns a connected blocking fd. When `tls` is
    /// set the fd is a `TurnTLSTunnel` loopback whose bytes are TLS'd to the
    /// relay (turns:, 5349) — transparent to every STUN send/read and the data
    /// leg's splice, which keep treating it as a plain TCP socket.
    static func connect(host: String, port: Int, timeout: TimeInterval, tls: Bool = false) -> Int32? {
        if tls { return TurnTLSTunnel.connect(host: host, port: port, timeout: timeout) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let i = info {
            let fd = socket(i.pointee.ai_family, i.pointee.ai_socktype, i.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = i.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, i.pointee.ai_addrlen)
                }
                var ok = rc == 0
                if !ok && errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, Int32(max(1, timeout * 1000))) > 0, (pfd.revents & Int16(POLLOUT)) != 0 {
                        var soErr: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0
                    }
                }
                if ok {
                    _ = fcntl(fd, F_SETFL, flags)
                    SocketTuning.tuneInteractive(fd)
                    return fd
                }
                Darwin.close(fd)
            }
            info = i.pointee.ai_next
        }
        return nil
    }

    static func send(_ fd: Int32, _ msg: STUNMessage) -> Bool {
        let bytes = msg.encoded()
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: off), bytes.count - off) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// Read exactly one STUN message, waiting at most until `deadline`.
    static func read(_ fd: Int32, deadline: Date) -> STUNMessage? {
        guard let header = recvExact(fd, 20, deadline: deadline) else { return nil }
        let length = Int(header[2]) << 8 | Int(header[3])
        guard length <= 1 << 16 else { return nil }
        let body = length > 0 ? recvExact(fd, length, deadline: deadline) : []
        guard let body else { return nil }
        return STUNMessage.decode(header + body)
    }

    private static func recvExact(_ fd: Int32, _ count: Int, deadline: Date) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let msLeft = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard deadline > Date() else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, msLeft)
            if pr < 0 { if errno == EINTR { continue }; return nil }
            if pr == 0 { return nil }   // deadline
            let n = Darwin.read(fd, &buf, count - out.count)
            guard n > 0 else { return nil }
            out += buf[0..<n]
        }
        return out
    }
}

// MARK: - TURN-over-TCP client (RFC 5766 long-term auth + RFC 6062 verbs)

/// One TURN client session against coturn, everything blocking (runs on the
/// broker's background threads, like the rest of the transport layer). The
/// credentials are the TURN REST API pair minted by the control plane; auth is
/// the standard 401 realm/nonce dance, re-signed transparently on 438
/// (stale nonce).
final class TurnTCPClient: @unchecked Sendable {
    struct Allocation {
        let relayIP: String
        let relayPort: Int
        let mappedIP: String
        let mappedPort: Int
        let lifetime: UInt32
    }

    let host: String
    let port: Int
    /// Dial the control + data legs over TLS (turns:) rather than plain TCP.
    private let tls: Bool
    private let username: String
    private let password: String

    private let lock = NSLock()
    private var realm = ""
    private var nonce = ""
    private var key: [UInt8] = []
    /// Indications that arrived while a transaction was waiting for its reply.
    private var pendingEvents: [STUNMessage] = []
    private(set) var fd: Int32 = -1

    init(host: String, port: Int, tls: Bool = false, username: String, password: String) {
        self.host = host
        self.port = port
        self.tls = tls
        self.username = username
        self.password = password
    }

    func connect(timeout: TimeInterval) -> Bool {
        guard fd < 0 else { return true }
        guard let s = STUNTCP.connect(host: host, port: port, timeout: timeout, tls: tls) else { return false }
        fd = s
        return true
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    // MARK: Verbs

    func allocateTCP(timeout: TimeInterval) -> Allocation? {
        let resp = transact(on: fd, timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.allocateRequest)
            m.add(STUNMessage.attrRequestedTransport, [STUNMessage.protoTCP, 0, 0, 0])
            return m
        }
        guard let resp, resp.isSuccess,
              let relay = resp.xorAddress(STUNMessage.attrXorRelayedAddress),
              let mapped = resp.xorAddress(STUNMessage.attrXorMappedAddress) else { return nil }
        return Allocation(relayIP: relay.ip, relayPort: relay.port,
                          mappedIP: mapped.ip, mappedPort: mapped.port,
                          lifetime: resp.u32(STUNMessage.attrLifetime) ?? 600)
    }

    /// Allow inbound relayed connections from `peerIP` (the port is ignored
    /// for permissions). Refreshed by re-sending; coturn expires them at 5 min.
    @discardableResult
    func createPermission(peerIP: String, timeout: TimeInterval = 5) -> Bool {
        let resp = transact(on: fd, timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.createPermissionRequest)
            guard m.addXorAddress(STUNMessage.attrXorPeerAddress, ip: peerIP, port: 0) else {
                return nil
            }
            return m
        }
        return resp?.isSuccess ?? false
    }

    /// Refresh the allocation; returns the granted lifetime (nil = failed, the
    /// session is over — creds expired or the relay dropped us).
    func refresh(timeout: TimeInterval = 5) -> UInt32? {
        let resp = transact(on: fd, timeout: timeout) {
            STUNMessage(type: STUNMessage.refreshRequest)
        }
        guard let resp, resp.isSuccess else { return nil }
        return resp.u32(STUNMessage.attrLifetime) ?? 600
    }

    /// RFC 6062 §4.3: open a SECOND TCP connection to the relay and bind it to
    /// a ConnectionAttempt's id. On success the returned fd is a raw byte pipe
    /// to the peer (caller owns it — splice it into the local sshd).
    func bindDataConnection(id: UInt32, timeout: TimeInterval) -> Int32? {
        guard let dataFD = STUNTCP.connect(host: host, port: port, timeout: timeout, tls: tls) else { return nil }
        let resp = transact(on: dataFD, timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.connectionBindRequest)
            m.add(STUNMessage.attrConnectionID, u32: id)
            return m
        }
        guard let resp, resp.isSuccess else { Darwin.close(dataFD); return nil }
        return dataFD
    }

    /// Wait for the next server → client indication on the control connection
    /// (ConnectionAttempt). Stray responses (from a timed-out transaction) are
    /// dropped. nil = nothing within the timeout (normal — the caller ticks).
    func readEvent(timeout: TimeInterval) -> STUNMessage? {
        lock.lock()
        if !pendingEvents.isEmpty {
            let ev = pendingEvents.removeFirst()
            lock.unlock()
            return ev
        }
        lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let msg = STUNTCP.read(fd, deadline: deadline) else { return nil }
            if msg.isIndication { return msg }
        }
        return nil
    }

    /// STUN Binding — our public address as the relay host sees it (the NAT
    /// mapping the peer's permission must cover; only the IP is used there).
    /// TCP first — it exercises the same protocol (and NAT mapping family) the
    /// relay's TCP legs will use — then UDP with the remaining budget as the
    /// fallback for TCP-hostile paths.
    static func publicAddress(host: String, port: Int, timeout: TimeInterval) -> (ip: String, port: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        let tcpDeadline = min(deadline, Date().addingTimeInterval(timeout / 2))
        if let viaTCP = bindingTCP(host: host, port: port, deadline: tcpDeadline) {
            return viaTCP
        }
        return STUNUDP.binding(host: host, port: port, deadline: deadline)
    }

    private static func bindingTCP(host: String, port: Int, deadline: Date) -> (ip: String, port: Int)? {
        guard let fd = STUNTCP.connect(host: host, port: port,
                                       timeout: deadline.timeIntervalSinceNow) else { return nil }
        defer { Darwin.close(fd) }
        let req = STUNMessage(type: STUNMessage.bindingRequest)
        guard STUNTCP.send(fd, req) else { return nil }
        while let resp = STUNTCP.read(fd, deadline: deadline) {
            guard resp.txid == req.txid, resp.isSuccess else { continue }
            return resp.xorAddress(STUNMessage.attrXorMappedAddress)
        }
        return nil
    }

    // MARK: Authenticated transaction

    /// Send one request and wait for its reply, running the long-term-credential
    /// auth dance: first 401 teaches us realm+nonce (key = MD5 of the REST
    /// creds), 438 rotates the nonce; each retry is a fresh transaction.
    /// Indications seen while waiting are stashed for `readEvent`. `build`
    /// returns the bare request (no auth attributes) or nil to abort.
    private func transact(on fd: Int32, timeout: TimeInterval,
                          build: () -> STUNMessage?) -> STUNMessage? {
        guard fd >= 0 else { return nil }
        var authRetries = 0
        while authRetries < 3 {
            guard var msg = build() else { return nil }
            lock.lock()
            let haveKey = !key.isEmpty
            if haveKey {
                msg.add(STUNMessage.attrUsername, string: username)
                msg.add(STUNMessage.attrRealm, string: realm)
                msg.add(STUNMessage.attrNonce, string: nonce)
                msg.sign(key: key)
            }
            lock.unlock()
            guard STUNTCP.send(fd, msg) else { return nil }

            let deadline = Date().addingTimeInterval(timeout)
            var resp: STUNMessage?
            while Date() < deadline {
                guard let m = STUNTCP.read(fd, deadline: deadline) else { break }
                if m.isIndication {
                    lock.lock(); pendingEvents.append(m); lock.unlock()
                    continue
                }
                if m.txid == msg.txid { resp = m; break }
            }
            guard let resp else { return nil }

            switch resp.errorCode ?? 0 {
            case 401 where !haveKey, 438:
                // Learn (or rotate) realm+nonce and retry with a signed request.
                guard let newRealm = resp.string(STUNMessage.attrRealm) ?? optionalRealm(),
                      let newNonce = resp.string(STUNMessage.attrNonce) else { return resp }
                lock.lock()
                realm = newRealm
                nonce = newNonce
                key = STUNMessage.longTermKey(username: username, realm: realm, password: password)
                lock.unlock()
                authRetries += 1
            default:
                return resp
            }
        }
        return nil
    }

    private func optionalRealm() -> String? {
        lock.lock(); defer { lock.unlock() }
        return realm.isEmpty ? nil : realm
    }
}

// MARK: - Listener-side relay session

/// The listener's whole TURN life: one allocation (RFC 6062 TCP), a permission
/// for the dialer, then a service loop that answers every ConnectionAttempt
/// with a ConnectionBind and splices the resulting byte pipe into the local
/// sshd — so each SSH connection the dialer's loopback shim opens gets its own
/// relayed leg, transparently. Refreshes the allocation and permissions until
/// stopped or the credentials expire (~1 h); the mirror's poll failure then
/// tears down and re-establishes with a fresh grant.
final class TurnRelayListener: @unchecked Sendable {
    struct Started {
        /// The relayed transport address to advertise as a `relay` candidate.
        let relay: P2PCandidate
        /// Our public IP as coturn saw the control connection — used for the
        /// srflx-guess candidate (public IP + sshd port).
        let mappedIP: String
    }

    private let client: TurnTCPClient
    private let sshPort: Int
    private let lifetime: UInt32
    private let lock = NSLock()
    private var permitted: [String]
    private var pendingPermits: [String] = []
    private var stopped = false
    /// Called (once, off-main) when the service loop exits for any reason.
    var onStopped: (() -> Void)?

    /// Connect, allocate, and install the dialer's permission — all blocking
    /// (≤ ~10 s), call on a background thread. The permission is in place
    /// before this returns, so the relay candidate can be advertised without
    /// racing the dialer's connect.
    static func start(creds: TurnCredentials, permitIP: String, sshPort: Int)
        -> (listener: TurnRelayListener, started: Started)? {
        guard let (host, port, tls) = TurnRelayTransport.preferredRelayEndpoint(creds.urls) else {
            FatClientLog.log("p2p: no turn(s):…?transport=tcp URL in credentials")
            return nil
        }
        let client = TurnTCPClient(host: host, port: port, tls: tls,
                                   username: creds.username, password: creds.credential)
        guard client.connect(timeout: 5) else {
            FatClientLog.log("p2p: relay \(host):\(port) (\(tls ? "TLS" : "TCP")) unreachable")
            return nil
        }
        guard let alloc = client.allocateTCP(timeout: 6) else {
            FatClientLog.log("p2p: TURN allocate failed at \(host):\(port)")
            client.close()
            return nil
        }
        guard client.createPermission(peerIP: permitIP) else {
            FatClientLog.log("p2p: TURN permission for \(permitIP) refused")
            client.close()
            return nil
        }
        FatClientLog.log("p2p: TURN relay allocated \(alloc.relayIP):\(alloc.relayPort) "
            + "over \(tls ? "TLS" : "TCP") \(host):\(port) "
            + "(lifetime \(alloc.lifetime)s, permit \(permitIP))")
        let listener = TurnRelayListener(client: client, sshPort: sshPort,
                                         lifetime: alloc.lifetime, permitted: [permitIP])
        Thread.detachNewThread { listener.serviceLoop() }
        let relay = P2PCandidate(kind: .relay, proto: .tcp,
                                 ip: alloc.relayIP, port: alloc.relayPort, ttl: Int(alloc.lifetime))
        return (listener, Started(relay: relay, mappedIP: alloc.mappedIP))
    }

    private init(client: TurnTCPClient, sshPort: Int, lifetime: UInt32, permitted: [String]) {
        self.client = client
        self.sshPort = sshPort
        self.lifetime = lifetime
        self.permitted = permitted
    }

    /// Allow another peer IP (a later srflx trickle); picked up by the service
    /// loop within a tick.
    func permit(ip: String) {
        lock.lock(); defer { lock.unlock() }
        if !permitted.contains(ip) && !pendingPermits.contains(ip) { pendingPermits.append(ip) }
    }

    func stop() {
        lock.lock()
        let was = stopped
        stopped = true
        lock.unlock()
        if !was { client.close() }   // wakes the service loop's read with an error
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func serviceLoop() {
        // Allocations refresh at half-life; permissions expire at 5 min, so
        // re-assert them at 4.
        var nextAllocRefresh = Date().addingTimeInterval(Double(max(60, lifetime / 2)))
        var nextPermRefresh = Date().addingTimeInterval(240)
        while !isStopped {
            lock.lock()
            let newPermits = pendingPermits
            pendingPermits.removeAll()
            lock.unlock()
            for ip in newPermits where client.createPermission(peerIP: ip) {
                lock.lock(); permitted.append(ip); lock.unlock()
            }

            if let ev = client.readEvent(timeout: 1.0),
               ev.type == STUNMessage.connectionAttemptIndication,
               let connID = ev.u32(STUNMessage.attrConnectionID) {
                let peer = ev.xorAddress(STUNMessage.attrXorPeerAddress)
                FatClientLog.log("p2p: relay connection attempt from \(peer?.ip ?? "?"):\(peer?.port ?? 0)")
                Thread.detachNewThread { [weak self] in self?.serve(connID: connID) }
            }
            if isStopped { break }

            if Date() >= nextAllocRefresh {
                guard let granted = client.refresh() else {
                    FatClientLog.log("p2p: TURN refresh failed — relay session over")
                    break
                }
                nextAllocRefresh = Date().addingTimeInterval(Double(max(60, granted / 2)))
            }
            if Date() >= nextPermRefresh {
                lock.lock(); let ips = permitted; lock.unlock()
                for ip in ips { client.createPermission(peerIP: ip) }
                nextPermRefresh = Date().addingTimeInterval(240)
            }
        }
        client.close()
        onStopped?()
    }

    /// One relayed leg: bind the ConnectionAttempt, then splice the raw pipe
    /// into the local sshd (loopback — reachable from this process, see
    /// REMOTE_P2P_PLAN.md §"Listener splice & the EHOSTUNREACH gotcha").
    private func serve(connID: UInt32) {
        guard let dataFD = client.bindDataConnection(id: connID, timeout: 6) else {
            FatClientLog.log("p2p: ConnectionBind failed for id \(connID)")
            return
        }
        guard let sshFD = P2PTCP.connect(ip: "127.0.0.1", port: sshPort, timeout: 5) else {
            FatClientLog.log("p2p: local sshd :\(sshPort) unreachable for relayed leg")
            Darwin.close(dataFD)
            return
        }
        // The relay leg is the only socket that can observe the far client dying;
        // a blocking write to a vanished client would otherwise hang this pump —
        // and leak the session (fds, PTY, guest tmux view) — indefinitely.
        SocketTuning.boundStalledPeer(dataFD)
        FatForward.splice(dataFD, sshFD)
    }
}
