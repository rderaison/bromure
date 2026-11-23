import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// bromure.io's device grant (RFC 8628's shape), for a server with no
/// browser: `POST /v1/device-grants` gives a user code and a link; the
/// person approves it, signed in, in any browser; `POST
/// /v1/device-grants/token` (polled) then hands over one ordinary one-time
/// enrollment code, redeemed by the usual two-phase /v1/devices/enroll.
/// The deviceCode is the only secret: it stays in this process.
// @port-skip linux-only: macOS signs in through the browser's bromure:// handoff
public struct DeviceGrant: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String
    public let interval: Int
    public let expiresIn: Int
}

// @port-skip linux-only: see DeviceGrant
public enum DeviceGrantPoll: Sendable, Equatable {
    case pending(interval: Int?)
    case slowDown(interval: Int?)
    case approved(code: String)
    case denied
    case expired
}

// @port-skip linux-only: see DeviceGrant
public enum DeviceGrantError: Error, CustomStringConvertible, Equatable {
    /// The service has no device grants (404): not deployed there.
    case unavailable
    case denied
    case expired
    case http(Int, String)
    case badResponse(String)
    case transport(String)

    // @port-skip linux-only: see DeviceGrant
    public var description: String {
        switch self {
        case .unavailable: return "bromure.io doesn't offer sign-in by link yet"
        case .denied: return "the sign-in was denied on bromure.io"
        case .expired: return "the sign-in link expired before it was approved; run `bromure-ac account sign-in` again"
        case .http(let s, let m): return "bromure.io answered \(s)\(m.isEmpty ? "" : ": \(m)")"
        case .badResponse(let m): return "unexpected answer from bromure.io: \(m)"
        case .transport(let m): return "couldn't reach bromure.io: \(m)"
        }
    }
}

// @port-skip linux-only: see DeviceGrant
public struct DeviceGrantClient: Sendable {
    /// One request: the status and body (tests script it).
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    public let base: URL
    let transport: Transport

    /// bromure.io's API (EnrollLink's default).
    // @port-skip linux-only: see DeviceGrant
    public static var defaultAPIBase: String { EnrollLink.defaultAPIBase }

    /// `base`: the API base (EnrollLink's default, https://bromure.io/api).
    // @port-skip linux-only: see DeviceGrant
    public init?(base: String, transport: Transport? = nil) {
        guard let url = ControlPlaneEndpoint.normalize(base) else { return nil }
        self.base = url
        self.transport = transport ?? { req in
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    // @port-skip linux-only: see DeviceGrant
    func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let status: Int, data: Data
        do { (status, data) = try await transport(req) } catch { throw DeviceGrantError.transport(error.localizedDescription) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// Starts a grant for this machine.
    // @port-skip linux-only: see DeviceGrant
    public func start(deviceName: String, platform: String = "linux", capability: String = "server") async throws -> DeviceGrant {
        let (status, j) = try await post("/v1/device-grants", ["deviceName": String(deviceName.prefix(120)),
                                                                "platform": platform, "capability": capability])
        if status == 404 { throw DeviceGrantError.unavailable }
        guard status == 200 || status == 201 else { throw DeviceGrantError.http(status, Self.message(j)) }
        guard let dc = j["deviceCode"] as? String, !dc.isEmpty, let uc = j["userCode"] as? String,
              let v = j["verificationUri"] as? String else {
            throw DeviceGrantError.badResponse("no deviceCode/userCode/verificationUri")
        }
        return DeviceGrant(deviceCode: dc, userCode: uc, verificationURI: v,
                           verificationURIComplete: j["verificationUriComplete"] as? String ?? v,
                           interval: Self.int(j["interval"]) ?? 5, expiresIn: Self.int(j["expiresIn"]) ?? 900)
    }

    /// One poll.
    // @port-skip linux-only: see DeviceGrant
    public func poll(_ deviceCode: String) async throws -> DeviceGrantPoll {
        let (status, j) = try await post("/v1/device-grants/token", ["deviceCode": deviceCode])
        if status == 404 { return .expired }   // unknown: gone, or never ours
        if status == 429 { return .slowDown(interval: Self.int(j["interval"])) }
        guard status == 200 else { throw DeviceGrantError.http(status, Self.message(j)) }
        switch j["status"] as? String {
        case "pending": return .pending(interval: Self.int(j["interval"]))
        case "slow_down": return .slowDown(interval: Self.int(j["interval"]))
        case "denied": return .denied
        case "expired": return .expired
        case "approved":
            guard let code = j["code"] as? String, !code.isEmpty else { throw DeviceGrantError.badResponse("approved without a code") }
            return .approved(code: code)
        case let s: throw DeviceGrantError.badResponse("status \(s ?? "missing")")
        }
    }

    /// Polls until the grant is approved (its enrollment code), denied or
    /// expired: every `interval` seconds, one more interval after a
    /// slow_down, and no longer than the grant lives.
    // @port-skip linux-only: see DeviceGrant
    public func waitForApproval(_ grant: DeviceGrant,
                                sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) },
                                now: @Sendable () -> Date = Date.init) async throws -> String {
        let deadline = now().addingTimeInterval(TimeInterval(grant.expiresIn))
        var interval = max(1, grant.interval)
        while true {
            try await sleep(interval)
            switch try await poll(grant.deviceCode) {
            case .approved(let code): return code
            case .denied: throw DeviceGrantError.denied
            case .expired: throw DeviceGrantError.expired
            case .pending(let i): if let i { interval = max(1, i) }
            case .slowDown(let i): interval = max(1, i ?? interval + max(1, grant.interval))
            }
            if now() >= deadline { throw DeviceGrantError.expired }
        }
    }

    /// The enrollment link the daemon redeems: the code, against this base.
    // @port-skip linux-only: see DeviceGrant
    public func enrollLink(code: String) -> String {
        var c = URLComponents()
        c.scheme = "bromure"
        c.host = "enroll"
        c.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "code", value: code),
                        URLQueryItem(name: "api", value: base.absoluteString)]
        return c.url?.absoluteString ?? code
    }

    // @port-skip linux-only: see DeviceGrant
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    // @port-skip linux-only: see DeviceGrant
    static func message(_ j: [String: Any]) -> String {
        (j["error"] as? String) ?? (j["message"] as? String) ?? ""
    }
}
