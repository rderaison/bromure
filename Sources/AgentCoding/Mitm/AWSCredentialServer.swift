import Foundation

/// Per-profile AWS credential vendor served over vsock — and the
/// host-side custodian of the *real* signing material that the
/// `AWSResigner` consumes when it re-signs guest requests.
///
/// Two surfaces:
///
///   * `serve(fd:profileID:)` — what the guest's `credential_process`
///     helper talks to. The vended payload now contains the **real**
///     `AccessKeyId` (so the SDK's identity caching / debug output is
///     useful) and a **fake** 40-char `SecretAccessKey`. The `SessionToken`
///     is intentionally omitted — the resigner injects the real one
///     before signing on the host.
///
///     Result: the guest's SDK signs requests with material that
///     cannot authenticate against AWS. The signature only becomes
///     valid after the host's `AWSResigner` strips it and re-signs
///     with the real secret. If the proxy is bypassed, AWS rejects
///     the request — fail-closed.
///
///   * `signingMaterial(for:scopeHint:)` — what the resigner calls,
///     per request. Returns the real AKID/secret/sessionToken bundle
///     (after a consent prompt if `requireApproval` is set on the
///     credential). The real secret never reaches the VM's address
///     space.
///
/// Wire format on the credential_process socket: one JSON document,
/// server-pushed, then server EOF. Errors are reported as
/// `{"Version":1,"Error":"…"}` (non-standard but harmless — the SDK
/// rejects payloads without `AccessKeyId`, surfacing the message
/// verbatim).
public final class AWSCredentialServer: @unchecked Sendable {
    private struct Entry {
        var accessKeyID: String
        var secretAccessKey: String
        var sessionToken: String
        var requireApproval: Bool
        /// 40-char fake-secret string handed to the SDK in place of
        /// `secretAccessKey`. Generated once at `setCredentials` so
        /// every credential_process call within a session sees the
        /// same value; rotated whenever the profile's creds change.
        var vendedSecret: String
    }
    private var byProfile: [UUID: Entry] = [:]
    /// Keys the guest minted through the proxy (STS, iam:CreateAccessKey,
    /// DigitalOcean Spaces), by profile then access key id. See
    /// `MintedCredential`.
    private var mintedByProfile: [UUID: [String: MintedCredential]] = [:]
    private let lock = NSLock()
    private let consent: ConsentBroker

    public init(consent: ConsentBroker) {
        self.consent = consent
    }

    public func setCredentials(_ creds: AWSCredentials, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard creds.isUsable else {
            byProfile.removeValue(forKey: profileID)
            return
        }
        byProfile[profileID] = Entry(
            accessKeyID: creds.accessKeyID,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken,
            requireApproval: creds.requireApproval,
            vendedSecret: Self.makeFakeSecret())
    }

    public func clearCredentials(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        byProfile.removeValue(forKey: profileID)
        mintedByProfile.removeValue(forKey: profileID)
    }

    /// The workspace's saved minted keys (launch, live refresh). Replaces
    /// what was there, keeping keys minted since the save was read.
    public func setMinted(_ minted: [MintedCredential], for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var byKey = mintedByProfile[profileID] ?? [:]
        for m in minted where m.kind == .sigV4 && !m.accessKeyID.isEmpty { byKey[m.accessKeyID] = m }
        mintedByProfile[profileID] = byKey.isEmpty ? nil : byKey
    }

    /// One key the proxy just minted.
    public func addMinted(_ m: MintedCredential, for profileID: UUID) {
        guard m.kind == .sigV4, !m.accessKeyID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        mintedByProfile[profileID, default: [:]][m.accessKeyID] = m
    }

    public enum MintedLookup {
        /// Not a minted key: sign as the workspace (its own key, or an SSO
        /// key the guest cached before a refresh).
        case none
        case material(SigV4Signer.Credentials, source: String)
        /// A minted key past its expiry. Never re-signed as the workspace's
        /// own key -- that would run the request as another identity.
        case expired(source: String)
    }

    /// The minted key the guest signed with, if `accessKeyID` is one, and
    /// it's valid for `host` (AWS, or the S3-compatible family it was
    /// minted for).
    public func minted(accessKeyID: String, host: String, profileID: UUID,
                       now: Date = Date()) -> MintedLookup {
        lock.lock()
        let m = mintedByProfile[profileID]?[accessKeyID]
        lock.unlock()
        guard let m else { return .none }
        let h = host.lowercased()
        let forHost = m.hosts.isEmpty
            ? AWSResigner.isAWSHost(h)
            : m.hosts.contains { h == $0 || h.hasSuffix("." + $0) }
        guard forHost else { return .none }
        if m.isExpired(at: now) { return .expired(source: m.source) }
        return .material(SigV4Signer.Credentials(
            accessKeyID: m.accessKeyID, secretAccessKey: m.secret,
            sessionToken: m.sessionToken.isEmpty ? nil : m.sessionToken), source: m.source)
    }

    /// Whether `host` is one a minted key signs for (Spaces), so the
    /// resigner looks at it although it isn't AWS.
    public func hasMintedHost(_ host: String, profileID: UUID) -> Bool {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        return mintedByProfile[profileID]?.values.contains { m in
            m.hosts.contains { h == $0 || h.hasSuffix("." + $0) }
        } ?? false
    }

    /// The workspace's AWS access key id (not secret — the guest holds it,
    /// paired with a fake secret). nil when AWS isn't configured.
    public func accessKeyID(for profileID: UUID) -> String? {
        entry(for: profileID)?.accessKeyID
    }

    private func entry(for profileID: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return byProfile[profileID]
    }

    /// Result of `signingMaterial(for:scopeHint:)`.
    public enum SigningMaterial: Sendable {
        case material(SigV4Signer.Credentials)
        /// User declined the consent prompt. Caller should respond with
        /// a 403 to the guest rather than forwarding the unsigned
        /// request.
        case denied
        /// No AWS credentials configured for this profile. Caller
        /// should let the guest's (invalid) request through so the SDK
        /// surfaces a helpful error.
        case missing
    }

    /// Real signing material for the resigner. Gates on consent when
    /// the credential is flagged. Note the consent expiry windows in
    /// `ConsentBroker` (5min / 1hr / session) cover repeat requests so
    /// per-request prompting only fires the first time.
    public func signingMaterial(
        for profileID: UUID,
        scopeHint: String
    ) async -> SigningMaterial {
        guard let e = self.entry(for: profileID) else { return .missing }
        if e.requireApproval {
            let masked = Self.maskAccessKey(e.accessKeyID)
            let allowed = await consent.consent(
                profileID: profileID,
                credentialID: ConsentCredentialID.aws(),
                credentialDisplayName: "AWS access key \(masked)",
                scopeHint: scopeHint)
            if !allowed { return .denied }
        }
        let creds = SigV4Signer.Credentials(
            accessKeyID: e.accessKeyID,
            secretAccessKey: e.secretAccessKey,
            sessionToken: e.sessionToken.isEmpty ? nil : e.sessionToken)
        return .material(creds)
    }

    /// Serve one client connection. Pushes the (fake-secret) JSON
    /// payload and closes. No consent gate here — the secret being
    /// vended is fake by construction, so there is no real-world
    /// permission to ask about.
    public func serve(fd: Int32, profileID: UUID) async {
        defer { close(fd) }
        let payload = jsonPayload(for: profileID)
        writePayload(fd: fd, data: payload)
    }

    private func writePayload(fd: Int32, data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let n = write(fd, base.advanced(by: written), buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    private static func maskAccessKey(_ akid: String) -> String {
        guard akid.count > 6 else { return "***" }
        return String(akid.prefix(4)) + "…" + String(akid.suffix(4))
    }

    /// Serialize the credentials for `profileID` in the AWS SDK
    /// `credential_process` format. Omitting `Expiration` lets the SDK
    /// cache for the consumer process's lifetime — fine here since the
    /// process dies with the VM.
    ///
    /// Returns the **fake** secret. The real secret is delivered via
    /// `signingMaterial(for:scopeHint:)` to the host's resigner, never
    /// to the guest.
    private func jsonPayload(for profileID: UUID) -> Data {
        guard let e = entry(for: profileID) else {
            return errorPayload("no AWS credentials configured for this profile")
        }
        let obj: [String: Any] = [
            "Version": 1,
            "AccessKeyId": e.accessKeyID,
            "SecretAccessKey": e.vendedSecret,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        } catch {
            return errorPayload("encode failed: \(error)")
        }
    }

    private func errorPayload(_ message: String) -> Data {
        let obj: [String: Any] = ["Version": 1, "Error": message]
        return (try? JSONSerialization.data(withJSONObject: obj))
            ?? Data("{\"Version\":1,\"Error\":\"unknown\"}".utf8)
    }

    /// 40-char alphabet-restricted random string, in the same shape an
    /// AWS secret key takes on the wire (`[A-Za-z0-9+/]`). Doesn't
    /// authenticate against AWS — its only job is to look plausible to
    /// the SDK so signing doesn't crash, and unique per session so
    /// debug output is unambiguous about which session produced what.
    private static func makeFakeSecret() -> String {
        let alphabet = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(40)
        while out.count < 40 {
            let idx = Int(rng.next() % UInt64(alphabet.count))
            out.append(alphabet[idx])
        }
        return out
    }
}
