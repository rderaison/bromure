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

    /// Validate, then pull the repo's weights into the local models dir via the
    /// pure-Swift `HubDownloader` (no Python `hf` CLI). `onProgress` receives
    /// status lines; fine-grained progress is read off disk by the download
    /// manager. Cancellable via the enclosing Task.
    public static func pull(repo: String,
                            validating: Bool = true,
                            session: URLSession = .shared,
                            onProgress: @escaping (String) -> Void = { _ in }) async throws {
        if validating {
            let kind = try await validate(repo: repo, session: session)
            guard kind.loadable else { throw DownloadError.notMLX(kind) }
        }
        let dest = CatalogStore.shared.localModelDirectory(for: repo)
        try await HubDownloader.downloadModel(
            repo: repo, into: dest, session: session, onProgress: onProgress)
    }
}
