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
///   GET    /app/state             — full app-state snapshot
///   POST   /sessions/{id}/exec    — run a shell command inside the guest
///   GET    /vms                   — list running VMs
///   POST   /vms                   — create + boot a VM (profile ref or inline spec)
///   DELETE /vms/{id}              — stop a VM (body: `{ "action": "shutdown"|"suspend" }`)
///   POST   /vms/{id}/attach       — open a window onto a running VM
///   POST   /vms/{id}/exec         — run a shell command inside the guest
///
/// The TCP listener binds 127.0.0.1 and gates exec / app-state / vm endpoints
/// behind BROMURE_DEBUG_CLAUDE. The owner-only Unix control socket
/// (`control.sock`, mode 0600) used by the `bromure-ac` CLI is trusted: the
/// socket file's permissions are the access gate, so no env var is required.
final class ACAutomationServer {
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    let port: UInt16
    let bindAddress: String
    /// When non-nil, bind an AF_UNIX socket at this path instead of TCP — the
    /// owner-only local control socket used by the `bromure-ac` CLI.
    let unixSocketPath: String?
    /// True for the Unix control socket: `exec` / `/app/state` / `/vms` routes
    /// are allowed without `BROMURE_DEBUG_CLAUDE`, because reaching a 0600
    /// socket already proves local ownership.
    let isTrustedLocal: Bool

    let debugEnabled: Bool

    /// Callbacks plumbed by the app delegate.
    var onListProfiles: (() -> [ACAutomationProfileInfo])?
    var onListSessions: (() -> [ACAutomationSessionInfo])?
    var onCreateSession: ((_ profileNameOrID: String) async -> ACAutomationSessionInfo?)?
    var onDestroySession: ((_ profileNameOrID: String) async -> Bool)?
    var onGetAppState: (() -> [String: Any])?
    /// Debug: render a window (`which` = "unified" | "picker" | "editor") to a
    /// PNG at the given path and return a dump of its subview frames. The app
    /// draws itself, so this needs no Screen Recording permission.
    var onUIShot: ((_ path: String, _ which: String) -> [String: Any])?
    /// Debug: drive the settings editor for the screenshot tool — `action` is
    /// "ensure-profile" | "open" | "category" | "close". Lets the doc-screenshot
    /// script navigate over the control socket instead of AppleScript.
    var onEditorDebug: ((_ params: [String: Any]) -> [String: Any])?
    /// Returns a vsock connection wrapping a ShellBridge-dequeued one, or nil
    /// if no shell-agent connection is available for that session.
    var onGetShellConnection: ((_ profileID: String) -> ACShellProxyConnection?)?
    /// Resolve an id-or-name to the canonical profile UUID string, so interactive
    /// attach state is keyed the same way the consent broker queries it (by UUID).
    var onResolveProfileID: ((_ idOrName: String) -> String?)?

    // docker-style VM control plane (CLI). Each returns plain dicts/bools so
    // the server stays free of app types.
    var onListVMs: (() -> [[String: Any]])?
    var onStopVM: ((_ idOrName: String, _ action: String) async -> Bool)?
    var onAttachVM: ((_ idOrName: String) async -> Bool)?
    /// Create (boot) a VM from a profile ref or inline spec + mounts. Returns
    /// the new VM's info dict, or nil on failure.
    var onCreateVM: ((_ spec: [String: Any]) async -> [String: Any]?)?

    // Profile management (CLI `profiles …`).
    var onDescribeProfile: ((_ idOrName: String) -> [String: Any]?)?
    var onDeleteProfile: ((_ idOrName: String) -> [String: Any])?

    // MITM trace inspection (CLI `trace …`) + fusion toggle (`vm fusion`).
    var onListTrace: ((_ profileKey: String?) -> [[String: Any]])?
    var onClearTrace: (() -> Int)?
    var onSetFusion: ((_ idOrName: String, _ engaged: Bool) -> [String: Any])?
    // Local-inference routing (vLLM.md): `vm routing`, `vm hybrid`, `model use`.
    var onSetRouting: ((_ idOrName: String, _ mode: String) -> [String: Any])?
    var onSetHybrid: ((_ idOrName: String, _ knob: String, _ value: Double) -> [String: Any])?
    var onSetModel: ((_ idOrName: String, _ modelID: String) -> [String: Any])?

    // Remote access (optional SSH front door) — CLI `remote …` + Preferences.
    var onRemoteStatus: (() -> [String: Any])?
    var onRemoteApply: ((_ spec: [String: Any]) -> [String: Any])?
    var onRemoteAddKey: ((_ publicKey: String) -> [String: Any])?
    var onRemoteRemoveKey: ((_ selector: String) -> [String: Any])?

    init(port: UInt16 = 9223, bindAddress: String = "127.0.0.1") {
        // 9223 (one off from the browser's 9222) so both apps can run side
        // by side during development without conflicting.
        self.port = port
        self.bindAddress = bindAddress
        self.unixSocketPath = nil
        self.isTrustedLocal = false
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    /// Owner-only Unix-domain control socket for the local CLI. Always trusted
    /// — the 0600 socket file is the access gate.
    init(unixSocketPath: String) {
        self.port = 0
        self.bindAddress = ""
        self.unixSocketPath = unixSocketPath
        self.isTrustedLocal = true
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    func start() {
        if let path = unixSocketPath { startUnix(path: path) } else { startTCP() }
    }

    private func startTCP() {
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
        beginAccepting(on: sock)
        print("[ACAutomation] listening on \(bindAddress):\(port)\(debugEnabled ? " (debug endpoints enabled)" : "")")
    }

    private func startUnix(path: String) {
        unlink(path)   // clear any stale socket from a previous run
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[ACAutomation] ERROR: failed to create unix socket")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        guard pathBytes.count < cap else {
            print("[ACAutomation] ERROR: control socket path too long (\(pathBytes.count) ≥ \(cap))")
            Darwin.close(sock)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            print("[ACAutomation] ERROR: unix bind failed on \(path): \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }
        chmod(path, 0o600)   // owner-only: the file mode is the access gate
        Darwin.listen(sock, 32)
        beginAccepting(on: sock)
        print("[ACAutomation] control socket listening on \(path)")
    }

    private func beginAccepting(on sock: Int32) {
        self.serverSocket = sock
        let unixPath = unixSocketPath
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            if self?.serverSocket == sock { Darwin.close(sock) }
            if let unixPath { unlink(unixPath) }
        }
        source.resume()
        self.acceptSource = source
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
        // Address-family-agnostic accept (works for both TCP and the Unix
        // control socket); we don't use the peer address.
        let clientFD = Darwin.accept(serverSocket, nil, nil)
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
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            var state = DispatchQueue.main.sync { self.onGetAppState?() ?? [:] }
            state["debugEnabled"] = true
            sendResponse(fd: fd, status: 200, body: state)

        case (_, let p) where p == "/debug/ui-shot" || p.hasPrefix("/debug/ui-shot?"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Local only"])
                return
            }
            var pathParam = "/tmp/bromure-ui-shot.png"
            var whichParam = "unified"
            if let q = p.split(separator: "?", maxSplits: 1).dropFirst().first {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let v = kv[1].removingPercentEncoding ?? String(kv[1])
                    if kv.first == "path" { pathParam = v }
                    if kv.first == "which" { whichParam = v }
                }
            }
            let dump = DispatchQueue.main.sync { self.onUIShot?(pathParam, whichParam) ?? ["error": "no handler"] }
            sendResponse(fd: fd, status: 200, body: dump)

        case ("POST", "/debug/editor"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Local only"])
                return
            }
            let r = DispatchQueue.main.sync { self.onEditorDebug?(bodyJSON) ?? ["error": "no handler"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

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

        // docker-style VM control plane.
        case ("GET", "/vms"):
            let vms = DispatchQueue.main.sync { self.onListVMs?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["vms": vms])

        case ("POST", "/vms"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onCreateVM?(bodyJSON)
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if let info = result {
                // A handler that returns an `error` key is a clean refusal
                // (e.g. the workspace's local model is still downloading).
                if let err = info["error"] as? String {
                    sendResponse(fd: fd, status: 409, body: ["error": err])
                } else {
                    sendResponse(fd: fd, status: 201, body: info)
                }
            } else {
                sendResponse(fd: fd, status: 500, body: ["error": "Failed to create VM"])
            }

        // Remote access control plane (CLI `remote …`). Owner-only socket.
        case ("GET", "/remote"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let s = DispatchQueue.main.sync { self.onRemoteStatus?() ?? [:] }
            sendResponse(fd: fd, status: 200, body: s)

        case ("POST", "/remote"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let r = DispatchQueue.main.sync { self.onRemoteApply?(bodyJSON) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case ("POST", "/remote/keys"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let key = (bodyJSON["key"] as? String) ?? ""
            let r = DispatchQueue.main.sync { self.onRemoteAddKey?(key) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case (let m, let p) where m == "DELETE" && p.hasPrefix("/remote/keys/"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let sel = String(p.dropFirst("/remote/keys/".count)).removingPercentEncoding
                ?? String(p.dropFirst("/remote/keys/".count))
            let r = DispatchQueue.main.sync { self.onRemoteRemoveKey?(sel) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case (let m, let p) where p.hasPrefix("/vms/"):
            handleVMRoute(fd: fd, method: m, path: p, bodyJSON: bodyJSON)

        case (let m, let p) where p.hasPrefix("/profiles/"):
            handleProfileRoute(fd: fd, method: m, path: p)

        case (let m, let p) where p == "/trace" || p.hasPrefix("/trace?"):
            handleTraceRoute(fd: fd, method: m, path: p)

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
            guard debugEnabled || isTrustedLocal else {
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

    private func handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        // Strip any query string; params come from the JSON body.
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let rest = String(noQuery.dropFirst("/vms/".count))
        // The id/name is a single percent-encoded path segment (so names with
        // spaces survive the request line) — decode it before resolving.
        func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }

        if rest.hasSuffix("/exec") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            handleExec(fd: fd, profileID: decode(String(rest.dropLast("/exec".count))), bodyJSON: bodyJSON)
            return
        }
        if rest.hasSuffix("/attach") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/attach".count)))
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in ok = await self.onAttachVM?(id) ?? false; semaphore.signal() }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: ok ? 200 : 404,
                         body: ok ? ["status": "attached"] : ["error": "VM not found"])
            return
        }
        if rest.hasSuffix("/fusion") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/fusion".count)))
            let engaged = (bodyJSON["engaged"] as? Bool) ?? false
            let result = DispatchQueue.main.sync { self.onSetFusion?(id, engaged) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/routing") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/routing".count)))
            let mode = (bodyJSON["mode"] as? String) ?? "cloud"
            let result = DispatchQueue.main.sync { self.onSetRouting?(id, mode) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/hybrid") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/hybrid".count)))
            let knob = (bodyJSON["knob"] as? String) ?? ""
            let value = (bodyJSON["value"] as? Double) ?? Double((bodyJSON["value"] as? Int) ?? 0)
            let result = DispatchQueue.main.sync { self.onSetHybrid?(id, knob, value) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/model") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/model".count)))
            let modelID = (bodyJSON["modelID"] as? String) ?? ""
            let result = DispatchQueue.main.sync { self.onSetModel?(id, modelID) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        // /vms/{id}
        let id = decode(rest)
        switch method {
        case "DELETE":
            let action = (bodyJSON["action"] as? String) ?? "shutdown"
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in ok = await self.onStopVM?(id, action) ?? false; semaphore.signal() }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: ok ? 200 : 404,
                         body: ok ? ["status": "stopped"] : ["error": "VM not found"])
        case "GET":
            let vms = DispatchQueue.main.sync { self.onListVMs?() ?? [] }
            if let vm = vms.first(where: {
                ($0["id"] as? String) == id || ($0["shortId"] as? String) == id
                    || ($0["name"] as? String) == id
            }) {
                sendResponse(fd: fd, status: 200, body: vm)
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "VM not found"])
            }
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleTraceRoute(fd: Int32, method: String, path: String) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        // Optional ?profile=<key> filter.
        var profileKey: String?
        if let qIdx = path.firstIndex(of: "?") {
            for pair in path[path.index(after: qIdx)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "profile" {
                    profileKey = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        switch method {
        case "GET":
            let recs = DispatchQueue.main.sync { self.onListTrace?(profileKey) ?? [] }
            sendResponse(fd: fd, status: 200, body: ["trace": recs])
        case "DELETE":
            let n = DispatchQueue.main.sync { self.onClearTrace?() ?? 0 }
            sendResponse(fd: fd, status: 200, body: ["cleared": n])
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleProfileRoute(fd: Int32, method: String, path: String) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let raw = String(noQuery.dropFirst("/profiles/".count))
        let id = raw.removingPercentEncoding ?? raw
        switch method {
        case "GET":
            if let d = DispatchQueue.main.sync(execute: { self.onDescribeProfile?(id) }) {
                sendResponse(fd: fd, status: 200, body: d)
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Profile not found"])
            }
        case "DELETE":
            let result = DispatchQueue.main.sync(execute: { self.onDeleteProfile?(id) })
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleExec(fd: Int32, profileID: String, bodyJSON: [String: Any]) {
        // Interactive (`exec -it`): hijack the client connection and stream a
        // pty session — no request/response framing at this layer.
        if bodyJSON["interactive"] as? Bool == true {
            handleInteractiveExec(clientFD: fd, profileID: profileID, bodyJSON: bodyJSON)
            return
        }
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
                "error": "No shell connection for '\(profileID)' after 10s — the VM may not be running, the id/name didn't match, or its shell agent hasn't come up yet.",
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

    /// Run `command` in `profileID`'s VM via the shell agent; return stdout, or
    /// nil on failure. Blocking — call off the main thread (it hops to main only
    /// to dequeue a shell connection). Used by `RemoteConsent` to drive a tmux
    /// consent popup over SSH.
    public func vmExec(profileID: String, command: String, timeoutSeconds: Int) -> String? {
        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let conn = shellConn else { return nil }
        defer { _ = conn.conn }   // keep the connection alive until we're done
        return Self.executeShellCommand(fd: conn.fd, command: command, timeout: timeoutSeconds)?.stdout
    }

    // Sessions currently attached interactively over CLI/SSH (profileID → count;
    // a session can have more than one attach). SHARED (static) across every
    // AutomationServer instance: the attach is handled by `controlServer` (Unix
    // socket) but the consent broker may query via `automationServer` (TCP), so
    // per-instance state would never match (that was the `marked=[]` bug).
    private static let attachLock = NSLock()
    nonisolated(unsafe) private static var attachedCounts: [String: Int] = [:]

    /// True while `profileID` has at least one live interactive (CLI/SSH) attach.
    public func isInteractivelyAttached(_ profileID: String) -> Bool {
        Self.attachLock.lock(); defer { Self.attachLock.unlock() }
        let hit = (Self.attachedCounts[profileID] ?? 0) > 0
        FileHandle.standardError.write(Data(
            "[consent] attached? q=\(profileID.prefix(8)) marked=\(Self.attachedCounts.keys.map { String($0.prefix(8)) }) → \(hit)\n".utf8))
        return hit
    }
    private func markAttached(_ profileID: String) {
        Self.attachLock.lock(); Self.attachedCounts[profileID, default: 0] += 1; Self.attachLock.unlock()
    }
    private func unmarkAttached(_ profileID: String) {
        Self.attachLock.lock()
        if let c = Self.attachedCounts[profileID] { Self.attachedCounts[profileID] = c <= 1 ? nil : c - 1 }
        Self.attachLock.unlock()
    }

    /// Interactive pty session: dequeue a guest shell connection, tell the
    /// guest to go interactive, then pump raw bytes between the CLI's socket and
    /// the guest vsock until either side closes. The pty framing is end-to-end
    /// (CLI <-> guest); this layer is a transparent byte pump.
    private func handleInteractiveExec(clientFD: Int32, profileID: String, bodyJSON: [String: Any]) {
        let command = bodyJSON["command"] as? String ?? ""
        let cols = bodyJSON["cols"] as? Int ?? 80
        let rows = bodyJSON["rows"] as? Int ?? 24

        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let conn = shellConn else {
            sendResponse(fd: clientFD, status: 502, body: [
                "error": "No shell connection for '\(profileID)' after 10s — the VM may not be running or its shell agent hasn't come up yet.",
            ])
            return
        }
        let vsockFD = conn.fd

        // Tell the guest to start an interactive pty: [u32be len][JSON].
        let req: [String: Any] = ["cmd": command, "interactive": true, "cols": cols, "rows": rows]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else {
            sendResponse(fd: clientFD, status: 500, body: ["error": "Failed to encode request"])
            return
        }
        var lenBE = UInt32(reqData.count).bigEndian
        let framed = Data(bytes: &lenBE, count: 4) + reqData
        _ = framed.withUnsafeBytes { Darwin.write(vsockFD, $0.baseAddress, framed.count) }

        // Switch the client to raw streaming, then become a transparent pump.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        let hbytes = Array(header.utf8)
        _ = hbytes.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, hbytes.count) }

        // For the life of this attach the session is "in CLI/SSH mode" — consent
        // prompts go to a tmux popup the attached user can see, not an NSAlert.
        // Key by the canonical UUID (the CLI may pass a name/short id) so the
        // consent broker, which queries by UUID, actually matches.
        let attachKey = (DispatchQueue.main.sync { self.onResolveProfileID?(profileID) }) ?? profileID
        FileHandle.standardError.write(Data(
            "[consent] attach START raw=\(profileID) key=\(attachKey.prefix(8))\n".utf8))
        markAttached(attachKey)
        defer { unmarkAttached(attachKey) }
        Self.pump(clientFD, vsockFD)
        _ = conn.conn   // keep the vsock connection alive for the whole pump
        Darwin.close(clientFD)
    }

    /// Bidirectional raw byte pump between two fds until either closes.
    private static func pump(_ a: Int32, _ b: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bad = Int16(POLLHUP | POLLERR | POLLNVAL)
        while true {
            var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, -1)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { continue }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let r = Darwin.read(a, &buf, buf.count)
                if r <= 0 { break }
                if !writeAll(b, buf, r) { break }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let r = Darwin.read(b, &buf, buf.count)
                if r <= 0 { break }
                if !writeAll(a, buf, r) { break }
            }
            if (fds[0].revents & bad) != 0 && (fds[0].revents & Int16(POLLIN)) == 0 { break }
            if (fds[1].revents & bad) != 0 && (fds[1].revents & Int16(POLLIN)) == 0 { break }
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let w = buf.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: off), count - off)
            }
            if w <= 0 { return false }
            off += w
        }
        return true
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
    let shortId: String
    let name: String
    let color: String
    let tool: String
    let authMode: String
    let mcpServerCount: Int
    /// Live lifecycle state: "off" | "suspended" | "booting" | "running".
    let state: String

    func toDict() -> [String: Any] {
        [
            "id": id,
            "shortId": shortId,
            "name": name,
            "color": color,
            "tool": tool,
            "authMode": authMode,
            "mcpServerCount": mcpServerCount,
            "state": state,
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
