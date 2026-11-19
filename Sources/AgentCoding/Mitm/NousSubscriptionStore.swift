import Foundation

/// Nous Research's Portal, as Hermes Agent signs in to it (verified against
/// NousResearch/hermes-agent `hermes_cli/auth_nous.py`, `auth_device_flow.py`
/// and `auth_constants.py`):
///   * an RFC 8628 device-code flow: `POST /api/oauth/device/code`, then
///     `POST /api/oauth/token` (`grant_type=…:device_code`), public client id
///     `hermes-cli`, scope `inference:invoke`;
///   * the access token is itself the inference credential — a JWT carrying
///     `inference:invoke` and an `exp`, sent as `Authorization: Bearer` to
///     `inference-api.nousresearch.com/v1` (the free tier's
///     `welcome-api.nousresearch.com/v1`); Hermes refreshes it once it is
///     within 120 s of `exp`;
///   * a refresh is `POST /api/oauth/token` with the refresh token in an
///     `x-nous-refresh-token` HEADER and `grant_type=refresh_token&client_id=…`
///     in the form. Refresh tokens are single-use and rotating: a reused one
///     revokes the whole chain — so the host alone ever refreshes;
///   * the login lands in `~/.hermes/auth.json` under `providers.nous`.
public enum NousRegion {
    public static let portalHost = "portal.nousresearch.com"
    public static let portalBaseURL = "https://portal.nousresearch.com"
    public static let tokenURL = URL(string: "https://portal.nousresearch.com/api/oauth/token")!
    public static let tokenPath = "/api/oauth/token"
    public static let clientID = "hermes-cli"
    public static let scope = "inference:invoke"
    public static let defaultInferenceBaseURL = "https://inference-api.nousresearch.com/v1"

    /// Hosts the Portal's inference JWT is good for — Hermes's own allowlist
    /// (`_ALLOWED_NOUS_INFERENCE_HOSTS`). Exact names only: a suffix match
    /// would hand the real token to any other `*.nousresearch.com` host
    /// (telemetry, assets, the installer's).
    public static let inferenceHosts: Set<String> = [
        "inference-api.nousresearch.com",
        "welcome-api.nousresearch.com",
    ]

    /// The Nous Tool Gateway: a Portal subscription's managed tools (web
    /// search, image generation, voice, …) go to Nous's own vendor
    /// passthroughs, `<vendor>-gateway.nousresearch.com`, with the same
    /// bearer (Hermes `tools/managed_tool_gateway.py`, built with
    /// `build_vendor_gateway_url`); Nous calls the vendor with its own keys.
    /// Exactly one label ending in `-gateway`: no other Nous host, and no
    /// deeper name under one.
    public static func isToolGatewayHost(_ host: String) -> Bool {
        let h = host.lowercased()
        let suffix = "-gateway.nousresearch.com"
        guard h.hasSuffix(suffix) else { return false }
        let vendor = h.dropLast(suffix.count)
        return !vendor.isEmpty && vendor.first != "-"
            && vendor.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The hosts a Nous stand-in may be swapped on (exact names). Which
    /// requests there actually get the real token: `isSubscriptionRequest`.
    public static func isSubscriptionHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return inferenceHosts.contains(h) || h == portalHost || isToolGatewayHost(h)
    }

    /// Whether this request gets the real access token in place of the
    /// stand-in: anything on the inference hosts and the Tool Gateway's
    /// vendor hosts (that's what the token is for), and on the Portal only Hermes's account read
    /// (`GET /api/oauth/account`). Every other Portal endpoint takes the
    /// same bearer to act on the account — charges, upgrades, cloud agents,
    /// OAuth client registration — and one of them handing back a credential
    /// of its own would put a real secret in the machine; they see the
    /// stand-in and refuse it.
    public static func isSubscriptionRequest(host: String, method: String, path: String) -> Bool {
        let h = host.lowercased()
        if inferenceHosts.contains(h) || isToolGatewayHost(h) { return true }
        guard h == portalHost, method.uppercased() == "GET" else { return false }
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return bare == "/api/oauth/account"
    }

    /// An inference base URL the Portal returned, kept only when it names one
    /// of the allowed hosts over https (Hermes applies the same allowlist).
    public static func allowedInferenceBaseURL(_ raw: String?) -> String? {
        guard let raw, let u = URL(string: raw), u.scheme == "https",
              let host = u.host?.lowercased(), inferenceHosts.contains(host) else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}

/// The stand-in tokens a workspace's guest holds in place of the real Nous
/// login: the access JWT re-minted with a far-future `exp` and a marked,
/// fake signature (Hermes decodes the claims locally — `inference:invoke`
/// must be there and `exp` far enough out that it never refreshes), and a
/// marked refresh token the proxy answers itself.
public enum NousStandIn {
    public static func access(realAccess: String, profileID: UUID) -> String {
        let salt = Data("nous-bogus-access:\(profileID)".utf8)
        return SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: realAccess, salt: salt)
            ?? SessionTokenPlan.deriveFake(prefix: "nous-brm-", real: realAccess, salt: salt,
                                           targetLength: max(40, realAccess.count))
    }

    public static func refresh(realRefresh: String, profileID: UUID) -> String {
        let salt = Data("nous-bogus-refresh:\(profileID)".utf8)
        return SessionTokenPlan.deriveFake(prefix: "nousrt-brm-", real: realRefresh, salt: salt,
                                           targetLength: max(40, realRefresh.count))
    }

    /// One of Bromure's Nous access stand-ins (any workspace, any age).
    public static func isAccess(_ token: String) -> Bool {
        SubscriptionFakeMint.isJWTFake(token) || token.hasPrefix("nous-brm-")
    }

    /// One of Bromure's Nous refresh stand-ins (any workspace, any age).
    public static func isRefresh(_ token: String) -> Bool { token.hasPrefix("nousrt-brm-") }

    /// `expires_in` the guest is told: far out, so Hermes never refreshes.
    public static let lifetime: TimeInterval = 10 * 365 * 24 * 3600

    /// The token reply carrying stand-ins in place of `reply`'s real tokens —
    /// what the guest's Hermes hears for its sign-in (the device-code poll
    /// that succeeded) and for a refresh the proxy answers. Every other field
    /// (`scope`, `token_type`, `inference_base_url`) is kept.
    public static func reply(from real: [String: Any], access: String, refresh: String) -> [String: Any] {
        var out = real
        out["access_token"] = access
        out["refresh_token"] = refresh
        out["expires_in"] = Int(lifetime)
        out.removeValue(forKey: "expires_at")
        if out["token_type"] == nil { out["token_type"] = "Bearer" }
        if out["scope"] == nil { out["scope"] = NousRegion.scope }
        return out
    }

    /// The refresh reply minted from the host's current real record.
    public static func refreshAnswer(record: NousSubscriptionRecord, profileID: UUID)
        -> (json: [String: Any], bogusAccess: String) {
        let bogusAccess = access(realAccess: record.accessToken, profileID: profileID)
        var real: [String: Any] = ["token_type": "Bearer", "scope": record.scope ?? NousRegion.scope]
        if let base = record.inferenceBaseURL { real["inference_base_url"] = base }
        return (reply(from: real, access: bogusAccess,
                      refresh: refresh(realRefresh: record.refreshToken, profileID: profileID)),
                bogusAccess)
    }

    /// `~/.hermes/auth.json` with the Nous login set to stand-ins, merged into
    /// what the file already holds (the user's other providers stay). Mirrors
    /// the state `_nous_device_code_login` saves: the invoke JWT is also the
    /// `agent_key`, the expiry ISO-8601. `active_provider` is only set when
    /// the file names none. Pure — see `NousPortalTests`.
    public static func authFile(existing: [String: Any]?, record: NousSubscriptionRecord,
                                profileID: UUID, now: Date = Date()) -> [String: Any] {
        var file = existing ?? [:]
        if file["version"] == nil { file["version"] = 1 }
        var providers = file["providers"] as? [String: Any] ?? [:]
        let bogusAccess = access(realAccess: record.accessToken, profileID: profileID)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let expires = iso.string(from: now.addingTimeInterval(lifetime))
        let state: [String: Any] = [
            "portal_base_url": NousRegion.portalBaseURL,
            "inference_base_url": record.inferenceBaseURL ?? NousRegion.defaultInferenceBaseURL,
            "client_id": NousRegion.clientID,
            "scope": record.scope ?? NousRegion.scope,
            "token_type": "Bearer",
            "access_token": bogusAccess,
            "refresh_token": refresh(realRefresh: record.refreshToken, profileID: profileID),
            "obtained_at": iso.string(from: now),
            "expires_at": expires,
            "expires_in": Int(lifetime),
            "tls": ["insecure": false, "ca_bundle": NSNull()] as [String: Any],
            "agent_key": bogusAccess,
            "agent_key_id": NSNull(),
            "agent_key_expires_at": expires,
            "agent_key_expires_in": Int(lifetime),
            "agent_key_reused": false,
            "agent_key_obtained_at": iso.string(from: now),
        ]
        providers["nous"] = state
        file["providers"] = providers
        if (file["active_provider"] as? String ?? "").isEmpty { file["active_provider"] = "nous" }
        // Hermes's credential pool mirrors `providers.nous` (its `device_code`
        // entry); a pool entry from an earlier login would carry the old
        // tokens — dropped, and Hermes reseeds it from the state above.
        if var pool = file["credential_pool"] as? [String: Any], pool["nous"] != nil {
            pool.removeValue(forKey: "nous")
            file["credential_pool"] = pool
        }
        return file
    }
}

public struct NousSubscriptionRecord: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var savedAt: Date
    /// Set when the Portal REJECTED a refresh (the grant is dead): only a new
    /// sign-in clears it. Never set by a plain access-token expiry.
    public var reauthRequiredAt: Date?
    /// When the HOST last refreshed this grant for real (nil: not since sign-in).
    public var lastRefreshedAt: Date?
    /// The inference base URL the Portal named for this account (the free
    /// tier's differs), when it is one of the allowed hosts.
    public var inferenceBaseURL: String?
    /// The scope the Portal granted.
    public var scope: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, savedAt: Date,
                reauthRequiredAt: Date? = nil, lastRefreshedAt: Date? = nil,
                inferenceBaseURL: String? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
        self.lastRefreshedAt = lastRefreshedAt
        self.inferenceBaseURL = inferenceBaseURL
        self.scope = scope
    }

    /// The access token's own expiry (its JWT `exp`), else `fallback`.
    public static func jwtExpiry(_ token: String, fallback: Date) -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return fallback }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let exp = (obj["exp"] as? Double) ?? (obj["exp"] as? Int).map(Double.init)
        else { return fallback }
        return Date(timeIntervalSince1970: exp)
    }

    /// The record for a token reply (the sign-in's device-code exchange, or
    /// the Portal's refresh answer). nil without an access token.
    public static func from(tokenReply json: [String: Any], savedAt: Date = Date(),
                            previousRefresh: String? = nil) -> NousSubscriptionRecord? {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? previousRefresh ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        return NousSubscriptionRecord(
            accessToken: access, refreshToken: refresh,
            expiresAt: jwtExpiry(access, fallback: Date().addingTimeInterval(expiresIn)),
            savedAt: savedAt,
            inferenceBaseURL: NousRegion.allowedInferenceBaseURL(json["inference_base_url"] as? String),
            scope: json["scope"] as? String)
    }
}

private struct NousSubscriptionFile: Codable {
    var shared: NousSubscriptionRecord?
    var perProfile: [String: NousSubscriptionRecord]
    /// profileID → the profile whose credential it uses (an automation clone
    /// → its base): one rotating grant lives in ONE slot, never copied.
    var aliases: [String: String]?
}

/// Host-owned storage + refresh for a Nous Portal login, shared across every
/// VM session — the Nous twin of ``KimiSubscriptionStore``.
public final class NousSubscriptionStore: @unchecked Sendable {
    private let lock = NSLock()
    private let backing: SubscriptionStoreFile<NousSubscriptionFile>
    /// Bogus access token in use by a session → its profile. In memory only:
    /// an older stand-in is recognised by its mark (see the proxy).
    private var bogusKeys: [String: UUID] = [:]

    /// Tests pass their own `fileURL` — never the user's real store.
    public init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        backing = SubscriptionStoreFile(
            fileURL: fileURL ?? supportDir.appendingPathComponent("nous-subscription.enc"),
            tag: "nous-sub", empty: { NousSubscriptionFile(shared: nil, perProfile: [:]) })
    }

    private func loadLocked() -> NousSubscriptionFile { backing.read() }

    @discardableResult
    private func mutate(_ body: (inout NousSubscriptionFile) throws -> Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try backing.mutate(body)
    }

    public var isUnreadable: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = backing.read()
        return backing.isUnreadable
    }

    var refreshLockURL: URL { backing.refreshLockURL }

    var failWritesForTesting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return backing.failWritesForTesting }
        set { lock.lock(); backing.failWritesForTesting = newValue; lock.unlock() }
    }

    public func health(for profileID: UUID?) -> SubscriptionLoginHealth? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        let unreadable = backing.isUnreadable
        let r = ownerKeyLocked(file, profileID).flatMap { file.perProfile[$0] } ?? file.shared
        guard r != nil || unreadable else { return nil }
        return SubscriptionLoginHealth(lastRefreshedAt: r?.lastRefreshedAt, accessExpiresAt: r?.expiresAt,
                                       reauthRequiredAt: r?.reauthRequiredAt, storeUnreadable: unreadable)
    }

    public func reauthRequiredAt(for profileID: UUID?) -> Date? {
        record(for: profileID)?.reauthRequiredAt
    }

    public func setReauthRequired(_ flagged: Bool, for profileID: UUID?) {
        setReauth(flagged, expected: nil) { file in self.ownerKeyLocked(file, profileID) ?? "shared" }
    }

    func setReauthRequired(_ flagged: Bool, slotKey: String, ifRefreshTokenIs expected: String) {
        setReauth(flagged, expected: expected) { _ in slotKey }
    }

    private func setReauth(_ flagged: Bool, expected: String?,
                           resolve: @escaping (NousSubscriptionFile) -> String) {
        let changed: Bool
        do {
            changed = try mutate { file in
                let key = resolve(file)
                guard var r = key == "shared" ? file.shared : file.perProfile[key],
                      expected == nil || r.refreshToken == expected,
                      (r.reauthRequiredAt != nil) != flagged else { return false }
                r.reauthRequiredAt = flagged ? Date() : nil
                if key == "shared" { file.shared = r } else { file.perProfile[key] = r }
                return true
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[nous-sub] couldn't \(flagged ? "flag" : "clear") the sign-in state: \(error)\n".utf8))
            return
        }
        if changed {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
    }

    public func hasProfileRecord(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().perProfile[profileID.uuidString] != nil
    }

    private func ownerKeyLocked(_ file: NousSubscriptionFile, _ profileID: UUID?) -> String? {
        guard let pid = profileID else { return nil }
        let owner = file.aliases?[pid.uuidString] ?? pid.uuidString
        return file.perProfile[owner] != nil ? owner : nil
    }

    public func slotKey(for profileID: UUID?) -> String {
        lock.lock(); defer { lock.unlock() }
        return ownerKeyLocked(loadLocked(), profileID) ?? "shared"
    }

    func record(forSlot key: String) -> NousSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        return key == "shared" ? file.shared : file.perProfile[key]
    }

    public func alias(_ profileID: UUID, to base: UUID) throws {
        try mutate { file in
            var aliases = file.aliases ?? [:]
            aliases[profileID.uuidString] = file.aliases?[base.uuidString] ?? base.uuidString
            file.aliases = aliases
            return true
        }
    }

    public func record(for profileID: UUID?) -> NousSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: NousSubscriptionRecord) throws {
        try mutate { $0.shared = record; return true }
    }

    public func setOverride(_ record: NousSubscriptionRecord, for profileID: UUID) throws {
        try mutate { $0.perProfile[profileID.uuidString] = record; return true }
    }

    /// Persist a refresh's rotated tokens into `slotKey` — only while that
    /// slot still holds `sentRefresh` (checked against the file as it is NOW,
    /// under the lock). Throws when the write fails: a rotated single-use
    /// token is never kept only in memory.
    func commitRefresh(_ record: NousSubscriptionRecord, slotKey: String,
                       replacing sentRefresh: String) throws -> Bool {
        try mutate { file in
            let current = slotKey == "shared" ? file.shared : file.perProfile[slotKey]
            guard let held = current, held.refreshToken == sentRefresh else { return false }
            var record = record
            record.savedAt = held.savedAt
            if slotKey == "shared" { file.shared = record } else { file.perProfile[slotKey] = record }
            return true
        }
    }

    public func forget(for profileID: UUID?) throws {
        try mutate { file in
            if let pid = profileID {
                file.perProfile[pid.uuidString] = nil
                file.aliases?[pid.uuidString] = nil
            } else { file.shared = nil }
            return true
        }
    }

    public func registerBogusKey(_ key: String, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        bogusKeys[key] = profileID
    }
    public func unregisterBogusKeys(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        bogusKeys = bogusKeys.filter { $0.value != profileID }
    }
    public func profileForBogusKey(_ key: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return bogusKeys[key]
    }
}

// MARK: - Refresher

public enum NousSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse
    case reauthRequired
    public var description: String {
        switch self {
        case .noCredential: return "no Nous Portal credential registered"
        case .refreshHTTP(let c): return "Nous Portal refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Nous Portal refresh returned an unexpected body"
        case .reauthRequired: return "the Nous Portal sign-in was rejected; sign in again from Bromure"
        }
    }

    public var isRejection: Bool {
        switch self {
        case .noCredential, .reauthRequired: return true
        case .refreshHTTP(let code): return (400...403).contains(code)
        case .malformedRefreshResponse: return false
        }
    }
}

public actor NousSubscriptionRefresher {
    private let store: NousSubscriptionStore
    /// Hermes refreshes 120 s before `exp`; the host keeps a wider margin.
    private static let refreshMargin: TimeInterval = 300
    static let forcedRefreshFloor: TimeInterval = 60

    private var lastRefreshAt: [String: Date] = [:]
    private let sessionConfiguration: URLSessionConfiguration

    public init(store: NousSubscriptionStore,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
    }

    /// The request the Portal expects for a refresh: the token in the
    /// `x-nous-refresh-token` header, the grant and client id in the form.
    static func refreshRequest(refreshToken: String) -> URLRequest {
        var req = URLRequest(url: NousRegion.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(refreshToken, forHTTPHeaderField: "x-nous-refresh-token")
        req.httpBody = Data("grant_type=refresh_token&client_id=\(NousRegion.clientID)".utf8)
        return req
    }

    /// A currently-valid access token, refreshing proactively near expiry.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw NousSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw NousSubscriptionError.reauthRequired }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }
        return try await singleFlight(profileID, force: false).access
    }

    /// The guest sent its stand-in refresh token: refresh the REAL login now,
    /// unless the slot was refreshed moments ago.
    @discardableResult
    public func refreshForStandIn(for profileID: UUID?) async throws -> Bool {
        guard let record = store.record(for: profileID) else { throw NousSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw NousSubscriptionError.reauthRequired }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor {
            return false
        }
        return try await singleFlight(profileID, force: true, unlessAccessIsNot: record.accessToken).refreshed
    }

    /// An upstream 401 on `stale`: force a real refresh (rate-limited per slot).
    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID),
              record.accessToken == stale, record.reauthRequiredAt == nil else { return }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor { return }
        _ = try? await singleFlight(profileID, force: true, unlessAccessIsNot: stale)
    }

    /// One refresh per storage slot at a time (the actor is reentrant at the
    /// network await; two callers would spend the same single-use token).
    private var inflight: [String: Task<(access: String, refreshed: Bool), Error>] = [:]
    private func singleFlight(_ profileID: UUID?, force: Bool,
                              unlessAccessIsNot seen: String? = nil) async throws -> (access: String, refreshed: Bool) {
        let slot = store.slotKey(for: profileID)
        if let running = inflight[slot] { return try await running.value }
        let task = Task { try await self.performRefresh(slot: slot, force: force, seen: seen) }
        inflight[slot] = task
        defer { inflight[slot] = nil }
        return try await task.value
    }

    private func performRefresh(slot: String, force: Bool, seen: String?) async throws -> (access: String, refreshed: Bool) {
        let held = try await SubscriptionRefreshLock.acquire(store.refreshLockURL)
        defer { SubscriptionRefreshLock.release(held) }
        guard let record = store.record(forSlot: slot) else { throw NousSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw NousSubscriptionError.reauthRequired }
        if !force, record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return (record.accessToken, false) }
        if force, let seen, record.accessToken != seen {
            return (record.accessToken, false)
        }
        let sent = record.refreshToken
        guard !sent.isEmpty else {
            store.setReauthRequired(true, slotKey: slot, ifRefreshTokenIs: sent)
            throw NousSubscriptionError.reauthRequired
        }

        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: Self.refreshRequest(refreshToken: sent))
        lastRefreshAt[slot] = Date()
        guard let http = response as? HTTPURLResponse else { throw NousSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            FileHandle.standardError.write(Data(
                "[nous-sub] refresh (\(slot)) HTTP \(http.statusCode): \(detail)\n".utf8))
            // The Portal's edge firewall answers a challenge with 403/429 and
            // `x-vercel-mitigated` — the edge, not the grant: never flagged
            // (Hermes keeps its credentials on it too).
            let mitigated = http.value(forHTTPHeaderField: "x-vercel-mitigated") != nil
            if (400...403).contains(http.statusCode), !mitigated {
                store.setReauthRequired(true, slotKey: slot, ifRefreshTokenIs: sent)
            }
            throw NousSubscriptionError.refreshHTTP(mitigated ? 503 : http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var updated = NousSubscriptionRecord.from(tokenReply: json, savedAt: record.savedAt,
                                                        previousRefresh: sent)
        else { throw NousSubscriptionError.malformedRefreshResponse }
        updated.lastRefreshedAt = Date()
        if updated.inferenceBaseURL == nil { updated.inferenceBaseURL = record.inferenceBaseURL }
        if updated.scope == nil { updated.scope = record.scope }

        let committed: Bool
        do {
            committed = try store.commitRefresh(updated, slotKey: slot, replacing: sent)
        } catch {
            FileHandle.standardError.write(Data(
                "[nous-sub] refresh (\(slot)) succeeded but the rotated token couldn't be saved: \(error)\n".utf8))
            throw error
        }
        guard committed else {
            if let now = store.record(forSlot: slot) { return (now.accessToken, false) }
            throw NousSubscriptionError.noCredential
        }
        FileHandle.standardError.write(Data(
            "[nous-sub] refreshed (\(slot)); next expiry in \(Int(updated.expiresAt.timeIntervalSinceNow))s\n".utf8))
        return (updated.accessToken, true)
    }
}
