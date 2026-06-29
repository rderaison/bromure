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
    func serverArgs(model: String, host: String, port: Int, apiKey: String,
                    toolParser: String, reasoningParser: String?) -> [String] {
        switch self {
        case .vllmMLX:
            // Tool calling is OFF unless explicitly enabled with a parser —
            // without this the model never emits tool_use blocks (verified
            // live: Qwen + hermes works, no flag = plain text).
            var args = ["serve", model, "--host", host, "--port", String(port),
                        "--api-key", apiKey, "--enable-metrics",
                        "--enable-auto-tool-choice", "--tool-call-parser", toolParser]
            // Reasoning models: extract <think> into reasoning_content instead
            // of leaking it into the visible answer.
            if let rp = reasoningParser, !rp.isEmpty {
                args += ["--reasoning-parser", rp]
            }
            return args
        }
    }

    /// Multi-model arguments: serve a registry of models from one process
    /// (vllm-mlx lazy-loads them and LRU-evicts under the registry's memory
    /// budget). Clients request a model by its registry `name`.
    func serverArgsMulti(configPath: String, host: String, port: Int, apiKey: String) -> [String] {
        switch self {
        case .vllmMLX:
            // Per-model parsers live in the registry; "auto" lets the engine
            // pick each model's parser. (--enable-auto-tool-choice requires a
            // global --tool-call-parser.)
            return ["serve", "--models-config", configPath,
                    "--host", host, "--port", String(port),
                    "--api-key", apiKey, "--continuous-batching", "--enable-metrics",
                    "--enable-auto-tool-choice", "--tool-call-parser", "auto"]
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
    public var toolParser: String
    public var reasoningParser: String?
    public init(name: String, repo: String, estMemGB: Int,
                toolParser: String = "auto", reasoningParser: String? = nil) {
        self.name = name; self.repo = repo; self.estMemGB = estMemGB
        self.toolParser = toolParser; self.reasoningParser = reasoningParser
    }
}

/// The model set + budget the parent hands the spawned engine child via a
/// config file. Codable so `bromure-ac _mlx-engine --config <path>` can read it.
public struct EngineSpawnConfig: Codable, Sendable {
    public struct Model: Codable, Sendable {
        public var repo: String
        public var estMemGB: Int
        public var toolParser: String
        public var reasoningParser: String?
    }
    public var memoryBudgetGB: Int
    public var models: [Model]

    public init(memoryBudgetGB: Int, models: [Model]) {
        self.memoryBudgetGB = memoryBudgetGB; self.models = models
    }

    /// The `InferenceModel`s the engine child should serve.
    public var inferenceModels: [InferenceModel] {
        models.map { InferenceModel(name: $0.repo, repo: $0.repo, estMemGB: $0.estMemGB,
                                    toolParser: $0.toolParser, reasoningParser: $0.reasoningParser) }
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

    /// Per-app-run random Bearer key the engine requires. Generated once in the
    /// main app and shared by the engine child + every Bromure-injected client
    /// (guest configs, Fusion). The forked engine child inherits it via the
    /// `BROMURE_ENGINE_KEY` env var so it authenticates the parent's clients.
    nonisolated(unsafe) public static let apiKey: String = {
        if let inherited = ProcessInfo.processInfo.environment["BROMURE_ENGINE_KEY"],
           !inherited.isEmpty {
            return inherited
        }
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return "brk-" + bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Env var carrying the parent's key into the spawned engine process.
    static let engineKeyEnvVar = "BROMURE_ENGINE_KEY"

    /// Synchronously terminate the engine child if running. Safe from a signal
    /// handler (runs on the main queue) and from app teardown.
    nonisolated public static func killIfRunning() {
        let pid = runningPID
        if pid > 0 { kill(pid, SIGTERM); runningPID = 0 }
    }

    public let engine: InferenceEngine
    private let catalog: CatalogStore
    private var activeModels: [String] = []   // repos currently served (sorted)
    /// The spawned engine child (`bromure-ac _mlx-engine`). Out-of-process so an
    /// OOM/jetsam kill of a too-large model load takes down only the engine, not
    /// the app and its VMs.
    private var process: Process?
    private var lastConfig: EngineSpawnConfig?
    private var restartCount = 0
    /// Tees the engine child's stdout/stderr into the Inference Engine Log.
    /// Retained for the child's lifetime; replaced on each (re)spawn.
    private var engineLogReader: PipeLineReader?

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
        toolParser: String = "auto",
        reasoningParser: String? = nil,
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
                                         apiKey: apiKey, toolParser: toolParser,
                                         reasoningParser: reasoningParser),
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
        let m = catalog.resolve(modelRepo)
        let model = InferenceModel(
            name: modelRepo, repo: modelRepo,
            estMemGB: m?.minUnifiedMemGB ?? 0,
            toolParser: m?.toolParser ?? "auto", reasoningParser: m?.reasoningParser)
        return try await startServing([model], memoryBudgetGB: 0)
    }

    /// Ensure the engine is serving *all* of `models` (parallel models, one
    /// process — vllm-mlx lazy-loads + LRU-evicts under `memoryBudgetGB`).
    /// Restarts if the set of models changed.
    @discardableResult
    public func ensureRunning(models: [InferenceModel],
                              memoryBudgetGB: Int,
                              timeout: TimeInterval = 120,
                              onProvisionProgress: @escaping (String) -> Void = { _ in }) async throws -> EngineLaunchPlan {
        return try await startServing(models, memoryBudgetGB: memoryBudgetGB)
    }

    /// Start (or update) the engine child serving `models`, fronted by the
    /// tool-call repair proxy. Restarts the child if the model set changed.
    /// Returns a stub plan (callers use it only for the readiness URL).
    private func startServing(_ models: [InferenceModel], memoryBudgetGB: Int) async throws -> EngineLaunchPlan {
        // Move any models the old hf CLI left in ~/.cache into the local layout
        // (once, idempotent) so the engine child loads only from there.
        catalog.migrateLegacyHubCache()
        let repos = models.map(\.repo).sorted()
        if isRunning, activeModels == repos { return stubPlan() }
        if isRunning { stop() }
        let cfg = EngineSpawnConfig(
            memoryBudgetGB: memoryBudgetGB,
            models: models.map { .init(repo: $0.repo, estMemGB: $0.estMemGB,
                                       toolParser: $0.toolParser, reasoningParser: $0.reasoningParser) })
        try await spawnEngine(config: cfg, repos: repos, timeout: 120)
        return stubPlan()
    }

    /// Spawn `bromure-ac _mlx-engine` (our own binary, engine mode) on the
    /// loopback engine port and wait until it answers. Out-of-process so a model
    /// load that OOMs jetsams only the child; the parent + VMs survive and the
    /// child is restarted (capped) by `onEngineExit`.
    private func spawnEngine(config: EngineSpawnConfig, repos: [String], timeout: TimeInterval) async throws {
        guard let exe = Bundle.main.executableURL
                ?? (CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }) else {
            throw InferenceServiceError.engineNotFound
        }
        let cfgURL = catalog.modelsDir.deletingLastPathComponent()
            .appendingPathComponent("engine-spawn.json")
        try JSONEncoder().encode(config).write(to: cfgURL, options: .atomic)

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["model", "_mlx-engine", "--config", cfgURL.path]
        var env = ProcessInfo.processInfo.environment
        env[Self.engineKeyEnvVar] = Self.apiKey            // parent's admin key
        env[EngineKey.masterEnvVar] = EngineKey.masterHex  // so the child can verify per-VM keys
        proc.environment = env

        // Tee the engine child's stdout+stderr into the Inference Engine Log
        // (Window → Inference Engine Log…) so model-load / "serving" / OOM /
        // error lines are visible without Console. The buffer also mirrors each
        // line to our stderr, preserving the prior bromure-ac.log behavior.
        let logPipe = Pipe()
        proc.standardOutput = logPipe
        proc.standardError = logPipe
        let reader = PipeLineReader { InferenceLog.shared.record($0) }
        reader.attach(to: logPipe.fileHandleForReading)
        self.engineLogReader = reader

        proc.terminationHandler = { [weak self] p in
            Task { await self?.onEngineExit(p) }
        }
        InferenceLog.shared.record("[inference] starting engine for: \(repos.joined(separator: ", "))")
        try proc.run()
        self.process = proc
        self.activeModels = repos
        self.lastConfig = config
        Self.runningPID = proc.processIdentifier

        try await waitUntilReady(deadline: Date().addingTimeInterval(timeout))
        restartCount = 0   // healthy boot resets the crash-loop counter
        InferenceRepairProxy.shared.startIfNeeded(enginePort: Self.enginePort)
        InferenceLog.shared.record(
            "[inference] engine ready on port \(Self.enginePort) — serving \(repos.count) model(s).")
    }

    /// Engine-child termination handler. Restarts on an unexpected exit (a
    /// crash / OOM-kill), capped so a model that always OOMs doesn't loop.
    private func onEngineExit(_ exited: Process) async {
        guard exited === process else { return }   // superseded by a clean stop/switch
        process = nil
        Self.runningPID = 0
        guard let cfg = lastConfig, !activeModels.isEmpty else { return }
        guard restartCount < 3 else {
            InferenceLog.shared.record(
                "[inference] engine child crashed repeatedly — giving up (a model likely OOMs this Mac)")
            return
        }
        restartCount += 1
        InferenceLog.shared.record(
            "[inference] engine child exited (OOM?); restarting (\(restartCount)/3)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        try? await spawnEngine(config: cfg, repos: activeModels, timeout: 120)
    }

    private func waitUntilReady(deadline: Date) async throws {
        var req = URLRequest(url: URL(string: "http://\(Self.engineHost):\(Self.enginePort)/v1/models")!)
        req.timeoutInterval = 5
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        while Date() < deadline {
            if (process?.isRunning ?? false) == false { throw InferenceServiceError.startTimedOut }
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw InferenceServiceError.startTimedOut
    }

    private func stubPlan() -> EngineLaunchPlan {
        EngineLaunchPlan(executableURL: URL(fileURLWithPath: "/dev/null"),
                         arguments: [], environment: [:],
                         host: Self.engineHost, port: Self.enginePort)
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
            s += "    tool_call_parser: \"\(m.toolParser)\"\n"
            if let rp = m.reasoningParser, !rp.isEmpty {
                s += "    reasoning_parser: \"\(rp)\"\n"
            }
            s += "    estimated_memory_gb: \(m.estMemGB)\n"
        }
        return s
    }

    /// Graceful teardown (called on app exit). Clears `process` first so the
    /// termination handler doesn't treat this as a crash and restart.
    public func stop() {
        let p = process
        process = nil
        activeModels = []
        lastConfig = nil
        Self.runningPID = 0
        p?.terminate()
    }

    /// Reap a leftover engine child from a previous run (a SIGKILL leaves it
    /// orphaned, holding the weights' RAM and the engine port). Run once at app
    /// launch, before starting our own. Matches our own binary in `_mlx-engine`
    /// mode so it never touches an unrelated process.
    nonisolated public static func reapOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "_mlx-engine --config"]
        try? p.run(); p.waitUntilExit()
    }
}
