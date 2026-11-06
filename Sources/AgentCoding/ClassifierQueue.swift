import Foundation

/// Where an on-device detector model stands, asked without waiting for it.
enum ModelReadiness: Equatable, Sendable {
    /// Loaded: a scan runs now.
    case ready
    /// Being loaded (seconds, at first use or after an idle release).
    case loading
    /// Still loading past `warmupGrace`: a request no longer gets "try
    /// again" (an agent's retries run out), it waits for the load as before.
    case loadingLong
    /// Not installed, or it failed to load: the scan goes on without it.
    case absent

    static let warmupGrace: TimeInterval = 30

    static func loading(since start: Date, now: Date = Date()) -> ModelReadiness {
        now.timeIntervalSince(start) < warmupGrace ? .loading : .loadingLong
    }
}

/// The queue a detector's load and inference run on. Both block for a long
/// time — an ONNX session over a few hundred MB takes seconds to build — and
/// an actor's default executor is one of Swift concurrency's shared threads
/// (one per core): a load there held it, and with them the async work of the
/// whole app (see `MitmBlockingExecutor`). A dispatch queue's thread is its
/// own. Each platform supplies the queue itself (`Executor`, `make`):
/// macOS's is a DispatchSerialQueue (ClassifierLifecycle.swift).
enum ClassifierQueue {
    /// Run a load's blocking part on a thread of its own, leaving the
    /// detector's queue free meanwhile: a request asking `readiness()` while
    /// the model loads is answered "loading" at once, not after the load.
    static func load<T>(_ label: String, _ body: @escaping () throws -> T) async throws -> T {
        let box = LoadBox<T>()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "io.bromure.classifier.\(label).load", qos: .userInitiated).async {
                box.result = Result { try body() }
                c.resume()
            }
        }
        return try box.result!.get()
    }
}

extension ClassifierQueue {
    /// Run async work that blocks (a library's load, ~1 s) with a thread of
    /// its own (`MitmBlockingExecutor`), not one of the shared pool's: the
    /// nonisolated async code it calls runs there. macOS 14 has no task
    /// executors: there it runs as before.
    static func offPool<T>(_ body: () async throws -> T) async rethrows -> T {
        if #available(macOS 15.0, *) {
            return try await withTaskExecutorPreference(MitmBlockingExecutor.shared) { try await body() }
        }
        return try await body()
    }
}

/// Carries a load's result back from its thread (the continuation's
/// resume is the hand-off).
private final class LoadBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
