import Foundation

/// What an HF repo actually contains — decides whether we can serve it.
public enum RepoKind: Equatable, Sendable {
    case mlx          // MLX safetensors + config — loadable by vllm-mlx
    case gguf         // GGUF — the Ollama/llama.cpp path, NOT loadable here
    case unknown      // neither marker found

    public var loadable: Bool { self == .mlx }
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case notMLX(RepoKind)      // rejected before download (§5.5)
    case repoNotFound
    case downloadFailed(String)
    case toolMissing
    /// Refused up front: the models volume can't hold the weights + headroom.
    case insufficientDiskSpace(availableBytes: UInt64, requiredBytes: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notMLX(let kind):
            if kind == .gguf {
                return "That's a GGUF (Ollama/llama.cpp) model — Bromure serves MLX weights only."
            }
            return "That repo has no MLX safetensors + config.json, so it can't be served here."
        case .repoNotFound:
            return "That model repo wasn't found on Hugging Face."
        case .downloadFailed(let detail):
            return "Download failed: \(detail)"
        case .toolMissing:
            return "The download tool is missing."
        case .insufficientDiskSpace(let avail, let need):
            func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_000_000_000) }
            return "Not enough disk space: \(gb(avail)) free, but about \(gb(need)) is needed. "
                 + "Free up space and try again."
        }
    }
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

    // MARK: - Disk-space preflight

    /// Throw `insufficientDiskSpace` if the models volume can't hold a download
    /// of `expectedBytes` (the catalog's `download_gb`) plus a safety margin,
    /// after crediting whatever's already on disk for this repo (a resumed pull
    /// only needs the remainder). Fails open if free space can't be read — a
    /// stat hiccup shouldn't block a download.
    ///
    /// `expectedBytes == 0` (the `org/repo` escape hatch, whose size isn't in
    /// the catalog) still enforces the bare safety margin, so a near-full disk
    /// is caught even when the exact size is unknown.
    public static func checkDiskSpace(repo: String, expectedBytes: Int64,
                                      store: CatalogStore = .shared) throws {
        guard let free = DiskSpace.freeBytes(at: store.localModelDirectory(for: repo)) else { return }
        let need = DiskSpace.requiredBytes(forWriting: max(0, expectedBytes),
                                           alreadyOnDisk: store.installedBytes(repo: repo))
        if free < UInt64(need) {
            throw DownloadError.insufficientDiskSpace(availableBytes: free, requiredBytes: UInt64(need))
        }
    }

    // MARK: - Pull

    /// Validate, then pull the repo's weights into the local models dir via the
    /// pure-Swift `HubDownloader` (no Python `hf` CLI). `expectedBytes` (the
    /// catalog download size, 0 if unknown) gates a disk-space preflight before
    /// any bytes are fetched. `onProgress` receives status lines; fine-grained
    /// progress is read off disk by the download manager. Cancellable via the
    /// enclosing Task.
    public static func pull(repo: String,
                            expectedBytes: Int64 = 0,
                            validating: Bool = true,
                            session: URLSession = .shared,
                            onProgress: @escaping (String) -> Void = { _ in }) async throws {
        // Local + instant: fail fast on a full disk before touching the network.
        try checkDiskSpace(repo: repo, expectedBytes: expectedBytes)
        if validating {
            let kind = try await validate(repo: repo, session: session)
            guard kind.loadable else { throw DownloadError.notMLX(kind) }
        }
        let dest = CatalogStore.shared.localModelDirectory(for: repo)
        // Drop the in-progress sentinel; cleared only on full success below. If
        // this pull is killed or crashes, the sentinel survives so the partial
        // is detected as interrupted on next launch and never read as installed
        // (Bug#2/#3). A user-initiated cancel deletes the whole dir instead.
        CatalogStore.shared.beginDownload(repo: repo)
        try await HubDownloader.downloadModel(
            repo: repo, into: dest, session: session, onProgress: onProgress)
        CatalogStore.shared.finishDownload(repo: repo)
    }
}
