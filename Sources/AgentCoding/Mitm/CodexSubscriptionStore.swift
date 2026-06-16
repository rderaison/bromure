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

    public init(accessToken: String, refreshToken: String, idToken: String,
                expiresAt: Date, savedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
    }
}

private struct CodexSubscriptionFile: Codable {
    var shared: CodexSubscriptionRecord?
    var perProfile: [String: CodexSubscriptionRecord]
}

public final class CodexSubscriptionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: CodexSubscriptionFile?
    /// Bogus access-token JWT currently in use by a subscription session →
    /// the profile it belongs to. The proxy swaps a Bearer only for keys here.
    private var bogusKeys: [String: UUID] = [:]

    public init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = supportDir.appendingPathComponent("codex-subscription.enc")
    }

    // MARK: - Records

    private func loadLocked() -> CodexSubscriptionFile {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: fileURL),
              let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(CodexSubscriptionFile.self, from: plain)
        else {
            let empty = CodexSubscriptionFile(shared: nil, perProfile: [:])
            cache = empty
            return empty
        }
        cache = file
        return file
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

    public func record(for profileID: UUID?) -> CodexSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let pid = profileID, let r = file.perProfile[pid.uuidString] { return r }
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
        return try await performRefresh(for: profileID)
    }

    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID) else { return }
        if record.accessToken != stale { return }
        _ = try? await performRefresh(for: profileID)
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
        guard http.statusCode == 200 else { throw CodexSubscriptionError.refreshHTTP(http.statusCode) }
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
        return newAccess
    }
}
