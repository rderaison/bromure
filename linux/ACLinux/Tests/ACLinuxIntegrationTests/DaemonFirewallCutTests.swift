import Foundation
import NIOCore
import NIOPosix
import Testing
import ACLinux

/// A slow download on the host's LAN address (the guest reaches it through
/// the daemon's proxy; nothing leaves the machine): a 100 MiB body, 64 KiB
/// every 50 ms, so a transfer is under way when the test cuts it.
final class SlowDownload: @unchecked Sendable {
    let channel: Channel
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    let connections = Counter()
    var port: Int { channel.localAddress!.port! }

    init(host: String) throws {
        let connections = self.connections
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                connections.bump()
                return ch.pipeline.addHandler(Handler())
            }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        var seen = Data(), started = false
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            seen += Data(unwrapInboundIn(data).readableBytesView)
            guard !started, seen.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
            started = true
            let ch = context.channel
            ch.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 104857600\r\n\r\n"), promise: nil)
            let chunk = ByteBuffer(repeating: 0x61, count: 64 << 10)
            ch.eventLoop.scheduleRepeatedTask(initialDelay: .milliseconds(50), delay: .milliseconds(50)) { task in
                guard ch.isActive else { task.cancel(); return }
                ch.writeAndFlush(chunk, promise: nil)
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

extension DaemonTests {
    @Test("a firewall cut of a proxied download resets the guest's client (curl rc 56), not a short transfer's clean end (rc 18)")
    func firewallCutResetsTheClient() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let ip = try #require(hostLANAddress(), "a host LAN address")
        let server = try SlowDownload(host: ip)
        defer { server.stop() }

        #expect(try w.cli("vm", "run", "--name", "fc").0 == 0)
        let id = try #require(w.vm("fc")?["id"]?.stringValue)
        var up = false
        for _ in 0..<240 where !up {
            up = (try? w.cli("vm", "exec", "fc", "--", "true"))?.0 == 0
            if !up { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(up)
        // The download through agentd's proxy bridge, in the background; its
        // exit status lands in a file.
        let url = "http://\(ip):\(server.port)/big"
        _ = try w.cli("vm", "exec", "fc", "--", "sh", "-c",
                      "setsid sh -c 'curl -sS -x http://127.0.0.1:65534 -o /dev/null \(url); echo $? > /tmp/fc-rc' >/dev/null 2>&1 < /dev/null &")
        for _ in 0..<100 where server.connections.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.connections.value > 0, "the download reached the host")
        try await Task.sleep(for: .seconds(1))
        // The firewall now denies the host: the proxy cuts the flow.
        let api = FirecrackerAPI(socketPath: w.socket)
        let r = try await api.request("POST", "/profiles/\(id)/firewall", ["rules": .string("deny tcp \(ip)\ndefault allow")])
        #expect(r.status == 200, "\(r.body ?? .null)")
        var rc = ""
        for _ in 0..<60 where rc.isEmpty {
            rc = (try? w.cli("vm", "exec", "fc", "--", "cat", "/tmp/fc-rc"))?.1.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if rc.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(rc == "56", "curl saw a reset (56), not a clean short end (18): \(rc)")
        _ = try w.cli("vm", "kill", "--force", "fc")
    }
}
