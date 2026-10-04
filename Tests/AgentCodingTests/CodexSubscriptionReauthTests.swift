import Foundation
import Testing
@testable import bromure_ac

/// Stands in for auth.openai.com's token endpoint: counts refresh POSTs and
/// answers with a fixed status (200 = a rotated token set).
final class FakeCodexTokenEndpoint: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var status = 200

    static func reset(status: Int = 200) {
        lock.lock(); posts = 0; self.status = status; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.openai.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.posts += 1
        let n = Self.posts, status = Self.status
        Self.lock.unlock()
        let json: [String: Any] = status == 200
            ? ["access_token": "eyJnew\(n).x.y", "refresh_token": "rt_new\(n)", "expires_in": 864000]
            : ["error": ["code": "refresh_token_invalidated", "message": "invalidated"]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// B34: a ChatGPT login OpenAI invalidated must be flagged "needs sign-in",
/// never be injected again, and never be reported as "refreshed".
@Suite("Codex subscription: dead login is flagged, not injected", .serialized)
struct CodexSubscriptionReauthTests {
    private func tempStore() -> (CodexSubscriptionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-sub-\(UUID())", isDirectory: true)
        return (CodexSubscriptionStore(fileURL: dir.appendingPathComponent("c.enc")), dir)
    }
    /// A record whose access token still LOOKS valid for hours — the case
    /// the old code short-circuited on ("not expired" ⇒ "refreshed").
    private func unexpired() -> CodexSubscriptionRecord {
        CodexSubscriptionRecord(accessToken: "eyJorig.x.y", refreshToken: "rt_orig", idToken: "eyJid.x.y",
                                expiresAt: Date().addingTimeInterval(6 * 3600), savedAt: Date())
    }
    private func refresher(_ store: CodexSubscriptionStore) -> CodexSubscriptionRefresher {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeCodexTokenEndpoint.self]
        return CodexSubscriptionRefresher(store: store, sessionConfiguration: cfg)
    }

    @Test("a 401 on an unexpired token forces a real refresh")
    func unauthorizedForcesRefresh() async throws {
        FakeCodexTokenEndpoint.reset()
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.setShared(unexpired())
        let r = refresher(store)
        await r.noteUnauthorized(stale: "eyJorig.x.y", for: nil)
        #expect(FakeCodexTokenEndpoint.posts == 1)
        #expect(store.record(for: nil)?.accessToken == "eyJnew1.x.y")
        #expect(store.reauthRequiredAt(for: nil) == nil)
    }

    @Test("a rejected refresh flags sign-in and stops injection")
    func rejectedRefreshFlags() async throws {
        FakeCodexTokenEndpoint.reset(status: 401)
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.setShared(unexpired())
        let r = refresher(store)
        await r.noteUnauthorized(stale: "eyJorig.x.y", for: UUID(), invalidated: true)
        #expect(store.reauthRequiredAt(for: nil) != nil)
        await #expect(throws: CodexSubscriptionError.self) { try await r.accessToken(for: nil) }
        // The stand-in refresh Codex sends next is answered with a failure,
        // not fresh stand-ins — and doesn't hit OpenAI again.
        do {
            try await r.refreshForStandIn(for: nil)
            Issue.record("expected a rejection")
        } catch let e as CodexSubscriptionError {
            #expect(e.isRejection)
        }
        #expect(FakeCodexTokenEndpoint.posts == 1)
        // A fresh sign-in clears it.
        try store.setShared(unexpired())
        #expect(try await r.accessToken(for: nil) == "eyJorig.x.y")
    }

    @Test("a freshly refreshed token invalidated again flags the login")
    func invalidatedAfterRefresh() async throws {
        FakeCodexTokenEndpoint.reset()
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.setShared(unexpired())
        let r = refresher(store)
        #expect(try await r.refreshForStandIn(for: nil) == true)
        // Within the floor: reused, no second POST.
        #expect(try await r.refreshForStandIn(for: nil) == false)
        #expect(FakeCodexTokenEndpoint.posts == 1)
        // A plain 401 on the fresh token doesn't flag (could be anything)…
        await r.noteUnauthorized(stale: "eyJnew1.x.y", for: nil)
        #expect(store.reauthRequiredAt(for: nil) == nil)
        // …a token_invalidated one does.
        await r.noteUnauthorized(stale: "eyJnew1.x.y", for: nil, invalidated: true)
        #expect(store.reauthRequiredAt(for: nil) != nil)
    }

    @Test("token_invalidated bodies are recognised")
    func invalidationBody() {
        let body = Data(#"HTTP/1.1 401 Unauthorized\#r\#n\#r\#n{"error":{"message":"Your authentication token has been invalidated. Please try signing in again.","code":"token_invalidated"}}"#.utf8)
        #expect(CodexSignInExpired.isInvalidation(body))
        #expect(!CodexSignInExpired.isInvalidation(Data(#"{"error":{"code":"token_expired"}}"#.utf8)))
        // The locally-answered bodies carry the banner the session card keys on.
        let refresh = CodexSignInExpired.refreshRejectedJSON(CodexSubscriptionError.reauthRequired)
        let msg = ((refresh["error"] as? [String: Any])?["message"] as? String ?? "").lowercased()
        #expect(msg.contains("sign in again"))
    }
}
