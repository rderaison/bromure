import Foundation
@preconcurrency import Security
import Crypto
import _CryptoExtras
import X509
import SwiftASN1

// MARK: - Endpoint keys

/// The key both registries file an upstream under: the lowercased host,
/// then `:port` unless it's 443 -- what `KubeconfigEntry.hostPattern`
/// gives for `https://h` and `https://h:6443`, with an explicit `:443`
/// folded onto the bare form (same endpoint). One key per endpoint, so a
/// registration never writes into another context's slot and a lookup
/// never falls back to one.
/// An IPv6 literal is keyed unbracketed on 443 and bracketed with any other
/// port (`[2001:db8::1]:6443`), whichever form the host arrived in (CONNECT's
/// authority is bracketed, a URL's host is not).
func endpointKey(host: String, port: Int) -> String {
    port == 443 ? HostAuthority.bare(host) : HostAuthority.format(host: host, port: port)
}

/// A registration's `host[:port]` as an `endpointKey`.
func endpointKey(_ hostPattern: String) -> String {
    let (host, port) = TokenSwapper.splitScope(hostPattern.lowercased())
    return endpointKey(host: host, port: port ?? 443)
}

// MARK: - SecIdentity registry

/// Per-host client identity table the proxy hands to URLSession when
/// the upstream API server asks for client-cert auth (Kubernetes,
/// internal mTLS APIs, etc.). Keyed by `endpointKey` -- the host, with
/// its port unless 443 -- and looked up the same way, exactly.
public final class ClientIdentityRegistry: @unchecked Sendable {
    private let lock = NSLock()

    public struct Entry: Sendable {
        public let identity: SecIdentity
        /// Stable consent ID for the originating credential. nil = no
        /// gate; the proxy hands the identity to URLSession without
        /// prompting.
        public let consentCredentialID: String?
        public let consentDisplayName: String?
        public init(identity: SecIdentity,
                    consentCredentialID: String? = nil,
                    consentDisplayName: String? = nil) {
            self.identity = identity
            self.consentCredentialID = consentCredentialID
            self.consentDisplayName = consentDisplayName
        }
    }

    /// Per-profile, per-host map. We key by profile so two profiles
    /// pointing at the same cluster URL with different creds don't
    /// stomp on each other.
    private var perProfile: [UUID: [String: Entry]] = [:]

    public init() {}

    public func setIdentity(_ identity: SecIdentity, host: String, profileID: UUID,
                            consentCredentialID: String? = nil,
                            consentDisplayName: String? = nil) {
        let entry = Entry(identity: identity,
                          consentCredentialID: consentCredentialID,
                          consentDisplayName: consentDisplayName)
        lock.lock(); defer { lock.unlock() }
        perProfile[profileID, default: [:]][endpointKey(host)] = entry
    }

    public func clearAll(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        perProfile.removeValue(forKey: profileID)
    }

    /// Replace a profile's identities in ONE locked swap. Clearing and
    /// re-adding them one by one left a gap a handshake on the proxy's
    /// queue could hit -- no client certificate for that request (Finding
    /// CWE-362, "Live kube trust rebuild drops the cluster CA and client
    /// cert between lock acquisitions").
    public func replaceAll(_ identities: [(host: String, entry: Entry)], for profileID: UUID) {
        var byHost: [String: Entry] = [:]
        for (host, entry) in identities { byHost[endpointKey(host)] = entry }
        lock.lock(); defer { lock.unlock() }
        perProfile[profileID] = byHost.isEmpty ? nil : byHost
    }

    /// The identity registered for this endpoint -- `host` and `port` as
    /// the connection dials them. Never another port's: a `host:8443`
    /// context's certificate isn't presented to `host:6443` or `host`.
    public func entry(for host: String, port: Int, profileID: UUID) -> Entry? {
        let key = endpointKey(host: host, port: port)
        lock.lock(); defer { lock.unlock() }
        return perProfile[profileID]?[key]
    }

    /// Compatibility shortcut for code that only needs the SecIdentity.
    public func identity(for host: String, port: Int, profileID: UUID) -> SecIdentity? {
        return entry(for: host, port: port, profileID: profileID)?.identity
    }
}

// MARK: - Cluster CA trust registry

/// Per-host root-CA table the proxy hands to URLSession when an
/// upstream uses a cert that doesn't chain to the macOS system trust
/// store (e.g. a private k8s API server with its own CA). Keyed by
/// `endpointKey` and looked up exactly. When an entry is present, the
/// registered PEM is the *only* anchor used to evaluate that host's
/// server cert.
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
        lock.lock(); defer { lock.unlock() }
        perProfile[profileID, default: [:]][endpointKey(host)] = cert
    }

    public func clearAll(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        perProfile.removeValue(forKey: profileID)
    }

    /// Replace a profile's cluster CAs in ONE locked swap, every PEM parsed
    /// first -- a lookup never sees the profile cleared (an empty slot is
    /// system trust for that handshake: Finding CWE-362, "Live kube trust
    /// rebuild drops the cluster CA and client cert between lock
    /// acquisitions"). A host whose new PEM doesn't parse keeps the CA it
    /// had, rather than falling back to system trust. Each endpoint has
    /// its own key and nothing else writes it, so that CA is always its
    /// own -- never a context's this rebuild removed, or another port's on
    /// the same name (Findings CWE-295, "A failed cluster-CA parse
    /// republishes a removed context's CA on the bare host" and "Portless
    /// kube CA parse failure republishes another context's certificate").
    /// With no previous CA of its own it stays unpinned, as a new host would.
    public func replaceAll(_ cas: [(pem: String, host: String)], for profileID: UUID) {
        var parsed: [String: SecCertificate] = [:]
        var failed: [String] = []
        for (pem, host) in cas {
            let key = endpointKey(host)
            guard let cert = Self.parseFirstCertPEM(pem) else { failed.append(key); continue }
            parsed[key] = cert
        }
        lock.lock(); defer { lock.unlock() }
        let previous = perProfile[profileID] ?? [:]
        for key in failed where parsed[key] == nil {
            FileHandle.standardError.write(Data(
                "[mitm] cluster CA parse failed for host=\(key) — keeping its previous CA\n".utf8))
            parsed[key] = previous[key]
        }
        perProfile[profileID] = parsed.isEmpty ? nil : parsed
    }

    /// The CA pinned for this endpoint -- `host` and `port` as the
    /// connection dials them -- and only that one: a `host:8443` context's
    /// CA never anchors a handshake to `host` (443) or `host:6443`.
    public func ca(for host: String, port: Int, profileID: UUID) -> SecCertificate? {
        let key = endpointKey(host: host, port: port)
        lock.lock(); defer { lock.unlock() }
        return perProfile[profileID]?[key]
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

// MARK: - Pinned cluster-CA trust evaluation

/// Server-trust evaluation against a user-pinned cluster CA, shared by
/// the two upstream TLS paths: `ClientCertChallengeDelegate` (URLSession,
/// used for ordinary requests) and `TLSClientStream` (the raw
/// HTTP-upgrade fast path used by `kubectl exec`). Both must reach the
/// same verdict — a host that `kubectl get` can talk to is a host
/// `kubectl exec` must be able to talk to.
public enum PinnedClusterTrust {
    /// Evaluate `trust` for `host`, anchored exclusively at `ca`.
    /// Returns true iff the server cert chains to the pinned CA and
    /// binds to `host`.
    public static func evaluate(_ trust: SecTrust, ca: SecCertificate, host: String) -> Bool {
        // Anchor exclusively against the user-supplied CA — the private
        // k8s root almost never chains to macOS's bundled roots, and
        // falling back would defeat the override.
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        // Use the SSL policy with hostname binding. BasicX509 alone would
        // let any cert chained to the same pinned CA satisfy a request for
        // any hostname under that CA — fine for single-cert clusters, fatal
        // for any cluster with kubelet / etcd / sibling-API certs under the
        // same root. Apple's max-validity / CT restrictions only apply when
        // chaining to system roots; against a custom anchor with
        // anchorCertificatesOnly=true the long self-signed cluster cert
        // lifetimes are accepted.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, [policy] as CFArray)
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) { return true }
        if acceptPinnedDespiteValidityPeriod(trust, host: host) {
            // The user explicitly pinned this cluster CA, so Apple's 398-day
            // SSL max-validity policy shouldn't reject the long-lived
            // self-signed kube-apiserver cert it issued. We re-checked with a
            // Basic X.509 policy (chain-to-pinned-anchor + not expired,
            // *without* the SSL-only 398-day rule) plus a best-effort
            // hostname match, so this isn't a blanket bypass.
            FileHandle.standardError.write(Data(
                "[mitm] \(host): cert chains to the pinned cluster CA (Basic X.509 ok); accepting despite Apple's 398-day SSL max-validity rule\n".utf8))
            return true
        }
        let reason = (err as Error?).map { "\($0)" } ?? "unknown"
        FileHandle.standardError.write(Data(
            "[mitm] trust eval failed for \(host) using registered CA: \(reason)\n".utf8))
        return false
    }

    /// Accept a server cert that the SSL policy rejected *only* because of
    /// Apple's 398-day max-validity rule (which can fire on any cert in the
    /// chain — the long-lived self-signed cluster CA or the API server leaf).
    ///
    /// We re-evaluate the same trust (anchors still pinned to the user's
    /// cluster CA) with a **Basic X.509** policy, which checks chain-to-anchor
    /// and per-cert temporal validity (expired / not-yet-valid) but does NOT
    /// apply the SSL-only 398-day span rule. If that passes, the cert really
    /// does chain to the CA the user pinned for this host and isn't expired.
    /// Basic X.509 skips hostname binding, so we re-add it ourselves
    /// (best-effort) against the leaf's SANs — only refusing on a positive
    /// mismatch, never on a parsing gap.
    static func acceptPinnedDespiteValidityPeriod(_ trust: SecTrust, host: String) -> Bool {
        let basic = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(trust, [basic] as CFArray)
        var err: CFError?
        guard SecTrustEvaluateWithError(trust, &err) else { return false }
        // Index 0 of the evaluated chain is the leaf. (SecTrustGetCertificateAtIndex
        // was deprecated in macOS 12; SecTrustCopyCertificateChain is the
        // replacement and returns the full chain leaf-first.)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return true }
        return hostnameMatch(leaf, host: host) != .mismatch
    }

    private enum HostMatch { case match, mismatch, noSANs }

    /// Best-effort hostname/IP match against the leaf cert's SANs. Returns
    /// `.noSANs` (treated as acceptable) when we can't read SANs, so a parsing
    /// limitation never blocks a connection that already chained to the pinned
    /// CA.
    private static func hostnameMatch(_ cert: SecCertificate, host: String) -> HostMatch {
        guard let values = SecCertificateCopyValues(
                cert, [kSecOIDSubjectAltName] as CFArray, nil) as? [CFString: Any],
              let san = values[kSecOIDSubjectAltName] as? [CFString: Any],
              let entries = san[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return .noSANs
        }
        let target = host.lowercased()
        let targetIsIP = target.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        var sawAny = false
        for entry in entries {
            guard let value = (entry[kSecPropertyKeyValue] as? String)?.lowercased() else { continue }
            let label = (entry[kSecPropertyKeyLabel] as? String)?.lowercased() ?? ""
            sawAny = true
            if targetIsIP {
                if label.contains("ip"), value == target { return .match }
            } else if label.contains("dns") || label.contains("name") {
                if value == target { return .match }
                if value.hasPrefix("*.") {
                    let suffix = value.dropFirst(1)            // ".example.com"
                    if target.hasSuffix(suffix),
                       !target.dropLast(suffix.count).contains(".") { return .match }
                }
            }
        }
        return sawAny ? .mismatch : .noSANs
    }
}

// MARK: - Kubeconfig materialization: SecIdentity

/// The materializer's client identities as Security objects (macOS).
extension KubeconfigMaterializer {
    /// Build a SecIdentity from PEM cert + PEM key. PKCS#12 round-trip
    /// is the simplest cross-version path: assemble cert + key into a
    /// p12, import, fish out the identity. We use the SecIdentityCreate
    /// SPI from CertCache.swift instead — already proven.
    func makeSecIdentity(certPEM: String, keyPEM: String) -> SecIdentity? {
        // Decode the PEM cert
        guard let certData = pemDecode(certPEM, marker: "CERTIFICATE"),
              let secCert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }
        guard let key = makeSecKey(keyPEM: keyPEM) else { return nil }

        guard let identity = bromure_SecIdentityCreate(nil, secCert, key) else {
            return nil
        }
        return identity.takeRetainedValue()
    }

    /// SecKeyCreateWithData takes PKCS#1 DER for RSA and X9.63
    /// (`04 || X || Y || K`) for EC, not SEC1 or PKCS#8 PEM.
    func makeSecKey(keyPEM: String) -> SecKey? {
        let ecAttrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                        kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let rsaAttrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let candidates: [(Data, [CFString: Any])] = [
            ((try? P256.Signing.PrivateKey(pemRepresentation: keyPEM))?.x963Representation, ecAttrs),
            ((try? P384.Signing.PrivateKey(pemRepresentation: keyPEM))?.x963Representation, ecAttrs),
            ((try? P521.Signing.PrivateKey(pemRepresentation: keyPEM))?.x963Representation, ecAttrs),
            ((try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: keyPEM))?.derRepresentation, rsaAttrs),
        ].compactMap { data, attrs in data.map { ($0, attrs) } }
        for (data, attrs) in candidates {
            if let k = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil) { return k }
        }
        return nil
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
