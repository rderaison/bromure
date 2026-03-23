import Foundation
import Virtualization

private let shellDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Manages a pool of vsock connections to the guest's shell agent.
///
/// Provides remote command execution in the guest VM over vsock port 5800.
/// Uses length-prefixed JSON protocol:
///   Request:  [u32be len][{"cmd": "...", "timeout": 30}]
///   Response: [u32be len][{"stdout": "...", "stderr": "...", "exit_code": 0}]
///
/// Architecture (same guest-initiated pattern as CDPBridge):
///   1. Guest shell-agent.py proactively opens vsock connections to port 5800.
///   2. This class accepts them via setSocketListener and queues them.
///   3. AutomationServer calls dequeueConnection() to get a vsock for exec.
///   4. Guest receives command, runs it, returns result, opens a replacement.
@MainActor
public final class ShellBridge: @unchecked Sendable {
    /// vsock port for shell connections (guest → host).
    static let shellVsockPort: UInt32 = 5800

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: ShellListenerDelegate?
    private var vsockPool: [VZVirtioSocketConnection] = []

    public private(set) var isReady = false
    private static let minPoolSize = 1

    public var onReady: (() -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice

        let delegate = ShellListenerDelegate { [weak self] conn in
            self?.handleVsockConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.shellVsockPort)

        print("[ShellBridge] vsock pool listening on port \(Self.shellVsockPort)")
    }

    public func stop() {
        if shellDebug { print("[ShellBridge] stopping") }
        socketDevice?.removeSocketListener(forPort: Self.shellVsockPort)
        listenerDelegate = nil
        vsockPool.removeAll()
    }

    /// Take a vsock connection from the pool. Returns nil if none available.
    public func dequeueConnection() -> VZVirtioSocketConnection? {
        guard !vsockPool.isEmpty else { return nil }
        let conn = vsockPool.removeFirst()
        if shellDebug { print("[ShellBridge] dequeued vsock (pool: \(vsockPool.count) remaining)") }
        return conn
    }

    /// Number of connections available in the pool.
    public var poolSize: Int { vsockPool.count }

    // MARK: - Private

    private func handleVsockConnection(_ conn: VZVirtioSocketConnection) {
        vsockPool.append(conn)
        if shellDebug { print("[ShellBridge] guest vsock connected (fd=\(conn.fileDescriptor)), pool: \(vsockPool.count))") }

        if !isReady, vsockPool.count >= Self.minPoolSize {
            isReady = true
            onReady?()
        }
    }
}

// MARK: - vsock listener delegate

private final class ShellListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
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
