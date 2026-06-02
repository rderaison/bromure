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

    /// Single upstream we'll talk HTTPS to. Anything else gets 403.
    private static let upstreamHost = "dl-cdn.alpinelinux.org"

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
    private let session: URLSession
    private(set) var mirrorURL: URL?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        // modloop-virt can be ~50–100 MB; give it room.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 8
        // We don't want URLSession to add `Accept-Encoding: gzip` and
        // then transparently decode — the guest already handles
        // whatever encoding it asked for. Disable by setting an empty
        // additional Accept-Encoding via header forwarding below.
        self.session = URLSession(configuration: cfg)
    }

    /// Bind and start listening. Throws on bind / listen failure (e.g.
    /// `EADDRINUSE` if another process holds the port; we bind to
    /// kernel-assigned `port 0` so this is unlikely).
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
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
    /// handler closes the listening fd.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        mirrorURL = nil
    }

    // MARK: - Accept + serve

    private func acceptOne() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        workQueue.async { [weak self] in self?.serve(cfd) }
    }

    private func serve(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        // Read-side timeout in case the client opens a TCP connection
        // and never sends anything — keeps our concurrent worker queue
        // from filling up with idle handlers.
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO,
                   &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let req = readRequest(clientFD) else {
            writeStatus(clientFD, status: 400, reason: "Bad Request")
            return
        }
        guard req.method == "GET" || req.method == "HEAD" else {
            writeStatus(clientFD, status: 405, reason: "Method Not Allowed")
            return
        }
        guard req.path.hasPrefix("/"),
              let url = URL(string: "https://\(Self.upstreamHost)\(req.path)") else {
            writeStatus(clientFD, status: 400, reason: "Bad Path")
            return
        }

        var upstream = URLRequest(url: url)
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

        Self.log("\(req.method) \(req.path)")

        let semaphore = DispatchSemaphore(value: 0)
        var bodyOut: Data?
        var httpOut: HTTPURLResponse?
        var errOut: Swift.Error?
        let task = session.dataTask(with: upstream) { d, r, e in
            bodyOut = d
            httpOut = r as? HTTPURLResponse
            errOut = e
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 600)

        if let e = errOut {
            Self.log("upstream error for \(req.path): \(e)")
            writeStatus(clientFD, status: 502, reason: "Bad Gateway")
            return
        }
        guard let http = httpOut else {
            writeStatus(clientFD, status: 502, reason: "Bad Gateway")
            return
        }
        // HEAD: keep the status + headers, drop the body even if
        // upstream returned one (HEAD is supposed to be body-less).
        let body = req.method == "HEAD" ? Data() : (bodyOut ?? Data())
        writeResponse(clientFD, http: http, body: body, isHead: req.method == "HEAD")
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

    private func writeResponse(_ fd: Int32, http: HTTPURLResponse,
                                body: Data, isHead: Bool) {
        var head = "HTTP/1.1 \(http.statusCode) " +
            "\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        var sawContentLength = false
        // Drop hop-by-hop + content-coding headers. URLSession may have
        // already decompressed the body or rewritten chunked → single
        // blob; forwarding the original encoding hints would mislead
        // the guest.
        let drop: Set<String> = [
            "connection", "transfer-encoding",
            "content-encoding", "content-length",
        ]
        for (k, v) in http.allHeaderFields {
            guard let key = k as? String, let value = v as? String else { continue }
            if drop.contains(key.lowercased()) { continue }
            head += "\(key): \(value)\r\n"
            _ = sawContentLength
        }
        // We always know body.count here, so use it as the canonical
        // length (matches what we'll actually write).
        let len = isHead ? 0 : body.count
        head += "Content-Length: \(len)\r\n"
        head += "Connection: close\r\n\r\n"
        _ = head.withCString { Darwin.write(fd, $0, strlen($0)) }
        if isHead { return }
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < body.count {
                let w = Darwin.write(fd, base + off, body.count - off)
                if w <= 0 { break }
                off += w
            }
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
