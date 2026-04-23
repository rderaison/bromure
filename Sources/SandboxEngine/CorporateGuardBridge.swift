import Foundation
import Virtualization

private let cgDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Receives "open URL in a private Bromure profile" requests from the
/// guest corporate-guard Chrome extension over vsock.
///
/// Protocol: newline-delimited JSON on vsock port 5310.
///
/// Expected message: `{"type":"open_external","url":"https://..."}`
///
/// Mirrors `LinkSenderBridge` (port 5300) but semantically distinct —
/// the host picks an ephemeral profile itself rather than prompting
/// the user, because the extension's entire job is to route external
/// navigations out of the managed session without friction.
@MainActor
public final class CorporateGuardBridge: NSObject, @unchecked Sendable {
    private static let port: UInt32 = 5310

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: CorporateGuardListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    /// Whether the guest corporate-guard agent is connected.
    public var isConnected: Bool { connection != nil }

    /// Called when the guest requests opening a URL in a private profile.
    /// The host should route this to an ephemeral profile (navigate an
    /// existing session if one is open, else spawn a new one).
    public var onOpenExternal: ((URL) -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        if cgDebug {
            print("[CorporateGuard] init: setting up vsock listener on port \(Self.port)")
        }

        let delegate = CorporateGuardListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    public func stop() {
        if cgDebug { print("[CorporateGuard] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.port)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if cgDebug { print("[CorporateGuard] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if cgDebug { print("[CorporateGuard] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            if pendingData.count > 1_048_576 {
                if cgDebug { print("[CorporateGuard] buffer overflow, disconnecting") }
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])

                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            if cgDebug { print("[CorporateGuard] dispatch source cancelled") }
            self?.readSource = nil
            self?.connection = nil
        }

        readSource = source
        source.activate()
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "open_external",
              let urlString = json["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https"
        else {
            if cgDebug { print("[CorporateGuard] ignoring invalid message") }
            return
        }

        if cgDebug { print("[CorporateGuard] open_external: \(urlString)") }

        // Ack the guest so the extension knows the handoff succeeded.
        let ack: [String: Any] = ["type": "open_external_ack", "url": urlString]
        if let conn = connection,
           let ackData = try? JSONSerialization.data(withJSONObject: ack),
           var line = String(data: ackData, encoding: .utf8) {
            line += "\n"
            _ = line.withCString { ptr in
                Darwin.write(conn.fileDescriptor, ptr, Int(strlen(ptr)))
            }
        }

        onOpenExternal?(url)
    }
}

// MARK: - Listener delegate

private final class CorporateGuardListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if cgDebug { print("[CorporateGuard] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
