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
