import Foundation

/// Pure-Swift Hugging Face model downloader — the replacement for shelling out
/// to the Python `hf` CLI (which lived in the now-removed vllm-mlx venv).
///
/// Models land in a flat per-repo directory under
/// `~/Library/Application Support/BromureAC/models/<org>--<name>/` (config +
/// weights + tokenizer, no blob/symlink indirection), which is exactly what
/// `MLXEngine` loads with `loadModelContainer(directory:)`. Files stream to disk
/// via a URLSession data delegate (chunked writes — no multi-GB buffering), so
/// the on-disk size grows live for the download-progress poller. Resumable at
/// file granularity: a fully-present file is skipped on a re-run.
enum HubDownloader {
    /// Files we never need for serving — skip to save bytes.
    private static func skip(_ name: String) -> Bool {
        let l = name.lowercased()
        if l.hasPrefix(".git") { return true }
        for ext in [".md", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".gguf"] {
            if l.hasSuffix(ext) { return true }
        }
        return false
    }

    /// List the repo's files from the HF API (`siblings`).
    static func fileList(repo: String, session: URLSession) async throws -> [String] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw DownloadError.repoNotFound
        }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.repoNotFound }
        if http.statusCode == 404 { throw DownloadError.repoNotFound }
        guard http.statusCode == 200 else { throw DownloadError.downloadFailed("HTTP \(http.statusCode)") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let names = (obj?["siblings"] as? [[String: Any]])?
            .compactMap { $0["rfilename"] as? String } ?? []
        return names.filter { !skip($0) }
    }

    /// Download every serving file of `repo` into `destDir`. Idempotent: files
    /// already present (and not a leftover `.partial`) are skipped.
    static func downloadModel(repo: String, into destDir: URL,
                              session: URLSession = .shared,
                              onProgress: @escaping (String) -> Void = { _ in }) async throws {
        let files = try await fileList(repo: repo, session: session)
        guard !files.isEmpty else { throw DownloadError.repoNotFound }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        for file in files {
            try Task.checkCancellation()
            let dest = destDir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            // Nested paths (rare for MLX repos) — make the parent dirs.
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let url = URL(string:
                "https://huggingface.co/\(repo)/resolve/main/\(file)") else { continue }
            onProgress("fetching \(file)")
            try await downloadFile(from: url, to: dest, session: session)
        }
    }

    /// Stream one file to `dest` (via a `.partial`, atomically renamed on
    /// completion). Throws on a non-2xx response.
    private static func downloadFile(from url: URL, to dest: URL, session: URLSession) async throws {
        let partial = dest.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            throw DownloadError.downloadFailed("can't open \(partial.lastPathComponent)")
        }
        let delegate = StreamingFileDelegate(handle: handle)
        // Dedicated session so the delegate owns this transfer; long timeouts
        // for multi-GB weight shards.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        do {
            try await delegate.run(task: s.dataTask(with: url))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try FileManager.default.moveItem(at: partial, to: dest)
    }
}

/// URLSession data delegate that writes received chunks straight to a file
/// handle (bounded memory) and bridges completion to async/await.
private final class StreamingFileDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var cont: CheckedContinuation<Void, Error>?
    private var failed: Error?

    init(handle: FileHandle) { self.handle = handle }

    func run(task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                self.cont = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            failed = DownloadError.downloadFailed("HTTP \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle.write(contentsOf: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.close()
        let err = failed ?? error
        if let err { cont?.resume(throwing: err) } else { cont?.resume() }
        cont = nil
    }
}
