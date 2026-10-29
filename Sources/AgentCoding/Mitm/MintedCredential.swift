import Foundation

// MARK: - Credentials the guest mints through the proxy

/// A credential a workspace's VM created through an API while it ran --
/// `aws sts assume-role`, `aws iam create-access-key`, `aws ecr
/// get-login-password`, `doctl registry login`, `doctl kubernetes cluster
/// kubeconfig save`, `doctl spaces keys create` -- kept on the host. The
/// VM was handed a fake in its place (`CredentialMint`); the proxy swaps
/// the fake back (bearer kinds) or re-signs with the real secret (SigV4
/// kinds). Saved in the workspace's configuration, secrets encrypted with
/// the rest (`ProfileSecrets.mintedCredentialSecrets`), so the fakes the
/// guest stored keep working across restarts.
public struct MintedCredential: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A token presented as `Authorization: Bearer` or inside HTTP Basic
        /// credentials (registry logins). Swapped by the token map.
        case bearer
        /// An access key pair (+ session token) the guest signs SigV4 with.
        /// Re-signed by `AWSResigner`, matched on the access key id.
        case sigV4
    }
    public var id: UUID
    public var kind: Kind
    /// What minted it, for the editor and the log: "sts:AssumeRole",
    /// "DigitalOcean registry token".
    public var source: String
    /// Bearer: the hosts the token is swapped on. SigV4: empty for AWS, or
    /// the S3-compatible host family the key signs for
    /// (`digitaloceanspaces.com`).
    public var hosts: [String]
    /// SigV4 only: the access key id (identity, not secret -- the guest
    /// holds it, as it does the workspace's own).
    public var accessKeyID: String
    /// The real token (bearer) or secret access key (SigV4). Stripped into
    /// `ProfileSecrets` on save.
    public var secret: String
    /// SigV4 only: the real STS session token, when the key is temporary.
    public var sessionToken: String
    public var createdAt: Date
    /// When the issuer said it stops working; nil = no expiry given.
    public var expiresAt: Date?

    public init(id: UUID = UUID(), kind: Kind, source: String, hosts: [String] = [],
                accessKeyID: String = "", secret: String, sessionToken: String = "",
                createdAt: Date = Date(), expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.hosts = hosts
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.sessionToken = sessionToken
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Kept this long past its expiry, then dropped from the workspace. Until
    /// then an expired SigV4 key still answers "expired" for its access key
    /// id instead of the request falling back to the workspace's own key --
    /// which would run it as another identity.
    public static let retentionAfterExpiry: TimeInterval = 30 * 24 * 3600

    /// The fake the guest holds for a bearer token: stable for a given real
    /// value on this Mac (the engine's salt), so a fake stored in the VM
    /// before a restart still maps.
    public static func bearerFake(for real: String, salt: Data) -> String {
        SessionTokenPlan.deriveFake(prefix: "brm_mint_", real: real, salt: salt)
    }

    /// Drop credentials long past their expiry.
    public static func pruned(_ minted: [MintedCredential], now: Date = Date()) -> [MintedCredential] {
        minted.filter { m in
            guard let e = m.expiresAt else { return true }
            return now.timeIntervalSince(e) < retentionAfterExpiry
        }
    }
}
