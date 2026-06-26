import Foundation

/// The pluggable local inference engine. We standardize on `vllm-mlx`
/// (MLX backend, Anthropic-native `/v1/messages` + OpenAI `/v1/*`,
/// prefix caching, continuous batching) per §1.2. Kept as an enum so a
/// fallback engine (Ollama / mlx-lm) can be slotted in later.
public enum InferenceEngine: String, Sendable {
    case vllmMLX = "vllm-mlx"

    /// Server subcommand arguments to bind loopback and serve a model,
    /// gated behind a per-session API key (Bearer auth) since the engine is
    /// shared across VMs.
    func serverArgs(model: String, host: String, port: Int, apiKey: String) -> [String] {
        switch self {
        case .vllmMLX:
            return ["serve", model, "--host", host, "--port", String(port),
                    "--api-key", apiKey, "--enable-metrics"]
        }
    }

    /// Multi-model arguments: serve a registry of models from one process
    /// (vllm-mlx lazy-loads them and LRU-evicts under the registry's memory
    /// budget). Clients request a model by its registry `name`.
    func serverArgsMulti(configPath: String, host: String, port: Int, apiKey: String) -> [String] {
        switch self {
        case .vllmMLX:
            return ["serve", "--models-config", configPath,
                    "--host", host, "--port", String(port),
                    "--api-key", apiKey, "--continuous-batching", "--enable-metrics"]
        }
    }

    /// Readiness probe path — engine is up once this returns 200.
    var readinessPath: String { "/v1/models" }
}

/// One model in a multi-model engine registry. `name` is what clients
/// request (we use the repo, so existing model env/config still works);
/// `repo` is the HF repo to load; `estMemGB` is its resident footprint for
/// the budget/eviction accounting.
public struct InferenceModel: Equatable, Sendable {
    public var name: String
    public var repo: String
    public var estMemGB: Int
    public init(name: String, repo: String, estMemGB: Int) {
        self.name = name; self.repo = repo; self.estMemGB = estMemGB
    }
}

/// A fully-resolved plan for launching the engine subprocess. Pure data
/// so the resolution/arg-building is unit-testable without spawning.
public struct EngineLaunchPlan: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var host: String
    public var port: Int

    public var readinessURL: URL {
        URL(string: "http://\(host):\(port)/v1/models")!
    }
}

public enum InferenceServiceError: Error, Equatable {
    case engineNotFound
    case noModelSelected
    case startTimedOut
}

/// Supervises the local `vllm-mlx` server subprocess (§3.1).
///
/// - Single shared instance for all VMs — weights load once (decisive for
///   a ~100 GB GLM-5.2); continuous batching + prefix caching are shared.
/// - Binds `127.0.0.1:<enginePort>` only — never `0.0.0.0`.
/// - Lazy-start on first request; readiness via `/v1/models`.
/// - Auto-restart on crash; graceful teardown with the app.
public actor InferenceService {
    /// Host loopback port the engine binds. The guest reaches it as
    /// 127.0.0.1:11434 via the vsock 8446 bridge → here.
    public static let enginePort = 11434
    public static let engineHost = "127.0.0.1"

    /// Process-wide engine. Single shared instance (one model loaded) for
    /// now; the per-model pool + single-port model router come next.
    public static let shared = InferenceService()

    /// PID of the running engine, readable synchronously from a signal
    /// handler / `applicationWillTerminate` (where we can't await the
    /// actor). 0 = not running. The engine holds a lot of RAM, so killing
    /// it on exit matters more than for the idle ssh-agent.
    nonisolated(unsafe) public static var runningPID: pid_t = 0

    /// Per-app-run random API key the engine requires (vllm-mlx `--api-key`).
    /// Generated once and shared by the engine + every Bromure-injected
    /// client (guest configs, Fusion). Defense in depth: even though the
    /// engine is loopback + vsock-only, a stray host process can't use it
    /// without this key. Readable synchronously when writing guest configs.
    nonisolated(unsafe) public static let apiKey: String = {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return "brk-" + bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Synchronously terminate the engine if running. Safe from a signal
    /// handler (runs on the main queue) and from app teardown.
    nonisolated public static func killIfRunning() {
        let pid = runningPID
        if pid > 0 { kill(pid, SIGTERM); runningPID = 0 }
    }

    public let engine: InferenceEngine
    private let catalog: CatalogStore
    private var process: Process?
    private var activeModels: [String] = []   // repos currently served (sorted)

    public init(engine: InferenceEngine = .vllmMLX, catalog: CatalogStore = .shared) {
        self.engine = engine
        self.catalog = catalog
    }

    public var loadedModelRepos: [String] { activeModels }
    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Binary resolution

    /// Resolve the engine executable. Preference order:
    ///   1. `BROMURE_VLLM_MLX` env override (dev / tests)
    ///   2. the on-demand venv provisioned by `EngineProvisioner` into
    ///      Application Support (the standard path, §3.1 decided)
    ///   3. `vllm-mlx` on `PATH`
    public static func resolveExecutable(
        env: [String: String] = ProcessInfo.processInfo.environment,
        provisioner: EngineProvisioner = .shared,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let override = env["BROMURE_VLLM_MLX"], fileExists(override) {
            return URL(fileURLWithPath: override)
        }
        if fileExists(provisioner.vllmExecutable.path) {
            return provisioner.vllmExecutable
        }
        for dir in (env["PATH"] ?? "/usr/local/bin:/usr/bin:/opt/homebrew/bin").split(separator: ":") {
            let candidate = "\(dir)/vllm-mlx"
            if fileExists(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Build the launch plan for a model repo. Pure — no spawning.
    /// `cached` skips vllm-mlx's startup HF check (it calls `snapshot_download`
    /// every launch — a no-op when present, but it still hits the HF API).
    public static func makeLaunchPlan(
        engine: InferenceEngine,
        executable: URL,
        modelRepo: String,
        cached: Bool = false,
        apiKey: String = InferenceService.apiKey,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> EngineLaunchPlan {
        // Force MLX/HF to use the standard hub cache so installed-model
        // tracking (CatalogStore) and the downloader agree on paths.
        var childEnv = env
        childEnv["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // Model already fully downloaded → serve straight from cache, no
        // network round-trip / "Downloading model…" log on every start.
        if cached { childEnv["HF_HUB_OFFLINE"] = "1" }
        return EngineLaunchPlan(
            executableURL: executable,
            arguments: engine.serverArgs(model: modelRepo,
                                         host: engineHost, port: enginePort,
                                         apiKey: apiKey),
            environment: childEnv,
            host: engineHost,
            port: enginePort)
    }

    // MARK: - Lifecycle

    /// Ensure the engine is up and serving `modelRepo`. Restarts if a
    /// different model is requested. Returns once `/v1/models` answers 200.
    @discardableResult
    public func ensureRunning(modelRepo: String,
                              timeout: TimeInterval = 120,
                              onProvisionProgress: @escaping (String) -> Void = { _ in }) async throws -> EngineLaunchPlan {
        // Provision the engine on first use (uv + on-demand venv, §3.1).
        if Self.resolveExecutable() == nil {
            try await EngineProvisioner.shared.ensureProvisioned(onProgress: onProvisionProgress)
        }
        guard let exe = Self.resolveExecutable() else {
            throw InferenceServiceError.engineNotFound
        }
        let cached = catalog.isInstalled(repo: modelRepo)
        let plan = Self.makeLaunchPlan(engine: engine, executable: exe,
                                       modelRepo: modelRepo, cached: cached)
        return try await launch(plan: plan, exe: exe, repos: [modelRepo], timeout: timeout)
    }

    /// Ensure the engine is serving *all* of `models` (parallel models, one
    /// process — vllm-mlx lazy-loads + LRU-evicts under `memoryBudgetGB`).
    /// Restarts if the set of models changed.
    @discardableResult
    public func ensureRunning(models: [InferenceModel],
                              memoryBudgetGB: Int,
                              timeout: TimeInterval = 120,
                              onProvisionProgress: @escaping (String) -> Void = { _ in }) async throws -> EngineLaunchPlan {
        if models.count <= 1, let only = models.first {
            return try await ensureRunning(modelRepo: only.repo, timeout: timeout,
                                           onProvisionProgress: onProvisionProgress)
        }
        if Self.resolveExecutable() == nil {
            try await EngineProvisioner.shared.ensureProvisioned(onProgress: onProvisionProgress)
        }
        guard let exe = Self.resolveExecutable() else {
            throw InferenceServiceError.engineNotFound
        }
        // Write the registry, then launch with --models-config.
        let configURL = EngineProvisioner.shared.engineDir
            .deletingLastPathComponent().appendingPathComponent("models.yaml")
        try Self.makeModelsYAML(models: models, memoryBudgetGB: memoryBudgetGB)
            .write(to: configURL, atomically: true, encoding: .utf8)
        let allCached = models.allSatisfy { catalog.isInstalled(repo: $0.repo) }
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if allCached { childEnv["HF_HUB_OFFLINE"] = "1" }
        let plan = EngineLaunchPlan(
            executableURL: exe,
            arguments: engine.serverArgsMulti(configPath: configURL.path,
                                              host: Self.engineHost, port: Self.enginePort,
                                              apiKey: Self.apiKey),
            environment: childEnv, host: Self.engineHost, port: Self.enginePort)
        return try await launch(plan: plan, exe: exe,
                                repos: models.map(\.repo).sorted(), timeout: timeout)
    }

    /// Serialize the model registry YAML (the §model-registry schema).
    static func makeModelsYAML(models: [InferenceModel], memoryBudgetGB: Int) -> String {
        var s = """
        manager:
          memory_budget_gb: \(memoryBudgetGB)
          contention_policy:
            strategy: wait_then_preempt
            wait_timeout_s: 45
            preempt_after_s: 15

        models:

        """
        for m in models {
            s += "  - name: \"\(m.name)\"\n"
            s += "    model: \"\(m.repo)\"\n"
            s += "    continuous_batching: true\n"
            s += "    estimated_memory_gb: \(m.estMemGB)\n"
        }
        return s
    }

    /// Shared spawn + readiness for both single- and multi-model launches.
    private func launch(plan: EngineLaunchPlan, exe: URL,
                        repos: [String], timeout: TimeInterval) async throws -> EngineLaunchPlan {
        if isRunning, activeModels == repos { return plan }
        if isRunning { stop() }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = plan.arguments
        proc.environment = plan.environment
        try proc.run()
        self.process = proc
        self.activeModels = repos
        Self.runningPID = proc.processIdentifier

        try await waitUntilReady(url: plan.readinessURL, deadline: Date().addingTimeInterval(timeout))
        return plan
    }

    private func waitUntilReady(url: URL, deadline: Date) async throws {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        while Date() < deadline {
            if (process?.isRunning ?? false) == false {
                throw InferenceServiceError.startTimedOut
            }
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw InferenceServiceError.startTimedOut
    }

    /// Graceful teardown (called on app exit).
    public func stop() {
        process?.terminate()
        process = nil
        activeModels = []
        Self.runningPID = 0
    }
}
