import Crypto
import Foundation
import MitmCore
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import SwiftASN1
import X509

// mitm-bench upstream   --listen IP:PORT --dir DIR          TLS HTTP/1.1 origin (*.bench.test), CA in DIR/upstream-ca.pem
// mitm-bench handshakes --target IP:PORT [--proxy IP:PORT] --ca PEM --sni unique|same --conns N --seconds S
// mitm-bench latency    --target IP:PORT [--proxy IP:PORT] --ca PEM --requests N
// mitm-bench throughput --target IP:PORT [--proxy IP:PORT] --ca PEM --bytes N
// mitm-bench multipart  --target IP:PORT [--proxy IP:PORT] --ca PEM
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func hostPort(_ s: String) -> (String, Int) {
    let c = s.lastIndex(of: ":")!
    return (String(s[..<c]), Int(s[s.index(after: c)...])!)
}
let group = MultiThreadedEventLoopGroup.singleton

// MARK: origin

final class Origin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    var uri = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): uri = h.uri
        case .body: break
        case .end:
            if uri.hasPrefix("/big") {
                let n = Int(uri.split(separator: "=").last ?? "0") ?? 0
                var head = HTTPResponseHead(version: .http1_1, status: .ok)
                head.headers.add(name: "Content-Length", value: "\(n)")
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                sendBig(context: context, remaining: n, chunk: context.channel.allocator.buffer(repeating: 0x61, count: 1 << 16))
            } else if uri.hasPrefix("/stream") {
                var head = HTTPResponseHead(version: .http1_1, status: .ok)
                head.headers.add(name: "Content-Type", value: "multipart/x-mixed-replace; boundary=frame")
                head.headers.add(name: "Connection", value: "close")
                context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
                for i in 0..<5 {
                    context.eventLoop.scheduleTask(in: .milliseconds(Int64(200 * i))) {
                        let part = "--frame\r\nContent-Type: text/plain\r\n\r\npart \(i)\r\n"
                        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: part)))), promise: nil)
                        if i == 4 { context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) } }
                    }
                }
            } else {
                var head = HTTPResponseHead(version: .http1_1, status: .ok)
                head.headers.add(name: "Content-Length", value: "2")
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: "ok")))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
    func sendBig(context: ChannelHandlerContext, remaining: Int, chunk: ByteBuffer) {
        if remaining <= 0 { context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil); return }
        let n = min(remaining, chunk.readableBytes)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(chunk.getSlice(at: 0, length: n)!)))).whenSuccess {
            self.sendBig(context: context, remaining: remaining - n, chunk: chunk)
        }
    }
}

func runOrigin() throws {
    let (h, p) = hostPort(opt("--listen")!)
    let dir = opt("--dir")!
    let ca = try CertificateAuthority.generate(commonName: "Bench Upstream CA")
    try ca.certificatePEM.write(toFile: dir + "/upstream-ca.pem", atomically: true, encoding: .utf8)
    // One wildcard leaf for every *.bench.test SNI the bench uses.
    let (leaf, key) = try ca.mintLeaf(host: "*.bench.test")
    var cfg = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(leaf)], privateKey: .privateKey(key))
    cfg.applicationProtocols = ["http/1.1"]
    let ctx = try NIOSSLContext(configuration: cfg)
    let ch = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .serverChannelOption(.backlog, value: 1024)
        .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
        .childChannelInitializer { ch in
            ch.eventLoop.makeCompletedFuture {
                try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: ctx))
                try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                try ch.pipeline.syncOperations.addHandler(Origin())
            }
        }
        .bind(host: h, port: p).wait()
    print("origin on \(ch.localAddress!)")
    fflush(stdout)
    try ch.closeFuture.wait()
}

// MARK: client

/// Sends CONNECT and holds back channelActive (so TLS starts) until 200.
final class ConnectClient: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    let target: String
    var buf = ByteBuffer()
    init(target: String) { self.target = target }
    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        buf.writeBuffer(&b)
        guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
        let head = buf.readString(length: end.upperBound - buf.readerIndex) ?? ""
        guard head.hasPrefix("HTTP/1.1 200") else {
            context.fireErrorCaught(ChannelError.connectTimeout(.zero))
            context.close(promise: nil)
            return
        }
        context.fireChannelActive()
        if buf.readableBytes > 0 { context.fireChannelRead(NIOAny(buf)) }
        context.pipeline.removeHandler(self, promise: nil)
    }
}

/// Parses HTTP/1.1 responses by Content-Length (or to EOF), counting bytes.
final class Reader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    struct Waiter { let promise: EventLoopPromise<Int>; let onChunk: ((ByteBuffer) -> Void)? }
    var waiters: [Waiter] = []
    var buf = ByteBuffer()
    var inBody = false, remaining = -1, total = 0
    func expect(on el: EventLoop, onChunk: ((ByteBuffer) -> Void)? = nil) -> EventLoopFuture<Int> {
        let p = el.makePromise(of: Int.self)
        waiters.append(.init(promise: p, onChunk: onChunk))
        return p.futureResult
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        buf.writeBuffer(&b)
        process()
    }
    func process() {
        while let w = waiters.first {
            if !inBody {
                guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
                let head = buf.readString(length: end.upperBound - buf.readerIndex) ?? ""
                remaining = -1
                for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    remaining = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? -1
                }
                inBody = true
                total = 0
            }
            let take = remaining < 0 ? buf.readableBytes : min(remaining, buf.readableBytes)
            if take > 0 {
                let chunk = buf.readSlice(length: take)!
                w.onChunk?(chunk)
                total += take
                if remaining > 0 { remaining -= take }
            }
            buf.discardReadBytes()
            if remaining == 0 {
                inBody = false
                waiters.removeFirst()
                w.promise.succeed(total)
                continue
            }
            return
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        for w in waiters { if remaining < 0 && inBody { w.promise.succeed(total) } else { w.promise.fail(ChannelError.ioOnClosedChannel) } }
        waiters = []
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        for w in waiters { w.promise.fail(error) }
        waiters = []
        context.close(promise: nil)
    }
}

struct Client {
    let channel: Channel
    let reader: Reader
    let host: String
    func get(_ path: String, onChunk: ((ByteBuffer) -> Void)? = nil) async throws -> Int {
        let f: EventLoopFuture<Int> = channel.eventLoop.flatSubmit {
            let r = reader.expect(on: channel.eventLoop, onChunk: onChunk)
            channel.writeAndFlush(channel.allocator.buffer(string: "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"), promise: nil)
            return r
        }
        return try await f.get()
    }
    func close() async { try? await channel.close() }
}

let target = hostPort(opt("--target") ?? "127.0.0.1:19443")
let proxy = opt("--proxy").map(hostPort)
/// Lazy (a static), so `upstream` mode never reads --ca.
enum ClientTLS {
    static let context: NIOSSLContext = {
        var c = TLSConfiguration.makeClientConfiguration()
        c.trustRoots = .certificates(try! NIOSSLCertificate.fromPEMFile(opt("--ca") ?? "ca.pem"))
        c.applicationProtocols = ["h2", "http/1.1"]
        return try! NIOSSLContext(configuration: c)
    }()
}

func connect(sni: String) async throws -> Client {
    let reader = Reader()
    let dial = proxy ?? target
    let ch = try await ClientBootstrap(group: group)
        .channelOption(.tcpOption(.tcp_nodelay), value: 1)
        .channelInitializer { ch in
            ch.eventLoop.makeCompletedFuture {
                if proxy != nil { try ch.pipeline.syncOperations.addHandler(ConnectClient(target: "\(sni):\(target.1)")) }
                try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ClientTLS.context, serverHostname: sni))
                try ch.pipeline.syncOperations.addHandler(reader)
            }
        }
        .connect(host: dial.0, port: dial.1).get()
    return Client(channel: ch, reader: reader, host: sni)
}

func stats(_ xs: [Double]) -> String {
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
    return String(format: "mean %.0f µs, p50 %.0f µs, p99 %.0f µs", s.reduce(0, +) / Double(s.count), q(0.5), q(0.99))
}

func us(_ d: Duration) -> Double { Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12 }

let mode = args.first ?? ""
let via = proxy == nil ? "direct" : "via proxy"
switch mode {
case "upstream":
    try runOrigin()
case "handshakes":
    let conns = Int(opt("--conns") ?? "32")!, seconds = Double(opt("--seconds") ?? "5")!
    let unique = (opt("--sni") ?? "unique") == "unique"
    let counter = NIOLockedValueBox((ok: 0, failed: 0, n: 0))
    let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1000))
    let t0 = ContinuousClock.now
    await withTaskGroup(of: Void.self) { g in
        for _ in 0..<conns {
            g.addTask {
                while ContinuousClock.now < deadline {
                    let i = counter.withLockedValue { s -> Int in s.n += 1; return s.n }
                    let sni = unique ? "h\(i)-r\(t0.hashValue & 0xFFFF).bench.test" : "same.bench.test"
                    do {
                        let c = try await connect(sni: sni)
                        _ = try await c.get("/small")
                        await c.close()
                        counter.withLockedValue { $0.ok += 1 }
                    } catch {
                        counter.withLockedValue { $0.failed += 1 }
                    }
                }
            }
        }
    }
    let el = ContinuousClock.now - t0
    let r = counter.withLockedValue { $0 }
    print(String(format: "HANDSHAKES %@ sni=%@ conns=%d: %.0f/s (%d ok, %d failed in %.1fs; each = TCP + CONNECT + TLS + 1 GET)",
                 via, unique ? "unique" : "same", conns, Double(r.ok) / (us(el) / 1e6), r.ok, r.failed, us(el) / 1e6))
case "latency":
    let n = Int(opt("--requests") ?? "2000")!
    let c = try await connect(sni: "lat.bench.test")
    for _ in 0..<50 { _ = try await c.get("/small") }
    var xs: [Double] = []
    for _ in 0..<n {
        let t = ContinuousClock.now
        _ = try await c.get("/small")
        xs.append(us(ContinuousClock.now - t))
    }
    await c.close()
    print("LATENCY \(via) keep-alive GET /small x\(n): \(stats(xs))")
case "throughput":
    let bytes = Int(opt("--bytes") ?? "1073741824")!
    let c = try await connect(sni: "bulk.bench.test")
    let t = ContinuousClock.now
    let got = try await c.get("/big?bytes=\(bytes)")
    let s = us(ContinuousClock.now - t) / 1e6
    await c.close()
    print(String(format: "THROUGHPUT %@ %ld bytes in %.2fs = %.0f MB/s", via, got, s, Double(got) / s / 1e6))
case "multipart":
    let c = try await connect(sni: "stream.bench.test")
    let t = ContinuousClock.now
    let seen = NIOLockedValueBox<[String]>([])
    _ = try await c.get("/stream") { chunk in
        let s = String(buffer: chunk)
        let parts = s.components(separatedBy: "--frame").count - 1
        if parts > 0 { seen.withLockedValue { $0.append(String(format: "%.0fms", us(ContinuousClock.now - t) / 1000)) } }
    }
    print("MULTIPART \(via) part arrival times: \(seen.withLockedValue { $0 }.joined(separator: " "))")
default:
    print("usage: mitm-bench upstream|handshakes|latency|throughput|multipart …")
}
