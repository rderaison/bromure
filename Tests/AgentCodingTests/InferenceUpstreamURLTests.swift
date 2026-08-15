import Foundation
import Testing
@testable import bromure_ac

/// H1 regression: the inference repair proxy forwards raw guest HTTP (over
/// vsock 8446, unauthenticated) to the local engine. `req.path` is the
/// unmodified request-target, so a target that isn't origin-form could make
/// `http://127.0.0.1:<engine>` + path parse to a DIFFERENT loopback service.
/// Unlike the MITM smuggle (which changes the HOST), here the loopback host is
/// shared — the attack changes the PORT — so the origin-form guard plus a port
/// pin are what close it.
@Suite("Inference upstream URL construction")
struct InferenceUpstreamURLTests {
    private let engine = 8080

    private func url(_ path: String) -> URL? {
        InferenceRepairProxy.engineUpstreamURL(path: path, enginePort: engine)
    }

    @Test("Origin-form inference paths resolve to the engine loopback host+port")
    func originForm() throws {
        for p in ["/v1/messages", "/v1/chat/completions", "/v1/responses",
                  "/v1/messages?beta=true", "/health"] {
            let u = try #require(url(p), "rejected a legit path: \(p)")
            #expect(u.scheme == "http")
            #expect(u.host == "127.0.0.1")
            #expect(u.port == engine)
        }
    }

    @Test("Userinfo/port smuggle to another loopback service is rejected")
    func loopbackPortSmuggle() {
        // The reported attack: "http://127.0.0.1:8080@127.0.0.1:9223/sessions"
        // parses to host 127.0.0.1 PORT 9223 — the automation API — while the
        // engine's own host survives the assertion. The origin-form guard is
        // what rejects it (the target doesn't start with "/").
        #expect(url("@127.0.0.1:9223/sessions") == nil)
        #expect(url("@[::1]:9223/sessions") == nil)
        #expect(url("@localhost:631/printers") == nil)
        // Sanity: Foundation really does resolve the smuggled port, so the
        // guard is load-bearing (a bare host check would pass — host is still
        // 127.0.0.1).
        let raw = URL(string: "http://127.0.0.1:8080@127.0.0.1:9223/sessions")
        #expect(raw?.host == "127.0.0.1")
        #expect(raw?.port == 9223)
    }

    @Test("Absolute-, authority-, and asterisk-form targets are rejected")
    func nonOriginForms() {
        #expect(url("http://evil.example/x") == nil)
        #expect(url("https://evil.example/x") == nil)
        #expect(url("http://127.0.0.1:9223/x") == nil)
        #expect(url("evil.example:443") == nil)
        #expect(url("127.0.0.1:9223") == nil)
        #expect(url("*") == nil)
        #expect(url("") == nil)
    }

    @Test("An '@' or '//' inside an origin-form path stays a path, not an authority")
    func atSignInsidePathIsSafe() throws {
        // These start with "/", so the authority (127.0.0.1:engine) is already
        // fixed — the rest is just an odd path and can't redirect the port.
        for p in ["/@127.0.0.1:9223/sessions", "//127.0.0.1:9223/x",
                  "/v1/messages/@evil"] {
            let u = try #require(url(p), "wrongly rejected origin-form path: \(p)")
            #expect(u.host == "127.0.0.1")
            #expect(u.port == engine)
        }
    }
}
