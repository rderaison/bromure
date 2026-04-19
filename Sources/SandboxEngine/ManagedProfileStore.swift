import Foundation
import CryptoKit

/// On-disk storage for a managed profile bundle.
///
/// Layout:
///   ~/Library/Application Support/Bromure/managed/
///     install.json              (InstallIdentityStore)
///     profile/
///       profile.json            (ManagedProfile metadata + signed manifest)
///       assets/<filename>       (decrypted payload from sealed-box)
///       mtls/                   (leaf cert + CA)
///         cert.pem
///         ca.pem
///         key-ref.json          (pointer to Keychain private-key tag)
public final class ManagedProfileStore {
    public static let shared = ManagedProfileStore()

    private let root: URL
    private var cachedProfile: ManagedProfile?

    private init() {
        self.root = VMConfig.defaultStorageDirectory
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    private var metadataURL: URL { root.appendingPathComponent("profile.json") }
    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    private var assetsDir: URL { root.appendingPathComponent("assets", isDirectory: true) }
    private var mtlsDir: URL { root.appendingPathComponent("mtls", isDirectory: true) }

    public func assetPath(_ filename: String) -> URL {
        assetsDir.appendingPathComponent(filename)
    }

    public var mtlsCertURL: URL { mtlsDir.appendingPathComponent("cert.pem") }
    public var mtlsCAURL: URL { mtlsDir.appendingPathComponent("ca.pem") }

    // MARK: - Load / save

    /// Load and verify the managed profile. Returns nil if no managed profile
    /// exists OR if verification fails.
    public func load() -> ManagedProfile? {
        if let cached = cachedProfile { return cached }
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(ManagedProfile.self, from: data) else {
            return nil
        }
        // Re-verify signature + asset hashes before trusting.
        do {
            try verify(profile: profile)
        } catch {
            print("[ManagedProfileStore] verification failed: \(error)")
            return nil
        }
        cachedProfile = profile
        return profile
    }

    public func save(
        _ profile: ManagedProfile,
        assetsPlaintext: [String: Data],
        rawManifestJSON: Data,
    ) throws {
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mtlsDir, withIntermediateDirectories: true)
        try rawManifestJSON.write(to: manifestURL, options: .atomic)

        // Wipe any asset files the server no longer includes.
        let current = (try? FileManager.default.contentsOfDirectory(
            at: assetsDir, includingPropertiesForKeys: nil)
        ) ?? []
        let wanted = Set(profile.assets.map(\.filename))
        for url in current where !wanted.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        for (name, data) in assetsPlaintext {
            let dest = assetsDir.appendingPathComponent(name)
            try data.write(to: dest, options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: metadataURL, options: .atomic)
        cachedProfile = profile
    }

    public func destroy() {
        try? FileManager.default.removeItem(at: root)
        cachedProfile = nil
    }

    // MARK: - Verification

    private func verify(profile: ManagedProfile) throws {
        // Re-verify the signed manifest against the stored signature + pubkey.
        if let rawManifest = try? Data(contentsOf: manifestURL),
           let manifestObj = try? JSONSerialization.jsonObject(with: rawManifest) {
            let ok = (try? ManagedBundleCrypto.verify(
                manifest: manifestObj,
                signatureB64: profile.manifestSignatureB64,
                publicKeyPem: profile.signingKeyPublicPem,
            )) ?? false
            if !ok { throw ManagedBundleError.signatureInvalid }
        } else {
            throw ManagedBundleError.signatureInvalid
        }
        // Re-check asset hashes on disk.
        for asset in profile.assets {
            let path = assetPath(asset.filename)
            guard let bytes = try? Data(contentsOf: path) else {
                throw ManagedBundleError.assetMissing(asset.filename)
            }
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard sha == asset.sha256 else {
                throw ManagedBundleError.assetHashMismatch(asset.filename)
            }
        }
    }
}
