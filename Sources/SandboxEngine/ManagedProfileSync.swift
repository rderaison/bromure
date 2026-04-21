import Foundation
import CryptoKit
import _CryptoExtras
import X509
import SwiftASN1

/// Orchestrates enrollment + profile-list sync + mTLS leaf issuance on the
/// client. Each install may be enrolled in multiple orgs simultaneously —
/// sync reconciles across every enrollment. Within a single enrollment the
/// set of managed profiles delivered is the union of direct + group
/// assignments, resolved server-side on every sync.
public final class ManagedProfileSync {
    public static let shared = ManagedProfileSync()

    public static var defaultServerURL: URL {
        if let env = ProcessInfo.processInfo.environment["BROMURE_MANAGED_URL"],
           let url = URL(string: env) {
            return url
        }
        if let s = UserDefaults.standard.string(forKey: "managed.serverURL"),
           let url = URL(string: s) {
            return url
        }
        return URL(string: "https://bromure.io/api")!
    }

    private init() {}

    // MARK: - Enroll

    /// Post-sync callback fired on the main actor so UI state (ProfileManager,
    /// AppState) can react to changes in the managed profile set.
    public static var onSyncComplete: (@Sendable () -> Void)?

    @discardableResult
    public func enroll(
        code: String,
        serverURL: URL = defaultServerURL,
        deviceName: String = Host.current().localizedName ?? "unnamed",
    ) async throws -> [ManagedProfile] {
        let x25519 = try InstallIdentityStore.ensureX25519Key()
        let client = ManagedProfileClient(serverURL: serverURL)
        let resp = try await client.enroll(
            code: code,
            installPubkeyHex: x25519.publicKeyHex,
            deviceName: deviceName,
        )
        try InstallIdentityStore.storeInstallToken(resp.installToken, for: resp.installId)
        let identity = InstallIdentity(
            installId: resp.installId,
            orgSlug: resp.orgSlug,
            userId: resp.userId,
            userEmail: resp.userEmail,
            serverURL: serverURL,
            enrolledAt: Date(),
            deviceName: deviceName,
        )
        try InstallIdentityStore.save(identity)
        return try await syncProfiles(for: identity.installId)
    }

    // MARK: - Sync — reconcile local state with server-assigned set

    /// Sync every enrolled install and return the aggregated list of managed
    /// profiles saved on disk. Per-install errors are rethrown as the first
    /// failure to keep the existing single-install call sites working; once
    /// multi-install sync becomes the default, callers may want to surface
    /// per-install failures via `syncProfiles(for:)`.
    @discardableResult
    public func syncProfiles() async throws -> [ManagedProfile] {
        let installs = InstallIdentityStore.loadAll()
        guard !installs.isEmpty else {
            throw ManagedProfileClientError.notEnrolled
        }
        var aggregate: [ManagedProfile] = []
        var firstError: Error?
        var syncedIds: Set<UUID> = []
        for identity in installs {
            do {
                let saved = try await syncProfiles(for: identity.installId, fireCallback: false)
                for p in saved { syncedIds.insert(p.id) }
                aggregate.append(contentsOf: saved)
            } catch {
                firstError = firstError ?? error
            }
        }
        // Remove any locally-stored profile that no enrollment still claims.
        for existing in ManagedProfileStore.shared.loadAll() where !syncedIds.contains(existing.id) {
            // Only drop profiles whose owning install is still present — if the
            // install itself is gone (unenrolled separately) the caller will
            // have pruned already. Here we only want to expire profiles that
            // the server dropped from an install we did successfully sync.
            if installs.contains(where: { $0.installId == existing.installId }) {
                ManagedProfileStore.shared.remove(id: existing.id)
                deleteMTLSPrivateKey(for: existing.id)
            }
        }
        Self.onSyncComplete?()
        if let err = firstError, aggregate.isEmpty { throw err }
        return aggregate
    }

    /// Sync a single enrollment. Separating this out lets UI surfaces retry
    /// one failing install without re-hitting every other server.
    @discardableResult
    public func syncProfiles(for installId: String) async throws -> [ManagedProfile] {
        try await syncProfiles(for: installId, fireCallback: true)
    }

    @discardableResult
    private func syncProfiles(
        for installId: String,
        fireCallback: Bool,
    ) async throws -> [ManagedProfile] {
        guard let identity = InstallIdentityStore.load(installId: installId),
              let token = InstallIdentityStore.loadInstallToken(for: installId)
        else {
            throw ManagedProfileClientError.notEnrolled
        }
        let client = ManagedProfileClient(serverURL: identity.serverURL)
        let (resp, manifestBytes) = try await client.fetchProfiles(
            installId: identity.installId, bearer: token,
        )

        let x25519 = try InstallIdentityStore.loadX25519Key()
        var kept: Set<UUID> = []
        var saved: [ManagedProfile] = []

        for entry in resp.profiles {
            guard let raw = manifestBytes[entry.profileId] else { continue }
            let rawObj = try JSONSerialization.jsonObject(with: raw)
            let ok = (try? ManagedBundleCrypto.verify(
                manifest: rawObj,
                signatureB64: entry.signatureB64,
                publicKeyPem: entry.signingKeyPublicPem,
            )) ?? false
            guard ok else {
                print("[ManagedProfileSync] skipping profile \(entry.profileId) — bad signature")
                continue
            }
            guard let blob = Data(base64Encoded: entry.sealedPayloadB64) else { continue }
            let plaintext: Data
            do {
                plaintext = try ManagedBundleCrypto.open(sealedBoxData: blob, recipient: x25519)
            } catch {
                print("[ManagedProfileSync] skipping profile \(entry.profileId) — sealed box: \(error)")
                continue
            }
            struct AssetsEnvelope: Decodable { let assets: [String: String] }
            let env = try JSONDecoder().decode(AssetsEnvelope.self, from: plaintext)

            // Drive asset ingestion from the SIGNED manifest, not the sealed
            // envelope — sealed-box is unauthenticated (any holder of the
            // install's public key can craft one), so we only accept filenames
            // present in the signed manifest whose bytes hash to the declared
            // sha256.
            var assetsPlain: [String: Data] = [:]
            var assetsOK = true
            for declared in entry.manifest.assets {
                guard Self.isSafeAssetFilename(declared.filename) else {
                    print("[ManagedProfileSync] skipping profile \(entry.profileId) — unsafe filename \(declared.filename)")
                    assetsOK = false
                    break
                }
                guard let b64 = env.assets[declared.filename],
                      let bytes = Data(base64Encoded: b64)
                else {
                    print("[ManagedProfileSync] skipping profile \(entry.profileId) — missing asset \(declared.filename)")
                    assetsOK = false
                    break
                }
                guard bytes.count == declared.sizeBytes else {
                    print("[ManagedProfileSync] skipping profile \(entry.profileId) — size mismatch on \(declared.filename)")
                    assetsOK = false
                    break
                }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard digest == declared.sha256 else {
                    print("[ManagedProfileSync] skipping profile \(entry.profileId) — sha256 mismatch on \(declared.filename)")
                    assetsOK = false
                    break
                }
                assetsPlain[declared.filename] = bytes
            }
            if !assetsOK { continue }

            guard let pid = UUID(uuidString: entry.profileId) else { continue }
            let managed = ManagedProfile(
                id: pid,
                installId: identity.installId,
                orgSlug: identity.orgSlug,
                version: entry.version,
                name: entry.manifest.name,
                settings: entry.manifest.settings,
                assets: entry.manifest.assets.map { ManagedAssetMetadata(
                    filename: $0.filename, sizeBytes: $0.sizeBytes, sha256: $0.sha256,
                ) },
                mtls: ManagedMTLSConfig(
                    enabled: entry.manifest.mtls.enabled,
                    cnTemplate: entry.manifest.mtls.cnTemplate,
                    certValiditySeconds: entry.manifest.mtls.certValiditySeconds,
                ),
                manifestSignatureB64: entry.signatureB64,
                signingKeyPublicPem: entry.signingKeyPublicPem,
                publishedAt: parseISO(entry.manifest.publishedAt),
            )
            try ManagedProfileStore.shared.save(managed, assetsPlaintext: assetsPlain, rawManifestJSON: raw)
            kept.insert(pid)
            saved.append(managed)

            if managed.mtls.enabled,
               !hasValidLeafCert(for: pid, expiringSoonerThan: 60 * 60) {
                try await issueMTLSLeaf(for: managed)
            }
        }

        // Within this install only, prune profiles the server no longer assigns.
        for existing in ManagedProfileStore.shared.loadAll()
        where existing.installId == identity.installId && !kept.contains(existing.id) {
            ManagedProfileStore.shared.remove(id: existing.id)
            deleteMTLSPrivateKey(for: existing.id)
        }

        if fireCallback { Self.onSyncComplete?() }
        return saved
    }

    // MARK: - mTLS

    public func issueMTLSLeaf(for profile: ManagedProfile) async throws {
        guard let identity = InstallIdentityStore.load(installId: profile.installId),
              let token = InstallIdentityStore.loadInstallToken(for: profile.installId)
        else { throw ManagedProfileClientError.notEnrolled }

        // RSA-2048 for broad compatibility. The server-side CSR parser
        // (node-forge) only reads RSA public keys; switching to ECDSA means
        // swapping the server to @peculiar/x509 or equivalent.
        let priv = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let privKey = Certificate.PrivateKey(priv)
        let subject = try DistinguishedName {
            CommonName("bromure-install-\(identity.installId)")
        }
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: privKey,
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha256WithRSAEncryption,
        )
        var ser = DER.Serializer()
        try csr.serialize(into: &ser)
        let csrPem = PEMDocument(type: "CERTIFICATE REQUEST", derBytes: ser.serializedBytes).pemString

        let client = ManagedProfileClient(serverURL: identity.serverURL)
        let resp = try await client.signCSR(
            installId: identity.installId,
            bearer: token,
            profileId: profile.id.uuidString.lowercased(),
            csrPem: csrPem,
        )
        try resp.certPem.write(
            to: ManagedProfileStore.shared.mtlsCertURL(for: profile.id),
            atomically: true, encoding: .utf8)
        try resp.caCertPem.write(
            to: ManagedProfileStore.shared.mtlsCAURL(for: profile.id),
            atomically: true, encoding: .utf8)
        // RSA private keys have no compact "raw" representation; store the
        // DER-encoded PKCS#8 blob instead.
        try storeMTLSPrivateKey(priv.derRepresentation, for: profile.id, serial: resp.serialHex)
    }

    public func loadMTLSPrivateKey(for profileId: UUID) throws -> _RSA.Signing.PrivateKey {
        let der = try readMTLSPrivateKey(for: profileId)
        return try _RSA.Signing.PrivateKey(derRepresentation: der)
    }

    // MARK: - Sign-out

    /// Remove a single enrollment and every profile / mTLS leaf tied to it.
    /// Other enrollments are untouched.
    public func unenroll(installId: String) {
        for p in ManagedProfileStore.shared.loadAll() where p.installId == installId {
            deleteMTLSPrivateKey(for: p.id)
            ManagedProfileStore.shared.remove(id: p.id)
        }
        InstallIdentityStore.remove(installId: installId)
        Self.onSyncComplete?()
    }

    /// Wipe every enrollment (equivalent to `unenroll` on each install,
    /// plus the shared X25519 key).
    public func destroyLocalState() {
        for p in ManagedProfileStore.shared.loadAll() {
            deleteMTLSPrivateKey(for: p.id)
        }
        ManagedProfileStore.shared.removeAll()
        InstallIdentityStore.destroy()
        Self.onSyncComplete?()
    }

    // MARK: - Private helpers

    /// Whitelist-style check against path-traversal filenames in server-delivered
    /// assets. Applied at the sync boundary and again in `ManagedProfileStore.save`.
    static func isSafeAssetFilename(_ name: String) -> Bool {
        if name.isEmpty || name.count > 255 { return false }
        if name == "." || name == ".." { return false }
        if name.hasPrefix(".") { return false }
        for scalar in name.unicodeScalars {
            if scalar.value == 0 { return false }           // NUL
            if scalar == "/" || scalar == "\\" { return false }
        }
        return true
    }

    private func parseISO(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
    }

    private func hasValidLeafCert(for profileId: UUID, expiringSoonerThan minSeconds: TimeInterval) -> Bool {
        let url = ManagedProfileStore.shared.mtlsCertURL(for: profileId)
        guard let pem = try? String(contentsOf: url, encoding: .utf8),
              let _ = try? readMTLSPrivateKey(for: profileId)
        else { return false }
        // Quick sniff: we don't parse the cert here — presence of key + cert
        // is enough for V1; full expiry check comes with cert parsing.
        _ = pem
        return true
    }

    // MARK: - Keychain for leaf keys (one per profile)

    private static let mtlsService = "io.bromure.app.managed-mtls"

    private func mtlsAccount(for profileId: UUID) -> String {
        "leaf-\(profileId.uuidString.lowercased())"
    }

    private func storeMTLSPrivateKey(_ raw: Data, for profileId: UUID, serial: String) throws {
        deleteMTLSPrivateKey(for: profileId)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: mtlsAccount(for: profileId),
            kSecAttrLabel as String: "Bromure managed mTLS key (serial \(serial))",
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw InstallIdentityError.keychainFailure(status, "store mtls leaf")
        }
    }

    private func readMTLSPrivateKey(for profileId: UUID) throws -> Data {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: mtlsAccount(for: profileId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var r: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &r)
        guard s == errSecSuccess, let d = r as? Data else { throw InstallIdentityError.notFound }
        return d
    }

    private func deleteMTLSPrivateKey(for profileId: UUID) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: mtlsAccount(for: profileId),
        ]
        SecItemDelete(q as CFDictionary)
    }
}
