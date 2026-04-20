import Foundation
import CryptoKit

/// Triple of PEMs the guest needs to install a client cert into its NSS db.
public struct ManagedMTLSMaterial: Sendable {
    public let certPem: String
    public let keyPem: String   // PKCS#8 PEM
    public let caPem: String
}

/// On-disk store for the set of managed profiles currently assigned to this
/// install. One subdirectory per profile; the store handles reconciliation
/// (add/remove) driven by sync.
///
/// Layout:
///   ~/Library/Application Support/Bromure/managed/
///     install.json                            (InstallIdentityStore)
///     profiles/
///       <profileId>/
///         profile.json                         (ManagedProfile)
///         manifest.json                        (raw signed payload)
///         assets/<filename>                    (decrypted asset bytes)
///         mtls/{cert.pem,ca.pem}               (leaf cert + CA — if mTLS on)
public final class ManagedProfileStore {
    public static let shared = ManagedProfileStore()

    private let root: URL
    private var cache: [UUID: ManagedProfile] = [:]

    private init() {
        self.root = VMConfig.defaultStorageDirectory
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    private func dir(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
    private func metadataURL(for id: UUID) -> URL { dir(for: id).appendingPathComponent("profile.json") }
    private func manifestURL(for id: UUID) -> URL { dir(for: id).appendingPathComponent("manifest.json") }
    private func assetsDir(for id: UUID) -> URL { dir(for: id).appendingPathComponent("assets", isDirectory: true) }
    public func mtlsDir(for id: UUID) -> URL { dir(for: id).appendingPathComponent("mtls", isDirectory: true) }
    public func assetPath(profileId: UUID, filename: String) -> URL {
        assetsDir(for: profileId).appendingPathComponent(filename)
    }
    public func mtlsCertURL(for id: UUID) -> URL { mtlsDir(for: id).appendingPathComponent("cert.pem") }
    public func mtlsCAURL(for id: UUID) -> URL { mtlsDir(for: id).appendingPathComponent("ca.pem") }

    /// Bundle of mTLS material ready to be pushed into a guest VM at session
    /// launch. Returns nil if the profile isn't managed, doesn't have mTLS
    /// enabled, or a leaf cert hasn't been issued yet.
    public func mtlsMaterial(profileId: UUID) -> ManagedMTLSMaterial? {
        let certURL = mtlsCertURL(for: profileId)
        let caURL = mtlsCAURL(for: profileId)
        guard FileManager.default.fileExists(atPath: certURL.path),
              FileManager.default.fileExists(atPath: caURL.path),
              let certPem = try? String(contentsOf: certURL, encoding: .utf8),
              let caPem = try? String(contentsOf: caURL, encoding: .utf8)
        else { return nil }
        guard let privKey = try? ManagedProfileSync.shared.loadMTLSPrivateKey(for: profileId) else {
            return nil
        }
        return ManagedMTLSMaterial(
            certPem: certPem,
            keyPem: privKey.pemRepresentation,
            caPem: caPem,
        )
    }

    // MARK: - Read

    /// Load + verify every managed profile on disk. Profiles whose signature
    /// doesn't verify (tamper, stale key) are silently skipped.
    public func loadAll() -> [ManagedProfile] {
        if !cache.isEmpty { return Array(cache.values) }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [ManagedProfile] = []
        for d in dirs where d.hasDirectoryPath {
            guard let id = UUID(uuidString: d.lastPathComponent.uppercased()) else { continue }
            let meta = metadataURL(for: id)
            guard let data = try? Data(contentsOf: meta),
                  let profile = try? decoder.decode(ManagedProfile.self, from: data)
            else { continue }
            do {
                try verify(profile: profile)
                out.append(profile)
                cache[id] = profile
            } catch {
                print("[ManagedProfileStore] skipping \(id) — \(error)")
            }
        }
        return out
    }

    public func profile(id: UUID) -> ManagedProfile? {
        loadAll().first { $0.id == id }
    }

    // MARK: - Write

    public func save(
        _ profile: ManagedProfile,
        assetsPlaintext: [String: Data],
        rawManifestJSON: Data,
    ) throws {
        // Defense in depth: reject any unsafe filename before we so much as
        // compute a directory. Upstream sync also filters, but this ensures
        // no future caller can slip past.
        for name in profile.assets.map(\.filename) + Array(assetsPlaintext.keys) {
            guard ManagedProfileSync.isSafeAssetFilename(name) else {
                throw ManagedBundleError.assetHashMismatch(name)
            }
        }

        let base = dir(for: profile.id)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsDir(for: profile.id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mtlsDir(for: profile.id), withIntermediateDirectories: true)

        try rawManifestJSON.write(to: manifestURL(for: profile.id), options: .atomic)

        // Drop asset files no longer in the manifest.
        let current = (try? FileManager.default.contentsOfDirectory(
            at: assetsDir(for: profile.id), includingPropertiesForKeys: nil)
        ) ?? []
        let wanted = Set(profile.assets.map(\.filename))
        for url in current where !wanted.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        // Belt-and-suspenders: resolve the destination and assert it stays
        // inside the assets directory before opening the file.
        let assetsRoot = assetsDir(for: profile.id).standardizedFileURL.path
        for (name, data) in assetsPlaintext {
            let dest = assetsDir(for: profile.id).appendingPathComponent(name)
            let resolved = dest.standardizedFileURL.path
            guard resolved.hasPrefix(assetsRoot + "/") else {
                throw ManagedBundleError.assetHashMismatch(name)
            }
            try data.write(to: dest, options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: metadataURL(for: profile.id), options: .atomic)
        cache[profile.id] = profile
    }

    /// Remove a single profile (including its mTLS material) from disk.
    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: dir(for: id))
        cache.removeValue(forKey: id)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache.removeAll()
    }

    // MARK: - Verification

    private func verify(profile: ManagedProfile) throws {
        guard let rawManifest = try? Data(contentsOf: manifestURL(for: profile.id)),
              let manifestObj = try? JSONSerialization.jsonObject(with: rawManifest)
        else {
            throw ManagedBundleError.signatureInvalid
        }
        let ok = (try? ManagedBundleCrypto.verify(
            manifest: manifestObj,
            signatureB64: profile.manifestSignatureB64,
            publicKeyPem: profile.signingKeyPublicPem,
        )) ?? false
        if !ok { throw ManagedBundleError.signatureInvalid }

        for asset in profile.assets {
            let path = assetPath(profileId: profile.id, filename: asset.filename)
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
