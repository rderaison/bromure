import Foundation
import SandboxEngine
import Virtualization

private let lsDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil
@inline(__always) private func lsLog(_ msg: @autoclosure () -> String) {
    if lsDebug { print(msg()) }
}

/// Receives "open URL in another profile" requests from guest Chrome
/// extensions over vsock and notifies the host app delegate to show a
/// profile picker.
///
/// Protocol: newline-delimited JSON on vsock port 5300.
/// Expected message: `{"type":"open_in_profile","url":"https://..."}`
///
/// Connections are managed as a SET — multiple concurrent clients can
/// share the port (e.g. link-sender's persistent connectNative port +
/// corporate-guard's persistent connectNative port). An earlier version
/// tracked only the latest connection, which silently dropped traffic
/// from whichever peer lost the replacement race.
@MainActor
public final class LinkSenderBridge: NSObject, @unchecked Sendable {
    private static let linkPort: UInt32 = 5300

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: LinkListenerDelegate?

    private var nextClientID: UInt64 = 0
    private struct Client {
        let fd: Int32
        let source: DispatchSourceRead
        let conn: VZVirtioSocketConnection
    }
    private var clients: [UInt64: Client] = [:]

    /// Whether at least one guest client is currently connected.
    public var isConnected: Bool { !clients.isEmpty }

    /// Called when the guest requests opening a URL in another profile.
    public var onOpenInProfile: ((URL) -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        lsLog("[LinkSender] init: setting up vsock listener on port \(Self.linkPort)")

        let delegate = LinkListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.linkPort)
    }

    public func stop() {
        lsLog("[LinkSender] stop (\(clients.count) clients)")
        for (_, c) in clients { c.source.cancel() }
        clients.removeAll()
        socketDevice?.removeSocketListener(forPort: Self.linkPort)
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        nextClientID &+= 1
        let clientID = nextClientID
        let fd = conn.fileDescriptor
        lsLog("[LinkSender] guest connected (id=\(clientID), fd=\(fd), total=\(clients.count + 1))")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                lsLog("[LinkSender] client \(clientID) EOF/closed")
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            if pendingData.count > 1_048_576 {
                lsLog("[LinkSender] client \(clientID) buffer overflow, disconnecting")
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])
                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData), replyFD: fd)
                }
            }
        }

        source.setCancelHandler { [weak self] in
            lsLog("[LinkSender] client \(clientID) cancelled")
            self?.clients.removeValue(forKey: clientID)
        }

        clients[clientID] = Client(fd: fd, source: source, conn: conn)
        source.activate()
    }

    private func handleMessage(_ data: Data, replyFD: Int32) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "open_in_profile",
              let urlString = json["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https"
        else {
            lsLog("[LinkSender] ignoring invalid message")
            return
        }

        lsLog("[LinkSender] open_in_profile: \(urlString)")

        // Ack on the same connection the request came in on. Using a
        // generic "current connection" reference was the shape of the
        // earlier bug: with multiple clients, a reply could get routed
        // back to the wrong peer.
        let ack: [String: Any] = ["type": "open_in_profile_ack", "url": urlString]
        if let ackData = try? JSONSerialization.data(withJSONObject: ack),
           var line = String(data: ackData, encoding: .utf8) {
            line += "\n"
            _ = line.withCString { ptr in
                Darwin.write(replyFD, ptr, Int(strlen(ptr)))
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
        lsLog("[LinkSender] listener: accepting connection (fd=\(connection.fileDescriptor))")
        onConnection(connection)
        return true
    }
}
