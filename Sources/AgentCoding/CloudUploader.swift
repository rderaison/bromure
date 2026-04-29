import Foundation
import SandboxEngine

/// Batches `BACCloudEvent`s and POSTs them to
/// /v1/installs/:installId/ac-events on bromure.io.
///
/// In-memory only: dropping buffered events on a hard quit is fine for
/// telemetry, and a disk-backed retry queue is a Phase 3c-or-later
/// problem. Up to 200 events / 30 s in flight at once. Failures are
/// logged but don't drop the buffer — the next flush retries the
/// whole batch.
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

    public init() {
        flushTask = Task { [weak self] in
            await self?.flushLoop()
        }
    }

    public func enqueue(_ event: BACCloudEvent) {
        var shouldKick = false
        lock.lock()
        pending.append(event)
        if pending.count >= flushHighWatermark { shouldKick = true }
        // Hard cap: if a long network outage piles up more than a
        // couple of multiples of the server limit, drop the oldest
        // half. Keeping the buffer unbounded would eat memory; an
        // admin gets at-least-recent visibility either way.
        let drainCap = maxBatch * 4
        if pending.count > drainCap {
            pending.removeFirst(pending.count - drainCap / 2)
        }
        lock.unlock()
        if shouldKick { Task { await self.flushNow() } }
    }

    public func shutdown() {
        lock.lock()
        stopped = true
        lock.unlock()
        flushTask?.cancel()
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
        var batch: [BACCloudEvent] = []
        lock.lock()
        if !pending.isEmpty {
            let take = min(pending.count, maxBatch)
            batch = Array(pending.prefix(take))
        }
        let isStopped = stopped
        lock.unlock()
        if isStopped { return }
        if batch.isEmpty { return }

        guard let install = BACEnrollmentStore.load(),
              let token = BACEnrollmentStore.loadInstallToken() else {
            // Lost enrollment between enqueue and flush. Drop the
            // batch — a future enrollment will start fresh.
            lock.lock()
            pending.removeFirst(min(pending.count, batch.count))
            lock.unlock()
            return
        }

        do {
            try await postBatch(batch, install: install, bearer: token)
            // Success: drop the prefix that matched what we sent.
            lock.lock()
            pending.removeFirst(min(pending.count, batch.count))
            lock.unlock()
        } catch {
            // Leave `pending` intact for the next flush. Log so
            // operator can spot a sustained failure (e.g. expired
            // bearer token) without a disk-backed retry queue.
            FileHandle.standardError.write(Data(
                "[bac/uploader] flush of \(batch.count) events failed: \(error)\n".utf8))
        }
    }

    private func postBatch(_ events: [BACCloudEvent], install: BACInstall, bearer: String) async throws {
        var req = URLRequest(url: install.serverURL.appendingPathComponent(
            "v1/installs/\(install.installId)/ac-events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(["events": events])
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BAC.Uploader", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
    }
}
