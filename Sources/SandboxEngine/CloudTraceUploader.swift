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
        redactSecrets(&e)
        return e
    }

    // MARK: - Secret redaction

    /// Placeholder that replaces redacted values. Analysts still see that
    /// a field was present, just not its content.
    static let redactionMask = "***"

    /// Hard ceilings — redaction runs on the uploader queue and must
    /// never spike CPU or stack on adversarial input.
    private static let maxBodyBytes = 256 * 1024
    private static let maxJSONDepth = 64
    private static let maxHeaderValueBytes = 8 * 1024

    /// Names we treat as secret regardless of where they appear. Matched
    /// case-insensitively against decoded name; substrings count so
    /// `new_password`, `password_confirmation`, `my_api_key` all hit.
    /// Stored already-lowercased to avoid re-lowercasing per check.
    private static let secretNamePatterns: [String] = [
        "password", "passwd", "pwd",
        "secret", "token", "api_key", "apikey",
        "authorization", "auth_token",
        "credential",
    ]

    /// Full-header names whose entire value we redact (they don't fit
    /// the "name pattern on an inner key" shape — the header value IS
    /// the secret).
    private static let secretHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
    ]

    @inline(__always)
    private static func isSecretName(_ name: String) -> Bool {
        // Short-circuit on empty — happens a lot with form bodies.
        if name.isEmpty { return false }
        let lower = name.lowercased()
        for p in secretNamePatterns where lower.contains(p) { return true }
        return false
    }

    /// Scrub password-shaped values out of an event in place. Run on
    /// every event before it's uploaded, regardless of level — the call
    /// sites above nil-out the fields at lower levels anyway, but it's
    /// cheaper to belt-and-suspenders than risk leaking because someone
    /// adds a new level above `.headers`.
    ///
    /// Guarantees (for airtightness):
    /// * Never traps. Every parse failure falls back to returning a
    ///   safe value (either the input unchanged, or fully masked).
    /// * Never recurses unbounded — JSON depth is capped.
    /// * Never chews CPU on pathological payloads — bodies over
    ///   `maxBodyBytes` are masked wholesale instead of parsed.
    private static func redactSecrets(_ e: inout TraceEvent) {
        // 1. Headers — outright sensitive header values.
        e.requestHeaders = redactHeaders(e.requestHeaders)
        e.responseHeaders = redactHeaders(e.responseHeaders)

        // 2. form fields — any input typed password, plus any named like one.
        if let fields = e.formFields {
            e.formFields = fields.map { f in
                if f.type.lowercased() == "password" || isSecretName(f.name) {
                    return TraceEvent.FormFieldSnapshot(name: f.name, type: f.type, value: redactionMask)
                }
                return f
            }
        }

        // 3. request body — parse by content-type and redact secret keys.
        if let body = e.postData {
            if body.utf8.count > maxBodyBytes {
                // Too big to parse safely — mask wholesale. Better to
                // drop content than risk leaking via partial parse or
                // DoS on the upload queue.
                e.postData = redactionMask
            } else {
                let ct = contentType(from: e.requestHeaders) ?? ""
                if ct.contains("application/x-www-form-urlencoded") {
                    e.postData = redactURLEncoded(body)
                } else if ct.contains("application/json") || ct.contains("+json") {
                    e.postData = redactJSON(body)
                }
                // Multipart + other content types are left alone — a
                // per-format parser would be needed to avoid
                // corrupting the body.
            }
        }
    }

    private static func redactHeaders(_ headers: [String: String]?) -> [String: String]? {
        guard let headers else { return nil }
        var out: [String: String] = [:]
        out.reserveCapacity(headers.count)
        for (k, v) in headers {
            if secretHeaderNames.contains(k.lowercased()) {
                out[k] = redactionMask
            } else if v.utf8.count > maxHeaderValueBytes {
                // Overlong header values are almost always attack
                // surface — mask rather than ship.
                out[k] = redactionMask
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func contentType(from headers: [String: String]?) -> String? {
        guard let headers else { return nil }
        for (k, v) in headers where k.lowercased() == "content-type" { return v.lowercased() }
        return nil
    }

    private static func redactURLEncoded(_ body: String) -> String {
        // Manual parse — URLComponents.percentEncodedQuery asserts on
        // any body it can't parse (raw '#', unescaped reserved chars,
        // malformed %XX, etc.). Browsers POST a wide range of
        // malformed-but-consumable bodies.
        let pairs = body.split(separator: "&", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(pairs.count)
        for pair in pairs {
            let s = String(pair)
            guard let eq = s.firstIndex(of: "=") else {
                out.append(s)
                continue
            }
            let rawName = String(s[..<eq])
            let rawValue = String(s[s.index(after: eq)...])
            // Match on the decoded name so `user%2Fpassword` still hits,
            // but keep the wire form of the name in the output so we
            // don't accidentally re-encode it differently than the
            // browser sent it.
            let decodedName = rawName.removingPercentEncoding ?? rawName
            if isSecretName(decodedName) {
                out.append("\(rawName)=\(redactionMask)")
            } else {
                out.append("\(rawName)=\(rawValue)")
            }
        }
        return out.joined(separator: "&")
    }

    private static func redactJSON(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return body }
        let scrubbed = redactJSONValue(obj, depth: 0)
        guard let out = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8)
        else { return body }
        return s
    }

    /// Depth-capped recursion: past `maxJSONDepth`, mask the subtree
    /// rather than keep walking. Adversarial nesting can't crash us.
    private static func redactJSONValue(_ value: Any, depth: Int) -> Any {
        if depth >= maxJSONDepth { return redactionMask }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = isSecretName(k) ? redactionMask : redactJSONValue(v, depth: depth + 1)
            }
            return out
        }
        if let arr = value as? [Any] {
            var out: [Any] = []
            out.reserveCapacity(arr.count)
            for v in arr { out.append(redactJSONValue(v, depth: depth + 1)) }
            return out
        }
        return value
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
            do {
                let identity = try AnalyticsMTLSIdentity.identity(for: profileId)
                let cred = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, cred)
            } catch {
                print("[CloudTraceUploader] no mTLS identity for profile \(profileId): \(error)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Builds a `SecIdentity` from *exactly* the leaf cert and private key
/// that were issued for a given managed profile — without ever writing to
/// a file-based keychain, which means no unlock prompts, no Keychain
/// Access entries, no interference with the user's login keychain.
///
/// The cert + PKCS#8 private key are packaged into a PKCS#12 blob
/// entirely in memory by `PKCS12Builder`, then handed to
/// `SecPKCS12Import` with no `kSecImportExportKeychain` option. Per the
/// Security framework contract, items in that case "will not be written
/// to any keychain and will only be accessible via references returned
/// by this function" — so the resulting `SecIdentity` is a pure
/// in-memory reference. The identity is cached per-profile so the
/// packaging only runs once per process.
///
/// History: this used to live in the user's login keychain (random
/// identities got picked for mTLS challenges, and every sign op popped
/// an ACL prompt), then briefly in a process-private file-based keychain
/// in `$TMPDIR` (which still prompted the user for the keychain
/// password), and briefly went through `/usr/bin/openssl`. All gone —
/// no `SecKeychain` is created, and no subprocess is spawned.
public enum AnalyticsMTLSIdentity {
    enum Error: Swift.Error {
        case missingMaterial
        case invalidCertificate
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
    /// destroy-local-state / leaf rotation so a stale SecIdentity isn't
    /// served on the next mTLS handshake.
    public static func purge(profileId: UUID) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: profileId)
    }

    private static func buildIdentity(for profileId: UUID) throws -> SecIdentity {
        let certURL = ManagedProfileStore.shared.mtlsCertURL(for: profileId)
        guard let certPem = try? String(contentsOf: certURL, encoding: .utf8),
              let certDer = derFromPEM(certPem, type: "CERTIFICATE")
        else { throw Error.invalidCertificate }

        guard let privKey = try? ManagedProfileSync.shared.loadMTLSPrivateKey(for: profileId) else {
            throw Error.missingMaterial
        }
        // Use `pkcs8DERRepresentation` (PrivateKeyInfo), NOT
        // `derRepresentation` (RSAPrivateKey / PKCS#1) — the shrouded
        // key bag in PKCS#12 encrypts a PKCS#8 plaintext, and
        // SecPKCS12Import won't pair an RSAPrivateKey-shaped blob with
        // its cert.
        let keyDer = privKey.pkcs8DERRepresentation

        // Random per-invocation PKCS#12 password. We're both producer and
        // consumer; it never leaves this function.
        var pwdBytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, pwdBytes.count, &pwdBytes)
        let password = Data(pwdBytes).base64EncodedString()

        let pkcs12 = PKCS12Builder.build(
            certDER: certDer, privateKeyDER: keyDer, password: password)

        // No `kSecImportExportKeychain` option ⇒ items stay in memory,
        // referenced only by the returned identity.
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

    private static func derFromPEM(_ pem: String, type: String) -> Data? {
        let begin = "-----BEGIN \(type)-----"
        let end = "-----END \(type)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex)
        else { return nil }
        let b64 = pem[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(b64))
    }
}
