import Foundation
import Darwin

// MARK: - Attached machines (Bromure Agent Host)

/// Plain Macs whose agents take part here as if they were one more machine
/// beside the workspace VMs: a Bromure Agent Host attaches ITSELF — it dials
/// this app (the control socket, locally or through the SSH `control` verb)
/// and parks connections with `POST /machines/link`. Nothing here dials out.
///
/// A parked link carries one thing once taken: this side writes a verb line
/// — `control` (then an HTTP request, answered by the machine's own control
/// API) or `delegation-mcp` (then one of its agents' MCP streams) — and the
/// machine parks a fresh link in its place.
///
/// With that the machine is:
///  • listed in /state (its workspace + VM entry + sessions) for every fat
///    client, in the same window as this host's VMs;
///  • reachable through the proxy: requests aimed at it (exec and terminals,
///    file ops, its sessions' commands) go down a link verbatim;
///  • a delegation party: `AttachedMachine` is an AgentHostLink, and its
///    agents' delegation MCP is served by this app's engine.
final class MachineLinkHub: @unchecked Sendable {
    static let shared = MachineLinkHub()

    private let cond = NSCondition()
    private var parked: [UUID: [Int32]] = [:]
    private var names: [UUID: String] = [:]
    /// Who attached each machine ("device:<id>", from the SSH grant of an
    /// agent host's key): only they may park links for it or detach it.
    /// A local caller (owner-only control socket) or a full-access key
    /// sends none and isn't bound.
    private var owners: [UUID: String] = [:]
    /// What the pollers last read from each machine, for /state.
    private var fragments: [UUID: Fragment] = [:]

    struct Fragment {
        var workspace: [String: Any]
        var vm: [String: Any]
        var sessions: [[String: Any]]
        var sessionIDs: Set<String>
        var connected: Bool
    }

    /// Posted (main queue) when a machine parks its first link or detaches.
    static let machinesChanged = Notification.Name("io.bromure.machineLinks.changed")

    // MARK: Links

    func mayPark(id: UUID, owner: String?) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard let owner, let bound = owners[id] else { return true }
        return bound == owner
    }

    /// `POST /machines/link {id, name, owner?}`: keep `fd` for later. False
    /// when the machine belongs to another owner (a stolen agent-host key
    /// can't pose as another machine and take its traffic).
    @discardableResult
    func park(fd: Int32, id: UUID, name: String, owner: String?) -> Bool {
        cond.lock()
        if let owner {
            if let bound = owners[id], bound != owner { cond.unlock(); return false }
            owners[id] = owner
        }
        let isNew = names[id] == nil
        names[id] = name
        parked[id, default: []].append(fd)
        cond.broadcast()
        cond.unlock()
        if isNew {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.machinesChanged, object: id) }
        }
        return true
    }

    /// `POST /machines/detach {id, owner?}`: forget the machine and its links.
    @discardableResult
    func detach(id: UUID, owner: String?) -> Bool {
        cond.lock()
        if let owner, let bound = owners[id], bound != owner { cond.unlock(); return false }
        owners[id] = nil
        let fds = parked.removeValue(forKey: id) ?? []
        names[id] = nil
        fragments[id] = nil
        cond.unlock()
        fds.forEach { close($0) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.machinesChanged, object: id) }
        return true
    }

    var machineIDs: [UUID] {
        cond.lock(); defer { cond.unlock() }
        return Array(names.keys)
    }

    func name(_ id: UUID) -> String? {
        cond.lock(); defer { cond.unlock() }
        return names[id]
    }

    /// A link to `id` carrying `verb`, waiting up to `timeout` for one to be
    /// parked (the machine re-parks as soon as one is taken). nil when the
    /// machine isn't there.
    func open(_ id: UUID, verb: String, timeout: TimeInterval = 10) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            cond.lock()
            while (parked[id]?.isEmpty ?? true) && names[id] != nil {
                if !cond.wait(until: deadline) { cond.unlock(); return nil }
            }
            guard names[id] != nil, let fd = parked[id]?.popLast() else { cond.unlock(); return nil }
            cond.unlock()
            // A link the machine dropped while parked fails the write: next.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let line = Array("\(verb)\n".utf8)
            if write(fd, line, line.count) == line.count { return fd }
            close(fd)
        }
    }

    // MARK: Requests down a link

    /// One control-API request to the machine; the status and JSON body.
    func request(_ id: UUID, _ method: String, _ path: String, body: [String: Any]? = nil,
                 timeout: TimeInterval = 30) -> (status: Int, json: [String: Any])? {
        guard let fd = open(id, verb: "control") else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let head = "\(method) \(path) HTTP/1.1\r\nHost: machine\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd, Data(head.utf8) + payload) else { return nil }
        // Read to Content-Length, not to EOF: over an SSH link the machine's
        // half-close doesn't come through, and waiting for EOF sat out the
        // whole receive timeout on every call.
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var expected: Int?
        while true {
            if expected == nil, let sep = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).lowercased()
                if let r = head.range(of: "content-length:") {
                    let n = Int(head[r.upperBound...].drop(while: { $0 == " " }).prefix(while: { $0.isNumber })) ?? 0
                    expected = sep.upperBound - data.startIndex + n
                }
            }
            if let expected, data.count >= expected { break }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let status = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
            .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data[sep.upperBound...])) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// Hand a client's request to the machine and splice the two until either
    /// side closes — plain replies and hijacked terminal streams alike.
    func proxy(clientFD: Int32, machine id: UUID, method: String, path: String,
               body: [String: Any], gzip: Bool) {
        // A new session: note its id at once, so the calls that follow it
        // (before the next poll lists it) are routed here too.
        if path == "/agent-sessions/start" {
            let r = request(id, method, path, body: body, timeout: 60)
            if let sid = (r?.json["id"] as? String)?.uppercased() {
                cond.lock(); fragments[id]?.sessionIDs.insert(sid); cond.unlock()
            }
            let out = (try? JSONSerialization.data(withJSONObject: r?.json ?? ["error": "That machine isn't connected right now"])) ?? Data()
            let status = r?.status ?? 502
            _ = Self.writeAll(clientFD, Data(("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n").utf8) + out)
            close(clientFD)
            return
        }
        guard let fd = open(id, verb: "control") else {
            let msg = #"{"error":"That machine isn't connected right now"}"#
            _ = Self.writeAll(clientFD, Data(("HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(msg.utf8.count)\r\nConnection: close\r\n\r\n" + msg).utf8))
            close(clientFD)
            return
        }
        let payload = body.isEmpty ? Data() : ((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        let head = "\(method) \(path) HTTP/1.1\r\nHost: machine\r\nContent-Type: application/json\r\n"
            + (gzip ? "X-Bromure-Gzip: 1\r\n" : "")
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd, Data(head.utf8) + payload) else { close(fd); close(clientFD); return }
        Self.splice(clientFD, fd)
        close(fd)
        close(clientFD)
    }

    /// Is this request for an attached machine? Its id when it is: a VM route
    /// on the machine's id, a tab on it, a session of its, or a new session /
    /// folder listing that names it.
    func target(method: String, path: String, body: [String: Any]) -> UUID? {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        cond.lock(); defer { cond.unlock() }
        guard !names.isEmpty else { return nil }
        func machine(_ s: Substring?) -> UUID? {
            guard let s, let id = UUID(uuidString: String(s).removingPercentEncoding ?? String(s)),
                  names[id] != nil else { return nil }
            return id
        }
        let parts = p.split(separator: "/")
        if p.hasPrefix("/vms/") || p.hasPrefix("/sessions/") { return machine(parts.dropFirst().first) }
        if ["/agent-sessions/start", "/agent-sessions/folders", "/agent-sessions/worktree-open",
            "/agent-sessions/worktree-discard"].contains(p) {
            return (body["profile"] as? String).flatMap { machine(Substring($0)) }
        }
        if p == "/agent-sessions/git-state" {
            let key = (body["id"] as? String ?? "").uppercased()
            return fragments.first { $0.value.sessionIDs.contains(key) }?.key
        }
        if p.hasPrefix("/agent-sessions/"), let sid = parts.dropFirst().first {
            let key = (String(sid).removingPercentEncoding ?? String(sid)).uppercased()
            return fragments.first { $0.value.sessionIDs.contains(key) }?.key
        }
        return nil
    }

    // MARK: State

    func setFragment(_ id: UUID, _ f: Fragment?) {
        cond.lock()
        if names[id] != nil { fragments[id] = f }
        cond.unlock()
    }

    /// The machines' part of /state (a disconnected machine reads as off).
    func stateAdditions() -> (workspaces: [[String: Any]], vms: [[String: Any]], sessions: [[String: Any]]) {
        cond.lock(); defer { cond.unlock() }
        var ws: [[String: Any]] = [], vms: [[String: Any]] = [], ss: [[String: Any]] = []
        for (id, name) in names {
            guard var f = fragments[id] else { continue }
            f.workspace["name"] = name
            if !f.connected { f.workspace["state"] = "off" }
            ws.append(f.workspace)
            if f.connected { vms.append(f.vm) }
            ss += f.sessions
        }
        return (ws, vms, ss)
    }

    // MARK: Byte plumbing

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var rem = raw.count
            while rem > 0 {
                let w = write(fd, base, rem)
                if w > 0 { base += w; rem -= w; continue }
                if w < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Copy both ways until either side ends.
    static func splice(_ a: Int32, _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        func copy(_ from: Int32, _ to: Int32) {
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(from, &buf, buf.count)
                    if n <= 0 { break }
                    if !writeAll(to, Data(buf[0..<n])) { break }
                }
                shutdown(to, SHUT_WR)
                shutdown(from, SHUT_RD)
                done.signal()
            }
        }
        copy(a, b)
        copy(b, a)
        done.wait()
        done.wait()
    }
}

/// One attached machine, as this app's delegation engine and UI see it:
/// its sessions (mirrored from its /state, polled through a link), and the
/// machine-side actions the engine needs.
@MainActor
final class AttachedMachine {
    let id: UUID
    private(set) var name: String
    let sessionStore = AgentSessionStore(mirror: true)
    /// Its tmux roster, as the local window's sidebar and session buckets
    /// read a VM's (fed from the machine's /state like a fat client's mirror).
    let tabsModel = TabsModel()
    private(set) var accentHex = "#5E8BDE"
    private(set) var connected = false
    /// The machine's workspace entry from its last /state (the profile a
    /// local window builds for it).
    private(set) var workspace: [String: Any] = [:]
    /// Something shown changed (connection, roster, sessions): the app
    /// refreshes its sidebar.
    var onChange: (() -> Void)?
    private var tabs: [Int: AgentStatus] = [:]
    private var poller: Task<Void, Never>?
    private var relay: DelegationRelayClient?

    init(id: UUID, name: String, makeServer: @escaping @MainActor (AttachedMachine) -> DelegationMCPServer?) {
        self.id = id
        self.name = name
        let relay = DelegationRelayClient(
            dial: { MachineLinkHub.shared.open(id, verb: "delegation-mcp", timeout: 30) },
            label: name,
            makeServer: { [weak self] in self.flatMap { makeServer($0) } })
        self.relay = relay
        relay.start()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        poller?.cancel()
        relay?.stop()
        relay = nil
    }

    private func poll() async {
        let id = self.id
        let r = await Task.detached { MachineLinkHub.shared.request(id, "GET", "/state", timeout: 10) }.value
        guard let r, r.status == 200 else {
            if connected {
                connected = false
                tabsModel.rosterLive = false
                MachineLinkHub.shared.setFragment(id, nil)
                onChange?()
            }
            return
        }
        let wasConnected = connected
        let before = sessionStore.sessions
        connected = true
        name = MachineLinkHub.shared.name(id) ?? name
        let ws = (r.json["workspaces"] as? [[String: Any]])?.first ?? [:]
        let vm = (r.json["vms"] as? [[String: Any]])?.first ?? [:]
        let sessions = (r.json["agentSessions"] as? [[String: Any]]) ?? []
        var map: [Int: AgentStatus] = [:]
        for t in (vm["tabs"] as? [[String: Any]]) ?? [] {
            if let i = t["index"] as? Int, let s = (t["agentStatus"] as? String).flatMap(AgentStatus.init(rawValue:)) {
                map[i] = s
            }
        }
        tabs = map
        workspace = ws
        if let a = ws["accentHex"] as? String { accentHex = a }
        let roster = (vm["tabs"] as? [[String: Any]]) ?? []
        tabsModel.applyRoster(roster)
        if tabsModel.rosterLive != !roster.isEmpty { tabsModel.rosterLive = !roster.isEmpty }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        sessionStore.applyMirror(sessions.compactMap { d in
            (try? JSONSerialization.data(withJSONObject: d)).flatMap { try? dec.decode(AgentSession.self, from: $0) }
        })
        MachineLinkHub.shared.setFragment(id, .init(
            workspace: ws, vm: vm, sessions: sessions,
            sessionIDs: Set(sessions.compactMap { ($0["id"] as? String)?.uppercased() }),
            connected: true))
        if !wasConnected || sessionStore.sessions != before { onChange?() }
    }

    /// A stand-in workspace for the local window's views (terminal colors,
    /// the new-session target list): the machine as its /state describes it.
    var profile: Profile {
        var p = Profile(id: id, name: name,
                        tool: Profile.Tool(rawValue: workspace["tool"] as? String ?? "") ?? .claude,
                        authMode: .subscription)
        p.color = ProfileColor(rawValue: workspace["color"] as? String ?? "") ?? .blue
        return p
    }

    /// One call to the machine's control API, for the local window.
    func control(_ method: String, _ path: String, _ body: [String: Any]?,
                 timeout: TimeInterval = 30) async -> (status: Int, json: [String: Any])? {
        await call(method, path, body, timeout: timeout)
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]?,
                      timeout: TimeInterval = 30) async -> (status: Int, json: [String: Any])? {
        let id = self.id
        return await Task.detached {
            MachineLinkHub.shared.request(id, method, path, body: body, timeout: timeout)
        }.value
    }
}

extension AttachedMachine: AgentHostLink {
    var agentHostID: UUID? { id }
    var hostName: String { name }
    var hostSessions: AgentSessionStore { sessionStore }

    func hostExec(_ command: String, timeout: Int) async throws -> String {
        guard let r = await call("POST", "/vms/\(id.uuidString)/exec",
                                 ["command": command, "timeout": timeout], timeout: TimeInterval(timeout + 15)),
              r.status == 200 else { throw ACAppDelegate.GuestExecError.connectionFailed }
        let code = r.json["exitCode"] as? Int ?? 1
        guard code == 0 else {
            throw ACAppDelegate.GuestExecError.commandFailed(exitCode: code, stderr: r.json["stderr"] as? String ?? "")
        }
        return r.json["stdout"] as? String ?? ""
    }

    func hostFileOp(_ op: [String: Any], timeout: Int) async throws -> [String: Any] {
        guard let r = await call("POST", "/vms/\(id.uuidString)/file", ["op": op, "timeout": timeout],
                                 timeout: TimeInterval(timeout + 5)) else {
            throw ACAppDelegate.GuestExecError.connectionFailed
        }
        if let err = r.json["error"] as? String { throw ACAppDelegate.GuestExecError.commandFailed(exitCode: 1, stderr: err) }
        return r.json
    }

    func hostTabStatus(window: Int) -> AgentStatus? { tabs[window] }

    func hostControl(_ method: String, _ path: String, _ body: [String: Any]?) async -> (status: Int, json: [String: Any])? {
        await call(method, path, body)
    }

    func hostSessionCommand(_ sid: UUID, _ action: String, _ body: [String: Any]) {
        Task { _ = await call("POST", "/agent-sessions/\(sid.uuidString)/\(action)", body) }
    }

    func hostStartSession(tool: Profile.Tool, cwd: String, message: String) async -> UUID? {
        let r = await call("POST", "/agent-sessions/start",
                           ["profile": id.uuidString, "tool": tool.rawValue, "cwd": cwd, "message": message])
        return (r?.json["id"] as? String).flatMap(UUID.init(uuidString:))
    }
}
