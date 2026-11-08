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
    /// Connections that have ended (the proxy closed its side).
    let closed = NIOLockedValueBox(0)
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(host: String, reply: String) throws {
        let (received, closed) = (self.received, self.closed)
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(received, reply, closed: closed)) }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let received: NIOLockedValueBox<String>
        let reply: String
        let closed: NIOLockedValueBox<Int>?
        var answered = false
        init(_ r: NIOLockedValueBox<String>, _ reply: String, closed: NIOLockedValueBox<Int>? = nil) {
            received = r; self.reply = reply; self.closed = closed
        }
        func channelInactive(context: ChannelHandlerContext) {
            closed?.withLockedValue { $0 += 1 }
            context.fireChannelInactive()
        }
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

    /// A 100 Continue on a plain request reaches the guest once, ahead of
    /// the final head, which alone carries the Connection: close.
    @Test func aContinueGoesAheadOfTheFinalHeadOnce() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        let out = try Self.talk(rig.path(), "POST http://\(h)/x HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n")
        #expect(out.components(separatedBy: "HTTP/1.1 100 Continue").count == 2, "once: \(out)")
        let heads = out.components(separatedBy: "\r\n\r\n")
        #expect(heads.count >= 2 && heads[0] == "HTTP/1.1 100 Continue", "first: \(out)")
        let final = heads.count >= 2 ? heads[1] : ""
        #expect(final.hasPrefix("HTTP/1.1 200 OK") && final.contains("Connection: close") && !final.contains("keep-alive"), "\(final)")
        #expect(!heads[0].contains("Connection"), "the interim head as it came")
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
        let refused = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\n"
                                    + "POST http://\(h)/smuggled HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n",
                                    then: "POST http://\(h)/later HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n")
        #expect(refused.hasPrefix("HTTP/1.1 200") && refused.contains("Connection: close\r\n"),
                "the guest is told the connection is done (it would wait on it otherwise): \(refused.prefix(120))")
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
        // Relayed after the guest's last read returned: waited for (a loaded
        // machine takes longer than the read's quiet period).
        let deadline = Date().addingTimeInterval(5)
        while !yes.received.withLockedValue({ $0 }).contains("FRAME-AFTER-101"), Date() < deadline { usleep(20_000) }
        seen = yes.received.withLockedValue { $0 }
        #expect(out.hasPrefix("HTTP/1.1 101"), "\(out.prefix(80))")
        #expect(seen.contains("EARLY-FRAME"), "the frame held for the 101 went up: \(seen)")
        #expect(seen.contains("FRAME-AFTER-101"), "the upgraded stream's bytes went up: \(seen)")
    }

    /// A response the guest doesn't read is read from the upstream no faster
    /// than the guest takes it (not all into the proxy's memory).
    @Test func aResponseIsReadNoFasterThanTheGuestTakesIt() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        // The upstream: answers with a 256 MiB body, counting what its
        // (blocking, 1 s send timeout) socket gets to send.
        let srv = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var one: Int32 = 1
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sin = sockaddr_in(); sin.sin_family = sa_family_t(AF_INET); sin.sin_port = 0
        inet_pton(AF_INET, ip, &sin.sin_addr)
        _ = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(srv, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
        let port = Int(UInt16(bigEndian: sin.sin_port))
        let sent = NIOLockedValueBox(0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            let c = accept(srv, nil, nil)
            guard c >= 0 else { return }
            defer { close(c) }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = recv(c, &buf, buf.count, 0)
            let head = "HTTP/1.1 200 OK\r\nContent-Length: \(256 << 20)\r\n\r\n"
            _ = head.withCString { send(c, $0, strlen($0), Int32(MSG_NOSIGNAL)) }
            let chunk = [UInt8](repeating: 0x41, count: 65536)
            while sent.withLockedValue({ $0 }) < 256 << 20 {
                let n = chunk.withUnsafeBytes { send(c, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                if n <= 0 { break }       // the send timeout: the proxy stopped reading
                sent.withLockedValue { $0 += n }
            }
        }
        defer { close(srv) }
        // The guest asks, reads nothing for a while.
        let fd = try ProxyEgressPolicyTests.connectUDS(rig.path())
        defer { close(fd) }
        GuestEnd.send(fd, "GET http://\(ip):\(port)/big HTTP/1.1\r\nHost: \(ip):\(port)\r\n\r\n")
        _ = done.wait(timeout: .now() + 20)
        #expect(sent.withLockedValue { $0 } < 64 << 20, "the proxy stopped reading the upstream: \(sent.withLockedValue { $0 } >> 20) MiB went out")
    }

    /// h2c isn't offered: the request goes up as plain HTTP/1.1, closing.
    @Test func anH2cUpgradeIsServedAsHTTP11() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        _ = try Self.talk(rig.path(), "GET http://\(h)/ HTTP/1.1\r\nHost: \(h)\r\nConnection: Upgrade, HTTP2-Settings\r\n"
                          + "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n")
        let seen = up.received.withLockedValue { $0 }.lowercased()
        #expect(seen.contains("get / ") && !seen.contains("upgrade: h2c") && !seen.contains("http2-settings")
                && seen.contains("connection: close"), "\(seen)")
    }

    /// An interim answer (100 Continue) before an upgrade's 101 isn't a refusal.
    @Test func a100BeforeThe101IsntARefusal() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        let out = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\nEARLY", then: "LATER")
        let seen = up.received.withLockedValue { $0 }
        #expect(out.hasPrefix("HTTP/1.1 100") && out.contains("HTTP/1.1 101"), "\(out.prefix(160))")
        #expect(seen.contains("EARLY") && seen.contains("LATER"), "the stream opened after the 101: \(seen)")
    }

    /// Only websocket is offered: other tokens go, across every Upgrade header.
    @Test func onlyWebSocketIsOfferedAsAnUpgrade() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        _ = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\nConnection: Upgrade\r\nUpgrade: h2c, websocket\r\nUpgrade: foo\r\n"
                          + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
        let seen = up.received.withLockedValue { $0 }.lowercased()
        #expect(seen.contains("upgrade: websocket") && !seen.contains("h2c") && !seen.contains("foo"), "\(seen)")
        let plain = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { plain.stop() }
        let h2 = "\(ip):\(plain.port)"
        _ = try Self.talk(rig.path(), "GET http://\(h2)/ HTTP/1.1\r\nHost: \(h2)\r\nConnection: Upgrade\r\nUpgrade: foo/1\r\n\r\n")
        let seen2 = plain.received.withLockedValue { $0 }.lowercased()
        #expect(!seen2.contains("upgrade:") && seen2.contains("connection: close"), "no websocket token: plain HTTP/1.1: \(seen2)")
    }

    /// Several interim answers (100, 103, 100) before the 101.
    @Test func severalInterimAnswersBeforeThe101() throws {
        let (rig, ip) = try Self.rig(); defer { rig.stop() }
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n"
                                 + "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        defer { up.stop() }
        let h = "\(ip):\(up.port)"
        let out = try Self.talk(rig.path(), "GET http://\(h)/ws HTTP/1.1\r\nHost: \(h)\r\n\(ws)\r\nEARLY", then: "LATER")
        #expect(out.contains("103 Early Hints") && out.contains("HTTP/1.1 101"), "\(out.prefix(240))")
        let seen = up.received.withLockedValue { $0 }
        #expect(seen.contains("EARLY") && seen.contains("LATER"), "\(seen)")
    }
}
