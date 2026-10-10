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
    /// Machines in the fleet with links here, by name. Only these are
    /// listed, routed to and served delegation.
    private var names: [UUID: String] = [:]
    /// Machines that asked to join and wait for the user's answer: their
    /// links park, but nothing reaches them (and they reach nothing) yet.
    private var pending: [UUID: (name: String, owner: String?)] = [:]
    /// The user's answers, kept across launches (`storeURL`): each machine
    /// id allowed or blocked, bound to the device that asked ("device:<id>",
    /// from the SSH grant of an agent host's key) — only that device may
    /// park links for it or detach it, after a restart too.
    private var admissions: [UUID: Admission] = [:]
    /// A client started a session on a machine through the proxy: its id
    /// and the request (a `room` in it is this host's to record).
    var onSessionStarted: ((UUID, [String: Any]) -> Void)?
    /// What the pollers last read from each machine, for /state.
    private var fragments: [UUID: Fragment] = [:]

    struct Admission: Codable {
        var name: String
        var owner: String?
        var allowed: Bool
        var at: Date
    }

    struct Fragment {
        var workspace: [String: Any]
        var vm: [String: Any]
        var sessions: [[String: Any]]
        var sessionIDs: Set<String>
        var connected: Bool
    }

    /// Posted (main queue) when a machine joins (its first link, admitted)
    /// or leaves.
    static let machinesChanged = Notification.Name("io.bromure.machineLinks.changed")
    /// Posted (main queue) when a machine starts or stops waiting for an
    /// answer.
    static let admissionsChanged = Notification.Name("io.bromure.machineLinks.admissions")

    /// Where the answers are kept; nil keeps them in memory (tests).
    var storeURL: URL? {
        didSet {
            cond.lock()
            admissions = [:]
            if let storeURL, let data = try? Data(contentsOf: storeURL) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                admissions = (try? dec.decode([UUID: Admission].self, from: data)) ?? [:]
            }
            cond.unlock()
        }
    }

    private func saveLocked() {
        guard let storeURL else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(admissions) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
        chmod(storeURL.path, 0o600)
    }

    // MARK: Links

    enum Admit: Equatable { case allowed, pending, refused(String) }

    /// Whether `owner` may park a link for machine `id`. `reserved`: the ids
    /// of this host's workspaces and VMs — a machine taking one would have
    /// their traffic routed to it. A caller with no owner (this Mac's own
    /// control socket, or a full-access key) is trusted as it already is
    /// everywhere else, and joins without asking.
    func admit(id: UUID, owner: String?, reserved: Set<UUID>) -> Admit {
        cond.lock(); defer { cond.unlock() }
        if reserved.contains(id) { return .refused("That id belongs to a workspace on this host") }
        if let a = admissions[id] {
            if let owner, let bound = a.owner, bound != owner {
                return .refused("That machine is attached by another device")
            }
            if !a.allowed { return .refused("This server blocked that machine") }
            return .allowed
        }
        if let owner, let p = pending[id], let bound = p.owner, bound != owner {
            return .refused("That machine is attached by another device")
        }
        return owner == nil ? .allowed : .pending
    }

    /// Kept for callers that only need the yes/no.
    func mayPark(id: UUID, owner: String?) -> Bool {
        if case .refused = admit(id: id, owner: owner, reserved: []) { return false }
        return true
    }

    /// `POST /machines/link {id, name, owner?}`: keep `fd` for later — live
    /// if the machine is in the fleet, else waiting for the user's answer.
    /// False when it may not park at all.
    @discardableResult
    func park(fd: Int32, id: UUID, name: String, owner: String?, reserved: Set<UUID> = []) -> Bool {
        let verdict = admit(id: id, owner: owner, reserved: reserved)
        if case .refused = verdict { return false }
        cond.lock()
        var joined = false, asked = false
        if verdict == .allowed {
            if admissions[id] == nil, owner != nil {
                admissions[id] = Admission(name: name, owner: owner, allowed: true, at: Date())
                saveLocked()
            }
            joined = names[id] == nil
            names[id] = name
        } else {
            asked = pending[id] == nil
            pending[id] = (name, owner)
        }
        parked[id, default: []].append(fd)
        cond.broadcast()
        cond.unlock()
        if joined { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.machinesChanged, object: id) } }
        if asked { Self.noteAdmissions() }
        return true
    }

    /// The user's answer for a waiting (or listed, or blocked) machine.
    /// Allowing admits it — its links already parked go live; blocking
    /// drops it and refuses it from now on. False when `id` isn't known.
    @discardableResult
    func decide(id: UUID, allow: Bool) -> Bool {
        cond.lock()
        let wait = pending[id]
        let known = wait != nil || names[id] != nil || admissions[id] != nil
        guard known else { cond.unlock(); return false }
        let name = wait?.name ?? names[id] ?? admissions[id]?.name ?? "Mac"
        let owner = wait?.owner ?? admissions[id]?.owner
        admissions[id] = Admission(name: name, owner: owner, allowed: allow, at: Date())
        saveLocked()
        pending[id] = nil
        var fds: [Int32] = []
        var changed = false
        if allow {
            if wait != nil, !(parked[id]?.isEmpty ?? true) { names[id] = name; changed = true }
        } else {
            fds = parked.removeValue(forKey: id) ?? []
            changed = names.removeValue(forKey: id) != nil
            fragments[id] = nil
        }
        cond.broadcast()
        cond.unlock()
        fds.forEach { close($0) }
        if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.machinesChanged, object: id) } }
        Self.noteAdmissions()
        return true
    }

    /// Forget a blocked machine's answer: it asks again when it next dials.
    func forget(id: UUID) {
        cond.lock()
        let had = admissions.removeValue(forKey: id) != nil
        if had { saveLocked() }
        cond.unlock()
        if had { Self.noteAdmissions() }
    }

    /// For /state: who waits for an answer, who is blocked.
    func admissionState() -> (pending: [[String: Any]], blocked: [[String: Any]]) {
        cond.lock(); defer { cond.unlock() }
        let p = pending.map { ["id": $0.key.uuidString, "name": $0.value.name] as [String: Any] }
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let b = admissions.filter { !$0.value.allowed }
            .map { ["id": $0.key.uuidString, "name": $0.value.name] as [String: Any] }
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return (p, b)
    }

    private static func noteAdmissions() {
        ACAutomationServer.noteMutation()
        DispatchQueue.main.async { NotificationCenter.default.post(name: admissionsChanged, object: nil) }
    }

    /// `POST /machines/detach {id, owner?}`: forget the machine and its links.
    @discardableResult
    func detach(id: UUID, owner: String?) -> Bool {
        cond.lock()
        if let owner, let bound = admissions[id]?.owner ?? pending[id]?.owner, bound != owner {
            cond.unlock(); return false
        }
        let fds = parked.removeValue(forKey: id) ?? []
        let wasPending = pending.removeValue(forKey: id) != nil
        names[id] = nil
        fragments[id] = nil
        cond.unlock()
        fds.forEach { close($0) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.machinesChanged, object: id) }
        if wasPending { Self.noteAdmissions() }
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
                if let u = UUID(uuidString: sid) { onSessionStarted?(u, body) }
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
        // The reply's head is due once the machine has done the work (an
        // exec runs up to its own timeout; a guarded type ~75 s): past that,
        // the link is a dead end and holding it would pin this thread.
        let work = TimeInterval(max(0, (body["timeout"] as? Int) ?? 0))
        Self.relay(clientFD, fd, headWithin: work + Self.replyHeadGrace)
        close(fd)
        close(clientFD)
    }

    /// How long a proxied request's reply head may take beyond the work the
    /// request itself asked for.
    static let replyHeadGrace: TimeInterval = 90

    /// Like splice, but a reply that states its Content-Length ends there:
    /// over an SSH link the machine's close never arrives, so waiting for it
    /// held every proxied call (a folder listing, an exec) until the
    /// client's receive timeout. Streams without one (the framed PTY) run to
    /// EOF as before.
    ///
    /// `headWithin`: the most the machine may take to start its reply — a
    /// link whose far end is gone (a relayed path that never saw it close)
    /// otherwise holds the call, and this thread, forever. Once the head is
    /// in, the reply may take as long as it needs (a terminal stream).
    static func relay(_ client: Int32, _ machine: Int32, headWithin: TimeInterval? = nil) {
        func receiveTimeout(_ secs: TimeInterval) {
            var tv = timeval(tv_sec: Int(secs), tv_usec: Int32((secs - secs.rounded(.down)) * 1_000_000))
            setsockopt(machine, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        if let headWithin { receiveTimeout(headWithin) }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                if !writeAll(machine, Data(buf[0..<n])) { break }
            }
            shutdown(machine, SHUT_WR)
            done.signal()
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        var head = Data()
        var remaining: Int?      // body bytes still to forward, once known
        var streaming = false    // no Content-Length: to EOF
        loop: while true {
            let n = read(machine, &buf, buf.count)
            if n <= 0 { break }
            var chunk = Data(buf[0..<n])
            if remaining == nil && !streaming {
                head.append(chunk)
                guard let sep = head.range(of: Data("\r\n\r\n".utf8)) else {
                    if head.count > 1 << 20 {
                        streaming = true
                        if headWithin != nil { receiveTimeout(0) }
                        if !writeAll(client, head) { break loop }
                    }
                    continue
                }
                let header = String(decoding: head[..<sep.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").lazy.compactMap { line -> Int? in
                    let kv = line.split(separator: ":", maxSplits: 1)
                    guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                    else { return nil }
                    return Int(kv[1].trimmingCharacters(in: .whitespaces))
                }.first
                let body = head.count - sep.upperBound
                if let length { remaining = length - body } else { streaming = true }
                if headWithin != nil { receiveTimeout(0) }
                chunk = head
                head = Data()
            } else if let r = remaining {
                remaining = r - chunk.count
            }
            if let r = remaining, r < 0 { chunk = chunk.dropLast(-r); remaining = 0 }
            if !writeAll(client, chunk) { break }
            if remaining == 0 { break }
        }
        // Done (or gone): wake the other direction's read.
        shutdown(client, SHUT_RDWR)
        shutdown(machine, SHUT_RDWR)
        done.wait()
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

    /// The machine stopped answering: keep what it last said (its sessions
    /// stay listed), marked off — /state then shows no VM entry for it.
    func markDisconnected(_ id: UUID) {
        cond.lock()
        fragments[id]?.connected = false
        cond.unlock()
        ACAutomationServer.noteMutation()
    }

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
    /// The Mac's home folder, as it reports it (an absolute path, else nil).
    private(set) var home: String?
    private(set) var connected = false
    /// Failed polls in a row. One slow reply (a request waits for a free link
    /// over the relay) isn't the machine going away: it used to drop the
    /// machine and every session of it from /state for a second, and a fat
    /// client watching one of them lost its stage (another session, or the
    /// bare terminal underneath).
    private var failedPolls = 0
    private static let failuresBeforeOffline = 3
    /// The machine's workspace entry from its last /state (the profile a
    /// local window builds for it).
    private(set) var workspace: [String: Any] = [:]
    /// Something shown changed (connection, roster, sessions): the app
    /// refreshes its sidebar.
    var onChange: (() -> Void)?
    /// Session ids that belong to someone else (this host's own, other
    /// machines'): a machine listing one is lying — it would have that
    /// session's commands routed to it — and the entry is dropped.
    var foreignSessionIDs: () -> Set<UUID> = { [] }
    /// The room this host put a session of the machine in (rooms are the
    /// host's; what the machine says is ignored).
    var roomOf: (UUID) -> UUID? = { _ in nil }
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
            failedPolls += 1
            if connected, failedPolls >= Self.failuresBeforeOffline {
                // Gone for real: off, but its sessions stay listed (asleep)
                // rather than vanishing from every client's stage.
                connected = false
                tabsModel.rosterLive = false
                MachineLinkHub.shared.markDisconnected(id)
                onChange?()
            }
            return
        }
        failedPolls = 0
        let wasConnected = connected
        let before = sessionStore.sessions
        connected = true
        name = MachineLinkHub.shared.name(id) ?? name
        // What the machine says of itself is pinned to what it is: its own id
        // everywhere, a native machine (the unsandboxed cues key off
        // hostKind), and only sessions nobody else owns.
        var ws = (r.json["workspaces"] as? [[String: Any]])?.first ?? [:]
        var vm = (r.json["vms"] as? [[String: Any]])?.first ?? [:]
        ws["id"] = id.uuidString; ws["hostKind"] = "agent-host"
        vm["id"] = id.uuidString; vm["hostKind"] = "agent-host"
        let sessions = Self.ownSessions((r.json["agentSessions"] as? [[String: Any]]) ?? [],
                                        machine: id, foreign: foreignSessionIDs(), roomOf: roomOf)
        var map: [Int: AgentStatus] = [:]
        for t in (vm["tabs"] as? [[String: Any]]) ?? [] {
            if let i = t["index"] as? Int, let s = (t["agentStatus"] as? String).flatMap(AgentStatus.init(rawValue:)) {
                map[i] = s
            }
        }
        tabs = map
        workspace = ws
        if let h = vm["home"] as? String, h.hasPrefix("/"), !h.contains("\n") { home = h }
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

    /// The sessions a machine lists, as this host takes them: each one its
    /// own (its profileID forced to the machine), none that someone else
    /// already owns.
    nonisolated static func ownSessions(_ listed: [[String: Any]], machine: UUID, foreign: Set<UUID>,
                                        roomOf: (UUID) -> UUID? = { _ in nil }) -> [[String: Any]] {
        var seen = Set<UUID>()
        return listed.compactMap { d in
            guard let sid = (d["id"] as? String).flatMap(UUID.init(uuidString:)),
                  !foreign.contains(sid), seen.insert(sid).inserted else { return nil }
            var d = d
            d["id"] = sid.uuidString
            d["profileID"] = machine.uuidString
            // Rooms are this host's; a machine can't seat itself in one. Nor
            // run a room's Switchboard.
            d["roomID"] = roomOf(sid)?.uuidString
            if d["role"] as? String == AgentSession.switchboardRole { d["role"] = nil }
            return d
        }
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
    var hostHome: String? { home }

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
