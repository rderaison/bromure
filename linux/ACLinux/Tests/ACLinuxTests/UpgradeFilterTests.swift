import Foundation
import Testing
@testable import ACLinux

/// Which upgrades the proxy passes: WebSocket, else SPDY/3.1 (kubectl exec /
/// attach / port-forward); every other token (h2c above all) is stripped and
/// the request goes on as plain HTTP/1.1 under the per-request policy.
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
        // Offered beside another protocol: only SPDY/3.1 is kept.
        let mixed = try await Self.plan("Upgrade: h2c, SPDY/3.1\r\nHTTP2-Settings: AAMAAABkAAQAAP__\r\n")
        #expect(mixed.upgrade && Self.upgradeHeaders(mixed.out) == ["Upgrade: SPDY/3.1"])
        #expect(!mixed.out.lowercased().contains("http2-settings"))
    }

    @Test func h2cIsStrippedToPlainHTTP() async throws {
        let r = try await Self.plan("Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAAQAAP__\r\n")
        #expect(!r.upgrade, "served as plain HTTP/1.1")
        #expect(Self.upgradeHeaders(r.out).isEmpty)
        #expect(!r.out.lowercased().contains("http2-settings") && !r.out.contains("Connection: Upgrade"))
    }

    @Test func anUnknownTokenIsStripped() async throws {
        let r = try await Self.plan("Upgrade: example-proto/2\r\n")
        #expect(!r.upgrade && Self.upgradeHeaders(r.out).isEmpty)
        // Beside WebSocket, it goes and WebSocket stays.
        let mixed = try await Self.plan("Upgrade: example-proto/2\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")
        #expect(mixed.upgrade && Self.upgradeHeaders(mixed.out) == ["Upgrade: websocket"])
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
