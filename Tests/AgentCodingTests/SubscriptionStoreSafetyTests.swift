import Foundation
import Testing
@testable import bromure_ac

/// A token endpoint for any host that rejects a refresh token already spent
/// (like a rotating OAuth server) and answers slowly enough for concurrent
/// refreshes to overlap. Its own statics, so suites running in parallel
/// don't share counters.
final class FakeRotatingTokenEndpoint: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var spent: Set<String> = []
    static func reset() { lock.lock(); posts = 0; spent = []; lock.unlock() }
    static var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        let sent = ((try? JSONSerialization.jsonObject(with: body)) as? [String: String])?["refresh_token"] ?? ""
        Self.lock.lock()
        Self.posts += 1
        let n = Self.posts
        let reused = !Self.spent.insert(sent).inserted
        Self.lock.unlock()
        let status = reused ? 400 : 200
        let json: [String: Any] = status == 200
            ? ["access_token": "eyJnew\(n).x.y", "refresh_token": "rt_new\(n)", "expires_in": 28800]
            : ["error": "invalid_grant"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// The subscription stores' at-rest safety, shared by all four through
/// `SubscriptionStoreFile`: two processes (modelled as two store instances on
/// one file) never lose each other's writes or spend one refresh token
/// twice; an unreadable file is never overwritten; a failed write changes
/// nothing in memory.
@Suite("Subscription stores: file safety", .serialized)
struct SubscriptionStoreSafetyTests {

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sub-safety-\(UUID().uuidString)", isDirectory: true)
    }
    private static func codex(_ tag: String, expiresIn: TimeInterval = 6 * 3600) -> CodexSubscriptionRecord {
        CodexSubscriptionRecord(accessToken: "eyJ\(tag).x.y", refreshToken: "rt_\(tag)", idToken: "eyJid.x.y",
                                expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
    }
    private static func claude(_ tag: String, expiresIn: TimeInterval = 6 * 3600) -> ClaudeSubscriptionRecord {
        ClaudeSubscriptionRecord(accessToken: "sk-ant-oat01-\(tag)", refreshToken: "sk-ant-ort01-\(tag)",
                                 expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
    }
    private static func kimi(_ tag: String) -> KimiSubscriptionRecord {
        KimiSubscriptionRecord(accessToken: "kimi-\(tag)", refreshToken: "kimi-rt-\(tag)",
                               expiresAt: Date().addingTimeInterval(3600), savedAt: Date())
    }
    private static func grok(_ tag: String) -> GrokSubscriptionRecord {
        GrokSubscriptionRecord(accessToken: "grok-\(tag)", refreshToken: "grok-rt-\(tag)",
                               expiresAt: Date().addingTimeInterval(3600), savedAt: Date())
    }

    @Test("a second instance sees the first one's writes, and its own writes keep them")
    func twoInstancesReload() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.enc")
        let a = CodexSubscriptionStore(fileURL: url), b = CodexSubscriptionStore(fileURL: url)
        try a.setShared(Self.codex("one"))
        #expect(b.record(for: nil)?.refreshToken == "rt_one")
        // A rotates the token after B cached the file: B reloads.
        try a.update(Self.codex("two"), for: nil)
        #expect(b.record(for: nil)?.refreshToken == "rt_two")
        // B writes another slot: it writes over the CURRENT file, so A's
        // rotation survives.
        let pid = UUID()
        try b.setOverride(Self.codex("ws"), for: pid)
        #expect(a.record(for: nil)?.refreshToken == "rt_two")
        #expect(a.record(for: pid)?.refreshToken == "rt_ws")
    }

    @Test("concurrent writers on two instances never drop each other's records")
    func concurrentWriters() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("k.enc")
        let a = KimiSubscriptionStore(fileURL: url), b = KimiSubscriptionStore(fileURL: url)
        let ids = (0..<16).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { g in
            for (i, id) in ids.enumerated() {
                let store = i % 2 == 0 ? a : b
                g.addTask { try? store.setOverride(Self.kimi("\(i)"), for: id) }
            }
        }
        let fresh = KimiSubscriptionStore(fileURL: url)
        for (i, id) in ids.enumerated() {
            #expect(fresh.record(for: id)?.refreshToken == "kimi-rt-\(i)")
            #expect(a.record(for: id) != nil && b.record(for: id) != nil)
        }
    }

    @Test("two 'processes' refreshing one expired grant spend its refresh token once")
    func crossProcessSingleRefresh() async throws {
        FakeRotatingTokenEndpoint.reset()
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.enc")
        let a = ClaudeSubscriptionStore(fileURL: url), b = ClaudeSubscriptionStore(fileURL: url)
        try a.setShared(Self.claude("orig", expiresIn: -10))
        _ = b.record(for: nil)   // B has the expired grant cached too
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeRotatingTokenEndpoint.self]
        let ra = ClaudeSubscriptionRefresher(store: a, sessionConfiguration: cfg)
        let rb = ClaudeSubscriptionRefresher(store: b, sessionConfiguration: cfg)
        async let ta = ra.accessToken(for: nil)
        async let tb = rb.accessToken(for: nil)
        let (x, y) = try await (ta, tb)
        // The endpoint rejects a reused refresh token: one POST, both served.
        #expect(FakeRotatingTokenEndpoint.postCount == 1)
        #expect(x == y)
        #expect(a.record(for: nil)?.lastRefreshedAt != nil)
        #expect(b.reauthRequiredAt(for: nil) == nil)
    }

    @Test("an unreadable store is never overwritten, a copy is kept, and the state is visible")
    func unreadableNotOverwritten() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("g.enc")
        let garbage = Data("not a vault blob".utf8)
        try garbage.write(to: url)
        let store = GrokSubscriptionStore(fileURL: url)
        #expect(store.record(for: nil) == nil)
        #expect(throws: SubscriptionStoreError.self) { try store.setShared(Self.grok("new")) }
        #expect(throws: SubscriptionStoreError.self) { try store.forget(for: nil) }
        store.setReauthRequired(true, for: nil)   // logged, not written
        #expect(try Data(contentsOf: url) == garbage)
        #expect(store.isUnreadable)
        #expect(store.health(for: nil)?.storeUnreadable == true)
        #expect(store.health(for: nil)?.stateJSON["storeUnreadable"] as? Bool == true)
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("g.enc.unreadable-") }
        #expect(copies.count == 1)

        // Once it reads again (repaired / right key), writes resume.
        try FileManager.default.removeItem(at: url)
        try store.setShared(Self.grok("new"))
        #expect(!store.isUnreadable)
        #expect(GrokSubscriptionStore(fileURL: url).record(for: nil)?.refreshToken == "grok-rt-new")
    }

    @Test("a failed write leaves memory and disk as they were")
    func failedWriteKeepsCache() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.enc")
        let store = ClaudeSubscriptionStore(fileURL: url)
        try store.setShared(Self.claude("one"))
        store.failWritesForTesting = true
        #expect(throws: SubscriptionStoreError.self) { try store.setShared(Self.claude("two")) }
        #expect(throws: SubscriptionStoreError.self) {
            try store.commitRefresh(Self.claude("two"), slotKey: "shared", replacing: "sk-ant-ort01-one")
        }
        #expect(store.record(for: nil)?.refreshToken == "sk-ant-ort01-one")
        #expect(ClaudeSubscriptionStore(fileURL: url).record(for: nil)?.refreshToken == "sk-ant-ort01-one")
    }

    @Test("a refresh whose rotated token can't be saved fails instead of living in memory")
    func refreshWriteFailure() async throws {
        FakeRotatingTokenEndpoint.reset()
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodexSubscriptionStore(fileURL: dir.appendingPathComponent("c.enc"))
        try store.setShared(Self.codex("orig", expiresIn: -10))
        store.failWritesForTesting = true
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeRotatingTokenEndpoint.self]
        let r = CodexSubscriptionRefresher(store: store, sessionConfiguration: cfg)
        await #expect(throws: SubscriptionStoreError.self) { try await r.accessToken(for: nil) }
        #expect(store.record(for: nil)?.refreshToken == "rt_orig")
    }

    @Test("health reports refresh time and expiry, never token data")
    func healthShape() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = KimiSubscriptionStore(fileURL: dir.appendingPathComponent("k.enc"))
        #expect(store.health(for: nil) == nil)
        var r = Self.kimi("x")
        r.lastRefreshedAt = Date(timeIntervalSince1970: 1_000)
        r.expiresAt = Date(timeIntervalSince1970: 2_000_000_000)  // whole seconds: the JSON epoch round trip drops sub-µs bits
        try store.setShared(r)
        let h = try #require(store.health(for: nil))
        #expect(h.lastRefreshedAt == Date(timeIntervalSince1970: 1_000))
        #expect(h.accessExpiresAt == r.expiresAt)
        let json = h.stateJSON
        #expect(json["lastRefreshedAt"] as? Double == 1_000)
        #expect(Set(json.keys).isSubset(of: ["lastRefreshedAt", "accessExpiresAt", "reauthRequiredAt", "storeUnreadable"]))
        #expect(SubscriptionLoginHealth(stateJSON: json) == h)
    }
}
