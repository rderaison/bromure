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

/// Server-side acceptance state of this install, distinct from "is a
/// row on disk". The leaf cert and bearer token can both go stale while
/// the install.json still exists, and only the server can tell us:
///   - `.ok`            — last heartbeat succeeded, not revoked.
///   - `.tokenRejected` — the bearer token was refused (401/403): it
///                        expired or the install was reset. Renewal and
///                        managed uploads can't recover without a fresh
///                        enrollment code.
///   - `.revoked`       — the admin revoked this install server-side.
/// Persisted so the status UI can surface it on launch without waiting
/// for the first heartbeat.
public enum BACEnrollmentHealth: String, Codable, Sendable {
    case ok
    case tokenRejected
    case revoked
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

    /// Pointer to the keychain account holding the private key for
    /// `leaf.crt`. Updated atomically with the cert during rotation so
    /// readers always see a (cert, serial, key) triple from the same
    /// issuance.
    private static var leafSerialURL: URL {
        managedDir.appendingPathComponent("leaf.serial")
    }

    private static var healthURL: URL {
        managedDir.appendingPathComponent("health")
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
        try? FileManager.default.removeItem(at: leafSerialURL)
        try? FileManager.default.removeItem(at: healthURL)
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

    // MARK: - Server-acceptance health

    public static func storeHealth(_ h: BACEnrollmentHealth) {
        try? Data(h.rawValue.utf8).write(to: healthURL, options: .atomic)
    }

    /// Defaults to `.ok` when unwritten — a fresh enrollment is assumed
    /// good until a heartbeat says otherwise.
    public static func loadHealth() -> BACEnrollmentHealth {
        guard let data = try? Data(contentsOf: healthURL),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let h = BACEnrollmentHealth(rawValue: raw)
        else { return .ok }
        return h
    }

    // MARK: - mTLS leaf material
    //
    // Cert + CA stored as PEM files (no secrecy needed, cheap to inspect
    // if anything goes wrong); the private key lives in the Keychain
    // keyed by serial, so a key rotation can keep N versions until the
    // old cert expires. URLSession-side construction of a SecIdentity
    // happens in Phase 3b.

    public static func storeLeafCert(certPem: String, caPem: String, privateKeyDER: Data, serialHex: String) throws {
        let lower = serialHex.lowercased()
        try certPem.write(to: leafCertPemURL, atomically: true, encoding: .utf8)
        try caPem.write(to: caCertPemURL, atomically: true, encoding: .utf8)
        try storeKeychain(account: leafCertKeyPrefix + lower, data: privateKeyDER)
        // Serial pointer is written last so a partially-completed rotation
        // leaves the previous (cert, key) pair selectable rather than
        // pointing at material that doesn't exist yet.
        try lower.write(to: leafSerialURL, atomically: true, encoding: .utf8)
    }

    public static func loadLeafCertPem() -> String? {
        try? String(contentsOf: leafCertPemURL, encoding: .utf8)
    }

    public static func loadCAPem() -> String? {
        try? String(contentsOf: caCertPemURL, encoding: .utf8)
    }

    public static func loadLeafSerial() -> String? {
        guard let s = try? String(contentsOf: leafSerialURL, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// Where the BAC uploader POSTs event batches. Distinct from
    /// `defaultServerURL` because the analytics service is internet-facing
    /// with its own mTLS termination — bromure.io/api is HAProxy-fronted
    /// and not in a position to verify the install's leaf cert.
    public static var defaultAnalyticsURL: URL {
        if let env = ProcessInfo.processInfo.environment["BROMURE_AC_INGEST_URL"],
           let url = URL(string: env) { return url }
        if let s = UserDefaults.standard.string(forKey: "managed.acIngestURL"),
           let url = URL(string: s) { return url }
        return URL(string: "https://analytics.bromure.io/ac-ingest")!
    }

    /// Posted on the main actor whenever the enrollment state changes
    /// (enroll succeeded, or unenroll wiped state). UI observers refresh
    /// from `BACEnrollmentStore.load()`.
    public static var onStateChange: (@Sendable @MainActor () -> Void)?

    /// Posted when the server-acceptance health changes (revoked, token
    /// rejected, or recovered). The status panel subscribes to surface a
    /// re-enroll banner without polling.
    public static let healthDidChange =
        Notification.Name("io.bromure.ac.enrollmentHealthDidChange")

    /// The leaf is renewed when it's missing or within this window of
    /// expiry. Wide (3 days) so even a Mac that's only opened
    /// occasionally refreshes well before expiry; a long-absent install
    /// has an already-expired leaf, which is past the window, so the
    /// first heartbeat after launch renews it immediately. Renewal is
    /// bearer-authed, so an expired leaf is fine to replace.
    public static let leafRenewThreshold: TimeInterval = 72 * 60 * 60

    /// Persist + broadcast a health transition. No-op when unchanged so
    /// the UI isn't churned on every 10-minute heartbeat.
    private func recordHealth(_ h: BACEnrollmentHealth) {
        guard BACEnrollmentStore.loadHealth() != h else { return }
        BACEnrollmentStore.storeHealth(h)
        if h != .ok {
            FileHandle.standardError.write(Data(
                "[bac/enroll] enrollment health → \(h.rawValue)\n".utf8))
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.healthDidChange, object: nil)
        }
    }

    /// Map a client error to a health transition: a 401/403 means the
    /// bearer token is no longer accepted (expired / install reset), so
    /// neither renewal nor managed uploads can recover without a fresh
    /// enrollment. Other errors are transient (offline, 5xx) and leave
    /// health untouched so a blip doesn't nag the user to re-enroll.
    private func note(_ error: Error, context: String) {
        if case let ManagedProfileClientError.httpError(status, _) = error,
           status == 401 || status == 403 {
            recordHealth(.tokenRejected)
        }
        FileHandle.standardError.write(Data("[bac/\(context)] \(error)\n".utf8))
    }

    /// Expiry of the stored leaf cert, or nil when absent/unparseable.
    public func leafExpiry() -> Date? {
        guard let pem = BACEnrollmentStore.loadLeafCertPem(),
              let cert = try? Certificate(pemEncoded: pem)
        else { return nil }
        return cert.notValidAfter
    }

    /// Renew the leaf if it's missing or within `leafRenewThreshold` of
    /// expiry; no-op when it's still comfortably valid. Safe to call on
    /// every heartbeat tick — once a renewal succeeds the new expiry is
    /// ~weeks out, so the next tick takes the no-op path. Errors are
    /// swallowed (logged, and 401/403 flips health to `.tokenRejected`)
    /// so a failed renewal never tears down the heartbeat loop.
    public func renewLeafCertIfNeeded(now: Date = Date()) async {
        guard BACEnrollmentStore.load() != nil,
              BACEnrollmentStore.loadInstallToken() != nil else { return }
        if let expiry = leafExpiry(),
           expiry.timeIntervalSince(now) > Self.leafRenewThreshold {
            return
        }
        do {
            _ = try await fetchLeafCert()
        } catch {
            note(error, context: "renew")
        }
    }

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
        // Drop any cached SecIdentity so the next enrollment doesn't reuse
        // the previous leaf for an mTLS handshake.
        BACMTLSIdentity.purge()
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
        // New material → drop any cached SecIdentity so subsequent uploads
        // present the freshly-issued leaf.
        BACMTLSIdentity.purge()
        // A signed CSR proves the bearer token still works, so clear a
        // stale `.tokenRejected` (e.g. the user hit "Renew certificate"
        // after the server re-accepted them). Don't override `.revoked`.
        if BACEnrollmentStore.loadHealth() == .tokenRejected {
            recordHealth(.ok)
        }
        return resp.notAfter
    }

    /// Fire-and-forget heartbeat. Called from the periodic task; if it
    /// fails, swallow the error and let the next tick retry.
    public func heartbeat() async {
        guard let install = BACEnrollmentStore.load(),
              let token = BACEnrollmentStore.loadInstallToken() else { return }
        let client = ManagedProfileClient(serverURL: install.serverURL)
        do {
            let resp = try await client.heartbeat(installId: install.installId, bearer: token)
            // The server is the authority on acceptance: `revoked` means
            // an admin killed this install; a clean response clears any
            // prior bad state (e.g. the token was reset and re-accepted).
            recordHealth(resp.revoked ? .revoked : .ok)
        } catch {
            note(error, context: "heartbeat")
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
            // for the first interval to elapse. The leaf-renewal check
            // rides along: doing it on launch means an install that's
            // been closed past its cert's expiry heals on the next open
            // rather than silently failing managed uploads forever.
            await BACEnrollment.shared.heartbeat()
            await BACEnrollment.shared.renewLeafCertIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await BACEnrollment.shared.heartbeat()
                await BACEnrollment.shared.renewLeafCertIfNeeded()
                _ = self
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

/// Per-install egress-IP heartbeat. Bromure Web has an equivalent
/// shipped as a Chromium MV3 extension that pings every minute from
/// inside the browser session (so the recorded IP reflects whatever
/// VPN / proxy the user routed Chromium through). AC runs the host
/// itself behind the same network policies the Mac is on, so the host
/// process pings directly — same endpoint, same mTLS auth, same
/// `install_ips` table on the server.
///
/// Mirrors `BACHeartbeat`'s lifecycle: started once when the app
/// launches enrolled, restarted on (un)enroll. mTLS handshake fails
/// silently when not enrolled (no install identity in the keychain).
@MainActor
public final class BACIPRegister {
    private var task: Task<Void, Never>?
    public static let shared = BACIPRegister()
    private init() {}

    private static let pingIntervalSec: UInt64 = 60
    /// `analytics.bromure.io/register-ip` by default. Overridable via
    /// the same env / UserDefaults knob that controls `/ac-ingest`.
    public static var endpoint: URL {
        if let env = ProcessInfo.processInfo.environment["BROMURE_AC_REGISTER_IP_URL"],
           let url = URL(string: env) { return url }
        if let s = UserDefaults.standard.string(forKey: "managed.acRegisterIPURL"),
           let url = URL(string: s) { return url }
        // Sibling of `defaultAnalyticsURL`'s `/ac-ingest` — same host,
        // different path. Hard-code the swap so a custom analytics
        // URL still gets the right register-ip endpoint by default.
        let ingest = BACEnrollment.defaultAnalyticsURL
        if let comps = URLComponents(url: ingest, resolvingAgainstBaseURL: false) {
            var c = comps
            c.path = "/register-ip"
            if let url = c.url { return url }
        }
        return URL(string: "https://analytics.bromure.io/register-ip")!
    }

    public func start() {
        if task != nil { return }
        task = Task { [weak self] in
            // Fire one immediately so `install_ips` records the IP
            // within seconds of a fresh enrollment, then settle into
            // the periodic cadence.
            await Self.ping()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalSec * 1_000_000_000)
                if Task.isCancelled { break }
                await Self.ping()
                _ = self
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One-shot ping. Public so tests / debug menu items can trigger
    /// it on demand; production fires it from the periodic loop.
    public static func ping() async {
        // Hard gate: no install identity → no mTLS to authenticate
        // with, the request would just be rejected. Skip silently so
        // unenrolled installs don't spam the analytics edge.
        guard BACEnrollmentStore.load() != nil,
              BACEnrollmentStore.loadInstallToken() != nil else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"schemaVersion\":1}".utf8)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let delegate = BACMTLSDelegate()
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                FileHandle.standardError.write(Data(
                    "[bac/register-ip] HTTP \(http.statusCode)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[bac/register-ip] \(error)\n".utf8))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
