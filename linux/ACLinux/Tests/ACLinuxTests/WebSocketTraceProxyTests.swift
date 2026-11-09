import Foundation
import Glibc
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// A WebSocket through the Linux proxy with the workspace traced: one trace
/// record at the close, the handshake and both directions' messages its
/// response body (macOS: emitWebSocketTrace), not the upstream's raw frames.
@Suite("WebSocket traces through the proxy", .serialized)
struct WebSocketTraceProxyTests {
    @Test @MainActor func aTracedSocketIsRecordedWithItsMessages() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        proxy.setUpTraceStore(rootDir: URL(fileURLWithPath: dir + "/traces", isDirectory: true))
        let pid = UUID()
        proxy.setSessionTrace(TraceSession(sessionID: UUID(), level: .all), for: pid)
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let up = try WSUpstream(host: ip, reply: { payload in
            _ = payload; return [WSFrame.encode(opcode: WSFrame.text, payload: Data("server-says-hi".utf8), masked: false)]
        })
        defer { up.stop() }
        proxy.routeAllTo = (ip, up.port)
        let w = try await OpenShellWebSocketRouteTests.Wire(proxy: proxy, pid: pid)
        let upgrade = Data("GET /socket HTTP/1.1\r\nHost: ws.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
        w.send(upgrade)
        let head = String(decoding: w.read(), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 101"), "\(head)")
        w.send(WSFrame.encode(opcode: WSFrame.text, payload: Data("ping-from-guest".utf8), masked: true))
        var got = Data()
        for _ in 0..<20 where !String(decoding: got, as: UTF8.self).contains("server-says-hi") { got += w.read() }
        #expect(String(decoding: got, as: UTF8.self).contains("server-says-hi"))
        w.close()
        let store = try #require(proxy.traces.withLockedValue { $0 })
        for _ in 0..<200 where !store.recent.contains(where: { $0.statusCode == 101 }) { try await Task.sleep(for: .milliseconds(10)) }
        let r = try #require(store.recent.first { $0.statusCode == 101 && $0.profileID == pid })
        #expect(r.method == "GET" && r.path == "/socket" && r.bodyStored)
        var body = ""
        for _ in 0..<100 {
            if let b = store.loadBody(for: r, kind: .response) { body = String(decoding: b, as: UTF8.self); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(body.hasPrefix("HTTP/1.1 101") && body.contains("server-says-hi"), "\(body)")
        // The guest's frame is masked on the wire: only the transcript has it.
        #expect(body.contains("ping-from-guest"), "the client's message too: \(body)")
    }
}
