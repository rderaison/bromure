import Foundation

/// Process-wide in-memory ring buffer of log lines, with a `tail -f`-style live
/// stream for SwiftUI viewers. The reusable core behind the diagnostics windows
/// (the inference-engine log; the Security Log keeps its own bespoke
/// `SupplyChainLog` for now). Each `record()` optionally mirrors to stderr so
/// the existing `bromure-ac.log` / terminal output is preserved, and pushes the
/// entry to every subscriber.
///
/// Thread-safety: every public call lock-guards the internal state. Subscribers
/// receive entries via an `AsyncStream`; the continuation lives until the
/// consumer's Task is cancelled.
public final class LogBuffer: @unchecked Sendable {
    public struct Entry: Sendable, Identifiable {
        public let id: UInt64
        public let date: Date
        public let message: String
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var buffer: [Entry] = []
    private var continuations: [UUID: AsyncStream<Entry>.Continuation] = [:]
    private let cap: Int

    /// `cap` bounds the ring so a long-running session can't grow it unbounded.
    public init(cap: Int = 5_000) { self.cap = cap }

    /// Append a line. `message` should be a single line; a trailing newline is
    /// trimmed (and re-added when mirroring to stderr).
    public func record(_ message: String, mirrorToStderr: Bool = true) {
        let trimmed = message.hasSuffix("\n") ? String(message.dropLast()) : message
        if mirrorToStderr {
            FileHandle.standardError.write(Data((trimmed + "\n").utf8))
        }
        lock.lock()
        nextID &+= 1
        let entry = Entry(id: nextID, date: Date(), message: trimmed)
        buffer.append(entry)
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(entry) }
    }

    /// History snapshot — rendered first, before subscribing to the live stream.
    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Live stream of entries appended *after* this call. Pair with `snapshot()`.
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

    /// Wipe the buffer (the viewer's "Clear" button). Already-streamed entries a
    /// viewer is showing are unaffected; the viewer clears its own copy too.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}

/// The inference engine's log sink: the out-of-process MLX engine child's
/// stdout/stderr (model load, "serving", OOM/crash, errors) plus the parent's
/// engine-lifecycle events, captured for the `Window → Inference Engine Log…`
/// viewer so diagnostics don't require Console.app.
public enum InferenceLog {
    public static let shared = LogBuffer()
}

/// Reads a pipe's file handle and forwards complete lines to `onLine`, holding
/// a partial trailing line across reads (chunk boundaries don't fall on
/// newlines). Install on a child process's `Pipe.fileHandleForReading` to tee
/// its stdout/stderr into a ``LogBuffer``. The reader must be retained for the
/// lifetime of the pipe; it self-detaches on EOF.
public final class PipeLineReader: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private var partial = Data()

    public init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    public func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }   // EOF
            self?.feed(chunk)
        }
    }

    private func feed(_ data: Data) {
        partial.append(data)
        let nl = UInt8(ascii: "\n")
        while let idx = partial.firstIndex(of: nl) {
            let line = partial.subdata(in: partial.startIndex..<idx)
            partial.removeSubrange(partial.startIndex...idx)
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { onLine(s) }
        }
    }
}
