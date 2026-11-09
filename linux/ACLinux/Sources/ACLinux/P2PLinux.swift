import Foundation
import Glibc
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// The P2P code's `Darwin.close(fd)`-style calls (qualified so they don't
/// resolve to a type's own close/read/write), on Linux: Glibc's.
// @port-skip linux-only: Glibc stand-ins for the P2P code's Darwin-qualified calls
enum Darwin {
    // @port-skip linux-only: see Darwin
    @discardableResult static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    // @port-skip linux-only: see Darwin
    static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 { Glibc.connect(fd, addr, len) }
    // @port-skip linux-only: see Darwin
    static func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: UnsafeMutablePointer<socklen_t>!) -> Int32 {
        Glibc.accept(fd, addr, len)
    }
    // @port-skip linux-only: see Darwin
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ n: Int) -> Int { Glibc.read(fd, buf, n) }
    // @port-skip linux-only: see Darwin
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer!, _ n: Int) -> Int { Glibc.write(fd, buf, n) }
    // @port-skip linux-only: see Darwin
    static func recv(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ n: Int, _ flags: Int32) -> Int { Glibc.recv(fd, buf, n, flags) }
    // @port-skip linux-only: see Darwin
    static func send(_ fd: Int32, _ buf: UnsafeRawPointer!, _ n: Int, _ flags: Int32) -> Int { Glibc.send(fd, buf, n, flags) }
    // @port-skip linux-only: see Darwin
    static func socket(_ domain: Int32, _ type: __socket_type, _ proto: Int32) -> Int32 {
        Glibc.socket(domain, Int32(type.rawValue), proto)
    }
    // @port-skip linux-only: see Darwin
    static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 { Glibc.bind(fd, addr, len) }
    // @port-skip linux-only: see Darwin
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    // @port-skip linux-only: see Darwin
    @discardableResult static func shutdown(_ fd: Int32, _ how: Int) -> Int32 { Glibc.shutdown(fd, Int32(how)) }
}

/// TURN over TLS (turns:, 5349) behind a blocking loopback fd (macOS:
/// TurnTLS.swift, an NWConnection): one TLS connection to the relay, its
/// certificate checked against the system's roots for `host`, behind a
/// socketpair the TURN code reads and writes like a TCP socket. Each tunnel
/// has an event loop of its own: a slow local reader blocks that loop's
/// writes to the socketpair, never another connection's.
// @port-skip linux-only: TurnTLSTunnel over NIOSSL (macOS: Network.framework's TLS)
enum TurnTLSTunnel {
    // @port-skip linux-only: see TurnTLSTunnel
    static func connect(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        guard port > 0, port <= 65535, let context = try? NIOSSLContext(configuration: .makeClientConfiguration()) else { return nil }
        var sp: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &sp) == 0 else { return nil }
        let localFD = sp[0], pumpFD = sp[1]
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handshake = Handshake(group.next().makePromise(of: Void.self))
        let sni = (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
        // As macOS's NWProtocolTCP options: keepalive after 15 s idle, every
        // 5 s, 3 misses; a stalled send dropped after 30 s.
        let tcp = SocketOptionLevel(IPPROTO_TCP)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(max(1, timeout) * 1000)))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(tcp, TCP_KEEPIDLE), value: 15)
            .channelOption(ChannelOptions.socket(tcp, TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(tcp, TCP_KEEPCNT), value: 3)
            .channelOption(ChannelOptions.socket(tcp, TCP_USER_TIMEOUT), value: 30_000)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: sni))
                    try ch.pipeline.syncOperations.addHandler(TLSPump(pumpFD: pumpFD, handshake: handshake))
                }
            }
        let fail = { () -> Int32? in
            Glibc.close(localFD); Glibc.close(pumpFD)
            try? group.syncShutdownGracefully()
            return nil
        }
        guard let channel = try? bootstrap.connect(host: host, port: port).wait() else { return fail() }
        let deadline = group.next().scheduleTask(in: .milliseconds(Int64(max(1, timeout) * 1000))) {
            handshake.fail(ChannelError.connectTimeout(.seconds(Int64(timeout))))
        }
        guard (try? handshake.promise.futureResult.wait()) != nil else { deadline.cancel(); channel.close(promise: nil); return fail() }
        deadline.cancel()
        // Uplink: the socketpair to the relay, on a thread of its own.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = buf.withUnsafeMutableBytes { Glibc.read(pumpFD, $0.baseAddress, $0.count) }
                guard n > 0 else { break }
                var out = channel.allocator.buffer(capacity: n)
                out.writeBytes(buf[0..<n])
                guard (try? channel.writeAndFlush(out).wait()) != nil else { break }
            }
            channel.close(promise: nil)
            _ = try? channel.closeFuture.wait()
            Glibc.close(pumpFD)
            group.shutdownGracefully { _ in }
        }
        return localFD
    }

    /// The handshake's outcome, settled once (the TLS event, the channel's
    /// end, an error or the deadline: all on the tunnel's one loop).
    // @port-skip linux-only: see TurnTLSTunnel
    final class Handshake: @unchecked Sendable {
        let promise: EventLoopPromise<Void>
        private var settled = false
        // @port-skip linux-only: see TurnTLSTunnel
        init(_ p: EventLoopPromise<Void>) { promise = p }
        // @port-skip linux-only: see TurnTLSTunnel
        func succeed() { guard !settled else { return }; settled = true; promise.succeed(()) }
        // @port-skip linux-only: see TurnTLSTunnel
        func fail(_ e: Error) { guard !settled else { return }; settled = true; promise.fail(e) }
    }

    /// The relay's decrypted bytes to the socketpair; its end, the
    /// socketpair's write side shut (the TURN code reads EOF).
    // @port-skip linux-only: see TurnTLSTunnel
    final class TLSPump: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let pumpFD: Int32
        let handshake: Handshake
        // @port-skip linux-only: see TurnTLSTunnel
        init(pumpFD: Int32, handshake: Handshake) { self.pumpFD = pumpFD; self.handshake = handshake }
        // @port-skip linux-only: see TurnTLSTunnel
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case TLSUserEvent.handshakeCompleted = event { handshake.succeed() }
            context.fireUserInboundEventTriggered(event)
        }
        // @port-skip linux-only: see TurnTLSTunnel
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            while b.readableBytes > 0 {
                let n = b.withUnsafeReadableBytes { Glibc.write(pumpFD, $0.baseAddress, $0.count) }
                guard n > 0 else { context.close(promise: nil); return }
                b.moveReaderIndex(forwardBy: n)
            }
        }
        // @port-skip linux-only: see TurnTLSTunnel
        func channelInactive(context: ChannelHandlerContext) {
            handshake.fail(ChannelError.ioOnClosedChannel)
            Glibc.shutdown(pumpFD, Int32(SHUT_WR))
            context.fireChannelInactive()
        }
        // @port-skip linux-only: see TurnTLSTunnel
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            handshake.fail(error)
            context.close(promise: nil)
        }
    }
}

extension P2PBroker {
    /// No path monitor on a server: it watches the network for a dialer's
    /// live peer paths (macOS starts it on the first dial), and a Linux
    /// server only listens. Its signaling channel reconnects on its own.
    // partial: a server never dials, so there's nothing to re-establish on a path change
// @port P2PBroker.startNetworkMonitor() h=bf125c45cf2ca52b @cd1336b9
    func startNetworkMonitor() {}
}
