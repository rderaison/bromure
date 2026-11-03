import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The line channel to an in-VM token agent (`claude-token-agent.py` on
/// vsock 8446, `codex-token-agent.py` on 8447): one newline-terminated JSON
/// request, one JSON reply, in order, over a connected socket. The VZ
/// listeners (SubscriptionTokenBridge, CodexTokenBridge) hand it each
/// connection's fd; the Linux daemon its hybrid-vsock fd.
@MainActor
final class TokenAgentChannel {
    private var fd: Int32 = -1
    /// What owns the fd (a VZVirtioSocketConnection), kept alive while it's
    /// in use; nil: the channel owns the fd and closes it.
    private var owner: AnyObject?
    private var readSource: DispatchSourceRead?
    private var pending: [CheckedContinuation<[String: Any], Error>] = []
    private var rxBuffer = Data()
    private(set) var isConnected = false
    /// What callers waiting on a channel that drops are failed with.
    private let disconnected: Error

    init(disconnectedError: Error) {
        disconnected = disconnectedError
    }

    /// A new agent connection replaces the current one (the agent
    /// reconnects every 2 s after a drop).
    func accept(fd: Int32, owner: AnyObject?) {
        readSource?.cancel()
        readSource = nil
        self.fd = fd
        self.owner = owner
        isConnected = true
        rxBuffer = Data()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { source.cancel(); return }
            MainActor.assumeIsolated {
                self?.rxBuffer.append(contentsOf: buf[0..<n])
                self?.drainLines()
            }
        }
        let ownsFD = owner == nil
        source.setCancelHandler { [weak self] in
            if ownsFD { close(fd) }
            MainActor.assumeIsolated {
                // A replaced connection's cancel mustn't end its successor.
                guard let self, self.readSource === source || self.readSource == nil else { return }
                self.owner = nil
                self.isConnected = false
                // Fail any in-flight request — caller can retry once the
                // agent reconnects.
                self.failPending()
                self.readSource = nil
            }
        }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        owner = nil
        isConnected = false
        // Unblock any callers still waiting.
        failPending()
    }

    /// One request, its reply.
    func rpc(_ payload: [String: Any]) async throws -> [String: Any] {
        guard isConnected, fd >= 0 else { throw disconnected }
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0a)  // newline-delimited
        let fd = self.fd
        return try await withCheckedThrowingContinuation { cont in
            pending.append(cont)
            line.withUnsafeBytes { ptr in
                var offset = 0
                while offset < line.count {
                    let n = write(fd, ptr.baseAddress! + offset, line.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    private func failPending() {
        for cont in pending { cont.resume(throwing: disconnected) }
        pending.removeAll()
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
            pending.removeFirst().resume(returning: response)
        }
    }
}
