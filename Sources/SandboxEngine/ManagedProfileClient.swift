import Foundation
import CryptoKit

public struct ManagedProfileClient {
    public let serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    // MARK: - Enroll

    public struct EnrollResponse: Decodable {
        public let installId: String
        public let installToken: String
        public let orgSlug: String
        public let userId: String
        public let userEmail: String
        // The server stamps the install row with the app the enrollment
        // code was issued for. Returned so the client can sanity-check
        // it ended up where it expected ("agentic-coding" only).
        public let app: String?
    }

    public func enroll(code: String, installPubkeyHex: String, deviceName: String) async throws -> EnrollResponse {
        // Convenience overload preserves the original Bromure Web call
        // shape (no `app`). Server defaults to 'web' when the field is
        // absent on the wire.
        return try await enroll(
            code: code, installPubkeyHex: installPubkeyHex, deviceName: deviceName, app: nil,
        )
    }

    public func enroll(
        code: String,
        installPubkeyHex: String,
        deviceName: String,
        app: String?,
    ) async throws -> EnrollResponse {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/enroll"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "code": code,
            "installPubkey": installPubkeyHex,
            "deviceName": deviceName,
        ]
        // Codes are app-scoped server-side; the redeeming client doesn't
        // strictly need to send `app` because the token row already
        // carries it. We pass it anyway so misuse (an admin minting a
        // code for the wrong app) surfaces here as a server-side reject
        // rather than silently producing the wrong install kind.
        if let app { body["app"] = app }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(EnrollResponse.self, from: data)
    }

    // MARK: - Profile sync (list)

    public struct ProfilesResponse: Decodable {
        public let profiles: [ProfileEntry]
        public let revoked: Bool
    }

    public struct ProfileEntry: Decodable {
        public let profileId: String
        public let version: Int
        public let manifest: ManifestPayload
        public let signatureB64: String
        public let signingKeyPublicPem: String
        public let sealedPayloadB64: String
    }

    public struct ManifestPayload: Decodable {
        public let profileId: String
        public let version: Int
        public let name: String
        public let settings: [String: AnyCodable]
        public let assets: [AssetEntry]
        public let mtls: MTLSEntry
        public let signingKey: SigningKeyEntry
        public let publishedAt: String

        public struct AssetEntry: Decodable {
            public let filename: String
            public let sizeBytes: Int
            public let sha256: String
        }
        public struct MTLSEntry: Decodable {
            public let enabled: Bool
            public let cnTemplate: String?
            public let certValiditySeconds: Int?
        }
        public struct SigningKeyEntry: Decodable {
            public let id: String
            public let publicKeyPem: String
        }
    }

    /// Returns both the parsed struct and the raw `profiles[i].manifest` JSON
    /// bytes (one blob per profile, sorted-keys normalized) so the caller can
    /// verify signatures against the exact bytes the server signed.
    public func fetchProfiles(
        installId: String, bearer: String,
    ) async throws -> (ProfilesResponse, [String: Data]) {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/installs/\(installId)/profiles"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        let decoded = try JSONDecoder().decode(ProfilesResponse.self, from: data)
        let manifests = try Self.extractManifestBytes(from: data)
        return (decoded, manifests)
    }

    private static func extractManifestBytes(from responseData: Data) throws -> [String: Data] {
        guard
            let top = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let profiles = top["profiles"] as? [[String: Any]]
        else {
            throw ManagedProfileClientError.sealedPayloadInvalid
        }
        var out: [String: Data] = [:]
        for entry in profiles {
            guard let pid = entry["profileId"] as? String,
                  let m = entry["manifest"]
            else { continue }
            out[pid] = try JSONSerialization.data(
                withJSONObject: m,
                options: [.sortedKeys],
            )
        }
        return out
    }

    // MARK: - Heartbeat

    public struct HeartbeatResponse: Decodable {
        public let profiles: [ProfileVersion]
        public let revoked: Bool

        public struct ProfileVersion: Decodable {
            public let profileId: String
            public let version: Int
        }
    }

    public func heartbeat(installId: String, bearer: String) async throws -> HeartbeatResponse {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/installs/\(installId)/heartbeat"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(HeartbeatResponse.self, from: data)
    }

    // MARK: - mTLS CSR signing (per profile)

    public struct CertResponse: Decodable {
        public let certPem: String
        public let caCertPem: String
        public let serialHex: String
        public let notBefore: Date
        public let notAfter: Date

        enum CodingKeys: String, CodingKey {
            case certPem, caCertPem, serialHex, notBefore, notAfter
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            certPem = try c.decode(String.self, forKey: .certPem)
            caCertPem = try c.decode(String.self, forKey: .caCertPem)
            serialHex = try c.decode(String.self, forKey: .serialHex)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            notBefore = fmt.date(from: try c.decode(String.self, forKey: .notBefore)) ?? Date()
            notAfter = fmt.date(from: try c.decode(String.self, forKey: .notAfter)) ?? Date()
        }
    }

    public func signCSR(
        installId: String, bearer: String, profileId: String, csrPem: String,
    ) async throws -> CertResponse {
        try await signCSR(
            installId: installId, bearer: bearer,
            profileId: profileId as String?, csrPem: csrPem,
        )
    }

    /// `profileId == nil` ⇒ sign with the workspace org CA (the path BAC
    /// installs always use; AC has no managed-profile concept on the
    /// server side). With a profileId, the server prefers that profile's
    /// CA and falls back to the org CA only if the profile has none.
    public func signCSR(
        installId: String, bearer: String, profileId: String?, csrPem: String,
    ) async throws -> CertResponse {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/installs/\(installId)/cert"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["csrPem": csrPem]
        if let profileId { body["profileId"] = profileId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(CertResponse.self, from: data)
    }

    // MARK: - Helpers

    private static func assertOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw ManagedProfileClientError.httpError(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ManagedProfileClientError.httpError(http.statusCode, body)
        }
    }
}

public enum ManagedProfileClientError: Error, LocalizedError {
    case httpError(Int, String)
    case notEnrolled
    case signatureInvalid
    case sealedPayloadInvalid

    public var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .notEnrolled: return "Bromure is not enrolled"
        case .signatureInvalid: return "Managed profile signature did not verify"
        case .sealedPayloadInvalid: return "Could not open sealed profile payload"
        }
    }
}
