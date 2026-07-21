import Foundation
import Testing
@testable import bromure_ac

// Exercises ControlPlaneClient against a stubbed transport so the exact
// request shaping (path, method, Authorization, JSON body) and response
// decoding are pinned to the bromure-infra contract without a live server.

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        let method: String
        let path: String
        let authorization: String?
        let body: [String: Any]
    }

    struct Response {
        let status: Int
        let json: Any
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((Captured) -> Response)?
    nonisolated(unsafe) private static var captures: [Captured] = []

    static func install(_ h: @escaping (Captured) -> Response) {
        lock.lock(); handler = h; captures = []; lock.unlock()
    }
    static func recorded() -> [Captured] { lock.lock(); defer { lock.unlock() }; return captures }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var bodyObj: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            stream.close()
            bodyObj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        } else if let data = request.httpBody {
            bodyObj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        }
        let cap = Captured(method: request.httpMethod ?? "GET", path: path,
                           authorization: request.value(forHTTPHeaderField: "Authorization"),
                           body: bodyObj)
        StubURLProtocol.lock.lock()
        StubURLProtocol.captures.append(cap)
        let h = StubURLProtocol.handler
        StubURLProtocol.lock.unlock()

        let resp = h?(cap) ?? Response(status: 500, json: [:])
        let http = HTTPURLResponse(url: request.url!, statusCode: resp.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let data = try! JSONSerialization.data(withJSONObject: resp.json)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Serialized: the stub protocol keeps its captured request + canned response in
// process-wide static state, so these must not interleave.
@Suite("P2P control-plane client", .serialized)
struct P2PClientTests {

    private func client() throws -> ControlPlaneClient {
        let ep = try ControlPlaneEndpoint(base: "https://bromure.io/api")
        return ControlPlaneClient(endpoint: ep, session: StubURLProtocol.session())
    }

    @Test("enroll begin: POST /v1/devices/enroll with pubkey, no bearer")
    func enrollBegin() async throws {
        StubURLProtocol.install { _ in
            .init(status: 200, json: [
                "challengeId": "ch-1", "challenge": "rnd",
                "signPayload": "bromure-p2p-enroll:v1:ch-1:rnd",
                "capability": "client", "expiresInSeconds": 120,
            ])
        }
        let c = try client()
        let r = try await c.enrollBegin(code: "the-code", devicePubkeyHex: String(repeating: "ab", count: 32),
                                        deviceName: "Studio", capability: nil)
        #expect(r.challengeId == "ch-1")
        #expect(r.signPayload == "bromure-p2p-enroll:v1:ch-1:rnd")

        let cap = try #require(StubURLProtocol.recorded().first)
        #expect(cap.method == "POST")
        #expect(cap.path == "/api/v1/devices/enroll")
        #expect(cap.authorization == nil)   // enrollment proves key possession, no bearer
        #expect(cap.body["code"] as? String == "the-code")
        #expect((cap.body["devicePubkey"] as? String)?.count == 64)
        #expect(cap.body["deviceName"] as? String == "Studio")
    }

    @Test("enroll complete: POST signature → deviceToken")
    func enrollComplete() async throws {
        StubURLProtocol.install { _ in
            .init(status: 201, json: [
                "deviceId": "dev-1", "deviceToken": "tok-1",
                "deviceTokenExpiresAt": "2027-07-21T00:00:00.000Z",
                "capability": "client", "orgSlug": "acme", "userId": "u-1",
            ])
        }
        let c = try client()
        let r = try await c.enrollComplete(challengeId: "ch-1", signatureBase64: "c2ln")
        #expect(r.deviceId == "dev-1")
        #expect(r.deviceToken == "tok-1")
        let cap = try #require(StubURLProtocol.recorded().first)
        #expect(cap.body["challengeId"] as? String == "ch-1")
        #expect(cap.body["signature"] as? String == "c2ln")
    }

    @Test("requestConnection: POST /v1/connections {deviceId} with bearer")
    func requestConnection() async throws {
        StubURLProtocol.install { _ in
            .init(status: 201, json: ["connection": [
                "id": "g-1", "expiresAt": "2026-07-21T10:00:45.000Z",
                "self": ["deviceId": "cli", "signalId": "cs", "role": "client"],
                "peer": ["deviceId": "srv", "signalId": "ss", "role": "server"],
            ]])
        }
        let c = try client()
        let grant = try await c.requestConnection(bearer: "tok-1", targetDeviceId: "srv")
        #expect(grant.id == "g-1")
        #expect(grant.own.role == "client")
        #expect(grant.peer.deviceId == "srv")
        let cap = try #require(StubURLProtocol.recorded().first)
        #expect(cap.path == "/api/v1/connections")
        #expect(cap.authorization == "Bearer tok-1")
        #expect(cap.body["deviceId"] as? String == "srv")
    }

    @Test("turn-credentials 503 maps to .turnUnavailable")
    func turnUnavailable() async throws {
        StubURLProtocol.install { _ in .init(status: 503, json: ["error": "turn-unconfigured"]) }
        let c = try client()
        await #expect(throws: ControlPlaneError.turnUnavailable) {
            _ = try await c.turnCredentials(bearer: "tok-1", connectionId: "g-1")
        }
    }

    @Test("complete: first report returns recorded=true")
    func complete() async throws {
        StubURLProtocol.install { _ in .init(status: 200, json: ["ok": true, "recorded": true]) }
        let c = try client()
        let recorded = try await c.complete(bearer: "tok-1", connectionId: "g-1",
                                            report: .connected(pathKind: .direct, timeToConnectedMs: 100))
        #expect(recorded)
        let cap = try #require(StubURLProtocol.recorded().first)
        #expect(cap.path == "/api/v1/connections/g-1/complete")
        #expect(cap.body["outcome"] as? String == "connected")
    }

    @Test("server-mode: POST /v1/devices/server-mode {enabled} with bearer")
    func serverMode() async throws {
        StubURLProtocol.install { _ in .init(status: 200, json: ["ok": true, "server": true]) }
        let c = try client()
        let on = try await c.setServerMode(bearer: "tok-1", enabled: true)
        #expect(on == true)
        let cap = try #require(StubURLProtocol.recorded().first)
        #expect(cap.path == "/api/v1/devices/server-mode")
        #expect(cap.authorization == "Bearer tok-1")
        #expect(cap.body["enabled"] as? Bool == true)
    }

    @Test("a 404 surfaces as ControlPlaneError.http(404, code)")
    func notFound() async throws {
        StubURLProtocol.install { _ in .init(status: 404, json: ["error": "unknown-device"]) }
        let c = try client()
        await #expect(throws: ControlPlaneError.http(status: 404, code: "unknown-device")) {
            _ = try await c.requestConnection(bearer: "tok-1", targetDeviceId: "nope")
        }
    }
}
