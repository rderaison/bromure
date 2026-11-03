import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One vsock stream between the host and a guest (with Firecracker's
/// hybrid vsock, a Unix stream to its socket).
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
}
