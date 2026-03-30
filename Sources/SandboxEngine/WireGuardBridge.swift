import Foundation
import Virtualization

/// Controls a WireGuard VPN tunnel inside the guest VM via vsock.
///
/// Protocol: newline-delimited JSON on vsock port 5701.
///
/// The guest-side ``wireguard-agent.py`` connects to this listener and
/// responds to ``status``, ``enable``, and ``disable`` commands.
/// The state enum is shared with ``WarpBridge`` — the same connected/
/// disconnected/error model applies to WireGuard sessions.
@MainActor
public final class WireGuardBridge: NSObject, @unchecked Sendable {
    private static let port: UInt32 = 5701

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: WireGuardListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private var pendingData = Data()
    private var connectionGeneration: UInt64 = 0

    /// Whether the guest WireGuard agent is connected over vsock.
    public var isAgentConnected: Bool { connection != nil }

    /// Current VPN state — observe this from the UI layer.
    public private(set) var state: WarpState = .unknown {
        didSet {
            if state != oldValue { onStateChanged?(state) }
        }
    }

    /// Called whenever ``state`` changes.
    public var onStateChanged: ((WarpState) -> Void)?

    /// Whether an enable/disable operation is in flight.
    public private(set) var busy = false

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        let delegate = WireGuardListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.port)
        connection = nil
    }

    // MARK: - Public API

    /// Ask the guest agent for the current WireGuard status.
    public func requestStatus() {
        sendCommand(["type": "status"])
    }

    /// Tell the guest agent to bring up the WireGuard tunnel.
    public func enable() {
        guard !busy else { return }
        busy = true
        state = .connecting
        sendCommand(["type": "enable"])
    }

    /// Tell the guest agent to tear down the WireGuard tunnel.
    public func disable() {
        guard !busy else { return }
        busy = true
        sendCommand(["type": "disable"])
    }

    /// Toggle the tunnel based on current state.
    public func toggle() {
        switch state {
        case .connected:
            disable()
        case .disconnected, .error:
            enable()
        case .connecting:
            break
        default:
            requestStatus()
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        let setup = { @MainActor @Sendable [weak self] in
            guard let self else { return }

            print("[WireGuardBridge] guest connected (fd=\(conn.fileDescriptor))")

            self.readSource?.cancel()
            self.connectionGeneration &+= 1
            let gen = self.connectionGeneration
            self.connection = conn
            self.pendingData = Data()

            let fd = conn.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)

            source.setEventHandler { [weak self] in
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(fd, &buf, buf.count)
                guard n > 0 else {
                    print("[WireGuardBridge] connection closed (read returned \(n))")
                    source.cancel()
                    return
                }
                self?.pendingData.append(contentsOf: buf[0..<n])
                self?.drainMessages()
            }

            source.setCancelHandler { [weak self] in
                guard let self, self.connectionGeneration == gen else { return }
                print("[WireGuardBridge] dispatch source cancelled")
                self.readSource = nil
                self.connection = nil
            }

            source.resume()
            self.readSource = source

            self.requestStatus()
        }

        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.async(execute: setup)
        }
    }

    // MARK: - Message handling

    private func drainMessages() {
        while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingData[pendingData.startIndex..<newlineIndex]
            pendingData = Data(pendingData[(newlineIndex + 1)...])

            if pendingData.count > 1_048_576 {
                print("[WireGuardBridge] buffer overflow, disconnecting")
                readSource?.cancel()
                return
            }

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            handleResponse(type: type, json: json)
        }
    }

    private func handleResponse(type: String, json: [String: Any]) {
        switch type {
        case "status":
            if let stateStr = json["state"] as? String {
                state = parseState(stateStr, error: json["error"] as? String)
            }

        case "enable":
            busy = false
            if let ok = json["ok"] as? Bool, ok {
                state = .connected
            } else {
                let msg = json["error"] as? String ?? "enable failed"
                state = .error(msg)
            }

        case "disable":
            busy = false
            if let ok = json["ok"] as? Bool, ok {
                state = .disconnected
            } else {
                let msg = json["error"] as? String ?? "disable failed"
                state = .error(msg)
            }

        case "error":
            busy = false
            let msg = json["error"] as? String ?? "unknown error"
            state = .error(msg)

        default:
            break
        }
    }

    private func parseState(_ str: String, error: String?) -> WarpState {
        switch str {
        case "connected": return .connected
        case "connecting": return .connecting
        case "disconnected": return .disconnected
        case "not_installed": return .notInstalled
        case "error": return .error(error ?? "unknown error")
        default: return .unknown
        }
    }

    // MARK: - Sending

    private func sendCommand(_ json: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: json),
              var line = String(data: data, encoding: .utf8)
        else {
            print("[WireGuardBridge] sendCommand: no connection or serialization failed")
            return
        }
        line += "\n"
        line.withCString { ptr in
            var offset = 0
            let len = Int(strlen(ptr))
            while offset < len {
                let written = Darwin.write(conn.fileDescriptor, ptr + offset, len - offset)
                if written <= 0 {
                    print("[WireGuardBridge] write error at \(offset)/\(len)")
                    break
                }
                offset += written
            }
        }
    }
}

// MARK: - Listener delegate

private final class WireGuardListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
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
