import Foundation
import Virtualization

/// Host side of the Claude subscription-token swap channel. Listens on
/// vsock port 8446 for the in-VM `claude-token-agent.py`, then exposes
/// two async RPCs:
///
///   `read()`   → pulls the current `accessToken` + `refreshToken` from
///                ~/.claude/.credentials.json. Used once on first
///                consent, and (in the response-rotation rewriter) is
///                NOT used during refreshes — those go through the
///                proxy directly. Returns nil if the file is missing.
///   `write(access:refresh:)` → overwrites both tokens with fakes. The
///                agent enforces the brm- prefix shape, so a buggy host
///                can't pollute the file even if we screw up here.
///
/// **Security invariant:** the host NEVER sends real cleartext token
/// values to the VM. Only fakes flow host→VM. Only reals flow VM→host.
/// There is no RPC for "host hands me a real token," and adding one
/// would defeat the purpose of the swap.
@MainActor
public final class SubscriptionTokenBridge: NSObject, @unchecked Sendable {
    /// Port the in-VM agent connects to. Mirrors `TOKEN_PORT` in
    /// claude-token-agent.py.
    public static let port: UInt32 = 8446

    public struct Tokens: Sendable {
        public let access: String
        public let refresh: String
    }

    public enum BridgeError: Swift.Error, LocalizedError {
        case notConnected
        case agentRejected(String)
        case malformedResponse
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Claude token agent isn't connected yet"
            case .agentRejected(let r): return "VM agent refused the request: \(r)"
            case .malformedResponse: return "VM agent returned a malformed response"
            case .timedOut: return "VM agent didn't respond in time"
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

    // MARK: - RPCs

    /// Read whatever's currently in the VM's credentials.json. Returns
    /// nil when the file or oauth block is missing (i.e., the user
    /// hasn't logged in yet or the field shape doesn't match).
    public func read() async throws -> Tokens? {
        let response = try await rpc(["op": "read"])
        guard let ok = response["ok"] as? Bool, ok else {
            throw BridgeError.agentRejected(
                (response["reason"] as? String) ?? "unknown reason")
        }
        if let access = response["access"] as? String,
           let refresh = response["refresh"] as? String {
            return Tokens(access: access, refresh: refresh)
        }
        return nil
    }

    /// Overwrite the credentials file's accessToken + refreshToken
    /// fields. Both must carry the brm- fake-prefix shape (the agent
    /// rejects anything else).
    public func write(access: String, refresh: String) async throws {
        let response = try await rpc([
            "op": "write",
            "access": access,
            "refresh": refresh,
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
