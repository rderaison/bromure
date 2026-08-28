import Foundation

/// File-backed cache of engine-reported model metadata — context length plus
/// the capability flags (vision/thinking) — keyed "engine-base|model-id". The
/// launch-time probe writes it asynchronously; guest-config staging reads it
/// synchronously: agents size compaction off the context number, and omp
/// gates image input on the vision flag (a wrong/absent value means a wasted
/// half-window or a client-side "not a vision model" refusal). A staging-time
/// cache miss (first boot against a new server/model) does one short-capped
/// synchronous probe so even the first session gets real metadata when the
/// server answers fast; on timeout the caller's defaults apply and the async
/// probe heals the cache for the next restage.
enum EngineModelMeta {
    private static let lock = NSLock()
    private static var loaded: [String: ExternalEngine.ModelMeta]?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("engine-model-meta.json")
    }

    private static func key(_ base: URL, _ model: String) -> String {
        base.absoluteString.lowercased() + "|" + model
    }

    private static func table() -> [String: ExternalEngine.ModelMeta] {
        if let loaded { return loaded }
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        var t = (try? JSONDecoder().decode([String: ExternalEngine.ModelMeta].self, from: data)) ?? [:]
        if t.isEmpty, let legacy = try? JSONDecoder().decode([String: Int].self, from: data) {
            // Pre-capabilities cache shape: bare context lengths.
            t = legacy.mapValues { ExternalEngine.ModelMeta(context: $0) }
        }
        loaded = t
        return t
    }

    /// Cached metadata, or nil when this (server, model) pair was never
    /// probed successfully.
    static func meta(base: URL, model: String) -> ExternalEngine.ModelMeta? {
        lock.lock(); defer { lock.unlock() }
        return table()[key(base, model)]
    }

    static func setMeta(_ m: ExternalEngine.ModelMeta, base: URL, model: String) {
        lock.lock(); defer { lock.unlock() }
        var t = table()
        guard t[key(base, model)] != m else { return }
        t[key(base, model)] = m
        loaded = t
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Probe `base` for `model`'s metadata and cache the result. Async
    /// fire-and-forget from the launch path; `waitUpTo` > 0 makes it
    /// synchronous with that cap (the staging-time first-boot case).
    @discardableResult
    static func refresh(base: URL, apiKey: String?, model: String,
                        waitUpTo: TimeInterval = 0) -> ExternalEngine.ModelMeta? {
        let sema = waitUpTo > 0 ? DispatchSemaphore(value: 0) : nil
        nonisolated(unsafe) var result: ExternalEngine.ModelMeta?
        Task.detached(priority: .utility) {
            if let m = await ExternalEngine.modelMeta(
                base: base, apiKey: apiKey, model: model,
                timeout: waitUpTo > 0 ? waitUpTo : 10) {
                setMeta(m, base: base, model: model)
                result = m
            }
            sema?.signal()
        }
        _ = sema?.wait(timeout: .now() + waitUpTo)
        return result
    }
}
