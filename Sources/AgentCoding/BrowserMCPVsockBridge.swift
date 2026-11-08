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

    /// The workspace, whose quarantine drops every agent and refuses new ones.
    private let profileID: UUID?
    private var quarantineCut: UUID?

    init(socketDevice: VZVirtioSocketDevice, server: BrowserMCPServer, profileID: UUID? = nil) {
        self.socketDevice = socketDevice
        self.server = server
        self.profileID = profileID
        super.init()
        if let profileID {
            quarantineCut = WorkspaceQuarantine.shared.onQuarantine(profileID) { [weak self] in
                Task { @MainActor in self?.dropForQuarantine() }
            }
        }
        let delegate = MCPListenerDelegate { [weak self] conn in self?.adopt(conn) }
        listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    /// A quarantine: every agent connection and the fat-client relay go (a
    /// later agent is refused at adopt while it lasts).
    func dropForQuarantine() {
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        detachRemote()
    }

    func stop() {
        if let quarantineCut, let profileID { WorkspaceQuarantine.shared.remove(quarantineCut, for: profileID) }
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
        if let profileID, WorkspaceQuarantine.shared.contains(profileID) {
            conn.close()
            return
        }
        if let relay, ConsolePresence.shared.remotePreferred {
            if relay.isAlive {
                // Every agent of the workspace rides the one channel — the
                // second agent used to be closed on arrival here, which its
                // shim surfaced as "host channel unavailable".
                relay.add(fd: conn.fileDescriptor, close: { conn.close() })
                FatClientLog.log("browser-mcp: agent joined the fat-client relay (\(relay.agentCount) on it)")
                browserRouteLog("agent → fat-client relay (\(relay.agentCount) on it)")
                return
            }
            // The client hung up and the drop hasn't been processed yet:
            // serve this agent locally again.
            detachRemote()
        } else if relay != nil {
            FatClientLog.log("browser-mcp: agent served locally — the server's console was used last")
            browserRouteLog("agent → server browser (relay up, but the server's console was used last)")
        } else {
            browserRouteLog("agent → server browser (no fat-client relay attached)")
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
