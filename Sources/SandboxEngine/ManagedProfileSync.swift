import Foundation
import CryptoKit
import X509
import SwiftASN1

/// Orchestrates enrollment + profile sync + mTLS cert issuance on the client.
public final class ManagedProfileSync {
    public static let shared = ManagedProfileSync()

    /// Default server URL. Can be overridden via user defaults
    /// `managed.serverURL` or the `BROMURE_MANAGED_URL` environment variable.
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

    // MARK: - Enrollment

    /// Redeem an enrollment code. On success, the managed profile is fetched,
    /// verified, and persisted. If the profile has mTLS enabled, a leaf cert
    /// is also issued.
    @discardableResult
    public func enroll(
        code: String,
        serverURL: URL = defaultServerURL,
        deviceName: String = Host.current().localizedName ?? "unnamed",
    ) async throws -> ManagedProfile {
        // 1. Ensure a fresh X25519 key exists.
        let x25519 = try InstallIdentityStore.ensureX25519Key()

        // 2. Redeem.
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
            profileId: resp.profileId,
            serverURL: serverURL,
            enrolledAt: Date(),
            deviceName: deviceName,
        )
        try InstallIdentityStore.save(identity)

        // 3. Pull + persist the current profile.
        let profile = try await syncProfile()

        // 4. If mTLS is configured, generate a keypair + CSR + get it signed.
        if profile.mtls.enabled {
            try await issueMTLSLeaf()
        }
        return profile
    }

    // MARK: - Sync (fetch, verify, save)

    @discardableResult
    public func syncProfile() async throws -> ManagedProfile {
        guard let identity = InstallIdentityStore.load(),
              let token = InstallIdentityStore.loadInstallToken()
        else {
            throw ManagedProfileClientError.notEnrolled
        }
        let client = ManagedProfileClient(serverURL: identity.serverURL)
        let (resp, rawManifestJSON) = try await client.fetchProfile(installId: identity.installId, bearer: token)

        // Verify signature over the raw manifest bytes — this is what the
        // server canonicalized + signed.
        let rawObj = try JSONSerialization.jsonObject(with: rawManifestJSON)
        let ok = try ManagedBundleCrypto.verify(
            manifest: rawObj,
            signatureB64: resp.signatureB64,
            publicKeyPem: resp.signingKeyPublicPem,
        )
        guard ok else { throw ManagedProfileClientError.signatureInvalid }

        // Decrypt sealed payload.
        guard let blob = Data(base64Encoded: resp.sealedPayloadB64) else {
            throw ManagedProfileClientError.sealedPayloadInvalid
        }
        let x25519 = try InstallIdentityStore.loadX25519Key()
        let plaintext: Data
        do {
            plaintext = try ManagedBundleCrypto.open(sealedBoxData: blob, recipient: x25519)
        } catch {
            throw ManagedProfileClientError.sealedPayloadInvalid
        }
        struct AssetsEnvelope: Decodable {
            let assets: [String: String]
        }
        let env = try JSONDecoder().decode(AssetsEnvelope.self, from: plaintext)
        var assetsPlaintext: [String: Data] = [:]
        for (filename, b64) in env.assets {
            guard let bytes = Data(base64Encoded: b64) else {
                throw ManagedProfileClientError.sealedPayloadInvalid
            }
            assetsPlaintext[filename] = bytes
        }

        // Construct the local record + write to disk.
        let profile = ManagedProfile(
            id: UUID(uuidString: resp.manifest.profileId) ?? UUID(),
            installId: identity.installId,
            orgSlug: identity.orgSlug,
            version: resp.version,
            name: resp.manifest.name,
            settings: resp.manifest.settings,
            assets: resp.manifest.assets.map { ManagedAssetMetadata(
                filename: $0.filename, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
            },
            mtls: ManagedMTLSConfig(
                enabled: resp.manifest.mtls.enabled,
                cnTemplate: resp.manifest.mtls.cnTemplate,
                certValiditySeconds: resp.manifest.mtls.certValiditySeconds,
            ),
            manifestSignatureB64: resp.signatureB64,
            signingKeyPublicPem: resp.signingKeyPublicPem,
            publishedAt: parseISO(resp.manifest.publishedAt),
        )
        try ManagedProfileStore.shared.save(
            profile,
            assetsPlaintext: assetsPlaintext,
            rawManifestJSON: rawManifestJSON,
        )
        return profile
    }

    // MARK: - mTLS

    /// Generate a fresh P-256 keypair + CSR, ship it to the server for
    /// signing, write the returned cert chain to disk, and store the private
    /// key in the macOS Keychain.
    public func issueMTLSLeaf() async throws {
        guard let identity = InstallIdentityStore.load(),
              let token = InstallIdentityStore.loadInstallToken()
        else {
            throw ManagedProfileClientError.notEnrolled
        }

        // P-256 is widely compatible and fits nicely in the Secure Enclave.
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
        let resp = try await client.signCSR(installId: identity.installId, bearer: token, csrPem: csrPem)

        // Persist cert + CA to disk; stash the raw private key in Keychain.
        try resp.certPem.write(to: ManagedProfileStore.shared.mtlsCertURL, atomically: true, encoding: .utf8)
        try resp.caCertPem.write(to: ManagedProfileStore.shared.mtlsCAURL, atomically: true, encoding: .utf8)
        try storeMTLSPrivateKey(priv.rawRepresentation, serial: resp.serialHex)
    }

    public func loadMTLSPrivateKey() throws -> P256.Signing.PrivateKey {
        let raw = try readMTLSPrivateKey()
        return try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    // MARK: - Sign-out

    public func destroyLocalState() {
        ManagedProfileStore.shared.destroy()
        InstallIdentityStore.destroy()
        deleteMTLSPrivateKey()
    }

    // MARK: - Private helpers

    private func parseISO(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
    }

    // MARK: - Keychain bits for the mTLS private key

    private static let mtlsService = "io.bromure.app.managed-mtls"
    private static let mtlsAccount = "leaf-private"

    private func storeMTLSPrivateKey(_ raw: Data, serial: String) throws {
        deleteMTLSPrivateKey()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: Self.mtlsAccount,
            kSecAttrLabel as String: "Bromure managed-profile mTLS key (serial \(serial))",
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw InstallIdentityError.keychainFailure(status, "store mtls leaf")
        }
    }

    private func readMTLSPrivateKey() throws -> Data {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: Self.mtlsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var r: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &r)
        guard s == errSecSuccess, let d = r as? Data else { throw InstallIdentityError.notFound }
        return d
    }

    private func deleteMTLSPrivateKey() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mtlsService,
            kSecAttrAccount as String: Self.mtlsAccount,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

private struct Host_compat {} // keep name-collision linter calm; see `Host.current()` below

// `Host.current().localizedName` is provided by Foundation's `Host` on macOS.
