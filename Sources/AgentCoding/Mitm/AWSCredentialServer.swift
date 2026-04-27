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
    }
    private var byProfile: [UUID: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public func setCredentials(_ creds: AWSCredentials, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard creds.isUsable else {
            byProfile.removeValue(forKey: profileID)
            return
        }
        byProfile[profileID] = Entry(
            accessKeyID: creds.accessKeyID,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken)
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
    public func serve(fd: Int32, profileID: UUID) {
        defer { close(fd) }
        let payload = jsonPayload(for: profileID)
        payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let n = write(fd, base.advanced(by: written), buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
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
