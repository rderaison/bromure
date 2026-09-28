import Foundation
import Darwin

/// The agent host's control socket: the subset of bromure-ac's control API
/// (AutomationServer.swift) a fat client needs to mirror this Mac as one
/// machine with agent sessions — /state, /vms, exec (plain and the framed
/// PTY stream behind every terminal), file ops, agent-session commands.
/// Same wire rules as bromure-ac's: HTTP/1.1, one request per connection,
/// `Connection: close`, zlib bodies when the client sends X-Bromure-Gzip.
/// Reached over SSH (`bromure-fatclient/1 control`, spliced by the shared
/// RemoteSSHHandlers) or locally by the `claude` launcher.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()

    private var listenFD: Int32 = -1
    private let startedAt = Date()
    private var gridCells: [[String: Any]] = []
    private let gridLock = NSLock()

    func start() throws {
        let path = AgentHostPaths.controlSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.failed("socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw HostError.failed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else {
            let e = String(cString: strerror(errno)); close(fd)
            throw HostError.failed("bind \(path): \(e)")
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw HostError.failed("listen failed") }
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "agent-host.control"
        t.start()
        AgentHostLog.log("control: listening on \(path)")
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                AgentHostLog.log("control: accept failed: \(String(cString: strerror(errno)))")
                return
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(fd: c) }
        }
    }

    // MARK: Request

    private struct Request {
        var method: String
        var path: String
        var body: [String: Any]
        var gzip: Bool
    }

    private func handle(fd: Int32) {
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Int?
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { close(fd); return }
            data.append(contentsOf: chunk[0..<n])
            headerEnd = Self.findHeaderEnd(data)
            if headerEnd == nil, data.count > (1 << 20) { close(fd); return }
        }
        let start = headerEnd!
        let header = String(decoding: data[0..<start], as: UTF8.self)
        let lower = header.lowercased()
        var contentLength = 0
        if let r = lower.range(of: "content-length:") {
            contentLength = Int(lower[r.upperBound...].drop(while: { $0 == " " }).prefix(while: { $0.isNumber })) ?? 0
        }
        contentLength = min(max(0, contentLength), 16 << 20)
        while data.count - start < contentLength {
            let n = read(fd, &chunk, min(chunk.count, contentLength - (data.count - start)))
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        let line = header.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { respond(fd, 400, ["error": "Bad request"], gzip: false); return }
        var body: [String: Any] = [:]
        if data.count > start,
           let json = try? JSONSerialization.jsonObject(with: Data(data[start...])) as? [String: Any] {
            body = json
        }
        let req = Request(method: String(parts[0]), path: String(parts[1]), body: body,
                          gzip: lower.contains("x-bromure-gzip: 1"))
        route(fd, req)
    }

    private static func findHeaderEnd(_ d: [UInt8]) -> Int? {
        guard d.count >= 4 else { return nil }
        for i in 0...(d.count - 4) where d[i] == 13 && d[i + 1] == 10 && d[i + 2] == 13 && d[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    // MARK: Routing

    private func route(_ fd: Int32, _ req: Request) {
        let path = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.path
        let engine = SessionEngine.shared
        func reply(_ status: Int, _ body: [String: Any]) { respond(fd, status, body, gzip: req.gzip) }
        func replyResult(_ r: Result<[String: Any], HostError>) {
            switch r {
            case .success(let b): reply(200, b)
            case .failure(let e): reply(e.status, ["error": e.message])
            }
        }

        switch (req.method, path) {
        case ("GET", "/health"):
            reply(200, ["status": "ok", "service": "bromure-native", "debugEnabled": false])

        case ("GET", "/state"):
            reply(200, stateSnapshot())

        case ("GET", "/vms"):
            reply(200, ["vms": [vmEntry(engine.snapshot())]])

        case ("GET", "/grid-layout"):
            gridLock.lock(); let cells = gridCells; gridLock.unlock()
            reply(200, ["cells": cells])

        case ("POST", "/grid-layout"):
            gridLock.lock(); gridCells = (req.body["cells"] as? [[String: Any]]) ?? []; gridLock.unlock()
            reply(200, ["ok": true])

        case ("POST", "/remote/keys"):
            let key = (req.body["key"] as? String) ?? ""
            let r: [String: Any] = DispatchQueue.main.sync {
                do { try RemoteAccessServer.shared.addAuthorizedKey(key); return ["ok": true] }
                catch { return ["error": error.localizedDescription] }
            }
            reply(r["error"] == nil ? 200 : 400, r)

        case ("DELETE", let p) where p.hasPrefix("/remote/keys/"):
            let sel = String(p.dropFirst("/remote/keys/".count)).removingPercentEncoding ?? ""
            let r: [String: Any] = DispatchQueue.main.sync {
                do { try RemoteAccessServer.shared.removeAuthorizedKey(sel); return ["ok": true] }
                catch { return ["error": error.localizedDescription] }
            }
            reply(r["error"] == nil ? 200 : 400, r)

        case ("POST", "/agent-sessions/start"):
            let tool = (req.body["tool"] as? String) ?? "claude"
            let r = engine.start(.init(tool: tool, cwd: (req.body["cwd"] as? String) ?? "~",
                                       cloneURL: req.body["cloneURL"] as? String,
                                       message: req.body["message"] as? String,
                                       attachments: (req.body["attachments"] as? [[String: Any]]) ?? [],
                                       extraArgs: (req.body["extraArgs"] as? [String]) ?? []))
            switch r {
            case .success(let s): reply(200, ["ok": true, "id": s.id.uuidString, "window": s.window])
            case .failure(let e): reply(e.status, ["error": e.message])
            }

        case ("POST", "/agent-sessions/folders"):
            reply(200, ["folders": Self.folders(at: (req.body["path"] as? String) ?? "~")])

        case ("GET", let p) where p.hasPrefix("/agent-sessions/") && p.hasSuffix("/transcript"):
            let idStr = String(p.dropFirst("/agent-sessions/".count).dropLast("/transcript".count))
            guard let id = UUID(uuidString: idStr.removingPercentEncoding ?? idStr) else {
                reply(400, ["error": "Bad session id"]); return
            }
            if let data = engine.transcript(id) {
                reply(200, ["transcript": data.base64EncodedString()])
            } else {
                reply(404, ["error": "No transcript"])
            }

        case ("POST", let p) where p.hasPrefix("/agent-sessions/"):
            let parts = String(p.dropFirst("/agent-sessions/".count)).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0].removingPercentEncoding ?? parts[0]) else {
                reply(404, ["error": "Not available on a native machine"]); return
            }
            replyResult(engine.command(id, parts[1], req.body))

        case ("POST", let p) where p.hasPrefix("/sessions/") && p.hasSuffix("/tab"):
            let action = (req.body["action"] as? String) ?? ""
            let index = req.body["index"] as? Int
            switch action {
            case "select": if let index { Tmux.selectWindow(index) }
            case "close": if let index { Tmux.killWindow(index) }
            case "new":
                _ = Tmux.newWindow(cwd: NSHomeDirectory(), name: "shell",
                                   command: "exec \(shellQuote(Tmux.userShell)) -l", options: [:])
            default: reply(400, ["error": "action must be select, new or close"]); return
            }
            reply(200, ["ok": true])

        case ("POST", let p) where p.hasPrefix("/vms/") && p.hasSuffix("/exec"):
            if req.body["interactive"] as? Bool == true {
                PTYBridge.run(clientFD: fd, body: req.body)
                return
            }
            let r = HostExec.run(req.body)
            reply(r.status, r.body)

        case ("POST", let p) where p.hasPrefix("/vms/") && p.hasSuffix("/file"):
            let r = HostExec.fileOp((req.body["op"] as? [String: Any]) ?? [:])
            reply(r["error"] == nil ? 200 : 409, r)

        default:
            reply(404, ["error": "Not available on a native machine"])
        }
    }

    // MARK: State

    /// The fat client's snapshot. One workspace ("This Mac", always running
    /// — a client ignores an empty workspace list) whose single VM entry
    /// carries the tmux windows as tabs, plus the sessions.
    func stateSnapshot() -> [String: Any] {
        let snap = SessionEngine.shared.snapshot()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let sessions: [[String: Any]] = snap.sessions.compactMap {
            guard let d = try? enc.encode($0) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        gridLock.lock(); let cells = gridCells; gridLock.unlock()
        return [
            "version": 1,
            "supportsPush": false,
            "hostKind": "agent-host",
            "workspaces": [workspaceEntry(snap)],
            "vms": [vmEntry(snap)],
            "agentSessions": sessions,
            "gridLayout": ["cells": cells],
            "automations": ["automations": [], "runs": []],
            "tasks": ["tasks": []],
            "pendingPrompts": [],
            "subscriptions": [:],
        ]
    }

    /// What this machine is called wherever it shows up (the bromure.io
    /// device, a Bromure AC's Native Machines): the user's choice, else the
    /// Mac's name with `-native` — so it never reads as the Bromure AC of the
    /// same Mac ("macdev" vs "macdev-native").
    static let machineNameKey = "machineName"
    static var defaultMachineName: String {
        (Host.current().localizedName ?? "mac") + "-native"
    }
    static var machineName: String {
        let saved = UserDefaults.standard.string(forKey: machineNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultMachineName : saved
    }
    /// Save a new name (trimmed, at most 60 characters; empty = the default).
    static func setMachineName(_ raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if name.isEmpty || name == defaultMachineName {
            UserDefaults.standard.removeObject(forKey: machineNameKey)
        } else {
            UserDefaults.standard.set(name, forKey: machineNameKey)
        }
    }

    private func workspaceEntry(_ snap: SessionEngine.Snapshot) -> [String: Any] {
        [
            "id": SessionEngine.shared.hostID.uuidString,
            "name": Self.machineName,
            "accentHex": "#5E8BDE",
            "color": "blue",
            "tool": "claude",
            "authMode": "subscription",
            "state": snap.tmuxUp ? "running" : "booting",
            "compromised": false,
            "memoryGB": Int(ProcessInfo.processInfo.physicalMemory >> 30),
            "cpuCount": ProcessInfo.processInfo.activeProcessorCount,
            "diskAllocatedBytes": 0,
            "diskCapacityBytes": 0,
            "hostKind": "agent-host",
        ]
    }

    private func vmEntry(_ snap: SessionEngine.Snapshot) -> [String: Any] {
        let tabs: [[String: Any]] = snap.windows.map { w in
            var t: [String: Any] = ["index": w.index, "title": w.title, "active": w.active, "cwd": w.cwd]
            if snap.agents[w.index] != nil {
                // A hook's last word; an agent that just started has none yet.
                t["agentStatus"] = snap.prompting.contains(w.index) ? "needsInput"
                    : ["working", "done", "needsInput"].contains(w.status) ? w.status : "done"
            }
            return t
        }
        return [
            "id": SessionEngine.shared.hostID.uuidString,
            "name": Self.machineName,
            "state": snap.tmuxUp ? "running" : "booting",
            "accentHex": "#5E8BDE",
            "kubeClusterID": "",
            "ip": "",
            // Monotonic, like a VM's: the machine's own uptime.
            "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
            "mounts": [],
            "tabs": tabs,
            "hostKind": "agent-host",
        ]
    }

    /// The new-session folder browser: sub-folders of `path` (not hidden).
    static func folders(at path: String) -> [String] {
        let dir = SessionEngine.expand(path)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Response

    private func respond(_ fd: Int32, _ status: Int, _ body: [String: Any], gzip: Bool) {
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        var status = status
        if data.isEmpty { status = 500; data = Data(#"{"error":"response serialization failed"}"#.utf8) }
        var extra = ""
        if gzip, data.count > 1024, let z = try? (data as NSData).compressed(using: .zlib) {
            data = z as Data
            extra = "X-Bromure-Gzip: 1\r\n"
        }
        let head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\nContent-Type: application/json\r\n"
            + extra + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        Self.writeAll(fd, Data(head.utf8) + data)
        close(fd)
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard var base = p.baseAddress else { return }
            var left = p.count
            while left > 0 {
                let n = write(fd, base, left)
                if n > 0 { base += n; left -= n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                }
                return
            }
        }
    }

    private static func statusText(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 501: return "Not Implemented"
        default: return s < 400 ? "OK" : "Error"
        }
    }
}
