import Foundation
import Glibc

/// The plan-stream listener on a Linux server (macOS: PlanEventBridge on the
/// VZ socket device): the guest's planning driver dials host vsock 5832,
/// which Firecracker's hybrid vsock delivers on `<v.sock>_5832`. It announces
/// its worktree branch with a hello event, then streams NDJSON events
/// (PlanEvent); commands (PlanCommand) travel back on the same socket. The
/// binding rules are PlanEventBridge's: a fresh hello for a branch replaces
/// its old connection, events before a hello or after a terminal event are
/// dropped, and a bound connection closing without one is reported lost.
// @port-skip linux-only: PlanEventBridge's listener and connections over hybrid vsock
@MainActor
final class PlanStreamListener {
    let path: String
    private let listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    /// Every live connection (bound or not), keyed by identity.
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// branch → the connection whose hello claimed it.
    private var bound: [String: Connection] = [:]
    /// What each branch this listener has seen delivered so far (its hello
    /// included), across reconnects: the per-branch caps and the count of
    /// distinct branches.
    private var usage: [String: (events: Int, bytes: Int)] = [:]
    /// Accept order, for evicting the oldest connection.
    private var accepted = 0
    /// Event bytes delivered over every branch.
    private var deliveredBytes = 0
    /// Read callbacks run so far over every connection, and the longest
    /// one: the tests' view of the read budget.
    private(set) var readTurns = 0
    private(set) var longestTurn: Duration = .zero

    /// The guest is untrusted: what one VM's driver end may hold of the
    /// daemon. Everything here runs on the main queue, so no single
    /// callback may run long, and nothing a guest sends grows without end.
    struct Limits {
        /// Open connections; past it the oldest unbound one goes (else the
        /// oldest bound one).
        var connections = 8
        /// Distinct branches a VM's boot may announce (each one a planning
        /// session in the hub); a hello for one more is refused.
        var branches = 32
        /// Events and event bytes delivered per branch; past either, its
        /// connection is closed and later hellos for it are refused.
        var eventsPerBranch = 10_000
        var bytesPerBranch = 8 << 20
        /// Event bytes delivered over every branch: past it, every event
        /// is refused the same way.
        var bytesTotal = 64 << 20
        /// One NDJSON line; a longer one closes the connection.
        var lineBytes = 1 << 20
        /// Bytes read per read callback; the rest waits for the next turn.
        var readBudget = 64 << 10
    }
    let limits: Limits

    /// Every decoded event on a bound connection, the binding hello included.
    var onEvent: ((_ branch: String, _ event: PlanEvent) -> Void)?
    /// A bound connection closed without a terminal event: the driver died or
    /// the VM went away mid-session (the consumer applies a grace period).
    var onConnectionLost: ((_ branch: String) -> Void)?

    /// Listens on `<udsPath>_5832`, or on `stored` (a restarted daemon's,
    /// from the fd store), and keeps the listener in the store as `fdStoreName`.
    // @port PlanEventBridge.init(socketDevice: VZVirtioSocketDevice) h=bc0cab646e552cd4 @7a5b82ab
    init(udsPath: String, fdStoreName: String, stored: Int32? = nil, limits: Limits = Limits()) throws {
        self.limits = limits
        path = HybridVsockListener.path(uds: udsPath, port: GuestPorts.planStreamVsockPort)
        if let stored {
            listenFD = stored
        } else {
            listenFD = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [listenFD])
        }
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.activate()
    }

    /// A live connection currently claims this branch.
    // @port PlanEventBridge.isBound(branch: String) h=a2c7f2254deb57f7 @7a5b82ab
    func isBound(branch: String) -> Bool { bound[branch] != nil }

    /// Write a command to the connection bound to `branch`; false when no
    /// live session claims that branch.
    // @port PlanEventBridge.send(branch: String, _: PlanCommand) h=a835128c52b5db5e @7a5b82ab
    func send(branch: String, _ cmd: PlanCommand) -> Bool {
        guard let c = bound[branch] else { return false }
        return c.write(cmd.jsonLine())
    }

    /// The VM is gone: the listener and every connection closed, the socket file removed.
    // @port PlanEventBridge.stop() h=08aec554b7e4500c @7a5b82ab
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        Glibc.close(listenFD)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        bound.removeAll()
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Accepts until the backlog is empty (one event may stand for several).
    // @port PlanEventBridge.adopt(_: VZVirtioSocketConnection) h=0b8a2afb0f5fe7df @7a5b82ab
    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if connections.count >= limits.connections { evictOne() }
            accepted += 1
            let c = Connection(fd: fd, order: accepted, lineBytes: limits.lineBytes, readBudget: limits.readBudget,
                               onEvent: { [weak self] c, event, size in self?.handle(c, event, size: size) },
                               onTurn: { [weak self] took in
                                   guard let self else { return }
                                   readTurns += 1
                                   longestTurn = max(longestTurn, took)
                               },
                               onClose: { [weak self] c in self?.closed(c) })
            connections[ObjectIdentifier(c)] = c
            c.start()
        }
    }

    /// Room for one more connection: the oldest unbound one closes, or the
    /// oldest bound one when every one is bound.
    // @port-skip linux-only: the Linux listener's connection cap (the guest is untrusted)
    private func evictOne() {
        let all = connections.values.sorted { $0.order < $1.order }
        (all.first { $0.branch == nil } ?? all.first)?.cancel()
    }

    /// Counts `size` bytes against `branch`; false once it is over a cap.
    // @port-skip linux-only: the Linux listener's per-branch caps
    private func charge(_ branch: String, size: Int) -> Bool {
        var u = usage[branch] ?? (0, 0)
        u.events += 1
        u.bytes += size
        usage[branch] = u
        deliveredBytes += size
        return u.events <= limits.eventsPerBranch && u.bytes <= limits.bytesPerBranch
            && deliveredBytes <= limits.bytesTotal
    }

    // @port PlanEventBridge.handle(_: Connection, _: PlanEvent) h=cda2e9ec879fb706 @7a5b82ab
    private func handle(_ c: Connection, _ event: PlanEvent, size: Int) {
        if case .hello(let branch, _) = event {
            // A hello with no branch has nothing to bind to: dropped.
            guard !branch.isEmpty else { return }
            // One branch too many for this VM, or one that spent its share:
            // refused, its connection closed.
            if usage[branch] == nil, usage.count >= limits.branches { c.cancel(); return }
            guard charge(branch, size: size) else { c.cancel(); return }
            if let old = bound[branch], old !== c { old.cancel() }
            bound[branch] = c
            c.branch = branch
            onEvent?(branch, event)
            return
        }
        guard let branch = c.branch else { return }   // pre-hello chatter
        // Over its share: closed before the event goes anywhere (the
        // consumer hears the connection lost).
        guard charge(branch, size: size) else { c.cancel(); return }
        onEvent?(branch, event)
        // Terminal events end the session even before the socket closes:
        // send() refuses further commands and trailing events are dropped.
        switch event {
        case .result, .fatal: unbind(c)
        default: break
        }
    }

    // @port PlanEventBridge.unbind(_: Connection) h=a7516d78701e16c5 @7a5b82ab
    private func unbind(_ c: Connection) {
        // A stale connection closing must not evict the fresh one that
        // replaced it for the same branch.
        if let branch = c.branch, bound[branch] === c {
            bound.removeValue(forKey: branch)
        }
        c.branch = nil
    }

    // @port PlanEventBridge.closed(_: Connection) h=998a316dd34d52aa @7a5b82ab
    private func closed(_ c: Connection) {
        let lostBranch: String? = {
            guard let b = c.branch, bound[b] === c else { return nil }
            return b
        }()
        unbind(c)
        connections.removeValue(forKey: ObjectIdentifier(c))
        if let b = lostBranch { onConnectionLost?(b) }
    }

    /// One driver's connection.
    @MainActor
    private final class Connection {
        private let fd: Int32
        let order: Int
        private let lineBytes: Int
        private let readBudget: Int
        private let onEvent: (Connection, PlanEvent, Int) -> Void
        private let onClose: (Connection) -> Void
        private let onTurn: (Duration) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = [UInt8]()
        /// Where the next newline search starts in `pending` (the bytes
        /// before it hold none).
        private var scanned = 0
        private var open = true
        /// A continuation is queued (the read budget ran out).
        private var resumeQueued = false
        /// The worktree branch this connection's hello claimed; nil until
        /// the hello, and again after a terminal event or a replacement.
        var branch: String?

        // @port PlanEventBridge.Connection.init(conn: VZVirtioSocketConnection, onEvent: @escaping(Connection,PlanEvent)->Void, onClose: @escaping(Connection)->Void) h=43af0ce4aa6fe33a @7a5b82ab
        init(fd: Int32, order: Int, lineBytes: Int, readBudget: Int,
             onEvent: @escaping (Connection, PlanEvent, Int) -> Void,
             onTurn: @escaping (Duration) -> Void = { _ in },
             onClose: @escaping (Connection) -> Void) {
            self.fd = fd
            self.order = order
            self.lineBytes = lineBytes
            self.readBudget = readBudget
            self.onEvent = onEvent
            self.onTurn = onTurn
            self.onClose = onClose
        }

        // @port PlanEventBridge.Connection.start() h=4450c673753a61b9 @7a5b82ab
        func start() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            readSource = src
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
            src.activate()
        }

        /// Closed now; reported to the listener once.
        // @port PlanEventBridge.Connection.cancel() h=11d33aff786ce484 @7a5b82ab
        func cancel() {
            readSource?.cancel()
            readSource = nil
            guard open else { return }
            open = false
            Glibc.close(fd)
            onClose(self)
        }

        /// Reads to EAGAIN (libdispatch on Linux doesn't fire again for an
        /// EOF that arrived with the data), at most `readBudget` bytes per
        /// turn of the main queue: past it, the rest is read on a later
        /// turn. Each whole line is decoded as it is found; the buffer is
        /// compacted once per turn. A line longer than `lineBytes` closes
        /// the connection.
        // @port PlanEventBridge.Connection.readAvailable() h=1d3d2e5b603e7f31 @7a5b82ab
        private func readAvailable() {
            guard open else { return }
            let start = ContinuousClock.now
            defer { onTurn(ContinuousClock.now - start) }
            var buf = [UInt8](repeating: 0, count: 65536)
            var eof = false, budget = readBudget, more = false
            while true {
                guard budget > 0 else { more = true; break }
                let n = Glibc.read(fd, &buf, min(buf.count, budget))
                if n > 0 {
                    pending.append(contentsOf: buf[0..<n])
                    budget -= n
                    guard drainLines() else { return }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { eof = true }
                break
            }
            if eof { cancel(); return }
            if more, !resumeQueued {
                resumeQueued = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.resumeQueued = false
                        self?.readAvailable()
                    }
                }
            }
        }

        /// Decodes every whole line in `pending` (a moving start, one
        /// compaction at the end); false when the connection closed.
        // @port-skip linux-only: readAvailable's line parser, bounded
        private func drainLines() -> Bool {
            var start = 0
            while let nl = pending[scanned...].firstIndex(of: 0x0A) {
                let size = nl - start
                if size > lineBytes { cancel(); return false }
                if size > 0, let event = PlanEvent.parse(line: Data(pending[start..<nl])) {
                    onEvent(self, event, size)
                    if !open { return false }
                }
                start = nl + 1
                scanned = start
            }
            if start > 0 { pending.removeFirst(start) }
            scanned = pending.count
            if pending.count > lineBytes { cancel(); return false }
            return true
        }

        /// Write one already-framed NDJSON line; true when fully written
        /// (the socket is non-blocking: a full buffer is waited out briefly).
        // @port PlanEventBridge.Connection.write(_: Data) h=e7c3404efb6592ef @7a5b82ab
        func write(_ data: Data) -> Bool {
            guard open else { return false }
            var ok = true
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { ok = false; return }
                var off = 0, rem = raw.count, waits = 0
                while rem > 0 {
                    let w = Glibc.send(fd, base.advanced(by: off), rem, Int32(MSG_NOSIGNAL))
                    if w > 0 { off += w; rem -= w; continue }
                    if w < 0, errno == EINTR { continue }
                    if w < 0, errno == EAGAIN || errno == EWOULDBLOCK, waits < 200 {
                        waits += 1
                        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 10)
                        continue
                    }
                    ok = false
                    break
                }
            }
            return ok
        }
    }
}
