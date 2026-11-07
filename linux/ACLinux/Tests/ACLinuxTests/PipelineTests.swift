import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux

/// An upstream that records every byte each connection sends, answers the
/// first request head with `reply`, and stays open (so whatever a proxy
/// sends after the first request shows up).
final class RawUpstream: @unchecked Sendable {
    let received = NIOLockedValueBox<String>("")
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(host: String, reply: String) throws {
        let received = self.received
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(received, reply)) }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let received: NIOLockedValueBox<String>
        let reply: String
        var answered = false
        init(_ r: NIOLockedValueBox<String>, _ reply: String) { received = r; self.reply = reply }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            let s = b.readString(length: b.readableBytes) ?? ""
            let all = received.withLockedValue { $0 += s; return $0 }
            if !answered, all.contains("\r\n\r\n") {
                answered = true
                context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: reply)), promise: nil)
            }
        }
    }
}

/// One request per proxied connection: a request pipelined behind the
/// first never leaves (it would skip the rules, the guardrails and the
/// swap), and an upgrade's bytes go up only once the upstream switched.
@Suite("Proxy: one request per connection", .serialized)
struct PipelineTests {
    static func rig() throws -> (ProxyEgressPolicyTests.Rig, String) {
        (try ProxyEgressPolicyTests.Rig(), try #require(Daemon.primaryIPv4()))
    }

    /// The guest's end: connect, send, read for `ms`, then send `more` and read again.
    static func talk(_ path: String, _ first: String, then more: String? = nil, ms: Int32 = 1500) throws -> String {
        let fd = try ProxyEgressPolicyTests.connectUDS(path)
        defer { close(fd) }
        func read() -> String {
            var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while poll(&p, 1, ms) > 0 {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out += buf[0..<n]
            }
            return String(decoding: out, as: UTF8.self)
        }
        GuestEnd.send(fd, first)
        var got = read()
        if let more { GuestEnd.send(fd, more); got += read() }
        return got
    }

    @Test func aRequestPipelinedBehindAnotherNeverLeaves() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        let out = try Self.talk(rig.path(), "GET http://\(h)/first HTTP/1.1\r\nHost: \(h)\r\n\r\n"
                                + "POST http://\(h)/second HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 4\r\n\r\nevil",
                                then: "DELETE http://\(h)/third HTTP/1.1\r\nHost: \(h)\r\n\r\n")
        let seen = up.received.withLockedValue { $0 }
        #expect(out.hasPrefix("HTTP/1.1 200"), "the first is answered: \(out.prefix(80))")
        #expect(seen.contains("GET /first"), "\(seen)")
        #expect(!seen.contains("second") && !seen.contains("evil") && !seen.contains("third"), "nothing behind it went up: \(seen)")
        #expect(seen.contains("Connection: close"), "the first went up as the only one")
    }

    @Test func anUpgradesBytesGoUpOnlyAfterA101() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        // Refused (a 200, not a 101): what follows the request stays here.
        let no = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno")
        defer { no.stop() }
        var h = "\(ip):\(no.port)"
        _ = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\n"
                          + "POST http://\(h)/smuggled HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n",
                          then: "POST http://\(h)/later HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n")
        var seen = no.received.withLockedValue { $0 }
        #expect(seen.contains("GET /ws"), "\(seen)")
        #expect(!seen.contains("smuggled") && !seen.contains("later"), "nothing after a refused upgrade: \(seen)")
        // Accepted (a 101): the frames that follow go up.
        let yes = try RawUpstream(host: ip, reply: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        defer { yes.stop() }
        h = "\(ip):\(yes.port)"
        // A frame sent with the request is held until the 101, then goes up.
        let out = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\nEARLY-FRAME",
                                then: "FRAME-AFTER-101")
        seen = yes.received.withLockedValue { $0 }
        #expect(out.hasPrefix("HTTP/1.1 101"), "\(out.prefix(80))")
        #expect(seen.contains("EARLY-FRAME"), "the frame held for the 101 went up: \(seen)")
        #expect(seen.contains("FRAME-AFTER-101"), "the upgraded stream's bytes went up: \(seen)")
    }
}
