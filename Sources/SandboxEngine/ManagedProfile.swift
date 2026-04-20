import Foundation

/// A managed profile delivered by the control plane.
///
/// Unlike local `Profile`, the settings + asset filenames are authoritative —
/// the user cannot edit them. We store a signed manifest alongside so every
/// load re-verifies integrity.
public struct ManagedProfile: Codable, Identifiable, Equatable {
    public let id: UUID           // mapped from server UUID
    public let installId: String
    public let orgSlug: String
    public var version: Int
    public var name: String
    public var settings: [String: AnyCodable]
    public var assets: [ManagedAssetMetadata]
    public var mtls: ManagedMTLSConfig
    public var manifestSignatureB64: String
    public var signingKeyPublicPem: String
    public var publishedAt: Date
    public var lastSyncedAt: Date

    public init(
        id: UUID,
        installId: String,
        orgSlug: String,
        version: Int,
        name: String,
        settings: [String: AnyCodable],
        assets: [ManagedAssetMetadata],
        mtls: ManagedMTLSConfig,
        manifestSignatureB64: String,
        signingKeyPublicPem: String,
        publishedAt: Date,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.installId = installId
        self.orgSlug = orgSlug
        self.version = version
        self.name = name
        self.settings = settings
        self.assets = assets
        self.mtls = mtls
        self.manifestSignatureB64 = manifestSignatureB64
        self.signingKeyPublicPem = signingKeyPublicPem
        self.publishedAt = publishedAt
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct ManagedAssetMetadata: Codable, Equatable {
    public let filename: String
    public let sizeBytes: Int
    public let sha256: String
}

public struct ManagedMTLSConfig: Codable, Equatable {
    public let enabled: Bool
    public var cnTemplate: String?
    public var certValiditySeconds: Int?
}

/// Server-controlled session-trace upload policy for a managed profile.
///
/// When `enabled` is true, the client is required to capture HTTP traces for
/// every session opened against this profile and upload them to `endpoint`
/// via mTLS (using the profile's issued leaf cert). The user cannot disable
/// it — that's the point. `level` tunes what fields ship per event:
///   - `.basic`   — URL/method/status/timing only, no headers, no bodies.
///   - `.headers` — also request/response headers.
///   - `.full`    — headers + post body + response body + form-field values.
public struct CloudTracePolicy: Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case basic, headers, full
    }

    public let enabled: Bool
    public let endpoint: URL?
    public let level: Level

    public static let disabled = CloudTracePolicy(enabled: false, endpoint: nil, level: .basic)
}

public extension ManagedProfile {
    /// Extract the `cloudTrace` block from the settings manifest, if any.
    ///
    /// Manifest shape (all fields optional — sensible defaults below):
    /// ```json
    /// "cloudTrace": {
    ///   "enabled":  true,
    ///   "endpoint": "https://analytics.bromure.io/ingest",
    ///   "level":    "full"
    /// }
    /// ```
    var cloudTrace: CloudTracePolicy {
        guard case .object(let obj) = settings["cloudTrace"] ?? .null else {
            return .disabled
        }
        let enabled: Bool = {
            if case .bool(let b) = obj["enabled"] ?? .null { return b }
            return false
        }()
        let endpoint: URL? = {
            if case .string(let s) = obj["endpoint"] ?? .null, let url = URL(string: s) {
                return url
            }
            return nil
        }()
        let level: CloudTracePolicy.Level = {
            if case .string(let s) = obj["level"] ?? .null,
               let lvl = CloudTracePolicy.Level(rawValue: s.lowercased()) {
                return lvl
            }
            return .full
        }()
        return CloudTracePolicy(enabled: enabled, endpoint: endpoint, level: level)
    }
}

/// Tiny Codable wrapper for arbitrary JSON values inside the settings dict.
public enum AnyCodable: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyCodable].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyCodable].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            AnyCodable.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown JSON"),
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Drop AnyCodable → plain JSON-compatible Swift value, for
    /// ManagedBundleCrypto.canonicalize() input.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }
}
