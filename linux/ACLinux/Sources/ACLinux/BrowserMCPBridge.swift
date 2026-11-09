import Foundation

/// The workspace browser MCP on a Linux server (macOS: BrowserMCPVsockBridge).
/// The agents' stdio shim (bromure-browser-mcp.py) dials host vsock 5830,
/// which Firecracker's hybrid vsock delivers on `<v.sock>_5830`. The server
/// has no browser of its own: every agent rides the fat client's
/// `browser-mcp` channel through the shared RelayMux, and an agent that
/// arrives while no client holds the browser waits for one (its first
/// request stays in the socket until then).
// @port-skip linux-only: macOS listens on the VZ socket device and can serve agents from its own browser
@MainActor
final class BrowserMCPBridge {
    static let port = GuestPorts.browserMCPVsockPort
    /// Agents kept waiting for a client at most; past it the oldest goes.
    static let maxWaiting = 32

    let path: String
    private let listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    private var relay: RelayMux?
    private var waiting: [Int32] = []
    /// The workspace, whose quarantine drops every agent and refuses new ones.
    private let profileID: UUID?
    private var quarantineCut: UUID?

    /// Listens on `<udsPath>_5830`, or on `stored` (a restarted daemon's,
    /// from the fd store), and keeps the listener in the store as `fdStoreName`.
    // partial: listens on the hybrid vsock's <v.sock>_5830 (macOS: the VZ socket device); no browser of its own to serve from
    // @port BrowserMCPVsockBridge.init(socketDevice: VZVirtioSocketDevice, server: BrowserMCPServer, profileID: UUID?) h=74542c36cb76379d @b91fddfb
    init(udsPath: String, fdStoreName: String, stored: Int32? = nil, profileID: UUID? = nil) throws {
        path = HybridVsockListener.path(uds: udsPath, port: Self.port)
        self.profileID = profileID
        if let stored {
            listenFD = stored
        } else {
            listenFD = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [listenFD])
        }
        let flags = fcntl(listenFD, F_GETFL)
        _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.activate()
        if let profileID {
            quarantineCut = WorkspaceQuarantine.shared.onQuarantine(profileID) { [weak self] in
                Task { @MainActor in self?.dropAgents() }
            }
        }
    }

    /// A quarantine: the client's channel and every agent, waiting or
    /// relayed, go (a later agent is refused at accept while it lasts).
    // @port BrowserMCPVsockBridge.dropForQuarantine() h=edba3d8f6739f122 @b91fddfb
    func dropAgents() {
        relay?.close()
        relay = nil
        for w in waiting { Glibc.close(w) }
        waiting.removeAll()
    }

    /// Accepts until the backlog is empty (one event may stand for several).
    // @port-skip linux-only: Linux browser MCP bridge
    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            adopt(fd)
        }
    }

    // partial: an accepted hybrid-vsock fd; it waits for a client's channel (no local browser)
    // @port BrowserMCPVsockBridge.adopt(_: VZVirtioSocketConnection) h=514c51f6513bee17 @b91fddfb
    private func adopt(_ fd: Int32) {
        if let profileID, WorkspaceQuarantine.shared.contains(profileID) {
            Glibc.close(fd)
            return
        }
        if let relay, relay.isAlive {
            relay.add(fd: fd, close: { Glibc.close(fd) })
            FatClientLog.log("browser-mcp: agent joined the fat-client relay (\(relay.agentCount) on it)")
            return
        }
        relay = nil
        waiting.append(fd)
        if waiting.count > Self.maxWaiting { Glibc.close(waiting.removeFirst()) }
        FatClientLog.log("browser-mcp: agent waiting for a fat client (\(waiting.count) waiting)")
    }

    /// Tests: agents on the client's channel now.
    // @port-skip linux-only: test hook
    var relayedAgentCount: Int { relay?.agentCount ?? 0 }

    /// A fat client's `browser-mcp` channel (`fd`, now the bridge's): every
    /// agent, waiting or new, goes over it. A previous client's is closed.
    // partial: no local browser to take agents from
    // @port BrowserMCPVsockBridge.attachRemote(fd: Int32) h=473fcb3a6bcbb9d3 @b91fddfb
    func attachRemote(fd: Int32) {
        relay?.close()
        let mux = RelayMux(remoteFd: fd) { [weak self] in self?.relay = nil }
        relay = mux
        for w in waiting { mux.add(fd: w, close: { Glibc.close(w) }) }
        waiting.removeAll()
    }

    /// The VM is gone: no more agents, the client's channel and the waiting
    /// agents closed, the socket file removed.
    // @port BrowserMCPVsockBridge.stop() h=7a678819812bbec6 @b91fddfb
    func stop() {
        if let quarantineCut, let profileID { WorkspaceQuarantine.shared.remove(quarantineCut, for: profileID) }
        acceptSource?.cancel()
        acceptSource = nil
        Glibc.close(listenFD)
        relay?.close()
        relay = nil
        for w in waiting { Glibc.close(w) }
        waiting.removeAll()
        try? FileManager.default.removeItem(atPath: path)
    }
}
