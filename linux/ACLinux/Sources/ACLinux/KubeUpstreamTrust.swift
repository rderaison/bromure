import Foundation
import NIOConcurrencyHelpers
import NIOSSL

/// The upstream TLS material of a workspace's imported kubeconfigs (macOS:
/// MitmEngine's ClientIdentityRegistry and ClusterCATrustRegistry): per
/// workspace and endpoint (`endpointKey`), a client certificate to present
/// and a cluster CA that is then the only anchor of that endpoint's server
/// certificate (system roots never). Each endpoint's client context is made
/// once, when the material is applied; the proxy dials with it.
// @port-skip linux-only: the two macOS registries over NIOSSL (SecIdentity / SecTrust there)
final class KubeUpstreamTrust: @unchecked Sendable {
    /// A client certificate, as `consent` gates it.
    struct Identity {
        let chain: [NIOSSLCertificate]
        let key: NIOSSLPrivateKey
        let consentCredentialID: String?
        let consentDisplayName: String?
    }

    /// What one endpoint dials with.
    struct Endpoint {
        let context: NIOSSLContext
        let identity: Identity?
        let pinned: Bool
    }

    private struct Profile {
        var identities: [String: Identity] = [:]
        var cas: [String: NIOSSLCertificate] = [:]
        var endpoints: [String: Endpoint] = [:]
    }

    private let state = NIOLockedValueBox<[UUID: Profile]>([:])
    /// Tests: roots trusted besides the system's for an endpoint that has a
    /// client certificate but no CA of its own (as the proxy's default context).
    private let extraRoots: [NIOSSLCertificate]

    // @port-skip linux-only: the Linux proxy's kube upstream trust
    init(extraRoots: [NIOSSLCertificate] = []) { self.extraRoots = extraRoots }

    /// A workspace's material, swapped in whole (macOS: applyKubeMaterial's
    /// two replaceAll): a handshake never sees the workspace cleared midway.
    /// A client certificate that doesn't load is left out; a cluster CA that
    /// doesn't parse keeps that endpoint's previous CA, or none.
    // @port MitmEngine.static applyKubeMaterial(_: KubeconfigMaterializer.Materialized, profileID: UUID, identities: ClientIdentityRegistry, clusterCAs: ClusterCATrustRegistry, poller: ExecCredentialPoller, swapper: TokenSwapper) h=269693f80b746698 @8e2543eb
    func apply(_ mat: KubeconfigMaterializer.Materialized, profileID: UUID) {
        replaceAll(identities: mat.clientIdentities.map {
            (host: $0.host, certPEM: $0.certPEM, keyPEM: $0.keyPEM,
             consentCredentialID: $0.consentCredentialID, consentDisplayName: $0.consentDisplayName)
        }, cas: mat.clusterCAs.map { (pem: $0.caPEM, host: $0.host) }, for: profileID)
    }

    // @port ClientIdentityRegistry.replaceAll(_: [(host:String,entry:Entry)], for: UUID) h=ae1ba7f438f50f6d @b733b8a1
    // @port ClusterCATrustRegistry.replaceAll(_: [(pem:String,host:String)], for: UUID) h=63606b0fc89bec34 @b733b8a1
    func replaceAll(identities: [(host: String, certPEM: String, keyPEM: String,
                                  consentCredentialID: String?, consentDisplayName: String?)],
                    cas: [(pem: String, host: String)], for profileID: UUID) {
        var ids: [String: Identity] = [:]
        for spec in identities {
            let key = endpointKey(spec.host)
            guard let id = Self.makeIdentity(certPEM: spec.certPEM, keyPEM: spec.keyPEM) else {
                FileHandle.standardError.write(Data(
                    "[mitm] client certificate for host=\(key) doesn't load — left out\n".utf8))
                continue
            }
            ids[key] = Identity(chain: id.chain, key: id.key, consentCredentialID: spec.consentCredentialID,
                                consentDisplayName: spec.consentDisplayName)
        }
        var parsed: [String: NIOSSLCertificate] = [:]
        var failed: [String] = []
        for (pem, host) in cas {
            let key = endpointKey(host)
            guard let cert = Self.parseFirstCertPEM(pem) else { failed.append(key); continue }
            parsed[key] = cert
        }
        // One locked step, as macOS's: the previous CA read and the swap.
        state.withLockedValue { all in
            let previous = all[profileID]?.cas ?? [:]
            for key in failed where parsed[key] == nil {
                FileHandle.standardError.write(Data(
                    "[mitm] cluster CA parse failed for host=\(key) — keeping its previous CA\n".utf8))
                parsed[key] = previous[key]
            }
            var next = Profile(identities: ids, cas: parsed)
            for key in Set(ids.keys).union(parsed.keys) {
                if let e = makeEndpoint(identity: ids[key], ca: parsed[key], key: key) { next.endpoints[key] = e }
            }
            all[profileID] = next.endpoints.isEmpty ? nil : next
        }
    }

    // @port ClientIdentityRegistry.clearAll(for: UUID) h=695257467ab1f983 @b733b8a1
    // @port ClusterCATrustRegistry.clearAll(for: UUID) h=695257467ab1f983 @b733b8a1
    func clearAll(for profileID: UUID) {
        state.withLockedValue { $0[profileID] = nil }
    }

    /// The material for this endpoint -- `host` and `port` as the connection
    /// dials them -- and only that one: a `host:8443` context's never serves
    /// `host` (443) or `host:6443`. nil: the proxy's own context (system roots,
    /// no client certificate).
    // @port ClientIdentityRegistry.entry(for: String, port: Int, profileID: UUID) h=20e5bac7b230e0cc @b733b8a1
    // @port ClusterCATrustRegistry.ca(for: String, port: Int, profileID: UUID) h=20e5bac7b230e0cc @b733b8a1
    func endpoint(for host: String, port: Int, profileID: UUID) -> Endpoint? {
        let key = endpointKey(host: host, port: port)
        return state.withLockedValue { $0[profileID]?.endpoints[key] }
    }

    /// One endpoint's client context. A pinned CA is its only trust root; a
    /// client certificate that the context refuses (a key that isn't the
    /// certificate's) is dropped, the CA kept. A CA whose context can't be
    /// made leaves nothing to dial with: that endpoint fails closed.
    // @port-skip linux-only: NIOSSL client contexts (macOS: ClientCertChallengeDelegate / TLSClientStream)
    private func makeEndpoint(identity: Identity?, ca: NIOSSLCertificate?, key: String) -> Endpoint? {
        func context(_ id: Identity?) -> NIOSSLContext? {
            var cfg = TLSConfiguration.makeClientConfiguration()
            cfg.applicationProtocols = ["http/1.1"]
            // A sibling leaf under the pinned CA (kubelet, etcd, aggregator)
            // never serves the API server's name or address (MitmProxy's
            // upstreamContext: the same binding).
            cfg.certificateVerification = .fullVerification
            if let ca {
                cfg.trustRoots = .certificates([ca])
            } else if !extraRoots.isEmpty {
                cfg.additionalTrustRoots = [.certificates(extraRoots)]
            }
            if let id {
                cfg.certificateChain = id.chain.map { .certificate($0) }
                cfg.privateKey = .privateKey(id.key)
            }
            return try? NIOSSLContext(configuration: cfg)
        }
        if let ctx = context(identity) { return Endpoint(context: ctx, identity: identity, pinned: ca != nil) }
        if identity != nil {
            FileHandle.standardError.write(Data(
                "[mitm] client certificate for host=\(key) doesn't match its key — left out\n".utf8))
            if ca != nil, let ctx = context(nil) { return Endpoint(context: ctx, identity: nil, pinned: true) }
            return nil
        }
        FileHandle.standardError.write(Data("[mitm] cluster CA for host=\(key) isn't usable — that endpoint fails closed\n".utf8))
        return Endpoint(context: Self.refusing, identity: nil, pinned: true)
    }

    /// A context that trusts nothing: an endpoint whose pinned CA can't be
    /// used never falls back to the system roots.
    // @port-skip linux-only: fail-closed context of the Linux proxy
    private static let refusing: NIOSSLContext = {
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.trustRoots = .certificates([])
        return try! NIOSSLContext(configuration: cfg)
    }()

    /// The certificate chain (leaf first) and key of a kubeconfig's
    /// client-certificate-data / client-key-data.
    // @port KubeconfigMaterializer.static makeSecIdentity(certPEM: String, keyPEM: String) h=9c514fe7463353b2 @b733b8a1
    static func makeIdentity(certPEM: String, keyPEM: String) -> (chain: [NIOSSLCertificate], key: NIOSSLPrivateKey)? {
        guard let chain = try? NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8)), !chain.isEmpty,
              let key = try? NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem) else { return nil }
        return (chain, key)
    }

    /// The first certificate of a PEM bundle, as macOS pins it.
    // @port ClusterCATrustRegistry.static parseFirstCertPEM(_: String) h=00cd1214be6fddb0 @b733b8a1
    static func parseFirstCertPEM(_ pem: String) -> NIOSSLCertificate? {
        (try? NIOSSLCertificate.fromPEMBytes(Array(pem.utf8)))?.first
    }
}

extension MitmProxy {
    /// A workspace's kube material in force (macOS: MitmEngine's
    /// applyKubeMaterial): its trust, and its exec pollers synced -- an
    /// unchanged context keeps running (no second run of its plugin), a
    /// changed one restarts, one no longer listed stops.
    // @port MitmEngine.applyKubeMaterial(_: KubeconfigMaterializer.Materialized, profileID: UUID) h=ecbeb19cbf92d3cd @8e2543eb
    @MainActor
    func applyKubeMaterial(_ mat: KubeconfigMaterializer.Materialized, profileID: UUID) {
        execContexts.withLockedValue { $0[profileID] = mat.execContexts.isEmpty ? nil : mat.execContexts }
        kubeTrust.apply(mat, profileID: profileID)
        execPoller.sync(mat.execContexts, profileID: profileID, swapper: swapper)
    }

    /// The kubeconfig step's proxy side, and the one place the workspace's
    /// swap map is set: its token plan's map (`base`; none: no map, as a
    /// sign-in VM) with the bearer and exec swaps, fresh at launch, merged
    /// when `live` (macOS: pushLiveCredentials' liveMerge -- an exec token
    /// already fetched stays on its unchanged fake); then the material
    /// applied.
    // @port-skip linux-only: the kubeconfig step of ACAppDelegate.launch / pushLiveCredentials, proxy side
    @MainActor
    func installKube(_ mat: KubeconfigMaterializer.Materialized, base: TokenMap?, profileID: UUID, live: Bool) {
        if var map = base {
            for swap in mat.bearerSwaps {
                map.entries.append(TokenMap.Entry(
                    fake: swap.fakeToken, real: swap.realToken, host: swap.host,
                    consentCredentialID: swap.consentCredentialID,
                    consentDisplayName: swap.consentDisplayName))
            }
            swapper.setMap(live ? TokenMap.liveMerge(fresh: map.entries, current: swapper.entries(for: profileID)) : map,
                           for: profileID)
            Self.debugLogMap(profileID, swapper.entries(for: profileID), live: live)
            // 1Password: a credential whose value is an `op://` reference keeps
            // the plan's stable fake; the real secret is resolved on the host,
            // now and every 120 s, and only the reference is ever on disk. A
            // live refresh follows the new references (macOS: launch's and
            // restage's opRefresher.start).
            opRefresher.start(profileID: profileID, refs: OnePasswordRefresher.refs(in: map.entries), swapper: swapper,
                              onFirstError: { err in
                FileHandle.standardError.write(Data("[1password] \(err.errorDescription ?? "\(err)") — workspace \(profileID)\n".utf8))
            })
        }
        // Launch and live refresh alike: what's added, edited or removed
        // while the VM runs takes effect at once (trust and exec pollers).
        applyKubeMaterial(mat, profileID: profileID)
    }

    /// Debug builds: the map installed (fakes' first 8 characters and hosts,
    /// never a real value), for the VM e2es. A release build logs nothing.
    // @port-skip linux-only: e2e diagnostics of the Linux proxy
    nonisolated static func debugLogMap(_ profileID: UUID, _ entries: [TokenMap.Entry], live: Bool) {
        #if DEBUG
        let list = entries.map { "\($0.fake.prefix(8))…@\($0.host ?? "*")\($0.real.isEmpty ? "(empty)" : "")" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[mitm] DEBUG: map for \(profileID) (\(live ? "live" : "launch")): \(entries.count): \(list)\n".utf8))
        #endif
    }

    // @port MitmEngine.kubeExecContexts(for: UUID) h=641587bd0d2992de @8e2543eb
    func kubeExecContexts(for profileID: UUID) -> [KubeconfigMaterializer.ExecContext] {
        execContexts.withLockedValue { $0[profileID] ?? [] }
    }

    /// The VM stopped: its trust gone, its plugins no longer run (macOS:
    /// MitmEngine.unregister's share).
    // @port-skip linux-only: the kube share of MitmEngine.unregister(profileID:)
    @MainActor
    func clearKube(for profileID: UUID) {
        kubeTrust.clearAll(for: profileID)
        execPoller.stopAll(profileID: profileID)
        opRefresher.stop(profileID: profileID)
        execContexts.withLockedValue { $0[profileID] = nil }
    }
}

/// The key both kinds of material file an upstream under: the lowercased
/// host, then `:port` unless it's 443 (macOS: CloudCredentials.swift's,
/// which the Linux build doesn't compile).
// @port endpointKey(host: String, port: Int) h=ff828e5e9f6cb8ab @b733b8a1
func endpointKey(host: String, port: Int) -> String {
    port == 443 ? HostAuthority.bare(host) : HostAuthority.format(host: host, port: port)
}

/// A registration's `host[:port]` as an `endpointKey`.
// @port endpointKey(_: String) h=efd8c4451d615cbe @b733b8a1
func endpointKey(_ hostPattern: String) -> String {
    let (host, port) = TokenSwapper.splitScope(hostPattern.lowercased())
    return endpointKey(host: host, port: port ?? 443)
}
