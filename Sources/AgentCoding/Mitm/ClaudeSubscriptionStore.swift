import Foundation

/// Host-owned storage + refresh for a Claude **subscription** OAuth credential
/// that is shared across every VM session.
///
/// **Why this exists.** Previously each VM ran `claude login` and held the real
/// OAuth tokens in `~/.claude/.credentials.json` — a credential an attacker in
/// the guest could steal, and one that had to be re-established every ephemeral
/// session. The new model keeps the real tokens **only on the host**: the guest
/// runs in API-key mode with a *bogus* `ANTHROPIC_API_KEY`, and the proxy swaps
/// that for a live `Authorization: Bearer <access>` (+ the OAuth beta header)
/// pulled from here. The host owns the entire refresh lifecycle, so one refresh
/// benefits every running VM at once.
///
/// A single AES-GCM file (`claude-subscription.enc`, encrypted via
/// ``SecretsVault``) holds one `shared` record plus optional per-profile
/// overrides ("share with just this session"). ``ClaudeSubscriptionRefresher``
/// owns the network refresh; this type owns at-rest storage + the in-memory
/// cache, and the bogus-key registry the proxy consults.

/// One Claude subscription credential as persisted on disk.
public struct ClaudeSubscriptionRecord: Codable, Sendable, Equatable {
    public var accessToken: String      // sk-ant-oat01-…
    public var refreshToken: String     // sk-ant-ort01-…
    /// When `accessToken` expires (now + `expires_in` at refresh time). A
    /// freshly-registered record uses `.distantPast` to force an immediate
    /// proactive refresh on first use, which establishes the real expiry and
    /// proves the refresh path end-to-end.
    public var expiresAt: Date
    public var savedAt: Date
    /// Set when a refresh was REJECTED by the provider (HTTP 400/401/403 —
    /// the refresh token was revoked, expired, or the account signed out).
    /// Only re-registration clears this; a plain access-token expiry never
    /// sets it, because the refresh path renews that silently. Optional so
    /// records written before this existed still decode.
    public var reauthRequiredAt: Date?

    public init(accessToken: String, refreshToken: String,
                expiresAt: Date, savedAt: Date,
                reauthRequiredAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
    }
}

/// On-disk container: the default credential plus per-profile overrides.
private struct ClaudeSubscriptionFile: Codable {
    var shared: ClaudeSubscriptionRecord?
    var perProfile: [String: ClaudeSubscriptionRecord]  // profileID UUID string → record
    /// profileID → the profile whose credential it uses (an automation clone
    /// → its base). One OAuth grant must live in exactly ONE slot: refresh
    /// tokens rotate, so two copies refreshed independently log each other
    /// out. Optional so files written before this existed still decode.
    var aliases: [String: String]?
}

public final class ClaudeSubscriptionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    /// In-memory mirror of the on-disk file; loaded lazily, authoritative for
    /// this process (the singleton owner serves every session).
    private var cache: ClaudeSubscriptionFile?

    /// Bogus `ANTHROPIC_API_KEY` values currently in use by subscription-mode
    /// sessions → the profile they belong to. The proxy fires its transform
    /// only for keys in here, which disambiguates subscription-mode bogus keys
    /// from `.token`-mode fakes that share the `sk-ant-api03-brm-` prefix.
    private var bogusKeys: [String: UUID] = [:]

    /// `claude-subscription.enc` next to `fake-salt.bin` under app support.
    /// Tests pass their own `fileURL` — never the user's real store.
    public init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = fileURL ?? supportDir.appendingPathComponent("claude-subscription.enc")
    }

    // MARK: - Records

    private func loadLocked() -> ClaudeSubscriptionFile {
        if let cache { return cache }
        let empty = ClaudeSubscriptionFile(shared: nil, perProfile: [:])
        guard let blob = try? Data(contentsOf: fileURL) else {
            cache = empty          // no file yet: genuinely empty
            return empty
        }
        guard let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(ClaudeSubscriptionFile.self, from: plain)
        else {
            // The file exists but can't be read (a keychain hiccup handing
            // back no/other vault key). Don't CACHE the emptiness — that
            // would hide the login for the rest of the process and let the
            // next write replace the real file. Retry on the next read.
            FileHandle.standardError.write(Data(
                "[claude-sub] couldn't decrypt \(fileURL.lastPathComponent); will retry\n".utf8))
            return empty
        }
        cache = file
        return file
    }

    /// The storage slot a profile's credential lives in — its own override
    /// (following an automation clone's alias to its base), else the shared
    /// one — or nil when there's no credential at all. Refresh is
    /// single-flighted and compare-and-swapped per SLOT, since many profiles
    /// share one.
    private func slotLocked(_ file: ClaudeSubscriptionFile, _ profileID: UUID?)
        -> (key: String, record: ClaudeSubscriptionRecord)? {
        if let pid = profileID {
            let owner = file.aliases?[pid.uuidString] ?? pid.uuidString
            if let r = file.perProfile[owner] { return (owner, r) }
        }
        return file.shared.map { ("shared", $0) }
    }

    private func slotLocked(_ file: ClaudeSubscriptionFile, key: String)
        -> (key: String, record: ClaudeSubscriptionRecord)? {
        let r = key == "shared" ? file.shared : file.perProfile[key]
        return r.map { (key, $0) }
    }

    /// The record in a slot by key (the refresher re-reads its slot this way).
    func slot(forKey key: String) -> ClaudeSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        return slotLocked(loadLocked(), key: key)?.record
    }

    private func writeSlot(_ file: inout ClaudeSubscriptionFile, _ key: String,
                           _ record: ClaudeSubscriptionRecord) {
        if key == "shared" { file.shared = record } else { file.perProfile[key] = record }
    }

    /// The slot + record backing `profileID` (see `slotLocked`).
    public func slot(for profileID: UUID?) -> (key: String, record: ClaudeSubscriptionRecord)? {
        lock.lock(); defer { lock.unlock() }
        return slotLocked(loadLocked(), profileID)
    }

    /// Make `profileID` (an automation clone) use `base`'s credential — the
    /// base's override if it has one, else the shared login — WITHOUT copying
    /// the grant. `forget(for: profileID)` drops the alias again.
    public func alias(_ profileID: UUID, to base: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        let owner = file.aliases?[base.uuidString] ?? base.uuidString
        var aliases = file.aliases ?? [:]
        aliases[profileID.uuidString] = owner
        file.aliases = aliases
        try persistLocked(file)
    }

    // MARK: - Re-auth state

    /// When the provider last REJECTED this credential's refresh, or nil when
    /// it is believed good. The editor surfaces this as "sign-in expired";
    /// nothing else can fix it but a fresh registration.
    public func reauthRequiredAt(for profileID: UUID?) -> Date? {
        record(for: profileID)?.reauthRequiredAt
    }

    /// Flag/clear the credential behind `profileID`. Writes through the same
    /// shared-vs-override resolution `record(for:)` reads, so a profile using
    /// the shared credential flags the shared one.
    ///
    /// The change notification is posted AFTER the lock is released (like the
    /// Kimi/Codex/Grok stores): an observer registered with `queue: .main`
    /// makes `post` block until the main thread has run it, and the main
    /// thread may be inside `record(for:)` waiting for this very lock — a
    /// `/state` snapshot racing a refresher's re-auth flag deadlocked the
    /// whole app that way.
    public func setReauthRequired(_ flagged: Bool, for profileID: UUID?) {
        setReauth(flagged, expected: nil) { self.slotLocked($0, profileID) }
    }

    /// The refresher's variant: flag the slot it refreshed, and only while it
    /// still holds the refresh token that was rejected.
    func setReauthRequired(_ flagged: Bool, slotKey: String, ifRefreshTokenIs expected: String) {
        setReauth(flagged, expected: expected) { self.slotLocked($0, key: slotKey) }
    }

    private func setReauth(_ flagged: Bool, expected: String?,
                           resolve: (ClaudeSubscriptionFile) -> (key: String, record: ClaudeSubscriptionRecord)?) {
        lock.lock()
        var file = loadLocked()
        let stamp = flagged ? Date() : nil
        var changed = false
        if let (key, r0) = resolve(file),
           expected == nil || r0.refreshToken == expected {
            var r = r0
            if !(r.reauthRequiredAt == stamp || (flagged && r.reauthRequiredAt != nil)) {
                r.reauthRequiredAt = stamp
                writeSlot(&file, key, r)
                changed = true
            }
        }
        if changed { try? persistLocked(file) }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
    }

    private func persistLocked(_ file: ClaudeSubscriptionFile) throws {
        cache = file
        let plain = try JSONEncoder().encode(file)
        let blob = try SecretsVault.encrypt(plain)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try blob.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path)
    }

    /// The credential to use for `profileID`: its per-profile override if one
    /// exists, otherwise the shared default. `nil` profileID → shared only.
    /// True when THIS profile has its own per-profile record (as opposed to
    /// only inheriting the shared one). Lets a per-workspace log-out clear
    /// the right scope.
    public func hasProfileRecord(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().perProfile[profileID.uuidString] != nil
    }

    public func record(for profileID: UUID?) -> ClaudeSubscriptionRecord? {
        slot(for: profileID)?.record
    }

    /// True when any usable credential exists (shared or an override for this
    /// profile). Cheap gate for "should subscription mode emit a bogus key?".
    public func hasCredential(for profileID: UUID?) -> Bool {
        record(for: profileID) != nil
    }

    public func setShared(_ record: ClaudeSubscriptionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        file.shared = record
        try persistLocked(file)
    }

    public func setOverride(_ record: ClaudeSubscriptionRecord, for profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        file.perProfile[profileID.uuidString] = record
        try persistLocked(file)
    }

    /// Replace whichever record backs `profileID` (override if present, else
    /// shared) — used by the refresher to persist rotated tokens in place.
    public func update(_ record: ClaudeSubscriptionRecord, for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        writeSlot(&file, slotLocked(file, profileID)?.key ?? "shared", record)
        try persistLocked(file)
    }

    /// Persist a refresh's rotated tokens into `slotKey` — but only while that
    /// slot still holds `sentRefresh`, the refresh token the grant was spent
    /// with. If the user re-registered (or signed out) meanwhile, the slot
    /// holds a different grant that must not be clobbered: returns false.
    /// The in-memory cache takes the tokens even when the disk write fails, so
    /// this process keeps using the live grant (the spent one is dead).
    public func commitRefresh(_ record: ClaudeSubscriptionRecord, slotKey: String,
                              replacing sentRefresh: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        let current = slotKey == "shared" ? file.shared : file.perProfile[slotKey]
        guard current?.refreshToken == sentRefresh else { return false }
        writeSlot(&file, slotKey, record)
        do { try persistLocked(file) } catch {
            FileHandle.standardError.write(Data(
                "[claude-sub] couldn't persist the rotated token (kept in memory): \(error)\n".utf8))
        }
        return true
    }

    /// Forget the per-profile override (and, when `profileID == nil`, the
    /// shared default). Used by the "Forget" UI action.
    public func forget(for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        if let pid = profileID {
            file.perProfile[pid.uuidString] = nil
            file.aliases?[pid.uuidString] = nil
        } else {
            file.shared = nil
        }
        try persistLocked(file)
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

    /// The profile a bogus `ANTHROPIC_API_KEY` belongs to, or nil if `key` is
    /// not one of ours (a real-key / token-mode user — leave untouched).
    public func profileForBogusKey(_ key: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return bogusKeys[key]
    }
}

// MARK: - Refresher

public enum ClaudeSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse

    public var description: String {
        switch self {
        case .noCredential: return "no Claude subscription credential registered"
        case .refreshHTTP(let code): return "Claude OAuth refresh failed (HTTP \(code))"
        case .malformedRefreshResponse: return "Claude OAuth refresh returned an unexpected body"
        }
    }

    /// The provider REJECTED the grant (as opposed to a transient failure):
    /// only a new sign-in fixes it.
    public var isRejection: Bool {
        switch self {
        case .noCredential: return true
        case .refreshHTTP(let code): return (400...403).contains(code)
        case .malformedRefreshResponse: return false
        }
    }
}

/// The ONE place a Claude OAuth grant is refreshed, for every session.
///
/// Refresh tokens rotate: each refresh spends the one it presents. So a grant
/// must be refreshed by exactly one party at a time, and the rotated pair
/// stored before anyone refreshes again — two refreshes presenting the same
/// refresh token make the second one fail (and may get the grant revoked),
/// which surfaces as a Claude logout in every VM.
///
/// An `actor` alone does NOT give that: it is reentrant at every `await`, so
/// while one refresh waits on the network, every other caller walks in, still
/// sees the expired record and fires its own refresh. Hence the explicit
/// single-flight: one in-flight `Task` per storage slot, which every
/// concurrent caller (any VM, any request, Fusion) awaits.
public actor ClaudeSubscriptionRefresher {
    private let store: ClaudeSubscriptionStore
    /// Claude Code's public PKCE OAuth client (verified against CLI 2.1.178).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Refresh this many seconds before the access token actually expires.
    private static let refreshMargin: TimeInterval = 300
    /// A 401-driven refresh at most this often per slot, so an upstream that
    /// 401s for some other reason can't turn every request into a refresh.
    private static let forcedRefreshFloor: TimeInterval = 60

    /// The refresh currently running for each slot (see `store.slot(for:)`).
    private var inflight: [String: Task<String, Error>] = [:]
    private var lastRefreshAt: [String: Date] = [:]

    /// The HTTP stack the refresh goes out on (tests stub it).
    private let sessionConfiguration: URLSessionConfiguration

    public init(store: ClaudeSubscriptionStore,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
    }

    /// A currently-valid access token for `profileID`, refreshing proactively
    /// if it is at/near expiry. Throws if no credential is registered, or if
    /// the token is expired and can't be renewed.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let (slot, record) = store.slot(for: profileID) else {
            throw ClaudeSubscriptionError.noCredential
        }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return record.accessToken
        }
        return try await refresh(slot: slot, force: false)
    }

    /// Reactive path for an upstream 401 on `stale`: force a refresh unless
    /// the slot already moved past that token (another caller refreshed) or
    /// was refreshed moments ago. Fire-and-forget from the proxy's streaming
    /// path — the next request picks up the result.
    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let (slot, record) = store.slot(for: profileID),
              record.accessToken == stale else { return }
        if let last = lastRefreshAt[slot],
           Date().timeIntervalSince(last) < Self.forcedRefreshFloor { return }
        _ = try? await refresh(slot: slot, force: true)
    }

    /// Join the slot's in-flight refresh, or start it.
    private func refresh(slot: String, force: Bool) async throws -> String {
        if let running = inflight[slot] { return try await running.value }
        // Unstructured on purpose: a caller giving up (its guest connection
        // dropped) must not cancel a refresh that already spent the old
        // refresh token — its result has to be stored.
        let task = Task { try await self.performRefresh(slot: slot, force: force) }
        inflight[slot] = task
        defer { inflight[slot] = nil }
        return try await task.value
    }

    /// POST the refresh_token grant to platform.claude.com, persist the rotated
    /// tokens, return the new access token. Goes direct (not via the MITM).
    private func performRefresh(slot: String, force: Bool) async throws -> String {
        guard let record = store.slot(forKey: slot) else {
            throw ClaudeSubscriptionError.noCredential
        }
        if !force, record.expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return record.accessToken
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

        // A still-valid token outlives a failed PROACTIVE refresh (we start
        // 5 min early): keep serving it rather than failing the request.
        func fallback(_ error: Error) throws -> String {
            if record.expiresAt.timeIntervalSinceNow > 10 { return record.accessToken }
            throw error
        }

        let session = URLSession(configuration: sessionConfiguration)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            FileHandle.standardError.write(Data(
                "[claude-sub] refresh (\(slot)) unreachable: \(error.localizedDescription)\n".utf8))
            return try fallback(error)
        }
        lastRefreshAt[slot] = Date()
        guard let http = response as? HTTPURLResponse else {
            return try fallback(ClaudeSubscriptionError.malformedRefreshResponse)
        }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            FileHandle.standardError.write(Data(
                "[claude-sub] refresh (\(slot)) HTTP \(http.statusCode): \(detail)\n".utf8))
            // 400–403 = the provider rejected the REFRESH TOKEN itself
            // (revoked, expired, signed out elsewhere) — flag it so the UI
            // says "sign-in expired". Only if the slot still holds the token
            // we presented: if it moved on (a re-registration landed while we
            // waited), this rejection is about a grant nobody uses any more.
            // A 5xx or a rate-limit is transient and must NOT flag.
            if (400...403).contains(http.statusCode) {
                store.setReauthRequired(true, slotKey: slot, ifRefreshTokenIs: sent)
                throw ClaudeSubscriptionError.refreshHTTP(http.statusCode)
            }
            return try fallback(ClaudeSubscriptionError.refreshHTTP(http.statusCode))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { throw ClaudeSubscriptionError.malformedRefreshResponse }

        // The refresh token rotates on every refresh; carry the old one
        // forward only if the server didn't send a new one.
        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sent
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init))
            ?? 3600

        let updated = ClaudeSubscriptionRecord(
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            savedAt: Date())
        guard store.commitRefresh(updated, slotKey: slot, replacing: sent) else {
            // The slot changed under us (re-registered / signed out): serve
            // whatever it holds now rather than resurrect the old grant.
            FileHandle.standardError.write(Data(
                "[claude-sub] refresh (\(slot)) superseded by a newer sign-in; discarded\n".utf8))
            if let now = store.slot(forKey: slot) { return now.accessToken }
            throw ClaudeSubscriptionError.noCredential
        }
        FileHandle.standardError.write(Data(
            "[claude-sub] refreshed (\(slot)); next expiry in \(Int(expiresIn))s\n".utf8))
        // The refresh worked, so any earlier "sign-in expired" is stale (the
        // committed record carries no flag); tell the UI.
        if record.reauthRequiredAt != nil {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
        return newAccess
    }
}
