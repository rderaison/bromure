import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Control-socket client
//
// Split out of CLICommands.swift (which is ArgumentParser CLI surface,
// macOS-only) so the iOS fat client can compile it: this client + the framed
// PTY codec are the entire wire contract with the control plane, local or
// tunneled.

/// Synchronous HTTP-over-Unix-socket client for the agent's control socket —
/// the `bromure-ac` CLI's transport. Mirrors how `docker` talks to
/// /var/run/docker.sock: plain HTTP/1.1 over an AF_UNIX stream.
struct ControlClient {
    let socketPath: String
    /// How to obtain a fresh bidirectional byte stream to the control plane.
    /// Default dials the local AF_UNIX control socket; the fat client swaps in
    /// a dial that spawns an `ssh … bromure-fatclient control` subprocess wired
    /// to a socketpair (macOS) or opens an in-process NIOSSH exec channel
    /// (iOS), so the exact same request/openStream logic runs over the SSH
    /// tunnel to a remote bromure-ac. Returns an fd the caller owns, or nil.
    let dial: () -> Int32?

    init(socketPath: String? = nil) {
        let path = socketPath ?? ProfileStore().controlSocketURL.path
        self.socketPath = path
        self.dial = { ControlClient.connect(to: path) }
    }

    /// Build a client whose transport is a caller-supplied dial (e.g. the SSH
    /// tunnel). `socketPath` is retained only for diagnostics/labels.
    init(socketPath: String, dial: @escaping () -> Int32?) {
        self.socketPath = socketPath
        self.dial = dial
    }

    struct Response { let status: Int; let json: [String: Any] }

    enum ClientError: LocalizedError {
        case agentNotRunning
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .agentNotRunning:  return "The bromure-ac agent isn't running."
            case .transport(let m): return m
            }
        }
    }

    // MARK: Request

    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Response {
        guard let fd = dial() else { throw ClientError.agentNotRunning }
        defer { Darwin.close(fd) }

        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData)
        Self.writeAll(fd, out)

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            resp.append(contentsOf: buf[0..<n])
        }
        guard let str = String(data: resp, encoding: .utf8),
              let sep = str.range(of: "\r\n\r\n") else {
            throw ClientError.transport("Invalid HTTP response from agent")
        }
        // NB: "\r\n" is a single grapheme cluster in Swift, so
        // `firstIndex(of: "\r")` finds nothing — split on the substring instead.
        let firstLine = str.components(separatedBy: "\r\n").first ?? ""
        let status = firstLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let json = (try? JSONSerialization.jsonObject(
            with: Data(str[sep.upperBound...].utf8)) as? [String: Any]) ?? [:]
        return Response(status: status, json: json)
    }

    /// Write the whole buffer, looping over short writes. A single
    /// `Darwin.write` returns as few as one byte when the socket's send buffer
    /// fills — which it does for a multi-megabyte body (a base64 image/file
    /// upload) over the ssh-tunnel socketpair. Ignoring the count silently
    /// truncated the request body, so large uploads never reached the remote
    /// guest while small control calls and all downloads (tiny requests) worked.
    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n > 0 {
                    base = base.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue          // interrupted before any byte moved — retry
                } else {
                    break             // hard error or peer gone; response read reports it
                }
            }
        }
    }

    /// Open a streaming connection: send the request, consume the response
    /// header, and hand back the raw fd for bidirectional streaming. The caller
    /// owns the fd and must close it. Throws on non-200.
    func openStream(_ method: String, _ path: String, body: [String: Any]) throws -> Int32 {
        guard let fd = dial() else { throw ClientError.agentNotRunning }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData)
        Self.writeAll(fd, out)

        // Read exactly up to the end of the response header (\r\n\r\n) one byte
        // at a time, so we don't swallow any stream bytes that follow it.
        var header = [UInt8]()
        var one = [UInt8](repeating: 0, count: 1)
        while true {
            let r = Darwin.read(fd, &one, 1)
            if r <= 0 { Darwin.close(fd); throw ClientError.transport("Agent closed during handshake") }
            header.append(one[0])
            let c = header.count
            if c >= 4, header[c-4] == 13, header[c-3] == 10, header[c-2] == 13, header[c-1] == 10 { break }
            if c > 16384 { Darwin.close(fd); throw ClientError.transport("Oversized response header") }
        }
        let headStr = String(decoding: header, as: UTF8.self)
        let firstLine = headStr.components(separatedBy: "\r\n").first ?? ""
        let status = firstLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        if status != 200 {
            var rest = Data(); var b = [UInt8](repeating: 0, count: 4096)
            while true { let r = Darwin.read(fd, &b, b.count); if r <= 0 { break }; rest.append(contentsOf: b[0..<r]) }
            Darwin.close(fd)
            let msg = ((try? JSONSerialization.jsonObject(with: rest)) as? [String: Any])?["error"] as? String
                ?? "request failed (HTTP \(status))"
            throw ClientError.transport(msg)
        }
        return fd
    }

    /// True if the agent answers a health probe on the control socket.
    func isAgentRunning() -> Bool {
        ((try? request("GET", "/health"))?.status ?? 0) == 200
    }

#if os(macOS)
    /// Ensure the agent is up — autostart `bromure-ac run --headless` if not,
    /// then poll the control socket until it answers (or `timeout` elapses).
    func ensureAgentRunning(timeout: TimeInterval = 40) throws {
        if isAgentRunning() { return }

        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["run", "--headless"]
        // Detach from this CLI's stdio so the agent survives us exiting.
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() }
        catch { throw ClientError.transport("Couldn't start the agent: \(error.localizedDescription)") }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAgentRunning() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ClientError.transport("Agent didn't come up within \(Int(timeout))s.")
    }
#endif

    /// Percent-encode an id/name as a single path segment so values with
    /// spaces (e.g. a profile named "Default profile") survive the HTTP request
    /// line. The agent decodes it before resolving.
    static func encodeSegment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Socket

    private static let cliDebug = ProcessInfo.processInfo.environment["BROMURE_CLI_DEBUG"] != nil

    private static func connect(to path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            if cliDebug { FileHandle.standardError.write(Data("[cli] socket() failed: \(String(cString: strerror(errno)))\n".utf8)) }
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            if cliDebug { FileHandle.standardError.write(Data("[cli] path too long (\(bytes.count) >= \(cap)): \(path)\n".utf8)) }
            Darwin.close(fd); return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            if cliDebug { FileHandle.standardError.write(Data("[cli] connect() failed: \(String(cString: strerror(errno))) path=\(path)\n".utf8)) }
            Darwin.close(fd); return nil
        }
        return fd
    }
}

// MARK: - Framed PTY wire codec

/// The interactive-attach frame codec, shared by the macOS `InteractiveExec`
/// pump (CLI/TUI, over a real tty) and the iOS in-process pump (SwiftTerm).
/// Wire format: `[type:u8][len:u32be][payload]`; types 0=data 1=resize
/// 2=exit 3=stdin-EOF.
enum PTYFrame {
    static let data: UInt8 = 0
    static let resize: UInt8 = 1
    static let exit: UInt8 = 2
    static let eof: UInt8 = 3

    static func encode(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [type]
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xff)); out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff));  out.append(UInt8(len & 0xff))
        out.append(contentsOf: payload)
        return out
    }

    static func resizePayload(cols: Int, rows: Int) -> [UInt8] {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)]
    }

    /// Write one frame to a blocking fd (short-write safe).
    static func send(_ fd: Int32, _ type: UInt8, _ payload: [UInt8]) {
        let out = encode(type, payload)
        out.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n > 0 { base += n; remaining -= n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    /// Drain complete frames off the front of `buffer`, calling `handle` for
    /// each. Leaves any trailing partial frame in place.
    static func drain(_ buffer: inout [UInt8], handle: (UInt8, [UInt8]) -> Void) {
        while buffer.count >= 5 {
            let type = buffer[0]
            let len = (Int(buffer[1]) << 24) | (Int(buffer[2]) << 16)
                    | (Int(buffer[3]) << 8) | Int(buffer[4])
            if buffer.count < 5 + len { break }
            let payload = Array(buffer[5 ..< 5 + len])
            buffer.removeFirst(5 + len)
            handle(type, payload)
        }
    }
}
