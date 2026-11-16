import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SandboxEngine
import Testing
@testable import ACLinux

/// Stands in for the Claude, Codex, Grok and Kimi token endpoints: counts
/// refresh POSTs and answers each with a rotated token set.
final class FakeRefreshEndpoints: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts: [String: Int] = [:]

    static func reset() { lock.lock(); posts = [:]; lock.unlock() }
    static func count(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return posts[host] ?? 0 }

    static let hosts: Set = ["console.anthropic.com", "platform.claude.com", "auth.openai.com", "auth.x.ai", "auth.kimi.ai"]
    override class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock(); Self.posts[host, default: 0] += 1; let n = Self.posts[host]!; Self.lock.unlock()
        let json: [String: Any] = ["access_token": SubscriptionRefresherReuseTests.jwt("new\(n)"),
                                   "refresh_token": "refresh-new\(n)", "expires_in": 3600]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A refresher keeps one URLSession for its life (a freed one crashes on
/// Linux: URLSessionRetirement): a refresh must never invalidate it, so a
/// second refresh on the same refresher goes out too. Two profiles' slots,
/// one refresh each (a second refresh of one slot would be rate-limited).
@Suite("Subscription refreshers: one session, many refreshes", .serialized)
struct SubscriptionRefresherReuseTests {
    static func jwt(_ sub: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return b64(#"{"alg":"RS256","typ":"JWT"}"#) + "." + b64(#"{"sub":"\#(sub)","exp":4102444800}"#) + "." + b64("sig")
    }
    static var stubbed: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeRefreshEndpoints.self]
        return c
    }
    static func tempFile(_ tag: String) -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        return (dir, dir.appendingPathComponent("s.enc"))
    }
    static let later = Date().addingTimeInterval(6 * 3600)

    @Test func codexRefreshesTwice() async throws {
        FakeRefreshEndpoints.reset()
        let (dir, file) = Self.tempFile("codex"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodexSubscriptionStore(fileURL: file)
        let (p1, p2) = (UUID(), UUID())
        for (p, t) in [(p1, "a"), (p2, "b")] {
            try store.setOverride(CodexSubscriptionRecord(accessToken: Self.jwt(t), refreshToken: "rt-\(t)", idToken: Self.jwt("id"),
                                                          expiresAt: Self.later, savedAt: Date()), for: p)
        }
        let r = CodexSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await r.noteUnauthorized(stale: Self.jwt("a"), for: p1)
        await r.noteUnauthorized(stale: Self.jwt("b"), for: p2)
        #expect(FakeRefreshEndpoints.count("auth.openai.com") == 2)
        #expect(store.record(for: p1)?.refreshToken == "refresh-new1")
        #expect(store.record(for: p2)?.refreshToken == "refresh-new2")
    }

    @Test func grokRefreshesTwice() async throws {
        FakeRefreshEndpoints.reset()
        let (dir, file) = Self.tempFile("grok"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrokSubscriptionStore(fileURL: file)
        let (p1, p2) = (UUID(), UUID())
        for (p, t) in [(p1, "a"), (p2, "b")] {
            try store.setOverride(GrokSubscriptionRecord(accessToken: Self.jwt(t), refreshToken: "rt-\(t)",
                                                         expiresAt: Self.later, savedAt: Date()), for: p)
        }
        let r = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await r.noteUnauthorized(stale: Self.jwt("a"), for: p1)
        await r.noteUnauthorized(stale: Self.jwt("b"), for: p2)
        #expect(FakeRefreshEndpoints.count("auth.x.ai") == 2)
        #expect(store.record(for: p1)?.refreshToken == "refresh-new1")
        #expect(store.record(for: p2)?.refreshToken == "refresh-new2")
    }

    @Test func kimiRefreshesTwice() async throws {
        FakeRefreshEndpoints.reset()
        let (dir, file) = Self.tempFile("kimi"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = KimiSubscriptionStore(fileURL: file)
        let (p1, p2) = (UUID(), UUID())
        for (p, t) in [(p1, "a"), (p2, "b")] {
            try store.setOverride(KimiSubscriptionRecord(accessToken: Self.jwt(t), refreshToken: "rt-\(t)",
                                                         expiresAt: Self.later, savedAt: Date()), for: p)
        }
        let r = KimiSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await r.noteUnauthorized(stale: Self.jwt("a"), for: p1)
        await r.noteUnauthorized(stale: Self.jwt("b"), for: p2)
        #expect(FakeRefreshEndpoints.count("auth.kimi.ai") == 2)
        #expect(store.record(for: p1)?.refreshToken == "refresh-new1")
        #expect(store.record(for: p2)?.refreshToken == "refresh-new2")
    }

    /// The shared sessions' configuration: a copy (the caller's is left as
    /// it was) that keeps and sends no cookies, the stub's protocol kept.
    @Test func sharedSessionsKeepNoCookies() {
        let given = Self.stubbed
        let c = given.withoutCookies()
        #expect(c.httpCookieStorage == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.httpCookieAcceptPolicy == .never)
        #expect(given.httpShouldSetCookies == true)
        #expect(c.protocolClasses?.contains { $0 == FakeRefreshEndpoints.self } == true)
    }
}
