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

    public init(accessToken: String, refreshToken: String, idToken: String,
                expiresAt: Date, savedAt: Date,
                reauthRequiredAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
        self.reauthRequiredAt = reauthRequiredAt
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
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: CodexSubscriptionFile?
    /// Bogus access-token JWT currently in use by a subscription session →
    /// the profile it belongs to. The proxy swaps a Bearer only for keys here.
    private var bogusKeys: [String: UUID] = [:]

    /// Tests pass their own `fileURL` — never the user's real store.
    public init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = fileURL ?? supportDir.appendingPathComponent("codex-subscription.enc")
    }

    // MARK: - Records

    private func loadLocked() -> CodexSubscriptionFile {
        if let cache { return cache }
        let empty = CodexSubscriptionFile(shared: nil, perProfile: [:])
        guard let blob = try? Data(contentsOf: fileURL) else { cache = empty; return empty }
        guard let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(CodexSubscriptionFile.self, from: plain)
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

    private func persistLocked(_ file: CodexSubscriptionFile) throws {
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

    public func record(for profileID: UUID?) -> CodexSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let key = ownerKeyLocked(file, profileID), let r = file.perProfile[key] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: CodexSubscriptionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.shared = record; try persistLocked(file)
    }

    public func setOverride(_ record: CodexSubscriptionRecord, for profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.perProfile[profileID.uuidString] = record; try persistLocked(file)
    }

    public func update(_ record: CodexSubscriptionRecord, for profileID: UUID?) throws {
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
    public var description: String {
        switch self {
        case .noCredential: return "no Codex subscription credential registered"
        case .refreshHTTP(let c): return "Codex OAuth refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Codex OAuth refresh returned an unexpected body"
        }
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

    public init(store: CodexSubscriptionStore) { self.store = store }

    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw CodexSubscriptionError.noCredential }
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
        guard let record = store.record(for: profileID) else { throw CodexSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": record.refreshToken,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CodexSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else {
            // 400/401/403 = the provider rejected the REFRESH TOKEN itself
            // (revoked, expired, signed out elsewhere). Nothing retries out of
            // that — flag the credential so the UI can say "sign-in expired"
            // instead of every session failing with an opaque auth error. A
            // 5xx or a rate-limit is transient and must NOT flag.
            if (400...403).contains(http.statusCode) {
                store.setReauthRequired(true, for: profileID)
            }
            throw CodexSubscriptionError.refreshHTTP(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, newAccess.hasPrefix("eyJ")
        else { throw CodexSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String) ?? record.refreshToken
        let newID = (json["id_token"] as? String).flatMap { $0.hasPrefix("eyJ") ? $0 : nil } ?? record.idToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init)) ?? 3600

        let updated = CodexSubscriptionRecord(
            accessToken: newAccess, refreshToken: newRefresh, idToken: newID,
            expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
        try store.update(updated, for: profileID)
        // Refresh worked — any earlier rejection is stale.
        store.setReauthRequired(false, for: profileID)
        return newAccess
    }
}
