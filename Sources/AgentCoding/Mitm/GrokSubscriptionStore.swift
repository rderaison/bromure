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

public struct GrokSubscriptionRecord: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var savedAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date, savedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.savedAt = savedAt
    }
}

private struct GrokSubscriptionFile: Codable {
    var shared: GrokSubscriptionRecord?
    var perProfile: [String: GrokSubscriptionRecord]
}

public final class GrokSubscriptionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: GrokSubscriptionFile?
    private var bogusKeys: [String: UUID] = [:]

    public init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        self.fileURL = supportDir.appendingPathComponent("grok-subscription.enc")
    }

    private func loadLocked() -> GrokSubscriptionFile {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: fileURL),
              let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(GrokSubscriptionFile.self, from: plain)
        else {
            let empty = GrokSubscriptionFile(shared: nil, perProfile: [:])
            cache = empty
            return empty
        }
        cache = file
        return file
    }

    private func persistLocked(_ file: GrokSubscriptionFile) throws {
        cache = file
        let plain = try JSONEncoder().encode(file)
        let blob = try SecretsVault.encrypt(plain)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    public func record(for profileID: UUID?) -> GrokSubscriptionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = loadLocked()
        if let pid = profileID, let r = file.perProfile[pid.uuidString] { return r }
        return file.shared
    }

    public func hasCredential(for profileID: UUID?) -> Bool { record(for: profileID) != nil }

    public func setShared(_ record: GrokSubscriptionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.shared = record; try persistLocked(file)
    }
    public func setOverride(_ record: GrokSubscriptionRecord, for profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var file = loadLocked(); file.perProfile[profileID.uuidString] = record; try persistLocked(file)
    }
    public func update(_ record: GrokSubscriptionRecord, for profileID: UUID?) throws {
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

public enum GrokSubscriptionError: Error, CustomStringConvertible {
    case noCredential
    case refreshHTTP(Int)
    case malformedRefreshResponse
    public var description: String {
        switch self {
        case .noCredential: return "no Grok subscription credential registered"
        case .refreshHTTP(let c): return "Grok OIDC refresh failed (HTTP \(c))"
        case .malformedRefreshResponse: return "Grok OIDC refresh returned an unexpected body"
        }
    }
}

public actor GrokSubscriptionRefresher {
    private let store: GrokSubscriptionStore
    private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let refreshMargin: TimeInterval = 300

    public init(store: GrokSubscriptionStore) { self.store = store }

    public func accessToken(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw GrokSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }
        return try await performRefresh(for: profileID)
    }

    public func noteUnauthorized(stale: String, for profileID: UUID?) async {
        guard let record = store.record(for: profileID) else { return }
        if record.accessToken != stale { return }
        _ = try? await performRefresh(for: profileID)
    }

    private func performRefresh(for profileID: UUID?) async throws -> String {
        guard let record = store.record(for: profileID) else { throw GrokSubscriptionError.noCredential }
        if record.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return record.accessToken }

        // Standard OIDC token endpoint → application/x-www-form-urlencoded.
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
        guard let http = response as? HTTPURLResponse else { throw GrokSubscriptionError.malformedRefreshResponse }
        guard http.statusCode == 200 else { throw GrokSubscriptionError.refreshHTTP(http.statusCode) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { throw GrokSubscriptionError.malformedRefreshResponse }

        let newRefresh = (json["refresh_token"] as? String) ?? record.refreshToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? ((json["expires_in"] as? Int).map(Double.init)) ?? 3600

        let updated = GrokSubscriptionRecord(
            accessToken: newAccess, refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn), savedAt: Date())
        try store.update(updated, for: profileID)
        return newAccess
    }
}
