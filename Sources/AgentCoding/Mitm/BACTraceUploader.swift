import Foundation
import Security
import SandboxEngine

/// Ships detailed per-request HTTP logs from the MITM proxy to the
/// analytics service, in the *same wire shape the Bromure Web browser
/// uses* (`SandboxEngine.TraceEvent` + the `/ingest` envelope), so AC
/// traffic lands in the shared ClickHouse `session_events` store and
/// renders in the exact same admin session view as web-browser logs.
///
/// It plugs into `TraceStore.uploader`, so it sees every `TraceRecord`
/// the proxy emits along with the raw (already header-redacted) request
/// / response bytes. Records convert to `TraceEvent`s, buffer per
/// `(sessionID, profileID)`, and POST in batches over mTLS.
///
/// Auth mirrors `BACCloudUploader`: the install's org-CA-signed leaf via
/// `BACMTLSDelegate`. The target is `/ac-http-ingest` (a sibling of
/// `/ac-ingest`) — an org-CA endpoint that writes into `session_events`
/// with the install's tenancy.
///
/// Gating: only runs while the Mac is enrolled (the engine tears the
/// uploader down on unenroll), and drops records for any profile in
/// private mode. The per-record *fidelity* is whatever the profile's
/// `TraceLevel` already captured — metadata only, or metadata + bodies.
public final class BACTraceUploader: TraceUploader, @unchecked Sendable {
    // Where to POST. `/ac-http-ingest`, derived from the ac-events
    // endpoint (same host, same mTLS), overridable for dev/staging.
    public static var defaultHTTPIngestURL: URL {
        if let env = ProcessInfo.processInfo.environment["BROMURE_AC_HTTP_INGEST_URL"],
           let u = URL(string: env) { return u }
        if let s = UserDefaults.standard.string(forKey: "managed.acHttpIngestURL"),
           let u = URL(string: s) { return u }
        let base = BACEnrollment.defaultAnalyticsURL   // …/ac-ingest
        return base.deletingLastPathComponent().appendingPathComponent("ac-http-ingest")
    }

    // MARK: Tunables
    /// Max events per POST envelope. The server accepts up to 10k; 200
    /// matches the Web uploader and keeps a POST comfortably small.
    private let maxBatch = 200
    /// Drop the oldest buffered events past this to bound memory during
    /// a network outage.
    private let maxBufferedEvents = 5000
    private let flushIntervalSec: TimeInterval = 5
    private let maxRetries = 4
    /// Backstop on envelopes awaiting a successful POST during a sustained
    /// outage. Drops newest past this — the in-flight head (index 0) is
    /// always preserved so the send/complete bookkeeping stays consistent.
    private let maxPendingEnvelopes = 200
    /// Per-body ceiling. Bodies over this ship truncated — keeps a POST
    /// bounded even when the trace level captured a 5 MB response.
    private static let maxUploadBodyBytes = 256 * 1024

    // MARK: State (all touched only on `queue`)
    private let queue = DispatchQueue(label: "io.bromure.ac.trace-upload", qos: .utility)
    private let endpoint: URL
    private let session: URLSession
    private let delegate: BACMTLSDelegate
    /// Buffered events keyed by "\(sessionID)|\(profileID)".
    private var groups: [String: Group] = [:]
    /// Envelopes converted from `groups` and awaiting a successful POST.
    private var pending: [Envelope] = []
    private var privateProfileIDs: Set<UUID> = []
    private var bufferedCount = 0
    private var isFlushing = false
    private var isClosed = false
    private var flushTimer: DispatchSourceTimer?

    private struct Group {
        let sessionID: UUID
        let profileID: UUID
        var events: [TraceEvent]
        var hasBodies: Bool
    }
    private struct Envelope {
        let sessionID: UUID
        let profileID: UUID
        let level: String
        let events: [TraceEvent]
    }

    public init(endpoint: URL? = nil) {
        self.endpoint = endpoint ?? Self.defaultHTTPIngestURL
        self.delegate = BACMTLSDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        startFlushTimer()
    }

    // MARK: TraceUploader

    public func upload(_ record: TraceRecord, requestBody: Data?, responseBody: Data?) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.privateProfileIDs.contains(record.profileID) { return }
            let event = self.makeEvent(from: record,
                                       requestBody: requestBody,
                                       responseBody: responseBody)
            let key = "\(record.sessionID.uuidString)|\(record.profileID.uuidString)"
            let hasBodies = requestBody != nil || responseBody != nil
            if var g = self.groups[key] {
                g.events.append(event)
                g.hasBodies = g.hasBodies || hasBodies
                self.groups[key] = g
            } else {
                self.groups[key] = Group(sessionID: record.sessionID,
                                         profileID: record.profileID,
                                         events: [event], hasBodies: hasBodies)
            }
            self.bufferedCount += 1
            self.trimIfNeeded()
            if self.bufferedCount >= self.maxBatch { self.flushLocked() }
        }
    }

    // MARK: Control (from the engine, on enroll/unenroll/private-mode)

    public func setPrivateProfiles(_ ids: Set<UUID>) {
        queue.async { self.privateProfileIDs = ids }
    }

    public func shutdown() {
        queue.async {
            self.isClosed = true
            self.flushTimer?.cancel()
            self.flushTimer = nil
        }
        session.finishTasksAndInvalidate()
    }

    // MARK: Buffering / flush (queue-isolated)

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushIntervalSec, repeating: flushIntervalSec)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        flushTimer = t
    }

    /// Drop oldest groups whole when the buffer overflows. Coarse, but a
    /// sustained outage means telemetry, not user data — at-least-recent
    /// visibility is the goal.
    private func trimIfNeeded() {
        guard bufferedCount > maxBufferedEvents else { return }
        // Remove arbitrary groups until under the cap. Dictionary order
        // is unspecified but that's fine for a memory backstop.
        for (key, g) in groups {
            bufferedCount -= g.events.count
            groups.removeValue(forKey: key)
            if bufferedCount <= maxBufferedEvents { break }
        }
        if bufferedCount < 0 { bufferedCount = 0 }
    }

    /// Convert any buffered groups into envelopes, then POST the head of
    /// the pending queue. Must run on `queue`.
    private func flushLocked() {
        if !groups.isEmpty {
            for (_, g) in groups {
                let level = g.hasBodies ? "full" : "basic"
                // Chunk each group so no single POST exceeds maxBatch.
                var idx = 0
                while idx < g.events.count {
                    let slice = Array(g.events[idx..<min(idx + maxBatch, g.events.count)])
                    pending.append(Envelope(sessionID: g.sessionID,
                                            profileID: g.profileID,
                                            level: level, events: slice))
                    idx += maxBatch
                }
            }
            groups.removeAll()
            bufferedCount = 0
        }
        if pending.count > maxPendingEnvelopes {
            // Drop newest (never index 0, the in-flight head) so a long
            // outage can't grow the queue without bound.
            let overflow = pending.count - maxPendingEnvelopes
            pending.removeLast(overflow)
            FileHandle.standardError.write(Data(
                "[bac/trace-upload] pending backlog over \(maxPendingEnvelopes); dropped \(overflow) newest envelope(s)\n".utf8))
        }
        guard !isFlushing, let next = pending.first else { return }
        isFlushing = true
        send(next, attempt: 1)
    }

    private func send(_ env: Envelope, attempt: Int) {
        // Re-check enrollment at send time. Lost between enqueue and now
        // ⇒ drop the batch; a future enrollment starts clean.
        guard let install = BACEnrollmentStore.load() else {
            if !pending.isEmpty { pending.removeFirst() }
            isFlushing = false
            if !pending.isEmpty { flushLocked() }
            return
        }
        let body = encodeEnvelope(env, install: install)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(install.installId, forHTTPHeaderField: "X-Bromure-Install")
        req.setValue(install.orgSlug, forHTTPHeaderField: "X-Bromure-Org")
        req.httpBody = body

        let task = session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let ok = err == nil && (200...299).contains(code)
            self.queue.async {
                if ok {
                    if !self.pending.isEmpty { self.pending.removeFirst() }
                    self.isFlushing = false
                    if !self.pending.isEmpty { self.flushLocked() }
                } else if attempt >= self.maxRetries {
                    // Give up on this batch to unblock the queue.
                    if !self.pending.isEmpty { self.pending.removeFirst() }
                    self.isFlushing = false
                    FileHandle.standardError.write(Data(
                        "[bac/trace-upload] dropping \(env.events.count) events after \(attempt) attempts (HTTP \(code))\n".utf8))
                    if !self.pending.isEmpty { self.flushLocked() }
                } else {
                    // Backoff 1,2,4,8 s ± 20% jitter (index-varied, no RNG on the hot path).
                    let base = pow(2.0, Double(attempt - 1))
                    let jitter = Double(env.events.count % 5) / 10.0 - 0.2
                    let delay = base * (1.0 + jitter)
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, !self.isClosed else { self?.isFlushing = false; return }
                        self.send(env, attempt: attempt + 1)
                    }
                }
            }
        }
        task.resume()
    }

    private func encodeEnvelope(_ env: Envelope, install: BACInstall) -> Data {
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
            installId: install.installId,
            orgSlug: install.orgSlug,
            userEmail: install.userEmail,
            sessionId: env.sessionID.uuidString.lowercased(),
            profileId: env.profileID.uuidString.lowercased(),
            level: env.level,
            events: env.events)
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    // MARK: TraceRecord → TraceEvent

    /// Reconstruct an absolute URL from the proxy's host/port/path. The
    /// MITM only ever sees https (:443) or plain http (:80); a non-standard
    /// port is kept explicit.
    static func requestURL(host: String, port: Int, path: String) -> String {
        let scheme = port == 80 ? "http" : "https"
        let hostPort = (port == 443 || port == 80) ? host : "\(host):\(port)"
        return "\(scheme)://\(hostPort)\(path)"
    }

    private func makeEvent(from r: TraceRecord,
                           requestBody: Data?,
                           responseBody: Data?) -> TraceEvent {
        let url = Self.requestURL(host: r.host, port: r.port, path: r.path)

        var reqHeaders: [String: String]? = nil
        var postData: String? = nil
        if let requestBody,
           let parsed = Self.parseHTTPMessage(requestBody) {
            reqHeaders = parsed.headers.isEmpty ? nil : parsed.headers
            if let b = parsed.body {
                postData = Self.redactBody(b, contentType: parsed.contentType)
            }
        }

        var resHeaders: [String: String]? = nil
        var responseBodyStr: String? = nil
        var responseTruncated: Bool? = nil
        var mimeType: String? = nil
        if let responseBody,
           let parsed = Self.parseHTTPMessage(responseBody) {
            resHeaders = parsed.headers.isEmpty ? nil : parsed.headers
            mimeType = parsed.contentType
            if let b = parsed.body {
                responseBodyStr = Self.redactBody(b, contentType: parsed.contentType)
            } else if parsed.hadBodyBytes {
                // Body present but not decodable/too big — flag it so the
                // admin view shows "(truncated)" rather than silence.
                responseTruncated = true
            }
            if parsed.truncated { responseTruncated = true }
        }

        return TraceEvent(
            id: r.id.uuidString.lowercased(),
            timestamp: r.timestamp.timeIntervalSince1970,
            method: r.method,
            url: url,
            statusCode: r.statusCode == 0 ? nil : r.statusCode,
            duration: r.latencyMs / 1000.0,
            requestHeaders: reqHeaders,
            responseHeaders: resHeaders,
            postData: postData,
            responseBody: responseBodyStr,
            responseBodyTruncated: responseTruncated,
            mimeType: mimeType,
            initiator: nil,
            tabId: nil,
            errorText: nil,
            hostname: r.host,
            documentUrl: nil,
            frameUrl: nil,
            navType: nil,
            redirectFrom: nil,
            formFields: nil)
    }

    // MARK: Raw HTTP parsing

    struct ParsedMessage {
        var headers: [String: String]
        var body: String?
        var contentType: String?
        var truncated: Bool
        var hadBodyBytes: Bool
    }

    /// Split a raw HTTP message (start line + headers + body) into a
    /// header dict and a decoded body string. De-chunks a
    /// `Transfer-Encoding: chunked` body; the proxy already stripped
    /// `Content-Encoding`, so no decompression is needed here.
    static func parseHTTPMessage(_ raw: Data) -> ParsedMessage? {
        guard !raw.isEmpty else { return nil }
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            // Not a framed message — treat the whole thing as a body.
            let s = String(data: raw, encoding: .utf8)
            return ParsedMessage(headers: [:], body: s, contentType: nil,
                                 truncated: false, hadBodyBytes: !raw.isEmpty)
        }
        let headData = raw.subdata(in: raw.startIndex..<sep.lowerBound)
        var bodyData = raw.subdata(in: sep.upperBound..<raw.endIndex)
        guard let headStr = String(data: headData, encoding: .utf8)
                ?? String(data: headData, encoding: .ascii) else { return nil }

        var lines = headStr.components(separatedBy: "\r\n")
        if !lines.isEmpty { lines.removeFirst() }   // drop request/status line
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            headers[name] = value
        }

        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value

        if let te = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?
            .value.lowercased(), te.contains("chunked") {
            bodyData = dechunk(bodyData) ?? bodyData
        }

        let hadBodyBytes = !bodyData.isEmpty
        var truncated = false
        if bodyData.count > maxUploadBodyBytes {
            bodyData = bodyData.prefix(maxUploadBodyBytes)
            truncated = true
        }
        let body: String? = bodyData.isEmpty ? nil : String(data: bodyData, encoding: .utf8)
        return ParsedMessage(headers: headers, body: body, contentType: contentType,
                             truncated: truncated, hadBodyBytes: hadBodyBytes)
    }

    /// Decode HTTP/1.1 chunked transfer-encoding into the raw payload.
    static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        var guardCounter = 0
        while i < data.endIndex {
            guardCounter += 1
            if guardCounter > 100_000 { return out }   // pathological input backstop
            guard let lineEnd = data.range(of: crlf, options: [], in: i..<data.endIndex) else { break }
            let sizeLine = data.subdata(in: i..<lineEnd.lowerBound)
            guard let sizeStr = String(data: sizeLine, encoding: .ascii) else { break }
            let hex = sizeStr.split(separator: ";").first.map(String.init) ?? sizeStr
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { break }
            if size == 0 { break }
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) else { break }
            out.append(data.subdata(in: chunkStart..<chunkEnd))
            // Skip the CRLF that follows each chunk.
            i = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    // MARK: Body secret redaction (defense-in-depth over header redaction)

    private static let secretKeyPatterns = [
        "password", "passwd", "pwd", "secret", "token",
        "api_key", "apikey", "authorization", "auth_token", "credential",
    ]
    private static let redactionMask = "***"
    private static let maxJSONDepth = 64

    private static func isSecretKey(_ name: String) -> Bool {
        if name.isEmpty { return false }
        let l = name.lowercased()
        return secretKeyPatterns.contains { l.contains($0) }
    }

    static func redactBody(_ body: String, contentType: String?) -> String {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("application/x-www-form-urlencoded") { return redactURLEncoded(body) }
        if ct.contains("application/json") || ct.contains("+json") { return redactJSON(body) }
        return body
    }

    private static func redactURLEncoded(_ body: String) -> String {
        let pairs = body.split(separator: "&", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(pairs.count)
        for pair in pairs {
            let s = String(pair)
            guard let eq = s.firstIndex(of: "=") else { out.append(s); continue }
            let rawName = String(s[..<eq])
            let rawValue = String(s[s.index(after: eq)...])
            let decodedName = rawName.removingPercentEncoding ?? rawName
            out.append(isSecretKey(decodedName) ? "\(rawName)=\(redactionMask)" : "\(rawName)=\(rawValue)")
        }
        return out.joined(separator: "&")
    }

    private static func redactJSON(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return body }
        let scrubbed = redactJSONValue(obj, depth: 0)
        guard let out = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8) else { return body }
        return s
    }

    private static func redactJSONValue(_ value: Any, depth: Int) -> Any {
        if depth >= maxJSONDepth { return redactionMask }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = isSecretKey(k) ? redactionMask : redactJSONValue(v, depth: depth + 1)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactJSONValue($0, depth: depth + 1) }
        }
        return value
    }
}
