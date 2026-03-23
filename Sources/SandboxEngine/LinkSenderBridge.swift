import Foundation
import Virtualization

private let lsDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Receives "open URL in another profile" requests from the guest Chrome extension
/// over vsock and notifies the host app delegate to show a profile picker.
///
/// Protocol: newline-delimited JSON on vsock port 5300.
///
/// Expected message: `{"type":"open_in_profile","url":"https://..."}`
@MainActor
public final class LinkSenderBridge: NSObject, @unchecked Sendable {
    private static let linkPort: UInt32 = 5300

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: LinkListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    /// Called when the guest requests opening a URL in another profile.
    public var onOpenInProfile: ((URL) -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        if lsDebug { print("[LinkSender] init: setting up vsock listener on port \(Self.linkPort)") }

        let delegate = LinkListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.linkPort)
    }

    public func stop() {
        if lsDebug { print("[LinkSender] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.linkPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if lsDebug { print("[LinkSender] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if lsDebug { print("[LinkSender] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            // Cap buffer to prevent abuse
            if pendingData.count > 1_048_576 {
                if lsDebug { print("[LinkSender] buffer overflow, disconnecting") }
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
            if lsDebug { print("[LinkSender] dispatch source cancelled") }
            self?.readSource = nil
            self?.connection = nil
        }

        readSource = source
        source.activate()
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "open_in_profile",
              let urlString = json["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https"
        else {
            if lsDebug { print("[LinkSender] ignoring invalid message") }
            return
        }

        if lsDebug { print("[LinkSender] open_in_profile: \(urlString)") }

        // Send acknowledgement back to the guest
        let ack: [String: Any] = ["type": "open_in_profile_ack", "url": urlString]
        if let conn = connection,
           let ackData = try? JSONSerialization.data(withJSONObject: ack),
           var line = String(data: ackData, encoding: .utf8) {
            line += "\n"
            _ = line.withCString { ptr in
                Darwin.write(conn.fileDescriptor, ptr, Int(strlen(ptr)))
            }
        }

        onOpenInProfile?(url)
    }
}

// MARK: - Listener delegate

private final class LinkListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if lsDebug { print("[LinkSender] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
