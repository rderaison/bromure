import Foundation

/// What an HF repo actually contains — decides whether we can serve it.
public enum RepoKind: Equatable, Sendable {
    case mlx          // MLX safetensors + config — loadable by vllm-mlx
    case gguf         // GGUF — the Ollama/llama.cpp path, NOT loadable here
    case unknown      // neither marker found

    public var loadable: Bool { self == .mlx }
}

public enum DownloadError: Error, Equatable {
    case notMLX(RepoKind)      // rejected before download (§5.5)
    case repoNotFound
    case downloadFailed(String)
    case toolMissing
}

/// Validates and pulls pre-converted MLX weights straight from Hugging
/// Face (§5.6 — no conversion, ever). Validation is pure + testable;
/// the pull shells out to `huggingface-cli` / `hf` with progress.
public enum ModelDownloader {

    // MARK: - Validation (pure)

    /// Classify a repo from its file listing (HF `siblings`). MLX wins if
    /// there are `.safetensors` + a `config.json`; GGUF is rejected with a
    /// clear "that's an ollama model" message upstream.
    public static func classify(siblings: [String]) -> RepoKind {
        let lower = siblings.map { $0.lowercased() }
        let hasSafetensors = lower.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = lower.contains { $0 == "config.json" }
        let hasGGUF = lower.contains { $0.hasSuffix(".gguf") }
        if hasSafetensors && hasConfig { return .mlx }
        if hasGGUF { return .gguf }
        return .unknown
    }

    /// Query the HF API and classify a repo before any bytes are pulled.
    public static func validate(repo: String,
                                session: URLSession = .shared) async throws -> RepoKind {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw DownloadError.repoNotFound
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(from: url)
        } catch {
            throw DownloadError.downloadFailed("\(error)")
        }
        guard let http = resp as? HTTPURLResponse else {
            throw DownloadError.repoNotFound
        }
        if http.statusCode == 404 { throw DownloadError.repoNotFound }
        guard http.statusCode == 200 else {
            throw DownloadError.downloadFailed("HTTP \(http.statusCode)")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let siblings = (obj?["siblings"] as? [[String: Any]])?
            .compactMap { $0["rfilename"] as? String } ?? []
        return classify(siblings: siblings)
    }

    // MARK: - Pull

    /// Resolve the `huggingface-cli` / `hf` downloader. Prefers the
    /// provisioned engine venv (`hf` ships as an `mlx-lm` dependency), then
    /// `PATH`.
    public static func resolveDownloader(
        env: [String: String] = ProcessInfo.processInfo.environment,
        provisioner: EngineProvisioner = .shared,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let venvBin = provisioner.venvBin.path
        for name in ["hf", "huggingface-cli"] where fileExists("\(venvBin)/\(name)") {
            return URL(fileURLWithPath: "\(venvBin)/\(name)")
        }
        for dir in (env["PATH"] ?? "/usr/local/bin:/usr/bin:/opt/homebrew/bin").split(separator: ":") {
            for name in ["hf", "huggingface-cli"] where fileExists("\(dir)/\(name)") {
                return URL(fileURLWithPath: "\(dir)/\(name)")
            }
        }
        return nil
    }

    /// Download args for the resolved tool. `hf download <repo>` (new CLI)
    /// and `huggingface-cli download <repo>` (legacy) share the verb.
    public static func downloadArgs(repo: String) -> [String] {
        ["download", repo]
    }

    /// Validate then pull. `onProgress` receives raw CLI progress lines.
    public static func pull(repo: String,
                            validating: Bool = true,
                            session: URLSession = .shared,
                            onProgress: @escaping (String) -> Void = { _ in }) async throws {
        if validating {
            let kind = try await validate(repo: repo, session: session)
            guard kind.loadable else { throw DownloadError.notMLX(kind) }
        }
        guard let tool = resolveDownloader() else { throw DownloadError.toolMissing }

        let proc = Process()
        proc.executableURL = tool
        proc.arguments = downloadArgs(repo: repo)
        // Unbuffered so the tqdm progress lines stream live (otherwise the
        // pipe buffers and progress appears to jump 0 → 100 at the end).
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
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
            throw DownloadError.downloadFailed("exit \(proc.terminationStatus)")
        }
    }
}
