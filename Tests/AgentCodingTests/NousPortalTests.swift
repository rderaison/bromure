import Foundation
import Testing
@testable import bromure_ac

/// Stands in for portal.nousresearch.com's token endpoint: records how each
/// refresh was sent, answers with a fixed status (200 = a rotated token set),
/// optionally as the Portal's edge firewall (`x-vercel-mitigated`).
final class FakeNousTokenEndpoint: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lock = NSLock()
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var mitigated = false
    nonisolated(unsafe) static var lastHeader: String?
    nonisolated(unsafe) static var lastBody = ""

    static func reset(status: Int = 200, mitigated: Bool = false) {
        lock.lock(); posts = 0; self.status = status; self.mitigated = mitigated
        lastHeader = nil; lastBody = ""; lock.unlock()
    }
    static var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == NousRegion.portalHost
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        Self.lock.lock()
        Self.posts += 1
        let n = Self.posts, status = Self.status, mitigated = Self.mitigated
        Self.lastHeader = request.value(forHTTPHeaderField: "x-nous-refresh-token")
        Self.lastBody = String(decoding: body, as: UTF8.self)
        Self.lock.unlock()
        let json: [String: Any] = status == 200
            ? ["access_token": NousPortalTests.jwt(["exp": 2_000_000_000, "scope": "inference:invoke", "n": n]),
               "refresh_token": "real-refresh-new\(n)", "expires_in": 900,
               "inference_base_url": "https://inference-api.nousresearch.com/v1"]
            : ["error": "invalid_grant"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: mitigated ? ["x-vercel-mitigated": "challenge"] : nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Hermes Agent's Nous Portal sign-in: the host keeps the real (rotating)
/// login, the guest only stand-ins; the proxy swaps the access token on the
/// Nous hosts alone and answers a stand-in refresh itself.
@Suite("Nous Portal (Hermes) sign-in", .serialized)
struct NousPortalTests {

    static func jwt(_ claims: [String: Any]) -> String {
        func seg(_ o: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return seg(["alg": "RS256", "typ": "JWT"]) + "." + seg(claims) + ".c2lnbmF0dXJlLXJlYWw"
    }

    private static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return (Data(base64Encoded: s).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("s.enc")
    }
    private static var stubbed: URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeNousTokenEndpoint.self]
        return cfg
    }
    private static func record(_ tag: String = "orig", expiresIn: TimeInterval = 6 * 3600) -> NousSubscriptionRecord {
        NousSubscriptionRecord(accessToken: jwt(["exp": 2_000_000_000, "scope": "inference:invoke", "sub": tag]),
                               refreshToken: "real-refresh-\(tag)",
                               expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
    }
    private static func refreshRequest(refresh: String, body: String = "grant_type=refresh_token&client_id=hermes-cli") -> Data {
        Data(("POST /api/oauth/token HTTP/1.1\r\nHost: portal.nousresearch.com\r\n"
            + "x-nous-refresh-token: \(refresh)\r\n"
            + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body).utf8)
    }
    private static func status(_ reply: Data) -> Int {
        let parts = String(decoding: reply.prefix(64), as: UTF8.self).split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }
    private static func json(_ reply: Data) -> [String: Any] {
        guard let r = reply.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: reply.subdata(in: r.upperBound..<reply.count))) as? [String: Any]) ?? [:]
    }

    // MARK: - Hosts

    @Test("the real token goes to the Nous inference hosts and the Portal only, by exact name")
    func hosts() {
        #expect(NousRegion.isSubscriptionHost("inference-api.nousresearch.com"))
        #expect(NousRegion.isSubscriptionHost("WELCOME-API.nousresearch.com"))
        #expect(NousRegion.isSubscriptionHost("portal.nousresearch.com"))
        for h in ["telemetry.nousresearch.com", "hermes-agent.nousresearch.com", "nousresearch.com",
                  "inference-api.nousresearch.com.evil.example", "evilinference-api.nousresearch.com"] {
            #expect(!NousRegion.isSubscriptionHost(h), "\(h)")
        }
        // On the Portal, only the account read: its other endpoints act on the
        // account with the same bearer (charges, cloud agents, OAuth clients).
        #expect(NousRegion.isSubscriptionRequest(host: "inference-api.nousresearch.com", method: "POST", path: "/v1/chat/completions"))
        #expect(NousRegion.isSubscriptionRequest(host: "portal.nousresearch.com", method: "GET", path: "/api/oauth/account?x=1"))
        for (m, path) in [("POST", "/api/billing/charge"), ("POST", "/api/oauth/self-hosted-client"),
                          ("GET", "/api/cloud/agents"), ("POST", "/api/oauth/account"),
                          ("GET", "/api/oauth/account/../../billing/state"), ("GET", "/api/oauth/accounts")] {
            #expect(!NousRegion.isSubscriptionRequest(host: "portal.nousresearch.com", method: m, path: path), "\(m) \(path)")
        }
        #expect(!NousRegion.isSubscriptionRequest(host: "telemetry.nousresearch.com", method: "GET", path: "/api/oauth/account"))
        #expect(NousRegion.allowedInferenceBaseURL("https://welcome-api.nousresearch.com/v1/") == "https://welcome-api.nousresearch.com/v1")
        #expect(NousRegion.allowedInferenceBaseURL("http://inference-api.nousresearch.com/v1") == nil)
        #expect(NousRegion.allowedInferenceBaseURL("https://attacker.example/v1") == nil)
    }

    // MARK: - Stand-ins

    @Test("the access stand-in keeps the invoke scope, lives for years and is marked")
    func accessStandIn() throws {
        let rec = Self.record()
        let pid = UUID()
        let standIn = NousStandIn.access(realAccess: rec.accessToken, profileID: pid)
        #expect(standIn != rec.accessToken)
        #expect(NousStandIn.isAccess(standIn))
        #expect(!NousStandIn.isAccess(rec.accessToken))
        let c = Self.claims(standIn)
        #expect(c["scope"] as? String == "inference:invoke")
        let exp = try #require(c["exp"] as? Int)
        #expect(Double(exp) > Date().addingTimeInterval(5 * 365 * 24 * 3600).timeIntervalSince1970)
        let refresh = NousStandIn.refresh(realRefresh: rec.refreshToken, profileID: pid)
        #expect(NousStandIn.isRefresh(refresh) && !refresh.contains(rec.refreshToken))
        #expect(!NousStandIn.isRefresh(rec.refreshToken))
    }

    @Test("the sign-in reply the guest hears carries stand-ins, never the real tokens")
    func signInReply() {
        let realAccess = Self.jwt(["exp": 2_000_000_000, "scope": "inference:invoke"])
        let real: [String: Any] = ["access_token": realAccess, "refresh_token": "real-r", "expires_in": 900,
                                   "token_type": "Bearer", "inference_base_url": "https://welcome-api.nousresearch.com/v1"]
        let out = NousStandIn.reply(from: real, access: "A", refresh: "R")
        #expect(out["access_token"] as? String == "A")
        #expect(out["refresh_token"] as? String == "R")
        #expect((out["expires_in"] as? Int ?? 0) > 365 * 24 * 3600)
        #expect(out["inference_base_url"] as? String == "https://welcome-api.nousresearch.com/v1")
        let flat = String(decoding: try! JSONSerialization.data(withJSONObject: out), as: UTF8.self)
        #expect(!flat.contains("real-r") && !flat.contains(realAccess))
    }

    @Test("auth.json: the Nous login as stand-ins, the user's other logins kept")
    func authFileMerge() throws {
        let rec = Self.record()
        let pid = UUID()
        let existing: [String: Any] = [
            "version": 1, "active_provider": "openrouter",
            "providers": ["openrouter": ["api_key": "user-own"]],
            "credential_pool": ["nous": [["access_token": "old"]], "openrouter": [["x": 1]]],
        ]
        let doc = NousStandIn.authFile(existing: existing, record: rec, profileID: pid)
        let providers = try #require(doc["providers"] as? [String: Any])
        #expect((providers["openrouter"] as? [String: Any])?["api_key"] as? String == "user-own")
        let nous = try #require(providers["nous"] as? [String: Any])
        let access = try #require(nous["access_token"] as? String)
        #expect(NousStandIn.isAccess(access))
        #expect(nous["agent_key"] as? String == access)
        #expect(NousStandIn.isRefresh(try #require(nous["refresh_token"] as? String)))
        #expect(nous["client_id"] as? String == "hermes-cli")
        #expect(nous["inference_base_url"] as? String == NousRegion.defaultInferenceBaseURL)
        #expect(doc["active_provider"] as? String == "openrouter", "the user's choice stays")
        #expect((doc["credential_pool"] as? [String: Any])?["nous"] == nil, "an old pool entry goes")
        #expect((doc["credential_pool"] as? [String: Any])?["openrouter"] != nil)
        let flat = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        #expect(!flat.contains(rec.accessToken) && !flat.contains(rec.refreshToken))
        // A fresh home: Nous is the active provider.
        #expect(NousStandIn.authFile(existing: nil, record: rec, profileID: pid)["active_provider"] as? String == "nous")
    }

    @Test("a token reply becomes a record: the JWT's own expiry, an allowed base URL only")
    func recordFromReply() throws {
        let access = Self.jwt(["exp": 2_000_000_000])
        let rec = try #require(NousSubscriptionRecord.from(tokenReply: [
            "access_token": access, "refresh_token": "r", "expires_in": 900,
            "inference_base_url": "https://attacker.example/v1", "scope": "inference:invoke"]))
        #expect(rec.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(rec.inferenceBaseURL == nil)
        #expect(rec.scope == "inference:invoke")
        #expect(NousSubscriptionRecord.from(tokenReply: ["refresh_token": "r"]) == nil)
        // A refresh that doesn't rotate keeps the token it was spent with.
        #expect(NousSubscriptionRecord.from(tokenReply: ["access_token": access], previousRefresh: "keep")?.refreshToken == "keep")
    }

    @Test("the sign-in machine's auth.json is read for the real login, never a stand-in")
    @MainActor
    func readAuthFile() throws {
        let dir = Self.tempURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        let real = Self.jwt(["exp": 2_000_000_000, "scope": "inference:invoke"])
        let doc: [String: Any] = ["version": 1, "providers": ["nous": [
            "access_token": real, "refresh_token": "real-r",
            "inference_base_url": "https://inference-api.nousresearch.com/v1"]]]
        try JSONSerialization.data(withJSONObject: doc).write(to: url)
        let rec = try #require(ACAppDelegate.readNousAuthFile(at: url))
        #expect(rec.accessToken == real && rec.refreshToken == "real-r")
        #expect(rec.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        // Bromure's own seed is not a sign-in.
        let seeded = NousStandIn.authFile(existing: nil, record: Self.record(), profileID: UUID())
        try JSONSerialization.data(withJSONObject: seeded).write(to: url)
        #expect(ACAppDelegate.readNousAuthFile(at: url) == nil)
    }

    // MARK: - Store + refresher

    @Test("a refresh sends the token in the x-nous-refresh-token header and persists the rotation")
    func refreshRotates() async throws {
        FakeNousTokenEndpoint.reset()
        let store = NousSubscriptionStore(fileURL: Self.tempURL())
        let pid = UUID()
        try store.setOverride(Self.record("orig", expiresIn: 30), for: pid)
        let r = NousSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let access = try await r.accessToken(for: pid)
        #expect(FakeNousTokenEndpoint.postCount == 1)
        #expect(FakeNousTokenEndpoint.lastHeader == "real-refresh-orig")
        #expect(!FakeNousTokenEndpoint.lastBody.contains("real-refresh-orig"), "never in the form")
        #expect(FakeNousTokenEndpoint.lastBody.contains("grant_type=refresh_token"))
        #expect(FakeNousTokenEndpoint.lastBody.contains("client_id=hermes-cli"))
        let rec = try #require(store.record(for: pid))
        #expect(rec.accessToken == access)
        #expect(rec.refreshToken == "real-refresh-new1")
        #expect(rec.lastRefreshedAt != nil)
        // Fresh now: no second spend of a single-use token.
        _ = try await r.accessToken(for: pid)
        #expect(FakeNousTokenEndpoint.postCount == 1)
    }

    @Test("a rejected refresh flags the sign-in; the Portal's edge firewall doesn't")
    func refreshRejection() async throws {
        FakeNousTokenEndpoint.reset(status: 401)
        let store = NousSubscriptionStore(fileURL: Self.tempURL())
        let pid = UUID()
        try store.setOverride(Self.record("a", expiresIn: 30), for: pid)
        let r = NousSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        await #expect(throws: NousSubscriptionError.self) { _ = try await r.accessToken(for: pid) }
        #expect(store.reauthRequiredAt(for: pid) != nil)
        await #expect(throws: NousSubscriptionError.self) { _ = try await r.accessToken(for: pid) }
        #expect(FakeNousTokenEndpoint.postCount == 1, "a flagged login is never refreshed again")

        FakeNousTokenEndpoint.reset(status: 403, mitigated: true)
        let store2 = NousSubscriptionStore(fileURL: Self.tempURL())
        try store2.setOverride(Self.record("b", expiresIn: 30), for: pid)
        let r2 = NousSubscriptionRefresher(store: store2, sessionConfiguration: Self.stubbed)
        do { _ = try await r2.accessToken(for: pid); Issue.record("expected a failure") } catch let e as NousSubscriptionError {
            #expect(!e.isRejection)
        }
        #expect(store2.reauthRequiredAt(for: pid) == nil)
    }

    @Test("a refresh that a newer sign-in superseded is discarded")
    func supersededRefresh() throws {
        let store = NousSubscriptionStore(fileURL: Self.tempURL())
        try store.setShared(Self.record("new-sign-in"))
        let committed = try store.commitRefresh(Self.record("rotated"), slotKey: "shared",
                                                replacing: "real-refresh-old")
        #expect(!committed)
        #expect(store.record(for: nil)?.refreshToken == "real-refresh-new-sign-in")
    }

    // MARK: - Proxy

    @Test("a stand-in refresh is answered on the proxy with fresh stand-ins, never sent on")
    func standInRefreshOnProxy() async throws {
        FakeNousTokenEndpoint.reset()
        let store = NousSubscriptionStore(fileURL: Self.tempURL())
        let pid = UUID()
        try store.setOverride(Self.record(), for: pid)
        let refresher = NousSubscriptionRefresher(store: store, sessionConfiguration: Self.stubbed)
        let saved = HTTPMitmConnection.nousSubscriptionProvider
        HTTPMitmConnection.nousSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.nousSubscriptionProvider = saved }

        let standIn = NousStandIn.refresh(realRefresh: "real-refresh-orig", profileID: pid)
        let reply = try #require(await HTTPMitmConnection.answerStandInRefresh(
            host: "portal.nousresearch.com", method: "POST", path: "/api/oauth/token",
            rawRequest: Self.refreshRequest(refresh: standIn), profileID: pid))
        #expect(Self.status(reply) == 200)
        let body = Self.json(reply)
        let access = try #require(body["access_token"] as? String)
        #expect(NousStandIn.isAccess(access))
        #expect(store.profileForBogusKey(access) == pid)
        #expect(NousStandIn.isRefresh(try #require(body["refresh_token"] as? String)))
        #expect(FakeNousTokenEndpoint.postCount == 1, "the host refreshed the real login")
        let flat = String(decoding: reply, as: UTF8.self)
        #expect(!flat.contains("real-refresh"))

        // A genuine refresh (the sign-in machine's own) goes on untouched;
        // so does a device-code poll and a refresh to another host.
        #expect(await HTTPMitmConnection.answerStandInRefresh(
            host: "portal.nousresearch.com", method: "POST", path: "/api/oauth/token",
            rawRequest: Self.refreshRequest(refresh: "real-refresh-x"), profileID: pid) == nil)
        #expect(await HTTPMitmConnection.answerStandInRefresh(
            host: "portal.nousresearch.com", method: "POST", path: "/api/oauth/token",
            rawRequest: Self.refreshRequest(
                refresh: standIn,
                body: "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=d&client_id=hermes-cli"),
            profileID: pid) == nil)
        #expect(await HTTPMitmConnection.answerStandInRefresh(
            host: "evil.example", method: "POST", path: "/api/oauth/token",
            rawRequest: Self.refreshRequest(refresh: standIn), profileID: pid) == nil)
    }

    @Test("a stand-in is this workspace's only while it has a Nous login")
    func standInRecognition() throws {
        let store = NousSubscriptionStore(fileURL: Self.tempURL())
        let pid = UUID()
        let saved = HTTPMitmConnection.nousSubscriptionProvider
        let refresher = NousSubscriptionRefresher(store: store)
        HTTPMitmConnection.nousSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.nousSubscriptionProvider = saved }
        let standIn = NousStandIn.access(realAccess: Self.record().accessToken, profileID: pid)
        #expect(!HTTPMitmConnection.isNousStandIn(standIn, profileID: pid))
        try store.setOverride(Self.record(), for: pid)
        #expect(HTTPMitmConnection.isNousStandIn(standIn, profileID: pid))
        #expect(!HTTPMitmConnection.isNousStandIn("sk-user-own-key", profileID: pid))
    }

    @Test("the sign-in exchange is the device-code poll on the Portal; a refresh there isn't")
    @MainActor
    func captureEndpoint() {
        let ep = ACAppDelegate.tokenEndpoint(for: .nous)
        #expect(ep.hosts == ["portal.nousresearch.com"] && ep.path == "/api/oauth/token")
        let capture = SignInCapture(profileID: UUID(), hosts: ep.hosts, pathPrefix: ep.path,
                                    handle: { _, _ in nil })
        let poll = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id=hermes-cli&device_code=d".utf8)
        #expect(capture.matches(host: "portal.nousresearch.com", method: "POST", path: "/api/oauth/token", body: poll))
        let refresh = Data("grant_type=refresh_token&client_id=hermes-cli".utf8)
        #expect(!capture.matches(host: "portal.nousresearch.com", method: "POST", path: "/api/oauth/token", body: refresh))
    }

    // MARK: - Provider plumbing

    @Test("Nous is Hermes's alone: a sign-in, no key, never routed to another agent")
    func providerPlumbing() {
        #expect(ModelProvider.nous.supportsSubscription && ModelProvider.nous.isSignInOnly)
        #expect(ModelProvider.nous.canRoute(.hermes, native: .anthropic))
        for agent in ModelAgent.allCases where agent != .hermes {
            #expect(!ModelProvider.nous.canRoute(agent, native: .anthropic), "\(agent)")
        }
        #expect(ModelProvider.nous.openAICompatibleBase == nil)
        #expect(ModelProvider.nous.nativeAgent == .hermes)
        #expect(!Profile.OmpProvider.ompChoices.contains(.nous))
        #expect(Profile.OmpProvider.nous.apiKeyEnvVar.isEmpty)
        #expect(SubscriptionProvider(rawValue: Profile.Tool.hermes.rawValue) == .nous)
        #expect(SubscriptionProvider.nous.scratchTool == .hermes)
        #expect(SubscriptionProvider.nous.capturesFromHomeDir)
        #expect(ModelProvider.nous.subscriptionKey == "hermes")
    }

    @Test("the login: a fresh device-code sign-in, no shared-credential import prompt")
    @MainActor
    func loginCommand() {
        let cmd = RegistrationLaunch.loginCommand(for: .nous)
        #expect(cmd.contains("hermes auth add nous --type oauth"))
        #expect(cmd.hasPrefix("rm -f ~/.hermes/shared/nous_auth.json;"))
        #expect(ACAppDelegate.loginCommand(for: .nous) == cmd)
        let pattern = RegistrationLaunch.processPattern(for: .nous)
        let re = try! NSRegularExpression(pattern: pattern)
        let argv = "/home/ubuntu/.hermes/tools/python/bin/python3 -I -c import x auth add nous --type oauth"
        #expect(re.firstMatch(in: argv, range: NSRange(argv.startIndex..., in: argv)) != nil)
    }

    @Test("Hermes on Nous: provider nous, no key variable, every provider key hidden")
    func hermesSettingsOnNous() throws {
        var p = Profile(name: "h", tool: .hermes, authMode: .subscription)
        let s = try #require(SessionDisk.hermesSettings(profile: p))
        let model = try #require(s["model"] as? [String: String])
        #expect(model["provider"] == "nous")
        #expect(model["base_url"] == nil && model["key_env"] == nil)
        #expect(s["key_var"] as? String == "")
        let hidden = SessionDisk.hermesHiddenKeyEnvVars(profile: p)
        for v in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "NOUS_API_KEY"] {
            #expect(hidden.contains(v), "\(v)")
        }
        #expect(!hidden.contains(""))
        // Switched to Nous by the Models pane (token mode, provider nous).
        p = Profile(name: "h", tool: .hermes, authMode: .token)
        p.ompProvider = .nous
        p.ompModel = "anthropic/claude-sonnet-5.5"
        #expect(SessionDisk.hermesUsesNous(p))
        let m2 = try #require(SessionDisk.hermesSettings(profile: p)?["model"] as? [String: String])
        #expect(m2["provider"] == "nous" && m2["default"] == "anthropic/claude-sonnet-5.5")
        // Local mode is never Nous.
        #expect(!SessionDisk.hermesUsesNous(Profile(name: "h", tool: .hermes, authMode: .local)))
    }

    @Test("the Models pane: a Nous model puts Hermes on its sign-in, never omp")
    func overlay() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .nous, useSubscription: true)]
        s.agentTiers[.hermes] = [.medium: ModelRef(source: .provider(.nous), modelID: "anthropic/claude-sonnet-5.5")]
        s.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.nous), modelID: "x")]
        let out = Profile(name: "w", tool: .hermes, authMode: .token)
            .overlaidWithGlobalModels(s, subscribed: [.nous])
        let hermes = out.allToolSpecs.first { $0.tool == .hermes }
        #expect(hermes?.effectiveOmpProvider == .nous)
        #expect(hermes?.authMode == .subscription)
        #expect(out.allToolSpecs.first { $0.tool == .omp }?.effectiveOmpProvider != .nous)
    }

    private static func runPy(_ script: String, _ args: [String]) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-"] + args
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        pipe.fileHandleForWriting.write(Data(script.utf8))
        try pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    @Test("the guest merges the seeded Nous stand-ins into auth.json, keeping the rest")
    func guestMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nous-merge-\(UUID().uuidString)")
        let store = ProfileStore(rootDir: root)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: Profile(name: "ws", tool: .hermes, authMode: .subscription),
                                     into: seedDir, terminalDefaults: .fallback)
        let rc = try String(contentsOf: seedDir.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        let start = try #require(rc.range(of: "<<'BROMURE_NOUS_AUTH'"))
        let afterLine = try #require(rc[start.upperBound...].firstIndex(of: "\n"))
        let end = try #require(rc.range(of: "\nBROMURE_NOUS_AUTH\n", range: afterLine..<rc.endIndex))
        let script = String(rc[rc.index(after: afterLine)..<end.lowerBound])
        #expect(script.contains(SubscriptionFakeMint.jwtSignatureMarker))

        let home = root.appendingPathComponent("home/.hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = home.appendingPathComponent("auth.json"), side = home.appendingPathComponent(".bromure-nous.json")
        let pid = UUID()
        let nous = try #require((NousStandIn.authFile(existing: nil, record: Self.record(), profileID: pid)["providers"]
            as? [String: Any])?["nous"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: nous).write(to: side)
        func read() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        }

        // No auth.json yet: created, private, Nous active.
        #expect(try Self.runPy(script, [auth.path, side.path]) == 0)
        var doc = try read()
        #expect(doc["active_provider"] as? String == "nous")
        #expect(((doc["providers"] as? [String: Any])?["nous"] as? [String: Any])?["access_token"] as? String
                == nous["access_token"] as? String)
        let perms = try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // The user's own logins, and a real (non-Bromure) Nous login: merged over.
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "active_provider": "openrouter",
            "providers": ["openrouter": ["k": "v"], "nous": ["access_token": "real.jwt.sig"]]]).write(to: auth)
        #expect(try Self.runPy(script, [auth.path, side.path]) == 0)
        doc = try read()
        #expect(doc["active_provider"] as? String == "openrouter")
        #expect((doc["providers"] as? [String: Any])?["openrouter"] != nil)
        #expect(((doc["providers"] as? [String: Any])?["nous"] as? [String: Any])?["access_token"] as? String
                == nous["access_token"] as? String)

        // Already a Bromure stand-in (an older one): left exactly as it is.
        let older = NousStandIn.access(realAccess: Self.record("older").accessToken, profileID: pid)
        let held = try JSONSerialization.data(withJSONObject: ["providers": ["nous": ["access_token": older]]])
        try held.write(to: auth)
        #expect(try Self.runPy(script, [auth.path, side.path]) == 0)
        #expect(try Data(contentsOf: auth) == held)

        // A file it can't read: never written over.
        try Data("{not json".utf8).write(to: auth)
        _ = try Self.runPy(script, [auth.path, side.path])
        #expect(try Data(contentsOf: auth) == Data("{not json".utf8))
    }

    @Test("an ext4 seed carries the sidecar only while Hermes is on Nous, and deletes it after")
    func seedManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nous-seed-\(UUID().uuidString)")
        let store = ProfileStore(rootDir: root)
        let seedDir = root.appendingPathComponent("seed")
        let p = Profile(name: "ws", tool: .hermes, authMode: .subscription)
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        let files = seedDir.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files.appendingPathComponent(".hermes"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: files.appendingPathComponent(Profile.hermesNousSidecar))
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)
        var manifest = try String(contentsOf: seedDir.appendingPathComponent("manifest.tsv"), encoding: .utf8)
        #expect(manifest.contains("o\t600\t\(Profile.hermesNousSidecar)"))
        #expect(!manifest.contains("\t.hermes/auth.json"), "Hermes's own file is never the seed's")
        try FileManager.default.removeItem(at: files.appendingPathComponent(Profile.hermesNousSidecar))
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)
        manifest = try String(contentsOf: seedDir.appendingPathComponent("manifest.tsv"), encoding: .utf8)
        #expect(manifest.contains("d\t-\t\(Profile.hermesNousSidecar)"))
    }

    @Test("a sign-in machine for Hermes starts its Nous login, not a chat")
    func registrationAutoLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nous-rc-\(UUID().uuidString)")
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .subscription)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        let rc = try String(contentsOf: seedDir.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        #expect(rc.contains("hermes) rm -f ~/.hermes/shared/nous_auth.json; hermes auth add nous --type oauth ;;"))
    }
}
