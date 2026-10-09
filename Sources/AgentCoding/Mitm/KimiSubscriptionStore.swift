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
    /// from then on. The proxy therefore recognizes any of these (`isRefresh`
    /// — an older one too) on a `grant_type=refresh_token` POST and answers
    /// it itself (see
    /// `KimiRefreshAnswer`), performing the real refresh host-side.
    public static func refresh(realRefresh: String, profileID: UUID) -> String {
        let salt = Data("kimi-bogus-refresh:\(profileID)".utf8)
        return SessionTokenPlan.deriveFake(prefix: "kimirt-brm-", real: realRefresh, salt: salt,
                                           targetLength: max(40, realRefresh.count))
    }

    /// One of Bromure's Kimi access stand-ins (any workspace, any age) —
    /// recognised by its mark, since the in-memory registry is emptied by an
    /// app restart while a resumed machine still holds an older stand-in.
    public static func isAccess(_ token: String) -> Bool {
        SubscriptionFakeMint.isJWTFake(token) || token.hasPrefix("kimi-brm-")
    }

    /// One of Bromure's Kimi refresh stand-ins (any workspace, any age): an
    /// older one (minted before the host rotated the real refresh token)
    /// must still be answered by the proxy, never sent on to auth.kimi.ai.
    public static func isRefresh(_ token: String) -> Bool { token.hasPrefix("kimirt-brm-") }

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
    /// When the HOST last refreshed this grant for real (nil: not since
    /// sign-in). Shown in `/state` and Settings › Models — never a token.
    public var lastRefreshedAt: Date?
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
                reauthRequiredAt: Date? = nil, lastRefreshedAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
        self.lastRefreshedAt = lastRefreshedAt
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
    private let lock = NSLock()
    /// The encrypted file, shared safely with any other process using it
    /// (see ``SubscriptionStoreFile``).
    private let backing: SubscriptionStoreFile<KimiSubscriptionFile>
    /// Bogus access token currently in use by a subscription session → the
    /// profile it belongs to. In memory only: a stand-in minted before an app
    /// restart is recognised by its mark instead (see the proxy).
    private var bogusKeys: [String: UUID] = [:]

    /// Tests pass their own `fileURL` — never the user's real store.
    public init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        backing = SubscriptionStoreFile(
            fileURL: fileURL ?? supportDir.appendingPathComponent("kimi-subscription.enc"),
            tag: "kimi-sub", empty: { KimiSubscriptionFile(shared: nil, perProfile: [:]) })
    }

    // MARK: - Records

    /// The file's current contents (reloaded when another process changed it).
    private func loadLocked() -> KimiSubscriptionFile { backing.read() }

    /// Read-modify-write against the CURRENT file, under the cross-process
    /// lock. Throws (changing nothing) when the file is unreadable or the
    /// write fails.
    @discardableResult
    private func mutate(_ body: (inout KimiSubscriptionFile) throws -> Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try backing.mutate(body)
    }

    /// The file exists but can't be read: its logins are hidden and nothing
    /// is written over it.
    public var isUnreadable: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = backing.read()
        return backing.isUnreadable
    }

    /// The cross-process lock refreshers hold around read → refresh → write.
    var refreshLockURL: URL { backing.refreshLockURL }

    /// Test seam: make writes fail (a full / read-only disk).
    var failWritesForTesting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return backing.failWritesForTesting }
        set { lock.lock(); backing.failWritesForTesting = newValue; lock.unlock() }
    }

    /// Refresh time, expiry and re-auth state of the login `profileID` reads —
    /// no token data. nil when there's no login (and the store is readable).
    public func health(for profileID: UUID?) -> SubscriptionLoginHealth? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        let unreadable = backing.isUnreadable
        let r = ownerKeyLocked(file, profileID).flatMap { file.perProfile[$0] } ?? file.shared
        guard r != nil || unreadable else { return nil }
        return SubscriptionLoginHealth(lastRefreshedAt: r?.lastRefreshedAt, accessExpiresAt: r?.expiresAt,
                                       reauthRequiredAt: r?.reauthRequiredAt, storeUnreadable: unreadable)
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
        setReauth(flagged, expected: nil) { file in
            self.ownerKeyLocked(file, profileID) ?? "shared"
        }
    }

    /// The refresher's variant: flag the slot it refreshed, and only while it
    /// still holds the refresh token that was rejected (a sign-in that landed
    /// meanwhile is a different, good grant).
    func setReauthRequired(_ flagged: Bool, slotKey: String, ifRefreshTokenIs expected: String) {
        setReauth(flagged, expected: expected) { _ in slotKey }
    }

    private func setReauth(_ flagged: Bool, expected: String?,
                           resolve: @escaping (KimiSubscriptionFile) -> String) {
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
                "[kimi-sub] couldn't \(flagged ? "flag" : "clear") the sign-in state: \(error)\n".utf8))
            return
        }
        // Posted outside the lock (a main-queue observer may be waiting on it).
        if changed {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
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

    /// The record in a slot by key (the refresher re-reads its slot this way).
    func record(forSlot key: String) -> KimiSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        return key == "shared" ? file.shared : file.perProfile[key]
    }

    /// Make `profileID` (an automation clone) use `base`'s own credential
    /// without copying the grant. `forget(for: profileID)` drops the alias.
    public func alias(_ profileID: UUID, to base: UUID) throws {
        try mutate { file in
            var aliases = file.aliases ?? [:]
            aliases[profileID.uuidString] = file.aliases?[base.uuidString] ?? base.uuidString
            file.aliases = aliases
            return true
        }
    }

    public func record(for profileID: UUID?) -> KimiSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: KimiSubscriptionRecord) throws {
        try mutate { $0.shared = record; return true }
    }

    public func setOverride(_ record: KimiSubscriptionRecord, for profileID: UUID) throws {
        try mutate { $0.perProfile[profileID.uuidString] = record; return true }
    }

    public func update(_ record: KimiSubscriptionRecord, for profileID: UUID?) throws {
        try mutate { file in
            if let key = self.ownerKeyLocked(file, profileID) {
                file.perProfile[key] = record
            } else { file.shared = record }
            return true
        }
    }

    /// Persist a refresh's rotated tokens into `slotKey` — only while that
    /// slot still holds `sentRefresh`, the refresh token the grant was spent
    /// with (checked against the file as it is NOW, under the lock). Returns
    /// false when a newer sign-in / another process's refresh replaced it.
    /// Throws when the write fails: the rotated token is never kept only in
    /// memory.
    func commitRefresh(_ record: KimiSubscriptionRecord, slotKey: String,
                       replacing sentRefresh: String) throws -> Bool {
        try mutate { file in
            let current = slotKey == "shared" ? file.shared : file.perProfile[slotKey]
            guard let held = current, held.refreshToken == sentRefresh else { return false }
            // Same grant, rotated: it was registered when it was, not now.
            var record = record
            record.savedAt = held.savedAt
            if slotKey == "shared" { file.shared = record } else { file.perProfile[slotKey] = record }
            return true
        }
    }

    /// Fill in the managed `config.toml` of the record `profileID` reads,
    /// against the CURRENT record (a refresh that rotated its tokens
    /// meanwhile is kept). No-op when it is already provisioned.
    func setConfigTOML(_ toml: String, for profileID: UUID?,
                       unlessProvisioned isProvisioned: (String?) -> Bool) throws {
        try mutate { file in
            let key = self.ownerKeyLocked(file, profileID) ?? "shared"
            guard var r = key == "shared" ? file.shared : file.perProfile[key],
                  !isProvisioned(r.configTOML) else { return false }
            r.configTOML = toml
            if key == "shared" { file.shared = r } else { file.perProfile[key] = r }
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

    // MARK: - Bogus-key registry

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
    /// The login is flagged "needs sign-in" (the provider rejected its
    /// refresh): nothing is injected until the user signs in again.
    case reauthRequired
    public var description: String {
        switch self {
        case .noCredential: return "no Kimi subscription credential registered"
        case .refreshHTTP(let c): return "Kimi OAuth refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Kimi OAuth refresh returned an unexpected body"
        case .reauthRequired: return "the Kimi sign-in was rejected; sign in again from Bromure"
        }
    }

    /// The provider REJECTED the grant (as opposed to a transient failure):
    /// only a new sign-in fixes it.
    public var isRejection: Bool {
        switch self {
        case .noCredential, .reauthRequired: return true
        case .refreshHTTP(let code): return (400...403).contains(code)
        case .malformedRefreshResponse: return false
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
    /// A forced (401- or stand-in-driven) refresh at most this often per
    /// slot, so an upstream that 401s for some other reason can't turn every
    /// request into a refresh.
    static let forcedRefreshFloor: TimeInterval = 60

    private var lastRefreshAt: [String: Date] = [:]
    /// The HTTP stack the refresh goes out on (tests stub it).
    private let sessionConfiguration: URLSessionConfiguration

    public init(store: KimiSubscriptionStore,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
    }

    /// A currently-valid access token, refreshing proactively near expiry.
    /// Throws ``KimiSubscriptionError/reauthRequired`` while the login is
    /// flagged — a dead token is never injected.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw KimiSubscriptionError.reauthRequired }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }
        return try await singleFlight(profileID, force: false).access
    }

    /// The agent sent its stand-in refresh token (it only does that after
    /// the provider turned a request down): refresh the REAL login now,
    /// unless the slot was refreshed moments ago. Returns true when a real
    /// refresh happened on this call, false when a recent one (this process
    /// or another) is reused. Throws when the login is flagged or the refresh
    /// is rejected — the caller must then tell the agent the truth instead
    /// of handing out fresh stand-ins.
    @discardableResult
    public func refreshForStandIn(for profileID: UUID?) async throws -> Bool {
        guard let record = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw KimiSubscriptionError.reauthRequired }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor {
            return false
        }
        return try await singleFlight(profileID, force: true, unlessAccessIsNot: record.accessToken).refreshed
    }

    /// Reactive path for an upstream 401 on `stale`: force a real refresh
    /// (rate-limited per slot) — an unexpired-looking token the provider
    /// turned down must not be injected forever.
    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID),
              record.accessToken == stale, record.reauthRequiredAt == nil else { return }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor { return }
        _ = try? await singleFlight(profileID, force: true, unlessAccessIsNot: stale)
    }

    /// One refresh per storage slot at a time. The actor alone doesn't
    /// serialize it — it's reentrant at the network `await`, so concurrent
    /// callers would each spend the same rotating refresh token (see
    /// ``ClaudeSubscriptionRefresher``). Unstructured so a caller giving up
    /// can't cancel a refresh whose rotated token must still be stored.
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

    /// `seen`: for a forced refresh, the access token the caller saw turned
    /// down — if the slot no longer holds it once the lock is held, another
    /// refresh (here or in another process) already replaced it: reuse that.
    private func performRefresh(slot: String, force: Bool, seen: String?) async throws -> (access: String, refreshed: Bool) {
        // Hold the store's cross-process refresh lock across read → refresh →
        // write, and re-read the slot under it: another process (the CLI, a
        // fat client, a second instance) may have refreshed meanwhile.
        let held = try await SubscriptionRefreshLock.acquire(store.refreshLockURL)
        defer { SubscriptionRefreshLock.release(held) }
        guard let record = store.record(forSlot: slot) else { throw KimiSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw KimiSubscriptionError.reauthRequired }
        if !force, record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return (record.accessToken, false) }
        if force, let seen, record.accessToken != seen {
            FileHandle.standardError.write(Data(
                "[kimi-sub] refresh (\(slot)) already done elsewhere; reused\n".utf8))
            return (record.accessToken, false)
        }
        let sent = record.refreshToken

        // Standard token endpoint → application/x-www-form-urlencoded.
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let form = "grant_type=refresh_token&refresh_token=\(enc(sent))&client_id=\(enc(Self.clientID))"
        req.httpBody = Data(form.utf8)

        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        lastRefreshAt[slot] = Date()
        guard let http = response as? HTTPURLResponse else { throw KimiSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            FileHandle.standardError.write(Data(
                "[kimi-sub] refresh (\(slot)) HTTP \(http.statusCode): \(detail)\n".utf8))
            // 400/401/403 = the provider rejected the REFRESH TOKEN itself
            // (revoked, expired, reused, signed out elsewhere). Nothing
            // retries out of that — flag the credential so the UI can say
            // "sign-in expired" and the proxy stops injecting. Only if the
            // slot still holds the token we presented (a re-registration
            // that landed meanwhile is a different, good grant). A 5xx or a
            // rate-limit is transient and must NOT flag.
            if (400...403).contains(http.statusCode) {
                store.setReauthRequired(true, slotKey: slot, ifRefreshTokenIs: sent)
            }
            throw KimiSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { throw KimiSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sent
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
            expiresAt: expiresAt, savedAt: record.savedAt,
            credentialName: record.credentialName,
            templateJSON: record.templateJSON,
            configTOML: record.configTOML,
            lastRefreshedAt: Date())

        let committed: Bool
        do {
            committed = try store.commitRefresh(updated, slotKey: slot, replacing: sent)
        } catch {
            // The grant was spent but the rotated tokens couldn't be written:
            // never keep them only in memory — say so and fail.
            FileHandle.standardError.write(Data(
                "[kimi-sub] refresh (\(slot)) succeeded but the rotated token couldn't be saved: \(error)\n".utf8))
            throw error
        }
        guard committed else {
            // The slot changed under us (re-registered / signed out): serve
            // what it holds now rather than resurrect the old grant.
            FileHandle.standardError.write(Data(
                "[kimi-sub] refresh (\(slot)) superseded by a newer sign-in; discarded\n".utf8))
            if let now = store.record(forSlot: slot) { return (now.accessToken, false) }
            throw KimiSubscriptionError.noCredential
        }
        FileHandle.standardError.write(Data(
            "[kimi-sub] refreshed (\(slot)); next expiry in \(Int(updated.expiresAt.timeIntervalSinceNow))s\n".utf8))
        return (updated.accessToken, true)
    }
}
