import Foundation
import NIOCore
import NIOPosix

/// The host half of Firecracker's hybrid vsock for guest-initiated
/// connections: a guest that connects to host (CID 2) port P makes
/// Firecracker connect to the Unix socket `<uds_path>_P`, which this listens
/// on. The guest side is plain AF_VSOCK, unchanged; each connection comes
/// out as a VsockConnection from (the VM's CID, P), so GuestShell and the
/// rest of the daemon don't know the difference from vhost-vsock.
///
/// One listener per VM and port (the socket path is the VM's), unlike
/// VsockListener's one per port for all guests. Kept in systemd's fd store
/// (`fdStoreName`) and taken back after a restart (`stored`), as the shared
/// vsock listener is: while no daemon runs, the guest's connects wait in
/// the listen backlog instead of being refused (agentd re-dials only so long).
// @port-skip linux-only: Firecracker hybrid vsock (macOS: VZVirtioSocketListener)
public final class HybridVsockListener: Sendable {
    public let path: String
    public let cid: UInt32
    public let port: UInt32
    /// Accepted connections, in order. Single consumer.
    public let connections: AsyncStream<VsockConnection>
    private let server: Channel

    /// `<udsPath>_<port>`: what Firecracker dials for host port `port`.
    // @port-skip linux-only: Firecracker hybrid vsock
    public static func path(uds: String, port: UInt32) -> String { "\(uds)_\(port)" }

    /// Binds `<udsPath>_<port>` (replacing a stale socket file).
    // @port-skip linux-only: Firecracker hybrid vsock
    public static func listen(udsPath: String, port: UInt32, cid: UInt32,
                              fdStoreName: String? = nil, stored: Int32? = nil,
                              group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> HybridVsockListener {
        let path = Self.path(uds: udsPath, port: port)
        let fd: Int32
        if let stored {
            fd = stored
        } else {
            fd = try Self.bindListening(path)
            if let fdStoreName { FDStore.store(fdStoreName, [fd]) }
        }
        let (stream, sink) = AsyncStream<VsockConnection>.makeStream()
        let peer = VsockAddress(cid: .init(rawValue: cid), port: .init(rawValue: port))
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let conn = VsockConnection(peer: peer, channel: try NIOAsyncChannel(wrappingChannelSynchronously: ch))
                    if case .terminated = sink.yield(conn) { Task { await conn.close() } }
                }
            }
            .withBoundSocket(fd).get()
        server.closeFuture.whenComplete { _ in sink.finish() }
        return HybridVsockListener(path: path, cid: cid, port: port, connections: stream, server: server)
    }

    /// A listening AF_UNIX stream socket on `path` (a stale file replaced).
    // @port-skip linux-only: Firecracker hybrid vsock
    static func bindListening(_ path: String) throws -> Int32 {
        let bytes = Array(path.utf8)
        var addr = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw MachineError.socketPathTooLong(path) }
        try? FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw MachineError.io("socket", errno) }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            p.copyBytes(from: bytes)
            p[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, Glibc.listen(fd, 128) == 0 else {
            let e = errno
            Glibc.close(fd)
            throw MachineError.io("listen \(path)", e)
        }
        return fd
    }

    // @port-skip linux-only: Firecracker hybrid vsock
    private init(path: String, cid: UInt32, port: UInt32, connections: AsyncStream<VsockConnection>, server: Channel) {
        self.path = path
        self.cid = cid
        self.port = port
        self.connections = connections
        self.server = server
    }

    // @port-skip linux-only: Firecracker hybrid vsock
    public func close() async {
        try? await server.close()
        try? FileManager.default.removeItem(atPath: path)
    }
}
