import Foundation
import Testing
@testable import bromure_ac

/// Stands in for platform.claude.com's token endpoint: counts refresh POSTs,
/// answers slowly (so concurrent callers overlap the in-flight refresh) with a
/// rotated pair, and rejects a refresh token that was already spent — like a
/// rotating OAuth server does.
final class FakeClaudeTokenEndpoint: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var spent: Set<String> = []
    nonisolated(unsafe) static var status = 200

    static func reset(status: Int = 200) {
        lock.lock(); posts = 0; spent = []; self.status = status; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.claude.com"
    }
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
        let status = reused ? 400 : Self.status
        Self.lock.unlock()
        let json: [String: Any] = status == 200
            ? ["access_token": "sk-ant-oat01-new\(n)", "refresh_token": "sk-ant-ort01-new\(n)", "expires_in": 28800]
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

@Suite("Claude subscription: one grant, one refresher", .serialized)
struct ClaudeSubscriptionRefreshTests {
    private func tempStore() -> (ClaudeSubscriptionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-sub-\(UUID())", isDirectory: true)
        return (ClaudeSubscriptionStore(fileURL: dir.appendingPathComponent("c.enc")), dir)
    }
    private func expired(_ refresh: String = "sk-ant-ort01-orig") -> ClaudeSubscriptionRecord {
        ClaudeSubscriptionRecord(accessToken: "sk-ant-oat01-orig", refreshToken: refresh,
                                 expiresAt: .distantPast, savedAt: Date())
    }
    private func refresher(_ store: ClaudeSubscriptionStore) -> ClaudeSubscriptionRefresher {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeClaudeTokenEndpoint.self]
        return ClaudeSubscriptionRefresher(store: store, sessionConfiguration: cfg)
    }

    @Test("concurrent callers on an expired token share ONE refresh")
    func singleFlight() async throws {
        FakeClaudeTokenEndpoint.reset()
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.setShared(expired())
        let r = refresher(store)
        // Twenty requests from several "VMs" (all on the shared login).
        let ids = (0..<5).map { _ in UUID() }
        let tokens = try await withThrowingTaskGroup(of: String.self) { g in
            for i in 0..<20 { g.addTask { try await r.accessToken(for: ids[i % ids.count]) } }
            var out: [String] = []
            for try await t in g { out.append(t) }
            return out
        }
        #expect(FakeClaudeTokenEndpoint.posts == 1)
        #expect(Set(tokens) == ["sk-ant-oat01-new1"])
        #expect(store.record(for: nil)?.refreshToken == "sk-ant-ort01-new1")
        #expect(store.reauthRequiredAt(for: nil) == nil)
    }

    @Test("a refresh finishing after a re-registration doesn't clobber it")
    func compareAndSwap() throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.setShared(expired("sk-ant-ort01-A"))
        // The user signs in again while a refresh of grant A is in flight.
        try store.setShared(expired("sk-ant-ort01-B"))
        let late = ClaudeSubscriptionRecord(accessToken: "sk-ant-oat01-A2", refreshToken: "sk-ant-ort01-A2",
                                            expiresAt: Date().addingTimeInterval(3600), savedAt: Date())
        #expect(!store.commitRefresh(late, slotKey: "shared", replacing: "sk-ant-ort01-A"))
        #expect(store.record(for: nil)?.refreshToken == "sk-ant-ort01-B")
        // A stale rejection of A mustn't flag B either.
        store.setReauthRequired(true, slotKey: "shared", ifRefreshTokenIs: "sk-ant-ort01-A")
        #expect(store.reauthRequiredAt(for: nil) == nil)
    }

    @Test("an automation clone aliases its base's grant instead of copying it")
    func cloneAlias() throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let base = UUID(), clone = UUID()
        try store.setShared(expired("sk-ant-ort01-shared"))
        try store.setOverride(expired("sk-ant-ort01-base"), for: base)
        try store.alias(clone, to: base)
        #expect(store.slot(for: clone)?.key == base.uuidString)
        #expect(!store.hasProfileRecord(clone))
        // A refresh through the clone rotates the BASE's slot — one grant.
        let rotated = ClaudeSubscriptionRecord(accessToken: "sk-ant-oat01-r", refreshToken: "sk-ant-ort01-r",
                                               expiresAt: Date().addingTimeInterval(3600), savedAt: Date())
        #expect(store.commitRefresh(rotated, slotKey: store.slot(for: clone)!.key, replacing: "sk-ant-ort01-base"))
        #expect(store.record(for: base)?.refreshToken == "sk-ant-ort01-r")
        try store.forget(for: clone)
        #expect(store.slot(for: clone)?.key == "shared")
        #expect(store.record(for: base)?.refreshToken == "sk-ant-ort01-r")
    }

    @Test("a rejected refresh flags re-auth; a transient one keeps a still-valid token")
    func failureClassification() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        // Transient 503 while the token is inside the 5-min early window.
        FakeClaudeTokenEndpoint.reset(status: 503)
        try store.setShared(ClaudeSubscriptionRecord(
            accessToken: "sk-ant-oat01-live", refreshToken: "sk-ant-ort01-x",
            expiresAt: Date().addingTimeInterval(120), savedAt: Date()))
        let r = refresher(store)
        #expect(try await r.accessToken(for: nil) == "sk-ant-oat01-live")
        #expect(store.reauthRequiredAt(for: nil) == nil)
        // Rejected grant on an expired token → throws a rejection + flags.
        FakeClaudeTokenEndpoint.reset(status: 400)
        try store.setShared(expired("sk-ant-ort01-y"))
        do {
            _ = try await r.accessToken(for: nil)
            Issue.record("expected a rejection")
        } catch let e as ClaudeSubscriptionError {
            #expect(e.isRejection)
        }
        #expect(store.reauthRequiredAt(for: nil) != nil)
    }
}
