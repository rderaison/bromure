import Foundation
import NIOCore

/// The pool of guest-initiated vsock connections to bromure-agentd's shell
/// service (host port 5800), and command execution over them: the Linux
/// side of ShellBridge. Same protocol:
///   request  `u32be len` + `{"cmd": "...", "timeout": 30, "workdir": "..."}`
///   response `u32be len` + `{"stdout": "...", "stderr": "...", "exit_code": 0}`
/// One request per connection; agentd opens a replacement after each.
// @port-skip linux-only: the type; its members carry @port lines
public actor GuestShell {
    // @port-skip linux-only: exec result
    public struct Result: Sendable, Codable, Equatable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int
    }

    // @port-skip linux-only: exec errors
    public enum ShellError: Error, Equatable { case notReady, protocolError(String) }

    public nonisolated let cid: UInt32
    private var pool: [VsockConnection] = []
    private var waiters: [Int: CheckedContinuation<VsockConnection?, Never>] = [:]
    private var nextWaiter = 0
    private var feed: Task<Void, Never>?
    public private(set) var isReady = false
    private static let minPoolSize = 1

    /// Starts taking `cid`'s connections from the shared host listener.
    // @port ShellBridge.init(socketDevice: VZVirtioSocketDevice) h=2bdb1c18bb9740bc @fd4de5b5
    public init(cid: UInt32, listener: VsockListener) async {
        self.cid = cid
        let stream = await listener.connections(from: cid)
        feed = Task { [weak self] in
            for await c in stream { await self?.handleVsockConnection(c) }
        }
    }

    // @port ShellBridge.stop() h=4f8be4d1583dae61 @fd4de5b5
    public func stop() {
        feed?.cancel()
        feed = nil
        flushPool()
        for w in waiters.values { w.resume(returning: nil) }
        waiters = [:]
    }

    /// Take a connection from the pool (nil if none is available).
    // @port ShellBridge.dequeueConnection() h=0eacd77ed6d43fa1 @fd4de5b5
    public func dequeueConnection() -> VsockConnection? {
        while !pool.isEmpty {
            let c = pool.removeFirst()
            if c.channel.channel.isActive { return c }   // agentd may have dropped an idle one
        }
        return nil
    }

    /// Drop every queued connection (the guest rebooted or was restored: the
    /// pooled sockets belong to the previous agent).
    // @port ShellBridge.flushPool() h=5496be3a75fbb6d3 @fd4de5b5
    public func flushPool() {
        let old = pool
        pool = []
        Task { for c in old { await c.close() } }
    }

    // @port ShellBridge.var poolSize h=33b1cd0c4033f99e @fd4de5b5
    public var poolSize: Int { pool.count }

    // @port ShellBridge.handleVsockConnection(_: VZVirtioSocketConnection) h=18e39e8b6fc21087 @fd4de5b5
    private func handleVsockConnection(_ conn: VsockConnection) {
        if let (id, w) = waiters.min(by: { $0.key < $1.key }) {
            waiters.removeValue(forKey: id)
            w.resume(returning: conn)
        } else {
            pool.append(conn)
        }
        if !isReady, pool.count + 1 >= Self.minPoolSize { isReady = true }
    }

    /// A pooled connection, waiting up to `timeout` for agentd to offer one.
    // @port-skip linux-only: async wait for the pool (macOS polls dequeueConnection)
    public func connection(timeout: Duration) async -> VsockConnection? {
        if let c = dequeueConnection() { return c }
        nextWaiter += 1
        let id = nextWaiter
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    // @port-skip linux-only: async wait for the pool
    private func expire(_ id: Int) { waiters.removeValue(forKey: id)?.resume(returning: nil) }

    /// Runs `cmd` in the guest. Retries on a pooled connection agentd already
    /// dropped; fails with `.notReady` if no connection comes within `wait`.
    // @port-skip linux-only: exec over NIO vsock (macOS: the automation server's exec over a VZ connection)
    public func exec(_ cmd: String, timeout: Int = 30, workdir: String? = nil,
                     wait: Duration = .seconds(30)) async throws -> Result {
        var req: [String: Any] = ["cmd": cmd, "timeout": timeout]
        if let workdir { req["workdir"] = workdir }
        let body = try JSONSerialization.data(withJSONObject: req)
        for _ in 0..<32 {
            guard let c = await connection(timeout: wait) else { throw ShellError.notReady }
            if let r = try? await Self.roundTrip(c, body) { return r }
        }
        throw ShellError.notReady
    }

    // @port-skip linux-only: exec over NIO vsock
    static func roundTrip(_ conn: VsockConnection, _ body: Data) async throws -> Result {
        try await conn.withStreams { inbound, outbound in
            var buf = ByteBuffer()
            buf.writeInteger(UInt32(body.count))
            buf.writeBytes(body)
            try await outbound.write(buf)
            var acc = ByteBuffer()
            for try await chunk in inbound {
                var c = chunk
                acc.writeBuffer(&c)
                if let n = acc.getInteger(at: acc.readerIndex, as: UInt32.self), acc.readableBytes >= 4 + Int(n) {
                    let json = Data(acc.getBytes(at: acc.readerIndex + 4, length: Int(n))!)
                    guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                        throw ShellError.protocolError("not an object")
                    }
                    return Result(stdout: o["stdout"] as? String ?? (o["output"] as? String ?? ""),
                                  stderr: o["stderr"] as? String ?? "", exitCode: o["exit_code"] as? Int ?? -1)
                }
            }
            throw ShellError.protocolError("connection closed before a reply")
        }
    }
}
