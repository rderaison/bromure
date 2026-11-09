import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux

/// Which upgrades the proxy pumps (macOS 4477b665's rule): exactly one
/// Upgrade header naming only websocket or SPDY/3.1 (kubectl exec / attach /
/// port-forward), in a clean header block; anything else (h2c above all)
/// goes on as plain HTTP/1.1 with Upgrade, Connection and HTTP2-Settings
/// dropped, under the per-request policy.
@Suite("Upgrade filter")
struct UpgradeFilterTests {
    static let host = "api.cluster.example.test"

    static func plan(_ headers: String) async throws -> (out: String, upgrade: Bool) {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        var trace: RequestReader.Trace?
        let req = "GET /api/v1/namespaces/default/pods/p/exec?command=sh HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\n\(headers)\r\n"
        guard case .forward(let out, _, _, let upgrade, _, _, _, _, _, _, _, _, _) =
                await RequestReader.rewrite(Data(req.utf8), proxy: proxy, profileID: pid, host: host, port: 443,
                                            tls: true, session: proxy.strictSession(of: pid), trace: &trace) else {
            Issue.record("not forwarded"); return ("", false)
        }
        return (String(decoding: out, as: UTF8.self), upgrade)
    }

    static func upgradeHeaders(_ out: String) -> [String] {
        out.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("upgrade:") }
    }

    @Test func webSocketPasses() async throws {
        let r = try await Self.plan("Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")
        #expect(r.upgrade)
        #expect(Self.upgradeHeaders(r.out).map { $0.lowercased() } == ["upgrade: websocket"])
    }

    @Test func spdyPasses() async throws {
        let r = try await Self.plan("Upgrade: SPDY/3.1\r\nX-Stream-Protocol-Version: v4.channel.k8s.io\r\n")
        #expect(r.upgrade, "kubectl's SPDY stream is switched")
        #expect(Self.upgradeHeaders(r.out) == ["Upgrade: SPDY/3.1"])
        // Offered beside h2c: not pumped at all (the block would still offer h2c).
        let mixed = try await Self.plan("Upgrade: h2c, SPDY/3.1\r\nHTTP2-Settings: AAMAAABkAAQAAP__\r\n")
        #expect(!mixed.upgrade && Self.upgradeHeaders(mixed.out).isEmpty)
        #expect(!mixed.out.lowercased().contains("http2-settings"))
    }

    @Test func h2cIsStrippedToPlainHTTP() async throws {
        let r = try await Self.plan("Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAAQAAP__\r\n")
        #expect(!r.upgrade, "served as plain HTTP/1.1")
        #expect(Self.upgradeHeaders(r.out).isEmpty)
        #expect(!r.out.lowercased().contains("http2-settings") && !r.out.contains("Connection: Upgrade"))
        // HTTP2-Settings alone (no Upgrade): dropped too.
        let settings = try await Self.plan("HTTP2-Settings: AAMAAABkAAQAAP__\r\n")
        #expect(!settings.upgrade && !settings.out.lowercased().contains("http2-settings"))
    }

    @Test func anUnknownTokenIsStripped() async throws {
        let r = try await Self.plan("Upgrade: example-proto/2\r\n")
        #expect(!r.upgrade && Self.upgradeHeaders(r.out).isEmpty)
        // A second Upgrade header beside WebSocket: not pumped.
        let mixed = try await Self.plan("Upgrade: example-proto/2\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")
        #expect(!mixed.upgrade && Self.upgradeHeaders(mixed.out).isEmpty)
    }

    @Test("the pump's rule, as macOS's pumpedUpgrade: one Upgrade header, websocket / SPDY/3.1 only, no fold, no bare CR, LF or NUL")
    func pumpedUpgrade() {
        func ok(_ headers: String) -> Bool { ResponseRelay.pumpedUpgrade(headerBlock: "GET / HTTP/1.1\r\nHost: h\r\n" + headers) }
        #expect(ok("Upgrade: websocket"))
        #expect(ok("Upgrade: SPDY/3.1"))
        #expect(ok("upgrade:  WebSocket , spdy/3.1"))
        #expect(!ok("Upgrade: h2c"))
        #expect(!ok("Upgrade: websocket, h2c"))
        #expect(!ok("Upgrade: websocket\r\nUpgrade: websocket"), "a second Upgrade header")
        #expect(!ok("Upgrade: websocket\r\n h2c"), "a folded continuation")
        #expect(!ok("Upgrade: websocket\r\nX-A: 1\rUpgrade: h2c"), "a bare CR")
        #expect(!ok("Upgrade: websocket\r\nX-A: 1\nUpgrade: h2c"), "a bare LF")
        #expect(!ok("Upgrade: websocket\r\nX-A: 1\0"), "a NUL")
        #expect(!ok("Connection: Upgrade"), "no Upgrade header")
        // A 101's head the same way.
        #expect(ResponseRelay.pumpedUpgrade(headerBlock: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade"))
        #expect(!ResponseRelay.pumpedUpgrade(headerBlock: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade"))
    }

    @Test func onlyAWebSocketSwitchIsReadAsFrames() {
        #expect(ResponseRelay.switchedToWebSocket(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8)))
        #expect(!ResponseRelay.switchedToWebSocket(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: SPDY/3.1\r\n\r\n".utf8)))
    }
}

@Suite("Proxy preamble")
struct ProxyPreambleTests {
    @Test("the bridge's BROMURE-CLIENT line names its client's port, when well formed (macOS: stripClientPreamble)")
    func sport() {
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1 sport=43210 peer=127.0.0.1") == 43210)
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1 peer=127.0.0.1 sport=1") == 1)
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1 sport=0") == nil)
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1 sport=65536") == nil)
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1 sport=x") == nil)
        #expect(ConnectHandler.preambleSport("BROMURE-CLIENT 1") == nil)
    }
}

/// Through the proxy, against a real upstream: a 101 to another protocol is
/// refused (502), and a body past the 8 MiB inline cap is streamed whole
/// (macOS: 5z), its head still swapped.
@Suite("Proxy: switched protocols and streamed bodies", .serialized)
struct ProxyStreamingTests {
    @Test func a101ToAnotherProtocolIsA502() throws {
        let (rig, ip) = try PipelineTests.rig(); defer { rig.stop() }
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        let h2c = try RawUpstream(host: ip, reply: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\n")
        defer { h2c.stop() }
        var h = "\(ip):\(h2c.port)"
        let out = try PipelineTests.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\n", ms: 800)
        #expect(out.hasPrefix("HTTP/1.1 502 Bad Gateway"), "\(out.prefix(120))")
        #expect(!out.contains("101"), "the switch isn't relayed")
        // A plain request answered with a 101: refused the same way.
        let sneaky = try RawUpstream(host: ip, reply: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        defer { sneaky.stop() }
        h = "\(ip):\(sneaky.port)"
        let plain = try PipelineTests.talk(rig.path(), "GET http://\(h)/x HTTP/1.1\r\nHost: \(h)\r\n\r\n", ms: 800)
        #expect(plain.hasPrefix("HTTP/1.1 502 Bad Gateway"), "\(plain.prefix(120))")
    }

    @Test func aLargeBodyIsStreamedWholeItsHeadSwapped() throws {
        let (rig, ip) = try PipelineTests.rig(); defer { rig.stop() }
        let size = 9 << 20
        let up = try CountingUpstream(host: ip, answerAfter: size)
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        let fake = "brm-standin-for-the-streaming-test"
        rig.proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "the-real-registry-token", host: ip)]), for: rig.pid)
        let body = String(repeating: "0123456789abcdef", count: size / 16)
        let out = try PipelineTests.talk(rig.path(), "PUT http://\(h)/v2/blobs/uploads/1 HTTP/1.1\r\nHost: \(h)\r\n"
                                         + "Authorization: Bearer \(fake)\r\nContent-Length: \(size)\r\n\r\n" + body, ms: 3000)
        #expect(out.hasPrefix("HTTP/1.1 201"), "\(out.prefix(120))")
        let (head, count) = up.seen.withLockedValue { $0 }
        #expect(count == size, "every byte of the body went up: \(count)")
        #expect(head.contains("Bearer the-real-registry-token") && !head.contains(fake), "the head was swapped")
    }
}

/// An upstream that keeps the first request's head, counts the body bytes
/// after it, and answers 201 once `answerAfter` of them arrived.
final class CountingUpstream: @unchecked Sendable {
    let seen = NIOLockedValueBox<(head: String, body: Int)>(("", 0))
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(host: String, answerAfter: Int) throws {
        let seen = self.seen
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(seen, answerAfter)) }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let seen: NIOLockedValueBox<(head: String, body: Int)>
        let answerAfter: Int
        var headBytes = Data(), inBody = false, answered = false
        init(_ seen: NIOLockedValueBox<(head: String, body: Int)>, _ answerAfter: Int) { self.seen = seen; self.answerAfter = answerAfter }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let b = unwrapInboundIn(data)
            var bytes = Data(b.readableBytesView)
            if !inBody {
                headBytes += bytes
                guard let end = headBytes.range(of: Data("\r\n\r\n".utf8)) else { return }
                inBody = true
                bytes = headBytes.subdata(in: end.upperBound..<headBytes.endIndex)
                let head = String(decoding: headBytes[..<end.lowerBound], as: UTF8.self)
                seen.withLockedValue { $0.head = head }
            }
            let total = seen.withLockedValue { $0.body += bytes.count; return $0.body }
            if !answered, total >= answerAfter {
                answered = true
                context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
                    string: "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")), promise: nil)
            }
        }
    }
}
