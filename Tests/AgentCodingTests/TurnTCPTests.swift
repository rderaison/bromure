import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bromure_ac

// The TURN-TCP client and the listener-side relay session, exercised against a
// scripted coturn double over real loopback sockets: 401 realm/nonce dance,
// RFC 6062 allocate/permission, ConnectionAttempt → ConnectionBind, and the
// full relayed byte path spliced into a fake sshd. No network, no coturn — but
// every fd and every STUN transaction is real.

@Suite("TURN-TCP relay", .serialized)
struct TurnTCPTests {

    /// Minimal coturn double: one TURN port (control + data connections), one
    /// relay port (where the "peer" connects). First TURN connection is the
    /// control leg; later ones must open with ConnectionBind (RFC 6062 §4.3).
    /// Requires the long-term-credential dance before honoring Allocate.
    final class FakeCoturn: @unchecked Sendable {
        let port: Int
        let relayPort: Int
        private let lfd: Int32
        private let relayLFD: Int32
        private let username: String
        private let password: String
        private let realm = "bromure.io"
        private let nonce = "abcdef0123456789"
        private let lock = NSLock()
        private var controlFD: Int32 = -1
        private var seenControl = false
        private var nextConnID: UInt32 = 7
        private var pendingPeers: [UInt32: Int32] = [:]
        private(set) var permitted: [String] = []
        private(set) var sawUnauthenticatedAllocate = false
        /// Refuse this many CreatePermissions for an address (403), then
        /// grant them — a permission that fails once.
        private var refusals: [String: Int] = [:]
        func refusePermission(_ ip: String, times: Int) { lock.withLock { refusals[ip] = times } }

        init?(username: String, password: String) {
            self.username = username
            self.password = password
            let (a, ap) = FatForward.listenEphemeral(bindAll: false)
            let (b, bp) = FatForward.listenEphemeral(bindAll: false)
            guard a >= 0, b >= 0 else { return nil }
            lfd = a; port = ap
            relayLFD = b; relayPort = bp
            Thread.detachNewThread { [weak self] in self?.acceptTurn() }
            Thread.detachNewThread { [weak self] in self?.acceptRelay() }
        }

        func stop() {
            Darwin.close(lfd)
            Darwin.close(relayLFD)
        }

        var permittedIPs: [String] { lock.lock(); defer { lock.unlock() }; return permitted }

        private func acceptTurn() {
            while true {
                let fd = Darwin.accept(lfd, nil, nil)
                if fd < 0 { if errno == EINTR { continue }; break }
                lock.lock()
                let isControl = !seenControl
                seenControl = true
                if isControl { controlFD = fd }
                lock.unlock()
                if isControl {
                    Thread.detachNewThread { [weak self] in self?.serveControl(fd) }
                } else {
                    Thread.detachNewThread { [weak self] in self?.serveData(fd) }
                }
            }
        }

        private func serveControl(_ fd: Int32) {
            while let req = STUNTCP.read(fd, deadline: Date().addingTimeInterval(30)) {
                var resp: STUNMessage
                switch req.type {
                case STUNMessage.bindingRequest:
                    resp = STUNMessage(type: STUNMessage.bindingSuccess, txid: req.txid)
                    resp.addXorAddress(STUNMessage.attrXorMappedAddress, ip: "203.0.113.7", port: 42424)
                case STUNMessage.allocateRequest where !authed(req):
                    lock.lock(); sawUnauthenticatedAllocate = true; lock.unlock()
                    resp = STUNMessage(type: STUNMessage.allocateError, txid: req.txid)
                    resp.add(STUNMessage.attrErrorCode, [0, 0, 4, 1])   // 401
                    resp.add(STUNMessage.attrRealm, string: realm)
                    resp.add(STUNMessage.attrNonce, string: nonce)
                case STUNMessage.allocateRequest:
                    #expect(req.attr(STUNMessage.attrRequestedTransport)?.first == STUNMessage.protoTCP)
                    resp = STUNMessage(type: STUNMessage.allocateSuccess, txid: req.txid)
                    resp.addXorAddress(STUNMessage.attrXorRelayedAddress, ip: "127.0.0.1", port: relayPort)
                    resp.addXorAddress(STUNMessage.attrXorMappedAddress, ip: "203.0.113.7", port: 42424)
                    resp.add(STUNMessage.attrLifetime, u32: 600)
                case STUNMessage.createPermissionRequest where authed(req):
                    let peer = req.xorAddress(STUNMessage.attrXorPeerAddress)
                    let refuse: Bool = lock.withLock {
                        guard let ip = peer?.ip, let n = refusals[ip], n > 0 else { return false }
                        refusals[ip] = n - 1
                        return true
                    }
                    if refuse {
                        resp = STUNMessage(type: 0x0118, txid: req.txid)   // CreatePermission error
                        resp.add(STUNMessage.attrErrorCode, [0, 0, 4, 3])  // 403
                    } else {
                        if let peer { lock.lock(); permitted.append(peer.ip); lock.unlock() }
                        resp = STUNMessage(type: STUNMessage.createPermissionSuccess, txid: req.txid)
                    }
                case STUNMessage.refreshRequest where authed(req):
                    resp = STUNMessage(type: STUNMessage.refreshSuccess, txid: req.txid)
                    resp.add(STUNMessage.attrLifetime, u32: 600)
                default:
                    resp = STUNMessage(type: req.type | 0x0110, txid: req.txid)
                    resp.add(STUNMessage.attrErrorCode, [0, 0, 4, 0])   // 400
                }
                if !STUNTCP.send(fd, resp) { break }
            }
            Darwin.close(fd)
        }

        /// Long-term-credential check: USERNAME/REALM/NONCE present and the
        /// MESSAGE-INTEGRITY HMAC recomputes over the re-encoded message.
        private func authed(_ req: STUNMessage) -> Bool {
            guard req.string(STUNMessage.attrUsername) == username,
                  req.string(STUNMessage.attrRealm) == realm,
                  req.string(STUNMessage.attrNonce) == nonce,
                  let mi = req.attr(STUNMessage.attrMessageIntegrity) else { return false }
            var unsigned = STUNMessage(type: req.type, txid: req.txid)
            unsigned.attrs = req.attrs.filter { $0.type != STUNMessage.attrMessageIntegrity }
            unsigned.sign(key: STUNMessage.longTermKey(username: username, realm: realm,
                                                       password: password))
            return unsigned.attr(STUNMessage.attrMessageIntegrity) == mi
        }

        private func acceptRelay() {
            while true {
                var peer = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let fd = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(relayLFD, $0, &len) }
                }
                if fd < 0 { if errno == EINTR { continue }; break }
                lock.lock()
                let ip = FatForward.peerIPv4(peer)
                let allowed = permitted.contains(ip)
                let id = nextConnID
                nextConnID += 1
                if allowed { pendingPeers[id] = fd }
                let control = controlFD
                lock.unlock()
                guard allowed else { Darwin.close(fd); continue }   // RFC 6062 §5.3
                var attempt = STUNMessage(type: STUNMessage.connectionAttemptIndication)
                attempt.add(STUNMessage.attrConnectionID, u32: id)
                attempt.addXorAddress(STUNMessage.attrXorPeerAddress, ip: ip, port: 12345)
                _ = STUNTCP.send(control, attempt)
            }
        }

        private func serveData(_ fd: Int32) {
            guard let bind = STUNTCP.read(fd, deadline: Date().addingTimeInterval(10)),
                  bind.type == STUNMessage.connectionBindRequest, authed(bind),
                  let id = bind.u32(STUNMessage.attrConnectionID) else { Darwin.close(fd); return }
            lock.lock()
            let peerFD = pendingPeers.removeValue(forKey: id)
            lock.unlock()
            guard let peerFD else { Darwin.close(fd); return }
            let ok = STUNMessage(type: STUNMessage.connectionBindSuccess, txid: bind.txid)
            guard STUNTCP.send(fd, ok) else { Darwin.close(fd); Darwin.close(peerFD); return }
            FatForward.splice(fd, peerFD)
        }
    }

    /// A loopback UDP STUN responder — answers Binding requests with a fixed
    /// XOR-MAPPED-ADDRESS. Can bind a SPECIFIC port so it can share a port
    /// number with the TCP fake (separate protocol namespaces), which is how
    /// the UDP-preference test tells the two paths apart.
    final class FakeStunUDP: @unchecked Sendable {
        let port: Int
        private let fd: Int32
        init?(port requested: Int = 0, mappedIP: String, mappedPort: Int) {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { return nil }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(requested).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else { Darwin.close(s); return nil }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            fd = s
            port = Int(UInt16(bigEndian: bound.sin_port))
            Thread.detachNewThread { [fd = s] in
                var buf = [UInt8](repeating: 0, count: 1500)
                while true {
                    var peer = sockaddr_storage()
                    var plen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let n = withUnsafeMutablePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &plen)
                        }
                    }
                    guard n > 0 else { break }
                    guard let req = STUNMessage.decode(Array(buf[0..<n])),
                          req.type == STUNMessage.bindingRequest else { continue }
                    var resp = STUNMessage(type: STUNMessage.bindingSuccess, txid: req.txid)
                    resp.addXorAddress(STUNMessage.attrXorMappedAddress, ip: mappedIP, port: mappedPort)
                    let out = resp.encoded()
                    _ = withUnsafePointer(to: &peer) { peerPtr in
                        peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            out.withUnsafeBytes { raw in
                                Darwin.sendto(fd, raw.baseAddress, out.count, 0, sa, plen)
                            }
                        }
                    }
                }
            }
        }
        func stop() { Darwin.close(fd) }
    }

    /// A loopback echo server standing in for the listener's sshd.
    final class EchoServer: @unchecked Sendable {
        let port: Int
        private let lfd: Int32
        init?() {
            let (fd, port) = FatForward.listenEphemeral(bindAll: false)
            guard fd >= 0 else { return nil }
            lfd = fd; self.port = port
            Thread.detachNewThread { [lfd] in
                while true {
                    let c = Darwin.accept(lfd, nil, nil)
                    if c < 0 { break }
                    Thread.detachNewThread {
                        var buf = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = Darwin.read(c, &buf, buf.count)
                            if n <= 0 { break }
                            var off = 0
                            while off < n {
                                let w = buf.withUnsafeBytes {
                                    Darwin.write(c, $0.baseAddress!.advanced(by: off), n - off)
                                }
                                if w <= 0 { break }
                                off += w
                            }
                        }
                        Darwin.close(c)
                    }
                }
            }
        }
        func stop() { Darwin.close(lfd) }
    }

    private func makeCreds(port: Int) throws -> TurnCredentials {
        try JSONDecoder().decode(TurnCredentials.self, from: Data("""
        {"turn":{"urls":["stun:127.0.0.1:\(port)",
                         "turn:127.0.0.1:\(port)?transport=udp",
                         "turn:127.0.0.1:\(port)?transport=tcp"],
                 "username":"1893456000:conn-under-test","credential":"s3cr3t",
                 "ttlSeconds":3600,"expiresAt":"2030-01-01T00:00:00Z","region":"default"}}
        """.utf8))
    }

    @Test("publicAddress prefers TCP when the relay answers it")
    func stunBindingPrefersTCP() throws {
        // TCP and UDP fakes share one port number (separate protocol
        // namespaces) and return DIFFERENT mapped addresses — whichever comes
        // back is the path that won.
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let udp = try #require(FakeStunUDP(port: turn.port, mappedIP: "198.51.100.5", mappedPort: 5555))
        defer { udp.stop() }
        let pub = TurnTCPClient.publicAddress(host: "127.0.0.1", port: turn.port, timeout: 5)
        #expect(pub?.ip == "203.0.113.7")
        #expect(pub?.port == 42424)
    }

    @Test("publicAddress falls back to UDP when TCP is dead")
    func stunBindingUDPFallback() throws {
        // Only a UDP responder: the TCP connect refuses instantly on loopback
        // and the UDP leg answers with the remaining budget.
        let udp = try #require(FakeStunUDP(mappedIP: "198.51.100.5", mappedPort: 5555))
        defer { udp.stop() }
        let pub = TurnTCPClient.publicAddress(host: "127.0.0.1", port: udp.port, timeout: 5)
        #expect(pub?.ip == "198.51.100.5")
        #expect(pub?.port == 5555)
    }

    @Test("allocate runs the 401 dance and yields the relayed + mapped addresses")
    func allocate() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let client = TurnTCPClient(host: "127.0.0.1", port: turn.port,
                                   username: "1893456000:conn-under-test", password: "s3cr3t")
        defer { client.close() }
        #expect(client.connect(timeout: 5))
        let alloc = client.allocateTCP(timeout: 5)
        #expect(turn.sawUnauthenticatedAllocate)   // 401 first, then signed
        #expect(alloc?.relayIP == "127.0.0.1")
        #expect(alloc?.relayPort == turn.relayPort)
        #expect(alloc?.mappedIP == "203.0.113.7")
        #expect(alloc?.lifetime == 600)
        #expect(client.createPermission(peerIP: "127.0.0.1"))
        #expect(turn.permittedIPs == ["127.0.0.1"])
        #expect(client.refresh() == 600)
    }

    @Test("TurnRelayListener relays a peer's bytes into the local sshd, end to end")
    func relayEndToEnd() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let sshd = try #require(EchoServer())
        defer { sshd.stop() }

        let started = TurnRelayListener.start(creds: try makeCreds(port: turn.port),
                                              permitIPs: ["127.0.0.1"], sshPort: sshd.port,
                                              admit: { _ in true })   // loopback fake relay
        let (listener, info) = try #require(started)
        defer { listener.stop() }
        #expect(info.relay.kind == .relay)
        #expect(info.relay.proto == .tcp)
        #expect(info.relay.ip == "127.0.0.1")
        #expect(info.relay.port == turn.relayPort)
        #expect(info.mappedIP == "203.0.113.7")
        #expect(turn.permittedIPs.contains("127.0.0.1"))

        // The "dialer": an ordinary TCP connection to the relayed address —
        // exactly what P2PDirectDialer does with a relay candidate.
        let peer = try #require(P2PTCP.connect(ip: info.relay.ip, port: info.relay.port, timeout: 5))
        defer { Darwin.close(peer) }
        let probe = [UInt8]("ssh-would-go-here".utf8)
        #expect(probe.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, probe.count) } == probe.count)

        // Expect it echoed back through: relay → ConnectionBind leg →
        // listener splice → sshd echo → all the way back.
        var got = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(8)
        while got.count < probe.count && Date() < deadline {
            var pfd = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let n = Darwin.read(peer, &buf, buf.count)
            guard n > 0 else { break }
            got += buf[0..<n]
        }
        #expect(got == probe)
    }

    /// Board report: out of Asia to a US host, the relay rung timed out. The
    /// dialer learned its address from ITS nearest relay, the listener
    /// allocated on ITS own (another continent) and permitted only that one
    /// address — a network with several exits reaches the far relay from
    /// another, and the relay dropped it. Every address the dialer reports is
    /// permitted now, and the dialer asks every relay.
    @Test("the relay permits every address the dialer was seen from")
    func everyDialerAddressPermitted() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let sshd = try #require(EchoServer())
        defer { sshd.stop() }
        // As seen by a far relay first (another exit), then by this one.
        let started = TurnRelayListener.start(creds: try makeCreds(port: turn.port),
                                              permitIPs: ["198.51.100.9", "127.0.0.1"], sshPort: sshd.port,
                                              admit: { _ in true })   // loopback fake relay
        let (listener, info) = try #require(started)
        defer { listener.stop() }
        #expect(turn.permittedIPs.contains("198.51.100.9") && turn.permittedIPs.contains("127.0.0.1"))
        // The dialer arrives from the second address and still gets through.
        let peer = try #require(P2PTCP.connect(ip: info.relay.ip, port: info.relay.port, timeout: 5))
        defer { Darwin.close(peer) }
        let probe = [UInt8]("hello".utf8)
        #expect(probe.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, probe.count) } == probe.count)
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 16)
        let deadline = Date().addingTimeInterval(8)
        while got.count < probe.count && Date() < deadline {
            var pfd = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let n = Darwin.read(peer, &buf, buf.count)
            guard n > 0 else { break }
            got += buf[0..<n]
        }
        #expect(got == probe)

        // The dialer asks one STUN endpoint per relay host, nearest first.
        let urls = ["stun:turn-a.sg.example:3478", "turns:turn-a.sg.example:5349?transport=tcp",
                    "turn:turn-a.us.example:3478?transport=tcp", "stun:turn-a.eu.example:3478"]
        #expect(TurnRelayTransport.stunEndpointsPerHost(urls).map { "\($0.host):\($0.port)" }
                == ["turn-a.sg.example:3478", "turn-a.us.example:3478", "turn-a.eu.example:3478"])
    }

    /// Finding (CWE-755): a permission that failed (at allocation, or added
    /// later) was dropped — never retried, never renewed — and the far
    /// relay kept refusing the dialer from that exit.
    @Test("a permission refused (at allocation and on a retry) is retried until it is installed, and the dialer then gets through")
    func refusedPermissionRetried() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let sshd = try #require(EchoServer())
        defer { sshd.stop() }
        turn.refusePermission("127.0.0.1", times: 2)   // at allocation, and its first retry
        let started = TurnRelayListener.start(creds: try makeCreds(port: turn.port),
                                              permitIPs: ["198.51.100.9", "127.0.0.1"], sshPort: sshd.port,
                                              admit: { _ in true })   // loopback fake relay
        let (listener, info) = try #require(started)
        defer { listener.stop() }
        let deadline = Date().addingTimeInterval(8)
        while !turn.permittedIPs.contains("127.0.0.1") && Date() < deadline { usleep(100_000) }
        #expect(turn.permittedIPs.contains("127.0.0.1"))
        let peer = try #require(P2PTCP.connect(ip: info.relay.ip, port: info.relay.port, timeout: 5))
        defer { Darwin.close(peer) }
        let probe = [UInt8]("again".utf8)
        #expect(probe.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, probe.count) } == probe.count)
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 16)
        let until = Date().addingTimeInterval(8)
        while got.count < probe.count && Date() < until {
            var pfd = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let n = Darwin.read(peer, &buf, buf.count)
            guard n > 0 else { break }
            got += buf[0..<n]
        }
        #expect(got == probe)
    }

    /// Review: with EVERY address refused at allocation the listener gave
    /// up (closed, nil) — the relay rung was lost for the grant.
    @Test("every permission refused at allocation: the relay is kept and retried")
    func allRefusedStillRetried() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        let sshd = try #require(EchoServer())
        defer { sshd.stop() }
        turn.refusePermission("127.0.0.1", times: 2)
        let started = TurnRelayListener.start(creds: try makeCreds(port: turn.port),
                                              permitIPs: ["127.0.0.1"], sshPort: sshd.port,
                                              admit: { _ in true })   // loopback fake relay
        let (listener, _) = try #require(started)
        defer { listener.stop() }
        let deadline = Date().addingTimeInterval(10)
        while !turn.permittedIPs.contains("127.0.0.1") && Date() < deadline { usleep(100_000) }
        #expect(turn.permittedIPs.contains("127.0.0.1"))
    }

    /// Finding (CWE-807): the permissions are the ACL in front of sshd and
    /// came from unsigned signalling — every srflx the peer sent was let
    /// in, any string, no cap. Only public unicast addresses, a few at most.
    @Test("only public unicast addresses are let in, a few per allocation")
    func permitsArePublicAndCapped() {
        for ip in ["8.8.8.8", "203.0.114.1", "2606:4700::1111", "2a00:1450:4001::64"] {
            #expect(RelayPermits.isPublicUnicast(ip), "\(ip)")
        }
        for ip in ["10.1.2.3", "172.20.0.1", "192.168.1.1", "127.0.0.1", "169.254.1.1", "100.64.0.1",
                   "0.0.0.0", "224.0.0.1", "255.255.255.255", "198.51.100.9", "203.0.113.7", "192.0.2.1",
                   "::1", "::", "fe80::1", "fd00::1", "ff02::1", "2001:db8::1", "::ffff:8.8.8.8",
                   "example.com", "8.8.8", ""] {
            #expect(!RelayPermits.isPublicUnicast(ip), "\(ip)")
        }
        let many = (1...10).map { "8.8.8.\($0)" }
        #expect(RelayPermits.admissible(["10.0.0.1"] + many + ["8.8.8.1"]) == Array(many.prefix(RelayPermits.maxAddresses)))
        var p = RelayPermits(installed: ["8.8.8.1", "10.0.0.1"])
        #expect(p.installed == ["8.8.8.1"])
        let privateOne = p.add("192.168.0.9")
        let fill = [p.add("8.8.8.2"), p.add("8.8.8.3"), p.add("8.8.8.4")]
        let overCap = p.add("8.8.8.5")
        let again = p.add("8.8.8.4")
        #expect(!privateOne)
        #expect(fill == [true, true, true])
        #expect(!overCap)   // the cap
        #expect(again)      // already queued: fine

        // Review: an address whose CreatePermission is under way still
        // counts — a late one can't take its slot, then both get in.
        var q = RelayPermits(installed: ["8.8.8.1", "8.8.8.2", "8.8.8.3"], pending: ["8.8.8.4"])
        let inFlight = q.takeOne()
        let late = q.add("8.8.8.5")
        #expect(inFlight?.ip == "8.8.8.4")
        #expect(!late)
        let requeued = q.record("8.8.8.4", tries: 0, ok: false)
        #expect(requeued && q.pending.map(\.ip) == ["8.8.8.4"])
        _ = q.takeOne()
        _ = q.record("8.8.8.4", tries: 1, ok: true)
        #expect(q.installed.count == RelayPermits.maxAddresses && q.inFlight.isEmpty)
    }

    @Test("RelayPermits: installed only on success, a failure retried up to the cap, renewals of what's installed")
    func relayPermitsBookkeeping() {
        var p = RelayPermits(installed: ["a"], pending: ["b"], admit: { _ in true })
        p.add("a"); p.add("b"); p.add("c")
        #expect(p.pending.map(\.ip) == ["b", "c"])
        let first = p.take()
        #expect(p.pending.isEmpty)
        let bAgain = p.record("b", tries: first[0].tries, ok: true)
        let cAgain = p.record("c", tries: first[1].tries, ok: false)
        #expect(!bAgain)
        #expect(cAgain)   // queued again
        #expect(p.installed == ["a", "b"])
        var tries = 0
        while let c = p.take().first {
            tries += 1
            if !p.record(c.ip, tries: c.tries, ok: false) { break }
        }
        #expect(tries == RelayPermits.maxTries - 1)   // given up at the cap
        #expect(p.pending.isEmpty && !p.installed.contains("c"))
        p.renewalFailed("a")
        #expect(p.pending.map(\.ip) == ["a"] && p.installed.contains("a"))
        #expect(p.pending.first?.tries == RelayPermits.maxTries - RelayPermits.renewalTries)
        #expect(p.takeOne()?.ip == "a" && p.takeOne() == nil)
    }

    @Test("an unpermitted peer never reaches the listener")
    func unpermittedPeerDropped() throws {
        let turn = try #require(FakeCoturn(username: "1893456000:conn-under-test", password: "s3cr3t"))
        defer { turn.stop() }
        // No permission installed: the relay must close the peer leg without
        // ever surfacing a ConnectionAttempt.
        let fd = try #require(P2PTCP.connect(ip: "127.0.0.1", port: turn.relayPort, timeout: 5))
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 8)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pfd, 1, 2000) > 0)          // readable = EOF
        #expect(Darwin.read(fd, &buf, buf.count) == 0)
    }
}
