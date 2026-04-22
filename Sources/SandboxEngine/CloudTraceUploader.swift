import Foundation
import Security

/// Per-session uploader that ships HTTP trace events to an organization's
/// analytics endpoint via mTLS.
///
/// One instance per browser session. Events are buffered in memory and
/// POSTed in batches to `policy.endpoint`; authentication is the managed
/// profile's leaf cert (reused from the NSS-DB install flow), so no bearer
/// tokens ride with the data. The server identifies the install by the
/// cert's subject CN, and we denormalize `installId`, `userEmail`, and
/// `orgSlug` onto every event batch so it's searchable per-request by
/// infosec.
///
/// This uploader is intended for managed profiles only and is wired in at
/// session construction time. A managed profile with a non-disabled
/// `traceLevel` opts the session into cloud trace — recording is forced
/// on, the session-window toggle becomes read-only, and nothing lands on
/// disk. That policy is enforced by the call site, not here.
public final class CloudTraceUploader: @unchecked Sendable {
    public struct SessionContext: Sendable {
        public let sessionId: String
        public let profileId: UUID
        public let installId: String
        public let orgSlug: String
        public let userEmail: String
        public init(sessionId: String, profileId: UUID, installId: String,
                    orgSlug: String, userEmail: String) {
            self.sessionId = sessionId
            self.profileId = profileId
            self.installId = installId
            self.orgSlug = orgSlug
            self.userEmail = userEmail
        }
    }

    private let ctx: SessionContext
    private let policy: CloudTracePolicy
    private let session: URLSession
    private let delegate: MTLSDelegate

    // Buffer / batching configuration.
    private let maxBatchEvents = 200
    private let maxBatchBytes = 512 * 1024      // 512 KiB per POST
    private let flushInterval: TimeInterval = 2.0
    private let maxQueueEvents = 10_000         // ~upper bound before drops
    private let maxInflightRetries = 5

    // Serialization + state.
    private let queue = DispatchQueue(label: "io.bromure.cloudtrace", qos: .utility)
    private var buffer: [TraceEvent] = []
    private var pending: [[TraceEvent]] = []    // batches awaiting retry
    private var flushTimer: DispatchSourceTimer?
    private var isFlushing = false
    private var isClosed = false
    private var droppedEvents: Int = 0

    public init?(ctx: SessionContext, policy: CloudTracePolicy) {
        guard policy.enabled, policy.endpoint != nil else { return nil }
        self.ctx = ctx
        self.policy = policy
        self.delegate = MTLSDelegate(profileId: ctx.profileId)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        startFlushTimer()
    }

    // MARK: - Public API (thread-safe)

    public func ingest(_ event: TraceEvent) {
        queue.async {
            guard !self.isClosed else { return }
            if self.buffer.count + self.pending.reduce(0, { $0 + $1.count }) >= self.maxQueueEvents {
                // Drop oldest pending batch to bound memory.
                if !self.pending.isEmpty {
                    let dropped = self.pending.removeFirst()
                    self.droppedEvents += dropped.count
                } else {
                    self.droppedEvents += 1
                    self.buffer.removeFirst()
                }
            }
            self.buffer.append(Self.filter(event, level: self.policy.level))
            if self.buffer.count >= self.maxBatchEvents {
                self.flushLocked()
            }
        }
    }

    /// Stop accepting events and flush anything buffered. Blocks up to
    /// `timeout` seconds waiting for the last flush.
    public func close(timeout: TimeInterval = 5.0) {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.isClosed = true
            self.flushTimer?.cancel()
            self.flushTimer = nil
            self.flushLocked()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        session.finishTasksAndInvalidate()
    }

    // MARK: - Flush / upload

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        flushTimer = t
    }

    /// Must be called from `queue`.
    private func flushLocked() {
        guard !isFlushing else { return }
        if !buffer.isEmpty {
            pending.append(buffer)
            buffer = []
        }
        guard let next = pending.first else { return }
        isFlushing = true
        upload(batch: next, attempt: 1)
    }

    private func upload(batch: [TraceEvent], attempt: Int) {
        guard let endpoint = policy.endpoint else {
            // Shouldn't happen — `init?` already gated on this.
            queue.async {
                self.isFlushing = false
                _ = self.pending.removeFirst()
            }
            return
        }
        let body = envelope(for: batch)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ctx.installId, forHTTPHeaderField: "X-Bromure-Install")
        req.setValue(ctx.orgSlug, forHTTPHeaderField: "X-Bromure-Org")
        req.httpBody = body

        let task = session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let ok = err == nil && (200...299).contains(code)
            self.queue.async {
                if ok {
                    if !self.pending.isEmpty { _ = self.pending.removeFirst() }
                    self.isFlushing = false
                    // Chain to the next pending batch if any.
                    if !self.pending.isEmpty { self.flushLocked() }
                } else if attempt >= self.maxInflightRetries {
                    // Give up on this batch — drop to unblock the queue.
                    if !self.pending.isEmpty {
                        let dropped = self.pending.removeFirst()
                        self.droppedEvents += dropped.count
                    }
                    self.isFlushing = false
                    if !self.pending.isEmpty { self.flushLocked() }
                } else {
                    // Exponential backoff with jitter: 1, 2, 4, 8, 16 s ± 20%.
                    let base = pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: -0.2...0.2)
                    let delay = base * (1.0 + jitter)
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        guard !self.isClosed else {
                            self.isFlushing = false
                            return
                        }
                        self.upload(batch: batch, attempt: attempt + 1)
                    }
                }
            }
        }
        task.resume()
    }

    private func envelope(for batch: [TraceEvent]) -> Data {
        struct Wire: Encodable {
            let schemaVersion: Int
            let installId: String
            let orgSlug: String
            let userEmail: String
            let sessionId: String
            let profileId: String
            let level: String
            let events: [TraceEvent]
        }
        let wire = Wire(
            schemaVersion: 1,
            installId: ctx.installId,
            orgSlug: ctx.orgSlug,
            userEmail: ctx.userEmail,
            sessionId: ctx.sessionId,
            profileId: ctx.profileId.uuidString.lowercased(),
            level: policy.level.rawValue,
            events: batch,
        )
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    // MARK: - Event-level filtering

    private static func filter(_ event: TraceEvent, level: CloudTracePolicy.Level) -> TraceEvent {
        var e = event
        switch level {
        case .basic:
            e.requestHeaders = nil
            e.responseHeaders = nil
            e.postData = nil
            e.responseBody = nil
            e.responseBodyTruncated = nil
            e.formFields = nil
        case .headers:
            e.postData = nil
            e.responseBody = nil
            e.responseBodyTruncated = nil
            e.formFields = nil
        case .full:
            break
        }
        return e
    }
}

// MARK: - mTLS challenge handler

/// URLSession delegate that answers TLS client-cert challenges with the
/// managed profile's issued leaf cert. Resolves the identity via
/// `AnalyticsMTLSIdentity`, which caches the result — so the keychain is
/// hit at most once per profile per process, not once per HTTPS request.
private final class MTLSDelegate: NSObject, URLSessionDelegate {
    private let profileId: UUID
    init(profileId: UUID) { self.profileId = profileId }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = try? AnalyticsMTLSIdentity.identity(for: profileId) {
                let cred = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, cred)
            } else {
                print("[CloudTraceUploader] no mTLS identity available for profile \(profileId)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Builds a `SecIdentity` from *exactly* the leaf cert and private key that
/// were issued for a given managed profile — without ever writing to a
/// file-based keychain, which means no unlock prompts, no Keychain Access
/// entries, no interference with the user's login keychain.
///
/// We package the cert + PKCS#8 private key into a PKCS#12 blob in memory
/// (via `/usr/bin/openssl pkcs12 -export`, which LibreSSL ships with macOS)
/// and then hand the blob to `SecPKCS12Import` with *no*
/// `kSecImportExportKeychain` entry in the options dictionary. Per the
/// Security framework contract, items in that case "will not be written to
/// any keychain and will only be accessible via references returned by
/// this function" — the resulting `SecIdentity` is a pure in-memory
/// reference. The identity is cached per-profile so the packaging only
/// runs once per process.
///
/// History: this used to live in the user's login keychain (random
/// identities got picked for mTLS challenges, and every sign op popped an
/// ACL prompt), and then briefly in a process-private file-based keychain
/// in `$TMPDIR` (which still prompted the user for the keychain password).
/// Both are gone — no `SecKeychain` is created at any point on this path.
enum AnalyticsMTLSIdentity {
    enum Error: Swift.Error {
        case missingMaterial
        case pkcs12BuildFailed(code: Int32, stderr: String)
        case pkcs12ImportFailed(OSStatus)
        case identityExtractionFailed
    }

    private static let cacheLock = NSLock()
    private static var cache: [UUID: SecIdentity] = [:]

    static func identity(for profileId: UUID) throws -> SecIdentity {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[profileId] { return cached }
        let ident = try buildIdentity(for: profileId)
        cache[profileId] = ident
        return ident
    }

    /// Drop the cached identity for a profile — call on unenroll /
    /// destroy-local-state so a rotated cert isn't served by a stale
    /// identity ref.
    static func purge(profileId: UUID) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: profileId)
    }

    private static func buildIdentity(for profileId: UUID) throws -> SecIdentity {
        let certURL = ManagedProfileStore.shared.mtlsCertURL(for: profileId)
        guard let certPem = try? String(contentsOf: certURL, encoding: .utf8) else {
            throw Error.missingMaterial
        }
        guard let privKey = try? ManagedProfileSync.shared.loadMTLSPrivateKey(for: profileId) else {
            throw Error.missingMaterial
        }
        let keyPem = privKey.pemRepresentation

        // Random per-invocation PKCS#12 password. We're both producer and
        // consumer so the value only lives for the duration of this call;
        // it never leaves this function.
        var pwdBytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, pwdBytes.count, &pwdBytes)
        let password = Data(pwdBytes).base64EncodedString()

        let pkcs12 = try buildPKCS12(certPem: certPem, keyPem: keyPem, password: password)

        // Import with no `kSecImportExportKeychain` entry: items stay
        // in-memory, referenced only by the returned identity.
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let itemsArr = items as? [[String: Any]] else {
            throw Error.pkcs12ImportFailed(status)
        }
        guard let entry = itemsArr.first,
              let identityAny = entry[kSecImportItemIdentity as String]
        else {
            throw Error.identityExtractionFailed
        }
        return identityAny as! SecIdentity
    }

    /// Package cert + key into a PKCS#12 blob using the system `openssl`
    /// binary. Shelling out gets us a battle-tested PKCS#12 encoder for a
    /// few dozen lines of glue — the alternative is hand-rolling the
    /// ASN.1 + PBKDF2 + PBE ourselves, which is security-sensitive code
    /// we'd rather not own.
    ///
    /// The cert and key PEMs are written to a freshly-created 0700
    /// directory under `$TMPDIR` for the duration of the subprocess and
    /// deleted immediately after. The key is already persisted unencrypted
    /// in the ManagedProfileSync keychain entry, so the brief on-disk
    /// copy here doesn't expand the trust boundary.
    private static func buildPKCS12(
        certPem: String, keyPem: String, password: String,
    ) throws -> Data {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-p12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: base.path)
        defer { try? FileManager.default.removeItem(at: base) }

        let certFile = base.appendingPathComponent("c.pem")
        let keyFile = base.appendingPathComponent("k.pem")
        try certPem.write(to: certFile, atomically: true, encoding: .utf8)
        try keyPem.write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: certFile.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = [
            "pkcs12", "-export",
            "-in", certFile.path,
            "-inkey", keyFile.path,
            "-passout", "pass:\(password)",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let msg = String(data: err, encoding: .utf8) ?? "<non-utf8>"
            throw Error.pkcs12BuildFailed(code: proc.terminationStatus, stderr: msg)
        }
        return out
    }
}
