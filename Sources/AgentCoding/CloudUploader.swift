import Foundation
import Security
import SandboxEngine

/// Batches `BACCloudEvent`s and POSTs them to the analytics service's
/// `/ac-ingest` endpoint over mTLS. The install authenticates with the
/// leaf cert issued from the workspace's org CA — no bearer token rides
/// with the data.
///
/// In-memory only: dropping buffered events on a hard quit is fine for
/// telemetry, and a disk-backed retry queue is a Phase 3c-or-later
/// problem. Up to 200 events / 5 s in flight at once. Failures are
/// logged but don't drop the buffer — the next flush retries the whole
/// batch.
public final class BACCloudUploader: @unchecked Sendable {
    /// Events to flush. Guarded by `lock`.
    private var pending: [BACCloudEvent] = []
    private let lock = NSLock()

    /// Cap matching the server-side `MAX_EVENTS_PER_BATCH`. Bumping
    /// this requires bumping the server too.
    private let maxBatch = 500
    /// Auto-flush threshold — when pending hits this, kick a flush
    /// without waiting for the timer.
    private let flushHighWatermark = 200
    /// Periodic flush interval. Long enough that a Claude turn that
    /// fires 5 events bundles them into one POST; short enough that
    /// the admin UI feels live.
    private let flushIntervalSec: TimeInterval = 5

    private var flushTask: Task<Void, Never>?
    /// Set by `shutdown()` to stop the periodic flush loop. Reads
    /// happen under `lock`.
    private var stopped = false

    /// Endpoint to POST batches to. Defaults to `analytics.bromure.io`,
    /// overridable via `BROMURE_AC_INGEST_URL` for dev/staging.
    private let endpoint: URL
    /// URLSession configured with the mTLS challenge handler. Held by
    /// the uploader so the connection pool / TLS session cache survives
    /// across flushes — re-handshaking on every batch would defeat the
    /// point of keeping the session warm.
    private let session: URLSession
    private let delegate: BACMTLSDelegate

    public convenience init() {
        self.init(endpoint: BACEnrollment.defaultAnalyticsURL)
    }

    public init(endpoint: URL) {
        self.endpoint = endpoint
        self.delegate = BACMTLSDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        flushTask = Task { [weak self] in
            await self?.flushLoop()
        }
    }

    public func enqueue(_ event: BACCloudEvent) {
        var shouldKick = false
        var pendingAfter = 0
        var dropped = 0
        lock.lock()
        pending.append(event)
        if pending.count >= flushHighWatermark { shouldKick = true }
        // Hard cap: if a long network outage piles up more than a
        // couple of multiples of the server limit, drop the oldest
        // half. Keeping the buffer unbounded would eat memory; an
        // admin gets at-least-recent visibility either way.
        let drainCap = maxBatch * 4
        if pending.count > drainCap {
            dropped = pending.count - drainCap / 2
            pending.removeFirst(dropped)
        }
        pendingAfter = pending.count
        lock.unlock()
        BACDebug.log("[bac/uploader]",
                     "enqueue eventType=\(event.eventType) pending=\(pendingAfter) dropped=\(dropped) shouldKick=\(shouldKick)")
        if shouldKick { Task { await self.flushNow() } }
    }

    public func shutdown() {
        lock.lock()
        stopped = true
        lock.unlock()
        flushTask?.cancel()
        session.finishTasksAndInvalidate()
    }

    private func flushLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(flushIntervalSec * 1_000_000_000))
            if Task.isCancelled { break }
            await flushNow()
        }
    }

    public func flushNow() async {
        // Pull a slice off the front (matched by maxBatch) and try
        // sending it. Holding the lock across the network call would
        // serialise enqueue → keep the lock briefly, copy out, then
        // POST without it.
        let (batch, isStopped): ([BACCloudEvent], Bool) = lock.withLock {
            var b: [BACCloudEvent] = []
            if !pending.isEmpty {
                let take = min(pending.count, maxBatch)
                b = Array(pending.prefix(take))
            }
            return (b, stopped)
        }
        if isStopped {
            BACDebug.log("[bac/uploader]", "flushNow noop (stopped)")
            return
        }
        if batch.isEmpty {
            BACDebug.log("[bac/uploader]", "flushNow noop (empty)")
            return
        }

        // Confirm the install is still enrolled and that we have an
        // mTLS identity to present. Either being absent means the next
        // POST would 401/403; bail early so the buffer survives until
        // enrollment / cert-rotation is back.
        guard BACEnrollmentStore.load() != nil else {
            // Lost enrollment between enqueue and flush. Drop the
            // batch — a future enrollment will start fresh.
            BACDebug.log("[bac/uploader]",
                         "flushNow drop \(batch.count) events (not enrolled)")
            lock.withLock {
                pending.removeFirst(min(pending.count, batch.count))
            }
            return
        }

        let postT0 = Date()
        BACDebug.log("[bac/uploader]",
                     "POST start endpoint=\(endpoint.absoluteString) events=\(batch.count)")
        do {
            try await postBatch(batch)
            BACDebug.log("[bac/uploader]",
                         "POST done events=\(batch.count) took=\(BACDebug.ms(postT0))")
            // Success: drop the prefix that matched what we sent.
            lock.withLock {
                pending.removeFirst(min(pending.count, batch.count))
            }
        } catch {
            BACDebug.log("[bac/uploader]",
                         "POST failed events=\(batch.count) took=\(BACDebug.ms(postT0)) error=\(error)")
            // Leave `pending` intact for the next flush. Log so an
            // operator can spot a sustained failure (expired leaf
            // cert, missing org CA, etc.) without a disk-backed retry
            // queue.
            FileHandle.standardError.write(Data(
                "[bac/uploader] flush of \(batch.count) events failed: \(error)\n".utf8))
        }
    }

    private func postBatch(_ events: [BACCloudEvent]) async throws {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(["events": events])
        req.httpBody = body
        BACDebug.log("[bac/uploader]",
                     "URLSession.data start bodyBytes=\(body.count)")
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        BACDebug.log("[bac/uploader]",
                     "URLSession.data done status=\(status)")
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "BAC.Uploader", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
    }
}

/// URLSession delegate that answers TLS client-cert challenges with the
/// install's leaf cert via `BACMTLSIdentity`. Server trust is left to
/// the system default — the analytics service uses an ACME-issued
/// public cert, so the regular root-store path applies.
private final class BACMTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            do {
                let identity = try BACMTLSIdentity.current()
                let cred = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, cred)
            } catch {
                FileHandle.standardError.write(Data(
                    "[bac/uploader] no mTLS identity: \(error)\n".utf8))
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
