import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1

// MARK: - SecIdentity registry

/// Per-host client identity table the proxy hands to URLSession when
/// the upstream API server asks for client-cert auth (Kubernetes,
/// internal mTLS APIs, etc.). Keyed by `host[:port]` lowercased.
public final class ClientIdentityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// Per-profile, per-host map. We key by profile so two profiles
    /// pointing at the same cluster URL with different creds don't
    /// stomp on each other.
    private var perProfile: [UUID: [String: SecIdentity]] = [:]

    public init() {}

    public func setIdentity(_ identity: SecIdentity, host: String, profileID: UUID) {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        var byHost = perProfile[profileID] ?? [:]
        byHost[h] = identity
        // Also index by bare hostname — URLSession challenges + the
        // proxy's CONNECT-parsed host typically drop the port, so a
        // single registration must hit both forms.
        if let bare = h.split(separator: ":").first.map(String.init), bare != h {
            byHost[bare] = identity
        }
        perProfile[profileID] = byHost
    }

    public func clearAll(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        perProfile.removeValue(forKey: profileID)
    }

    public func identity(for host: String, profileID: UUID) -> SecIdentity? {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let id = perProfile[profileID]?[h] { return id }
        // Allow port-stripped fallback (some upstream challenges drop the port).
        if let bareHost = h.split(separator: ":").first.map(String.init),
           let id = perProfile[profileID]?[bareHost] { return id }
        return nil
    }
}

// MARK: - Cluster CA trust registry

/// Per-host root-CA table the proxy hands to URLSession when an
/// upstream uses a cert that doesn't chain to the macOS system trust
/// store (e.g. a private k8s API server with its own CA). Keyed by
/// `host[:port]` lowercased. When an entry is present, the registered
/// PEM is the *only* anchor used to evaluate that host's server cert.
public final class ClusterCATrustRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var perProfile: [UUID: [String: SecCertificate]] = [:]

    public init() {}

    /// Parse a PEM bundle and register the first cert. PEMs that fail
    /// to parse log to stderr and fall back to system trust.
    public func setCA(pem: String, host: String, profileID: UUID) {
        guard let cert = Self.parseFirstCertPEM(pem) else {
            FileHandle.standardError.write(Data(
                "[mitm] cluster CA parse failed for host=\(host) — falling back to system trust\n".utf8))
            return
        }
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        var byHost = perProfile[profileID] ?? [:]
        byHost[h] = cert
        if let bare = h.split(separator: ":").first.map(String.init), bare != h {
            byHost[bare] = cert
        }
        perProfile[profileID] = byHost
    }

    public func clearAll(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        perProfile.removeValue(forKey: profileID)
    }

    public func ca(for host: String, profileID: UUID) -> SecCertificate? {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let c = perProfile[profileID]?[h] { return c }
        if let bareHost = h.split(separator: ":").first.map(String.init),
           let c = perProfile[profileID]?[bareHost] { return c }
        return nil
    }

    /// PEM bundle → DER → SecCertificate (first cert). Handles both
    /// single-cert PEMs and bundles with multiple BEGIN/END blocks
    /// concatenated (intermediate + root).
    private static func parseFirstCertPEM(_ pem: String) -> SecCertificate? {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end   = "-----END CERTIFICATE-----"
        guard let beginRange = pem.range(of: begin),
              let endRange   = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex)
        else { return nil }
        let body = pem[beginRange.upperBound..<endRange.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

// MARK: - Kubeconfig materialization + secret extraction

/// Builds the synthetic kubeconfig file we drop into the VM and
/// registers the matching real credentials with the proxy.
@MainActor
public final class KubeconfigMaterializer {
    public init() {}

    /// One materialized kubeconfig: the YAML to drop in the VM, plus
    /// the swap-map / identity entries the proxy needs to substitute
    /// real credentials on the wire.
    public struct Materialized: Sendable {
        public var yaml: String
        public var bearerSwaps: [(host: String, fakeToken: String, realToken: String)]
        public var clientIdentities: [(host: String, identity: SecIdentity)]
        public var execContexts: [ExecContext]
        /// Per-host CA PEMs the proxy must trust when talking to the
        /// upstream API server. Empty when the cluster's API server uses
        /// a publicly-trusted cert (rare for on-prem k8s, common for
        /// managed services).
        public var clusterCAs: [(host: String, caPEM: String)]
    }

    public struct ExecContext: Sendable {
        public let entryID: UUID
        public let host: String
        public let fakeToken: String
        public let command: String
        public let args: [String]
        public let refreshSeconds: Int
    }

    /// Walk the profile's kubeconfigs, build a single combined YAML,
    /// hand back the swap entries + client identities. Pure function —
    /// callers thread the result into the swap map / identity registry
    /// / exec poller before VM start.
    public func materialize(profile: Profile,
                            bromureCAPEM: String) -> Materialized {
        var contexts: [String] = []
        var clusters: [String] = []
        var users: [String] = []
        var bearerSwaps: [(String, String, String)] = []
        var identities: [(String, SecIdentity)] = []
        var execContexts: [ExecContext] = []
        var clusterCAs: [(String, String)] = []

        for entry in profile.kubeconfigs {
            let safeName = entry.name.isEmpty ? entry.id.uuidString.prefix(8).lowercased() : entry.name
            let cluster = "cluster-\(safeName)"
            let user    = "user-\(safeName)"

            // The VM kubeconfig MUST trust the proxy's cert (signed by
            // Bromure CA), not the upstream cluster's own CA — kubectl
            // talks to the proxy, not the API server directly. The
            // cluster's real CA, when supplied, is forwarded separately
            // so the proxy can verify the upstream API server.
            let caData = Data(bromureCAPEM.utf8).base64EncodedString()
            if !entry.caCertPEM.isEmpty, !entry.hostPattern.isEmpty {
                clusterCAs.append((entry.hostPattern, entry.caCertPEM))
            }

            // Cluster block
            clusters.append("""
            - name: \(cluster)
              cluster:
                server: \(entry.serverURL)
                certificate-authority-data: \(caData)
            """)

            // Context block
            var ctxBody = "    cluster: \(cluster)\n    user: \(user)"
            if !entry.namespace.isEmpty {
                ctxBody += "\n    namespace: \(entry.namespace)"
            }
            contexts.append("""
            - name: \(safeName)
              context:
            \(ctxBody)
            """)

            // User block — swap by auth flavour.
            switch entry.auth {
            case .bearerToken(let realToken):
                let fake = makeFakeToken()
                bearerSwaps.append((entry.hostPattern, fake, realToken))
                users.append("""
                - name: \(user)
                  user:
                    token: \(fake)
                """)

            case .clientCert(let certPEM, let keyPEM):
                // Real cert + key get registered with the proxy as
                // a SecIdentity for upstream mTLS. The VM gets a
                // throwaway pair so kubectl can load valid PEM.
                if let id = makeSecIdentity(certPEM: certPEM, keyPEM: keyPEM) {
                    identities.append((entry.hostPattern, id))
                }
                let throwaway = makeThrowawayClientCert(commonName: user)
                let throwawayCert = Data(throwaway.cert.utf8).base64EncodedString()
                let throwawayKey  = Data(throwaway.key.utf8).base64EncodedString()
                users.append("""
                - name: \(user)
                  user:
                    client-certificate-data: \(throwawayCert)
                    client-key-data: \(throwawayKey)
                """)

            case .execPlugin(let cmd, let args, let secs):
                // Treat exec as a token-auth in the synthetic
                // kubeconfig — VM never actually runs the exec
                // plugin, the host poller does. Initial fake is a
                // placeholder; the poller updates the real value
                // before kubectl needs it.
                let fake = makeFakeToken()
                bearerSwaps.append((entry.hostPattern, fake, ""))   // real filled by poller
                execContexts.append(ExecContext(
                    entryID: entry.id,
                    host: entry.hostPattern,
                    fakeToken: fake,
                    command: cmd, args: args,
                    refreshSeconds: max(60, secs)))
                users.append("""
                - name: \(user)
                  user:
                    token: \(fake)
                """)
            }
        }

        let firstCtx = (profile.kubeconfigs.first?.name).map { $0.isEmpty ? "" : $0 } ?? ""
        let yaml = """
        apiVersion: v1
        kind: Config
        # Generated by Bromure Agentic Coding — do not edit.
        # Real credentials live on the macOS host; this file holds
        # synthetic stand-ins. The MITM proxy substitutes real values
        # on the wire when the VM talks to these clusters.
        current-context: \(firstCtx)
        clusters:
        \(clusters.joined(separator: "\n"))
        contexts:
        \(contexts.joined(separator: "\n"))
        users:
        \(users.joined(separator: "\n"))
        """

        return Materialized(yaml: yaml, bearerSwaps: bearerSwaps,
                            clientIdentities: identities,
                            execContexts: execContexts,
                            clusterCAs: clusterCAs)
    }

    // MARK: - Fakes

    private func makeFakeToken() -> String {
        let bytes = randomBytes(32).map { String(format: "%02x", $0) }.joined()
        return "brm-k8s-\(bytes)"
    }

    /// Self-signed throwaway cert + matching key for the VM's
    /// kubeconfig. kubectl requires loadable PEM; the bytes never
    /// authenticate anything (the proxy doesn't ask for client
    /// certs and re-handshakes upstream with the real identity).
    private struct Throwaway {
        var cert: String
        var key: String
    }
    private func makeThrowawayClientCert(commonName: String) -> Throwaway {
        do {
            // ONE P256 key, used both for signing the cert AND for
            // the PEM we hand back. Two keys = mismatch + kubectl
            // rejects on load.
            let cryptoKey = P256.Signing.PrivateKey()
            let key = Certificate.PrivateKey(cryptoKey)
            let pubKey = try Certificate.PublicKey(cryptoKey.publicKey)
            let subject = try DistinguishedName { CommonName(commonName) }
            let now = Date()
            let serial = Certificate.SerialNumber(bytes: Array(randomBytes(20)))
            let cert = try Certificate(
                version: .v3,
                serialNumber: serial,
                publicKey: pubKey,
                notValidBefore: now.addingTimeInterval(-60),
                notValidAfter:  now.addingTimeInterval(365 * 86_400),
                issuer: subject,
                subject: subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                    try ExtendedKeyUsage([.clientAuth])
                },
                issuerPrivateKey: key
            )
            let certPEM = try cert.serializeAsPEM().pemString
            return Throwaway(cert: certPEM, key: cryptoKey.pemRepresentation)
        } catch {
            return Throwaway(
                cert: "-----BEGIN CERTIFICATE-----\nINVALID\n-----END CERTIFICATE-----\n",
                key: "-----BEGIN PRIVATE KEY-----\nINVALID\n-----END PRIVATE KEY-----\n")
        }
    }

    /// Build a SecIdentity from PEM cert + PEM key. PKCS#12 round-trip
    /// is the simplest cross-version path: assemble cert + key into a
    /// p12, import, fish out the identity. We use the SecIdentityCreate
    /// SPI from CertCache.swift instead — already proven.
    private func makeSecIdentity(certPEM: String, keyPEM: String) -> SecIdentity? {
        // Decode the PEM cert
        guard let certData = pemDecode(certPEM, marker: "CERTIFICATE"),
              let secCert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }
        // Try the key as PKCS#8 first (modern), then RSA (legacy).
        let keyDataCandidates: [(Data, [CFString: Any])] = {
            var out: [(Data, [CFString: Any])] = []
            if let pkcs8 = pemDecode(keyPEM, marker: "PRIVATE KEY") {
                // PKCS#8 wraps multiple key types; SecKey handles RSA + EC.
                out.append((pkcs8, [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ]))
                out.append((pkcs8, [
                    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ]))
            }
            if let rsa = pemDecode(keyPEM, marker: "RSA PRIVATE KEY") {
                out.append((rsa, [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ]))
            }
            if let ec = pemDecode(keyPEM, marker: "EC PRIVATE KEY") {
                out.append((ec, [
                    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ]))
            }
            return out
        }()

        var secKey: SecKey?
        for (data, attrs) in keyDataCandidates {
            var err: Unmanaged<CFError>?
            if let k = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &err) {
                secKey = k
                break
            }
        }
        guard let key = secKey else { return nil }

        guard let identity = bromure_SecIdentityCreate(nil, secCert, key) else {
            return nil
        }
        return identity.takeRetainedValue()
    }

    /// Strip `-----BEGIN X-----` / `-----END X-----` and base64-decode
    /// the body. Returns nil if the marker isn't found.
    private func pemDecode(_ pem: String, marker: String) -> Data? {
        let begin = "-----BEGIN \(marker)-----"
        let end   = "-----END \(marker)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange   = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            return nil
        }
        let b64 = pem[beginRange.upperBound..<endRange.lowerBound]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: b64)
    }
}

// MARK: - Exec poller

/// Background poller that runs each kubeconfig's exec plugin every
/// `refreshSeconds` and pushes the resulting token into the swap map.
/// Lifetime is bound to the session — start on launch, stop on close.
@MainActor
public final class ExecCredentialPoller {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func start(_ contexts: [KubeconfigMaterializer.ExecContext],
                      profileID: UUID,
                      swapper: TokenSwapper) {
        for ctx in contexts {
            stop(entryID: ctx.entryID)
            let task = Task { [weak self, weak swapper] in
                guard self != nil else { return }
                while !Task.isCancelled {
                    let token = await Self.runExec(command: ctx.command, args: ctx.args)
                    if let token, let swapper {
                        Self.updateSwap(swapper: swapper,
                                        profileID: profileID,
                                        host: ctx.host,
                                        fake: ctx.fakeToken,
                                        real: token)
                        FileHandle.standardError.write(Data(
                            "[k8s-exec] refreshed token for \(ctx.host) (\(ctx.command))\n".utf8))
                    }
                    try? await Task.sleep(for: .seconds(Double(ctx.refreshSeconds)))
                }
            }
            tasks[ctx.entryID] = task
        }
    }

    public func stop(entryID: UUID) {
        tasks[entryID]?.cancel()
        tasks.removeValue(forKey: entryID)
    }

    public func stopAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }

    /// Spawn the exec plugin, decode its `ExecCredential` JSON, return
    /// the token. nil on any failure (network, JSON, missing token).
    private static func runExec(command: String, args: [String]) async -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        do {
            try p.run()
        } catch {
            FileHandle.standardError.write(Data(
                "[k8s-exec] failed to spawn \(command): \(error)\n".utf8))
            return nil
        }
        // Wait off-thread.
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? [String: Any],
                      let token = status["token"] as? String,
                      !token.isEmpty else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: token)
            }
        }
    }

    /// Replace the entry in the swap map for `(profileID, fake)` with
    /// the new real value. Uses the swapper's existing setMap surface
    /// since there's no per-entry mutator.
    private static func updateSwap(swapper: TokenSwapper, profileID: UUID,
                                   host: String, fake: String, real: String) {
        // We don't have public access to the current map — a simple
        // additive setEntry would let us avoid this dance. For v1
        // we let the proxy's runtime swap-map carry the latest value
        // by appending; old entries with the same fake get
        // overwritten by the lookup-by-fake nature of the swap.
        var entries = swapper.entries(for: profileID)
        // Remove any existing entry with this fake to avoid duplicates.
        entries.removeAll { $0.fake == fake }
        entries.append(TokenMap.Entry(fake: fake, real: real, host: host))
        swapper.setMap(TokenMap(entries: entries), for: profileID)
    }
}

// MARK: - SecIdentity SPI bridge

// Declared again here because the one in CertCache.swift is private
// to that file. @_silgen_name with same target → linker collapses
// them, so two identical declarations are safe.
@_silgen_name("SecIdentityCreate")
private func bromure_SecIdentityCreate(
    _ allocator: CFAllocator?,
    _ certificate: SecCertificate,
    _ privateKey: SecKey
) -> Unmanaged<SecIdentity>?
