import Foundation

/// File-backed cache of engine-reported model metadata (today: the context
/// length), keyed "engine-base|model-id". The launch-time probe writes it
/// asynchronously; guest-config staging reads it synchronously — agents size
/// compaction off this number, and a wrong default (128k for a 256k model)
/// silently wastes half the window. A staging-time cache miss (first boot
/// against a new server/model) does one short-capped synchronous probe so
/// even the first session sees the real window when the server answers fast;
/// on timeout the caller's default applies and the async probe heals the
/// cache for the next restage.
enum EngineModelMeta {
    private static let lock = NSLock()
    private static var loaded: [String: Int]?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("engine-model-meta.json")
    }

    private static func key(_ base: URL, _ model: String) -> String {
        base.absoluteString.lowercased() + "|" + model
    }

    private static func table() -> [String: Int] {
        if let loaded { return loaded }
        let t = (try? JSONDecoder().decode([String: Int].self,
                                           from: Data(contentsOf: fileURL))) ?? [:]
        loaded = t
        return t
    }

    /// Cached context length, or nil when this (server, model) pair was never
    /// probed successfully.
    static func contextLength(base: URL, model: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return table()[key(base, model)]
    }

    static func setContextLength(_ n: Int, base: URL, model: String) {
        lock.lock(); defer { lock.unlock() }
        var t = table()
        guard t[key(base, model)] != n else { return }
        t[key(base, model)] = n
        loaded = t
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Probe `base` for `model`'s context length and cache the result.
    /// Async fire-and-forget from the launch path; `waitUpTo` > 0 makes it
    /// synchronous with that cap (the staging-time first-boot case).
    @discardableResult
    static func refresh(base: URL, apiKey: String?, model: String,
                        waitUpTo: TimeInterval = 0) -> Int? {
        let sema = waitUpTo > 0 ? DispatchSemaphore(value: 0) : nil
        nonisolated(unsafe) var result: Int?
        Task.detached(priority: .utility) {
            if let n = await ExternalEngine.contextLength(
                base: base, apiKey: apiKey, model: model,
                timeout: waitUpTo > 0 ? waitUpTo : 10) {
                setContextLength(n, base: base, model: model)
                result = n
            }
            sema?.signal()
        }
        _ = sema?.wait(timeout: .now() + waitUpTo)
        return result
    }
}
