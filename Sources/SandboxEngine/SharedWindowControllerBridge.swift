import Foundation
import Darwin
@preconcurrency import Virtualization

/// One controller belongs to one VM/profile. Requests are serialized and carry
/// monotonically increasing IDs so the guest can reject duplicate mutations.
@MainActor
public final class SharedWindowControllerBridge {
    public static let vsockPort: UInt32 = 5832
    private let device: VZVirtioSocketDevice
    private weak var virtualMachine: VZVirtualMachine?
    private var nextID = 1
    private var busy = false
    private var epoch: String?
    public init(socketDevice: VZVirtioSocketDevice, virtualMachine: VZVirtualMachine? = nil) {
        device = socketDevice
        self.virtualMachine = virtualMachine
    }

    public func request(_ command: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        guard ["attachPrimary", "list", "create", "resize", "close", "focus", "shutdown"].contains(command),
              !busy, nextID <= 9_007_199_254_740_991, fields["id"] == nil, fields["cmd"] == nil else {
            throw Self.failure("Invalid or overlapping shared-window request")
        }
        busy = true; defer { busy = false }
        // Activation starts an asynchronous resume. Never connect while VZ is
        // transitioning, and never replay a mutation to recover from that race.
        if let vm = virtualMachine {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while vm.state == .paused || vm.state == .resuming || vm.state == .pausing {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Self.failure("Timed out waiting for the browser VM to resume")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard vm.state == .running else {
                throw Self.failure("Browser VM is not running")
            }
        }
        let id = nextID; nextID += 1
        var message = fields; message["id"] = id; message["cmd"] = command
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard data.count <= 65536 else { throw Self.failure("Shared-window request exceeds limit") }
        data.append(10)
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingConnection(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                pending.finish(.failure(Self.failure("Shared-window connection timed out")))
            }
            device.connect(toPort: Self.vsockPort) { result in pending.finish(result) }
        }
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.exchange(data, id: id, connection: connection)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        // Restart reconciliation must be explicit; a create against a new browser
        // must never be mistaken for a replay against the old controller.
        guard let currentEpoch = reply["epoch"] as? String else { throw Self.failure("Missing controller epoch") }
        if let epoch, epoch != currentEpoch { throw Self.failure("Shared-window controller restarted; reconciliation required") }
        epoch = currentEpoch
        return reply
    }

    /// Connection callbacks can arrive after timeout. Resume once and release
    /// late connections without ever sending a mutation on them.
    private final class PendingConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<VZVirtioSocketConnection, Error>?
        init(_ continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) {
            self.continuation = continuation
        }
        func finish(_ result: Result<VZVirtioSocketConnection, Error>) {
            lock.lock()
            let current = continuation
            continuation = nil
            lock.unlock()
            current?.resume(with: result)
        }
    }

    nonisolated private static func exchange(_ data: Data, id: Int,
                                            connection: VZVirtioSocketConnection) throws -> [String: Any] {
        let fd = connection.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw failure("Cannot configure controller connection") }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        func ready(_ events: Int16) throws {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw failure("Shared-window controller timed out") }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw failure("Controller connection poll failed")
                }
                if result == 0 { continue }
                guard descriptor.revents & events != 0 else { throw failure("Controller connection closed") }
                return
            }
        }
        var sent = 0
        while sent < data.count {
            try ready(Int16(POLLOUT))
            let count = data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw failure("Controller request write failed") }
            sent += count
        }
        var incoming = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try ready(Int16(POLLIN))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw failure("Controller reply truncated") }
            incoming.append(contentsOf: bytes.prefix(count))
            if let newline = incoming.firstIndex(of: 10) {
                guard newline <= 65536, newline + 1 == incoming.count,
                      let object = try JSONSerialization.jsonObject(with: incoming.prefix(newline)) as? [String: Any],
                      let replyID = object["id"] as? NSNumber,
                      String(cString: replyID.objCType) != "c", replyID.int64Value == Int64(id),
                      object["ok"] is Bool else { throw failure("Invalid controller reply") }
                return object
            }
            guard incoming.count <= 65536 else { throw failure("Controller reply exceeds limit") }
        }
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "BromureSharedWindows", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
