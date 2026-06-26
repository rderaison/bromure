import Foundation

public enum EngineProvisionError: Error, Equatable {
    case uvNotFound
    case venvFailed(String)
    case installFailed(String)
}

/// Provisions the `vllm-mlx` engine on demand using a bundled `uv` (§3.1,
/// decided: uv + on-demand venv). Rather than baking a ~1 GB venv into the
/// signed `.app`, we ship one tiny static `uv` binary and, on first
/// local-inference use, build a pinned venv into Application Support —
/// the same on-demand pattern `PromptInjectionModels` uses for ML models.
///
/// Reproducible (pinned requirements), offline after the first run, and the
/// app stays small. The host process loads the venv's unsigned dylibs via
/// the `cs.disable-library-validation` entitlement (the venv lives outside
/// the app signature).
public final class EngineProvisioner: @unchecked Sendable {
    public static let shared = EngineProvisioner()

    /// `~/Library/Application Support/BromureAC/engine` — the venv root.
    public let engineDir: URL

    public init(supportDir: URL? = nil) {
        let support = supportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
        self.engineDir = support.appendingPathComponent("engine", isDirectory: true)
    }

    public var venvBin: URL { engineDir.appendingPathComponent("bin", isDirectory: true) }
    public var vllmExecutable: URL { venvBin.appendingPathComponent("vllm-mlx") }
    public var venvPython: URL { venvBin.appendingPathComponent("python") }

    public var isProvisioned: Bool {
        FileManager.default.isExecutableFile(atPath: vllmExecutable.path)
    }

    /// Rough installed footprint of the venv (Python 3.12 + mlx + mlx-lm +
    /// vllm-mlx + deps). Used as the denominator for a determinate install
    /// progress bar driven by polling the venv dir as it grows.
    public static let estimatedInstallBytes: Int64 = 2_300_000_000

    /// Current bytes on disk under the engine venv (best-effort recursive).
    public var installedBytes: Int64 { Self.directoryBytes(engineDir) }

    /// Recursive size of a directory in bytes; 0 if it doesn't exist yet.
    public static func directoryBytes(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - uv resolution

    /// Resolve the `uv` installer. Preference: `BROMURE_UV` env override →
    /// bundled `Resources/bin/uv` (signed with the app) → `PATH`.
    public static func resolveUV(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle? = .main,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let override = env["BROMURE_UV"], fileExists(override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundle?.resourceURL?
            .appendingPathComponent("bin/uv").path, fileExists(bundled) {
            return URL(fileURLWithPath: bundled)
        }
        for dir in (env["PATH"] ?? "/usr/local/bin:/usr/bin:/opt/homebrew/bin").split(separator: ":") {
            let candidate = "\(dir)/uv"
            if fileExists(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    // MARK: - Pinned requirements

    /// Default engine requirements. `vllm-mlx` is a community project (not on
    /// PyPI), so it's pulled from the Bromure-hosted wheel index published by
    /// `scripts/publish-spaces.sh`; its deps (`mlx`, `mlx-lm`) resolve from
    /// PyPI. The index hosts exactly the wheel we built, so an unpinned
    /// `vllm-mlx` resolves to that build. Overridable by a bundled or
    /// Application-Support `engine-requirements.txt`.
    public static let defaultRequirements = """
    # Bromure local MLX inference engine (vLLM.md §3.1).
    --extra-index-url https://dl.bromure.io/mlx/simple/
    vllm-mlx
    """

    /// The requirements to install: a bundled/App-Support override if present,
    /// else the built-in default.
    public func requirementsText(bundle: Bundle? = .main) -> String {
        let override = engineDir.deletingLastPathComponent()
            .appendingPathComponent("engine-requirements.txt")
        if let s = try? String(contentsOf: override, encoding: .utf8), !s.isEmpty { return s }
        if let res = bundle?.resourceURL?.appendingPathComponent("engine-requirements.txt"),
           let s = try? String(contentsOf: res, encoding: .utf8), !s.isEmpty { return s }
        return Self.defaultRequirements
    }

    /// The Python version uv provisions for the engine.
    public static let pythonVersion = "3.12"

    // MARK: - uv command builders (pure / testable)

    /// `uv python install <ver>` — fetch a standalone CPython. macOS has no
    /// guaranteed system `python3` (it ships only with Xcode's CLT), so we
    /// never rely on one: uv downloads a `python-build-standalone` build
    /// into its own data dir. This is how we "ship Python" without bundling
    /// a framework or requiring Xcode.
    public static func pythonInstallArgs(python: String = pythonVersion) -> [String] {
        ["python", "install", python]
    }

    /// `uv venv <dir> --python <ver> --python-preference only-managed` —
    /// build the venv against uv's own managed interpreter, never a
    /// system/Homebrew one (which may be absent or the wrong version).
    public static func venvArgs(dir: URL, python: String = pythonVersion) -> [String] {
        ["venv", dir.path, "--python", python, "--python-preference", "only-managed"]
    }

    /// `uv pip install --python <venv-python> -r <reqs>`.
    public static func pipInstallArgs(venvPython: URL, requirementsFile: URL) -> [String] {
        ["pip", "install", "--python", venvPython.path, "-r", requirementsFile.path]
    }

    // MARK: - Provision

    /// Create the venv and install the engine if not already present.
    /// Idempotent — a no-op once `vllm-mlx` resolves. `onProgress` receives
    /// raw uv output lines.
    public func ensureProvisioned(onProgress: @escaping (String) -> Void = { _ in }) async throws {
        if isProvisioned { return }
        guard let uv = Self.resolveUV() else { throw EngineProvisionError.uvNotFound }

        try? FileManager.default.createDirectory(
            at: engineDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write the resolved requirements next to the venv for reproducibility.
        let reqFile = engineDir.deletingLastPathComponent()
            .appendingPathComponent("engine-requirements.lock")
        try requirementsText().write(to: reqFile, atomically: true, encoding: .utf8)

        // Fetch a standalone CPython via uv — never depend on system/Xcode
        // Python (it isn't guaranteed to exist on macOS).
        onProgress("Fetching Python \(Self.pythonVersion) (standalone)…\n")
        try Self.run(uv, Self.pythonInstallArgs(),
                     onProgress: onProgress, mapError: EngineProvisionError.venvFailed)

        onProgress("Creating Python \(Self.pythonVersion) venv…\n")
        try Self.run(uv, Self.venvArgs(dir: engineDir),
                     onProgress: onProgress, mapError: EngineProvisionError.venvFailed)

        onProgress("Installing vllm-mlx + mlx (pinned)…\n")
        try Self.run(uv, Self.pipInstallArgs(venvPython: venvPython, requirementsFile: reqFile),
                     onProgress: onProgress, mapError: EngineProvisionError.installFailed)
    }

    private static func run(_ tool: URL, _ args: [String],
                            onProgress: @escaping (String) -> Void,
                            mapError: (String) -> EngineProvisionError) throws {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args
        // Unbuffered child output so any progress lines stream live rather
        // than arriving in one chunk at the end.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["UV_NO_PROGRESS"] = "0"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            onProgress(s)
        }
        try proc.run()
        proc.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            throw mapError("exit \(proc.terminationStatus)")
        }
    }
}
