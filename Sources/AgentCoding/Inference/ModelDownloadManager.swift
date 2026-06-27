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
                try await ModelDownloader.pull(repo: repo, onProgress: { _ in })
                poller.cancel()
                self?.finishOK(repo)
            } catch is CancellationError {
                poller.cancel()
                self?.finishCancelled(repo)
            } catch {
                poller.cancel()
                self?.finishFailed(repo, "\(error)")
            }
        }
        tasks[repo] = task
    }

    /// Cancel an in-flight download (terminates `hf` + removes the partial).
    public func cancel(repo: String) {
        tasks[repo]?.cancel()
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
