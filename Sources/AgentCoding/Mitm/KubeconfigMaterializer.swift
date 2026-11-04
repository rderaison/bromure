import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1

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
        public var bearerSwaps: [BearerSwap]
        public var clientIdentities: [ClientIdentitySpec]
        public var execContexts: [ExecContext]
        /// Per-host CA PEMs the proxy must trust when talking to the
        /// upstream API server. Empty when the cluster's API server uses
        /// a publicly-trusted cert (rare for on-prem k8s, common for
        /// managed services).
        public var clusterCAs: [(host: String, caPEM: String)]
    }

    /// An imported kubeconfig's client certificate, as the proxy needs it
    /// for upstream mTLS: the PEM material, made into the host's own
    /// identity object where it's applied (macOS: a SecIdentity, in
    /// MitmEngine.applyKubeMaterial). Held only as long as the
    /// materialization; never Codable, never printed (the key is redacted
    /// from every description).
    public struct ClientIdentitySpec: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                                      CustomReflectable {
        public let host: String
        public let certPEM: String
        public let keyPEM: String
        public let consentCredentialID: String?
        public let consentDisplayName: String?

        public var description: String { "ClientIdentitySpec(host: \(host), key: <redacted>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["host": host]) }
    }

    public struct BearerSwap: Sendable {
        public let host: String
        public let fakeToken: String
        public let realToken: String
        /// `ConsentBroker` ID when the source kubeconfig entry is
        /// flagged for approval; nil = no gate.
        public let consentCredentialID: String?
        public let consentDisplayName: String?
    }

    public struct ExecContext: Sendable, Equatable {
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
    ///
    /// `reusingExec`: the exec contexts in force (a live refresh). An exec
    /// entry whose plugin, arguments and host are unchanged keeps its fake,
    /// so the guest's kubeconfig keeps naming the token the poller already
    /// resolved rather than a new one with nothing behind it yet.
    public func materialize(profile: Profile,
                            bromureCAPEM: String,
                            directClusters: [KubeDirectCluster] = [],
                            reusingExec: [ExecContext] = []) -> Materialized {
        var contexts: [String] = []
        var clusters: [String] = []
        var users: [String] = []
        var bearerSwaps: [BearerSwap] = []
        var identities: [ClientIdentitySpec] = []
        var execContexts: [ExecContext] = []
        var clusterCAs: [(String, String)] = []

        // Bromure-run clusters (sibling node VMs on the VM LAN): real CA +
        // admin cert, reached directly — the switch never intercepts
        // on-subnet traffic, so nothing here is proxied or swapped.
        for direct in directClusters {
            let ctx = direct.contextName
            clusters.append("""
            - name: \(ctx)
              cluster:
                server: \(direct.serverURL)
                certificate-authority-data: \(direct.caData)
            """)
            contexts.append("""
            - name: \(ctx)
              context:
                cluster: \(ctx)
                user: \(ctx)-admin
            """)
            users.append("""
            - name: \(ctx)-admin
              user:
                client-certificate-data: \(direct.clientCertData)
                client-key-data: \(direct.clientKeyData)
            """)
        }

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

            let consentID: String? = entry.requireApproval
                ? ConsentCredentialID.kubeconfig(entry.id) : nil
            let consentDisplay = entry.name.isEmpty
                ? "kubeconfig context" : "kubeconfig “\(entry.name)”"

            // User block — swap by auth flavour.
            switch entry.auth {
            case .bearerToken(let realToken):
                let fake = makeFakeToken()
                bearerSwaps.append(BearerSwap(
                    host: entry.tokenScope,
                    fakeToken: fake, realToken: realToken,
                    consentCredentialID: consentID,
                    consentDisplayName: consentDisplay))
                users.append("""
                - name: \(user)
                  user:
                    token: \(fake)
                """)

            case .clientCert(let certPEM, let keyPEM):
                // Real cert + key get registered with the proxy as
                // a SecIdentity for upstream mTLS. The VM gets a
                // throwaway pair so kubectl can load valid PEM.
                identities.append(ClientIdentitySpec(
                    host: entry.hostPattern,
                    certPEM: certPEM, keyPEM: keyPEM,
                    consentCredentialID: consentID,
                    consentDisplayName: consentDisplay))
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
                let fake = reusingExec.first {
                    $0.entryID == entry.id && $0.host == entry.tokenScope && $0.command == cmd && $0.args == args
                }?.fakeToken ?? makeFakeToken()
                bearerSwaps.append(BearerSwap(
                    host: entry.tokenScope,
                    fakeToken: fake, realToken: "",
                    consentCredentialID: consentID,
                    consentDisplayName: consentDisplay))
                execContexts.append(ExecContext(
                    entryID: entry.id,
                    host: entry.tokenScope,
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

        // Imported contexts keep the current-context slot they always had; a
        // bromure cluster takes it only when nothing was imported.
        let firstCtx = (profile.kubeconfigs.first?.name).map { $0.isEmpty ? "" : $0 }
            ?? directClusters.first?.contextName ?? ""
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
            let pubKey = Certificate.PublicKey(cryptoKey.publicKey)
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

}

// MARK: - Exec poller

/// Background poller that runs each kubeconfig's exec plugin every
/// `refreshSeconds` and pushes the resulting token into the swap map.
/// Lifetime is bound to the session — start on launch, stop on close.
@MainActor
public final class ExecCredentialPoller {
    /// One task per workspace and kubeconfig entry. Keyed by the entry
    /// alone, a workspace's live refresh cancelled and took over another
    /// workspace's poller for an entry with the same id (a duplicated
    /// workspace's), whose token then froze until it expired (Finding
    /// CWE-362, "A live kubeconfig refresh cancels another workspace's
    /// exec poller when entry ids match").
    private struct Key: Hashable { let profileID: UUID; let entryID: UUID }
    /// A poller: its context, its generation, its task. Only the current
    /// generation writes a token: a run whose plugin outlived its poller
    /// (stopped or replaced while it ran) wrote its older token over the
    /// newer one on the same reused fake (Finding CWE-362, "A cancelled kube
    /// exec poll writes an older token onto the reused fake").
    private struct Running { let ctx: KubeconfigMaterializer.ExecContext; let generation: Int; let task: Task<Void, Never> }
    private let lock = NSLock()
    private var tasks: [Key: Running] = [:]
    private var generation = 0

    public init() {}

    /// Make `profileID`'s pollers `contexts`: one whose context is unchanged
    /// keeps running (a live push no longer overlaps two runs of its
    /// plugin), a changed one restarts, one no longer listed stops.
    public func sync(_ contexts: [KubeconfigMaterializer.ExecContext],
                     profileID: UUID,
                     swapper: TokenSwapper) {
        let keep = Set(contexts.map(\.entryID))
        lock.lock()
        for key in tasks.keys where key.profileID == profileID && !keep.contains(key.entryID) {
            tasks.removeValue(forKey: key)?.task.cancel()
        }
        lock.unlock()
        start(contexts, profileID: profileID, swapper: swapper)
    }

    public func start(_ contexts: [KubeconfigMaterializer.ExecContext],
                      profileID: UUID,
                      swapper: TokenSwapper) {
        lock.lock(); defer { lock.unlock() }
        for ctx in contexts {
            let key = Key(profileID: profileID, entryID: ctx.entryID)
            if let running = tasks[key], running.ctx == ctx { continue }
            tasks[key]?.task.cancel()
            generation += 1
            let gen = generation
            let task = Task { [weak self, weak swapper] in
                guard self != nil else { return }
                while !Task.isCancelled {
                    let token = await Self.runExec(command: ctx.command, args: ctx.args)
                    if let token, let swapper, let self {
                        // Checked and written under one lock: a run that
                        // outlived its poller writes nothing.
                        self.ifCurrent(key, gen) {
                            Self.updateSwap(swapper: swapper,
                                            profileID: profileID,
                                            host: ctx.host,
                                            fake: ctx.fakeToken,
                                            real: token)
                            FileHandle.standardError.write(Data(
                                "[k8s-exec] refreshed token for \(ctx.host) (\(ctx.command))\n".utf8))
                        }
                    }
                    try? await Task.sleep(for: .seconds(Double(ctx.refreshSeconds)))
                }
            }
            tasks[key] = Running(ctx: ctx, generation: gen, task: task)
        }
    }

    private func ifCurrent(_ key: Key, _ gen: Int, _ write: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard tasks[key]?.generation == gen, !Task.isCancelled else { return }
        write()
    }

    /// Stop one workspace's pollers, and only its: a workspace closing
    /// used to stop every running workspace's exec-credential refresh.
    public func stopAll(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        for key in tasks.keys where key.profileID == profileID {
            tasks.removeValue(forKey: key)?.task.cancel()
        }
    }

    /// The kubeconfig entries being refreshed for `profileID`.
    public func entries(for profileID: UUID) -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(tasks.keys.filter { $0.profileID == profileID }.map(\.entryID))
    }

    public func stopAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, r) in tasks { r.task.cancel() }
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
        // The entry as the map has it (consent gate, header, paths), with the
        // new token. One the map no longer has (the kubeconfig was removed)
        // isn't put back.
        guard let prior = entries.first(where: { $0.fake == fake && $0.host == host }) else { return }
        entries.removeAll { $0.fake == fake && $0.host == host }
        entries.append(prior.withReal(real))
        swapper.setMap(TokenMap(entries: entries), for: profileID)
    }
}
