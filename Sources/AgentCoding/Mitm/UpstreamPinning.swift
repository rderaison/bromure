import Foundation
import SandboxEngine

/// OpenShell's "resolve once, validate every answer, dial only what passed"
/// for the host-side legs of the MITM. Under an OpenShell policy the proxy
/// resolves the destination itself, checks each address against the route's
/// address authorization (`OpenShellPolicy.destinationPlan` /
/// `validateDestination`), and connects only to those addresses — so a
/// private or rebinding DNS answer can't redirect a request the policy
/// allowed by name.
enum UpstreamPinning {
    typealias IPAddress = OpenShellPolicy.IPAddress

    /// Addresses the upstream leg may use: `.success(nil)` = not pinned (no
    /// OpenShell policy, or a Bromure-managed provider endpoint).
    static func pin(policy: OpenShellPolicy?, host: String, port: Int,
                    identity: OpenShellPolicy.BinaryIdentity?, enforceBinaries: Bool)
        -> Result<[IPAddress]?, OpenShellPolicy.DestinationDenial> {
        guard let policy else { return .success(nil) }
        let p = UInt16(truncatingIfNeeded: port)
        if policy.networkPolicies.contains(where: { $0.endpoints.contains { $0.managed && $0.matches(host: host.lowercased(), port: p) } }) {
            return .success(nil)
        }
        let lookup = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let resolved = IPAddress(lookup).map { [$0] } ?? resolve(lookup, port: port)
        return policy.destinationPlan(host: host, port: p, identity: identity, enforceBinaries: enforceBinaries)
            .flatMap { OpenShellPolicy.validateDestination($0, host: host, port: p, resolved: resolved) }
            .map { Optional($0) }
    }

    /// Host-side DNS (the system resolver), every A/AAAA answer.
    static func resolve(_ host: String, port: Int) -> [IPAddress] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [IPAddress] = []
        var cursor = res
        while let info = cursor {
            cursor = info.pointee.ai_next
            if info.pointee.ai_family == AF_INET {
                let a = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                out.append(.v4(UInt32(bigEndian: a.sin_addr.s_addr)))
            } else if info.pointee.ai_family == AF_INET6 {
                let a = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                out.append(.v6(withUnsafeBytes(of: a.sin6_addr) { Array($0) }))
            }
        }
        var seen = Set<IPAddress>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Connect to the first reachable address (non-blocking race, 10 s).
    /// Returns a blocking fd; the caller owns it.
    static func connect(_ addresses: [IPAddress], port: Int) throws -> Int32 {
        var fds: [Int32: Int32] = [:]          // fd → saved flags
        for ip in addresses {
            let fd: Int32
            var rc: Int32
            switch ip {
            case .v4(let v):
                fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                var sa = sockaddr_in()
                sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sa.sin_family = sa_family_t(AF_INET)
                sa.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
                sa.sin_addr.s_addr = v.bigEndian
                let flags = fcntl(fd, F_GETFL, 0); fds[fd] = flags
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                rc = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            case .v6(let b):
                fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                var sa = sockaddr_in6()
                sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sa.sin6_family = sa_family_t(AF_INET6)
                sa.sin6_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
                withUnsafeMutableBytes(of: &sa.sin6_addr) { $0.copyBytes(from: b) }
                let flags = fcntl(fd, F_GETFL, 0); fds[fd] = flags
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                rc = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if rc == 0 {
                _ = fcntl(fd, F_SETFL, fds[fd] ?? 0)
                fds.keys.filter { $0 != fd }.forEach { close($0) }
                return prepared(fd)
            }
            if errno != EINPROGRESS { close(fd); fds[fd] = nil }
        }
        let start = Date()
        while !fds.isEmpty, Date().timeIntervalSince(start) < 10 {
            var pfds = fds.keys.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            let pr = poll(&pfds, UInt32(pfds.count), 1000)
            if pr < 0 { if errno == EINTR { continue }; break }
            for p in pfds where p.revents & Int16(POLLOUT | POLLERR | POLLHUP | POLLNVAL) != 0 {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr == 0 {
                    _ = fcntl(p.fd, F_SETFL, fds[p.fd] ?? 0)
                    fds.keys.filter { $0 != p.fd }.forEach { close($0) }
                    return prepared(p.fd)
                }
                close(p.fd); fds[p.fd] = nil
            }
        }
        fds.keys.forEach { close($0) }
        throw MitmError.upstreamFailed("connect to validated address(es) \(addresses.map(\.description).joined(separator: ", ")) port \(port) failed")
    }

    private static func prepared(_ fd: Int32) -> Int32 {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

/// A loopback proxy that serves exactly one destination: the `URLSession`
/// behind one MITM'd request points at it (`connectionProxyDictionary`), so
/// the session keeps doing TLS end to end (SNI and certificate checks on the
/// real hostname) while the TCP leg goes to an address that already passed
/// OpenShell's destination checks. It answers `CONNECT host:port` (HTTPS) and
/// absolute-form requests (plain HTTP, rewritten to origin-form — what the
/// client sent, and what many servers insist on) for that host:port only;
/// anything else gets a 403.
final class PinnedUpstreamDialer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let host: String
    private let upstreamPort: Int
    private let addresses: [OpenShellPolicy.IPAddress]
    private let lock = NSLock()
    private var closed = false

    init(host: String, port upstreamPort: Int, addresses: [OpenShellPolicy.IPAddress]) throws {
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.upstreamPort = upstreamPort
        self.addresses = addresses
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw MitmError.upstreamFailed("pinned dialer: socket") }
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        sa.sin_port = 0
        let bound = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw MitmError.upstreamFailed("pinned dialer: bind/listen") }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: got.sin_port))
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { shutdownListener() }

    /// For `URLSessionConfiguration.connectionProxyDictionary`.
    var proxyDictionary: [AnyHashable: Any] {
        [kCFNetworkProxiesHTTPEnable as String: 1,
         kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
         kCFNetworkProxiesHTTPPort as String: port,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
    }

    func shutdownListener() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return                                   // listener closed
            }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var head = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(client, &buf, buf.count)
            guard n > 0, head.count + n <= 65_536 else { close(client); return }
            head.append(contentsOf: buf[0..<n])
        }
        let firstLine = String(decoding: head.prefix(while: { $0 != 0x0D }), as: UTF8.self)
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3 else { refuse(client); return }
        let isConnect = parts[0] == "CONNECT"
        var authority = String(parts[1])
        if !isConnect {
            // Absolute-form: http://host[:port]/…
            guard authority.lowercased().hasPrefix("http://") else { refuse(client); return }
            authority = String(authority.dropFirst(7).prefix(while: { $0 != "/" && $0 != "?" }))
        }
        guard let a = OpenShellHTTP.Authority.parse(authority),
              a.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              Int(a.port ?? (isConnect ? 443 : 80)) == upstreamPort else {
            refuse(client); return
        }
        guard let upstream = try? UpstreamPinning.connect(addresses, port: upstreamPort) else {
            _ = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".withCString { write(client, $0, strlen($0)) }
            close(client); return
        }
        if isConnect {
            let ok = "HTTP/1.1 200 Connection established\r\n\r\n"
            _ = ok.withCString { write(client, $0, strlen($0)) }
            // Bytes the client sent after the CONNECT head (none expected).
            if let e = head.range(of: Data("\r\n\r\n".utf8)), e.upperBound < head.count {
                writeAll(upstream, head.subdata(in: e.upperBound..<head.count))
            }
        } else {
            writeAll(upstream, Self.originForm(head, target: String(parts[1])))
        }
        let group = DispatchGroup()
        for (from, to) in [(client, upstream), (upstream, client)] {
            group.enter()
            Thread.detachNewThread {
                var b = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = read(from, &b, b.count)
                    if n <= 0 { break }
                    if !Self.writeAllRaw(to, b, n) { break }
                }
                Darwin.shutdown(to, SHUT_WR)
                group.leave()
            }
        }
        group.notify(queue: .global()) { close(client); close(upstream) }
    }

    /// A plain-HTTP request URLSession sent to us as its proxy, as the origin
    /// should see it: `METHOD /path?query HTTP/1.1` (not absolute-form), no
    /// proxy-only headers, and `Connection: close` so the connection carries
    /// exactly this request (later ones would arrive in absolute-form again).
    static func originForm(_ head: Data, target: String) -> Data {
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return head }
        let text = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return head }
        let parts = lines[0].split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return head }
        var path = target
        if let scheme = path.range(of: "://") {
            let rest = path[scheme.upperBound...]
            if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                path = String(rest[slash...])
                if path.hasPrefix("?") { path = "/" + path }
            } else {
                path = "/"
            }
        }
        lines[0] = "\(parts[0]) \(path) \(parts[2])"
        let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
        var out = [lines[0]]
        for line in lines.dropFirst() where !line.isEmpty {
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if !dropped.contains(name) { out.append(line) }
        }
        out.append("Connection: close")
        var data = Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(head[end.upperBound...])      // any body bytes already read
        return data
    }

    private func refuse(_ fd: Int32) {
        let r = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = r.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    private func writeAll(_ fd: Int32, _ d: Data) {
        let bytes = [UInt8](d)
        _ = Self.writeAllRaw(fd, bytes, bytes.count)
    }

    private static func writeAllRaw(_ fd: Int32, _ b: [UInt8], _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let w = b.withUnsafeBytes { write(fd, $0.baseAddress! + off, n - off) }
            if w > 0 { off += w } else if w < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}
