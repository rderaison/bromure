import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import SwiftASN1
import X509

/// The workspaces' intercepting proxy on a Linux server (macOS: MitmEngine +
/// HTTPMitmConnection). agentd bridges the guest's `127.0.0.1:<proxy_port>`
/// (proxy.env's HTTP(S)_PROXY) to host vsock 8443, which Firecracker's hybrid
/// vsock delivers on `<v.sock>_8443`: one listener per VM, so a connection's
/// workspace is the listener's.
///
/// Per connection, as macOS does it: the bridge's preamble line, then
/// `CONNECT host:port` (TLS terminated with a leaf the guest trusts through
/// the Bromure CA) or a plain `http://` request; one request per connection;
/// its subscription stand-ins and fake tokens swapped for the real ones
/// (SubscriptionAuthRewrite, TokenSwapper), a sign-in's token exchange
/// answered by the host (SignInCapture), and the response streamed back.
/// Guardrails, PII, supply-chain, tracing and the egress firewall are
/// macOS's alone for now.
// partial: no guardrails, PII, supply-chain, prompt-injection, tracing or egress policy on Linux yet
// @port-skip linux-only: macOS's MitmEngine runs HTTPMitmConnection (SecureTransport) per VZ vsock connection
final class MitmProxy: @unchecked Sendable {
    static let vsockPort: UInt32 = 8443
    /// A request body is held in memory up to this (macOS spools to disk).
    static let maxBody = 256 << 20

    let ca: BromureCA
    let caNIO: NIOSSLCertificate
    let swapper: TokenSwapper
    let claudeStore: ClaudeSubscriptionStore
    let claudeRefresher: ClaudeSubscriptionRefresher
    let codexStore: CodexSubscriptionStore
    let codexRefresher: CodexSubscriptionRefresher
    let grokStore: GrokSubscriptionStore
    let grokRefresher: GrokSubscriptionRefresher
    let kimiStore: KimiSubscriptionStore
    let kimiRefresher: KimiSubscriptionRefresher
    let captures = SignInCaptureRegistry()
    /// Per-install salt for the fake tokens (macOS: MitmEngine's
    /// `fake-salt.bin` beside the CA); wiping it rotates every fake.
    let fakeTokenSalt: Data
    let group: EventLoopGroup
    /// Leaves for the hosts the guests reach (macOS: CertCache's identities).
    private let leaves = NIOLockedValueBox<(map: [String: (NIOSSLContext, UInt64)], tick: UInt64)>(([:], 0))
    static let leafCapacity = 1024
    private let upstreamContext: NIOSSLContext
    /// Tests: every upstream connection goes here instead (SNI kept), trusting `extraRoots`.
    var routeAllTo: (host: String, port: Int)?

    /// The CA (`<dir>/cert.pem`, `key.pem`, made on first use) and the
    /// subscription stores the stand-in swaps read, wired where the swaps
    /// look for them (SubscriptionProviders).
    // @port-skip linux-only: MitmEngine.init's share for the Linux proxy
    init(caDirectory: URL, extraRoots: [NIOSSLCertificate] = [],
         group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) throws {
        ca = try BromureCA.loadOrCreate(at: caDirectory)
        caNIO = try NIOSSLCertificate(bytes: Array(ca.certificatePEM.utf8), format: .pem)
        let saltURL = caDirectory.appendingPathComponent("fake-salt.bin")
        if let existing = try? Data(contentsOf: saltURL), existing.count == 32 {
            fakeTokenSalt = existing
        } else {
            var g = SystemRandomNumberGenerator()
            let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })
            try fresh.write(to: saltURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: saltURL.path)
            fakeTokenSalt = fresh
        }
        swapper = TokenSwapper(consent: ConsentBroker())
        claudeStore = ClaudeSubscriptionStore()
        claudeRefresher = ClaudeSubscriptionRefresher(store: claudeStore)
        codexStore = CodexSubscriptionStore()
        codexRefresher = CodexSubscriptionRefresher(store: codexStore)
        grokStore = GrokSubscriptionStore()
        grokRefresher = GrokSubscriptionRefresher(store: grokStore)
        kimiStore = KimiSubscriptionStore()
        kimiRefresher = KimiSubscriptionRefresher(store: kimiStore)
        self.group = group
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = ["http/1.1"]
        if !extraRoots.isEmpty { cfg.additionalTrustRoots = [.certificates(extraRoots)] }
        upstreamContext = try NIOSSLContext(configuration: cfg)
        wireProviders()
    }

    /// The swaps reach the stores through SubscriptionProviders (macOS:
    /// MitmEngine.register sets the same closures).
    // @port-skip linux-only: MitmEngine.register's provider wiring
    private func wireProviders() {
        SubscriptionProviders.claude = { [weak self] in self.map { ($0.claudeStore, $0.claudeRefresher) } }
        SubscriptionProviders.codex = { [weak self] in self.map { ($0.codexStore, $0.codexRefresher) } }
        SubscriptionProviders.grok = { [weak self] in self.map { ($0.grokStore, $0.grokRefresher) } }
        SubscriptionProviders.kimi = { [weak self] in self.map { ($0.kimiStore, $0.kimiRefresher) } }
        SubscriptionProviders.signInCapture = { [weak self] pid in self?.captures.capture(for: pid) }
    }

    /// Serves one VM's `<udsPath>_8443` (or `stored`, a restarted daemon's
    /// listener from the fd store) for workspace `profileID`.
    // @port-skip linux-only: the per-VM proxy listener (macOS: MitmEngine.register on the VZ socket device)
    func serve(udsPath: String, profileID: UUID, fdStoreName: String, stored: Int32? = nil) throws -> MitmListener {
        let path = HybridVsockListener.path(uds: udsPath, port: Self.vsockPort)
        let fd: Int32
        if let stored { fd = stored } else {
            fd = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [fd])
        }
        let channel = try ServerBootstrap(group: group)
            .childChannelInitializer { [self] ch in
                ch.pipeline.addHandler(ConnectHandler(proxy: self, profileID: profileID))
            }
            .withBoundSocket(fd).wait()
        return MitmListener(channel: channel, path: path, fdStoreName: fdStoreName)
    }

    /// A server context for `host` (http/1.1), minted on a miss.
    // @port-skip linux-only: NIOSSL leaves from CertCache.mintLeaf (macOS caches SecIdentities)
    func serverContext(host: String) throws -> NIOSSLContext {
        let hit: NIOSSLContext? = leaves.withLockedValue { s in
            guard let (c, _) = s.map[host] else { return nil }
            s.tick += 1
            s.map[host] = (c, s.tick)
            return c
        }
        if let hit { return hit }
        let (leaf, key) = try CertCache.mintLeaf(for: host, ca: ca)
        var ser = DER.Serializer()
        try ser.serialize(leaf)
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: ser.serializedBytes, format: .der)),
                               .certificate(caNIO)],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
        cfg.applicationProtocols = ["http/1.1"]
        let ctx = try NIOSSLContext(configuration: cfg)
        leaves.withLockedValue { s in
            s.tick += 1
            s.map[host] = (ctx, s.tick)
            if s.map.count > Self.leafCapacity, let oldest = s.map.min(by: { $0.value.1 < $1.value.1 })?.key {
                s.map.removeValue(forKey: oldest)
            }
        }
        return ctx
    }

    /// Connects to `host:port` (TLS, verified against the system roots, when
    /// `tls`) on `loop`; the channel is ready to write when the future holds.
    // @port-skip linux-only: NIO upstream (macOS: URLSession / NWConnection)
    func connectUpstream(host: String, port: Int, tls: Bool, on loop: EventLoop) -> EventLoopFuture<Channel> {
        let target = routeAllTo ?? (host, port)
        let ctx = upstreamContext
        let isIP = host.contains(":") || host.split(separator: ".").allSatisfy { UInt8($0) != nil }
        let ready = OncePromise(loop.makePromise(of: Channel.self))
        ClientBootstrap(group: loop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(15))
            .channelInitializer { ch in
                guard tls else { return ch.eventLoop.makeSucceededVoidFuture() }
                do {
                    return ch.pipeline.addHandlers([
                        try NIOSSLClientHandler(context: ctx, serverHostname: isIP ? nil : host),
                        HandshakeWaiter(ready),
                    ])
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }
            .connect(host: target.host, port: target.port)
            .whenComplete { r in
                switch r {
                case .failure(let e): ready.fail(e)
                case .success(let ch): if !tls { ready.succeed(ch) }
                }
            }
        return ready.promise.futureResult
    }
}

/// A promise completed at most once, whichever side settles it first (all
/// on its event loop).
// @port-skip linux-only: NIO plumbing
final class OncePromise<T>: @unchecked Sendable {
    let promise: EventLoopPromise<T>
    private var settled = false
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(_ p: EventLoopPromise<T>) { promise = p }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func succeed(_ v: T) { guard !settled else { return }; settled = true; promise.succeed(v) }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func fail(_ e: Error) { guard !settled else { return }; settled = true; promise.fail(e) }
}

/// One VM's proxy listener.
// @port-skip linux-only: the per-VM proxy listener
final class MitmListener: @unchecked Sendable {
    let channel: Channel
    let path: String
    let fdStoreName: String
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(channel: Channel, path: String, fdStoreName: String) {
        self.channel = channel
        self.path = path
        self.fdStoreName = fdStoreName
    }
    /// The VM is gone: the listener closed and its socket file removed.
    // @port-skip linux-only: the per-VM proxy listener
    func stop() {
        channel.close(promise: nil)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Fulfils `promise` once the upstream TLS handshake completed, then leaves.
// @port-skip linux-only: NIO plumbing
final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    let ready: OncePromise<Channel>
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(_ r: OncePromise<Channel>) { ready = r }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            ready.succeed(context.channel)
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(error)
        context.close(promise: nil)
    }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        ready.fail(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }
}

/// The guest side, before TLS: the bridge's `BROMURE-CLIENT` line, then
/// CONNECT (answered 200, then the ClientHello names the leaf) or a plain
/// absolute-form HTTP request, handed to a RequestReader as it is.
// @port-skip linux-only: HTTPMitmConnection.drive's CONNECT phase on NIO
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let proxy: MitmProxy
    let profileID: UUID
    private var buf = ByteBuffer()
    private enum Phase { case preamble, request, hello(host: String, port: Int), handedOff }
    private var phase = Phase.preamble

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(proxy: MitmProxy, profileID: UUID) {
        self.proxy = proxy
        self.profileID = profileID
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        buf.writeBuffer(&b)
        step(context)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func step(_ context: ChannelHandlerContext) {
        while true {
            switch phase {
            case .preamble:
                let prefix = Array("BROMURE-CLIENT ".utf8)
                let view = Array(buf.readableBytesView.prefix(prefix.count))
                if view.count < prefix.count, view == Array(prefix.prefix(view.count)) { return }
                if view == prefix {
                    guard let nl = buf.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                        if buf.readableBytes > 512 { context.close(promise: nil) }
                        return
                    }
                    buf.moveReaderIndex(forwardBy: nl - buf.readerIndex + 1)
                }
                phase = .request
            case .request:
                guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else {
                    if buf.readableBytes > 64 << 10 { context.close(promise: nil) }
                    return
                }
                let line = String(decoding: buf.readableBytesView.prefix(while: { $0 != 13 }), as: UTF8.self)
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { return reject(context, 400, "Bad Request") }
                if parts[0] == "CONNECT" {
                    let (host, port) = Self.split(String(parts[1]), defaultPort: 443)
                    buf.moveReaderIndex(forwardBy: end.upperBound - buf.readerIndex)
                    phase = .hello(host: host, port: port)
                    context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
                        string: "HTTP/1.1 200 Connection Established\r\n\r\n")), promise: nil)
                    continue
                }
                // A plain-HTTP request through the proxy: absolute form.
                guard let url = URL(string: String(parts[1])), url.scheme?.lowercased() == "http",
                      let host = url.host else { return reject(context, 405, "Method Not Allowed") }
                handOff(context, RequestReader(proxy: proxy, profileID: profileID, host: host,
                                               port: url.port ?? 80, tls: false), tlsHost: nil)
                return
            case .hello(let host, let port):
                switch ClientHelloInfo.parse(buf) {
                case .needMore: return
                case .notTLS: return reject(context, 400, "Bad Request")
                case .hello(let hello):
                    // The leaf names what the client will verify (its SNI); the
                    // upstream is that name too, at the CONNECT port.
                    let name = hello.serverName ?? host
                    handOff(context, RequestReader(proxy: proxy, profileID: profileID, host: name,
                                                   port: port, tls: true), tlsHost: name)
                    return
                }
            case .handedOff:
                return
            }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func handOff(_ context: ChannelHandlerContext, _ reader: RequestReader, tlsHost: String?) {
        phase = .handedOff
        do {
            let ops = context.pipeline.syncOperations
            if let tlsHost {
                let tls = NIOSSLServerHandler(context: try proxy.serverContext(host: tlsHost))
                try ops.addHandler(tls, position: .after(self))
                try ops.addHandler(reader, position: .after(tls))
            } else {
                try ops.addHandler(reader, position: .after(self))
            }
        } catch {
            context.close(promise: nil)
            return
        }
        let rest = buf
        buf.clear()
        if rest.readableBytes > 0 { context.fireChannelRead(NIOAny(rest)) }
        context.pipeline.removeHandler(self, promise: nil)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func reject(_ context: ChannelHandlerContext, _ status: Int, _ reason: String) {
        phase = .handedOff
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
            string: "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
            .whenComplete { _ in context.close(promise: nil) }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func split(_ target: String, defaultPort: Int) -> (String, Int) {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let h = String(target[target.index(after: target.startIndex)..<close])
            return (h, Int(target[target.index(after: close)...].dropFirst()) ?? defaultPort)
        }
        if let c = target.lastIndex(of: ":"), let p = Int(target[target.index(after: c)...]) {
            return (String(target[..<c]), p)
        }
        return (target, defaultPort)
    }
}

/// One request from the guest (plaintext: after the TLS handler, or a plain
/// HTTP request), read whole, then rewritten and sent on (RequestReader.forward).
// @port-skip linux-only: HTTPMitmConnection.driveTLS's request phase on NIO
final class RequestReader: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let proxy: MitmProxy
    let profileID: UUID
    let host: String
    let port: Int
    let tls: Bool
    private var buf = ByteBuffer()
    private var started = false
    /// After the request went upstream: the guest's further bytes (a
    /// WebSocket's frames) go to the upstream channel.
    private var upstream: Channel?
    private var pending: [ByteBuffer] = []

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool) {
        self.proxy = proxy
        self.profileID = profileID
        self.host = host
        self.port = port
        self.tls = tls
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if started {
            if let upstream { upstream.writeAndFlush(b, promise: nil) } else { pending.append(b) }
            return
        }
        buf.writeBuffer(&b)
        switch HTTPRequestFraming.complete(Data(buf.readableBytesView)) {
        case .needMore:
            if buf.readableBytes > MitmProxy.maxBody { reply(context, Self.simple(413, "Payload Too Large")) }
        case .invalid:
            reply(context, Self.simple(400, "Bad Request"))
        case .complete(let request, let extra):
            started = true
            if !extra.isEmpty { pending.append(context.channel.allocator.buffer(bytes: extra)) }
            let loop = context.eventLoop
            let channel = context.channel
            let (proxy, pid, host, port, tls) = (self.proxy, profileID, self.host, self.port, self.tls)
            Task {
                let plan = await Self.rewrite(request, proxy: proxy, profileID: pid, host: host, port: port, tls: tls)
                loop.execute { self.send(plan, channel: channel, host: host, port: port, tls: tls) }
            }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    enum Plan {
        case answer(Data)
        case forward(Data, SubscriptionAuthRewrite.Injected, capture: SignInCapture?, upgrade: Bool)
    }

    /// The request as it goes upstream, or the host's own answer, in
    /// macOS's order: the subscription swaps (5c–5e), the token map's, then
    /// the 5f sign-in capture on what would go out.
    // @port-skip linux-only: the swap order of HTTPMitmConnection.driveTLS (5c–5f, then TokenSwapper)
    static func rewrite(_ raw: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool) async -> Plan {
        var req = origin(raw)
        let head = SubscriptionAuthRewrite.rawHeaderSection(of: req) ?? ""
        let line = head.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        let method = line.first.map(String.init) ?? ""
        let path = line.count > 1 ? String(line[1]) : "/"
        let upgrade = SubscriptionAuthRewrite.headerValue("upgrade", inHeaderSection: head) != nil
        var injected = SubscriptionAuthRewrite.Injected()
        if tls {
            switch await SubscriptionAuthRewrite.apply(rawRequest: req, host: host, method: method, path: path,
                                                       profileID: profileID, spooledBody: false) {
            case .answer(let reply): return .answer(reply)
            case .forward(let r, let i): req = r; injected = i
            }
        }
        req = await proxy.swapper.swap(rawRequest: req, host: host, port: port, profileID: profileID).modified
        // 5f. A sign-in this workspace runs: its token exchange is the host's.
        var capture: SignInCapture?
        if tls, let c = SubscriptionProviders.signInCapture?(profileID),
           let bodyStart = req.range(of: Data("\r\n\r\n".utf8)),
           c.matches(host: host, method: method, path: path, body: req.subdata(in: bodyStart.upperBound..<req.count)) {
            if let sim = c.simulatedReply {
                // The sign-in simulator (e2e): the provider's reply is canned.
                let (status, body) = HTTPRequestFraming.responseStatusAndBody(sim)
                return .answer(await c.handle(status, body) ?? sim)
            }
            capture = c
            // The exchange's reply is read here, not relayed: ask for it
            // uncompressed (nothing here decodes gzip or br).
            req = HTTPRequestFraming.replacingHeaders(req, drop: ["accept-encoding"], add: "Accept-Encoding: identity")
        }
        return .forward(upgrade ? req : closing(req), injected, capture: capture, upgrade: upgrade)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func send(_ plan: Plan, channel: Channel, host: String, port: Int, tls: Bool) {
        switch plan {
        case .answer(let reply):
            write(reply, to: channel, close: true)
        case .forward(let req, let injected, let capture, let upgrade):
            proxy.connectUpstream(host: host, port: port, tls: tls, on: channel.eventLoop).whenComplete { r in
                switch r {
                case .failure(let e):
                    self.write(Self.simple(502, "Bad Gateway", body: "Bromure couldn't reach \(host):\(port): \(e)\n"),
                               to: channel, close: true)
                case .success(let up):
                    let relay = ResponseRelay(guest: channel, profileID: self.profileID, injected: injected,
                                              capture: capture, upgrade: upgrade)
                    up.pipeline.addHandler(relay).whenComplete { _ in
                        self.upstream = up
                        up.write(up.allocator.buffer(bytes: req), promise: nil)
                        for p in self.pending { up.write(p, promise: nil) }
                        self.pending.removeAll()
                        up.flush()
                    }
                }
            }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func write(_ data: Data, to channel: Channel, close: Bool) {
        channel.writeAndFlush(channel.allocator.buffer(bytes: data)).whenComplete { _ in
            if close { channel.close(promise: nil) }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func reply(_ context: ChannelHandlerContext, _ data: Data) {
        started = true
        write(data, to: context.channel, close: true)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func simple(_ status: Int, _ reason: String, body: String = "") -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }

    /// An absolute-form request line (`GET http://h/p HTTP/1.1`) in origin
    /// form, as the origin expects it; anything else as it is.
    // @port-skip linux-only: proxy request-line handling
    static func origin(_ raw: Data) -> Data {
        guard let eol = raw.firstIndex(of: 13) else { return raw }
        let line = String(decoding: raw[raw.startIndex..<eol], as: UTF8.self)
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[1].lowercased().hasPrefix("http://"),
              let url = URL(string: String(parts[1])) else { return raw }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        return Data("\(parts[0]) \(path) \(parts[2])".utf8) + raw[eol...]
    }

    /// The request with `Connection: close` (one request per connection, as
    /// macOS does): any Connection / Keep-Alive / Proxy-Connection header replaced.
    // @port-skip linux-only: proxy request-head handling
    static func closing(_ raw: Data) -> Data {
        HTTPRequestFraming.replacingHeaders(raw, drop: ["connection", "keep-alive", "proxy-connection"],
                                            add: "Connection: close")
    }
}

/// The upstream side: its response streamed to the guest with `Connection:
/// close` in its head (a WebSocket's spliced as it is), or, for a captured
/// sign-in, read whole and answered by the capture. A 401 to a request
/// carrying a live subscription token tells the store (noteUnauthorized).
// @port-skip linux-only: HTTPMitmConnection's response relay on NIO
final class ResponseRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let guest: Channel
    let profileID: UUID
    let injected: SubscriptionAuthRewrite.Injected
    let capture: SignInCapture?
    let upgrade: Bool
    private var head = ByteBuffer()
    private var headDone = false
    private var whole = Data()

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(guest: Channel, profileID: UUID, injected: SubscriptionAuthRewrite.Injected,
         capture: SignInCapture?, upgrade: Bool) {
        self.guest = guest
        self.profileID = profileID
        self.injected = injected
        self.capture = capture
        self.upgrade = upgrade
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if capture != nil {
            whole.append(contentsOf: b.readableBytesView)
            return
        }
        if headDone || upgrade {
            headDone = true
            guest.write(b, promise: nil)
            return
        }
        head.writeBuffer(&b)
        guard let end = head.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if head.readableBytes > 64 << 10 { context.close(promise: nil) }
            return
        }
        headDone = true
        let all = Data(head.readableBytesView)
        let split = end.upperBound - head.readerIndex
        let h = HTTPRequestFraming.replacingHeaders(Data(all.prefix(split)),
                                                    drop: ["connection", "keep-alive"], add: "Connection: close")
        noteStatus(h)
        guest.write(guest.allocator.buffer(bytes: h + all.dropFirst(split)), promise: nil)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelReadComplete(context: ChannelHandlerContext) { guest.flush() }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        if let capture {
            let raw = whole
            let (status, body) = HTTPRequestFraming.responseStatusAndBody(raw)
            noteStatus(raw)
            let guest = self.guest
            let encoded = Self.isEncoded(raw)
            Task {
                let kept = encoded ? nil : await capture.handle(status, body)
                // A successful exchange the host didn't keep never reaches
                // the guest: its real tokens would. (A pending device-code
                // poll or an error isn't a 200, and passes through.)
                let reply: Data
                if let kept {
                    reply = kept
                } else if status == 200 {
                    reply = SignInCapture.response(status: 400, reason: "Bad Request", json: [
                        "error": "bromure_not_kept",
                        "error_description": "Bromure couldn't keep this sign-in on the host, so it wasn't saved and nothing was passed to the workspace. Sign in again from the session's card.",
                    ])
                } else {
                    reply = raw
                }
                FileHandle.standardError.write(Data(
                    "[mitm] sign-in exchange → \(status), \(kept != nil ? "kept on the host" : status == 200 ? "NOT kept\(encoded ? " (encoded reply)" : ""): refused to the guest" : "passed through")\n".utf8))
                guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in guest.close(promise: nil) }
            }
            return
        }
        guest.writeAndFlush(guest.allocator.buffer(capacity: 0)).whenComplete { _ in self.guest.close(promise: nil) }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// Whether a response's body is content-encoded (gzip, br, …).
    // @port-skip linux-only: proxy response parsing
    static func isEncoded(_ raw: Data) -> Bool {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        let ce = HTTPRequestFraming.headers(head)["content-encoding"]?.lowercased() ?? "identity"
        return !ce.isEmpty && ce != "identity"
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func noteStatus(_ head: Data) {
        guard HTTPRequestFraming.responseStatusAndBody(head).status == 401 else { return }
        SubscriptionAuthRewrite.noteUnauthorized(injected, response: head, profileID: profileID)
    }
}
