import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Feature flag

/// The UDP relay + `RelayARQ` transport (the slow-link resilience path) is new,
/// so it ships dark: the proven RFC 6062 TCP relay stays the default until the
/// UDP path is validated on real lossy links, then this flips to true and
/// `.relay/.udp` candidates outrank `.relay/.tcp` (see `P2PCandidate`).
///
/// Toggled by the `BROMURE_P2P_UDP_RELAY` env var (1/true/y) or the
/// `p2p.udpRelay.enabled` UserDefault. Read live so ops can flip it without a
/// rebuild.
enum P2PRelayConfig {
    static var udpRelayEnabled: Bool {
        if let e = ProcessInfo.processInfo.environment["BROMURE_P2P_UDP_RELAY"] {
            let v = e.lowercased()
            return v == "1" || v == "true" || v == "y" || v == "yes"
        }
        return UserDefaults.standard.bool(forKey: "p2p.udpRelay.enabled")
    }
}

// MARK: - Connected UDP socket helper

enum UDPSocket {
    /// A connected UDP socket to `host:port` (numeric or DNS). Connected so
    /// `send`/`recv` need no address and ICMP port-unreachable surfaces as an
    /// error rather than a silent black hole. Returns a blocking fd (caller owns).
    static func connect(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let i = info {
            let fd = socket(i.pointee.ai_family, i.pointee.ai_socktype, i.pointee.ai_protocol)
            if fd >= 0 {
                let rc = i.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, i.pointee.ai_addrlen)
                }
                if rc == 0 { return fd }
                Darwin.close(fd)
            }
            info = i.pointee.ai_next
        }
        return nil
    }
}

// MARK: - TURN-over-UDP client (RFC 5766 long-term auth + UDP relay verbs)

/// One TURN client session against coturn over UDP. Unlike the TCP client
/// (`TurnTCPClient`, one blocking connection per leg) a single UDP socket
/// multiplexes everything: our own request/response transactions AND the relayed
/// peer data (Send/Data indications, then ChannelData once a channel is bound).
/// A dedicated recv loop owns the socket and demultiplexes: STUN responses go to
/// the waiting transaction by transaction-id; peer datagrams go to
/// `onPeerDatagram`. Sends are just `write`s on the connected socket.
final class TurnUDPClient: @unchecked Sendable {
    struct Allocation {
        let relayIP: String
        let relayPort: Int
        let mappedIP: String
        let mappedPort: Int
        let lifetime: UInt32
    }

    /// Called (off the recv thread) for every datagram a permitted peer relayed
    /// to us — the raw ARQ bytes, keyed by the peer's transport address.
    var onPeerDatagram: ((_ key: String, _ ip: String, _ port: Int, _ payload: [UInt8]) -> Void)?

    private let host: String
    private let port: Int
    private let username: String
    private let password: String

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var realm = ""
    private var nonce = ""
    private var key: [UInt8] = []
    private var pending: [[UInt8]: PendingBox] = [:]
    private var peerByChannel: [UInt16: (ip: String, port: Int, key: String)] = [:]
    private var channelByPeerKey: [String: UInt16] = [:]
    private var nextChannel: UInt16 = ChannelData.minChannel
    private var closed = false

    private final class PendingBox {
        let sem = DispatchSemaphore(value: 0)
        var resp: STUNMessage?
    }

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: Lifecycle

    func connect() -> Bool {
        guard let s = UDPSocket.connect(host: host, port: port) else { return false }
        lock.lock(); fd = s; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.recvLoop(s) }
        return true
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let s = fd; fd = -1
        // Wake every in-flight transaction so no caller hangs on teardown.
        let boxes = Array(pending.values); pending.removeAll()
        lock.unlock()
        for b in boxes { b.sem.signal() }
        if s >= 0 { Darwin.close(s) }
    }

    // MARK: Recv loop (owns the socket)

    private func recvLoop(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.recv(s, &buf, buf.count, 0)
            if n <= 0 { break }
            dispatch(Array(buf[0..<n]))
        }
    }

    private func dispatch(_ bytes: [UInt8]) {
        guard let first = bytes.first else { return }
        if ChannelData.isChannelData(first) {
            guard let (ch, payload) = ChannelData.decode(bytes) else { return }
            lock.lock(); let peer = peerByChannel[ch]; lock.unlock()
            if let peer { onPeerDatagram?(peer.key, peer.ip, peer.port, payload) }
            return
        }
        guard let msg = STUNMessage.decode(bytes) else { return }
        if msg.isIndication {
            if msg.type == STUNMessage.dataIndication,
               let peer = msg.xorAddress(STUNMessage.attrXorPeerAddress),
               let data = msg.attr(STUNMessage.attrData) {
                onPeerDatagram?("\(peer.ip):\(peer.port)", peer.ip, peer.port, data)
            }
            return
        }
        // A response — hand it to whoever is waiting on this transaction id.
        lock.lock()
        let box = pending[msg.txid]
        pending[msg.txid] = nil
        lock.unlock()
        if let box { box.resp = msg; box.sem.signal() }
    }

    private func sendDatagram(_ bytes: [UInt8]) {
        lock.lock(); let s = fd; lock.unlock()
        guard s >= 0 else { return }
        _ = bytes.withUnsafeBytes { Darwin.send(s, $0.baseAddress, bytes.count, 0) }
    }

    // MARK: Verbs

    func allocateUDP(timeout: TimeInterval) -> Allocation? {
        let resp = transact(timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.allocateRequest)
            m.add(STUNMessage.attrRequestedTransport, [STUNMessage.protoUDP, 0, 0, 0])
            return m
        }
        guard let resp, resp.isSuccess,
              let relay = resp.xorAddress(STUNMessage.attrXorRelayedAddress),
              let mapped = resp.xorAddress(STUNMessage.attrXorMappedAddress) else { return nil }
        return Allocation(relayIP: relay.ip, relayPort: relay.port,
                          mappedIP: mapped.ip, mappedPort: mapped.port,
                          lifetime: resp.u32(STUNMessage.attrLifetime) ?? 600)
    }

    @discardableResult
    func createPermission(peerIP: String, timeout: TimeInterval = 5) -> Bool {
        let resp = transact(timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.createPermissionRequest)
            guard m.addXorAddress(STUNMessage.attrXorPeerAddress, ip: peerIP, port: 0) else { return nil }
            return m
        }
        return resp?.isSuccess ?? false
    }

    /// Bind (or refresh) a channel to `ip:port` so peer data uses the 4-byte
    /// ChannelData framing instead of ~36-byte Send/Data indications. Idempotent
    /// per peer: re-binding the same peer refreshes the existing channel.
    @discardableResult
    func bindChannel(ip: String, port: Int, timeout: TimeInterval = 5) -> Bool {
        let peerKey = "\(ip):\(port)"
        lock.lock()
        let channel = channelByPeerKey[peerKey] ?? {
            let c = nextChannel
            if nextChannel < ChannelData.maxChannel { nextChannel += 1 }
            channelByPeerKey[peerKey] = c
            peerByChannel[c] = (ip, port, peerKey)
            return c
        }()
        lock.unlock()
        let resp = transact(timeout: timeout) {
            var m = STUNMessage(type: STUNMessage.channelBindRequest)
            m.add(channelNumber: channel)
            guard m.addXorAddress(STUNMessage.attrXorPeerAddress, ip: ip, port: port) else { return nil }
            return m
        }
        if resp?.isSuccess != true {
            // Bind failed — forget the mapping so we keep using Send indications.
            lock.lock(); channelByPeerKey[peerKey] = nil; peerByChannel[channel] = nil; lock.unlock()
            return false
        }
        return true
    }

    func refresh(timeout: TimeInterval = 5) -> UInt32? {
        let resp = transact(timeout: timeout) { STUNMessage(type: STUNMessage.refreshRequest) }
        guard let resp, resp.isSuccess else { return nil }
        return resp.u32(STUNMessage.attrLifetime) ?? 600
    }

    /// Relay `data` to a peer: ChannelData if we've bound a channel for it
    /// (cheap), else a Send indication (works before/without a channel).
    func sendToPeer(ip: String, port: Int, _ data: [UInt8]) {
        let peerKey = "\(ip):\(port)"
        lock.lock(); let channel = channelByPeerKey[peerKey]; lock.unlock()
        if let channel {
            sendDatagram(ChannelData.encode(channel: channel, data))
        } else {
            var m = STUNMessage(type: STUNMessage.sendIndication)
            guard m.addXorAddress(STUNMessage.attrXorPeerAddress, ip: ip, port: port) else { return }
            m.add(STUNMessage.attrData, data)
            sendDatagram(m.encoded())   // indications carry no MESSAGE-INTEGRITY
        }
    }

    // MARK: Authenticated transaction (long-term credential, UDP retransmit)

    /// Run one request→response with the 401/438 realm/nonce dance and RFC 5389
    /// UDP retransmission (500 ms RTO, doubling) until `timeout`.
    private func transact(timeout: TimeInterval, build: () -> STUNMessage?) -> STUNMessage? {
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
            guard let resp = sendAndAwait(msg, timeout: timeout) else { return nil }
            switch resp.errorCode ?? 0 {
            case 401 where !haveKey, 438:
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

    /// Register the transaction, retransmit with a doubling RTO, and wait for the
    /// recv loop to hand back the matching response (or give up at `timeout`).
    private func sendAndAwait(_ msg: STUNMessage, timeout: TimeInterval) -> STUNMessage? {
        let box = PendingBox()
        lock.lock()
        if closed { lock.unlock(); return nil }
        pending[msg.txid] = box
        lock.unlock()
        defer { lock.lock(); pending[msg.txid] = nil; lock.unlock() }

        let bytes = msg.encoded()
        let deadline = Date().addingTimeInterval(timeout)
        var rto: TimeInterval = 0.5
        while Date() < deadline {
            sendDatagram(bytes)
            let wait = min(rto, max(0.01, deadline.timeIntervalSinceNow))
            if box.sem.wait(timeout: .now() + wait) == .success { return box.resp }
            rto = min(rto * 2, 1.6)
        }
        return nil
    }

    private func optionalRealm() -> String? {
        lock.lock(); defer { lock.unlock() }
        return realm.isEmpty ? nil : realm
    }
}

// MARK: - Common listener abstraction

/// A listener-side relay session the broker can track and tear down uniformly,
/// whether it's the RFC 6062 TCP relay (`TurnRelayListener`) or the UDP relay
/// (`TurnUDPRelayListener`).
protocol P2PRelaySession: AnyObject {
    var onStopped: (() -> Void)? { get set }
    func stop()
}

extension TurnRelayListener: P2PRelaySession {}
extension TurnUDPRelayListener: P2PRelaySession {}

// MARK: - Listener-side UDP relay session

/// The listener's whole UDP-relay life: one allocation (RFC 5766 UDP), a
/// permission for the dialer, then — per distinct peer transport address (one
/// per SSH connection the dialer's shim opens) — a `RelayARQ` responder spliced
/// into the local sshd. Refreshes the allocation, permissions, and channels
/// until stopped or the credentials expire. Mirrors `TurnRelayListener` (the TCP
/// relay) but the data plane is datagrams + ARQ instead of RFC 6062 byte pipes.
final class TurnUDPRelayListener: @unchecked Sendable {
    struct Started {
        let relay: P2PCandidate     // the `.relay/.udp` candidate to advertise
        let mappedIP: String        // our public IP as coturn saw the control leg
    }

    private let client: TurnUDPClient
    private let sshPort: Int
    private let lifetime: UInt32
    private let lock = NSLock()
    private var permitted: [String]
    private var pendingPermits: [String] = []
    private var peers: [String: ARQEndpoint] = [:]
    private var stopped = false
    /// Bound so one misbehaving dialer can't exhaust us with peer sessions.
    private let maxPeers = 32
    var onStopped: (() -> Void)?

    static func start(creds: TurnCredentials, permitIP: String, sshPort: Int)
        -> (listener: TurnUDPRelayListener, started: Started)? {
        guard let (host, port) = TurnRelayTransport.preferredUDPEndpoint(creds.urls) else {
            FatClientLog.log("p2p: no turn:…?transport=udp URL in credentials")
            return nil
        }
        let client = TurnUDPClient(host: host, port: port,
                                   username: creds.username, password: creds.credential)
        guard client.connect() else {
            FatClientLog.log("p2p: UDP relay \(host):\(port) unreachable")
            return nil
        }
        guard let alloc = client.allocateUDP(timeout: 6) else {
            FatClientLog.log("p2p: TURN UDP allocate failed at \(host):\(port)")
            client.close()
            return nil
        }
        guard client.createPermission(peerIP: permitIP) else {
            FatClientLog.log("p2p: TURN UDP permission for \(permitIP) refused")
            client.close()
            return nil
        }
        FatClientLog.log("p2p: TURN UDP relay allocated \(alloc.relayIP):\(alloc.relayPort) "
            + "at \(host):\(port) (lifetime \(alloc.lifetime)s, permit \(permitIP))")
        let listener = TurnUDPRelayListener(client: client, sshPort: sshPort,
                                            lifetime: alloc.lifetime, permitted: [permitIP])
        client.onPeerDatagram = { [weak listener] key, ip, port, payload in
            listener?.handlePeer(key: key, ip: ip, port: port, payload: payload)
        }
        Thread.detachNewThread { listener.serviceLoop() }
        let relay = P2PCandidate(kind: .relay, proto: .udp,
                                 ip: alloc.relayIP, port: alloc.relayPort, ttl: Int(alloc.lifetime))
        return (listener, Started(relay: relay, mappedIP: alloc.mappedIP))
    }

    private init(client: TurnUDPClient, sshPort: Int, lifetime: UInt32, permitted: [String]) {
        self.client = client
        self.sshPort = sshPort
        self.lifetime = lifetime
        self.permitted = permitted
    }

    func permit(ip: String) {
        lock.lock(); defer { lock.unlock() }
        if !permitted.contains(ip) && !pendingPermits.contains(ip) { pendingPermits.append(ip) }
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let eps = Array(peers.values); peers.removeAll()
        lock.unlock()
        for ep in eps { ep.stop() }
        client.close()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Route a relayed datagram to its peer's ARQ, creating the session (and its
    /// splice into sshd) on the peer's first packet — which must be an ARQ SYN.
    private func handlePeer(key: String, ip: String, port: Int, payload: [UInt8]) {
        lock.lock()
        if stopped { lock.unlock(); return }
        if let ep = peers[key] { lock.unlock(); ep.receive(payload); return }
        // New peer: only an ARQ SYN opens a session (anything else is stray).
        guard let seg = ARQSegment.decode(payload), seg.cmd == .syn else { lock.unlock(); return }
        guard peers.count < maxPeers else {
            lock.unlock()
            FatClientLog.log("p2p: UDP relay peer cap hit — ignoring \(key)")
            return
        }
        guard let ep = ARQEndpoint(conv: seg.conv, isInitiator: false,
                                   send: { [weak self] d in self?.client.sendToPeer(ip: ip, port: port, d) }) else {
            lock.unlock(); return
        }
        ep.onStop = { [weak self] in self?.removePeer(key) }
        peers[key] = ep
        lock.unlock()

        ep.receive(payload)   // feed the SYN so the SYNACK goes out
        // Upgrade this peer to ChannelData framing (best-effort; Send indications
        // work meanwhile), and splice its stream into the local sshd.
        Thread.detachNewThread { [weak self] in self?.client.bindChannel(ip: ip, port: port) }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            guard let sshFD = P2PTCP.connect(ip: "127.0.0.1", port: self.sshPort, timeout: 5) else {
                FatClientLog.log("p2p: local sshd :\(self.sshPort) unreachable for UDP-relayed leg")
                ep.stop()
                return
            }
            FatForward.splice(ep.localFD, sshFD)
        }
    }

    private func removePeer(_ key: String) {
        lock.lock(); peers[key] = nil; lock.unlock()
    }

    private func serviceLoop() {
        var nextAllocRefresh = Date().addingTimeInterval(Double(max(60, lifetime / 2)))
        var nextPermRefresh = Date().addingTimeInterval(240)
        while !isStopped {
            lock.lock()
            let newPermits = pendingPermits; pendingPermits.removeAll()
            lock.unlock()
            for ip in newPermits where client.createPermission(peerIP: ip) {
                lock.lock(); permitted.append(ip); lock.unlock()
            }

            if Date() >= nextAllocRefresh {
                guard let granted = client.refresh() else {
                    FatClientLog.log("p2p: TURN UDP refresh failed — relay session over")
                    break
                }
                nextAllocRefresh = Date().addingTimeInterval(Double(max(60, granted / 2)))
            }
            if Date() >= nextPermRefresh {
                lock.lock()
                let ips = permitted
                let peerAddrs = peers.keys.compactMap { key -> (String, Int)? in
                    let parts = key.split(separator: ":")
                    guard parts.count == 2, let p = Int(parts[1]) else { return nil }
                    return (String(parts[0]), p)
                }
                lock.unlock()
                for ip in ips { client.createPermission(peerIP: ip) }
                for (ip, p) in peerAddrs { client.bindChannel(ip: ip, port: p) }   // refresh channels
                nextPermRefresh = Date().addingTimeInterval(240)
            }
            if isStopped { break }
            Thread.sleep(forTimeInterval: 1.0)
        }
        stop()
        onStopped?()
    }
}

// MARK: - Dialer-side UDP relay

/// The dialer connects to the listener's relayed transport address as an ordinary
/// UDP peer — it speaks no TURN (coturn wraps/unwraps the framing for the
/// listener). It runs the `RelayARQ` initiator over a raw connected UDP socket
/// and hands back a blocking loopback fd carrying the reliable SSH stream, so the
/// shim's `FatForward.splice` uses it exactly like a TCP candidate's fd.
enum TurnUDPDialer {
    static func open(relayIP: String, relayPort: Int, timeout: TimeInterval) -> Int32? {
        guard let fd = UDPSocket.connect(host: relayIP, port: relayPort) else { return nil }
        let conv = UInt32.random(in: 1 ... .max)
        guard let ep = ARQEndpoint(conv: conv, isInitiator: true,
                                   send: { bytes in
                                       _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
                                   }) else {
            Darwin.close(fd); return nil
        }
        // Closing the UDP socket wakes and ends the recv thread; do it once the
        // ARQ tears down (FIN, dead-link, or the spliced fd closing).
        ep.onStop = { Darwin.close(fd) }
        // The recv thread strong-captures `ep`, keeping the session alive until
        // the socket closes — no external owner needed.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                ep.receive(Array(buf[0..<n]))
            }
        }
        guard ep.waitEstablished(timeout: timeout) else {
            ep.stop()   // closes fd via onStop
            return nil
        }
        return ep.localFD
    }
}

// MARK: - Polymorphic candidate dial

/// Open a transport connection to a winning candidate and return a blocking fd
/// the shim can `FatForward.splice`. TCP candidates connect directly; a
/// `.relay/.udp` candidate goes through the UDP relay + ARQ. This is the single
/// seam that lets the rest of the dialer stay transport-agnostic.
enum P2PDial {
    static func connect(_ c: P2PCandidate, timeout: TimeInterval) -> Int32? {
        switch (c.kind, c.proto) {
        case (.relay, .udp):
            return TurnUDPDialer.open(relayIP: c.ip, relayPort: c.port, timeout: timeout)
        default:
            return P2PTCP.connect(ip: c.ip, port: c.port, timeout: timeout)
        }
    }
}
