import Foundation
import CryptoKit
import X509
import SwiftASN1

/// Orchestrates enrollment + profile-list sync + mTLS leaf issuance on the
/// client. The install is bound to a user in the org; the set of managed
/// profiles delivered is the union of direct + group assignments, resolved
/// server-side on every sync.
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
        return URL(string: "http://localhost:3847")!
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
        try InstallIdentityStore.storeInstallToken(resp.installToken)
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
        return try await syncProfiles()
    }

    // MARK: - Sync — reconcile local state with server-assigned set

    @discardableResult
    public func syncProfiles() async throws -> [ManagedProfile] {
        guard let identity = InstallIdentityStore.load(),
              let token = InstallIdentityStore.loadInstallToken()
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

        // Remove any locally-stored profile the server no longer assigns.
        for existing in ManagedProfileStore.shared.loadAll() where !kept.contains(existing.id) {
            ManagedProfileStore.shared.remove(id: existing.id)
            deleteMTLSPrivateKey(for: existing.id)
        }

        Self.onSyncComplete?()
        return saved
    }

    // MARK: - mTLS

    public func issueMTLSLeaf(for profile: ManagedProfile) async throws {
        guard let identity = InstallIdentityStore.load(),
              let token = InstallIdentityStore.loadInstallToken()
        else { throw ManagedProfileClientError.notEnrolled }

        let priv = P256.Signing.PrivateKey()
        let privKey = Certificate.PrivateKey(priv)
        let subject = try DistinguishedName {
            CommonName("bromure-install-\(identity.installId)")
        }
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: privKey,
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .ecdsaWithSHA256,
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
        try storeMTLSPrivateKey(priv.rawRepresentation, for: profile.id, serial: resp.serialHex)
    }

    public func loadMTLSPrivateKey(for profileId: UUID) throws -> P256.Signing.PrivateKey {
        let raw = try readMTLSPrivateKey(for: profileId)
        return try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    // MARK: - Sign-out

    public func destroyLocalState() {
        for p in ManagedProfileStore.shared.loadAll() {
            deleteMTLSPrivateKey(for: p.id)
        }
        ManagedProfileStore.shared.removeAll()
        InstallIdentityStore.destroy()
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
