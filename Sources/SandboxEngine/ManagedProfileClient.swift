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
        public let profileId: String
    }

    public func enroll(code: String, installPubkeyHex: String, deviceName: String) async throws -> EnrollResponse {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/enroll"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "code": code,
            "installPubkey": installPubkeyHex,
            "deviceName": deviceName,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(EnrollResponse.self, from: data)
    }

    // MARK: - Profile sync

    public struct ProfileResponse: Decodable {
        public let version: Int
        public let manifest: ManifestPayload
        public let signatureB64: String
        public let signingKeyPublicPem: String
        public let sealedPayloadB64: String
        public let revoked: Bool
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

    public func fetchProfile(installId: String, bearer: String) async throws -> (ProfileResponse, Data) {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/installs/\(installId)/profile"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data)
        let decoded = try JSONDecoder().decode(ProfileResponse.self, from: data)
        // Pull the raw `manifest` sub-object bytes out of the top-level body.
        // We need them verbatim for signature verification on reload.
        let raw = try Self.extractManifestBytes(from: data)
        return (decoded, raw)
    }

    private static func extractManifestBytes(from responseData: Data) throws -> Data {
        // The response is a JSON object with a `manifest` key whose value is
        // itself a JSON object. Re-parse-and-re-serialize the sub-object so
        // whitespace is normalized — the *content* is still what got signed
        // because the server signs canonicalize(manifest), not the raw bytes.
        guard
            let top = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let manifest = top["manifest"]
        else {
            throw ManagedProfileClientError.sealedPayloadInvalid
        }
        return try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys],
        )
    }

    // MARK: - Heartbeat

    public struct HeartbeatResponse: Decodable {
        public let latestVersion: Int
        public let revoked: Bool
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

    // MARK: - mTLS CSR signing

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

    public func signCSR(installId: String, bearer: String, csrPem: String) async throws -> CertResponse {
        var req = URLRequest(url: serverURL.appendingPathComponent("v1/installs/\(installId)/cert"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["csrPem": csrPem]
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
        case .notEnrolled: return "Bromure is not enrolled in a managed profile"
        case .signatureInvalid: return "Managed profile signature did not verify"
        case .sealedPayloadInvalid: return "Could not open sealed profile payload"
        }
    }
}
