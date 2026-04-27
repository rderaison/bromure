import Foundation

/// Per-profile AWS credential vendor served over vsock. The guest's
/// `credential_process` helper opens a connection, the host writes the
/// SDK-format JSON, and the connection closes. The real access key /
/// secret never touches the guest disk; SigV4 signing still happens in
/// the VM but with material that lives only in this process's memory.
///
/// Wire format on the socket: one JSON document, server-pushed, then
/// server EOF. Any errors are reported as `{"Version":1,"Error":"…"}`
/// (non-standard but harmless — the SDK rejects payloads without
/// AccessKeyId, surfacing the message verbatim).
public final class AWSCredentialServer: @unchecked Sendable {
    private struct Entry {
        var accessKeyID: String
        var secretAccessKey: String
        var sessionToken: String
        var requireApproval: Bool
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
            requireApproval: creds.requireApproval)
    }

    public func clearCredentials(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        byProfile.removeValue(forKey: profileID)
    }

    private func entry(for profileID: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return byProfile[profileID]
    }

    /// Serve one client connection. Pushes the JSON payload and closes.
    public func serve(fd: Int32, profileID: UUID) async {
        defer { close(fd) }

        // Gate on consent if the credential is flagged. Denial returns
        // a structured error JSON so the SDK reports a useful message
        // rather than hanging on a closed socket.
        let entry = self.entry(for: profileID)
        if let e = entry, e.requireApproval {
            let masked = Self.maskAccessKey(e.accessKeyID)
            let allowed = await consent.consent(
                profileID: profileID,
                credentialID: ConsentCredentialID.aws(),
                credentialDisplayName: "AWS access key \(masked)",
                scopeHint: NSLocalizedString(
                    "for any AWS API call (SigV4 signing in the VM)",
                    comment: ""))
            if !allowed {
                writePayload(fd: fd, data: errorPayload("denied by user consent"))
                return
            }
        }

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
    private func jsonPayload(for profileID: UUID) -> Data {
        guard let e = entry(for: profileID) else {
            return errorPayload("no AWS credentials configured for this profile")
        }
        var obj: [String: Any] = [
            "Version": 1,
            "AccessKeyId": e.accessKeyID,
            "SecretAccessKey": e.secretAccessKey,
        ]
        if !e.sessionToken.isEmpty {
            obj["SessionToken"] = e.sessionToken
        }
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
}
