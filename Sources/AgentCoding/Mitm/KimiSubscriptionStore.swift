import Foundation

/// Kimi Code region. The `@moonshot-ai/kimi-code` CLI ships two region
/// profiles — `mainland-cn` (the default, `*.kimi.com`) and `global`
/// (`*.kimi.ai`) — and a non-China account can only register and refresh
/// against the international `global` endpoints; the `.com` region rejects it.
/// Bromure therefore forces every Kimi session into the `global` region (the
/// guest gets `KIMI_CODE_OAUTH_HOST` / `KIMI_CODE_BASE_URL` from SessionDisk),
/// and the host-side refresh + proxy bearer swap follow the same hosts here.
public enum KimiRegion {
    /// OAuth device-flow + token host (international).
    public static let oauthHost = "auth.kimi.ai"
    /// Managed subscription API base (`…/coding/v1` is the OpenAI-compatible surface).
    public static let baseURL = "https://api.kimi.ai/coding/v1"
    /// Fusion's non-`/v1` base for the subscription leg.
    public static let apiBase = "https://api.kimi.ai/coding"
    /// The token endpoint the host refreshes against.
    public static let tokenURL = URL(string: "https://auth.kimi.ai/api/oauth/token")!

    /// Whether `host` is Kimi subscription API traffic the proxy should swap
    /// the bearer on: the managed API host on the international `.ai` (what
    /// Bromure uses now) and the legacy `.com` (a credential registered before
    /// the switch), so a stale session keeps working until it re-registers.
    /// Deliberately NOT every `*.kimi.ai` host — the CLI also posts to
    /// `telemetry-logs.kimi.ai`, and a suffix match injected the real
    /// subscription token into those (verified in a live run); the auth host is
    /// handled by the stand-in refresh step, not the swap.
    public static func isSubscriptionHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "api.kimi.ai" || h == "api.kimi.com"
    }
}

/// Host-owned storage + refresh for a Moonshot **Kimi Code** subscription
/// credential, shared across every VM session. The Kimi twin of
/// ``GrokSubscriptionStore`` — see ``ClaudeSubscriptionStore`` for the
/// overall rationale.
///
/// Kimi specifics (verified against MoonshotAI/kimi-code `packages/oauth`):
///   * Auth is an RFC 8628 device-code flow against `https://auth.kimi.ai`
///     (international/global region; the `.com` default is China-only)
///     (`/api/oauth/device_authorization` + `/api/oauth/token`), public
///     client id below.
///   * Credentials live in `~/.kimi-code/credentials/<name>.json` (managed
///     flow name: `kimi-code`), snake_case wire shape
///     `{ access_token, refresh_token, expires_at (unix s), scope,
///     token_type, expires_in }`.
///   * Subscription API calls go to `api.kimi.ai/coding/v1` with
///     `Authorization: Bearer <access>`.
///   * Refresh is a form POST to `https://auth.kimi.ai/api/oauth/token`
///     (`grant_type=refresh_token`), refreshed ~5 min before `expires_at`.
///     We seed `expires_at` far in the future so the guest never refreshes;
///     the host owns refresh.
///   * No vsock token agent — like Grok, the credentials file lives in the
///     registration VM's host-mounted home dir, so the host seeds (write)
///     and captures (read) it directly. `/login` also writes the managed
///     provider + model list into `~/.kimi-code/config.toml`; we capture
///     that file verbatim so a seeded guest starts with a working config
///     without ever doing OAuth itself.

/// Credentials filename (sans `.json`) the managed OAuth flow stores under.
public let kimiManagedCredentialName = "kimi-code"

/// The stand-in (bogus) tokens a workspace's guest holds in place of the real
/// Kimi credential, derived deterministically from the real one + the profile
/// id — so the seed that writes `~/.kimi-code/credentials/<slot>.json`, the
/// proxy's bearer swap, and the proxy's answer to a guest refresh all agree
/// on the exact strings without sharing state.
public enum KimiStandIn {
    /// A JWT-shaped bogus access token (real claims, far-future `exp`, fake
    /// signature) so the CLI can decode it locally; an opaque placeholder
    /// would make it treat the session as logged out.
    public static func access(realAccess: String, profileID: UUID) -> String {
        let salt = Data("kimi-bogus-access:\(profileID)".utf8)
        return SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: realAccess, salt: salt)
            ?? SessionTokenPlan.deriveFake(prefix: "kimi-brm-", real: realAccess, salt: salt,
                                           targetLength: max(40, realAccess.count))
    }

    /// The bogus refresh token. The guest is never meant to use it — but kimi
    /// 2.0.x FORCES a refresh whenever its managed-models provisioning call
    /// gets a 401, and a refresh that `auth.kimi.ai` rejects is persisted as a
    /// revoked tombstone (empty access token), which reads as "requires login"
    /// from then on. The proxy therefore recognizes this exact string on a
    /// `grant_type=refresh_token` POST and answers it itself (see
    /// `KimiRefreshAnswer`), performing the real refresh host-side.
    public static func refresh(realRefresh: String, profileID: UUID) -> String {
        let salt = Data("kimi-bogus-refresh:\(profileID)".utf8)
        return SessionTokenPlan.deriveFake(prefix: "kimirt-brm-", real: realRefresh, salt: salt,
                                           targetLength: max(40, realRefresh.count))
    }

    /// `expires_in` / `expires_at` the guest is told. Far future so the CLI's
    /// own threshold (`expiresAt − now < max(300, expiresIn/2)`) never trips a
    /// proactive refresh; the host owns refresh.
    public static let lifetime: TimeInterval = 10 * 365 * 24 * 3600
}

/// The token reply the proxy hands the guest when kimi refreshes its stand-in
/// (kimi's `tokenFromResponse` requires a non-empty `access_token` and
/// `refresh_token` and a finite `expires_in > 0`; it derives `expires_at`
/// itself as `now + expires_in`). Pure so it's unit-tested.
public enum KimiRefreshAnswer {
    /// Build the reply for `profileID` from its (freshly refreshed) real
    /// record, and the new bogus access token to register for the swap.
    public static func build(record: KimiSubscriptionRecord, profileID: UUID)
        -> (json: [String: Any], bogusAccess: String) {
        let bogusAccess = KimiStandIn.access(realAccess: record.accessToken, profileID: profileID)
        let bogusRefresh = KimiStandIn.refresh(realRefresh: record.refreshToken, profileID: profileID)
        let lifetime = Int(KimiStandIn.lifetime)
        var json: [String: Any] = [
            "access_token": bogusAccess,
            "refresh_token": bogusRefresh,
            "token_type": "Bearer",
            "expires_in": lifetime,
            "expires_at": Int(Date().timeIntervalSince1970) + lifetime,
        ]
        // Carry the captured scope/token_type through so the stored entry keeps
        // the fields the CLI's loader expects.
        if let t = record.templateJSON,
           let obj = (try? JSONSerialization.jsonObject(with: t)) as? [String: Any] {
            if let scope = obj["scope"] as? String { json["scope"] = scope }
            if let tt = obj["token_type"] as? String { json["token_type"] = tt }
        }
        if json["scope"] == nil { json["scope"] = "kimi-code" }
        return (json, bogusAccess)
    }
}

public struct KimiSubscriptionRecord: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var savedAt: Date
    /// Set when a refresh was REJECTED by the provider (HTTP 400/401/403 —
    /// the refresh token was revoked, expired, or the account signed out).
    /// Only re-registration clears this; a plain access-token expiry never
    /// sets it, because the refresh path renews that silently. Optional so
    /// records written before this existed still decode.
    public var reauthRequiredAt: Date?
    /// Filename (sans `.json`) under `~/.kimi-code/credentials/` the entry
    /// was captured from — reused when re-seeding the bogus copy.
    public var credentialName: String
    /// The FULL real credentials JSON as captured at registration, minus the
    /// live secrets, so the bogus re-seed preserves every field kimi's
    /// loader expects (`scope`, `token_type`, `expires_in`, …).
    public var templateJSON: Data?
    /// `~/.kimi-code/config.toml` as written by the CLI's managed `/login`
    /// (providers + models + default_model). Seeded write-if-missing into
    /// new sessions so the guest CLI is fully configured without OAuth.
    public var configTOML: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                savedAt: Date, credentialName: String = kimiManagedCredentialName,
                templateJSON: Data? = nil, configTOML: String? = nil,
                reauthRequiredAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
        self.credentialName = credentialName
        self.templateJSON = templateJSON
        self.configTOML = configTOML
    }
}

private struct KimiSubscriptionFile: Codable {
    var shared: KimiSubscriptionRecord?
    var perProfile: [String: KimiSubscriptionRecord]
    /// profileID → the profile whose credential it uses (an automation clone
    /// → its base): one OAuth grant lives in ONE slot, never copied, since a
    /// rotating refresh token refreshed from two copies logs one of them out.
    var aliases: [String: String]?
}

public final class KimiSubscriptionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: KimiSubscriptionFile?
    private var bogusKeys: [String: UUID] = [:]

    /// Tests pass their own `fileURL` — never the user's real store.
    public init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = fileURL ?? supportDir.appendingPathComponent("kimi-subscription.enc")
    }

    private func loadLocked() -> KimiSubscriptionFile {
        if let cache { return cache }
        let empty = KimiSubscriptionFile(shared: nil, perProfile: [:])
        guard let blob = try? Data(contentsOf: fileURL) else { cache = empty; return empty }
        guard let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(KimiSubscriptionFile.self, from: plain)
        else {
            // Exists but unreadable (keychain hiccup): don't cache the
            // emptiness — it would hide the login and let a write clobber it.
            return empty
        }
        cache = file
        return file
    }

    // MARK: - Re-auth state

    /// When the provider last REJECTED this credential's refresh, or nil when
    /// it is believed good. The editor surfaces this as "sign-in expired";
    /// nothing but a fresh registration can clear it.
    public func reauthRequiredAt(for profileID: UUID?) -> Date? {
        record(for: profileID)?.reauthRequiredAt
    }

    /// Flag/clear the credential behind `profileID`. Writes through the same
    /// shared-vs-override resolution `record(for:)` reads, so a profile using
    /// the shared credential flags the shared one.
    public func setReauthRequired(_ flagged: Bool, for profileID: UUID?) {
        lock.lock()
        var file = loadLocked()
        let stamp: Date? = flagged ? Date() : nil
        var changed = false
        if let key = ownerKeyLocked(file, profileID), var r = file.perProfile[key] {
            if (r.reauthRequiredAt != nil) != flagged {
                r.reauthRequiredAt = stamp
                file.perProfile[key] = r
                changed = true
            }
        } else if var shared = file.shared {
            if (shared.reauthRequiredAt != nil) != flagged {
                shared.reauthRequiredAt = stamp
                file.shared = shared
                changed = true
            }
        }
        if changed { try? persistLocked(file) }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
    }

    private func persistLocked(_ file: KimiSubscriptionFile) throws {
        cache = file
        let plain = try JSONEncoder().encode(file)
        let blob = try SecretsVault.encrypt(plain)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    /// True when THIS profile has its own per-profile record (as opposed to
    /// only inheriting the shared one). Lets a per-workspace log-out clear
    /// the right scope.
    public func hasProfileRecord(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().perProfile[profileID.uuidString] != nil
    }

    /// The per-profile key holding `profileID`'s own credential (following an
    /// automation clone's alias), or nil when it uses the shared one.
    private func ownerKeyLocked(_ file: KimiSubscriptionFile, _ profileID: UUID?) -> String? {
        guard let pid = profileID else { return nil }
        let owner = file.aliases?[pid.uuidString] ?? pid.uuidString
        return file.perProfile[owner] != nil ? owner : nil
    }

    /// The storage slot backing `profileID` ("shared" or a profile id) —
    /// what the refresher single-flights on.
    public func slotKey(for profileID: UUID?) -> String {
        lock.lock(); defer { lock.unlock() }
        return ownerKeyLocked(loadLocked(), profileID) ?? "shared"
    }

    /// Make `profileID` (an automation clone) use `base`'s own credential
    /// without copying the grant. `forget(for: profileID)` drops the alias.
    public func alias(_ profileID: UUID, to base: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        var aliases = file.aliases ?? [:]
        aliases[profileID.uuidString] = file.aliases?[base.uuidString] ?? base.uuidString
        file.aliases = aliases
        try persistLocked(file)
    }

    public func record(for profileID: UUID?) -> KimiSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: KimiSubscriptionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.shared = record; try persistLocked(file)
    }
    public func setOverride(_ record: KimiSubscriptionRecord, for profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.perProfile[profileID.uuidString] = record; try persistLocked(file)
    }
    public func update(_ record: KimiSubscriptionRecord, for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        if let key = ownerKeyLocked(file, profileID) {
            file.perProfile[key] = record
        } else { file.shared = record }
        try persistLocked(file)
    }
    public func forget(for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        if let pid = profileID {
            file.perProfile[pid.uuidString] = nil
            file.aliases?[pid.uuidString] = nil
        } else { file.shared = nil }
        try persistLocked(file)
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

public enum KimiSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse
    public var description: String {
        switch self {
        case .noCredential: return "no Kimi subscription credential registered"
        case .refreshHTTP(let c): return "Kimi OAuth refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Kimi OAuth refresh returned an unexpected body"
        }
    }
}

public actor KimiSubscriptionRefresher {
    private let store: KimiSubscriptionStore
    /// Public device-flow client id from kimi-code's `packages/oauth`.
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    // International (global) region — the mainland-CN default (auth.kimi.com)
    // rejects non-China accounts. See ``KimiRegion``.
    private static let tokenURL = KimiRegion.tokenURL
    private static let refreshMargin: TimeInterval = 300

    public init(store: KimiSubscriptionStore) { self.store = store }

    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }
        return try await singleFlight(profileID)
    }

    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID) else { return }
        if record.accessToken != stale { return }
        _ = try? await singleFlight(profileID)
    }

    /// One refresh per storage slot at a time. The actor alone doesn't
    /// serialize it — it's reentrant at the network `await`, so concurrent
    /// callers would each spend the same rotating refresh token (see
    /// ``ClaudeSubscriptionRefresher``). Unstructured so a caller giving up
    /// can't cancel a refresh whose rotated token must still be stored.
    private var inflight: [String: Task<String, Error>] = [:]
    private func singleFlight(_ profileID: UUID?) async throws -> String {
        let slot = store.slotKey(for: profileID)
        if let running = inflight[slot] { return try await running.value }
        let task = Task { try await self.performRefresh(for: profileID) }
        inflight[slot] = task
        defer { inflight[slot] = nil }
        return try await task.value
    }

    private func performRefresh(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let form = "grant_type=refresh_token&refresh_token=\(enc(record.refreshToken))&client_id=\(enc(Self.clientID))"
        req.httpBody = Data(form.utf8)

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw KimiSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            // 400/401/403 = the provider rejected the REFRESH TOKEN itself
            // (revoked, expired, signed out elsewhere). Nothing retries out of
            // that — flag the credential so the UI can say "sign-in expired"
            // instead of every session failing with an opaque auth error. A
            // 5xx or a rate-limit is transient and must NOT flag.
            if (400...403).contains(http.statusCode) {
                store.setReauthRequired(true, for: profileID)
            }
            throw KimiSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { throw KimiSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String) ?? record.refreshToken
        // Prefer the server's absolute expiry; fall back to expires_in.
        let expiresAt: Date
        if let at = (json["expires_at"] as? Double) ?? (json["expires_at"] as? Int).map(Double.init) {
            expiresAt = Date(timeIntervalSince1970: at)
        } else {
            let expiresIn = (json["expires_in"] as? Double)
                ?? ((json["expires_in"] as? Int).map(Double.init)) ?? 3600
            expiresAt = Date().addingTimeInterval(expiresIn)
        }

        let updated = KimiSubscriptionRecord(
            accessToken: newAccess, refreshToken: newRefresh,
            expiresAt: expiresAt, savedAt: Date(),
            credentialName: record.credentialName,
            templateJSON: record.templateJSON,
            configTOML: record.configTOML)
        try store.update(updated, for: profileID)
        // Refresh worked — any earlier rejection is stale.
        store.setReauthRequired(false, for: profileID)
        return newAccess
    }
}
