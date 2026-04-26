import Foundation
import SandboxEngine
import Virtualization

private let cdpDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Manages a pool of vsock connections to the guest's CDP agent.
///
/// No TCP server — the AutomationServer on port 9222 handles all incoming
/// connections and calls ``dequeueConnection()`` to get a vsock tunnel when
/// it needs to proxy a CDP request to this session's Chromium.
///
/// Architecture:
///   1. Guest cdp-agent.py proactively opens vsock connections to port 5200.
///   2. This class accepts them via setSocketListener and queues them.
///   3. AutomationServer calls dequeueConnection() to pair a vsock with an
///      incoming HTTP/WebSocket request.
///   4. Guest detects data on the vsock, connects it to Chromium CDP, and
///      opens a replacement connection to keep the pool filled.
@MainActor
public final class CDPBridge: @unchecked Sendable {
    /// vsock port for CDP tunnel connections (guest → host).
    static let cdpVsockPort: UInt32 = 5200

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: CDPListenerDelegate?

    /// Pool of vsock connections from the guest, ready to be used.
    private var vsockPool: [VZVirtioSocketConnection] = []

    /// Whether enough vsock connections have arrived for CDP to be usable.
    /// We need at least 2: one for the /json/version probe during session
    /// creation, and one for the actual Puppeteer WebSocket connect.
    public private(set) var isReady = false

    /// Minimum pool size before signaling readiness.
    private static let minPoolSize = 2

    /// Called on the main queue when enough vsock connections have arrived.
    public var onReady: (() -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice

        let delegate = CDPListenerDelegate { [weak self] conn in
            self?.handleVsockConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.cdpVsockPort)

        print("[CDPBridge] vsock pool listening on port \(Self.cdpVsockPort)")
    }

    public func stop() {
        if cdpDebug { print("[CDPBridge] stopping") }
        socketDevice?.removeSocketListener(forPort: Self.cdpVsockPort)
        listenerDelegate = nil
        vsockPool.removeAll()
    }

    /// Take a vsock connection from the pool. Returns nil if none available.
    public func dequeueConnection() -> VZVirtioSocketConnection? {
        guard !vsockPool.isEmpty else { return nil }
        let conn = vsockPool.removeFirst()
        if cdpDebug { print("[CDPBridge] dequeued vsock (pool: \(vsockPool.count) remaining)") }
        return conn
    }

    /// Number of connections available in the pool.
    public var poolSize: Int { vsockPool.count }

    // MARK: - Private

    private func handleVsockConnection(_ conn: VZVirtioSocketConnection) {
        vsockPool.append(conn)
        if cdpDebug { print("[CDPBridge] guest vsock connected (fd=\(conn.fileDescriptor)), pool: \(vsockPool.count))") }

        if !isReady, vsockPool.count >= Self.minPoolSize {
            isReady = true
            onReady?()
        }
    }
}

// MARK: - vsock listener delegate

private final class CDPListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        onConnection(connection)
        return true
    }
}
