#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-to-HTTPS reverse proxy for `dl-cdn.alpinelinux.org`. The guest
/// makes plain HTTP requests to us; we re-emit them as HTTPS using
/// `URLSession` (i.e. Apple's networking stack), and stream the response
/// back. This sidesteps the various ways the guest's TLS stacks
/// (apk-tools' OpenSSL 3.x, busybox-wget's bundled TLS) fail against
/// VPNs / corporate MITM boxes that the host's URLSession handles fine.
///
/// Integrity is preserved end-to-end at the package layer: apk verifies
/// each `.apk` and the `APKINDEX` against RSA keys baked into the
/// `alpine-keys` package we ship in the initramfs, regardless of
/// transport.
///
/// Scope (it is not an open relay): only the guest's own subnet may
/// connect (`admitsPeer`) — never the Mac itself or the LAN.
///
/// Lifecycle: bind a TCP listener on 0.0.0.0:<auto-port> before the VM
/// boots; pass `http://<guest-visible host IP>:<port>` into the kernel
/// cmdline and `setup.sh`/`postinstall.sh` environment; tear down when
/// the bake exits. `mirrorURL` uses the default 192.168.64.0/24 gateway
/// (AC's provisioner rides VMNetSwitch's default subnet); flows on other
/// subnets (the browser bake's ascending switch/per-VM vmnet) build the
/// guest URL with `guestBase(host:)` and the actual gateway IP.
///
/// Shared by the AC Ubuntu bake (UbuntuImageManager) and the browser
/// image bake/postinstall (LinuxImageManager) — it's what makes guest
/// package fetches work on hosts where guest-direct TLS doesn't
/// (VPN/MITM setups, the build server).
public final class AlpinePackageProxy: @unchecked Sendable {
    /// vmnet's NAT gateway. macOS Virtualization framework's shared mode
    /// hands out 192.168.64.0/24 with .1 as the host-side gateway IP.
    static let guestReachableHost = "192.168.64.1"

    /// Default upstream for reverse-proxy (path-only) requests, which
    /// is what the bake's alpine_repo and modloop cmdline URLs use.
    private static let defaultReverseUpstream = "dl-cdn.alpinelinux.org"

    /// Per-bake record of every upstream host we proxied to (and the
    /// number of requests). Dumped on stop() so a successful bake's
    /// network footprint is visible — that's how we build (or audit)
    /// the production allowlist. Concurrent worker queues access
    /// this, so guard with a lock.
    private let contactedLock = NSLock()
    private var contactedHosts: [String: Int] = [:]
    /// Guest connections accepted (under `contactedLock`).
    private var acceptedCount = 0

    private func recordHost(_ host: String) {
        contactedLock.lock()
        defer { contactedLock.unlock() }
        contactedHosts[host, default: 0] += 1
    }

    /// Hard cap on the request-header bytes we'll buffer before parsing.
    /// Real apk-tools / busybox-wget headers are well under 1 KB; this
    /// cap is purely a defence against a stuck client streaming garbage.
    private static let maxHeaderSize = 16 * 1024

    private let acceptQueue = DispatchQueue(
        label: "io.bromure.ac.alpineproxy.accept", qos: .utility)
    private let workQueue = DispatchQueue(
        label: "io.bromure.ac.alpineproxy.work",
        qos: .utility, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    public private(set) var mirrorURL: URL?
    /// The bound port (0 until `start()` succeeds).
    public private(set) var port: UInt16 = 0

    /// The guest's gateway (the address it reaches us on) and its /24 —
    /// the only peers `acceptOne` serves. Set by `start(guestGateway:)`.
    private var gateway: UInt32 = 0
    private static let guestMask: UInt32 = 0xFFFF_FF00

    public init() {}

    /// Guest-visible base URL for a guest whose gateway is `host` —
    /// e.g. the NetworkFilter/VMNetSwitch gateway IP.
    public func guestBase(host: String) -> URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    // Per-request URLSession is created inside `streamRequest` so the
    // streaming delegate's lifetime matches one HTTP hop. No shared
    // session state — connection pooling per host is still done by
    // URLSession internally but isolated per request, which keeps
    // memory bounded.

    /// Bind and start listening for the guest whose gateway (the host side
    /// of its network, the address it reaches us on) is `guestGateway`.
    /// Bound to 0.0.0.0 — the guest's interface may not exist until its VM
    /// boots — but only that guest's /24 is served. Throws on bind / listen
    /// failure, or an unparsable gateway.
    public func start(guestGateway: String) throws {
        guard let gw = Self.ipv4(guestGateway) else { throw Error.gateway(guestGateway) }
        gateway = gw
        // Globally ignore SIGPIPE. Our `ProxySocket.write` calls in
        // splice / writeStatus / writeResponse hit a closed client
        // socket the moment a guest gives up mid-download (curl
        // returned 23, npm bailed, etc.). Default SIGPIPE disposition
        // is "terminate the process" — no crash log, no diagnostic
        // report, just silent exit. Per-socket SO_NOSIGPIPE below is
        // belt-and-braces; this is the suspenders.
        signal(SIGPIPE, SIG_IGN)

        let fd = ProxySocket.tcp(AF_INET)
        guard fd >= 0 else { throw Error.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   &yes, socklen_t(MemoryLayout<Int32>.size))
        ProxySocket.noSigPipe(fd)

        // port = 0: let the kernel pick a free ephemeral port. Avoids
        // clashing with whatever else the user has running on 8080 etc.
        var addr = ProxySocket.anyAddress(port: 0)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                ProxySocket.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            let e = errno
            close(fd)
            throw Error.bind(e)
        }

        // Read back the actual port the kernel handed us.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        self.port = port

        if ProxySocket.listen(fd, 16) != 0 {
            let e = errno
            close(fd)
            throw Error.listen(e)
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.activate()

        let url = URL(string: "http://\(Self.guestReachableHost):\(port)")!
        mirrorURL = url
        // The guest URL is the caller's (`guestBase(host:)`, the switch's
        // real gateway) — `url` above is only the NAT default.
        Self.log("listening on 0.0.0.0:\(port) for the guest subnet of \(guestGateway)")
    }

    /// Serve the guest without a listening socket: the host's own switch
    /// hands over each guest connection to `guestGateway:port`
    /// (`serveDiverted`), so nothing listens on the host's network. The
    /// Linux server's bake (its switch is in-process, and a multi-user
    /// server shouldn't open a port for it).
    public func startDiverted(guestGateway: String, port: UInt16) throws {
        guard let gw = Self.ipv4(guestGateway) else { throw Error.gateway(guestGateway) }
        gateway = gw
        signal(SIGPIPE, SIG_IGN)
        self.port = port
        mirrorURL = URL(string: "http://\(Self.guestReachableHost):\(port)")
        Self.log("serving the guest subnet of \(guestGateway) on \(guestGateway):\(port) (diverted by the switch, no listener)")
    }

    /// A guest connection the switch diverted (`startDiverted`), from `peer`
    /// (IPv4, host order): served as an accepted one is. Takes `fd`.
    public func serveDiverted(_ fd: Int32, peer: UInt32) {
        admit(fd, peer: peer)
    }

    /// Tear the listener down. Safe to call from any thread; the cancel
    /// handler closes the listening fd. Also dumps a sorted list of
    /// every upstream host this proxy contacted so we can audit what
    /// the bake actually talks to and tighten / extend the allowlist.
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        mirrorURL = nil

        contactedLock.lock()
        let snapshot = contactedHosts
        let accepted = acceptedCount
        contactedLock.unlock()
        guard !snapshot.isEmpty else {
            // Nothing reached us at all: the Mac refused the guest's
            // connections (Local Network privacy, a VPN/security agent).
            if accepted == 0 { Self.log("no guest connection reached the proxy during this bake") }
            return
        }
        let lines = snapshot
            .sorted { $0.key < $1.key }
            .map { "  \($0.key)  (\($0.value) request\($0.value == 1 ? "" : "s"))" }
            .joined(separator: "\n")
        Self.log("upstream hosts contacted during this bake:\n\(lines)")
    }

    // MARK: - Accept + serve

    private func acceptOne() {
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let cfd = withUnsafeMutablePointer(to: &peer) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ProxySocket.accept(listenFD, $0, &plen) }
        }
        guard cfd >= 0 else { return }
        let peerIP = peer.sin_family == sa_family_t(AF_INET) ? UInt32(bigEndian: peer.sin_addr.s_addr) : 0
        admit(cfd, peer: peerIP)
    }

    /// A connection from `peerIP`: served if it's the guest's, else closed.
    private func admit(_ cfd: Int32, peer peerIP: UInt32) {
        guard Self.admitsPeer(peerIP, gateway: gateway) else {
            Self.log("refused a connection from \(Self.ipString(peerIP)) (not the guest's subnet)")
            ProxySocket.close(cfd)
            return
        }
        contactedLock.lock()
        acceptedCount += 1
        contactedLock.unlock()
        // Per-socket SIGPIPE suppression — a closed-client write
        // returns EPIPE without signalling the process.
        ProxySocket.noSigPipe(cfd)
        workQueue.async { [weak self] in self?.serve(cfd) }
    }

    private func serve(_ clientFD: Int32) {
        // Read-side timeout in case the client opens a TCP connection
        // and never sends anything — keeps our concurrent worker queue
        // from filling up with idle handlers.
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO,
                   &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let req = readRequest(clientFD) else {
            writeStatus(clientFD, status: 400, reason: "Bad Request")
            ProxySocket.close(clientFD)
            return
        }

        // CONNECT host:port — open a raw TCP tunnel to upstream and
        // splice bytes both ways. Used when the guest has
        // HTTPS_PROXY=http://us pointed at us. The client then does
        // TLS end-to-end through our tunnel; we never see the
        // plaintext. Only the guest's subnet gets this far (acceptOne).
        if req.method == "CONNECT" {
            // The 30s SO_RCVTIMEO set above is right for header reads but
            // fatal inside a long-lived tunnel: an HTTPS download is
            // receive-only after the request, so the client→upstream
            // pump sits idle, "times out" at 30s, and half-closes the
            // upstream — which kills any transfer that takes longer than
            // 30s (e.g. the 73 MB WARP deb over a VPN). Tunnels block
            // indefinitely; the ends' EOF/RST is what finishes them.
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO,
                       &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            handleConnect(clientFD, target: req.path)
            return
        }

        defer { ProxySocket.close(clientFD) }

        guard req.method == "GET" || req.method == "HEAD" else {
            writeStatus(clientFD, status: 405, reason: "Method Not Allowed")
            return
        }

        // Two GET/HEAD shapes:
        //   - "/path"        — reverse-proxy mode, used by the kernel
        //                       cmdline alpine_repo/modloop URLs.
        //                       Hardcoded upstream is dl-cdn.
        //   - "http://..."   — forward-proxy mode, used when guest has
        //                       HTTP_PROXY set. We promote the scheme
        //                       to HTTPS upstream via URLSession so
        //                       the guest stays on plain HTTP.
        let upstreamURL: URL
        let pathForLog: String
        if req.path.hasPrefix("http://") || req.path.hasPrefix("https://") {
            guard let abs = URL(string: req.path),
                  let host = abs.host else {
                writeStatus(clientFD, status: 400, reason: "Bad Path")
                return
            }
            recordHost(host)
            // Always speak HTTPS upstream regardless of what the
            // client URL said — that's the whole point of this proxy.
            var comps = URLComponents(url: abs, resolvingAgainstBaseURL: false)!
            comps.scheme = "https"
            guard let promoted = comps.url else {
                writeStatus(clientFD, status: 400, reason: "Bad Path")
                return
            }
            upstreamURL = promoted
            pathForLog = "\(req.method) \(promoted)"
        } else if req.path.hasPrefix("/") {
            recordHost(Self.defaultReverseUpstream)
            guard let url = URL(string: "https://\(Self.defaultReverseUpstream)\(req.path)") else {
                writeStatus(clientFD, status: 400, reason: "Bad Path")
                return
            }
            upstreamURL = url
            pathForLog = "\(req.method) \(req.path)"
        } else {
            writeStatus(clientFD, status: 400, reason: "Bad Path")
            return
        }

        var upstream = URLRequest(url: upstreamURL)
        upstream.httpMethod = req.method
        // Forward most headers verbatim. Strip:
        //   - Host:   URLSession sets it from the URL.
        //   - Connection: we always force close on our reply.
        //   - Accept-Encoding: let URLSession decide; otherwise we'd
        //     forward "Accept-Encoding: gzip", get gzip back, URLSession
        //     would decompress, but the response headers we emit would
        //     still say "Content-Encoding: gzip" → guest tries to
        //     decompress already-decompressed bytes.
        let skip: Set<String> = ["host", "connection", "accept-encoding"]
        for (k, v) in req.headers where !skip.contains(k.lowercased()) {
            upstream.setValue(v, forHTTPHeaderField: k)
        }

        Self.log(pathForLog)
        streamRequest(clientFD: clientFD, request: upstream, isHead: req.method == "HEAD")
    }

    /// Drive the upstream request through a `URLSessionDataDelegate`
    /// so each chunk lands on the wire as it arrives instead of
    /// buffering the entire body in memory. Previous implementation
    /// used `URLSession.dataTask(_:completionHandler:)` which holds
    /// the whole response — a parallel apt + npm install would
    /// allocate hundreds of MB of `Data`, plenty enough to trip
    /// macOS jetsam and silently kill the host process.
    private func streamRequest(
        clientFD: Int32, request: URLRequest, isHead: Bool
    ) {
        let delegate = StreamingProxyDelegate(clientFD: clientFD, isHead: isHead)
        // The task runs under `delegate` (ProxySession: a session per
        // request where that's safe, else one shared session).
        let finish = ProxySession.start(request, delegate: delegate)
        _ = delegate.semaphore.wait(timeout: .now() + 600)
        finish()

        if delegate.completionError != nil && !delegate.headersSent {
            // Upstream errored before we wrote a response line —
            // safe to emit a 502. Once headers are out we can't
            // change status; just close.
            writeStatus(clientFD, status: 502, reason: "Bad Gateway")
        }
    }

    // MARK: - CONNECT tunnel

    /// Accept a CONNECT request, open a raw TCP socket to the upstream
    /// host:port, tell the client the tunnel
    /// is up, and splice bytes both ways until either side hits EOF.
    /// Note: we do NOT terminate TLS — the client and upstream do TLS
    /// end-to-end through the tunnel. This means CONNECT mode does
    /// not work around guest-side TLS bugs; it's useful when the
    /// guest's TLS is fine but the connection itself needs to come
    /// from the host's network stack (e.g. different MTU / routing).
    private func handleConnect(_ clientFD: Int32, target: String) {
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            writeStatus(clientFD, status: 400, reason: "Bad CONNECT target")
            ProxySocket.close(clientFD)
            return
        }
        let host = parts[0]
        recordHost(host)
        Self.log("CONNECT \(host):\(port)")

        // Resolve + connect on a background queue (DNS can take a
        // moment). Once connected, write 200 to the client and start
        // the splice.
        workQueue.async { [weak self] in
            guard let self else { ProxySocket.close(clientFD); return }
            guard let upstreamFD = Self.openTCP(host: host, port: port) else {
                self.writeStatus(clientFD, status: 502, reason: "Bad Gateway")
                ProxySocket.close(clientFD)
                return
            }
            let okay = "HTTP/1.1 200 Connection established\r\n\r\n"
            _ = okay.withCString { ProxySocket.write(clientFD, $0, strlen($0)) }
            Self.splice(clientFD, upstreamFD)
        }
    }

    /// Open a TCP socket to `host:port`. Returns the (blocking) fd on
    /// success; nil after logging on failure.
    ///
    /// Happy-Eyeballs-lite: start a NON-BLOCKING connect to every address
    /// `getaddrinfo` returns (v6 and v4 together) and take the first that
    /// completes. The previous sequential BLOCKING connect() honoured
    /// getaddrinfo's RFC 6724 ordering, which puts AAAA first whenever
    /// the host has a global IPv6 address — and on a network whose IPv6
    /// is black-holed (address + default route, no upstream) each dead
    /// v6 attempt sits in the kernel's ~75 s SYN timeout before the v4
    /// fallback is even tried. That is exactly what broke both image
    /// bakes: apt reaches its HTTPS repos (deb.nodesource.com,
    /// dl.google.com — both dual-stack CDNs) via CONNECT through us,
    /// its proxy-read timeout is 120 s, and two AAAA records already
    /// cost 150 s → "Reading from proxy failed", the repo is silently
    /// dropped and the wrong (or no) package gets installed. The GET
    /// path never suffered because URLSession races the families
    /// itself. Same remedy as Mitm/HTTPProxy.connectTCP.
    private static let connectDeadline: TimeInterval = 15

    private static func openTCP(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = ProxySocket.streamType
        hints.ai_protocol = ProxySocket.tcpProtocol
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let info = res else {
            log("getaddrinfo(\(host)) failed: \(String(cString: gai_strerror(rc)))")
            return nil
        }
        defer { freeaddrinfo(info) }

        /// Winner bookkeeping: put the fd back in blocking mode (the
        /// splice pump does plain read/write) and drop every other
        /// in-flight attempt.
        func finish(_ winner: Int32, flags: Int32, losers: [Int32]) -> Int32 {
            _ = fcntl(winner, F_SETFL, flags)
            losers.forEach { ProxySocket.close($0) }
            return winner
        }

        var pending: [Int32] = []
        var savedFlags: [Int32: Int32] = [:]
        var ai: UnsafeMutablePointer<addrinfo>? = info
        while let cur = ai {
            ai = cur.pointee.ai_next
            let fd = socket(cur.pointee.ai_family,
                            cur.pointee.ai_socktype,
                            cur.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            ProxySocket.noSigPipe(fd)
            let flags = fcntl(fd, F_GETFL, 0)
            savedFlags[fd] = flags
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if ProxySocket.connect(fd, cur.pointee.ai_addr,
                                   cur.pointee.ai_addrlen) == 0 {
                // Immediate success (loopback / already-open path).
                return finish(fd, flags: flags, losers: pending)
            }
            if errno == EINPROGRESS {
                pending.append(fd)
            } else {
                ProxySocket.close(fd)
            }
        }
        guard !pending.isEmpty else {
            log("could not connect to \(host):\(port) (no address accepted a connect)")
            return nil
        }

        let start = Date()
        while Date().timeIntervalSince(start) < connectDeadline, !pending.isEmpty {
            var pfds = pending.map {
                pollfd(fd: $0, events: Int16(POLLOUT), revents: 0)
            }
            let pr = poll(&pfds, nfds_t(pfds.count), 1000)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            for p in pfds where p.revents != 0 {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                pending.removeAll { $0 == p.fd }
                if soErr == 0 && (p.revents & Int16(POLLOUT)) != 0 {
                    return finish(p.fd, flags: savedFlags[p.fd] ?? 0, losers: pending)
                }
                ProxySocket.close(p.fd)
            }
        }
        pending.forEach { ProxySocket.close($0) }
        log("could not connect to \(host):\(port) within \(Int(connectDeadline))s "
            + "(all \(savedFlags.count) resolved address(es) failed or timed out)")
        return nil
    }

    /// Bidirectional byte pump until both sides hit EOF, then close
    /// both fds. Same pattern as LoopbackCallbackForwarder.splice.
    private static func splice(_ a: Int32, _ b: Int32) {
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .utility)
        func pump(from: Int32, to: Int32) {
            group.enter()
            q.async {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = ProxySocket.read(from, &buf, buf.count)
                    if n <= 0 { break }
                    var off = 0
                    let ok = buf.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        while off < n {
                            let w = ProxySocket.write(to, base + off, n - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !ok { break }
                }
                ProxySocket.shutdownWrite(to)
                group.leave()
            }
        }
        pump(from: a, to: b)
        pump(from: b, to: a)
        group.notify(queue: q) {
            ProxySocket.close(a)
            ProxySocket.close(b)
        }
    }

    // MARK: - Parser

    private struct Request {
        let method: String
        let path: String
        let version: String
        let headers: [(String, String)]
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while buf.count < Self.maxHeaderSize {
            let n = ProxySocket.read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(tmp, count: n)
            if let term = buf.range(of: Data("\r\n\r\n".utf8))?.lowerBound {
                return parseHeaders(buf[..<term])
            }
        }
        return nil
    }

    private func parseHeaders(_ data: Data) -> Request? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2,
                                 omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((k, v))
        }
        return Request(method: parts[0], path: parts[1],
                       version: parts[2], headers: headers)
    }

    // MARK: - Writer

    private func writeStatus(_ fd: Int32, status: Int, reason: String) {
        let s = "HTTP/1.1 \(status) \(reason)\r\n" +
                "Content-Length: 0\r\n" +
                "Connection: close\r\n\r\n"
        _ = s.withCString { ProxySocket.write(fd, $0, strlen($0)) }
    }

    /// Streaming response writer driven by URLSession's delegate
    /// callbacks. Headers go out in `urlSession(_:dataTask:didReceive:)`,
    /// each body chunk in `urlSession(_:dataTask:didReceive:)` for
    /// Data, completion in `urlSession(_:task:didCompleteWithError:)`.
    /// Memory footprint is bounded by URLSession's internal pacing —
    /// no per-request 100 MB Data hanging around.
    final class StreamingProxyDelegate: NSObject,
            URLSessionDataDelegate, @unchecked Sendable {
        let clientFD: Int32
        let isHead: Bool
        let semaphore = DispatchSemaphore(value: 0)
        var headersSent = false
        var completionError: Swift.Error?

        init(clientFD: Int32, isHead: Bool) {
            self.clientFD = clientFD
            self.isHead = isHead
            super.init()
        }

        func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         didReceive response: URLResponse,
                         completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            var head = "HTTP/1.1 \(http.statusCode) " +
                "\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
            // Drop hop-by-hop + content-coding headers. URLSession
            // transparently decompresses content-encoded responses, so
            // forwarding the original encoding hints would tell the
            // guest to decompress already-decompressed bytes. Also
            // drop Content-Length: we'll either pass through a known
            // length from URLResponse.expectedContentLength or stream
            // until we close the connection.
            let drop: Set<String> = [
                "connection", "transfer-encoding",
                "content-encoding", "content-length",
            ]
            for (k, v) in http.allHeaderFields {
                guard let key = k as? String, let value = v as? String else { continue }
                if drop.contains(key.lowercased()) { continue }
                head += "\(key): \(value)\r\n"
            }
            let expected = response.expectedContentLength
            if isHead {
                head += "Content-Length: 0\r\n"
            } else if expected >= 0 {
                head += "Content-Length: \(expected)\r\n"
            }
            // Connection: close — also our cue to the guest that
            // the body length is whatever it reads until EOF, in
            // case we didn't set Content-Length.
            head += "Connection: close\r\n\r\n"
            _ = head.withCString { ProxySocket.write(clientFD, $0, strlen($0)) }
            headersSent = true
            // HEAD: status + headers out, no body — cancel the task.
            completionHandler(isHead ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         didReceive data: Data) {
            // Write each chunk directly to the client socket. SIGPIPE
            // is masked process-wide and per-socket; writes to a
            // closed client just return EPIPE here and the underlying
            // URLSession task will fail next round and complete.
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < data.count {
                    let w = ProxySocket.write(clientFD, base + off, data.count - off)
                    if w <= 0 { return }
                    off += w
                }
            }
        }

        func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didCompleteWithError error: Swift.Error?) {
            completionError = error
            semaphore.signal()
        }
    }

    // MARK: - Scope

    /// A peer the proxy serves: an address on the guest's /24 other than the
    /// gateway itself (that's the Mac — a local process connecting to the
    /// gateway address shows up as it).
    static func admitsPeer(_ peer: UInt32, gateway: UInt32) -> Bool {
        gateway != 0 && peer != gateway && (peer & guestMask) == (gateway & guestMask)
    }

    static func ipv4(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func ipString(_ a: UInt32) -> String {
        "\(a >> 24).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }

    /// Where the proxy's lines go instead of stderr (nil: stderr). Set
    /// before `start`: the Linux bake keeps them in a file beside its
    /// console log, not in the installing terminal.
    nonisolated(unsafe) public static var logSink: ((String) -> Void)?

    private static func log(_ msg: String) {
        if let sink = logSink { sink("[ac-proxy] \(msg)"); return }
        FileHandle.standardError.write(Data("[ac-proxy] \(msg)\n".utf8))
    }

    public enum Error: Swift.Error {
        case gateway(String)
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }
}

/// Runs one proxied request under its own delegate.
///
/// macOS: a URLSession per request, so the delegate's lifetime matches the
/// task and nothing is multiplexed by task identifier (costs ~one URLSession
/// allocation per HTTP hop; cheap).
///
/// Linux: one session for every request, its callbacks routed to each
/// task's delegate. swift-corelibs-foundation aborts the process when a
/// session is freed while libcurl still watches one of its sockets
/// ("_MultiHandle deallocated with non-zero retain count", see
/// URLSessionRetirement), and retiring a session per request would keep
/// hundreds alive per bake.
enum ProxySession {
    static func configuration(maxPerHost: Int) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = maxPerHost
        return cfg
    }

    #if canImport(Darwin)
    /// Starts `request`; the returned closure ends it (after the delegate
    /// signalled, or on the caller's timeout).
    static func start(_ request: URLRequest,
                      delegate: AlpinePackageProxy.StreamingProxyDelegate) -> () -> Void {
        let sess = URLSession(configuration: configuration(maxPerHost: 4),
                              delegate: delegate, delegateQueue: nil)
        sess.dataTask(with: request).resume()
        return { sess.finishTasksAndInvalidate() }
    }
    #else
    // @port-skip linux-only: the Linux side of ProxySession (one session, its tasks routed)
    static func start(_ request: URLRequest,
                      delegate: AlpinePackageProxy.StreamingProxyDelegate) -> () -> Void {
        let task = shared.dataTask(with: request)
        router.add(task.taskIdentifier, delegate)
        task.resume()
        return {
            // A task still going past the caller's timeout is cancelled:
            // its client connection is about to close.
            if task.state == .running || task.state == .suspended { task.cancel() }
            router.remove(task.taskIdentifier)
        }
    }

    /// Each task's delegate, by task identifier.
    // @port-skip linux-only: the Linux side of ProxySession
    final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var delegates: [Int: AlpinePackageProxy.StreamingProxyDelegate] = [:]

        // @port-skip linux-only: the Linux side of ProxySession
        func add(_ id: Int, _ d: AlpinePackageProxy.StreamingProxyDelegate) { lock.withLock { delegates[id] = d } }
        // @port-skip linux-only: the Linux side of ProxySession
        func remove(_ id: Int) { lock.withLock { _ = delegates.removeValue(forKey: id) } }
        // @port-skip linux-only: the Linux side of ProxySession
        private func delegate(_ task: URLSessionTask) -> AlpinePackageProxy.StreamingProxyDelegate? {
            lock.withLock { delegates[task.taskIdentifier] }
        }

        // @port-skip linux-only: the Linux side of ProxySession
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let d = delegate(dataTask) else { completionHandler(.cancel); return }
            d.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }

        // @port-skip linux-only: the Linux side of ProxySession
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            delegate(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
        }

        // @port-skip linux-only: the Linux side of ProxySession
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            delegate(task)?.urlSession(session, task: task, didCompleteWithError: error)
        }
    }

    // @port-skip linux-only: the Linux side of ProxySession
    static let router = Router()
    // @port-skip linux-only: the Linux side of ProxySession (never freed: see above)
    static let shared = URLSession(configuration: configuration(maxPerHost: 16).withoutCookies(),
                                   delegate: router, delegateQueue: nil)
    #endif
}

/// The socket calls the proxy makes, by platform: Darwin's on macOS,
/// Glibc's on Linux (no SO_NOSIGPIPE or sin_len there; writes go through
/// send(MSG_NOSIGNAL), so a guest gone mid-download can't SIGPIPE the host).
enum ProxySocket {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    static let tcpProtocol = IPPROTO_TCP
    static func tcp(_ family: Int32) -> Int32 { Darwin.socket(family, SOCK_STREAM, 0) }
    static func noSigPipe(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func anyAddress(port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        return a
    }
    static func bind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Darwin.bind(fd, a, l) }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func accept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>?, _ l: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Darwin.accept(fd, a, l)
    }
    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { Darwin.connect(fd, a, l) }
    @discardableResult static func close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { Darwin.read(fd, buf, n) }
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int { Darwin.write(fd, buf, n) }
    static func shutdownWrite(_ fd: Int32) { _ = Darwin.shutdown(fd, SHUT_WR) }
    #else
    // @port-skip linux-only: the Glibc side of ProxySocket
    static let streamType = Int32(SOCK_STREAM.rawValue)
    // @port-skip linux-only: the Glibc side of ProxySocket
    static let tcpProtocol = Int32(IPPROTO_TCP)
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func tcp(_ family: Int32) -> Int32 { Glibc.socket(family, Int32(SOCK_STREAM.rawValue), 0) }
    // @port-skip linux-only: the Glibc side of ProxySocket (SIGPIPE is ignored process-wide, and writes use MSG_NOSIGNAL)
    static func noSigPipe(_ fd: Int32) {}
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func anyAddress(port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0)
        return a
    }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func bind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Glibc.bind(fd, a, l) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func accept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>?, _ l: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Glibc.accept(fd, a, l)
    }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { Glibc.connect(fd, a, l) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    @discardableResult static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { Glibc.read(fd, buf, n) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int { Glibc.send(fd, buf, n, Int32(MSG_NOSIGNAL)) }
    // @port-skip linux-only: the Glibc side of ProxySocket
    static func shutdownWrite(_ fd: Int32) { _ = Glibc.shutdown(fd, Int32(SHUT_WR)) }
    #endif
}
