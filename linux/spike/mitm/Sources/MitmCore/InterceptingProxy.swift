import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// An HTTP CONNECT proxy that intercepts TLS: the way guests reach the macOS
/// proxy (agentd bridges http_proxy to it).
///
/// Per CONNECT host:port:
/// 1. connect upstream and handshake TLS first, offering h2 + http/1.1 and
///    verifying against the system trust store (plus `extraTrustRoots`, or a
///    per-host pinned root); this learns the ALPN upstream picked;
/// 2. answer `200 Connection Established` and terminate the client's TLS with
///    a leaf minted for `host`, advertising exactly that ALPN;
/// 3. relay bytes both ways (the hook where the real proxy inspects/rewrites).
public final class InterceptingProxy: @unchecked Sendable {
    public struct Config {
        public var ca: CertificateAuthority
        /// Added to the system roots for upstream verification.
        public var extraTrustRoots: [NIOSSLCertificate] = []
        /// host -> the only roots accepted for it (pinning).
        public var pinnedRoots: [String: [NIOSSLCertificate]] = [:]
        /// Upstream client certificate (mTLS to the origin).
        public var clientCertificate: (chain: [NIOSSLCertificate], key: NIOSSLPrivateKey)?
        /// Bench: connect every upstream here instead of host:port (SNI kept).
        public var routeAllTo: (host: String, port: Int)?
        public init(ca: CertificateAuthority) { self.ca = ca }
    }

    public struct Stats: Sendable {
        public var accepted = 0, intercepted = 0, failed = 0
        public var h2 = 0, http1 = 0
    }

    public let config: Config
    let group: EventLoopGroup
    private let stats = NIOLockedValueBox(Stats())
    private let upstreamContexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])
    public private(set) var channel: Channel?

    public init(config: Config, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config
        self.group = group
    }

    public var snapshot: Stats { stats.withLockedValue { $0 } }

    public func listen(host: String, port: Int) throws -> Channel {
        let ch = try ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.backlog, value: 1024)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] ch in
                stats.withLockedValue { $0.accepted += 1 }
                return ch.pipeline.addHandler(ConnectHandler(proxy: self))
            }
            .bind(host: host, port: port).wait()
        channel = ch
        return ch
    }

    func upstreamContext(host: String, alpn: [String]) throws -> NIOSSLContext {
        let key = (config.pinnedRoots[host] != nil ? host : "*") + "|" + alpn.joined(separator: ",")
        if let c = upstreamContexts.withLockedValue({ $0[key] }) { return c }
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = alpn
        if let pinned = config.pinnedRoots[host] {
            cfg.trustRoots = .certificates(pinned)
        } else if !config.extraTrustRoots.isEmpty {
            cfg.additionalTrustRoots = [.certificates(config.extraTrustRoots)]
        }
        if let cc = config.clientCertificate {
            cfg.certificateChain = cc.chain.map { .certificate($0) }
            cfg.privateKey = .privateKey(cc.key)
        }
        let ctx = try NIOSSLContext(configuration: cfg)
        upstreamContexts.withLockedValue { $0[key] = ctx }
        return ctx
    }

    func record(_ f: (inout Stats) -> Void) { stats.withLockedValue(f) }

    /// Connects + handshakes upstream on `eventLoop`; yields the channel and ALPN.
    func connectUpstream(host: String, port: Int, alpn: [String], on eventLoop: EventLoop) -> EventLoopFuture<(Channel, String?)> {
        let done = eventLoop.makePromise(of: (Channel, String?).self)
        let target = config.routeAllTo ?? (host, port)
        let ctx: NIOSSLContext
        do { ctx = try upstreamContext(host: host, alpn: alpn) } catch { done.fail(error); return done.futureResult }
        let isIP = IPv4Address(host) != nil || host.contains(":")
        ClientBootstrap(group: eventLoop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(10))
            .channelInitializer { ch in
                do {
                    let tls = try NIOSSLClientHandler(context: ctx, serverHostname: isIP ? nil : host)
                    return ch.pipeline.addHandlers([tls, HandshakeWaiter(done)])
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: target.host, port: target.port)
            .whenFailure { done.fail($0) }
        return done.futureResult
    }
}

/// Fulfils `promise` with (channel, ALPN) once TLS is up, then leaves.
final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    let promise: EventLoopPromise<(Channel, String?)>
    init(_ p: EventLoopPromise<(Channel, String?)>) { promise = p }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let proto) = event {
            promise.succeed((context.channel, proto))
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }
}

/// Reads the CONNECT request, answers 200, reads the client's ClientHello
/// (SNI + offered ALPN), connects upstream offering exactly that ALPN list,
/// then terminates the client's TLS with a leaf for the SNI advertising what
/// upstream picked, and hands off to glue.
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let proxy: InterceptingProxy
    private var buf = ByteBuffer()
    private enum Phase { case request, hello(host: String, port: Int), connecting }
    private var phase = Phase.request

    init(proxy: InterceptingProxy) { self.proxy = proxy }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        buf.writeBuffer(&b)
        switch phase {
        case .request:
            guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
            let text = buf.readString(length: end.upperBound - buf.readerIndex) ?? ""
            let parts = text.split(separator: "\r\n").first?.split(separator: " ") ?? []
            guard parts.count >= 2, parts[0] == "CONNECT" else {
                reply(context, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
                return
            }
            let (host, port) = Self.split(String(parts[1]))
            phase = .hello(host: host, port: port)
            reply(context, "HTTP/1.1 200 Connection Established\r\n\r\n", close: false)
            if buf.readableBytes > 0 { helloArrived(context, host: host, port: port) }
        case .hello(let host, let port):
            helloArrived(context, host: host, port: port)
        case .connecting:
            break   // buffered until the TLS handler takes over
        }
    }

    private func helloArrived(_ context: ChannelHandlerContext, host: String, port: Int) {
        switch ClientHelloInfo.parse(buf) {
        case .needMore: return
        case .notTLS:
            proxy.record { $0.failed += 1 }
            context.close(promise: nil)
        case .hello(let hello):
            phase = .connecting
            // The leaf follows the SNI when there is one (what the client will
            // verify); upstream is the CONNECT target.
            let leafHost = hello.serverName ?? host
            let offered = hello.alpn.isEmpty ? ["http/1.1"] : hello.alpn
            let proxy = self.proxy
            proxy.connectUpstream(host: hello.serverName ?? host, port: port, alpn: offered, on: context.eventLoop)
                .whenComplete { result in
                    switch result {
                    case .failure:
                        proxy.record { $0.failed += 1 }
                        context.close(promise: nil)
                    case .success(let (upstream, alpn)):
                        do {
                            let serverCtx = try proxy.config.ca.serverContext(host: leafHost, alpn: alpn.map { [$0] } ?? [])
                            proxy.record { $0.intercepted += 1; if alpn == "h2" { $0.h2 += 1 } else { $0.http1 += 1 } }
                            let (local, remote) = GlueHandler.matchedPair()
                            try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverCtx), position: .after(self))
                            try context.pipeline.syncOperations.addHandler(local)
                            try upstream.pipeline.syncOperations.addHandler(remote)
                            let hello = self.buf
                            self.buf.clear()
                            context.fireChannelRead(NIOAny(hello))
                            context.pipeline.removeHandler(self, promise: nil)
                        } catch {
                            proxy.record { $0.failed += 1 }
                            upstream.close(promise: nil)
                            context.close(promise: nil)
                        }
                    }
                }
        }
    }

    private func reply(_ context: ChannelHandlerContext, _ s: String, close: Bool) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: s))).whenComplete { _ in
            if close { context.close(promise: nil) }
        }
    }

    static func split(_ target: String) -> (String, Int) {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let h = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            return (h, Int(rest.dropFirst()) ?? 443)
        }
        if let c = target.lastIndex(of: ":"), let p = Int(target[target.index(after: c)...]) {
            return (String(target[..<c]), p)
        }
        return (target, 443)
    }
}

/// Byte relay between two channels on the same event loop, with backpressure
/// (reads stop while the partner isn't writable). From NIO's connect-proxy example.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerClose() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The CONNECT handler may have turned reads off; glue drives them now.
        context.read()
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerClose() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e { partner?.partnerClose() }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }
    func read(context: ChannelHandlerContext) {
        if let p = partner, p.partnerWritable { context.read() } else { pendingRead = true }
    }
}
