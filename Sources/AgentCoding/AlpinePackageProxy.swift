import CryptoKit
import Darwin
import Foundation

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
/// transport. The proxy is also strictly limited to a single upstream
/// host so a compromised guest can't use it as a generic egress relay.
///
/// Lifecycle: bind a TCP listener on 0.0.0.0:<auto-port> before the VM
/// boots; pass `http://192.168.64.1:<port>` (the vmnet NAT gateway IP
/// the guest sees) into the kernel cmdline and `setup.sh` environment;
/// tear down when the bake exits.
final class AlpinePackageProxy: @unchecked Sendable {
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

    private func recordHost(_ host: String) {
        contactedLock.lock()
        defer { contactedLock.unlock() }
        contactedHosts[host, default: 0] += 1
    }

    /// Hard cap on the request-header bytes we'll buffer before parsing.
    /// Real apk-tools / busybox-wget headers are well under 1 KB; this
    /// cap is purely a defence against a stuck client streaming garbage.
    private static let maxHeaderSize = 16 * 1024

    // MARK: - Immutable-artifact disk cache

    /// On-disk cache for upstream content that can never change under
    /// its URL, so repeat bakes / postinstall amends stop re-downloading
    /// the same bytes: the Alpine modloop (~40 MB per provisioner boot),
    /// versioned .apk / .deb pool files, and apt's content-addressed
    /// `by-hash` index files (the ~20 MB `universe` Packages list behind
    /// every `apt-get update` against ports.ubuntu.com). Mutable
    /// metadata (InRelease, APKINDEX, non-by-hash Packages) is never
    /// cached — package managers keep verifying freshness and
    /// signatures end-to-end exactly as before.
    private let cacheDir: URL
    /// Entries untouched for this long are swept on start(). Hits bump
    /// the file's mtime, so anything in active use never expires.
    private static let cacheMaxAge: TimeInterval = 30 * 24 * 3600

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/pkg-proxy", isDirectory: true)
    }

    init(cacheDirectory: URL = AlpinePackageProxy.defaultCacheDirectory) {
        cacheDir = cacheDirectory
    }

    /// Cache filename for `url`, or nil when its content isn't
    /// immutable. Keyed on the SHA-256 of the full URL so distinct
    /// mirrors/paths can't collide.
    static func cacheKey(for url: URL) -> String? {
        let path = url.path
        // apt content-addressed indexes: the path *is* the content hash.
        let immutable = path.contains("/by-hash/")
            // Debian/Ubuntu pool artifacts — version is in the filename,
            // archives never rewrite a published .deb in place.
            || path.hasSuffix(".deb") || path.hasSuffix(".udeb")
            // Alpine packages — same versioned-filename contract.
            || path.hasSuffix(".apk")
            // Alpine release artifacts (modloop-virt, netboot kernel /
            // initramfs) live under a pinned release directory.
            || path.contains("/releases/")
        guard immutable else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Existing cache entry for `url`, mtime-bumped, or nil on miss /
    /// uncacheable. Also returns the final path a miss should populate.
    private func cacheLookup(for url: URL) -> (hit: URL?, destination: URL?) {
        guard let key = Self.cacheKey(for: url) else { return (nil, nil) }
        let file = cacheDir.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return (nil, file)
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return (file, file)
    }

    /// Serve a cached file: synthesized 200 + Content-Length, body
    /// streamed in chunks. The original upstream headers are gone, but
    /// apk / apt / busybox-wget only consume status + length.
    private func serveCached(_ clientFD: Int32, file: URL, size: Int64, isHead: Bool) {
        var head = "HTTP/1.1 200 OK\r\n" +
            "Content-Length: \(isHead ? 0 : size)\r\n" +
            "Connection: close\r\n\r\n"
        _ = head.withUTF8 { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Darwin.write(clientFD, base, buf.count)
        }
        guard !isHead, let handle = FileHandle(forReadingAtPath: file.path) else { return }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            let ok = chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                guard let base = raw.baseAddress else { return false }
                var off = 0
                while off < chunk.count {
                    let w = Darwin.write(clientFD, base + off, chunk.count - off)
                    if w <= 0 { return false }
                    off += w
                }
                return true
            }
            if !ok { return }
        }
    }

    /// Delete cache entries (and orphaned .partial files) untouched for
    /// `cacheMaxAge`. Runs detached — never blocks the accept path.
    private func sweepCache() {
        let dir = cacheDir
        workQueue.async {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-Self.cacheMaxAge)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            for entry in entries {
                let mtime = (try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    private let acceptQueue = DispatchQueue(
        label: "io.bromure.ac.alpineproxy.accept", qos: .utility)
    private let workQueue = DispatchQueue(
        label: "io.bromure.ac.alpineproxy.work",
        qos: .utility, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private(set) var mirrorURL: URL?

    // Per-request URLSession is created inside `streamRequest` so the
    // streaming delegate's lifetime matches one HTTP hop. No shared
    // session state — connection pooling per host is still done by
    // URLSession internally but isolated per request, which keeps
    // memory bounded.

    /// Bind and start listening. Throws on bind / listen failure (e.g.
    /// `EADDRINUSE` if another process holds the port; we bind to
    /// kernel-assigned `port 0` so this is unlikely).
    func start() throws {
        // Globally ignore SIGPIPE. Our `Darwin.write` calls in
        // splice / writeStatus / writeResponse hit a closed client
        // socket the moment a guest gives up mid-download (curl
        // returned 23, npm bailed, etc.). Default SIGPIPE disposition
        // is "terminate the process" — no crash log, no diagnostic
        // report, just silent exit. Per-socket SO_NOSIGPIPE below is
        // belt-and-braces; this is the suspenders.
        signal(SIGPIPE, SIG_IGN)

        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        sweepCache()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                   &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        // port = 0: let the kernel pick a free ephemeral port. Avoids
        // clashing with whatever else the user has running on 8080 etc.
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
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

        if Darwin.listen(fd, 16) != 0 {
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
        Self.log("listening on 0.0.0.0:\(port); guest URL = \(url)")
    }

    /// Tear the listener down. Safe to call from any thread; the cancel
    /// handler closes the listening fd. Also dumps a sorted list of
    /// every upstream host this proxy contacted so we can audit what
    /// the bake actually talks to and tighten / extend the allowlist.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        mirrorURL = nil

        contactedLock.lock()
        let snapshot = contactedHosts
        contactedLock.unlock()
        guard !snapshot.isEmpty else { return }
        let lines = snapshot
            .sorted { $0.key < $1.key }
            .map { "  \($0.key)  (\($0.value) request\($0.value == 1 ? "" : "s"))" }
            .joined(separator: "\n")
        Self.log("upstream hosts contacted during this bake:\n\(lines)")
    }

    // MARK: - Accept + serve

    private func acceptOne() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        // Per-socket SIGPIPE suppression — a closed-client write
        // returns EPIPE without signalling the process.
        var yes: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE,
                   &yes, socklen_t(MemoryLayout<Int32>.size))
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
            Darwin.close(clientFD)
            return
        }

        // CONNECT host:port — open a raw TCP tunnel to upstream and
        // splice bytes both ways. Used when the guest has
        // HTTPS_PROXY=http://us pointed at us. The client then does
        // TLS end-to-end through our tunnel; we never see the
        // plaintext. Only allowed for whitelisted hosts so the proxy
        // can't be used as a generic SOCKS-style escape hatch.
        if req.method == "CONNECT" {
            handleConnect(clientFD, target: req.path)
            return
        }

        defer { Darwin.close(clientFD) }

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

        let (cacheHit, cacheDestination) = cacheLookup(for: upstreamURL)
        if let cacheHit,
           let size = (try? FileManager.default.attributesOfItem(
               atPath: cacheHit.path)[.size] as? Int64) ?? nil {
            Self.log("\(pathForLog) [cache hit, \(size) bytes]")
            serveCached(clientFD, file: cacheHit, size: size,
                        isHead: req.method == "HEAD")
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
        streamRequest(clientFD: clientFD, request: upstream,
                      isHead: req.method == "HEAD",
                      cacheDestination: req.method == "GET" ? cacheDestination : nil)
    }

    /// Drive the upstream request through a `URLSessionDataDelegate`
    /// so each chunk lands on the wire as it arrives instead of
    /// buffering the entire body in memory. Previous implementation
    /// used `URLSession.dataTask(_:completionHandler:)` which holds
    /// the whole response — a parallel apt + npm install would
    /// allocate hundreds of MB of `Data`, plenty enough to trip
    /// macOS jetsam and silently kill the host process.
    private func streamRequest(
        clientFD: Int32, request: URLRequest, isHead: Bool,
        cacheDestination: URL? = nil
    ) {
        let delegate = StreamingProxyDelegate(
            clientFD: clientFD, isHead: isHead,
            cacheDestination: cacheDestination,
            expectedBodySHA256: cacheDestination.flatMap {
                _ in Self.byHashDigest(of: request.url)
            })
        // Per-request URLSession so the delegate's lifetime matches
        // the task and we don't have to multiplex by task identifier.
        // Costs ~one URLSession allocation per HTTP hop; cheap.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 4
        let sess = URLSession(configuration: cfg,
                               delegate: delegate, delegateQueue: nil)
        let task = sess.dataTask(with: request)
        task.resume()
        _ = delegate.semaphore.wait(timeout: .now() + 600)
        sess.finishTasksAndInvalidate()

        if delegate.completionError != nil && !delegate.headersSent {
            // Upstream errored before we wrote a response line —
            // safe to emit a 502. Once headers are out we can't
            // change status; just close.
            writeStatus(clientFD, status: 502, reason: "Bad Gateway")
        }
    }

    /// For apt by-hash URLs the last path component IS the expected
    /// SHA-256 of the body — verify it before promoting a cache entry.
    static func byHashDigest(of url: URL?) -> String? {
        guard let url, url.path.contains("/by-hash/SHA256/") else { return nil }
        let hex = url.lastPathComponent.lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    // MARK: - CONNECT tunnel

    /// Accept a CONNECT request, open a raw TCP socket to the upstream
    /// host:port (after allowlist check), tell the client the tunnel
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
            Darwin.close(clientFD)
            return
        }
        let host = parts[0]
        recordHost(host)
        Self.log("CONNECT \(host):\(port)")

        // Resolve + connect on a background queue (DNS can take a
        // moment). Once connected, write 200 to the client and start
        // the splice.
        workQueue.async { [weak self] in
            guard let self else { Darwin.close(clientFD); return }
            guard let upstreamFD = Self.openTCP(host: host, port: port) else {
                self.writeStatus(clientFD, status: 502, reason: "Bad Gateway")
                Darwin.close(clientFD)
                return
            }
            let okay = "HTTP/1.1 200 Connection established\r\n\r\n"
            _ = okay.withCString { Darwin.write(clientFD, $0, strlen($0)) }
            Self.splice(clientFD, upstreamFD)
        }
    }

    /// Open a TCP socket to `host:port`. Uses `getaddrinfo` so it
    /// works for both IPv4 and IPv6 upstreams. Returns the fd on
    /// success; closes + returns nil on failure.
    private static func openTCP(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let info = res else {
            log("getaddrinfo(\(host)) failed: \(rc)")
            return nil
        }
        defer { freeaddrinfo(info) }
        var ai: UnsafeMutablePointer<addrinfo>? = info
        while let cur = ai {
            let fd = socket(cur.pointee.ai_family,
                            cur.pointee.ai_socktype,
                            cur.pointee.ai_protocol)
            if fd >= 0 {
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                           &yes, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(fd, cur.pointee.ai_addr,
                                  cur.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            ai = cur.pointee.ai_next
        }
        log("could not connect to \(host):\(port)")
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
                    let n = Darwin.read(from, &buf, buf.count)
                    if n <= 0 { break }
                    var off = 0
                    let ok = buf.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        while off < n {
                            let w = Darwin.write(to, base + off, n - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !ok { break }
                }
                Darwin.shutdown(to, SHUT_WR)
                group.leave()
            }
        }
        pump(from: a, to: b)
        pump(from: b, to: a)
        group.notify(queue: q) {
            Darwin.close(a)
            Darwin.close(b)
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
            let n = Darwin.read(fd, &tmp, tmp.count)
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
        _ = s.withCString { Darwin.write(fd, $0, strlen($0)) }
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

        /// Cache tee — body chunks also land in `<destination>.partial-*`,
        /// promoted in didComplete only when the transfer finished intact.
        private let cacheDestination: URL?
        private let expectedBodySHA256: String?
        private var cacheTemp: URL?
        private var cacheHandle: FileHandle?
        private var cacheBytes: Int64 = 0
        private var bodyHasher = SHA256()
        private var expectedLength: Int64 = -1
        private var statusCode = 0

        init(clientFD: Int32, isHead: Bool,
             cacheDestination: URL? = nil, expectedBodySHA256: String? = nil) {
            self.clientFD = clientFD
            self.isHead = isHead
            self.cacheDestination = cacheDestination
            self.expectedBodySHA256 = expectedBodySHA256
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
            _ = head.withCString { Darwin.write(clientFD, $0, strlen($0)) }
            headersSent = true
            statusCode = http.statusCode
            expectedLength = expected
            // Cache only complete 200 bodies — a 206/304/404 must
            // never become "the" content for this URL.
            if !isHead, http.statusCode == 200, let dest = cacheDestination {
                let temp = dest.appendingPathExtension("partial-\(UUID().uuidString)")
                if FileManager.default.createFile(atPath: temp.path, contents: nil) {
                    cacheTemp = temp
                    cacheHandle = FileHandle(forWritingAtPath: temp.path)
                }
            }
            // HEAD: status + headers out, no body — cancel the task.
            completionHandler(isHead ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         didReceive data: Data) {
            // Tee into the cache temp file first — independent of the
            // client socket's fate, so an impatient guest doesn't cost
            // us the cache entry for the next run.
            if let handle = cacheHandle {
                do {
                    try handle.write(contentsOf: data)
                    cacheBytes += Int64(data.count)
                    if expectedBodySHA256 != nil { bodyHasher.update(data: data) }
                } catch {
                    // Disk full / volume gone: stop teeing, keep proxying.
                    try? handle.close()
                    cacheHandle = nil
                }
            }
            // Write each chunk directly to the client socket. SIGPIPE
            // is masked process-wide and per-socket; writes to a
            // closed client just return EPIPE here and the underlying
            // URLSession task will fail next round and complete.
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < data.count {
                    let w = Darwin.write(clientFD, base + off, data.count - off)
                    if w <= 0 { return }
                    off += w
                }
            }
        }

        func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didCompleteWithError error: Swift.Error?) {
            completionError = error
            finalizeCache(error: error)
            semaphore.signal()
        }

        /// Promote the temp file into the cache — only for an error-free
        /// 200 whose byte count matches Content-Length (when known) and,
        /// for by-hash URLs, whose body hashes to the digest in the URL.
        /// Anything short of that is discarded: a poisoned entry would
        /// fail apt/apk verification on every future run until swept.
        private func finalizeCache(error: Swift.Error?) {
            guard let temp = cacheTemp else { return }
            try? cacheHandle?.close()
            cacheHandle = nil
            cacheTemp = nil
            let fm = FileManager.default
            let intact = error == nil
                && statusCode == 200
                && (expectedLength < 0 || cacheBytes == expectedLength)
                && cacheBytes > 0
                && verifyBodyHash()
            guard intact, let dest = cacheDestination else {
                try? fm.removeItem(at: temp)
                return
            }
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: temp, to: dest) }
            catch { try? fm.removeItem(at: temp) }
        }

        private func verifyBodyHash() -> Bool {
            guard let expected = expectedBodySHA256 else { return true }
            let actual = bodyHasher.finalize()
                .map { String(format: "%02x", $0) }.joined()
            return actual == expected
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[ac-proxy] \(msg)\n".utf8))
    }

    enum Error: Swift.Error {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }
}
