import AppKit
import Foundation

/// Locates + downloads the local detector models for prompt-injection /
/// rules-file detection. Mirrors `FaceSwapEngine`'s "fetch to Application
/// Support" pattern: files come from `dl.bromure.io/llms/<dir>/<file>` and
/// land in `~/Library/Application Support/BromureAC/Models/<dir>/<file>` —
/// the same dirs the ONNX runtime loads from. Models are never bundled.
public enum PromptInjectionModels {
    public enum Kind: Sendable, CaseIterable {
        case promptGuard      // source-code / tool_result injection (PromptGuard)
        case claudeMdGuard    // rogue CLAUDE.md / instruction files (ModernBERT)

        var dirName: String {
            switch self {
            case .promptGuard:   return "prompt-injection"
            case .claudeMdGuard: return "claudemd-guard"
            }
        }
        /// (filename, min bytes). The size floor rejects truncated downloads
        /// and HTML error pages so a bad fetch fails loudly rather than
        /// silently disabling the detector.
        var files: [(name: String, minBytes: Int)] {
            switch self {
            case .promptGuard:
                return [("model.onnx", 50_000_000), ("tokenizer.json", 1_000_000),
                        ("tokenizer_config.json", 100), ("special_tokens_map.json", 50)]
            case .claudeMdGuard:
                return [("model.onnx", 100_000_000), ("tokenizer.json", 500_000),
                        ("tokenizer_config.json", 100), ("config.json", 100)]
            }
        }

        /// Human-readable detector name for the download-confirmation prompt.
        var detectorName: String {
            switch self {
            case .promptGuard:
                return NSLocalizedString("Source-code prompt-injection", comment: "detector name")
            case .claudeMdGuard:
                return NSLocalizedString("Rogue-instruction (CLAUDE.md)", comment: "detector name")
            }
        }

        /// Approximate total on-disk size of the model + tokenizer assets.
        /// Used to weight the progress bar and to tell the user up front how
        /// much disk the download will consume.
        var approxBytes: Int64 {
            switch self {
            case .promptGuard:   return 298_000_000   // ~284 MiB
            case .claudeMdGuard: return 603_000_000   // ~575 MiB
            }
        }

        /// Formatted size string for the confirmation dialog ("284 MB").
        var approxSizeString: String {
            ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
        }
    }

    private static let baseURL = URL(string: "https://dl.bromure.io/llms")!

    public static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/Models", isDirectory: true)
    }
    public static func directory(for kind: Kind) -> URL {
        modelsRoot.appendingPathComponent(kind.dirName, isDirectory: true)
    }

    public static func isInstalled(_ kind: Kind) -> Bool {
        let dir = directory(for: kind)
        let fm = FileManager.default
        return kind.files.allSatisfy { f in
            guard let sz = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)[.size]) as? Int
            else { return false }
            return sz >= f.minBytes
        }
    }

    /// Free host space required before starting a model download. The
    /// largest asset (the ModernBERT model.onnx) is ~600 MB and lands in a
    /// temp file before an instant same-volume move, so peak usage is ~one
    /// model; 1.5 GB leaves comfortable headroom.
    static let minimumFreeBytes: UInt64 = 1_500_000_000

    /// Download every file for `kind` (skipping ones already present + valid).
    /// Atomic per-file; verifies the size floor.
    public static func download(_ kind: Kind,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let dir = directory(for: kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Fail fast on a near-full host so a half-written model doesn't
        // silently disable the detector (or wedge the move).
        if let free = (try? FileManager.default
            .attributesOfFileSystem(forPath: dir.path)[.systemFreeSize]) as? UInt64,
           free < minimumFreeBytes {
            throw Err.diskFull(availableMB: free / (1024 * 1024),
                               requiredMB: minimumFreeBytes / (1024 * 1024))
        }
        let files = kind.files
        // Byte-weighted progress: the model.onnx dominates (≈99% of the
        // bytes), so per-file step progress would freeze the bar for the
        // whole big download. Report cumulative bytes over the known approx
        // total instead, for a smooth fill.
        let total = Double(kind.approxBytes)
        var completedBytes: Int64 = 0
        for f in files {
            let dest = dir.appendingPathComponent(f.name)
            if let sz = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int,
               sz >= f.minBytes {
                completedBytes += Int64(sz)
                progress(min(0.999, Double(completedBytes) / total)); continue
            }
            let url = baseURL.appendingPathComponent("\(kind.dirName)/\(f.name)")
            let base = completedBytes
            let downloader = ProgressDownloader { written in
                progress(min(0.999, Double(base + written) / total))
            }
            let (tmp, resp) = try await downloader.run(url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw Err.http((resp as? HTTPURLResponse)?.statusCode ?? 0, f.name)
            }
            let sz = ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int) ?? 0
            guard sz >= f.minBytes else { throw Err.truncated(f.name, sz, f.minBytes) }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            completedBytes += Int64(sz)
            progress(min(0.999, Double(completedBytes) / total))
        }
        progress(1.0)
    }

    /// Downloads one file on a dedicated `URLSession` so the *session*
    /// delegate reliably receives `didWriteData` progress callbacks. (The
    /// per-task delegate on the async `download(from:delegate:)` API does not
    /// deliver them dependably — without this the bar can sit at 0 and snap to
    /// 100 only when the download finishes.) Reports cumulative bytes for this
    /// file as they arrive, moves the finished temp file aside, and returns it
    /// with the response — mirroring `URLSession.download(from:)` so the
    /// caller's status/size validation + move-into-place stays unchanged.
    /// Honors task cancellation (the progress panel's Cancel button).
    private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onBytes: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var task: URLSessionDownloadTask?
        private var movedURL: URL?
        private var moveError: Error?

        init(onBytes: @escaping @Sendable (Int64) -> Void) { self.onBytes = onBytes }

        func run(_ url: URL) async throws -> (URL, URLResponse) {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    lock.lock()
                    continuation = cont
                    let t = session.downloadTask(with: url)
                    task = t
                    lock.unlock()
                    t.resume()
                }
            } onCancel: {
                lock.lock(); let t = task; lock.unlock()
                t?.cancel()
            }
        }

        private func finishOnce(_ result: Result<(URL, URLResponse), Error>) {
            lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
            guard let cont else { return }
            switch result {
            case .success(let v): cont.resume(returning: v)
            case .failure(let e): cont.resume(throwing: e)
            }
        }

        // Fires repeatedly as bytes arrive — the smooth-progress source.
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onBytes(totalBytesWritten)
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // The temp file is deleted when this returns — move it now.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do { try FileManager.default.moveItem(at: location, to: dest); movedURL = dest }
            catch { moveError = error }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finishOnce(.failure(error)); return }
            if let moveError { finishOnce(.failure(moveError)); return }
            if let moved = movedURL, let resp = task.response {
                finishOnce(.success((moved, resp)))
            } else {
                finishOnce(.failure(URLError(.cannotCreateFile)))
            }
        }
    }

    // MARK: - In-flight de-duplication

    private static let inFlightLock = NSLock()
    private static var inFlight: Set<String> = []

    /// Claim the download slot for `kind`; returns false if one is already
    /// running (so the UI flow and the launch-time background fetch don't
    /// both download the same model). Caller must `releaseInFlight` when done.
    static func claimInFlight(_ kind: Kind) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight.insert(kind.dirName).inserted
    }
    static func releaseInFlight(_ kind: Kind) {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlight.remove(kind.dirName)
    }
    static func isDownloading(_ kind: Kind) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight.contains(kind.dirName)
    }

    /// Fire a background download when a detector is enabled but its model is
    /// missing. Idempotent (a second call while running just re-checks +
    /// no-ops). Progress / outcome lands in the Security log.
    public static func ensureInstalledInBackground(_ kind: Kind) {
        guard !isInstalled(kind) else { return }
        // Don't start a second fetch if the editor's confirm-and-download
        // flow (or a prior launch) is already pulling this model.
        guard claimInFlight(kind) else { return }
        Task.detached(priority: .utility) {
            defer { releaseInFlight(kind) }
            guard !isInstalled(kind) else { return }
            SupplyChainLog.shared.record("[prompt-injection] downloading \(kind.dirName) model from bromure.io…")
            do {
                try await download(kind)
                SupplyChainLog.shared.record("[prompt-injection] \(kind.dirName) model installed.")
            } catch {
                SupplyChainLog.shared.record("[prompt-injection] \(kind.dirName) download failed: \(error.localizedDescription)")
                // A silent log isn't enough for the disk-full case: the user
                // enabled a detector and it just won't work. Surface it.
                if let err = error as? Err, case .diskFull = err {
                    await Self.presentDiskFullAlert(err.localizedDescription)
                }
            }
        }
    }

    /// One modal alert at a time — two detectors enabling at once would
    /// otherwise stack identical disk-full dialogs.
    @MainActor private static var diskAlertVisible = false
    @MainActor private static func presentDiskFullAlert(_ detail: String) {
        guard !diskAlertVisible else { return }
        diskAlertVisible = true
        defer { diskAlertVisible = false }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Not enough disk space to download the prompt-injection model",
            comment: "Alert title when a detector model can't be downloaded due to low disk")
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.runModal()
    }

    enum Err: LocalizedError {
        case http(Int, String)
        case truncated(String, Int, Int)
        case diskFull(availableMB: UInt64, requiredMB: UInt64)
        var errorDescription: String? {
            switch self {
            case .http(let s, let f):
                return String(format: NSLocalizedString("HTTP %d downloading %@",
                    comment: "Model download failed with an HTTP status"), s, f)
            case .truncated(let f, let got, let min):
                return String(format: NSLocalizedString(
                    "%@ too small (%d < %d bytes) — truncated download",
                    comment: "A model file download was truncated"), f, got, min)
            case .diskFull(let avail, let need):
                return String(format: NSLocalizedString(
                    "Only %llu MB free — the model needs about %llu MB. Free up space and re-enable the detector.",
                    comment: "Not enough disk to download a detector model"), avail, need)
            }
        }
    }
}
