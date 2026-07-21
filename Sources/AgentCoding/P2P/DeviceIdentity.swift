import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - P2P device identity

/// One Bromure installation's control-plane identity (REMOTE_P2P_PLAN.md
/// §"Identity, pairing & trust"): a non-exportable-in-spirit Ed25519 signing
/// key plus the bearer credential the control plane issues at enrollment.
///
/// This is DISTINCT from the SSH client/host keys — those stay the end-to-end
/// application security boundary and never touch the control plane. The device
/// key is used ONLY to prove key-possession during enrollment; every later
/// request authenticates with the opaque `deviceToken` (matches the infra:
/// `installs.p2p_pubkey_ed25519` + `install_tokens`, verified server-side on
/// every call, revocation is immediate).
struct DeviceRecord: Codable, Equatable {
    /// Ed25519 private seed, hex (32 bytes → 64 chars). The secret half.
    var privateKeyHex: String
    /// The bearer credential (base64url) returned once at enrollment.
    var deviceToken: String
    var deviceTokenExpiresAt: Date?
    /// The control plane's opaque id for this device (== the install id).
    var deviceId: String
    /// "server" (advertises the agentic-coding-server capability) or "client".
    var capability: String
    var orgSlug: String?
    /// The workspace kind, "individual" | "organization" (nil for identities
    /// enrolled before the control plane returned it). Personal workspaces are
    /// never sent per-session telemetry.
    var orgKind: String?
    /// The API base this device enrolled against, e.g. "https://bromure.io/api".
    /// Persisted so later calls hit the same control plane the code came from.
    var apiBase: String

    var isServer: Bool { capability == "server" }

    /// Whether this device may report per-session connection telemetry
    /// (`POST /v1/connections/:id/complete`). Only confirmed organization
    /// workspaces do — an individual account, or an identity whose kind is
    /// unknown, records nothing. This is the privacy-preserving default: the
    /// telemetry is opt-in to an org, never inferred.
    var recordsSessionTelemetry: Bool { orgKind == "organization" }
}

/// The device identity keychain store. Mirrors `FatClientKeyStore`'s discipline:
/// a keychain read has three honest outcomes and a transient "unavailable" must
/// NEVER be mistaken for "not enrolled" (that would silently orphan the
/// device on the control plane and force a re-enroll after a screen lock).
enum DeviceIdentityStore {
    private static let service = "io.bromure.agentic-coding.p2p"
    private static let account = "device-record"

    enum LoadResult: Equatable {
        case found(DeviceRecord)
        case notEnrolled
        case unavailable(OSStatus)
    }

    static func load() -> LoadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let rec = try? JSONDecoder().decode(DeviceRecord.self, from: data)
            else { return .unavailable(status) }
            return .found(rec)
        case errSecItemNotFound:
            return .notEnrolled
        default:
            return .unavailable(status)
        }
    }

    @discardableResult
    static func store(_ rec: DeviceRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(rec) else { return false }
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            // After-first-unlock, device-bound: the P2P listener must hold its
            // device-channel open and answer connection offers while the screen
            // is locked, same rationale as the fat-client SSH key.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Erase the local identity (used on server-side revoke: close, then forget
    /// so the next launch re-enrolls cleanly rather than looping on a dead token).
    static func erase() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
    }
}

// MARK: - Signing key

/// Thin wrapper over the device's Ed25519 key with the exact encodings the
/// control plane expects (bromure-infra `src/crypto/ed25519.js` + the enroll
/// challenge in `src/routes/devices.js`).
struct DeviceSigningKey {
    let key: Curve25519.Signing.PrivateKey

    init() { key = Curve25519.Signing.PrivateKey() }

    init?(privateKeyHex hex: String) {
        guard let raw = Data(hexString: hex),
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        key = k
    }

    var privateKeyHex: String { key.rawRepresentation.hexEncodedString() }

    /// Raw 32-byte public key, hex-encoded (64 chars) — the `devicePubkey`
    /// the server ingests with the SPKI DER prefix. Matches `PUBKEY_RE`.
    var publicKeyHex: String { key.publicKey.rawRepresentation.hexEncodedString() }

    /// Ed25519 signature over `payload`, standard base64 (NOT base64url) — the
    /// `signature` field for enroll phase 2. The server signs/verifies the
    /// exact UTF-8 string `bromure-p2p-enroll:v1:<challengeId>:<challenge>`.
    func signBase64(_ payload: String) -> String? {
        guard let sig = try? key.signature(for: Data(payload.utf8)) else { return nil }
        return sig.base64EncodedString()
    }
}

// MARK: - Hex helpers

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self.init(bytes)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
