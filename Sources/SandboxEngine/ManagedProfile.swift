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
