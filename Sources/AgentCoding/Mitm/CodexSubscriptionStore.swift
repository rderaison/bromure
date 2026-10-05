import Foundation

/// Host-owned storage + refresh for an OpenAI **Codex / ChatGPT** subscription
/// credential, shared across every VM session. The Codex twin of
/// ``ClaudeSubscriptionStore`` — see that file for the overall rationale.
///
/// Codex differs from Claude in three ways:
///   * The guest stays in *subscription* mode (Codex's API-key mode hits a
///     different backend with a different protocol, so we can't convert an
///     API-key request into a subscription one). We seed `~/.codex/auth.json`
///     with a **bogus** token set whose JWT `exp` is pushed far into the future
///     so the guest never refreshes; the host owns the real refresh.
///   * The credential is three tokens (access JWT, refresh, id JWT).
///   * On the wire the guest already sends `Authorization: Bearer <bogus JWT>`
///     to `chatgpt.com` / `api.openai.com`, so the proxy *swaps* it for the
///     live real access token rather than transforming an api-key header.
///
/// Verified against `@openai/codex` 0.140.0 (the build the base image installs):
/// refresh endpoint `auth.openai.com/oauth/token`, client_id
/// `app_EMoamEEZ73f0CkXaXp7hrann`, `grant_type=refresh_token`.

/// The stand-in tokens a workspace's Codex holds for the login the host
/// keeps: JWT-shaped with the real claims, a far-future expiry and a
/// Bromure-marked signature (`SubscriptionFakeMint.isJWTFake`), plus a
/// marked refresh token (`isCodexRefreshFake`). Minted the same way at boot
/// (the seeded ~/.codex/auth.json), after a sign-in, and when the proxy
/// answers a stand-in refresh.
public enum CodexStandIn {
    public struct Tokens: Equatable { public let access, id, refresh: String }

    public static func mint(_ real: CodexSubscriptionRecord, profileID: UUID) -> Tokens? {
        let saltA = Data("codex-bogus-access:\(profileID)".utf8)
        let saltR = Data("codex-bogus-refresh:\(profileID)".utf8)
        let saltI = Data("codex-bogus-id:\(profileID)".utf8)
        guard let access = SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: real.accessToken, salt: saltA),
              let id = SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: real.idToken, salt: saltI)
        else { return nil }
        return Tokens(access: access, id: id,
                      refresh: SubscriptionFakeMint.mintCodexRefreshFake(real: real.refreshToken, salt: saltR))
    }

    /// What Codex hears back from a refresh it sent with a stand-in: fresh
    /// stand-ins (the host has refreshed the real login). Codex writes them
    /// to its auth.json and carries on.
    public static func refreshAnswer(_ t: Tokens) -> [String: Any] {
        ["access_token": t.access, "id_token": t.id, "refresh_token": t.refresh,
         "token_type": "Bearer", "expires_in": 10 * 365 * 24 * 3600]
    }
}

public struct CodexSubscriptionRecord: Codable, Sendable, Equatable {
    public var accessToken: String      // JWT (eyJ…)
    public var refreshToken: String     // rt_…
    public var idToken: String          // JWT (eyJ…)
    /// When `accessToken` expires (now + `expires_in` at refresh). `.distantPast`
    /// on a fresh registration forces an immediate proactive refresh on first
    /// use, which both establishes the real expiry and proves the refresh path.
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

    public init(accessToken: String, refreshToken: String, idToken: String,
                expiresAt: Date, savedAt: Date,
                reauthRequiredAt: Date? = nil, lastRefreshedAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}

private struct CodexSubscriptionFile: Codable {
    var shared: CodexSubscriptionRecord?
    var perProfile: [String: CodexSubscriptionRecord]
    /// profileID → the profile whose credential it uses (an automation clone
    /// → its base): one OAuth grant lives in ONE slot, never copied, since a
    /// rotating refresh token refreshed from two copies logs one of them out.
    var aliases: [String: String]?
}

public final class CodexSubscriptionStore: @unchecked Sendable {
    private let lock = NSLock()
    /// The encrypted file, shared safely with any other process using it
    /// (see ``SubscriptionStoreFile``).
    private let backing: SubscriptionStoreFile<CodexSubscriptionFile>
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
            fileURL: fileURL ?? supportDir.appendingPathComponent("codex-subscription.enc"),
            tag: "codex-sub", empty: { CodexSubscriptionFile(shared: nil, perProfile: [:]) })
    }

    // MARK: - Records

    /// The file's current contents (reloaded when another process changed it).
    private func loadLocked() -> CodexSubscriptionFile { backing.read() }

    /// Read-modify-write against the CURRENT file, under the cross-process
    /// lock. Throws (changing nothing) when the file is unreadable or the
    /// write fails.
    @discardableResult
    private func mutate(_ body: (inout CodexSubscriptionFile) throws -> Bool) throws -> Bool {
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
                           resolve: @escaping (CodexSubscriptionFile) -> String) {
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
                "[codex-sub] couldn't \(flagged ? "flag" : "clear") the sign-in state: \(error)\n".utf8))
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
    private func ownerKeyLocked(_ file: CodexSubscriptionFile, _ profileID: UUID?) -> String? {
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
    func record(forSlot key: String) -> CodexSubscriptionRecord? {
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

    public func record(for profileID: UUID?) -> CodexSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: CodexSubscriptionRecord) throws {
        try mutate { $0.shared = record; return true }
    }

    public func setOverride(_ record: CodexSubscriptionRecord, for profileID: UUID) throws {
        try mutate { $0.perProfile[profileID.uuidString] = record; return true }
    }

    public func update(_ record: CodexSubscriptionRecord, for profileID: UUID?) throws {
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
    func commitRefresh(_ record: CodexSubscriptionRecord, slotKey: String,
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

public enum CodexSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse
    /// The login is flagged "needs sign-in" (OpenAI rejected its refresh, or
    /// invalidated a freshly refreshed token): nothing is injected until the
    /// user signs in again.
    case reauthRequired
    public var description: String {
        switch self {
        case .noCredential: return "no Codex subscription credential registered"
        case .refreshHTTP(let c): return "Codex OAuth refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Codex OAuth refresh returned an unexpected body"
        case .reauthRequired: return "the ChatGPT sign-in was invalidated; sign in again from Bromure"
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

/// What the proxy tells Codex when the host has no usable ChatGPT login:
/// a 401 whose message says where to fix it. Codex's own retry path then
/// tries a refresh — answered with ``refreshRejectedJSON`` — and prints its
/// "sign in again" banner, which the session view turns into a sign-in card.
public enum CodexSignInExpired {
    public static let message =
        "Your ChatGPT sign-in expired or was invalidated. Sign in again from Bromure (the session's sign-in card or Preferences → Models) — not with codex login inside the VM."

    /// Body for a chatgpt.com / api.openai.com request answered locally.
    public static var apiErrorJSON: [String: Any] {
        ["error": ["message": message, "type": "invalid_request_error",
                   "code": "token_invalidated", "param": NSNull()] as [String: Any],
         "status": 401]
    }

    /// Body for a stand-in refresh the host couldn't honour. Codex classes
    /// `refresh_token_invalidated` as permanent and stops retrying.
    public static func refreshRejectedJSON(_ error: Error) -> [String: Any] {
        ["error": ["code": "refresh_token_invalidated",
                   "message": "\(message) (\(error))"] as [String: Any],
         "error_description": "Bromure could not refresh the Codex subscription on the host: \(error)"]
    }

    /// An upstream 401 whose body says the access token was invalidated
    /// server-side (sign-out elsewhere, password change, revoked session) —
    /// not merely expired.
    public static func isInvalidation(_ response: Data) -> Bool {
        let text = String(decoding: response.prefix(64 * 1024), as: UTF8.self).lowercased()
        return text.contains("token_invalidated") || text.contains("token_revoked")
            || text.contains("authentication token has been invalidated")
    }
}

/// Serializes Codex OAuth refresh across all sessions (see
/// ``ClaudeSubscriptionRefresher`` for the actor-de-dup rationale).
public actor CodexSubscriptionRefresher {
    private let store: CodexSubscriptionStore
    /// Codex's public OAuth client (verified against codex 0.140.0).
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let refreshMargin: TimeInterval = 300
    /// A forced (401- or stand-in-driven) refresh at most this often per
    /// slot, so an upstream that 401s for some other reason can't turn every
    /// request into a refresh.
    static let forcedRefreshFloor: TimeInterval = 60

    private var lastRefreshAt: [String: Date] = [:]
    /// The HTTP stack the refresh goes out on (tests stub it).
    private let sessionConfiguration: URLSessionConfiguration

    public init(store: CodexSubscriptionStore,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
    }

    /// A currently-valid access token, refreshing proactively near expiry.
    /// Throws ``CodexSubscriptionError/reauthRequired`` while the login is
    /// flagged — a dead token is never injected.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw CodexSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw CodexSubscriptionError.reauthRequired }
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
        guard let record = store.record(for: profileID) else { throw CodexSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw CodexSubscriptionError.reauthRequired }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor {
            return false
        }
        return try await singleFlight(profileID, force: true, unlessAccessIsNot: record.accessToken).refreshed
    }

    /// Reactive path for an upstream 401 on `stale`: force a real refresh
    /// (rate-limited per slot) — an unexpired-looking token the provider
    /// turned down must not be injected forever.
    /// `invalidated` = the 401 body said the token was invalidated
    /// server-side: if the token it rejected is one we refreshed moments
    /// ago, the login itself is dead — flag it.
    public func noteUnauthorized(stale: String, for profileID: UUID?, invalidated: Bool = false) async {
        guard let record = store.record(for: profileID),
              record.accessToken == stale, record.reauthRequiredAt == nil else { return }
        let slot = store.slotKey(for: profileID)
        if let last = lastRefreshAt[slot], Date().timeIntervalSince(last) < Self.forcedRefreshFloor {
            if invalidated {
                FileHandle.standardError.write(Data(
                    "[codex-sub] (\(slot)) freshly refreshed token invalidated upstream; sign-in required\n".utf8))
                store.setReauthRequired(true, slotKey: slot, ifRefreshTokenIs: record.refreshToken)
            }
            return
        }
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
        guard let record = store.record(forSlot: slot) else { throw CodexSubscriptionError.noCredential }
        if record.reauthRequiredAt != nil { throw CodexSubscriptionError.reauthRequired }
        if !force, record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return (record.accessToken, false) }
        if force, let seen, record.accessToken != seen {
            FileHandle.standardError.write(Data(
                "[codex-sub] refresh (\(slot)) already done elsewhere; reused\n".utf8))
            return (record.accessToken, false)
        }
        let sent = record.refreshToken

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": sent,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        lastRefreshAt[slot] = Date()
        guard let http = response as? HTTPURLResponse else { throw CodexSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            FileHandle.standardError.write(Data(
                "[codex-sub] refresh (\(slot)) HTTP \(http.statusCode): \(detail)\n".utf8))
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
            throw CodexSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, newAccess.hasPrefix("eyJ")
        else { throw CodexSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sent
        let newID = (json["id_token"] as? String).flatMap { $0.hasPrefix("eyJ") ? $0 : nil } ?? record.idToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init)) ?? 3600
        let updated = CodexSubscriptionRecord(
            accessToken: newAccess, refreshToken: newRefresh, idToken: newID,
            expiresAt: Date().addingTimeInterval(expiresIn), savedAt: record.savedAt,
            lastRefreshedAt: Date())

        let committed: Bool
        do {
            committed = try store.commitRefresh(updated, slotKey: slot, replacing: sent)
        } catch {
            // The grant was spent but the rotated tokens couldn't be written:
            // never keep them only in memory — say so and fail.
            FileHandle.standardError.write(Data(
                "[codex-sub] refresh (\(slot)) succeeded but the rotated token couldn't be saved: \(error)\n".utf8))
            throw error
        }
        guard committed else {
            // The slot changed under us (re-registered / signed out): serve
            // what it holds now rather than resurrect the old grant.
            FileHandle.standardError.write(Data(
                "[codex-sub] refresh (\(slot)) superseded by a newer sign-in; discarded\n".utf8))
            if let now = store.record(forSlot: slot) { return (now.accessToken, false) }
            throw CodexSubscriptionError.noCredential
        }
        FileHandle.standardError.write(Data(
            "[codex-sub] refreshed (\(slot)); next expiry in \(Int(updated.expiresAt.timeIntervalSinceNow))s\n".utf8))
        return (updated.accessToken, true)
    }
}
