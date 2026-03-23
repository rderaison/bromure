import Foundation
import SandboxEngine

/// HTTP server that exposes a JSON API and CDP reverse proxy on a single port.
///
/// API endpoints:
///   GET  /health                — health check
///   GET  /profiles              — list available profiles
///   GET  /sessions              — list active sessions
///   POST /sessions              — create a new session  {"profile":"name-or-id", "url":"...", "restore":true}
///   GET  /sessions/:id          — get session info
///   DELETE /sessions/:id        — close a session
///
/// CDP proxy (all traffic forwarded to the session's Chromium via vsock):
///   /cdp/:sessionId/*           — reverse proxy to Chromium's CDP
///
/// Example Puppeteer usage:
///   const browser = await puppeteer.connect({
///     browserWSEndpoint: "ws://127.0.0.1:9222/cdp/SESSION_ID/devtools/browser/..."
///   });
final class AutomationServer {
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    let port: UInt16
    let bindAddress: String

    /// Whether debug endpoints (/exec, /app/*) are enabled.
    /// Gated on BROMURE_DEBUG_CLAUDE environment variable.
    let debugEnabled: Bool

    /// Callbacks into the app delegate for session management.
    var onCreateSession: ((_ profileName: String?, _ profileID: String?, _ url: String?, _ restore: Bool) async -> AutomationSessionInfo?)?
    var onDestroySession: ((_ sessionID: String) async -> Bool)?
    var onListSessions: (() -> [AutomationSessionInfo])?
    var onListProfiles: (() -> [AutomationProfileInfo])?

    /// Callback to get a vsock connection for a session's CDP.
    var onGetCDPConnection: ((_ sessionID: String) -> CDPProxyConnection?)?

    /// Callback to get a vsock connection for a session's shell (debug only).
    var onGetShellConnection: ((_ sessionID: String) -> ShellProxyConnection?)?

    /// Callback to get app state (debug only).
    var onGetAppState: (() -> [String: Any])?

    /// Callback to get trace events for a session with optional filters.
    var onGetTrace: ((_ sessionID: String, _ filters: [String: String]) -> [[String: Any]])?

    init(port: UInt16 = 9222, bindAddress: String = "127.0.0.1") {
        self.port = port
        self.bindAddress = bindAddress
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    func start() {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[AutomationServer] ERROR: failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(bindAddress)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            print("[AutomationServer] ERROR: bind failed on \(bindAddress):\(port): \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }

        Darwin.listen(sock, 32)
        self.serverSocket = sock

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            // Only close if stop() hasn't already closed it
            if self?.serverSocket == sock {
                Darwin.close(sock)
            }
        }
        source.resume()
        self.acceptSource = source

        print("[AutomationServer] listening on \(bindAddress):\(port)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        print("[AutomationServer] stopped")
    }

    // MARK: - Connection handling

    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.accept(serverSocket, sockPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Ensure clean connection shutdown — linger so data flushes before close
        var linger = Darwin.linger(l_onoff: 1, l_linger: 2)
        setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleRequest(fd: clientFD)
        }
    }

    private func handleRequest(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var totalRead = 0

        // Initial read — may contain headers + partial/full body
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else {
            Darwin.close(fd)
            return
        }
        totalRead = n

        // Check if we have the full body by parsing Content-Length
        if let raw = String(bytes: buf[0..<totalRead], encoding: .utf8),
           let headerEnd = raw.range(of: "\r\n\r\n") {
            let headers = String(raw[..<headerEnd.lowerBound]).lowercased()
            if let clRange = headers.range(of: "content-length: "),
               let clValue = Int(headers[clRange.upperBound...].prefix(while: { $0.isNumber })) {
                let bodyStart = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
                let bodyReceived = totalRead - bodyStart
                // Read remaining body bytes if needed
                var remaining = clValue - bodyReceived
                while remaining > 0 && totalRead < buf.count {
                    var tmp = [UInt8](repeating: 0, count: min(remaining, buf.count - totalRead))
                    let extra = Darwin.read(fd, &tmp, tmp.count)
                    if extra <= 0 { break }
                    buf.replaceSubrange(totalRead..<totalRead + extra, with: tmp[0..<extra])
                    totalRead += extra
                    remaining -= extra
                }
            }
        }

        let raw = String(bytes: buf[0..<totalRead], encoding: .utf8) ?? ""
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(fd: fd, status: 400, body: ["error": "Bad request"])
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(fd: fd, status: 400, body: ["error": "Bad request"])
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // CDP proxy: /cdp/:sessionId/...
        if path.hasPrefix("/cdp/") {
            let rest = path.dropFirst("/cdp/".count)
            // Extract session ID (up to the next /)
            let slashIdx = rest.firstIndex(of: "/") ?? rest.endIndex
            let sessionID = String(rest[rest.startIndex..<slashIdx])
            let innerPath = slashIdx < rest.endIndex ? String(rest[slashIdx...]) : "/"

            handleCDPProxy(fd: fd, sessionID: sessionID, innerPath: innerPath,
                           originalRequest: buf, requestLength: n, requestLine: requestLine,
                           method: method)
            return
        }

        // Extract JSON body
        var bodyJSON: [String: Any] = [:]
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty,
               let data = bodyStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodyJSON = json
            }
        }

        // API routes
        switch (method, path) {
        case ("GET", "/health"):
            sendResponse(fd: fd, status: 200, body: ["status": "ok", "service": "bromure-automation"])

        case ("GET", "/sessions"):
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            let list = sessions.map { $0.toDict() }
            sendResponse(fd: fd, status: 200, body: ["sessions": list])

        case ("POST", "/sessions"):
            let profileName = bodyJSON["profile"] as? String
            let profileID = bodyJSON["profileId"] as? String
            let url = bodyJSON["url"] as? String
            let restore = bodyJSON["restore"] as? Bool ?? false

            if profileName == nil && profileID == nil {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing 'profile' or 'profileId' field"])
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: AutomationSessionInfo?
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onCreateSession?(profileName, profileID, url, restore)
                    semaphore.signal()
                }
            }
            semaphore.wait()

            if let info = result {
                sendResponse(fd: fd, status: 201, body: info.toDict())
            } else {
                sendResponse(fd: fd, status: 500, body: ["error": "Failed to create session"])
            }

        // Trace: get captured events with optional query filters
        case ("GET", _) where path.contains("/trace") && path.hasPrefix("/sessions/"):
            // Parse: /sessions/UUID/trace?hostname=x&method=GET...
            let afterSessions = path.dropFirst("/sessions/".count)
            let pathAndQuery = String(afterSessions)
            let components = pathAndQuery.components(separatedBy: "/trace")
            let sessionID = components[0]
            // Parse query parameters
            var filters: [String: String] = [:]
            if let queryPart = pathAndQuery.components(separatedBy: "?").last,
               pathAndQuery.contains("?") {
                for param in queryPart.components(separatedBy: "&") {
                    let kv = param.components(separatedBy: "=")
                    if kv.count == 2 {
                        filters[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                    }
                }
            }
            let events = DispatchQueue.main.sync { self.onGetTrace?(sessionID, filters) ?? [] }
            sendResponse(fd: fd, status: 200, body: ["events": events, "count": events.count])

        case ("GET", _) where path.hasPrefix("/sessions/"):
            let sessionID = String(path.dropFirst("/sessions/".count))
            if sessionID.isEmpty {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing session ID"])
                return
            }
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            if let session = sessions.first(where: { $0.id == sessionID }) {
                sendResponse(fd: fd, status: 200, body: session.toDict())
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }

        case ("DELETE", _) where path.hasPrefix("/sessions/"):
            let sessionID = String(path.dropFirst("/sessions/".count))
            if sessionID.isEmpty {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing session ID"])
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var success = false
            DispatchQueue.main.async {
                Task { @MainActor in
                    success = await self.onDestroySession?(sessionID) ?? false
                    semaphore.signal()
                }
            }
            semaphore.wait()

            if success {
                sendResponse(fd: fd, status: 200, body: ["status": "closed"])
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }

        case ("GET", "/profiles"):
            let profiles = DispatchQueue.main.sync { self.onListProfiles?() ?? [] }
            let list = profiles.map { $0.toDict() }
            sendResponse(fd: fd, status: 200, body: ["profiles": list])

        // Debug: execute shell command in a session's VM
        case ("POST", _) where path.hasSuffix("/exec") && path.hasPrefix("/sessions/"):
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            let middle = path.dropFirst("/sessions/".count).dropLast("/exec".count)
            let sessionID = String(middle)
            let command = bodyJSON["command"] as? String ?? ""
            let timeout = bodyJSON["timeout"] as? Int ?? 30

            if command.isEmpty {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing 'command' field"])
                return
            }

            // Get shell connection (wait up to 10s for pool to fill)
            var shellConn: ShellProxyConnection?
            for _ in 0..<100 {
                shellConn = DispatchQueue.main.sync {
                    self.onGetShellConnection?(sessionID)
                }
                if shellConn != nil { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let conn = shellConn else {
                sendResponse(fd: fd, status: 502, body: ["error": "No shell connection available for session \(sessionID) after 10s"])
                return
            }

            if let result = Self.executeShellCommand(fd: conn.fd, command: command, timeout: timeout) {
                sendResponse(fd: fd, status: 200, body: [
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exitCode": result.exitCode,
                ])
            } else {
                sendResponse(fd: fd, status: 502, body: ["error": "Shell command execution failed"])
            }
            _ = conn.conn

        // Debug: app state
        case ("GET", "/app/state"):
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            let state = DispatchQueue.main.sync { self.onGetAppState?() ?? [:] }
            sendResponse(fd: fd, status: 200, body: state)

        default:
            sendResponse(fd: fd, status: 404, body: ["error": "Not found"])
        }
    }

    // MARK: - CDP Proxy

    private func handleCDPProxy(fd: Int32, sessionID: String, innerPath: String,
                                originalRequest: [UInt8], requestLength: Int,
                                requestLine: String, method: String) {
        // Get a vsock connection for this session, waiting up to 10s for the
        // guest cdp-agent to replenish the pool if it's temporarily empty.
        var proxyConn: CDPProxyConnection?
        for _ in 0..<100 {  // 100 × 100ms = 10s
            proxyConn = DispatchQueue.main.sync {
                self.onGetCDPConnection?(sessionID)
            }
            if proxyConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let proxy = proxyConn else {
            sendResponse(fd: fd, status: 502, body: ["error": "No CDP connection available for session \(sessionID) after 10s"])
            return
        }

        let vsockFD = proxy.fd

        // Rewrite the first HTTP request line: replace /cdp/:sessionId/... with /...
        // Original: "GET /cdp/SESSION_ID/json/version HTTP/1.1"
        // Rewritten: "GET /json/version HTTP/1.1"
        let originalPath = "/cdp/\(sessionID)\(innerPath)"
        let rewrittenPath = innerPath.isEmpty ? "/" : innerPath

        let rawStr = String(bytes: originalRequest[0..<requestLength], encoding: .utf8) ?? ""
        let rewritten = rawStr.replacingOccurrences(of: " \(originalPath) ", with: " \(rewrittenPath) ")

        // Also rewrite the Host header to point to the local CDP
        // (Chromium may check this for WebSocket upgrade)
        let finalRequest = rewritten
            .replacingOccurrences(
                of: "Host: [^\r\n]+",
                with: "Host: 127.0.0.1:9222",
                options: .regularExpression
            )

        // Send rewritten request to vsock
        guard let requestData = finalRequest.data(using: .utf8) else {
            sendResponse(fd: fd, status: 500, body: ["error": "Request encoding failed"])
            return
        }

        let ok = requestData.withUnsafeBytes { buf in
            Self.writeAll(fd: vsockFD, buf: buf.baseAddress!, count: buf.count)
        }
        guard ok else {
            sendResponse(fd: fd, status: 502, body: ["error": "Failed to send to CDP"])
            // Keep conn reference alive until we're done
            _ = proxy.conn
            return
        }

        // Now bridge bidirectionally until either side closes.
        // This handles both short HTTP responses and long-lived WebSocket.
        Self.bridgeLoop(fd1: fd, fd2: vsockFD)

        Darwin.close(fd)
        // Keep VZVirtioSocketConnection alive until bridge is done
        _ = proxy.conn
    }

    /// Bidirectional byte bridge between two file descriptors. Blocks until done.
    private static func bridgeLoop(fd1: Int32, fd2: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var fds = [pollfd(fd: fd1, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: fd2, events: Int16(POLLIN), revents: 0)]

        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            let ret = poll(&fds, 2, 120_000) // 120s timeout
            if ret <= 0 { break }

            for i in 0..<2 {
                guard fds[i].revents & Int16(POLLIN) != 0 else { continue }
                let srcFD = fds[i].fd
                let dstFD = fds[1 - i].fd
                let n = Darwin.read(srcFD, &buf, buf.count)
                if n <= 0 { return }
                let ok = buf.withUnsafeBytes { ptr in
                    writeAll(fd: dstFD, buf: ptr.baseAddress!, count: n)
                }
                if !ok { return }
            }

            // Check for hangup/error on either side
            let hupErr = Int16(POLLHUP | POLLERR)
            if fds[0].revents & hupErr != 0 || fds[1].revents & hupErr != 0 { break }
        }
    }

    // MARK: - Shell execution

    /// Execute a shell command over a vsock connection using the shell-agent protocol.
    /// Blocking I/O — call from a background queue.
    private static func executeShellCommand(fd: Int32, command: String, timeout: Int) -> ShellExecResult? {
        let request: [String: Any] = ["cmd": command, "timeout": timeout]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request) else { return nil }

        // Send [u32be len][json]
        var length = UInt32(jsonData.count).bigEndian
        let lenOK = withUnsafeBytes(of: &length) { buf in
            writeAll(fd: fd, buf: buf.baseAddress!, count: 4)
        }
        guard lenOK else { return nil }

        let dataOK = jsonData.withUnsafeBytes { buf in
            writeAll(fd: fd, buf: buf.baseAddress!, count: buf.count)
        }
        guard dataOK else { return nil }

        // Read response [u32be len][json]
        var respLenBuf = [UInt8](repeating: 0, count: 4)
        guard readAll(fd: fd, buf: &respLenBuf, count: 4) else { return nil }
        let respLen = respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard respLen > 0, respLen < 100 * 1024 * 1024 else { return nil }

        var respBuf = [UInt8](repeating: 0, count: Int(respLen))
        guard readAll(fd: fd, buf: &respBuf, count: Int(respLen)) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: Data(respBuf)) as? [String: Any] else { return nil }

        return ShellExecResult(
            stdout: json["stdout"] as? String ?? "",
            stderr: json["stderr"] as? String ?? "",
            exitCode: json["exit_code"] as? Int ?? -1
        )
    }

    private static func readAll(fd: Int32, buf: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var read = 0
        while read < count {
            let n = Darwin.read(fd, buf + read, count - read)
            if n <= 0 { return false }
            read += n
        }
        return true
    }

    // MARK: - Helpers

    private static func writeAll(fd: Int32, buf: UnsafeRawPointer, count: Int) -> Bool {
        var written = 0
        while written < count {
            let w = Darwin.write(fd, buf + written, count - written)
            if w <= 0 { return false }
            written += w
        }
        return true
    }

    private func sendResponse(fd: Int32, status: Int, body: Any) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 502: statusText = "Bad Gateway"
        default: statusText = "Unknown"
        }

        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()

        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        let response = header.data(using: .utf8)! + jsonData

        response.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let w = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                if w <= 0 { break }
                sent += w
            }
        }
        Darwin.close(fd)
    }
}

// MARK: - Data transfer types

/// A vsock connection ready to proxy CDP traffic.
struct CDPProxyConnection {
    let fd: Int32
    /// Keep alive to prevent VZ from closing the file descriptor.
    let conn: Any
}

struct AutomationSessionInfo {
    let id: String
    let profileName: String
    let profileID: String?
    /// Base URL for CDP access via the automation server.
    let cdpURL: String

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "profileName": profileName,
            "webSocketDebuggerUrl": cdpURL,
        ]
        if let profileID { d["profileId"] = profileID }
        return d
    }
}

/// A vsock connection ready to proxy shell commands (debug only).
struct ShellProxyConnection {
    let fd: Int32
    /// Keep alive to prevent VZ from closing the file descriptor.
    let conn: Any
}

struct ShellExecResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
}

struct AutomationProfileInfo {
    let id: String
    let name: String
    let isPersistent: Bool
    let color: String?

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "isPersistent": isPersistent,
        ]
        if let color { d["color"] = color }
        return d
    }
}
