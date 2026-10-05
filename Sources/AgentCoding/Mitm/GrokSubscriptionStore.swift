import Foundation

/// Host-owned storage + refresh for an xAI **Grok** subscription credential,
/// shared across every VM session. The Grok twin of ``ClaudeSubscriptionStore``
/// / ``CodexSubscriptionStore`` — see those for the overall rationale.
///
/// Grok specifics (verified against the x.ai `grok` CLI 0.2.54, the build the
/// base image installs via `https://x.ai/cli/install.sh`):
///   * Auth is OIDC. Credentials live in `~/.grok/auth.json`, shaped
///     `{ "<scope>": { "key": <access>, "refresh_token": <rt>, "expires_at": <epoch> } }`
///     where the OIDC scope is `https://auth.x.ai::<client_id>`.
///   * Subscription API calls go to `cli-chat-proxy.grok.com` with
///     `Authorization: Bearer <access>`.
///   * Refresh is standard OIDC against `https://auth.x.ai/oauth2/token`
///     (client_id `b1a00492-073a-47ea-816f-4c329264a828`), refreshed ~5 min
///     before `expires_at`. We seed `expires_at` far in the future so the guest
///     never refreshes; the host owns refresh.
///   * No vsock token agent exists for Grok — but `~/.grok/auth.json` lives in
///     the host-mounted home dir, so the host seeds (write) and captures (read)
///     the file directly. See `ACAppDelegate.seedGrokAuthFile` /
///     the registration coordinator's home-dir poll.

public let grokOIDCScope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"

/// The stand-in tokens a workspace's Grok holds in place of the real login:
/// a JWT-shaped access token (real claims, far-future `exp`, Bromure-marked
/// signature — `SubscriptionFakeMint.isJWTFake`) and a `grokrt-brm-` refresh
/// token. Minted the same way at boot (the seeded `~/.grok/auth.json`),
/// after an in-session sign-in, and when the proxy answers a stand-in
/// refresh. Recognised by these marks — not only by the in-memory registry,
/// which an app restart empties while a resumed machine still holds the
/// stand-in it booted with.
public enum GrokStandIn {
    public struct Tokens: Equatable { public let access, refresh: String }

    static let accessFallbackPrefix = "grok-brm-"
    static let refreshPrefix = "grokrt-brm-"

    public static func mint(_ real: GrokSubscriptionRecord, profileID: UUID) -> Tokens {
        mint(access: real.accessToken, refresh: real.refreshToken, profileID: profileID)
    }

    public static func mint(access: String, refresh: String, profileID: UUID) -> Tokens {
        let saltA = Data("grok-bogus-access:\(profileID)".utf8)
        let saltR = Data("grok-bogus-refresh:\(profileID)".utf8)
        // Grok's access token is a JWT — a JWT-shaped stand-in lets grok decode
        // it locally; an opaque placeholder makes grok treat the session as
        // logged out.
        let a = SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: access, salt: saltA)
            ?? SessionTokenPlan.deriveFake(prefix: accessFallbackPrefix, real: access, salt: saltA,
                                           targetLength: max(40, access.count))
        let r = SessionTokenPlan.deriveFake(prefix: refreshPrefix, real: refresh, salt: saltR,
                                            targetLength: max(40, refresh.count))
        return Tokens(access: a, refresh: r)
    }

    /// One of Bromure's Grok access stand-ins (any workspace, any age).
    public static func isAccess(_ token: String) -> Bool {
        SubscriptionFakeMint.isJWTFake(token) || token.hasPrefix(accessFallbackPrefix)
    }

    /// One of Bromure's Grok refresh stand-ins (any workspace, any age).
    public static func isRefresh(_ token: String) -> Bool { token.hasPrefix(refreshPrefix) }

    /// What grok hears back from a refresh it sent with a stand-in: fresh
    /// stand-ins with a far-future expiry (the host refreshed the real login).
    public static func refreshAnswer(_ t: Tokens) -> [String: Any] {
        ["access_token": t.access, "refresh_token": t.refresh, "token_type": "Bearer",
         "expires_in": 10 * 365 * 24 * 3600]
    }
}

public struct GrokSubscriptionRecord: Codable, Sendable, Equatable {
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
    /// The OIDC scope key the entry lives under in `~/.grok/auth.json`.
    public var scopeKey: String
    /// The FULL real scope object as captured at registration (JSON), so we can
    /// re-seed a bogus copy that preserves every account-specific field grok's
    /// strict serde requires (`auth_mode`, `team_name`, `subscription_tier`, …).
    /// nil for legacy records captured before this was stored.
    public var templateJSON: Data?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                savedAt: Date, scopeKey: String = grokOIDCScope, templateJSON: Data? = nil,
                reauthRequiredAt: Date? = nil, lastRefreshedAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
        self.lastRefreshedAt = lastRefreshedAt
        self.scopeKey = scopeKey
        self.templateJSON = templateJSON
    }
}

private struct GrokSubscriptionFile: Codable {
    var shared: GrokSubscriptionRecord?
    var perProfile: [String: GrokSubscriptionRecord]
    /// profileID → the profile whose credential it uses (an automation clone
    /// → its base): one OAuth grant lives in ONE slot, never copied, since a
    /// rotating refresh token refreshed from two copies logs one of them out.
    var aliases: [String: String]?
}

public final class GrokSubscriptionStore: @unchecked Sendable {
    private let lock = NSLock()
    /// The encrypted file, shared safely with any other process using it
    /// (see ``SubscriptionStoreFile``).
    private let backing: SubscriptionStoreFile<GrokSubscriptionFile>
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
            fileURL: fileURL ?? supportDir.appendingPathComponent("grok-subscription.enc"),
            tag: "grok-sub", empty: { GrokSubscriptionFile(shared: nil, perProfile: [:]) })
    }

    // MARK: - Records

    /// The file's current contents (reloaded when another process changed it).
    private func loadLocked() -> GrokSubscriptionFile { backing.read() }

    /// Read-modify-write against the CURRENT file, under the cross-process
    /// lock. Throws (changing nothing) when the file is unreadable or the
    /// write fails.
    @discardableResult
    private func mutate(_ body: (inout GrokSubscriptionFile) throws -> Bool) throws -> Bool {
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
                           resolve: @escaping (GrokSubscriptionFile) -> String) {
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
                "[grok-sub] couldn't \(flagged ? "flag" : "clear") the sign-in state: \(error)\n".utf8))
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
    private func ownerKeyLocked(_ file: GrokSubscriptionFile, _ profileID: UUID?) -> String? {
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
    func record(forSlot key: String) -> GrokSubscriptionRecord? {
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

    public func record(for profileID: UUID?) -> GrokSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: GrokSubscriptionRecord) throws {
        try mutate { $0.shared = record; return true }
    }

    public func setOverride(_ record: GrokSubscriptionRecord, for profileID: UUID) throws {
        try mutate { $0.perProfile[profileID.uuidString] = record; return true }
    }

    public func update(_ record: GrokSubscriptionRecord, for profileID: UUID?) throws {
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
    func commitRefresh(_ record: GrokSubscriptionRecord, slotKey: String,
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

public enum GrokSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse
    /// The login is flagged "needs sign-in" (the provider rejected its
    /// refresh): nothing is injected until the user signs in again.
    case reauthRequired
    public var description: String {
        switch self {
        case .noCredential: return "no Grok subscription credential registered"
        case .refreshHTTP(let c): return "Grok OIDC refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Grok OIDC refresh returned an unexpected body"
        case .reauthRequired: return "the Grok sign-in was rejected; sign in again from Bromure"
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

public actor GrokSubscriptionRefresher {
    private let store: GrokSubscriptionStore
    private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let refreshMargin: TimeInterval = 300
    /// A forced (401- or stand-in-driven) refresh at most this often per
    /// slot, so an upstream that 401s for some other reason can't turn every
    /// request into a refresh.
    static let forcedRefreshFloor: TimeInterval = 60

    private var lastRefreshAt: [String: Date] = [:]
    /// The HTTP stack the refresh goes out on (tests stub it).
    private let sessionConfiguration: URLSessionConfiguration

    public init(store: GrokSubscriptionStore,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
    }

    /// A currently-valid access token, refreshing proactively near expiry.
    /// Throws ``GrokSubscriptionError/reauthRequired`` while the login is
    /// flagged — a dead token is never injected.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw GrokSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw GrokSubscriptionError.reauthRequired }
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
        guard let record = store.record(for: profileID) else { throw GrokSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw GrokSubscriptionError.reauthRequired }
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
        guard let record = store.record(forSlot: slot) else { throw GrokSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw GrokSubscriptionError.reauthRequired }
        if !force, record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return (record.accessToken, false) }
        if force, let seen, record.accessToken != seen {
            FileHandle.standardError.write(Data(
                "[grok-sub] refresh (\(slot)) already done elsewhere; reused\n".utf8))
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
        guard let http = response as? HTTPURLResponse else { throw GrokSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            FileHandle.standardError.write(Data(
                "[grok-sub] refresh (\(slot)) HTTP \(http.statusCode): \(detail)\n".utf8))
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
            throw GrokSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { throw GrokSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sent
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init)) ?? 3600
        let updated = GrokSubscriptionRecord(
            accessToken: newAccess, refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn), savedAt: record.savedAt,
            scopeKey: record.scopeKey, templateJSON: record.templateJSON,
            lastRefreshedAt: Date())

        let committed: Bool
        do {
            committed = try store.commitRefresh(updated, slotKey: slot, replacing: sent)
        } catch {
            // The grant was spent but the rotated tokens couldn't be written:
            // never keep them only in memory — say so and fail.
            FileHandle.standardError.write(Data(
                "[grok-sub] refresh (\(slot)) succeeded but the rotated token couldn't be saved: \(error)\n".utf8))
            throw error
        }
        guard committed else {
            // The slot changed under us (re-registered / signed out): serve
            // what it holds now rather than resurrect the old grant.
            FileHandle.standardError.write(Data(
                "[grok-sub] refresh (\(slot)) superseded by a newer sign-in; discarded\n".utf8))
            if let now = store.record(forSlot: slot) { return (now.accessToken, false) }
            throw GrokSubscriptionError.noCredential
        }
        FileHandle.standardError.write(Data(
            "[grok-sub] refreshed (\(slot)); next expiry in \(Int(updated.expiresAt.timeIntervalSinceNow))s\n".utf8))
        return (updated.accessToken, true)
    }
}
