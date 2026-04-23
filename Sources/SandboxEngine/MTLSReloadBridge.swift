import Foundation
import Virtualization

private let mrDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Host→guest channel for live mTLS material rotation.
///
/// Unlike the other vsock bridges in this directory, this one is
/// push-only from the host: the guest dials in and waits on
/// newline-delimited JSON lines; the host writes an update whenever
/// `ManagedProfileSync` reissues a leaf cert.
///
/// Protocol (vsock port 5320):
///   host → guest  `{"type":"mtls_update","certPem":"...","keyPem":"...","caPem":"..."}\n`
///
/// The guest agent (`/usr/local/bin/mtls-reload-agent.py`) rewrites
/// `/tmp/bromure/mtls/{cert,key,ca}.pem` and re-runs
/// `/usr/local/bin/install-mtls.sh`, which reimports into Chromium's
/// NSS db. Open TLS connections keep using the old cert until they
/// close; new handshakes pick up the new material. Good enough —
/// renewal happens well before expiration.
@MainActor
public final class MTLSReloadBridge: NSObject, @unchecked Sendable {
    private static let port: UInt32 = 5320

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: MTLSReloadListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    public var isConnected: Bool { connection != nil }

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        if mrDebug {
            print("[MTLSReload] init: setting up vsock listener on port \(Self.port)")
        }

        let delegate = MTLSReloadListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    public func stop() {
        if mrDebug { print("[MTLSReload] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.port)
        connection = nil
    }

    /// Push new mTLS material to the guest. If the guest agent hasn't
    /// connected yet, we simply drop the update — the initial install
    /// already happened via config-agent, and the next renewal will
    /// (we hope) find a live connection.
    public func push(certPem: String, keyPem: String, caPem: String) {
        guard let conn = connection else {
            if mrDebug { print("[MTLSReload] push: no guest connection, dropping") }
            return
        }
        let payload: [String: Any] = [
            "type": "mtls_update",
            "certPem": certPem,
            "keyPem": keyPem,
            "caPem": caPem,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else {
            if mrDebug { print("[MTLSReload] push: serialize failed") }
            return
        }
        line += "\n"
        _ = line.withCString { ptr in
            Darwin.write(conn.fileDescriptor, ptr, Int(strlen(ptr)))
        }
        if mrDebug { print("[MTLSReload] push: sent \(line.count) bytes") }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if mrDebug { print("[MTLSReload] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        // Read-side is minimal — the guest may send acks, but we don't
        // gate anything on them. We still need a read source so the
        // kernel tells us when the socket closes.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                if mrDebug { print("[MTLSReload] connection closed") }
                source.cancel()
            }
            // drain & discard
        }
        source.setCancelHandler { [weak self] in
            self?.readSource = nil
            self?.connection = nil
        }
        readSource = source
        source.activate()
    }
}

// MARK: - Listener delegate

private final class MTLSReloadListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if mrDebug { print("[MTLSReload] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
