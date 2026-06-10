import Foundation
import SandboxEngine

/// HTTP server exposing a JSON API for orchestrating Bromure Agentic Coding
/// from outside the process. Intended use cases:
///   - Tests/ac-e2e.mjs (the main client today)
///   - `bromure-ac mcp` (the MCP subcommand wraps this same surface)
///
/// Endpoints (v1):
///   GET    /health                — `{ "status": "ok", "service": "bromure-ac-automation" }`
///   GET    /profiles              — `{ "profiles": [{ id, name, color, tool, authMode }, …] }`
///   GET    /sessions              — `{ "sessions": [{ profileId, profileName, windowId, visible }, …] }`
///   POST   /sessions              — body: `{ "profile": "<name-or-uuid>" }`; returns the
///                                   `AutomationSessionInfo` for the new session
///   GET    /sessions/{id}         — single-session info (id is the profile UUID)
///   DELETE /sessions/{id}         — close any open session for that profile
///   GET    /app/state             — debug-gated; full app-state snapshot
///   POST   /sessions/{id}/exec    — debug-gated; shell exec inside the guest. Wired
///                                   when ShellBridge lands in Phase 2b — returns
///                                   503 until then.
///
/// Bound to 127.0.0.1 by default. Debug endpoints are gated on the
/// BROMURE_DEBUG_CLAUDE environment variable, same as the browser.
final class ACAutomationServer {
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    let port: UInt16
    let bindAddress: String

    let debugEnabled: Bool

    /// Callbacks plumbed by the app delegate.
    var onListProfiles: (() -> [ACAutomationProfileInfo])?
    var onListSessions: (() -> [ACAutomationSessionInfo])?
    var onCreateSession: ((_ profileNameOrID: String) async -> ACAutomationSessionInfo?)?
    var onDestroySession: ((_ profileNameOrID: String) async -> Bool)?
    var onGetAppState: (() -> [String: Any])?
    /// Returns a vsock connection wrapping a ShellBridge-dequeued one,
    /// or nil if no shell-agent connection is available for that session.
    /// Will be wired in Phase 2b.
    var onGetShellConnection: ((_ profileID: String) -> ACShellProxyConnection?)?

    init(port: UInt16 = 9223, bindAddress: String = "127.0.0.1") {
        // 9223 (one off from the browser's 9222) so both apps can run side
        // by side during development without conflicting.
        self.port = port
        self.bindAddress = bindAddress
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    func start() {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[ACAutomation] ERROR: failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

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
            print("[ACAutomation] ERROR: bind failed on \(bindAddress):\(port): \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }

        Darwin.listen(sock, 32)
        self.serverSocket = sock

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            if self?.serverSocket == sock { Darwin.close(sock) }
        }
        source.resume()
        self.acceptSource = source

        print("[ACAutomation] listening on \(bindAddress):\(port)\(debugEnabled ? " (debug endpoints enabled)" : "")")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        print("[ACAutomation] stopped")
    }

    // MARK: - Connection

    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.accept(serverSocket, sockPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        var linger = Darwin.linger(l_onoff: 1, l_linger: 2)
        setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleRequest(fd: clientFD)
        }
    }

    private func handleRequest(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { Darwin.close(fd); return }
        var totalRead = n

        // Read the body if Content-Length says there's more
        if let raw = String(bytes: buf[0..<totalRead], encoding: .utf8),
           let headerEnd = raw.range(of: "\r\n\r\n") {
            let headers = String(raw[..<headerEnd.lowerBound]).lowercased()
            if let clRange = headers.range(of: "content-length: "),
               let clValue = Int(headers[clRange.upperBound...].prefix(while: { $0.isNumber })) {
                let bodyStart = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
                var remaining = clValue - (totalRead - bodyStart)
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

        var bodyJSON: [String: Any] = [:]
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty,
               let data = bodyStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodyJSON = json
            }
        }

        route(fd: fd, method: method, path: path, bodyJSON: bodyJSON)
    }

    // MARK: - Routing

    private func route(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        switch (method, path) {
        case ("GET", "/health"):
            sendResponse(fd: fd, status: 200, body: [
                "status": "ok",
                "service": "bromure-ac-automation",
                "debugEnabled": debugEnabled,
            ])

        case ("GET", "/profiles"):
            let profiles = DispatchQueue.main.sync { self.onListProfiles?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["profiles": profiles.map { $0.toDict() }])

        case ("GET", "/sessions"):
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["sessions": sessions.map { $0.toDict() }])

        case ("POST", "/sessions"):
            guard let profile = (bodyJSON["profile"] as? String) ?? (bodyJSON["profileId"] as? String),
                  !profile.isEmpty else {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing 'profile' field"])
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: ACAutomationSessionInfo?
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onCreateSession?(profile)
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if let info = result {
                sendResponse(fd: fd, status: 201, body: info.toDict())
            } else {
                sendResponse(fd: fd, status: 500, body: ["error": "Failed to create session"])
            }

        case ("GET", "/app/state"):
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            var state = DispatchQueue.main.sync { self.onGetAppState?() ?? [:] }
            state["debugEnabled"] = true
            sendResponse(fd: fd, status: 200, body: state)

        // Run the prompt-injection detectors on supplied text and return a
        // verdict — a test/introspection hook so the e2e suite can exercise
        // the real detection code (heuristic scanner + ONNX models) with
        // known good/bad data, without booting a VM. Gated behind the debug
        // flag like the other introspection endpoints.
        case ("POST", "/detect/prompt-injection"):
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            let text = (bodyJSON["text"] as? String) ?? ""
            let kind = (bodyJSON["kind"] as? String) ?? "rules"
            sendResponse(fd: fd, status: 200, body: Self.runDetection(text: text, kind: kind))

        // /sessions/{id} and /sessions/{id}/exec
        case (let m, let p) where p.hasPrefix("/sessions/"):
            handleSessionRoute(fd: fd, method: m, path: p, bodyJSON: bodyJSON)

        default:
            sendResponse(fd: fd, status: 404, body: ["error": "Not found", "path": path])
        }
    }

    /// Run the real prompt-injection detectors on `text` and return a verdict.
    /// `kind == "source"` → PromptGuard (tool_result injection). Otherwise the
    /// rogue-instruction detectors: the deterministic `RulesFileScanner`
    /// heuristics (always available) plus the fine-tuned ModernBERT model when
    /// installed. `modelInstalled` lets the caller distinguish "model said no"
    /// from "model not downloaded".
    private static func runDetection(text: String, kind: String) -> [String: Any] {
        // Box so the semaphore-bridged Task can write the async result without
        // a concurrent-capture warning on a bare local var.
        final class Box: @unchecked Sendable { var hit = false }

        if kind == "source" {
            let installed = PromptInjectionModels.isInstalled(.promptGuard)
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.hit = await PromptInjectionClassifier.shared
                    .detect(spans: [(id: "test", content: text)]) != nil
                sem.signal()
            }
            sem.wait()
            return ["detector": "source", "flagged": box.hit, "modelInstalled": installed]
        }

        // rules: deterministic heuristics + ModernBERT (if installed).
        let findings = RulesFileScanner.scanHiddenUnicode(text)
            + RulesFileScanner.scanInstructionContent(text)
        let heuristicHigh = findings.contains { $0.severity == .high }
        let installed = PromptInjectionModels.isInstalled(.claudeMdGuard)
        let box = Box()
        if installed {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.hit = await PromptInjectionClassifier.claudeMd
                    .detect(spans: [(id: "test", content: text)]) != nil
                sem.signal()
            }
            sem.wait()
        }
        return [
            "detector": "rules",
            "flagged": heuristicHigh || box.hit,
            "heuristicHigh": heuristicHigh,
            "signals": findings.map { $0.signal },
            "modelFlagged": box.hit,
            "modelInstalled": installed,
        ]
    }

    private func handleSessionRoute(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        let rest = String(path.dropFirst("/sessions/".count))
        if rest.hasSuffix("/exec") {
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
                return
            }
            let id = String(rest.dropLast("/exec".count))
            handleExec(fd: fd, profileID: id, bodyJSON: bodyJSON)
            return
        }

        // /sessions/{id}
        let id = rest
        switch method {
        case "GET":
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            if let s = sessions.first(where: { $0.profileID == id || $0.profileName == id }) {
                sendResponse(fd: fd, status: 200, body: s.toDict())
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }
        case "DELETE":
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in
                    ok = await self.onDestroySession?(id) ?? false
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if ok {
                sendResponse(fd: fd, status: 200, body: ["status": "closed"])
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleExec(fd: Int32, profileID: String, bodyJSON: [String: Any]) {
        let command = bodyJSON["command"] as? String ?? ""
        if command.isEmpty {
            sendResponse(fd: fd, status: 400, body: ["error": "Missing 'command' field"])
            return
        }
        let timeout = bodyJSON["timeout"] as? Int ?? 30

        // Wait up to 10s for a shell connection (matches the browser's behavior).
        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let conn = shellConn else {
            sendResponse(fd: fd, status: 502, body: [
                "error": "No shell connection available for profile \(profileID) after 10s. ShellBridge wiring lands in Phase 2b.",
            ])
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
        _ = conn.conn  // keep alive until response is sent
    }

    // MARK: - Shell-agent protocol

    /// Wire format: [u32be len][JSON {"cmd": "...", "timeout": N}] →
    ///              [u32be len][JSON {"stdout": "...", "stderr": "...", "exit_code": N}]
    private static func executeShellCommand(fd: Int32, command: String, timeout: Int) -> ACShellExecResult? {
        let request: [String: Any] = ["cmd": command, "timeout": timeout]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: request) else {
            return nil
        }
        var lenBE = UInt32(bodyData.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        let payload = lenData + bodyData

        let bytesWritten = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(fd, base, payload.count)
        }
        guard bytesWritten == payload.count else { return nil }

        // Read length prefix
        var lenBuf = [UInt8](repeating: 0, count: 4)
        var got = 0
        while got < 4 {
            let n = lenBuf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: got), 4 - got)
            }
            if n <= 0 { return nil }
            got += n
        }
        let respLen = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
        guard respLen < 50 * 1024 * 1024 else { return nil }

        var bodyBuf = [UInt8](repeating: 0, count: Int(respLen))
        got = 0
        while got < Int(respLen) {
            let n = bodyBuf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: got), Int(respLen) - got)
            }
            if n <= 0 { return nil }
            got += n
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bodyBuf)) as? [String: Any] else {
            return nil
        }
        return ACShellExecResult(
            stdout: obj["stdout"] as? String ?? "",
            stderr: obj["stderr"] as? String ?? "",
            exitCode: obj["exit_code"] as? Int ?? -1
        )
    }

    // MARK: - Response helpers

    private func sendResponse(fd: Int32, status: Int, body: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let statusText = httpStatusText(status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        let headerData = Data(response.utf8)
        let payload = headerData + bodyData
        _ = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(fd, base, payload.count)
        }
        Darwin.close(fd)
    }

    private func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "OK"
        }
    }
}

// MARK: - DTOs

struct ACAutomationProfileInfo {
    let id: String
    let name: String
    let color: String
    let tool: String
    let authMode: String
    let mcpServerCount: Int

    func toDict() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "color": color,
            "tool": tool,
            "authMode": authMode,
            "mcpServerCount": mcpServerCount,
        ]
    }
}

struct ACAutomationSessionInfo {
    let profileID: String
    let profileName: String
    let windowID: Int
    let visible: Bool

    func toDict() -> [String: Any] {
        [
            "profileId": profileID,
            "profileName": profileName,
            "windowId": windowID,
            "visible": visible,
        ]
    }
}

struct ACShellProxyConnection {
    let fd: Int32
    /// Keep alive until response sent.
    let conn: Any
}

struct ACShellExecResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
}
