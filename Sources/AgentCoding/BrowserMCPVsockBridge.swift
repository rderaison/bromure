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
    }

    private func adopt(_ conn: VZVirtioSocketConnection) {
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
                    Task { [weak self] in
                        guard let self else { return }
                        if let resp = await self.server.handle(line: line) {
                            self.writeLine(resp)
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
