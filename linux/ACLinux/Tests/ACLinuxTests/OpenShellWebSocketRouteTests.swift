import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SandboxEngine
import Testing
@testable import ACLinux

/// An OpenShell `protocol: websocket` route on the Linux proxy (macOS:
/// driveTLS's upgrade path with ProxyPolicy.webSocketPlan and the pump's
/// ClientStream gate): each client text message is judged before it goes
/// upstream. A GraphQL query passes; a mutation ends the session with a
/// 1008 close and never reaches the upstream; the deflate offer goes up
/// only without client context takeover (a bare offer is dropped).
@Suite("OpenShell WebSocket routes", .serialized)
struct OpenShellWebSocketRouteTests {
    static let yaml = """
    version: 1
    network_policies:
      gql:
        endpoints:
          - host: ws.example
            port: 80
            protocol: websocket
            enforcement: enforce
            rules:
              - allow: { method: GET, path: "/graphql" }
              - allow: { operation_type: query }
    """
    static let upgrade = Data("GET /graphql HTTP/1.1\r\nHost: ws.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n".utf8)

    final class Wire {
        let guest: Int32
        let channel: Channel
        init(proxy: MitmProxy, pid: UUID) async throws {
            var sv: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sv) == 0 else { throw POSIXError(.EIO) }
            guest = sv[0]
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let pinned = [OpenShellPolicy.IPAddress("203.0.113.9")!]
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { $0.pipeline.addHandler(RequestReader(proxy: proxy, profileID: pid, host: "ws.example",
                                                                          port: 80, tls: false, pinned: pinned)) }
                .withConnectedSocket(sv[1]).get()
        }
        func send(_ d: Data) { _ = d.withUnsafeBytes { Glibc.send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) } }
        func read() -> Data {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(guest, &buf, buf.count, 0)
            return n > 0 ? Data(buf[0..<n]) : Data()
        }
        func close() { channel.close(promise: nil); Glibc.close(guest) }
    }

    static func message(_ query: String, id: String) -> Data {
        WSFrame.encode(opcode: WSFrame.text, payload: Data(#"{"type":"subscribe","id":"\#(id)","payload":{"query":"\#(query)"}}"#.utf8),
                       masked: true)
    }

    @Test func aQueryPassesAndAMutationEndsTheSession() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                   egressPolicy: EgressPolicy(openShell: try OpenShellPolicy.parse(Self.yaml))),
                                  for: pid)
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let up = try WSUpstream(host: ip)
        defer { up.stop() }
        proxy.routeAllTo = (ip, up.port)
        let w = try await Wire(proxy: proxy, pid: pid)
        defer { w.close() }

        w.send(Self.upgrade)
        let head = String(decoding: w.read(), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 101"), "\(head)")
        let upHead = up.head.withLockedValue { $0 }.lowercased()
        // A bare offer (context takeover allowed) isn't forwarded: each client
        // message must inflate on its own to be judged.
        #expect(!upHead.contains("sec-websocket-extensions"), "\(upHead)")

        let query = Self.message("query { viewer }", id: "1")
        w.send(query)
        for _ in 0..<300 where up.frames.withLockedValue({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(up.frames.withLockedValue { $0 } == [query], "the query went up as sent")

        w.send(Self.message("mutation { del }", id: "2"))
        let close = w.read()
        // A close frame (opcode 8) with code 1008 and the policy's reason.
        #expect(close.first == 0x88, "\(Array(close.prefix(4)))")
        #expect(close.count > 4 && close[close.startIndex + 2] == 0x03 && close[close.startIndex + 3] == 0xF0, "1008")
        #expect(String(decoding: close.dropFirst(4), as: UTF8.self).contains("mutation"))
        #expect(w.read().isEmpty, "then the session ends")
        try await Task.sleep(for: .milliseconds(100))
        #expect(up.frames.withLockedValue { $0 } == [query], "the mutation never went up")
    }

    /// No OpenShell WebSocket route: the socket's frames pass as before.
    @Test func elsewhereTheSocketIsUntouched() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        let ip = try #require(Daemon.primaryIPv4())
        let up = try WSUpstream(host: ip)
        defer { up.stop() }
        proxy.routeAllTo = (ip, up.port)
        let w = try await Wire(proxy: proxy, pid: pid)
        defer { w.close() }
        w.send(Self.upgrade)
        #expect(String(decoding: w.read(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        let m = Self.message("mutation { del }", id: "3")
        w.send(m)
        for _ in 0..<300 where up.frames.withLockedValue({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(up.frames.withLockedValue { $0 } == [m])
    }
}
