import Foundation
import Observation

/// Process-wide registry of in-flight model downloads. Lives outside any
/// SwiftUI view so progress + cancellation survive navigating between
/// preference panes (the old per-view `@State` reset on every switch,
/// which made a still-running download look "Downloaded"). Also the single
/// source of truth the VM-launch path checks before booting.
@MainActor
@Observable
public final class ModelDownloadManager {
    public static let shared = ModelDownloadManager()

    public enum State: Equatable {
        case downloading(Double, String)   // fraction 0–1, "X.X / Y GB"
        case failed(String)
        /// A pull interrupted by a crash/kill (sentinel left behind): bytes
        /// already on disk + the expected total, for a "Resume / Discard" row.
        case interrupted(bytesOnDisk: Int64, totalBytes: Int64)

        /// JSON-ready form for the fat-client `/state` mirror. The engine and
        /// its downloads live on the host, so the client sees this and drives
        /// the server via `/models/*` rather than downloading locally.
        public var wireDict: [String: Any] {
            switch self {
            case .downloading(let f, let l): return ["phase": "downloading", "frac": f, "label": l]
            case .failed(let m):             return ["phase": "failed", "msg": m]
            case .interrupted(let d, let t): return ["phase": "interrupted", "onDisk": d, "total": t]
            }
        }
        public init?(wire d: [String: Any]) {
            func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64((v as? Int) ?? 0) }
            switch d["phase"] as? String {
            case "downloading":
                self = .downloading((d["frac"] as? Double) ?? 0, (d["label"] as? String) ?? "")
            case "failed":
                self = .failed((d["msg"] as? String) ?? "")
            case "interrupted":
                self = .interrupted(bytesOnDisk: i64(d["onDisk"]), totalBytes: i64(d["total"]))
            default:
                return nil
            }
        }
    }

    /// Keyed by HF repo.
    public private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public func state(repo: String) -> State? { states[repo] }

    public func isDownloading(repo: String) -> Bool {
        if case .downloading = states[repo] { return true }
        return false
    }

    /// Any download currently running (for a global "wait" gate).
    public var hasActiveDownloads: Bool {
        states.values.contains { if case .downloading = $0 { return true }; return false }
    }

    /// Start a download (idempotent per repo). `totalBytes` drives the
    /// determinate bar.
    public func start(repo: String, totalBytes: Int64) {
        guard tasks[repo] == nil else { return }
        // Preflight disk space before showing "downloading", so a doomed pull
        // surfaces as a clear failure (with Retry) instead of a false start.
        do {
            try ModelDownloader.checkDiskSpace(repo: repo, expectedBytes: totalBytes)
        } catch {
            states[repo] = .failed(error.localizedDescription)
            return
        }
        states[repo] = .downloading(0, "Starting…")
        let total = max(1, totalBytes)
        let task = Task { [weak self] in
            // Pure-Swift download (HubDownloader) — no venv to provision.
            // Determinate progress from bytes-on-disk vs the known total.
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, self.isDownloading(repo: repo) else { break }
                    let bytes = CatalogStore.shared.installedBytes(repo: repo)
                    let frac = min(0.99, Double(bytes) / Double(total))
                    self.states[repo] = .downloading(frac, ProgressBar.bytesLabel(bytes, total))
                }
            }
            do {
                try await ModelDownloader.pull(repo: repo, expectedBytes: totalBytes, onProgress: { _ in })
                poller.cancel()
                self?.finishOK(repo)
            } catch is CancellationError {
                poller.cancel()
                self?.finishCancelled(repo)
            } catch {
                poller.cancel()
                self?.finishFailed(repo, error.localizedDescription)
            }
        }
        tasks[repo] = task
    }

    /// Cancel an in-flight download (terminates `hf` + removes the partial).
    public func cancel(repo: String) {
        tasks[repo]?.cancel()
    }

    /// Surface any download interrupted by a crash/kill — its in-progress
    /// sentinel outlived the app — as a resumable entry, so the picker offers
    /// "Resume" or "Discard" rather than silently leaving a half-pull on disk
    /// (Bug#2). Call once at launch. Resuming is just `start(repo:)` again
    /// (HubDownloader skips files already complete); discarding deletes them.
    public func detectInterrupted() {
        for repo in CatalogStore.shared.interruptedRepos() {
            if tasks[repo] != nil { continue }                 // a live pull owns it
            if case .interrupted = states[repo] { continue }   // already surfaced
            let onDisk = CatalogStore.shared.installedBytes(repo: repo)
            let totalGB = CatalogStore.shared.resolve(repo)?.downloadGB ?? 0
            states[repo] = .interrupted(bytesOnDisk: onDisk,
                                        totalBytes: Int64(totalGB * 1_000_000_000))
        }
    }

    /// Throw away an interrupted (or failed) download's partial artifacts and
    /// clear its state — the "quietly delete" branch of Bug#2.
    public func discard(repo: String) {
        try? CatalogStore.shared.removeInstalled(repo: repo)
        states[repo] = nil
    }

    private func finishOK(_ repo: String) {
        states[repo] = nil
        tasks[repo] = nil
    }
    private func finishFailed(_ repo: String, _ msg: String) {
        states[repo] = .failed(msg)
        tasks[repo] = nil
    }
    private func finishCancelled(_ repo: String) {
        // Drop the partial so a half-download isn't mistaken for installed.
        try? CatalogStore.shared.removeInstalled(repo: repo)
        states[repo] = nil
        tasks[repo] = nil
    }
}
