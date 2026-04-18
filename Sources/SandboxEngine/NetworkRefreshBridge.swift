import Foundation
import Virtualization

private let nrDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Tells the guest to re-acquire its network configuration when the host's
/// physical network changes (Wi-Fi roam, Ethernet plug/unplug, VPN toggle).
///
/// Only meaningful in bridged mode — in NAT mode, vmnet handles roaming
/// transparently and nothing needs to be done inside the guest.
///
/// Protocol: newline-delimited JSON on vsock port 5703.
///
/// The guest-side ``network-refresh-agent.py`` connects to this listener and
/// responds to ``refresh`` commands by bouncing eth0, renewing its DHCP lease,
/// flushing the neighbor cache, and rewriting /etc/resolv.conf.
@MainActor
public final class NetworkRefreshBridge: NSObject, @unchecked Sendable {
    private static let port: UInt32 = 5703

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: NetworkRefreshListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private var connectionGeneration: UInt64 = 0

    public var isAgentConnected: Bool { connection != nil }

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        if nrDebug { print("[NetworkRefresh] init: setting up vsock listener on port \(Self.port)") }

        let delegate = NetworkRefreshListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    public func stop() {
        if nrDebug { print("[NetworkRefresh] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.port)
        connection = nil
    }

    /// Ask the guest to refresh its network configuration. Fire-and-forget —
    /// if the agent isn't connected yet (early in boot), the call is dropped
    /// and the next change event will pick up the new state anyway.
    public func refresh() {
        sendCommand(["type": "refresh"])
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        let setup = { @MainActor @Sendable [weak self] in
            guard let self else { return }
            if nrDebug { print("[NetworkRefresh] guest connected (fd=\(conn.fileDescriptor))") }

            self.readSource?.cancel()
            self.connectionGeneration &+= 1
            let gen = self.connectionGeneration
            self.connection = conn

            let fd = conn.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)

            source.setEventHandler {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 {
                    if nrDebug { print("[NetworkRefresh] connection closed (read returned \(n))") }
                    source.cancel()
                }
                // Responses are best-effort log lines; we don't parse them.
            }

            source.setCancelHandler { [weak self] in
                guard let self, self.connectionGeneration == gen else { return }
                if nrDebug { print("[NetworkRefresh] dispatch source cancelled") }
                self.readSource = nil
                self.connection = nil
            }

            source.resume()
            self.readSource = source
        }

        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.async(execute: setup)
        }
    }

    // MARK: - Sending

    private func sendCommand(_ json: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: json),
              var line = String(data: data, encoding: .utf8)
        else {
            if nrDebug { print("[NetworkRefresh] sendCommand: no connection (dropping)") }
            return
        }
        line += "\n"
        line.withCString { ptr in
            var offset = 0
            let len = Int(strlen(ptr))
            while offset < len {
                let written = Darwin.write(conn.fileDescriptor, ptr + offset, len - offset)
                if written <= 0 {
                    if nrDebug { print("[NetworkRefresh] write error at \(offset)/\(len)") }
                    break
                }
                offset += written
            }
        }
    }
}

// MARK: - Listener delegate

private final class NetworkRefreshListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
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
