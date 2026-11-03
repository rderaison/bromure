import Foundation
import Virtualization

/// Host side of the Codex / ChatGPT subscription-token swap channel.
/// Twin of `SubscriptionTokenBridge` (Anthropic) but listens on vsock
/// 8447 and carries Codex's three-token shape (`access`, `refresh`,
/// `id_token`).
///
/// Same security invariant: real values flow VM → host (one-way for
/// reads); only fake values flow host → VM (one-way for writes). No
/// "give me the real token" RPC exists.
@MainActor
public final class CodexTokenBridge: NSObject, @unchecked Sendable {
    public static let port: UInt32 = 8447

    public struct Tokens: Sendable {
        public let access: String
        public let refresh: String
        public let idToken: String
    }

    public enum BridgeError: Swift.Error, LocalizedError {
        case notConnected
        case agentRejected(String)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Codex token agent isn't connected yet"
            case .agentRejected(let r): return "VM agent refused the request: \(r)"
            case .malformedResponse: return "VM agent returned a malformed response"
            }
        }
    }

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: ListenerDelegate?
    /// The line channel to the agent (TokenAgentChannel.swift).
    private let channel = TokenAgentChannel(disconnectedError: BridgeError.notConnected)
    public var isConnected: Bool { channel.isConnected }

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()
        let delegate = ListenerDelegate { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        self.listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    public func stop() {
        socketDevice?.removeSocketListener(forPort: Self.port)
        channel.stop()
    }

    public func read() async throws -> Tokens? {
        let response = try await rpc(["op": "read"])
        guard let ok = response["ok"] as? Bool, ok else {
            throw BridgeError.agentRejected(
                (response["reason"] as? String) ?? "unknown reason")
        }
        if let access = response["access"] as? String,
           let refresh = response["refresh"] as? String,
           let idToken = response["id_token"] as? String {
            return Tokens(access: access, refresh: refresh, idToken: idToken)
        }
        return nil
    }

    public func write(access: String, refresh: String, idToken: String) async throws {
        let response = try await rpc([
            "op": "write",
            "access": access,
            "refresh": refresh,
            "id_token": idToken,
        ])
        guard let ok = response["ok"] as? Bool, ok else {
            throw BridgeError.agentRejected(
                (response["reason"] as? String) ?? "unknown reason")
        }
    }

    // MARK: - Wire

    private func rpc(_ payload: [String: Any]) async throws -> [String: Any] {
        try await channel.rpc(payload)
    }

    private func accept(_ conn: VZVirtioSocketConnection) {
        channel.accept(fd: conn.fileDescriptor, owner: conn)
    }
}

private final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void
    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        onConnection(connection)
        return true
    }
}
