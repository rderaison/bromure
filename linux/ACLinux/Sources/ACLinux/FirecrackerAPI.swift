import Foundation

/// Firecracker's API: HTTP/1.1 with JSON bodies on the Unix socket given by
/// `--api-sock`. One short-lived connection per request (Firecracker serves
/// them one at a time anyway); blocking I/O, off the cooperative pool.
// @port-skip linux-only: Firecracker's control API (macOS: VZVirtualMachine methods)
public struct FirecrackerAPI: Sendable {
    public let socketPath: String

    // @port-skip linux-only: Firecracker API
    public struct Response: Sendable {
        public let status: Int
        public let body: JSONValue?
        // @port-skip linux-only: Firecracker API
        public var ok: Bool { (200..<300).contains(status) }
        /// Firecracker's `fault_message`, or the status.
        // @port-skip linux-only: Firecracker API
        public var fault: String { body?["fault_message"]?.stringValue ?? "HTTP \(status)" }
    }

    // @port-skip linux-only: Firecracker API
    public init(socketPath: String) { self.socketPath = socketPath }

    // @port-skip linux-only: Firecracker API
    public func request(_ method: String, _ path: String, _ body: JSONValue? = nil,
                        timeout: Duration = .seconds(5)) async throws -> Response {
        let sock = socketPath
        let ms = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async {
                c.resume(with: Result { try Self.exchange(sock, method, path, body, timeoutMs: max(ms, 1)) })
            }
        }
    }

    /// `PUT /actions {"action_type": action}`.
    // @port-skip linux-only: Firecracker API
    public func action(_ action: String) async throws {
        let r = try await request("PUT", "/actions", ["action_type": .string(action)])
        guard r.ok else { throw MachineError.toolFailed("firecracker \(action)", Int32(r.status), r.fault) }
    }

    /// `GET /`: the instance's state ("Not started", "Running", "Paused").
    // @port-skip linux-only: Firecracker API
    public func instanceState() async throws -> String {
        let r = try await request("GET", "/")
        guard r.ok, let s = r.body?["state"]?.stringValue else {
            throw MachineError.toolFailed("firecracker GET /", Int32(r.status), r.fault)
        }
        return s
    }

    // @port-skip linux-only: Firecracker API
    static func exchange(_ path: String, _ method: String, _ target: String, _ body: JSONValue?,
                         timeoutMs: Int32) throws -> Response {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw MachineError.io("socket", errno) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int(timeoutMs % 1000) * 1000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw MachineError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            p.copyBytes(from: bytes)
            p[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw MachineError.io("connect \(path)", errno) }
        let payload = try body.map { try JSONEncoder().encode($0) } ?? Data()
        var head = "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(payload.count)\r\n\r\n"
        let out = Data(head.utf8) + payload
        try out.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = send(fd, p.baseAddress! + off, p.count - off, Int32(MSG_NOSIGNAL))
                if n < 0 { if errno == EINTR { continue }; throw MachineError.io("send \(path)", errno) }
                off += n
            }
        }
        // Headers, then Content-Length bytes of body (Firecracker keeps the
        // connection open, so EOF can't delimit it).
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        func readMore() throws -> Bool {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR { return true }
                throw MachineError.io(errno == EAGAIN ? "\(path): no answer in \(timeoutMs) ms" : "recv \(path)", errno)
            }
            if n == 0 { return false }
            buf.append(contentsOf: chunk[0..<n])
            return true
        }
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while (headerEnd = buf.range(of: sep), headerEnd).1 == nil {
            guard try readMore() else { throw MachineError.io("\(path): connection closed before a response", ECONNRESET) }
        }
        let header = String(decoding: buf[..<headerEnd!.lowerBound], as: UTF8.self)
        let lines = header.split(separator: "\r\n")
        guard let first = lines.first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw MachineError.io("\(path): bad response '\(header.prefix(80))'", EPROTO)
        }
        let length = lines.dropFirst().compactMap { l -> Int? in
            let kv = l.split(separator: ":", maxSplits: 1)
            return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        let bodyStart = headerEnd!.upperBound
        while buf.count - bodyStart < length {
            guard try readMore() else { break }
        }
        let raw = buf[bodyStart..<min(buf.count, bodyStart + length)]
        let json = raw.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: raw)
        return Response(status: status, body: json)
    }
}
