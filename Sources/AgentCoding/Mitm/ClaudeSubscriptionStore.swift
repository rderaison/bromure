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

    public init(accessToken: String, refreshToken: String,
                expiresAt: Date, savedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
    }
}

/// On-disk container: the default credential plus per-profile overrides.
private struct ClaudeSubscriptionFile: Codable {
    var shared: ClaudeSubscriptionRecord?
    var perProfile: [String: ClaudeSubscriptionRecord]  // profileID UUID string → record
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
    public init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = supportDir.appendingPathComponent("claude-subscription.enc")
    }

    // MARK: - Records

    private func loadLocked() -> ClaudeSubscriptionFile {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: fileURL),
              let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(ClaudeSubscriptionFile.self, from: plain)
        else {
            let empty = ClaudeSubscriptionFile(shared: nil, perProfile: [:])
            cache = empty
            return empty
        }
        cache = file
        return file
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
    public func record(for profileID: UUID?) -> ClaudeSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let pid = profileID, let r = file.perProfile[pid.uuidString] { return r }
        return file.shared
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
        if let pid = profileID, file.perProfile[pid.uuidString] != nil {
            file.perProfile[pid.uuidString] = record
        } else {
            file.shared = record
        }
        try persistLocked(file)
    }

    /// Forget the per-profile override (and, when `profileID == nil`, the
    /// shared default). Used by the "Forget" UI action.
    public func forget(for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        if let pid = profileID {
            file.perProfile[pid.uuidString] = nil
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
}

/// Serializes Claude OAuth refresh across all sessions. Being an `actor` means
/// two VMs hitting an expired token concurrently queue here, and the second one
/// sees the already-rotated token (via the `expiresAt` / `knownStale` checks)
/// instead of issuing a duplicate refresh.
public actor ClaudeSubscriptionRefresher {
    private let store: ClaudeSubscriptionStore
    /// Claude Code's public PKCE OAuth client (verified against CLI 2.1.178).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Refresh this many seconds before the access token actually expires.
    private static let refreshMargin: TimeInterval = 300

    public init(store: ClaudeSubscriptionStore) {
        self.store = store
    }

    /// A currently-valid access token for `profileID`, refreshing proactively
    /// if it is at/near expiry. Throws if no credential is registered.
    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else {
            throw ClaudeSubscriptionError.noCredential
        }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return record.accessToken
        }
        return try await performRefresh(for: profileID)
    }

    /// Reactive path for an upstream 401: refresh unless another caller already
    /// rotated past `stale` while we were queued on the actor. Fire-and-forget
    /// from the proxy's streaming path — the next request picks up the result.
    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID) else { return }
        if record.accessToken != stale { return }   // someone else already refreshed
        _ = try? await performRefresh(for: profileID)
    }

    /// POST the refresh_token grant to platform.claude.com, persist the rotated
    /// tokens, return the new access token. Goes direct (not via the MITM).
    private func performRefresh(for profileID: UUID?) async throws -> String {
        // Re-read inside the actor so concurrent callers serialized behind us
        // observe the freshly-persisted token rather than a stale snapshot.
        guard let record = store.record(for: profileID) else {
            throw ClaudeSubscriptionError.noCredential
        }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return record.accessToken
        }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": record.refreshToken,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeSubscriptionError.malformedRefreshResponse
        }
        guard http.statusCode == 200 else {
            throw ClaudeSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String,
              newAccess.hasPrefix("sk-ant-oat01-")
        else { throw ClaudeSubscriptionError.malformedRefreshResponse }

        // Anthropic rotates the refresh token on every refresh; keep the new
        // one if present, else carry the old one forward.
        let newRefresh = (json["refresh_token"] as? String)
            .flatMap { $0.hasPrefix("sk-ant-ort01-") ? $0 : nil } ?? record.refreshToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init))
            ?? 3600

        let updated = ClaudeSubscriptionRecord(
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            savedAt: Date())
        // Persist BEFORE returning. A rotated refresh token that we fail to
        // store would brick auth for every VM on the next refresh, so surface
        // a persistence failure rather than handing back a token we lost.
        try store.update(updated, for: profileID)
        return newAccess
    }
}
