import Foundation
import Virtualization

// MARK: - Vsock bridge

/// Host-side vsock listener for the plan stream (port 5832) —
/// TaskMCPVsockBridge's structure, but event-push instead of RPC: the guest
/// driver dials in, announces its worktree branch with a hello event, then
/// streams NDJSON events; commands travel back on the same socket.
@MainActor
final class PlanEventBridge: NSObject {
    /// Must match the guest driver and SessionDisk.planStreamVsockPort —
    /// defined locally so this file doesn't depend on that constant's
    /// landing order.
    static let vsockPort: UInt32 = 5832

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: PlanEventListenerDelegate?
    /// Every live connection (bound or not), keyed by identity.
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// branch → the connection whose hello claimed it. A fresh hello for
    /// the same branch replaces the old connection — the driver reconnects
    /// after a socket drop and replays nothing, so the newest socket wins.
    private var bound: [String: Connection] = [:]

    /// Invoked on the main actor for every decoded event on a bound
    /// connection; the binding hello itself is forwarded too. Events that
    /// arrive before a hello have no branch to attribute them to and are
    /// dropped, as are events after a terminal result/fatal.
    var onEvent: ((_ branch: String, _ event: PlanEvent) -> Void)?

    /// A BOUND connection's socket closed without a terminal event — the
    /// driver died or the VM went away mid-session. The driver reconnects
    /// with a fresh hello within seconds when it's alive, so the consumer
    /// should apply a grace period before declaring the session dead
    /// (check `isBound` again after it).
    var onConnectionLost: ((_ branch: String) -> Void)?

    /// A live connection currently claims this branch.
    func isBound(branch: String) -> Bool { bound[branch] != nil }

    init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()
        let delegate = PlanEventListenerDelegate { [weak self] conn in self?.adopt(conn) }
        listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    /// Write a command to the connection bound to `branch`; false when no
    /// live session claims that branch (the protocol only allows commands
    /// between hello and result/fatal).
    func send(branch: String, _ cmd: PlanCommand) -> Bool {
        guard let c = bound[branch] else { return false }
        return c.write(cmd.jsonLine())
    }

    func stop() {
        socketDevice?.removeSocketListener(forPort: Self.vsockPort)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        bound.removeAll()
    }

    private func adopt(_ conn: VZVirtioSocketConnection) {
        let c = Connection(conn: conn,
                           onEvent: { [weak self] c, event in self?.handle(c, event) },
                           onClose: { [weak self] c in self?.closed(c) })
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    private func handle(_ c: Connection, _ event: PlanEvent) {
        if case .hello(let branch, _) = event {
            // A hello with no branch has nothing to bind to — tolerate it
            // by dropping, per the protocol's ignore-what-you-don't-know
            // rule, rather than poisoning the table with an empty key.
            guard !branch.isEmpty else { return }
            if let old = bound[branch], old !== c { old.cancel() }
            bound[branch] = c
            c.branch = branch
            onEvent?(branch, event)
            return
        }
        guard let branch = c.branch else { return }   // pre-hello chatter
        onEvent?(branch, event)
        // Terminal events end the session even before the socket closes:
        // unbinding here makes send() refuse further commands and drops any
        // trailing events, exactly as the protocol requires.
        switch event {
        case .result, .fatal: unbind(c)
        default: break
        }
    }

    private func unbind(_ c: Connection) {
        // Identity check: a stale connection closing must not evict the
        // fresh connection that replaced it for the same branch.
        if let branch = c.branch, bound[branch] === c {
            bound.removeValue(forKey: branch)
        }
        c.branch = nil
    }

    private func closed(_ c: Connection) {
        // A bound connection dying WITHOUT a terminal event is the "driver
        // crashed / VM died" signal — terminal events already unbound it in
        // handle(), and a stale replaced connection fails the identity check.
        let lostBranch: String? = {
            guard let b = c.branch, bound[b] === c else { return nil }
            return b
        }()
        unbind(c)
        connections.removeValue(forKey: ObjectIdentifier(c))
        if let b = lostBranch { onConnectionLost?(b) }
    }

    private final class Connection {
        private let conn: VZVirtioSocketConnection
        private let fd: Int32
        private let onEvent: (Connection, PlanEvent) -> Void
        private let onClose: (Connection) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = Data()
        /// The worktree branch this connection's hello claimed; nil until
        /// the hello arrives, and cleared again on a terminal event or when
        /// a reconnect replaces this connection.
        var branch: String?

        init(conn: VZVirtioSocketConnection,
             onEvent: @escaping (Connection, PlanEvent) -> Void,
             onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.fd = conn.fileDescriptor
            self.onEvent = onEvent
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
            if pending.count > 4 * 1024 * 1024 { cancel(); return }   // pathological
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = Data(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty,
                      let event = PlanEvent.parse(line: lineData) else { continue }
                onEvent(self, event)
            }
        }

        /// Write one already-framed NDJSON line; true when fully written.
        func write(_ data: Data) -> Bool {
            guard fd >= 0 else { return false }
            var ok = true
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { ok = false; return }
                var off = 0, rem = raw.count
                while rem > 0 {
                    let w = Darwin.write(fd, base.advanced(by: off), rem)
                    if w <= 0 { ok = false; break }
                    off += w; rem -= w
                }
            }
            return ok
        }
    }
}

private final class PlanEventListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
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
