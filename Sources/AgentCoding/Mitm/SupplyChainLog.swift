import Foundation

/// Process-wide in-memory ring buffer for every supply-chain log line
/// the MITM proxy emits. Each `record()` mirrors the message to stderr
/// (preserving the existing `bromure-ac.log` / terminal behavior) AND
/// pushes it to subscribers so the `Window → Supply Chain Log…` viewer
/// can `tail -f` it without scraping a file.
///
/// Thread-safety: every public call lock-guards the internal state.
/// Subscribers receive entries via an `AsyncStream`; we keep the
/// continuation alive until the consumer's Task is cancelled.
public final class SupplyChainLog: @unchecked Sendable {
    public struct Entry: Sendable, Identifiable {
        public let id: UInt64
        public let date: Date
        public let message: String
    }

    public static let shared = SupplyChainLog()

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var buffer: [Entry] = []
    private var continuations: [UUID: AsyncStream<Entry>.Continuation] = [:]
    /// Cap the ring at ~5k lines. A busy `npm install` of a transitive
    /// graph of 1000 packages × (socket → / ✓ / 451) tops out around
    /// 3k; 5k gives us a comfortable margin without bloating memory.
    private static let cap = 5_000

    private init() {}

    /// Add a line. `message` should be a single line with no trailing
    /// newline — we add one when mirroring to stderr.
    public func record(_ message: String, mirrorToStderr: Bool = true) {
        let trimmed: String
        if message.hasSuffix("\n") {
            trimmed = String(message.dropLast())
        } else {
            trimmed = message
        }
        if mirrorToStderr {
            FileHandle.standardError.write(Data((trimmed + "\n").utf8))
        }
        lock.lock()
        nextID &+= 1
        let entry = Entry(id: nextID, date: Date(), message: trimmed)
        buffer.append(entry)
        if buffer.count > Self.cap {
            buffer.removeFirst(buffer.count - Self.cap)
        }
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(entry) }
    }

    /// Snapshot the current buffer (history). Used by the viewer when
    /// it opens, so the user sees what already happened before
    /// subscribing to the live stream.
    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Live stream of new entries appended *after* this call. Pair
    /// with `snapshot()` to render the full history first.
    public func stream() -> AsyncStream<Entry> {
        AsyncStream { continuation in
            let token = UUID()
            lock.lock()
            continuations[token] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: token)
                self.lock.unlock()
            }
        }
    }

    /// Wipe the buffer (called by the "Clear" button in the viewer).
    /// Does not affect already-streamed entries the viewer is showing —
    /// the viewer also clears its local copy.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}
