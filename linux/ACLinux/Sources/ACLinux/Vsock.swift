import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One AF_VSOCK stream between the host and a guest.
///
/// Use it through `withStreams { inbound, outbound in … }`. A connection
/// dropped without that (or `close()`) is closed for you: NIO
/// traps on an async channel whose writer is never finished.
// @port-skip linux-only: host AF_VSOCK (macOS: VZVirtioSocketConnection)
public final class VsockConnection: Sendable {
    /// The guest end (cid, port) — the peer for both accepted and dialed connections.
    public let peer: VsockAddress
    public let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    private let used = NIOLockedValueBox(false)

    // @port-skip linux-only: host AF_VSOCK
    init(peer: VsockAddress, channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) {
        self.peer = peer
        self.channel = channel
    }

    // @port-skip linux-only: host AF_VSOCK
    public func close() async {
        guard claim() else { return }
        try? await channel.executeThenClose { _, _ in }
    }

    /// Runs `body` with the streams, then closes (NIOAsyncChannel's scoped use).
    // @port-skip linux-only: host AF_VSOCK
    public func withStreams<R: Sendable>(
        _ body: (NIOAsyncChannelInboundStream<ByteBuffer>, NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws -> R
    ) async throws -> R {
        guard claim() else { throw ChannelError.alreadyClosed }
        return try await channel.executeThenClose(body)
    }

    // @port-skip linux-only: host AF_VSOCK
    private func claim() -> Bool {
        used.withLockedValue { u in defer { u = true }; return !u }
    }

    // @port-skip linux-only: host AF_VSOCK
    deinit {
        guard claim() else { return }
        let channel = self.channel
        Task { try? await channel.executeThenClose { _, _ in } }
    }

    /// Dials a guest's listening port (host -> guest).
    // @port-skip linux-only: host AF_VSOCK (macOS: VZVirtioSocketDevice.connect(toPort:))
    public static func connect(cid: UInt32, port: UInt32,
                               group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                               timeout: TimeAmount = .seconds(5)) async throws -> VsockConnection {
        let address = VsockAddress(cid: .init(rawValue: cid), port: .init(rawValue: port))
        return try await ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .connect(to: address) { ch in
                ch.eventLoop.makeCompletedFuture {
                    VsockConnection(peer: address,
                                    channel: try NIOAsyncChannel(wrappingChannelSynchronously: ch))
                }
            }
    }
}

/// Host-side listener for guest-initiated vsock connections on one port.
///
/// The host has a single port namespace across all guests (every VM's agentd
/// dials host 5800), so one listener per port serves every CID and hands each
/// accepted connection to that CID's subscriber. Connections from a CID
/// nobody has subscribed to yet are held (up to `backlogPerCID`) and handed
/// over on `connections(from:)`; the rest are closed.
// @port-skip linux-only: host AF_VSOCK (macOS: VZVirtioSocketListener per device)
public actor VsockListener {
    public nonisolated let port: UInt32
    public static let backlogPerCID = 32
    private static let registry = NIOLockedValueBox<[UInt32: Task<VsockListener, Error>]>([:])

    private var server: NIOAsyncChannel<VsockConnection, Never>?
    private var subscribers: [UInt32: (generation: Int, sink: AsyncStream<VsockConnection>.Continuation)] = [:]
    private var generation = 0
    private var backlog: [UInt32: [VsockConnection]] = [:]

    /// The process-wide listener for `port`, bound on first use.
    // @port-skip linux-only: host AF_VSOCK
    public static func shared(port: UInt32,
                              group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> VsockListener {
        let task = registry.withLockedValue { r -> Task<VsockListener, Error> in
            if let t = r[port] { return t }
            let t = Task { try await VsockListener.bind(port: port, group: group) }
            r[port] = t
            return t
        }
        do {
            return try await task.value
        } catch {
            _ = registry.withLockedValue { $0.removeValue(forKey: port) }
            throw error
        }
    }

    /// Unbinds the process-wide listener for `port`, if any (another process,
    /// e.g. a daemon, can then take the port). The next `shared(port:)` binds again.
    // @port-skip linux-only: host AF_VSOCK
    public static func closeShared(port: UInt32) async {
        guard let task = registry.withLockedValue({ $0.removeValue(forKey: port) }),
              let l = try? await task.value else { return }
        await l.close()
    }

    // @port-skip linux-only: host AF_VSOCK
    func close() async {
        for (_, s) in subscribers { s.sink.finish() }
        subscribers = [:]
        backlog = [:]
        try? await server?.channel.close()
        server = nil
    }

    // @port-skip linux-only: host AF_VSOCK
    private static func bind(port: UInt32, group: EventLoopGroup) async throws -> VsockListener {
        let server = try await ServerBootstrap(group: group)
            .bind(to: VsockAddress(cid: .any, port: .init(rawValue: port))) { ch in
                ch.eventLoop.makeCompletedFuture {
                    let peer = try ch.syncOptions!.getOption(.remoteVsockAddress)
                    return VsockConnection(peer: peer,
                                           channel: try NIOAsyncChannel(wrappingChannelSynchronously: ch))
                }
            }
        let l = VsockListener(port: port)
        await l.run(server)
        return l
    }

    // @port-skip linux-only: host AF_VSOCK
    private init(port: UInt32) { self.port = port }

    // @port-skip linux-only: host AF_VSOCK
    private func run(_ server: NIOAsyncChannel<VsockConnection, Never>) {
        self.server = server
        Task { [weak self] in
            try? await server.executeThenClose { inbound in
                for try await conn in inbound { await self?.dispatch(conn) }
            }
        }
    }

    /// Connections from `cid`, starting with any already held for it. One
    /// subscriber per CID; a new call replaces the previous stream.
    // @port-skip linux-only: host AF_VSOCK
    public func connections(from cid: UInt32) -> AsyncStream<VsockConnection> {
        subscribers[cid]?.sink.finish()
        let (stream, cont) = AsyncStream<VsockConnection>.makeStream()
        generation += 1
        let gen = generation
        subscribers[cid] = (gen, cont)
        cont.onTermination = { [weak self] _ in Task { await self?.unsubscribe(cid, gen) } }
        for c in backlog.removeValue(forKey: cid) ?? [] { cont.yield(c) }
        return stream
    }

    /// Stops routing `cid` and closes anything held for it (its VM is gone).
    // @port-skip linux-only: host AF_VSOCK
    public func forget(cid: UInt32) {
        subscribers.removeValue(forKey: cid)?.sink.finish()
        backlog.removeValue(forKey: cid)  // dropped connections close themselves
    }

    // @port-skip linux-only: host AF_VSOCK
    private func unsubscribe(_ cid: UInt32, _ gen: Int) {
        // Only if it's still the current one (a resubscribe replaced it otherwise).
        if subscribers[cid]?.generation == gen { subscribers.removeValue(forKey: cid) }
    }

    // @port-skip linux-only: host AF_VSOCK
    private func dispatch(_ conn: VsockConnection) {
        let cid = conn.peer.cid.rawValue
        if let sub = subscribers[cid]?.sink, case .enqueued = sub.yield(conn) { return }
        var held = backlog[cid] ?? []
        if held.count >= Self.backlogPerCID { return }  // dropped: closes itself
        held.append(conn)
        backlog[cid] = held
    }
}
