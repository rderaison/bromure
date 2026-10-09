import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import bromure_ac

/// The pre-opened spare control channel each fat-client SSH connection keeps:
/// a connection that drops (peer reset, server exit — never `close()`) must
/// not leave its fds behind.
@Suite("Fat client spare control channel")
struct FatClientSpareChannelTests {

    /// Accepts any key; exec channels stay open and silent (the control
    /// bridge never speaks first).
    private final class AcceptAll: NIOSSHServerUserAuthenticationDelegate {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    private final class Silent: ChannelInboundHandler {
        typealias InboundIn = SSHChannelData
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {}
    }

    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var channels: [Channel] = []
        func add(_ c: Channel) { lock.lock(); channels.append(c); lock.unlock() }
        func closeAll() {
            lock.lock(); let all = channels; lock.unlock()
            all.forEach { $0.close(promise: nil) }
        }
    }

    private func startServer(group: EventLoopGroup, accepted: Accepted) throws -> Channel {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        return try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                accepted.add(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: AcceptAll())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(Silent())
                            }
                        }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    @Test("A dropped connection closes its spare and every bridged fd's pump end")
    func dropReleasesFDs() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let accepted = Accepted()
        let server = try startServer(group: group, accepted: accepted)
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)
        let known = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: known) }

        let conn = try SSHConnection(
            host: RemoteHost(name: "test", address: "127.0.0.1", port: port, user: "test"),
            group: group, strictHostKey: false, knownHosts: KnownHostsStore(url: known),
            clientKey: Curve25519.Signing.PrivateKey())
        let fd = try #require(conn.openVerbChannel(FatClient.controlVerb))
        defer { Darwin.close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(conn.heldSpareCount == 1)

        // The peer goes away; nobody calls conn.close().
        accepted.closeAll()

        for _ in 0..<300 where conn.heldSpareCount > 0 { usleep(10_000) }
        #expect(conn.heldSpareCount == 0)
        // The bridged fd's pump end is closed too: the app end reads EOF.
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&p, 1, 3000) == 1)
        var byte: UInt8 = 0
        #expect(Darwin.read(fd, &byte, 1) <= 0)
    }
}
