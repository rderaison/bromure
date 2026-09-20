import Foundation
@preconcurrency import Virtualization

// Host-side vsock listener on the workspace VM's socket device (port 5830).
// The in-VM agents' browser MCP config launches a stdio shim
// (bromure-browser-mcp.py) that connects here; this bridge reads line-
// delimited JSON-RPC requests and answers them via BrowserMCPServer, which
// drives the workspace's embedded browser. Multiple concurrent agent
// connections are supported (each MCP client launch is one connection).

@MainActor
final class BrowserMCPVsockBridge: NSObject {
    static let vsockPort = SessionDisk.browserMCPVsockPort

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: MCPListenerDelegate?
    private let server: BrowserMCPServer
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// When a fat client has a `browser-mcp` channel open for this workspace,
    /// the agents' MCP streams go over that channel (the SSH channel's fd)
    /// instead of A's local `server` — so the fat client's own
    /// BrowserMCPServer drives its local browser. One channel, every agent
    /// of the workspace: `RelayMux` interleaves them by rewriting ids.
    private var relay: RelayMux?

    init(socketDevice: VZVirtioSocketDevice, server: BrowserMCPServer) {
        self.socketDevice = socketDevice
        self.server = server
        super.init()
        let delegate = MCPListenerDelegate { [weak self] conn in self?.adopt(conn) }
        listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    func stop() {
        socketDevice?.removeSocketListener(forPort: Self.vsockPort)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        // Close the fat-client relay + its agents. Without this a rebooted
        // workspace's OLD bridge keeps the socketpair to the client's
        // `browser-mcp` SSH channel open, so the client's relay never sees a
        // drop, never redials, and stays bound to this dead bridge — the NEW
        // bridge gets no relay and the agent is served on the (headless)
        // server instead, hanging its browser tools.
        detachRemote()
    }

    /// Route agent MCP connections to a fat client's `browser-mcp` channel (`fd`)
    /// instead of A's local browser. Existing local connections are dropped so
    /// the guest shim reconnects and joins the relay.
    func attachRemote(fd: Int32) {
        relay?.close()
        relay = RelayMux(remoteFd: fd) { [weak self] in
            // The client hung up: agents drop with it (their shims reconnect
            // and get served locally, or join the client's next dial).
            self?.relay = nil
        }
        // Redirect existing agent connections to the fat client by dropping them
        // so the guest shim reconnects and gets spliced (see `adopt`) — but only
        // when the CLIENT's console was used last (ConsolePresence): a relay
        // dialed by a background snapshot tick must not steal the browser from
        // a user actively working at the server. And NEVER tear one down
        // mid-handshake — the shim won't re-send initialize/tools_list, so the
        // agent's browser tools would hang "connecting". A handshake-complete
        // connection is dropped now (harmless — tools are already surfaced);
        // one still handshaking self-cancels the instant it finishes.
        // Cancelled connections remove themselves via onClose.
        guard ConsolePresence.shared.remotePreferred else { return }
        for c in Array(connections.values) {
            if c.handshakeDone { c.cancel() }
            else { c.redirectWhenReady = true }
        }
    }

    /// Stop relaying to the fat client; new agent connections go local again.
    func detachRemote() {
        relay?.close()
        relay = nil
    }

    /// The user changed seats (ConsolePresence flip): drop every routed
    /// stream so the guest shims reconnect and re-arbitrate — the browser
    /// follows the console that was used last, live.
    func rerouteForConsoleFlip() {
        for c in Array(connections.values) {
            if c.handshakeDone { c.cancel() }
            else { c.redirectWhenReady = true }
        }
        relay?.dropAgents()
    }

    private func adopt(_ conn: VZVirtioSocketConnection) {
        if let relay, ConsolePresence.shared.remotePreferred {
            if relay.isAlive {
                // Every agent of the workspace rides the one channel — the
                // second agent used to be closed on arrival here, which its
                // shim surfaced as "host channel unavailable".
                relay.add(conn)
                FatClientLog.log("browser-mcp: agent joined the fat-client relay (\(relay.agentCount) on it)")
                return
            }
            // The client hung up and the drop hasn't been processed yet:
            // serve this agent locally again.
            detachRemote()
        } else if relay != nil {
            FatClientLog.log("browser-mcp: agent served locally — the server's console was used last")
        }
        let c = Connection(conn: conn, server: server) { [weak self] c in
            self?.connections.removeValue(forKey: ObjectIdentifier(c))
        }
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    /// One agent's stdio-shim connection: line-delimited JSON-RPC in, responses
    /// out. Requests are served serially per connection (an MCP client issues
    /// one request at a time), so responses stay ordered.
    private final class Connection {
        private let conn: VZVirtioSocketConnection
        private let fd: Int32
        private let server: BrowserMCPServer
        private let onClose: (Connection) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = Data()
        /// True once this connection has answered `tools/list` — i.e. the agent's
        /// MCP client has finished its `initialize`/`tools/list` handshake and the
        /// browser tools have surfaced. Only then is it safe to tear the
        /// connection down to redirect it to a fat client (the dumb stdio shim
        /// never re-handshakes, so a mid-handshake redirect wedges the tools).
        private(set) var handshakeDone = false
        /// Set by `attachRemote` when a fat client wants this (still-handshaking)
        /// connection redirected — it self-cancels the moment the handshake ends.
        var redirectWhenReady = false

        init(conn: VZVirtioSocketConnection, server: BrowserMCPServer,
             onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.fd = conn.fileDescriptor
            self.server = server
            self.onClose = onClose
        }

        func start() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            readSource = src
            src.setEventHandler { [weak self] in self?.readAvailable() }
            src.setCancelHandler { [weak self] in
                guard let self else { return }
                self.conn.close()
                self.onClose(self)
            }
            src.activate()
        }

        func cancel() { readSource?.cancel(); readSource = nil }

        private func readAvailable() {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { cancel(); return }
            pending.append(contentsOf: buf[0..<n])
            if pending.count > 16 * 1024 * 1024 { cancel(); return }   // pathological
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty,
                      let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                MainActor.assumeIsolated {
                    _ = Task { [weak self] in
                        guard let self else { return }
                        if let resp = await self.server.handle(line: line) {
                            self.writeLine(resp)
                        }
                        // Handshake completes once tools/list is answered; a
                        // deferred fat-client redirect fires now (the agent
                        // already holds its tools, so the reconnect+splice to
                        // the fat client only carries subsequent tool calls).
                        if !self.handshakeDone, line.contains("\"tools/list\"") {
                            self.handshakeDone = true
                            if self.redirectWhenReady { self.cancel() }
                        }
                    }
                }
            }
        }

        private func writeLine(_ s: String) {
            guard fd >= 0 else { return }
            var data = Data(s.utf8); data.append(0x0A)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0, rem = raw.count
                while rem > 0 {
                    let w = Darwin.write(fd, base.advanced(by: off), rem)
                    if w <= 0 { break }
                    off += w; rem -= w
                }
            }
        }
    }
}

// MARK: - Fat-client relay: one channel, many agents

/// One `browser-mcp` channel to the fat client, shared by every agent in the
/// workspace. A raw splice could carry one agent only — the second connection
/// was closed on arrival and its shim reported "host channel unavailable",
/// which on a machine with several sessions left every agent but the oldest
/// without a browser. This rewrites JSON-RPC ids so the agents' request
/// streams interleave on the channel and each response finds its way back
/// (the client answers strictly in order; notifications pass through, and
/// client-originated ones reach every agent). The fd is closed exactly once,
/// on the main actor, after the reader thread has left it.
/// The relay's id bookkeeping, on its own so it can be tested without
/// sockets: requests get channel-unique ids on the way out, answers get
/// their agent's own id back on the way in.
struct BrowserMCPRelayIDMap {
    private var nextID = 1
    private var pending: [Int: (agent: ObjectIdentifier, id: Any)] = [:]

    enum Inbound: Equatable {
        /// An answer, restored to the agent's id, for that agent.
        case reply(agent: ObjectIdentifier, line: String)
        /// No id: a notification, for every agent.
        case notification
        /// An answer nobody waits for (the agent left, or an unknown id).
        case stale
    }

    /// The line to put on the channel for `agent`'s `line`.
    mutating func outbound(_ line: String, from agent: ObjectIdentifier) -> String {
        guard let data = line.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let original = obj["id"] else { return line }
        let mid = nextID
        nextID += 1
        pending[mid] = (agent, original)
        obj["id"] = mid
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return line }
        return s
    }

    /// Where a line from the channel goes.
    mutating func inbound(_ line: String) -> Inbound {
        guard let data = line.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .stale }
        guard let idValue = obj["id"] else { return .notification }
        guard let mid = idValue as? Int, let p = pending.removeValue(forKey: mid) else { return .stale }
        obj["id"] = p.id
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return .stale }
        return .reply(agent: p.agent, line: s)
    }

    mutating func forget(agent: ObjectIdentifier) {
        pending = pending.filter { $0.value.agent != agent }
    }

    mutating func removeAll() { pending.removeAll() }

    var pendingCount: Int { pending.count }
}

@MainActor
private final class RelayMux {
    private let remoteFd: Int32
    private let writeLock = NSLock()
    private var ids = BrowserMCPRelayIDMap()
    private var agents: [ObjectIdentifier: RelayedAgent] = [:]
    private(set) var isAlive = true
    private var fdClosed = false
    private let onDrop: () -> Void

    init(remoteFd: Int32, onDrop: @escaping () -> Void) {
        self.remoteFd = remoteFd
        self.onDrop = onDrop
        let fd = remoteFd
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var pendingBytes = Data()
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                // Pool per batch: a raw Thread never drains its implicit pool.
                autoreleasepool {
                    pendingBytes.append(contentsOf: buf[0..<n])
                    while let nl = pendingBytes.firstIndex(of: 0x0A) {
                        let lineData = Data(pendingBytes[pendingBytes.startIndex..<nl])
                        pendingBytes = Data(pendingBytes[(nl + 1)...])
                        guard !lineData.isEmpty,
                              let line = String(data: lineData, encoding: .utf8) else { continue }
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.route(line) } }
                    }
                }
                if pendingBytes.count > 16 * 1024 * 1024 { break }   // pathological
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.readerExited() } }
        }
    }

    var agentCount: Int { agents.count }

    func add(_ conn: VZVirtioSocketConnection) {
        let agent = RelayedAgent(conn: conn, mux: self)
        agents[ObjectIdentifier(agent)] = agent
        agent.start()
    }

    /// Drop every agent (their shims reconnect and re-arbitrate); the channel stays.
    func dropAgents() {
        for a in agents.values { a.cancel() }
        agents.removeAll()
        ids.removeAll()
    }

    /// Tear the relay down: agents drop, the reader wakes on the shutdown
    /// and the fd is closed once it has left.
    func close() {
        guard isAlive else { return }
        isAlive = false
        dropAgents()
        Darwin.shutdown(remoteFd, SHUT_RDWR)
    }

    fileprivate func agentClosed(_ agent: RelayedAgent) {
        let key = ObjectIdentifier(agent)
        agents.removeValue(forKey: key)
        ids.forget(agent: key)
    }

    /// An agent's line, outbound: requests get a channel-unique id.
    fileprivate func send(from agent: RelayedAgent, line: String) {
        guard isAlive else { return }
        if !writeRemote(ids.outbound(line, from: ObjectIdentifier(agent))) { remoteEnded() }
    }

    private func writeRemote(_ line: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        var data = Data(line.utf8); data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0, rem = raw.count
            while rem > 0 {
                let w = Darwin.write(remoteFd, base.advanced(by: off), rem)
                if w <= 0 { return false }
                off += w; rem -= w
            }
            return true
        }
    }

    /// The client's line, inbound: back to the agent that asked.
    private func route(_ line: String) {
        guard isAlive else { return }
        switch ids.inbound(line) {
        case .reply(let agent, let restored): agents[agent]?.write(restored)
        case .notification: for a in agents.values { a.write(line) }
        case .stale: break
        }
    }

    /// The client hung up (EOF, or a failed write): agents drop, the owner
    /// forgets the relay, and its next dial starts fresh.
    private func remoteEnded() {
        guard isAlive else { return }
        isAlive = false
        dropAgents()
        Darwin.shutdown(remoteFd, SHUT_RDWR)
        onDrop()
    }

    private func readerExited() {
        remoteEnded()
        if !fdClosed { fdClosed = true; Darwin.close(remoteFd) }
    }
}

/// One agent's stdio-shim connection while a fat client holds the browser:
/// lines in go to the mux, answers from the mux come back out.
@MainActor
private final class RelayedAgent {
    private let conn: VZVirtioSocketConnection
    private let fd: Int32
    private weak var mux: RelayMux?
    private var readSource: DispatchSourceRead?
    private var pending = Data()

    init(conn: VZVirtioSocketConnection, mux: RelayMux) {
        self.conn = conn
        self.fd = conn.fileDescriptor
        self.mux = mux
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource = src
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            self.conn.close()
            self.mux?.agentClosed(self)
        }
        src.activate()
    }

    func cancel() { readSource?.cancel(); readSource = nil }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { cancel(); return }
        pending.append(contentsOf: buf[0..<n])
        if pending.count > 16 * 1024 * 1024 { cancel(); return }   // pathological
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            pending = Data(pending[(nl + 1)...])
            guard !lineData.isEmpty,
                  let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            mux?.send(from: self, line: line)
        }
    }

    func write(_ s: String) {
        guard fd >= 0 else { return }
        var data = Data(s.utf8); data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0, rem = raw.count
            while rem > 0 {
                let w = Darwin.write(fd, base.advanced(by: off), rem)
                if w <= 0 { break }
                off += w; rem -= w
            }
        }
    }
}

private final class MCPListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void
    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        DispatchQueue.main.async { self.onConnection(connection) }
        return true
    }
}
