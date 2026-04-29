import Foundation
import CryptoKit
import _CryptoExtras
import SandboxEngine
import Security
import X509
import SwiftASN1

// Enrollment + leaf-cert + bearer-token storage for Bromure Agentic
// Coding. Mirrors `SandboxEngine/InstallIdentity.swift` but with a
// keychain service + on-disk path scoped to BAC's bundle, so Web's
// enrollment list (and vice versa) doesn't leak into the wrong app.
//
// Phase 3a delivers what's testable end-to-end without parser/uploader
// work: an admin mints an `app: agentic-coding` code on the user
// detail page, the user pastes it into BAC's enrollment sheet, and the
// new install row appears at /agentic-coding/installs.

public struct BACInstall: Codable, Equatable, Identifiable {
    public let installId: String
    public let orgSlug: String
    public let userId: String
    public let userEmail: String
    public let serverURL: URL
    public let enrolledAt: Date
    public var deviceName: String

    public var id: String { installId }
}

public enum BACEnrollmentError: Error, LocalizedError {
    case keychainFailure(OSStatus, String)
    case alreadyEnrolled
    case wrongApp(String)
    case notEnrolled

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status, let context):
            return "Keychain failure (\(status)) during \(context)"
        case .alreadyEnrolled:
            return "Bromure Agentic Coding is already enrolled."
        case .wrongApp(let got):
            return "Code was issued for app '\(got)', expected 'agentic-coding'."
        case .notEnrolled:
            return "Not enrolled with bromure.io yet."
        }
    }
}

/// One-instance store keyed off BAC's bundle. Static-only API mirrors
/// `InstallIdentityStore` so the call sites read similarly.
public enum BACEnrollmentStore {
    // Distinct from Bromure Web's "io.bromure.app.managed-install" so
    // each app has its own bearer + leaf-cert key material.
    private static let keychainService = "io.bromure.agentic-coding.managed-install"
    private static let installTokenKey = "install-token"
    private static let leafCertKeyPrefix = "leaf-cert-key-"

    /// Path: ~/Library/Application Support/BromureAC/managed/install.json
    private static var managedDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("managed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var installJSONURL: URL {
        managedDir.appendingPathComponent("install.json")
    }

    private static var leafCertPemURL: URL {
        managedDir.appendingPathComponent("leaf.crt")
    }

    private static var caCertPemURL: URL {
        managedDir.appendingPathComponent("ca.crt")
    }

    // MARK: - Install identity

    public static func load() -> BACInstall? {
        guard let data = try? Data(contentsOf: installJSONURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BACInstall.self, from: data)
    }

    public static func save(_ install: BACInstall) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(install)
        try data.write(to: installJSONURL, options: .atomic)
    }

    /// Wipe everything: install metadata, install bearer token, leaf
    /// cert + key, CA cert. The next launch comes back to the
    /// "not enrolled" state.
    public static func destroy() {
        try? FileManager.default.removeItem(at: installJSONURL)
        try? FileManager.default.removeItem(at: leafCertPemURL)
        try? FileManager.default.removeItem(at: caCertPemURL)
        deleteKeychain(account: installTokenKey)
        // Leaf cert keys are stored per-serial so we walk known accounts.
        // (Cheap — there's at most a handful as cert renewal turns over.)
        let keys = (try? FileManager.default
            .contentsOfDirectory(atPath: managedDir.path)) ?? []
        for k in keys where k.hasPrefix("leaf-cert-key-") {
            try? FileManager.default.removeItem(at: managedDir.appendingPathComponent(k))
        }
    }

    // MARK: - Bearer token

    public static func storeInstallToken(_ token: String) throws {
        try storeKeychain(account: installTokenKey, data: Data(token.utf8))
    }

    public static func loadInstallToken() -> String? {
        guard let data = readKeychain(account: installTokenKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - mTLS leaf material
    //
    // Cert + CA stored as PEM files (no secrecy needed, cheap to inspect
    // if anything goes wrong); the private key lives in the Keychain
    // keyed by serial, so a key rotation can keep N versions until the
    // old cert expires. URLSession-side construction of a SecIdentity
    // happens in Phase 3b.

    public static func storeLeafCert(certPem: String, caPem: String, privateKeyDER: Data, serialHex: String) throws {
        try certPem.write(to: leafCertPemURL, atomically: true, encoding: .utf8)
        try caPem.write(to: caCertPemURL, atomically: true, encoding: .utf8)
        try storeKeychain(account: leafCertKeyPrefix + serialHex.lowercased(), data: privateKeyDER)
    }

    public static func loadLeafCertPem() -> String? {
        try? String(contentsOf: leafCertPemURL, encoding: .utf8)
    }

    public static func loadCAPem() -> String? {
        try? String(contentsOf: caCertPemURL, encoding: .utf8)
    }

    public static func loadLeafPrivateKey(serialHex: String) -> Data? {
        readKeychain(account: leafCertKeyPrefix + serialHex.lowercased())
    }

    // MARK: - Keychain helpers

    private static func storeKeychain(account: String, data: Data) throws {
        deleteKeychain(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BACEnrollmentError.keychainFailure(status, "store \(account)")
        }
    }

    private static func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// High-level orchestrator: redeem a code → store install + bearer →
/// generate CSR → fetch leaf cert from the org CA → store cert + key.
/// One method per public flow, all `throws` for the SwiftUI sheet to
/// surface as a localized error.
public final class BACEnrollment {
    public static let shared = BACEnrollment()
    private init() {}

    public static var defaultServerURL: URL {
        if let env = ProcessInfo.processInfo.environment["BROMURE_MANAGED_URL"],
           let url = URL(string: env) { return url }
        if let s = UserDefaults.standard.string(forKey: "managed.serverURL"),
           let url = URL(string: s) { return url }
        return URL(string: "https://bromure.io/api")!
    }

    /// Posted on the main actor whenever the enrollment state changes
    /// (enroll succeeded, or unenroll wiped state). UI observers refresh
    /// from `BACEnrollmentStore.load()`.
    public static var onStateChange: (@Sendable @MainActor () -> Void)?

    @discardableResult
    public func enroll(
        code: String,
        serverURL: URL? = nil,
        deviceName: String? = nil,
    ) async throws -> BACInstall {
        if BACEnrollmentStore.load() != nil {
            throw BACEnrollmentError.alreadyEnrolled
        }
        let url = serverURL ?? Self.defaultServerURL
        let device = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Host.current().localizedName ?? "unnamed"
        let x25519 = Curve25519.KeyAgreement.PrivateKey()
        // BAC doesn't currently use the X25519 key for sealed-box
        // delivery (no profile bundles flow this direction), but the
        // server requires `installPubkey` and stamps it on the install
        // row — keep the symmetry with Bromure Web rather than padding
        // with zeros.

        let client = ManagedProfileClient(serverURL: url)
        let resp = try await client.enroll(
            code: code,
            installPubkeyHex: x25519.publicKeyHex,
            deviceName: device,
            app: "agentic-coding",
        )
        if let app = resp.app, app != "agentic-coding" {
            throw BACEnrollmentError.wrongApp(app)
        }
        let install = BACInstall(
            installId: resp.installId,
            orgSlug: resp.orgSlug,
            userId: resp.userId,
            userEmail: resp.userEmail,
            serverURL: url,
            enrolledAt: Date(),
            deviceName: device,
        )
        try BACEnrollmentStore.storeInstallToken(resp.installToken)
        try BACEnrollmentStore.save(install)

        // Cert request is best-effort during the enrollment flow: even
        // if the org CA isn't configured yet, the install is real and
        // visible to the admin. The first heartbeat will retry.
        do {
            try await fetchLeafCert(install: install)
        } catch {
            FileHandle.standardError.write(Data(
                "[bac/enroll] cert request deferred: \(error)\n".utf8))
        }

        await MainActor.run { Self.onStateChange?() }
        return install
    }

    public func unenroll() async {
        BACEnrollmentStore.destroy()
        await MainActor.run { Self.onStateChange?() }
    }

    /// Issue a leaf cert from the org CA. `profileId` is intentionally
    /// nil — the server falls back to org_ca when no profileId is
    /// supplied, which is the path AC always uses.
    @discardableResult
    public func fetchLeafCert(install: BACInstall? = nil) async throws -> Date {
        guard let install = install ?? BACEnrollmentStore.load(),
              let token = BACEnrollmentStore.loadInstallToken() else {
            throw BACEnrollmentError.notEnrolled
        }
        let priv = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let privKey = Certificate.PrivateKey(priv)
        let subject = try DistinguishedName {
            CommonName("bromure-install-\(install.installId)")
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

        let client = ManagedProfileClient(serverURL: install.serverURL)
        let resp = try await client.signCSR(
            installId: install.installId, bearer: token,
            profileId: nil, csrPem: csrPem,
        )
        try BACEnrollmentStore.storeLeafCert(
            certPem: resp.certPem,
            caPem: resp.caCertPem,
            privateKeyDER: priv.derRepresentation,
            serialHex: resp.serialHex,
        )
        return resp.notAfter
    }

    /// Fire-and-forget heartbeat. Called from the periodic task; if it
    /// fails, swallow the error and let the next tick retry.
    public func heartbeat() async {
        guard let install = BACEnrollmentStore.load(),
              let token = BACEnrollmentStore.loadInstallToken() else { return }
        let client = ManagedProfileClient(serverURL: install.serverURL)
        do {
            _ = try await client.heartbeat(installId: install.installId, bearer: token)
        } catch {
            FileHandle.standardError.write(Data(
                "[bac/heartbeat] \(error)\n".utf8))
        }
    }
}

/// Background task that pings `/heartbeat` periodically while the app
/// is running. Single instance owned by the app delegate so the task
/// is cancelled on quit.
@MainActor
public final class BACHeartbeat {
    private var task: Task<Void, Never>?
    public static let shared = BACHeartbeat()
    private init() {}

    public func start() {
        if task != nil { return }
        task = Task { [weak self] in
            // Initial ping right away — surfaces last_seen_at to the admin
            // UI within seconds of a fresh enrollment instead of waiting
            // for the first interval to elapse.
            await BACEnrollment.shared.heartbeat()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await BACEnrollment.shared.heartbeat()
                // Phase 3b will piggy-back: if the leaf cert is within
                // some threshold of expiry, attempt fetchLeafCert here.
                _ = self
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
