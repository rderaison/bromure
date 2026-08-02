import Foundation

/// Host-owned storage + refresh for a Moonshot **Kimi Code** subscription
/// credential, shared across every VM session. The Kimi twin of
/// ``GrokSubscriptionStore`` — see ``ClaudeSubscriptionStore`` for the
/// overall rationale.
///
/// Kimi specifics (verified against MoonshotAI/kimi-code `packages/oauth`):
///   * Auth is an RFC 8628 device-code flow against `https://auth.kimi.com`
///     (`/api/oauth/device_authorization` + `/api/oauth/token`), public
///     client id below.
///   * Credentials live in `~/.kimi-code/credentials/<name>.json` (managed
///     flow name: `kimi-code`), snake_case wire shape
///     `{ access_token, refresh_token, expires_at (unix s), scope,
///     token_type, expires_in }`.
///   * Subscription API calls go to `api.kimi.com/coding/v1` with
///     `Authorization: Bearer <access>`.
///   * Refresh is a form POST to `https://auth.kimi.com/api/oauth/token`
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
}

public final class KimiSubscriptionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: KimiSubscriptionFile?
    private var bogusKeys: [String: UUID] = [:]

    public init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = supportDir.appendingPathComponent("kimi-subscription.enc")
    }

    private func loadLocked() -> KimiSubscriptionFile {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: fileURL),
              let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(KimiSubscriptionFile.self, from: plain)
        else {
            let empty = KimiSubscriptionFile(shared: nil, perProfile: [:])
            cache = empty
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
        if let pid = profileID, var r = file.perProfile[pid.uuidString] {
            if (r.reauthRequiredAt != nil) != flagged {
                r.reauthRequiredAt = stamp
                file.perProfile[pid.uuidString] = r
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

    public func record(for profileID: UUID?) -> KimiSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let pid = profileID, let r = file.perProfile[pid.uuidString] { return r }
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
        if let pid = profileID, file.perProfile[pid.uuidString] != nil {
            file.perProfile[pid.uuidString] = record
        } else { file.shared = record }
        try persistLocked(file)
    }
    public func forget(for profileID: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked()
        if let pid = profileID { file.perProfile[pid.uuidString] = nil } else { file.shared = nil }
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
    private static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private static let refreshMargin: TimeInterval = 300

    public init(store: KimiSubscriptionStore) { self.store = store }

    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }
        return try await performRefresh(for: profileID)
    }

    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID) else { return }
        if record.accessToken != stale { return }
        _ = try? await performRefresh(for: profileID)
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
