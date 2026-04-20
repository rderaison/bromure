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
/// session construction time. When the managed profile's `cloudTrace.enabled`
/// is true the user cannot turn it off — recording is forced on and the
/// session-window toggle becomes read-only. That policy is enforced by the
/// call site, not here.
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
/// managed profile's issued leaf cert. Identity lookup is lazy: the first
/// time this session opens a connection, we load cert+key into the default
/// Keychain under a stable label and query a `SecIdentity` back.
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

/// Converts the on-disk cert PEM + Keychain-resident DER PKCS#8 private key
/// into a `SecIdentity` usable as a URL credential. Imports both items into
/// the user's default Keychain on first call, then queries the identity by
/// a stable per-profile label on subsequent calls. Kept in this file (not in
/// ManagedProfileSync) because this particular import path is only needed
/// for host-side HTTPS — the guest-side NSS-DB install uses raw PEM.
enum AnalyticsMTLSIdentity {
    enum Error: Swift.Error {
        case missingMaterial
        case importFailed(OSStatus)
        case queryFailed(OSStatus)
    }

    private static let labelPrefix = "io.bromure.app.analytics-mtls"

    static func identity(for profileId: UUID) throws -> SecIdentity {
        let label = "\(labelPrefix).\(profileId.uuidString.lowercased())"
        if let existing = queryIdentity(label: label) { return existing }
        try importToKeychain(label: label, profileId: profileId)
        guard let ready = queryIdentity(label: label) else {
            throw Error.queryFailed(errSecItemNotFound)
        }
        return ready
    }

    private static func queryIdentity(label: String) -> SecIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &result)
        guard s == errSecSuccess else { return nil }
        // SecIdentity is typed as AnyObject here; force the CFTypeID-safe cast.
        return (result as! SecIdentity)
    }

    private static func importToKeychain(label: String, profileId: UUID) throws {
        let certURL = ManagedProfileStore.shared.mtlsCertURL(for: profileId)
        guard let certPem = try? String(contentsOf: certURL, encoding: .utf8) else {
            throw Error.missingMaterial
        }
        guard let privKey = try? ManagedProfileSync.shared.loadMTLSPrivateKey(for: profileId) else {
            throw Error.missingMaterial
        }
        let keyPem = privKey.pemRepresentation
        guard let blob = (certPem + "\n" + keyPem).data(using: .utf8) else {
            throw Error.missingMaterial
        }
        var format: SecExternalFormat = .formatPEMSequence
        var itemType: SecExternalItemType = .itemTypeAggregate
        var importedItems: CFArray?
        let opts: SecItemImportExportFlags = []
        var keyParams = SecItemImportExportKeyParameters()
        let status = SecItemImport(
            blob as CFData,
            nil, &format, &itemType,
            opts, &keyParams, nil, &importedItems,
        )
        guard status == errSecSuccess, let items = importedItems as? [AnyObject] else {
            throw Error.importFailed(status)
        }
        // Tag each imported ref with our label + persist to default keychain.
        // We ignore duplicate-item errors so a second session for the same
        // profile doesn't error out noisily.
        for item in items {
            let attrs: [String: Any] = [
                kSecValueRef as String: item,
                kSecAttrLabel as String: label,
            ]
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
                throw Error.importFailed(addStatus)
            }
        }
    }
}
