import Foundation
import SandboxEngine

/// Downloads the embedded browser's base image on demand — phase 2b of
/// BROWSER_PANE_PLAN. AC normally rides Bromure Web's image
/// (~/Library/Application Support/Bromure); when neither that nor AC's
/// own copy exists, this pulls the prebuilt Alpine/Chromium image from
/// dl.bromure.io/browser-images/ into
/// `WorkspaceBrowserController.browserStorageDir` and runs the catalog
/// postinstall (Cloudflare WARP) + personalisation (macOS fonts,
/// keyboard/locale) — the exact machinery Bromure Web's own installer
/// uses (SandboxEngine's LinuxImageManager+Remote).
///
/// One shared instance, deliberately outside any view (same pattern as
/// ModelDownloadManager) so progress survives navigating between the
/// browser pane and Settings → Browser: both surfaces render the same
/// `progress` model, and concurrent triggers (pane click + settings
/// button + MCP `ensureRunning`) join a single in-flight install.
@MainActor
@Observable
final class BrowserImageInstaller {
    static let shared = BrowserImageInstaller()

    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Shared progress model (status pill, weighted bar, console log) —
    /// rendered by the browser-pane placeholder and Settings → Browser.
    let progress = InitProgressModel()

    private var task: Task<Bool, Never>?

    /// The browser-images/ catalog store. Cached in AC's own support dir
    /// — the file name (browser-img-catalog.json) is channel-scoped, so
    /// it sits safely next to AC's own img-catalog.json.
    private let catalogStore = ImageCatalogStore(
        distribution: .browser,
        supportDir: UbuntuImageManager.defaultStorageDirectory)

    /// Where AC's own copy of the image lands
    /// (~/Library/Application Support/BromureAC/browser).
    private var storageDir: URL { WorkspaceBrowserController.browserStorageDir }

    // MARK: - Presence

    enum ImageSource {
        /// Bromure Web's image dir — AC only reads it.
        case sharedWithBromureWeb
        /// AC's own downloaded copy.
        case downloadedByAC
    }

    /// Where a complete boot set currently lives (same resolution order
    /// the browser controller boots with), or nil when none exists.
    var installedSource: ImageSource? {
        if WorkspaceBrowserController.hasAllBootFiles(in: VMConfig.defaultStorageDirectory) {
            return .sharedWithBromureWeb
        }
        if WorkspaceBrowserController.hasAllBootFiles(in: storageDir) {
            return .downloadedByAC
        }
        return nil
    }

    var imageInstalled: Bool { installedSource != nil }

    /// Logical size of the installed disk image, human-formatted — for
    /// the Settings caption. nil when not installed.
    var installedDiskSize: String? {
        let dir: URL
        switch installedSource {
        case .sharedWithBromureWeb: dir = VMConfig.defaultStorageDirectory
        case .downloadedByAC: dir = storageDir
        case nil: return nil
        }
        let disk = dir.appendingPathComponent("linux-base.img")
        guard let bytes = (try? FileManager.default.attributesOfItem(
            atPath: disk.path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Install

    /// Ensure a browser image exists, downloading it when missing.
    /// Joins an in-flight install. Returns true when an image is present
    /// on return.
    @discardableResult
    func ensureInstalled() async -> Bool {
        if let task { return await task.value }
        if imageInstalled { return true }
        return await install()
    }

    /// Start (or join) an install. Unconditional — Settings uses this
    /// for re-download; the fresh image is promoted atomically over the
    /// old one, so open browser sessions keep running on their clones.
    @discardableResult
    func install() async -> Bool {
        if let task { return await task.value }
        let t = Task<Bool, Never> { await run() }
        task = t
        let ok = await t.value
        task = nil
        return ok
    }

    /// The failure message of the last install, if it failed.
    var lastError: String? {
        if case .failed(let msg) = phase { return msg }
        return nil
    }

    /// Human estimate of the download for consent UIs: the cached
    /// catalog's actual compressed sizes when we've seen one, else the
    /// ballpark.
    var downloadSizeDescription: String {
        if let image = catalogStore.remote()?.image {
            let total = image.disk.compressedBytes
                + (image.boot ?? []).reduce(Int64(0)) { $0 + $1.compressedBytes }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return String(localized: "about 500 MB")
    }

    private func run() async -> Bool {
        phase = .running
        progress.reset()
        progress.narrateBrowserGuestLog = true
        // The browser install is far quieter than the AC Ubuntu bake
        // (no debootstrap/apt firehose) — the phase weights do the work;
        // this only sets the gentle per-line nudge between phases.
        progress.expectedTotalLines = 900

        let manager = LinuxImageManager(storageDir: storageDir)
        let model = progress
        let handle: (ProgressEvent) -> Void = { event in
            DispatchQueue.main.async {
                switch event {
                case .message(let text):
                    model.noteBrowserHostProgress(text)
                case .stepStart(let text):
                    model.noteBrowserHostProgress(text + "…")
                case .stepDone:
                    break
                case .consoleOutput(let chunk):
                    model.appendLog(chunk)
                case .download, .install:
                    break
                }
            }
        }

        do {
            do {
                // AC runs NO catalog steps in its copy of the image
                // (fonts + personalisation still happen) unless a step
                // opts in with "bromureac": true — the image lives in
                // AC's own location, and Web-facing packages (Cloudflare
                // WARP) have no business in the agent browser.
                try await manager.downloadBaseImage(
                    catalogStore: catalogStore,
                    includeStep: { $0.appliesToAgentCoding },
                    progress: handle)
            } catch let error where LinuxImageManager.isDownloadSideFailure(error) {
                // Same policy as Bromure Web's installer: only
                // download-side failures fall back to the local bake.
                handle(.message(String(localized:
                    "Prebuilt image unavailable — building it locally instead (~10 min).")))
                // The local bake is line-driven; its Alpine/apk output is
                // shorter than the AC Ubuntu bake's.
                model.expectedTotalLines = 4000
                _ = await catalogStore.refresh()
                let catalog = catalogStore.effective()
                try await manager.createBaseImage(
                    postinstallSteps: catalog.sortedSteps.filter(\.appliesToAgentCoding),
                    progress: handle)
            }
            progress.bumpProgress(to: 1.0)
            progress.isRunning = false
            phase = .idle
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            progress.error = message
            progress.isRunning = false
            phase = .failed(message)
            return false
        }
    }
}
