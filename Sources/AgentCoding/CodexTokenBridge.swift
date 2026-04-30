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
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private var pending: [(req: Data, cont: CheckedContinuation<[String: Any], Error>)] = []
    private var rxBuffer = Data()
    public private(set) var isConnected: Bool = false

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
        readSource?.cancel()
        readSource = nil
        connection = nil
        isConnected = false
        socketDevice?.removeSocketListener(forPort: Self.port)
        for entry in pending {
            entry.cont.resume(throwing: BridgeError.notConnected)
        }
        pending.removeAll()
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

    private func rpc(_ payload: [String: Any]) async throws -> [String: Any] {
        guard isConnected, let conn = connection else {
            throw BridgeError.notConnected
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var line = body
        line.append(0x0a)

        return try await withCheckedThrowingContinuation { cont in
            pending.append((req: line, cont: cont))
            let fd = conn.fileDescriptor
            line.withUnsafeBytes { ptr in
                var offset = 0
                while offset < line.count {
                    let n = Darwin.write(fd, ptr.baseAddress! + offset, line.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    private func accept(_ conn: VZVirtioSocketConnection) {
        readSource?.cancel()
        readSource = nil
        connection = conn
        isConnected = true
        rxBuffer = Data()

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else { source.cancel(); return }
            self?.rxBuffer.append(contentsOf: buf[0..<n])
            self?.drainLines()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.connection = nil
            self.isConnected = false
            for entry in self.pending {
                entry.cont.resume(throwing: BridgeError.notConnected)
            }
            self.pending.removeAll()
            self.readSource = nil
        }
        source.resume()
        readSource = source
    }

    private func drainLines() {
        while let nl = rxBuffer.firstIndex(of: 0x0a) {
            let line = rxBuffer[rxBuffer.startIndex..<nl]
            rxBuffer = Data(rxBuffer[(nl + 1)...])
            let response: [String: Any]
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                response = obj
            } else {
                response = ["ok": false, "reason": "malformed json from agent"]
            }
            if pending.isEmpty { continue }
            let entry = pending.removeFirst()
            entry.cont.resume(returning: response)
        }
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
