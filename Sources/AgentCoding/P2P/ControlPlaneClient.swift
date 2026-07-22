import Foundation

// MARK: - Control-plane REST DTOs (exact bromure-infra contract)

/// `POST /v1/devices/enroll` phase 1 response (src/routes/devices.js:262).
struct EnrollBeginResponse: Decodable {
    let challengeId: String
    let challenge: String
    /// The exact string to sign — `bromure-p2p-enroll:v1:<id>:<challenge>`.
    /// We sign what the server sends rather than reconstructing it.
    let signPayload: String
    let capability: String
    let expiresInSeconds: Int
}

/// `POST /v1/devices/enroll` phase 2 response (src/routes/devices.js:389).
struct EnrollCompleteResponse: Decodable {
    let deviceId: String
    let deviceToken: String
    let deviceTokenExpiresAt: String?
    let capability: String
    let orgSlug: String?
    /// "individual" | "organization" — a personal workspace never reports
    /// per-session connection telemetry.
    let orgKind: String?
    let userId: String?
}

/// One row of `GET /v1/devices` (src/routes/devices.js:451). Deliberately no
/// emails/IPs — just an opaque id, a name, capability, presence, and whether
/// this row is the caller itself.
struct DeviceInfo: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let capability: String
    let revoked: Bool
    let online: Bool
    let lastSeenAt: String?
    let isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, capability, revoked, online, lastSeenAt
        case isSelf = "self"
    }

    var isServer: Bool { capability == "server" }
    var displayName: String { name?.isEmpty == false ? name! : String(id.prefix(8)) }
}

/// The session-scoped identity of one peer within a grant.
struct GrantPeer: Decodable, Equatable {
    let deviceId: String
    /// Per-grant, 16-byte base64url. Relayed signal frames carry the SENDER's
    /// signalId in `from`; this is how a peer recognises the other's frames.
    let signalId: String
    let role: String   // "client" | "server"
}

/// `POST /v1/connections` response, and the body of the `connection` notify
/// pushed to the server device over its device channel (self/peer swapped per
/// point of view). 45-second TTL.
struct ConnectionGrant: Decodable, Equatable {
    let id: String
    let expiresAt: String
    /// This device's view of itself in the grant.
    let own: GrantPeer
    let peer: GrantPeer

    enum CodingKeys: String, CodingKey {
        case id, expiresAt, peer
        case own = "self"
    }
}

/// `POST /v1/connections/:id/turn-credentials` response (connections.js:271).
struct TurnCredentials: Decodable, Equatable {
    let urls: [String]
    let username: String
    let credential: String
    let ttlSeconds: Int
    let expiresAt: String
    let region: String

    private enum Outer: CodingKey { case turn }
    init(from decoder: Decoder) throws {
        // The server wraps it: { "turn": { … } }.
        let outer = try decoder.container(keyedBy: Outer.self)
        let t = try outer.nestedContainer(keyedBy: Inner.self, forKey: .turn)
        urls = try t.decode([String].self, forKey: .urls)
        username = try t.decode(String.self, forKey: .username)
        credential = try t.decode(String.self, forKey: .credential)
        ttlSeconds = try t.decode(Int.self, forKey: .ttlSeconds)
        expiresAt = try t.decode(String.self, forKey: .expiresAt)
        region = try t.decode(String.self, forKey: .region)
    }
    private enum Inner: String, CodingKey {
        case urls, username, credential, ttlSeconds, expiresAt, region
    }
}

/// A `POST /v1/connections/:id/complete` telemetry report. Enum/bounded scalars
/// only — the server stores no raw ICE candidates (connections.js:303).
struct ConnectionReport: Encodable {
    enum Outcome: String, Encodable { case connected, failed }
    enum PathKind: String, Encodable { case direct, srflx, relay }
    enum FailureStage: String, Encodable { case signaling, ice, dtls, transport, other }

    let outcome: Outcome
    let pathKind: PathKind?
    let timeToConnectedMs: Int?
    let failureStage: FailureStage?

    static func connected(pathKind: PathKind, timeToConnectedMs: Int) -> ConnectionReport {
        // The server forbids failureStage on a connected report.
        ConnectionReport(outcome: .connected, pathKind: pathKind,
                         timeToConnectedMs: max(0, min(600_000, timeToConnectedMs)),
                         failureStage: nil)
    }
    static func failed(stage: FailureStage) -> ConnectionReport {
        // The server forbids path fields on a failed report.
        ConnectionReport(outcome: .failed, pathKind: nil, timeToConnectedMs: nil, failureStage: stage)
    }
}

// MARK: - Errors

enum ControlPlaneError: Error, Equatable {
    case badBase(String)
    case http(status: Int, code: String?)
    case decode
    case turnUnavailable
    case transport(String)
}

// MARK: - Endpoint base resolution

/// Resolves the control-plane base URL and derives the WebSocket URL.
///
/// The one ambiguity flagged during infra review: the enroll deep-link embeds
/// `api=<APP_PUBLIC_URL>` which is `https://bromure.io` (no `/api`), while the
/// externally reachable device API is `https://bromure.io/api` (HAProxy maps
/// `/api/*` → api-server, stripping the prefix). So a bare `https://bromure.io`
/// base is normalised to `.../api`; anything that already carries a path (a
/// dev `http://127.0.0.1:3847`, or a base that already ends in `/api`) is left
/// untouched.
struct ControlPlaneEndpoint: Equatable {
    let base: URL

    init(base: String) throws {
        guard let normalized = ControlPlaneEndpoint.normalize(base) else {
            throw ControlPlaneError.badBase(base)
        }
        self.base = normalized
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard var comps = URLComponents(string: s), let host = comps.host else { return nil }
        let path = comps.path
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        if (path.isEmpty || path == "/") && !isLocal {
            comps.path = "/api"
        }
        return comps.url
    }

    func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    /// `wss://…/v1/device-channel` (or `ws://` for a plaintext dev base).
    var deviceChannelURL: URL {
        var comps = URLComponents(url: base.appendingPathComponent("/v1/device-channel"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = base.scheme == "http" ? "ws" : "wss"
        return comps.url!
    }
}

// MARK: - The client

/// Stateless HTTPS client for the device/connection API. Auth is the opaque
/// `deviceToken` bearer on every call except enrollment (which proves key
/// possession instead). No retries here — the caller decides backoff.
struct ControlPlaneClient {
    let endpoint: ControlPlaneEndpoint
    let session: URLSession

    init(endpoint: ControlPlaneEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: Enrollment (no bearer — key-possession proof)

    func enrollBegin(code: String, devicePubkeyHex: String,
                     deviceName: String?, capability: String?) async throws -> EnrollBeginResponse {
        var body: [String: Any] = ["code": code, "devicePubkey": devicePubkeyHex]
        if let deviceName { body["deviceName"] = deviceName }
        if let capability { body["capability"] = capability }
        return try await post("/v1/devices/enroll", body: body, bearer: nil)
    }

    func enrollComplete(challengeId: String, signatureBase64: String) async throws -> EnrollCompleteResponse {
        try await post("/v1/devices/enroll",
                       body: ["challengeId": challengeId, "signature": signatureBase64],
                       bearer: nil)
    }

    // MARK: Directory & connections (bearer)

    func listDevices(bearer: String) async throws -> [DeviceInfo] {
        struct Wrap: Decodable { let devices: [DeviceInfo] }
        let w: Wrap = try await get("/v1/devices", bearer: bearer)
        return w.devices
    }

    func requestConnection(bearer: String, targetDeviceId: String) async throws -> ConnectionGrant {
        struct Wrap: Decodable { let connection: ConnectionGrant }
        let w: Wrap = try await post("/v1/connections", body: ["deviceId": targetDeviceId], bearer: bearer)
        return w.connection
    }

    /// Turn this install's server role on/off (advertised in the directory +
    /// connectable while on). Driven by the app's Remote Access switch. Returns
    /// the resulting server state.
    @discardableResult
    func setServerMode(bearer: String, enabled: Bool) async throws -> Bool {
        struct Wrap: Decodable { let ok: Bool; let server: Bool }
        let w: Wrap = try await post("/v1/devices/server-mode", body: ["enabled": enabled], bearer: bearer)
        return w.server
    }

    func turnCredentials(bearer: String, connectionId: String) async throws -> TurnCredentials {
        do {
            return try await post("/v1/connections/\(connectionId)/turn-credentials",
                                  body: [:], bearer: bearer)
        } catch ControlPlaneError.http(let status, _) where status == 503 {
            throw ControlPlaneError.turnUnavailable
        }
    }

    @discardableResult
    func complete(bearer: String, connectionId: String, report: ConnectionReport) async throws -> Bool {
        struct Wrap: Decodable { let ok: Bool; let recorded: Bool }
        let data = try JSONEncoder().encode(report)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let w: Wrap = try await post("/v1/connections/\(connectionId)/complete", body: obj, bearer: bearer)
        return w.recorded
    }

    // MARK: iOS push notifications (bearer)

    private struct Ack: Decodable { let ok: Bool? }

    /// Register/refresh this device's APNs token so the account can push to it.
    func registerPushToken(bearer: String, token: String,
                           environment: String, bundleId: String) async throws {
        let _: Ack = try await post("/v1/devices/push-token",
            body: ["token": token, "environment": environment, "bundleId": bundleId],
            bearer: bearer)
    }

    /// Register/refresh this device's X25519 push encryption key (hex).
    func registerPushKey(bearer: String, pubkeyHex: String) async throws {
        let _: Ack = try await post("/v1/devices/push-key",
            body: ["pubkey": pubkeyHex], bearer: bearer)
    }

    /// Report that a coding agent on this server is waiting for input.
    func notifyNeedsInput(bearer: String, eventKey: String, profileId: String?,
                          windowIndex: Int?, fallbackTitle: String,
                          macIdleSeconds: Double?, sealed: [String: String] = [:]) async throws {
        var body: [String: Any] = ["eventKey": eventKey,
                                    "fallbackTitle": fallbackTitle,
                                    "sealed": sealed]
        if let profileId { body["profileId"] = profileId }
        if let windowIndex { body["windowIndex"] = windowIndex }
        if let macIdleSeconds { body["macIdleSeconds"] = macIdleSeconds }
        let _: Ack = try await post("/v1/notifications/needs-input",
                                    body: body, bearer: bearer)
    }

    /// Report that a pending question was answered or otherwise went away.
    func notifyResolved(bearer: String, eventKey: String) async throws {
        let _: Ack = try await post("/v1/notifications/resolved",
                                    body: ["eventKey": eventKey], bearer: bearer)
    }

    struct PendingNotification: Decodable {
        let eventKey: String
        let serverInstallId: String?
        let profileId: String?
        let windowIndex: Int?
        let delivered: Bool?
    }
    /// The account's currently-unanswered questions — the phone removes any
    /// delivered notification not in this set when it foregrounds.
    func pendingNotifications(bearer: String) async throws -> [PendingNotification] {
        struct Wrap: Decodable { let pending: [PendingNotification] }
        let w: Wrap = try await get("/v1/notifications/pending", bearer: bearer)
        return w.pending
    }

    /// A client + bearer bound to the current enrolled device, or nil if this
    /// device has no bromure.io identity yet.
    static func current() -> (client: ControlPlaneClient, bearer: String)? {
        guard let id = P2PIdentity.current(),
              let endpoint = try? ControlPlaneEndpoint(base: id.apiBase) else { return nil }
        return (ControlPlaneClient(endpoint: endpoint), id.bearer)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, bearer: String?) async throws -> T {
        try await send(makeRequest(path, method: "GET", body: nil, bearer: bearer))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], bearer: String?) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(makeRequest(path, method: "POST", body: data, bearer: bearer))
    }

    private func makeRequest(_ path: String, method: String, body: Data?, bearer: String?) -> URLRequest {
        var req = URLRequest(url: endpoint.url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ControlPlaneError.transport((error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ControlPlaneError.decode }
        guard (200..<300).contains(http.statusCode) else {
            // The server's error body is `{ "error": "<code>" }`.
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw ControlPlaneError.http(status: http.statusCode, code: code)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw ControlPlaneError.decode
        }
        return value
    }
}

// MARK: - ISO8601 helpers

enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(from s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}
