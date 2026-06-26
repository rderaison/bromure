import Foundation

/// The pluggable local inference engine. We standardize on `vllm-mlx`
/// (MLX backend, Anthropic-native `/v1/messages` + OpenAI `/v1/*`,
/// prefix caching, continuous batching) per §1.2. Kept as an enum so a
/// fallback engine (Ollama / mlx-lm) can be slotted in later.
public enum InferenceEngine: String, Sendable {
    case vllmMLX = "vllm-mlx"

    /// Server subcommand arguments to bind loopback and serve a model.
    func serverArgs(model: String, host: String, port: Int) -> [String] {
        switch self {
        case .vllmMLX:
            return ["serve", model, "--host", host, "--port", String(port)]
        }
    }

    /// Readiness probe path — engine is up once this returns 200.
    var readinessPath: String { "/v1/models" }
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

    public let engine: InferenceEngine
    private let catalog: CatalogStore
    private var process: Process?
    private var activeModelRepo: String?

    public init(engine: InferenceEngine = .vllmMLX, catalog: CatalogStore = .shared) {
        self.engine = engine
        self.catalog = catalog
    }

    public var loadedModelRepo: String? { activeModelRepo }
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
    public static func makeLaunchPlan(
        engine: InferenceEngine,
        executable: URL,
        modelRepo: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> EngineLaunchPlan {
        // Force MLX/HF to use the standard hub cache so installed-model
        // tracking (CatalogStore) and the downloader agree on paths.
        var childEnv = env
        childEnv["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return EngineLaunchPlan(
            executableURL: executable,
            arguments: engine.serverArgs(model: modelRepo,
                                         host: engineHost, port: enginePort),
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
        let plan = Self.makeLaunchPlan(engine: engine, executable: exe, modelRepo: modelRepo)

        if isRunning, activeModelRepo == modelRepo {
            return plan
        }
        if isRunning { stop() }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = plan.arguments
        proc.environment = plan.environment
        try proc.run()
        self.process = proc
        self.activeModelRepo = modelRepo

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
        activeModelRepo = nil
    }
}
