import Foundation
import Testing
@testable import bromure_ac

/// Stands in for auth.x.ai's and auth.kimi.ai's token endpoints: counts
/// refresh POSTs, answers with a fixed status (200 = a rotated token set),
/// and runs `onRequest` while the refresh is in flight (so a test can land a
/// new sign-in mid-refresh).
final class FakeGrokKimiTokenEndpoint: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var onRequest: (() -> Void)?

    static func reset(status: Int = 200, onRequest: (() -> Void)? = nil) {
        lock.lock(); posts = 0; self.status = status; self.onRequest = onRequest; lock.unlock()
    }
    static var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.x.ai" || request.url?.host == "auth.kimi.ai"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.posts += 1
        let n = Self.posts, status = Self.status, hook = Self.onRequest
        Self.lock.unlock()
        hook?()
        let json: [String: Any] = status == 200
            ? ["access_token": GrokKimiStandInTests.jwt(["exp": 2_000_000_000, "n": n]),
               "refresh_token": "real-refresh-new\(n)", "expires_in": 3600]
            : ["error": "invalid_grant"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Grok and Kimi logins across an app relaunch with resumed machines: the
/// stand-in a resumed agent still holds is recognised by its mark (not only
/// the in-memory registry), a stand-in refresh is answered on the proxy, and
/// the refreshers force a real refresh on a 401 (rate-limited), discard a
/// refresh a newer sign-in superseded, and flag re-auth only for the grant
/// that was actually rejected.
@Suite("Grok / Kimi stand-ins and refreshers", .serialized)
struct GrokKimiStandInTests {

    static func jwt(_ claims: [String: Any]) -> String {
        func seg(_ o: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return seg(["alg": "RS256", "typ": "JWT"]) + "." + seg(claims) + ".c2lnbmF0dXJlLXJlYWw"
    }

    private static func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("s.enc")
    }
    private static var stubbed: URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeGrokKimiTokenEndpoint.self]
        return cfg
    }

    private static func grokRecord(_ tag: String = "orig", expiresIn: TimeInterval = 6 * 3600) -> GrokSubscriptionRecord {
        GrokSubscriptionRecord(accessToken: jwt(["exp": 2_000_000_000, "sub": tag]),
                               refreshToken: "real-refresh-\(tag)",
                               expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
    }
    private static func kimiRecord(_ tag: String = "orig", expiresIn: TimeInterval = 6 * 3600) -> KimiSubscriptionRecord {
        KimiSubscriptionRecord(accessToken: jwt(["exp": 2_000_000_000, "sub": tag]),
                               refreshToken: "real-refresh-\(tag)",
                               expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
    }

    private static func refreshRequest(host: String, path: String, refresh: String) -> Data {
        let body = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=x"
        return Data(("POST \(path) HTTP/1.1\r\nHost: \(host)\r\n"
            + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body).utf8)
    }
    private static func status(_ reply: Data) -> Int {
        let line = String(decoding: reply.prefix(64), as: UTF8.self)
        let parts = line.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }
    private static func json(_ reply: Data) -> [String: Any] {
        guard let r = reply.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: reply.subdata(in: r.upperBound..<reply.count))) as? [String: Any]) ?? [:]
    }

    // MARK: Recognition across a relaunch

    @Test("Grok: a stand-in minted before a relaunch (empty registry, rotated real token) is still swapped — for its own workspace only")
    @MainActor func grokRecognisedAcrossRelaunch() throws {
        let store = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        let withLogin = UUID(), without = UUID()
        try store.setOverride(Self.grokRecord(), for: withLogin)
        let saved = HTTPMitmConnection.grokSubscriptionProvider
        let refresher = GrokSubscriptionRefresher(store: store)
        HTTPMitmConnection.grokSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.grokSubscriptionProvider = saved }

        // The machine booted with this stand-in; the app then quit and
        // relaunched (new store = empty registry) and the host rotated the
        // real token.
        let old = GrokStandIn.mint(Self.grokRecord(), profileID: withLogin)
        try store.setOverride(Self.grokRecord("rotated"), for: withLogin)
        #expect(store.profileForBogusKey(old.access) == nil)
        #expect(GrokStandIn.isAccess(old.access))
        #expect(GrokStandIn.isRefresh(old.refresh))
        #expect(HTTPMitmConnection.isGrokStandIn(old.access, profileID: withLogin))
        #expect(!HTTPMitmConnection.isGrokStandIn(old.access, profileID: without))
        #expect(!HTTPMitmConnection.isGrokStandIn(Self.grokRecord().accessToken, profileID: withLogin))
        // The seed path and the in-session sign-in path mint the same shape.
        let viaSignIn = ACAppDelegate.standInTokens(for: .grok, profileID: withLogin,
                                                    access: Self.grokRecord().accessToken,
                                                    refresh: Self.grokRecord().refreshToken)
        #expect(viaSignIn.refresh == old.refresh)
        #expect(GrokStandIn.isAccess(viaSignIn.access))
    }

    @Test("Kimi: a stand-in minted before a relaunch is still swapped — for its own workspace only")
    func kimiRecognisedAcrossRelaunch() throws {
        let store = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        let withLogin = UUID(), without = UUID()
        try store.setOverride(Self.kimiRecord(), for: withLogin)
        let saved = HTTPMitmConnection.kimiSubscriptionProvider
        let refresher = KimiSubscriptionRefresher(store: store)
        HTTPMitmConnection.kimiSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.kimiSubscriptionProvider = saved }

        let oldAccess = KimiStandIn.access(realAccess: Self.kimiRecord().accessToken, profileID: withLogin)
        try store.setOverride(Self.kimiRecord("rotated"), for: withLogin)
        #expect(store.profileForBogusKey(oldAccess) == nil)
        #expect(HTTPMitmConnection.isKimiStandIn(oldAccess, profileID: withLogin))
        #expect(!HTTPMitmConnection.isKimiStandIn(oldAccess, profileID: without))
        #expect(!HTTPMitmConnection.isKimiStandIn(Self.kimiRecord().accessToken, profileID: withLogin))
        #expect(KimiStandIn.isRefresh(KimiStandIn.refresh(realRefresh: "anything", profileID: withLogin)))
        #expect(!KimiStandIn.isRefresh("real-refresh-orig"))
    }

    // MARK: Stand-in refresh answered on the proxy

    @Test("Grok: a stand-in refresh is answered on the proxy with fresh stand-ins after a real host refresh")
    func grokStandInRefreshOnProxy() async throws {
        FakeGrokKimiTokenEndpoint.reset()
        let store = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        let pid = UUID()
        try store.setOverride(Self.grokRecord(), for: pid)
        let refresher = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let saved = HTTPMitmConnection.grokSubscriptionProvider
        HTTPMitmConnection.grokSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.grokSubscriptionProvider = saved }

        let old = GrokStandIn.mint(Self.grokRecord(), profileID: pid)
        let req = Self.refreshRequest(host: "auth.x.ai", path: "/oauth2/token", refresh: old.refresh)
        let reply = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.x.ai", method: "POST", path: "/oauth2/token", rawRequest: req, profileID: pid))
        #expect(Self.status(reply) == 200)
        let body = Self.json(reply)
        let access = try #require(body["access_token"] as? String)
        #expect(GrokStandIn.isAccess(access))
        #expect(GrokStandIn.isRefresh(body["refresh_token"] as? String ?? ""))
        #expect(store.profileForBogusKey(access) == pid)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
        #expect(store.record(for: pid)?.refreshToken == "real-refresh-new1")
        #expect(store.record(for: pid)?.lastRefreshedAt != nil)
        // The real tokens never reach the guest.
        #expect(!String(decoding: reply, as: UTF8.self).contains("real-refresh"))

        // A second one moments later reuses the fresh real login.
        let again = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.x.ai", method: "POST", path: "/oauth2/token", rawRequest: req, profileID: pid))
        #expect(Self.status(again) == 200)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)

        // A genuine (non-stand-in) refresh passes through untouched.
        let genuine = Self.refreshRequest(host: "auth.x.ai", path: "/oauth2/token", refresh: "real-refresh-user")
        #expect(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.x.ai", method: "POST", path: "/oauth2/token", rawRequest: genuine, profileID: pid) == nil)
    }

    @Test("Kimi: an OLDER stand-in refresh (after a host rotation) is answered, not sent on")
    func kimiOlderStandInRefreshOnProxy() async throws {
        FakeGrokKimiTokenEndpoint.reset()
        let store = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        let pid = UUID()
        try store.setOverride(Self.kimiRecord("rotated-since"), for: pid)
        let refresher = KimiSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let saved = HTTPMitmConnection.kimiSubscriptionProvider
        HTTPMitmConnection.kimiSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.kimiSubscriptionProvider = saved }

        // Minted from a refresh token the host has since rotated away.
        let older = KimiStandIn.refresh(realRefresh: "real-refresh-orig", profileID: pid)
        let req = Self.refreshRequest(host: "auth.kimi.ai", path: "/api/oauth/token", refresh: older)
        let reply = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.kimi.ai", method: "POST", path: "/api/oauth/token", rawRequest: req, profileID: pid))
        #expect(Self.status(reply) == 200)
        let access = try #require(Self.json(reply)["access_token"] as? String)
        #expect(store.profileForBogusKey(access) == pid)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
    }

    @Test("a rejected real refresh is reported (and flagged); a transient one is a retryable 503")
    func standInRefreshFailures() async throws {
        let store = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        let kstore = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        let pid = UUID()
        try store.setOverride(Self.grokRecord(), for: pid)
        try kstore.setOverride(Self.kimiRecord(), for: pid)
        let savedG = HTTPMitmConnection.grokSubscriptionProvider
        let savedK = HTTPMitmConnection.kimiSubscriptionProvider
        defer {
            HTTPMitmConnection.grokSubscriptionProvider = savedG
            HTTPMitmConnection.kimiSubscriptionProvider = savedK
        }
        let gReq = Self.refreshRequest(host: "auth.x.ai", path: "/oauth2/token",
                                       refresh: GrokStandIn.mint(Self.grokRecord(), profileID: pid).refresh)
        let kReq = Self.refreshRequest(host: "auth.kimi.ai", path: "/api/oauth/token",
                                       refresh: KimiStandIn.refresh(realRefresh: "x", profileID: pid))

        // Transient (5xx): not flagged, 503.
        FakeGrokKimiTokenEndpoint.reset(status: 500)
        do {
            let g = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
            let k = KimiSubscriptionRefresher(store: kstore, sessionConfiguration: Self.stubbed)
            HTTPMitmConnection.grokSubscriptionProvider = { (store, g) }
            HTTPMitmConnection.kimiSubscriptionProvider = { (kstore, k) }
            let gr = try #require(await HTTPMitmConnection.answerStandInRefresh(
                host: "auth.x.ai", method: "POST", path: "/oauth2/token", rawRequest: gReq, profileID: pid))
            let kr = try #require(await HTTPMitmConnection.answerStandInRefresh(
                host: "auth.kimi.ai", method: "POST", path: "/api/oauth/token", rawRequest: kReq, profileID: pid))
            #expect(Self.status(gr) == 503)
            #expect(Self.status(kr) == 503)
            #expect(store.reauthRequiredAt(for: pid) == nil)
            #expect(kstore.reauthRequiredAt(for: pid) == nil)
        }

        // Rejected (400): flagged, permanent error; the access swap then
        // refuses to inject a dead token.
        FakeGrokKimiTokenEndpoint.reset(status: 400)
        let g = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let k = KimiSubscriptionRefresher(store: kstore, sessionConfiguration: Self.stubbed)
        HTTPMitmConnection.grokSubscriptionProvider = { (store, g) }
        HTTPMitmConnection.kimiSubscriptionProvider = { (kstore, k) }
        let gr = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.x.ai", method: "POST", path: "/oauth2/token", rawRequest: gReq, profileID: pid))
        let kr = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "auth.kimi.ai", method: "POST", path: "/api/oauth/token", rawRequest: kReq, profileID: pid))
        #expect(Self.status(gr) == 400)
        #expect(Self.json(gr)["error"] as? String == "invalid_grant")
        #expect(Self.status(kr) == 401)
        #expect(store.reauthRequiredAt(for: pid) != nil)
        #expect(kstore.reauthRequiredAt(for: pid) != nil)
        await #expect(throws: GrokSubscriptionError.self) { try await g.accessToken(for: pid) }
        await #expect(throws: KimiSubscriptionError.self) { try await k.accessToken(for: pid) }
    }

    // MARK: Refresher behaviour

    @Test("a 401 on an unexpired token forces a real refresh, at most once per floor")
    func unauthorizedForcesRefresh() async throws {
        FakeGrokKimiTokenEndpoint.reset()
        let store = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        try store.setShared(Self.grokRecord())
        let r = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await r.noteUnauthorized(stale: Self.grokRecord().accessToken, for: nil)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
        let fresh = try #require(store.record(for: nil))
        #expect(fresh.refreshToken == "real-refresh-new1")
        // A 401 on the fresh token moments later: rate-limited, no new POST.
        await r.noteUnauthorized(stale: fresh.accessToken, for: nil)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
        // A stale 401 on a token the slot no longer holds: nothing.
        await r.noteUnauthorized(stale: "not-the-current-token", for: nil)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)

        FakeGrokKimiTokenEndpoint.reset()
        let kstore = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        try kstore.setShared(Self.kimiRecord())
        let k = KimiSubscriptionRefresher(store: kstore, sessionConfiguration: Self.stubbed)
        await k.noteUnauthorized(stale: Self.kimiRecord().accessToken, for: nil)
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
        #expect(try await k.refreshForStandIn(for: nil) == false)   // within the floor: reused
        #expect(FakeGrokKimiTokenEndpoint.postCount == 1)
    }

    @Test("a refresh that a newer sign-in superseded is discarded")
    func discardIfChanged() async throws {
        let store = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        try store.setShared(Self.kimiRecord("A", expiresIn: -10))
        // The user signs in again while the refresh of grant A is in flight.
        FakeGrokKimiTokenEndpoint.reset(onRequest: { try? store.setShared(Self.kimiRecord("B")) })
        let r = KimiSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let served = try await r.accessToken(for: nil)
        #expect(store.record(for: nil)?.refreshToken == "real-refresh-B")
        #expect(served == Self.kimiRecord("B").accessToken)

        let gstore = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        try gstore.setShared(Self.grokRecord("A", expiresIn: -10))
        FakeGrokKimiTokenEndpoint.reset(onRequest: { try? gstore.setShared(Self.grokRecord("B")) })
        let g = GrokSubscriptionRefresher(store: gstore, sessionConfiguration: Self.stubbed)
        _ = try await g.accessToken(for: nil)
        #expect(gstore.record(for: nil)?.refreshToken == "real-refresh-B")
    }

    @Test("a rejection flags re-auth only while the slot still holds the rejected grant")
    func reauthOnlyIfUnchanged() async throws {
        let store = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        try store.setShared(Self.grokRecord("A", expiresIn: -10))
        FakeGrokKimiTokenEndpoint.reset(status: 401, onRequest: { try? store.setShared(Self.grokRecord("B")) })
        let r = GrokSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await #expect(throws: GrokSubscriptionError.self) { try await r.accessToken(for: nil) }
        #expect(store.reauthRequiredAt(for: nil) == nil)
        #expect(store.record(for: nil)?.refreshToken == "real-refresh-B")

        let kstore = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        try kstore.setShared(Self.kimiRecord("A", expiresIn: -10))
        FakeGrokKimiTokenEndpoint.reset(status: 401)
        let k = KimiSubscriptionRefresher(store: kstore, sessionConfiguration: Self.stubbed)
        await #expect(throws: KimiSubscriptionError.self) { try await k.accessToken(for: nil) }
        #expect(kstore.reauthRequiredAt(for: nil) != nil)
    }
}
