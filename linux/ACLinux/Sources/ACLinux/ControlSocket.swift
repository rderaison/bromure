import CACLinuxShims
import Foundation
import NIOCore
import NIOPosix

/// One control-socket request: the same shape as the macOS control.sock
/// (ACAutomationServer): `METHOD path HTTP/1.1`, Content-Length JSON body,
/// one request per connection.
// @port-skip linux-only: request value type (macOS passes fd + parsed parts)
public struct ControlRequest: Sendable {
    public let method: String
    /// Path including any query string (handlers split on `?`, as macOS does).
    public let path: String
    public let body: JSONValue
}

// @port-skip linux-only: response value type
public struct ControlResponse: Sendable {
    public let status: Int
    public let body: JSONValue
    /// Set for a streaming reply: the connection answers `200` with an
    /// octet-stream header and then belongs to this closure (raw bytes both
    /// ways) until it returns; the connection is closed after it.
    public let stream: (@Sendable (ControlStream) async -> Void)?
    // @port-skip linux-only: response value type
    public init(_ status: Int, _ body: JSONValue) { self.status = status; self.body = body; self.stream = nil }
    // @port-skip linux-only: response value type
    public static func streaming(_ body: @escaping @Sendable (ControlStream) async -> Void) -> ControlResponse {
        ControlResponse(stream: body)
    }
    // @port-skip linux-only: response value type
    private init(stream: @escaping @Sendable (ControlStream) async -> Void) {
        status = 200; body = .null; self.stream = stream
    }
    // @port-skip linux-only: response helpers
    public static func error(_ status: Int, _ message: String, _ extra: [String: JSONValue] = [:]) -> ControlResponse {
        ControlResponse(status, .object(extra.merging(["error": .string(message)]) { _, b in b }))
    }
}

/// The daemon's control.sock: HTTP/1.1 over a Unix socket at
/// `$XDG_RUNTIME_DIR/bromure-ac/control.sock`, mode 0600, and — unlike macOS,
/// where the file mode is the only gate — every connection's SO_PEERCRED uid
/// must be ours (root's connections are refused too).
// @port-skip linux-only: the type; its members carry @port lines
public final class ControlServer: Sendable {
    public let path: String
    private let channel: Channel

    /// Binds, chmods 0600, and serves `handler` for each request.
    // @port ACAutomationServer.startUnix(path: String) h=3a0a1caa7b640a41 @7dd92fdf
    public static func start(path: String, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                             handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) async throws -> ControlServer {
        if path.utf8.count > 107 { throw MachineError.socketPathTooLong(path) }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let me = getuid()
        let ch = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ControlConnection(owner: me, handler: handler))
                }
            }
            .bind(unixDomainSocketPath: path).get()
        chmod(path, 0o600)
        return ControlServer(path: path, channel: ch)
    }

    // @port-skip linux-only: control server
    private init(path: String, channel: Channel) {
        self.path = path
        self.channel = channel
    }

    // @port-skip linux-only: control server
    public func close() async {
        try? await channel.close()
        unlink(path)
    }

    /// `HTTP/1.1 <status> <text>`, JSON (pretty-printed, sorted keys),
    /// Content-Length, `Connection: close`: macOS's wire format.
    // @port ACAutomationServer.sendResponse(fd: Int32, status: Int, body: [String:Any], gzip: Bool) h=ce30c4766292fa6c @7dd92fdf
    static func encode(_ r: ControlResponse) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let (status, body) = (try? enc.encode(r.body)).map { (r.status, $0) }
            ?? (500, Data(#"{"error":"response serialization failed"}"#.utf8))
        var head = "HTTP/1.1 \(status) \(httpStatusText(status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Reason phrases. Differs from macOS on purpose for 409, which macOS
    /// sends as "OK" (it has no case for it).
    // @port ACAutomationServer.httpStatusText(_: Int) h=52b402e5982ff7be @7dd92fdf
    static func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

/// A control connection after a streaming reply's header: the client's
/// bytes as they arrive, and writes back to it.
// @port-skip linux-only: NIO stream handoff (macOS hands the raw fd to the handler)
public struct ControlStream: Sendable {
    /// Ends when the client closes (or the connection fails).
    public let inbound: AsyncStream<ByteBuffer>
    let channel: Channel
    // @port-skip linux-only: NIO stream handoff
    public func write(_ b: ByteBuffer) async throws { try await channel.writeAndFlush(b) }
}

/// Reads one request (headers to `\r\n\r\n`, then Content-Length bytes, both
/// capped as macOS does), answers it, closes.
// @port-skip linux-only: NIO request framing (macOS: a blocking read loop per thread)
final class ControlConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    static let maxHeader = 1 << 20, maxBody = 16 << 20
    let owner: uid_t
    let handler: @Sendable (ControlRequest) async -> ControlResponse
    private var buf = ByteBuffer()
    private var started = false
    /// Set once a streaming reply has taken the connection over.
    private var streamIn: AsyncStream<ByteBuffer>.Continuation?
    /// nil until SO_PEERCRED has answered: nothing is served before that.
    private var authorized: Bool?

    // @port-skip linux-only: NIO request framing
    init(owner: uid_t, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        self.owner = owner
        self.handler = handler
    }

    /// SO_PEERCRED: only our own uid gets an answer.
    // @port-skip linux-only: peer credential check (macOS has none)
    func channelActive(context: ChannelHandlerContext) {
        guard let provider = context.channel as? SocketOptionProvider else { context.close(promise: nil); return }
        let owner = self.owner
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        let peer: EventLoopFuture<acl_ucred> = provider.unsafeGetSocketOption(level: .socket, name: .init(rawValue: SO_PEERCRED))
        peer.whenComplete { r in
            let (handler, context) = bound.value
            if case .success(let cred) = r, cred.uid == owner {
                handler.authorized = true
                handler.process(context)
            } else {
                handler.authorized = false
                handler.reply(context, .error(403, "Forbidden: peer uid is not the daemon's"))
            }
        }
        context.fireChannelActive()
    }

    // @port-skip linux-only: NIO request framing
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if let streamIn { streamIn.yield(b); return }
        buf.writeBuffer(&b)
        process(context)
    }

    // @port-skip linux-only: NIO stream handoff
    func channelInactive(context: ChannelHandlerContext) {
        streamIn?.finish()
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO request framing
    private func process(_ context: ChannelHandlerContext) {
        guard authorized == true, !started else { return }
        guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if buf.readableBytes > Self.maxHeader { reply(context, .error(400, "Bad request")) }
            return
        }
        let headLen = end.upperBound - buf.readerIndex
        let head = buf.getString(at: buf.readerIndex, length: headLen) ?? ""
        var length = 0
        for line in head.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard length <= Self.maxBody else { reply(context, .error(400, "Bad request")); return }
        guard buf.readableBytes >= headLen + length else { return }
        started = true
        let line = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard line.count >= 2 else { reply(context, .error(400, "Bad request")); return }
        let bodyBytes = buf.getBytes(at: buf.readerIndex + headLen, length: length) ?? []
        let body = (try? JSONDecoder().decode(JSONValue.self, from: Data(bodyBytes))) ?? .object([:])
        let req = ControlRequest(method: String(line[0]), path: String(line[1]),
                                 body: { if case .object = body { return body }; return .object([:]) }())
        let handler = self.handler
        let promise = context.eventLoop.makePromise(of: ControlResponse.self)
        promise.completeWithTask { await handler(req) }
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        promise.futureResult.whenSuccess { r in
            let (handler, context) = bound.value
            if let stream = r.stream {
                handler.startStream(context, leftover: headLen + length, stream)
            } else {
                handler.reply(context, r)
            }
        }
    }

    /// The octet-stream header, then the connection is `body`'s: bytes the
    /// client sent after the request (and all later ones) go to its inbound.
    // @port-skip linux-only: NIO stream handoff (macOS: handleInteractiveExec writes the header on the fd)
    private func startStream(_ context: ChannelHandlerContext, leftover consumed: Int,
                             _ body: @escaping @Sendable (ControlStream) async -> Void) {
        let (inbound, cont) = AsyncStream<ByteBuffer>.makeStream()
        streamIn = cont
        buf.moveReaderIndex(forwardBy: consumed)
        if buf.readableBytes > 0 { cont.yield(buf.slice()) }
        buf = ByteBuffer()
        if !context.channel.isActive { cont.finish() }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: head)), promise: nil)
        let channel = context.channel
        Task {
            await body(ControlStream(inbound: inbound, channel: channel))
            try? await channel.close()
        }
    }

    // @port-skip linux-only: NIO request framing
    private func reply(_ context: ChannelHandlerContext, _ r: ControlResponse) {
        let data = ControlServer.encode(r)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: data))).whenComplete { _ in
            bound.value.close(promise: nil)
        }
    }

    // @port-skip linux-only: NIO request framing
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// The CLI's side: one blocking request per connection, as macOS's
/// ControlClient does.
// @port-skip linux-only: the type; its members carry @port lines
public struct ControlClient: Sendable {
    public let socketPath: String

    // @port-skip linux-only: control client
    public init(socketPath: String) { self.socketPath = socketPath }

    // @port-skip linux-only: control client
    public struct Response: Sendable {
        public let status: Int
        public let json: JSONValue
    }

    // @port-skip linux-only: control client errors
    public enum ClientError: Error, CustomStringConvertible {
        case connect(String, Int32), protocolError(String)
        // @port-skip linux-only: control client errors
        public var description: String {
            switch self {
            case .connect(let p, let e): return "can't reach the daemon at \(p): \(String(cString: strerror(e)))"
            case .protocolError(let m): return "bad response from the daemon: \(m)"
            }
        }
    }

    /// Path segment escaping for ids and names.
    // @port ControlClient.static encodeSegment(_: String) h=16982dcfd38df4b7 @53294cad
    public static func encodeSegment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // @port ControlClient.isAgentRunning() h=85833d14e8578cbe @53294cad
    public func isAgentRunning() -> Bool {
        (try? request("GET", "/health"))?.status == 200
    }

    // @port ControlClient.static connect(to: String) h=31ae0b2cf2981fe9 @53294cad
    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw ClientError.connect(path, errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw ClientError.connect(path, ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { let e = errno; close(fd); throw ClientError.connect(path, e) }
        return fd
    }

    // @port ControlClient.static writeAll(_: Int32, _: Data) h=0ccf962b390d2d20 @53294cad
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// A streaming request: returns the connected fd once a 200 header has
    /// been read (byte by byte, so no stream byte is consumed); any other
    /// status throws the reply's `error`. The header read is bounded at 12 s.
    // partial: no link-stats-scaled handshake timeout (fixed 12 s), Unix socket only
    // @port ControlClient.openStream(_: String, _: String, body: [String:Any]) h=8e529cadf8cdad71 @53294cad
    public func openStream(_ method: String, _ path: String, body: JSONValue) throws -> Int32 {
        let fd = try Self.connect(to: socketPath)
        let payload = try JSONEncoder().encode(body)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd, Data(head.utf8) + payload) else { close(fd); throw ClientError.protocolError("write failed") }
        var tv = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var header = [UInt8]()
        var one: UInt8 = 0
        while true {
            let r = read(fd, &one, 1)
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { close(fd); throw ClientError.protocolError("the daemon closed during the handshake") }
            header.append(one)
            if header.count >= 4, header.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
            if header.count > 16384 { close(fd); throw ClientError.protocolError("oversized response header") }
        }
        let status = String(decoding: header, as: UTF8.self).split(separator: "\r\n").first?
            .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard status == 200 else {
            var rest = Data()
            var b = [UInt8](repeating: 0, count: 4096)
            while true { let r = read(fd, &b, b.count); if r <= 0 { break }; rest.append(contentsOf: b[0..<r]) }
            close(fd)
            let json = (try? JSONDecoder().decode(JSONValue.self, from: rest)) ?? .null
            throw ClientError.protocolError(json["error"]?.stringValue ?? "request failed (HTTP \(status))")
        }
        var none = timeval()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// One request; reads the reply to EOF (the server closes after it).
    // @port-skip linux-only: blocking request (macOS's adds gzip, timeouts and extra headers)
    public func request(_ method: String, _ path: String, body: JSONValue? = nil) throws -> Response {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        let payload = try body.map { try JSONEncoder().encode($0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd, Data(head.utf8) + payload) else { throw ClientError.protocolError("write failed") }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: data[..<sep.lowerBound], encoding: .utf8)?.split(separator: "\r\n").first,
              let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
            throw ClientError.protocolError(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data[sep.upperBound...])) ?? .null
        return Response(status: status, json: json)
    }
}

/// The interactive exec frames, CLI <-> agentd (the daemon only pumps them):
/// `[type u8][len u32be][payload]`; data 0, resize 1 (cols u16be, rows u16be),
/// exit 2 (i32be), stdin EOF 3.
// @port-skip linux-only: the namespace; its members carry @port lines
public enum PTYFrame {
    public static let data: UInt8 = 0
    public static let resize: UInt8 = 1
    public static let exit: UInt8 = 2
    public static let eof: UInt8 = 3

    // @port PTYFrame.static encode(_: UInt8, _: [UInt8]) h=3d950a36f69dff33 @53294cad
    public static func encode(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let len = UInt32(payload.count)
        return [type, UInt8(len >> 24), UInt8((len >> 16) & 0xff), UInt8((len >> 8) & 0xff), UInt8(len & 0xff)] + payload
    }

    // @port PTYFrame.static resizePayload(cols: Int, rows: Int) h=c8eb5f2db136b1c2 @53294cad
    public static func resizePayload(cols: Int, rows: Int) -> [UInt8] {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)]
    }

    /// One frame to a blocking fd (short-write safe); false on a write error.
    // @port PTYFrame.static send(_: Int32, _: UInt8, _: [UInt8]) h=a2e489f84937d9a4 @53294cad
    @discardableResult
    public static func send(_ fd: Int32, _ type: UInt8, _ payload: [UInt8]) -> Bool {
        ControlClient.writeAll(fd, Data(encode(type, payload)))
    }

    /// Splits complete frames off the front of `buf`; a partial one stays.
    // @port-skip linux-only: frame parsing (macOS parses inline in InteractiveExec.run)
    public static func take(_ buf: inout [UInt8]) -> [(UInt8, [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var at = 0
        while buf.count - at >= 5 {
            let len = Int(buf[at + 1]) << 24 | Int(buf[at + 2]) << 16 | Int(buf[at + 3]) << 8 | Int(buf[at + 4])
            guard buf.count - at - 5 >= len else { break }
            out.append((buf[at], Array(buf[(at + 5)..<(at + 5 + len)])))
            at += 5 + len
        }
        buf.removeFirst(at)
        return out
    }
}
