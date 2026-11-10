import Foundation

/// One of the agents' MCP sockets on a Linux server (macOS: TaskMCPVsockBridge
/// on the VZ socket device): the guest's shim dials host vsock `port`, which
/// Firecracker's hybrid vsock delivers on `<v.sock>_<port>`. Each connection
/// carries newline-delimited JSON-RPC to `server`; a `bromure-hello <branch>`
/// line binds it to a worktree branch (the board's tools act on that task).
// @port-skip linux-only: TaskMCPVsockBridge's listener and connections over hybrid vsock
@MainActor
final class MCPLineListener {
    let path: String
    private let listenFD: Int32
    private let server: any MCPLineHandler
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// Listens on `<udsPath>_<port>`, or on `stored` (a restarted daemon's,
    /// from the fd store), and keeps the listener in the store as `fdStoreName`.
    // @port TaskMCPVsockBridge.init(socketDevice: VZVirtioSocketDevice, profileID: UUID?, server: anyMCPLineHandler, port: UInt32) h=14a7715826e5a6d6 @b91fddfb
    // partial: no delegate object
    // @port TaskMCPListenerDelegate.init(onConnection: @escaping(VZVirtioSocketConnection)->Void) h=10107f1f71ecd03d @b91fddfb
    init(udsPath: String, port: UInt32, server: any MCPLineHandler, fdStoreName: String, stored: Int32? = nil) throws {
        path = HybridVsockListener.path(uds: udsPath, port: port)
        self.server = server
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

    /// Accepts until the backlog is empty (one event may stand for several).
    // @port TaskMCPVsockBridge.adopt(_: VZVirtioSocketConnection) h=86428e08f1a52362 @b91fddfb
    // @port TaskMCPListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=4f290f1ba299eb60 @b91fddfb
    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let c = Connection(fd: fd, server: server) { [weak self] c in
                self?.connections.removeValue(forKey: ObjectIdentifier(c))
            }
            connections[ObjectIdentifier(c)] = c
            c.start()
        }
    }

    /// The VM is gone: the listener and every connection closed, the socket file removed.
    // @port TaskMCPVsockBridge.stop() h=d2ac873b2ad50b13 @b91fddfb
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        Glibc.close(listenFD)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        try? FileManager.default.removeItem(atPath: path)
    }

    /// One shim's connection. An EOF stops the reading; the socket closes
    /// once the answers already asked for are written.
    @MainActor
    private final class Connection {
        private let fd: Int32
        private let server: any MCPLineHandler
        private let onClose: (Connection) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = Data()
        /// The worktree branch the shim announced.
        private var branch: String?
        private var open = true
        private var inFlight = 0

        // @port TaskMCPVsockBridge.Connection.init(conn: VZVirtioSocketConnection, server: anyMCPLineHandler, onClose: @escaping(Connection)->Void) h=dbdebfa4b52b53c6 @b91fddfb
        init(fd: Int32, server: any MCPLineHandler, onClose: @escaping (Connection) -> Void) {
            self.fd = fd
            self.server = server
            self.onClose = onClose
        }

        // @port TaskMCPVsockBridge.Connection.start() h=4450c673753a61b9 @b91fddfb
        func start() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            readSource = src
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
            src.activate()
        }

        /// Closed now (the listener stops, or the client is gone for good).
        // @port TaskMCPVsockBridge.Connection.cancel() h=11d33aff786ce484 @b91fddfb
        func cancel() {
            stopReading()
            finish()
        }

        // @port-skip linux-only: hybrid vsock MCP connection
        private func stopReading() {
            readSource?.cancel()
            readSource = nil
        }

        // @port-skip linux-only: hybrid vsock MCP connection
        private func finish() {
            guard open else { return }
            open = false
            Glibc.close(fd)
            onClose(self)
        }

        /// Reads to EAGAIN (libdispatch on Linux doesn't fire again for an
        /// EOF that arrived with the data), then answers each whole line.
        // partial: non-blocking fd, bounded
        // @port TaskMCPVsockBridge.Connection.readAvailable() h=26b4e12476cc107f @b91fddfb
        private func readAvailable() {
            var buf = [UInt8](repeating: 0, count: 65536)
            var eof = false
            while true {
                let n = Glibc.read(fd, &buf, buf.count)
                if n > 0 { pending.append(contentsOf: buf[0..<n]); continue }
                if n < 0, errno == EINTR { continue }
                if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { eof = true }
                break
            }
            if pending.count > 4 * 1024 * 1024 { cancel(); return }   // pathological
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty, let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                if line.hasPrefix("bromure-hello ") {
                    branch = String(line.dropFirst("bromure-hello ".count)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                let bound = branch
                inFlight += 1
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let resp = await self.server.handle(line: line, branch: bound), !self.writeLine(resp) {
                        self.server.responseNotWritten(to: line, branch: bound)
                    }
                    self.inFlight -= 1
                    if self.readSource == nil, self.inFlight == 0 { self.finish() }
                }
            }
            if eof {
                stopReading()
                if inFlight == 0 { finish() }
            }
        }

        /// Whether all of it was written (false: the connection is gone).
        // @port TaskMCPVsockBridge.Connection.writeLine(_: String) h=83a6dc6c0a3d2d99 @b91fddfb
        @discardableResult
        private func writeLine(_ s: String) -> Bool {
            guard open else { return false }
            var data = Data(s.utf8)
            data.append(0x0A)
            return data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var off = 0
                while off < raw.count {
                    let w = Glibc.write(fd, base.advanced(by: off), raw.count - off)
                    if w > 0 { off += w; continue }
                    if w < 0, errno == EINTR { continue }
                    if w < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        if poll(&p, 1, 5000) > 0 { continue }
                    }
                    return false
                }
                return true
            }
        }
    }
}
