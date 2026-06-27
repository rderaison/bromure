import Foundation

/// A tiny loopback HTTP proxy that sits in front of the vllm-mlx engine and
/// applies `ToolCallRepair` to `/v1/messages` responses. The vsock bridge
/// (and the MITM local route) point here instead of straight at the engine,
/// so leaked-as-text tool calls become real `tool_use` blocks before the
/// agent ever sees them.
///
/// `/v1/messages` is buffered (we force `stream:false` upstream so we can
/// inspect the whole message, then re-emit it as SSE). Every other path is
/// forwarded transparently. Loopback-only; one accept loop, a thread per
/// connection — same shape as the other small servers here.
final class InferenceRepairProxy: @unchecked Sendable {
    static let shared = InferenceRepairProxy()

    /// Public port the bridge/clients connect to. The engine itself binds
    /// `InferenceService.enginePort`; we forward there.
    static let listenPort = 11500

    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    /// Start the accept loop if not already running. Idempotent.
    func startIfNeeded(enginePort: Int = InferenceService.enginePort) {
        lock.lock(); defer { lock.unlock() }
        if running { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(Self.listenPort).bigEndian)
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 64) != 0 { close(fd); return }
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop(enginePort: enginePort) }
    }

    private func acceptLoop(enginePort: Int) {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { break }
            Thread.detachNewThread { [weak self] in self?.handle(clientFD: c, enginePort: enginePort) }
        }
    }

    // MARK: - Per-connection

    private func handle(clientFD: Int32, enginePort: Int) {
        defer { close(clientFD) }
        while let req = Self.readRequest(fd: clientFD) {
            let resp = Self.respond(to: req, enginePort: enginePort)
            if !Self.writeAll(clientFD, resp) { break }
            // Honour keep-alive; the read loop exits on EOF / next-request error.
            if req.headerValue("connection")?.lowercased() == "close" { break }
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [(String, String)]
        var body: Data
        func headerValue(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    /// Read one HTTP/1.1 request (request line + headers + Content-Length body).
    static func readRequest(fd: Int32) -> Request? {
        var buf = Data()
        // Read until end of headers.
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
        }
        guard let he = headerEnd,
              let head = String(data: buf.subdata(in: 0..<he.lowerBound), encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        var body = buf.subdata(in: he.upperBound..<buf.endIndex)
        let contentLength = headers.first { $0.0.lowercased() == "content-length" }
            .flatMap { Int($0.1) } ?? 0
        while body.count < contentLength {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0..<n])
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    /// Build the full HTTP response bytes for a request.
    static func respond(to req: Request, enginePort: Int) -> Data {
        let base = "http://127.0.0.1:\(enginePort)"
        let isMessages = req.path.split(separator: "?").first.map(String.init) == "/v1/messages"

        // Non-/v1/messages: transparent passthrough.
        guard isMessages, req.method == "POST",
              var payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return passthrough(req, base: base)
        }

        // Force non-streaming upstream so we can inspect + repair the message.
        payload["stream"] = false
        let upstreamBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? req.body
        guard let url = URL(string: base + req.path) else { return passthrough(req, base: base) }
        var ur = URLRequest(url: url)
        ur.httpMethod = "POST"
        ur.httpBody = upstreamBody
        for (k, v) in req.headers where !["host", "content-length", "connection", "accept-encoding"].contains(k.lowercased()) {
            ur.setValue(v, forHTTPHeaderField: k)
        }
        ur.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, status) = syncData(ur)
        guard status == 200, let data,
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Upstream error — relay status + body verbatim.
            return httpResponse(status: status, headers: [("Content-Type", "application/json")],
                                body: data ?? Data())
        }
        let sse = ToolCallRepair.sse(message: ToolCallRepair.repair(message: message))
        return httpResponse(status: 200,
                            headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
                            body: sse)
    }

    private static func passthrough(_ req: Request, base: String) -> Data {
        guard let url = URL(string: base + req.path) else {
            return httpResponse(status: 502, headers: [], body: Data("bad path".utf8))
        }
        var ur = URLRequest(url: url)
        ur.httpMethod = req.method
        if !req.body.isEmpty { ur.httpBody = req.body }
        for (k, v) in req.headers where !["host", "content-length", "connection", "accept-encoding"].contains(k.lowercased()) {
            ur.setValue(v, forHTTPHeaderField: k)
        }
        let (data, status) = syncData(ur)
        return httpResponse(status: status, headers: [("Content-Type", "application/json")], body: data ?? Data())
    }

    /// Synchronous URLSession fetch (we're on a dedicated connection thread).
    private static func syncData(_ req: URLRequest) -> (Data?, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?; var status = 502
        var r = req; r.timeoutInterval = 300
        let task = URLSession.shared.dataTask(with: r) { d, resp, _ in
            out = d; status = (resp as? HTTPURLResponse)?.statusCode ?? 502; sem.signal()
        }
        task.resume()
        sem.wait()
        return (out, status)
    }

    private static func httpResponse(status: Int, headers: [(String, String)], body: Data) -> Data {
        var s = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\n"
        s += "Connection: keep-alive\r\n\r\n"
        var out = Data(s.utf8); out.append(body); return out
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < data.count {
                let w = write(fd, base + off, data.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
    }
}
