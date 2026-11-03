import Foundation

// The fat-client side of the workspace browser MCP (vsock 5830): one
// `browser-mcp` SSH channel shared by every agent of a workspace. Apart from
// the VZ listener in BrowserMCPVsockBridge, so a server without
// Virtualization (bromure-ac on Linux) relays its agents the same way.

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
final class RelayMux {
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
        // Strong on purpose: the reader is what closes the fd once it has
        // left. The bridge lets go of a relay as it closes it (a client's new
        // dial, a detach, a drop) — held weakly, the mux was gone by then and
        // the fd stayed open for good: one socketpair end per browser-MCP
        // dial ("->(none)" unix sockets piling up on the server while a fat
        // client stayed connected).
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var pendingBytes = Data()
            while true {
                let n = LibC.read(fd, &buf, buf.count)
                if n <= 0 { break }
                // Pool per batch: a raw Thread never drains its implicit pool.
                threadAutoreleasepool {
                    pendingBytes.append(contentsOf: buf[0..<n])
                    while let nl = pendingBytes.firstIndex(of: 0x0A) {
                        let lineData = Data(pendingBytes[pendingBytes.startIndex..<nl])
                        pendingBytes = Data(pendingBytes[(nl + 1)...])
                        guard !lineData.isEmpty,
                              let line = String(data: lineData, encoding: .utf8) else { continue }
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.route(line) } }
                    }
                }
                if pendingBytes.count > 16 * 1024 * 1024 { break }   // pathological
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.readerExited() } }
        }
    }

    var agentCount: Int { agents.count }

    /// An agent's connection (`fd`, closed through `close`) joins the channel.
    func add(fd: Int32, close: @escaping () -> Void) {
        let agent = RelayedAgent(fd: fd, close: close, mux: self)
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
        LibC.shutdown(remoteFd, SHUT_RDWR)
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
                let w = LibC.write(remoteFd, base.advanced(by: off), rem)
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
        LibC.shutdown(remoteFd, SHUT_RDWR)
        onDrop()
    }

    private func readerExited() {
        remoteEnded()
        if !fdClosed { fdClosed = true; LibC.close(remoteFd) }
    }
}

/// One agent's stdio-shim connection while a fat client holds the browser:
/// lines in go to the mux, answers from the mux come back out.
@MainActor
private final class RelayedAgent {
    private let fd: Int32
    private let closeConnection: () -> Void
    private weak var mux: RelayMux?
    private var readSource: DispatchSourceRead?
    private var pending = Data()

    init(fd: Int32, close: @escaping () -> Void, mux: RelayMux) {
        self.fd = fd
        self.closeConnection = close
        self.mux = mux
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource = src
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            self.closeConnection()
            self.mux?.agentClosed(self)
        }
        src.activate()
    }

    func cancel() { readSource?.cancel(); readSource = nil }

    /// Reads while more is waiting, so an EOF that came in with the last
    /// line is seen now: Linux's libdispatch doesn't fire again for it, and
    /// the agent's fd would stay open until the relay dropped. The fd may
    /// be blocking (a VZ connection's is): `readableNow` asks first.
    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        repeat {
            let n = LibC.read(fd, &buf, buf.count)
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
        } while readSource != nil && Self.readableNow(fd)
    }

    /// Data or an EOF is waiting on `fd` (a zero-timeout poll).
    private static func readableNow(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 0) == 1
    }

    func write(_ s: String) {
        guard fd >= 0 else { return }
        var data = Data(s.utf8); data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0, rem = raw.count
            while rem > 0 {
                let w = LibC.write(fd, base.advanced(by: off), rem)
                if w <= 0 { break }
                off += w; rem -= w
            }
        }
    }
}
