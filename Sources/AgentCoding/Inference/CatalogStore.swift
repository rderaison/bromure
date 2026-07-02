import Foundation

/// Loads/persists the model catalog and tracks installed weights.
///
/// Effective catalog = bundled `ModelCatalog.baseline` merged under a
/// remote `catalog.json` (fetched from a Bromure-hosted URL and cached in
/// Application Support, same JSON-in-Application-Support pattern as
/// profiles). Offline day one works off the baseline alone (§5.1).
public final class CatalogStore: @unchecked Sendable {
    public static let shared = CatalogStore()

    /// Where the refreshed manifest is cached on disk.
    private let cacheURL: URL
    /// Legacy HF hub cache (`models--org--name/snapshots/<rev>`) — read-only
    /// fallback so models pulled by the old `hf` CLI still resolve.
    private let hubCacheURL: URL
    /// Where the in-process engine's models live now: a flat per-repo dir,
    /// `…/BromureAC/models/<org>--<name>/`. New downloads land here.
    public let modelsDir: URL
    private let lock = NSLock()
    private var cachedRemote: ModelCatalog?

    public init(supportDir: URL? = nil, hubCacheDir: URL? = nil) {
        let support = supportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.cacheURL = support.appendingPathComponent("catalog.json")
        self.hubCacheURL = hubCacheDir ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        self.modelsDir = support.appendingPathComponent("models", isDirectory: true)
        if let data = try? Data(contentsOf: cacheURL) {
            self.cachedRemote = try? ModelCatalog.parse(data)
        }
    }

    /// Bromure-hosted refresh URL — published by `scripts/publish-spaces.sh`
    /// (Jenkinsfile.spaces) to the `bromure-dl` Space.
    public static let defaultRefreshURL =
        URL(string: "https://dl.bromure.io/mlx/catalog.json")!

    /// Testing kill-switch for the remote catalog:
    ///   defaults write io.bromure.agentic-coding catalog.refreshDisabled -bool YES
    /// When set, the published manifest is never *downloaded* — but the on-disk
    /// cache (`Application Support/BromureAC/catalog.json`) is still read and
    /// adopted, so a hand-edited catalog dropped there can be tested across
    /// launches without the published one overwriting it. Delete that file too
    /// when the *bundled* `Resources/catalog.json` should be authoritative.
    /// Delete the key to go back to normal.
    public static var refreshDisabled: Bool {
        UserDefaults.standard.bool(forKey: "catalog.refreshDisabled")
    }

    private func adoptRemote(_ parsed: ModelCatalog) {
        lock.lock(); cachedRemote = parsed; lock.unlock()
    }

    /// The merged, display-ready catalog.
    public func effective() -> ModelCatalog {
        lock.lock(); let remote = cachedRemote; lock.unlock()
        // The fetched catalog fully REPLACES the bundled baseline — no merging
        // of stale entries (a retired model disappears the moment it's dropped
        // from the published catalog.json). The bundled baseline is only the
        // offline day-one fallback. `refreshDisabled` blocks the *download*
        // only: the on-disk cache still applies, so a hand-edited cache file
        // survives launches instead of being clobbered by the published one.
        let base = remote ?? ModelCatalog.baseline
        return withInstalledExtras(base)
    }

    /// Append any *already-downloaded* model that isn't in `cat` as an
    /// `installed`/untested entry, so replacing the catalog never hides a
    /// model the user has on disk (e.g. one retired from the curated list).
    private func withInstalledExtras(_ cat: ModelCatalog) -> ModelCatalog {
        let present = Set(cat.models.map { $0.repo })
        let extras = installedRepos().filter { !present.contains($0) }.map { repo -> CatalogModel in
            let gb = (Double(installedBytes(repo: repo)) / 1_000_000_000 * 10).rounded() / 10
            return CatalogModel(
                id: repo, repo: repo, name: repo,
                downloadGB: gb, minUnifiedMemGB: max(8, Int(gb.rounded(.up)) + 8),
                tags: ["installed"], toolCalling: .untested)
        }
        guard !extras.isEmpty else { return cat }
        return ModelCatalog(version: cat.version, models: cat.models + extras)
    }

    /// Fully-downloaded repos — the new local models dir plus any still in the
    /// legacy hub cache.
    public func installedRepos() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)
        else { return [] }
        return names.filter { $0.contains("--") }
            .map { $0.replacingOccurrences(of: "--", with: "/") }
            .filter { isInstalled(repo: $0) }
            .sorted()
    }

    /// Resolve a user-supplied selector to a catalog entry. Accepts a
    /// catalog id, or a raw `org/repo` (the §5.5 escape hatch) which is
    /// synthesized into an `untested` entry.
    public func resolve(_ selector: String) -> CatalogModel? {
        let cat = effective()
        if let m = cat.model(id: selector) { return m }
        if let m = cat.models.first(where: { $0.repo == selector }) { return m }
        // The published (remote) catalog fully replaces the bundled baseline and
        // can lag this build — a model shipped in THIS app's baseline may be
        // absent from a stale fetched catalog. Fall back to the baseline so a
        // bundled catalog id always resolves to its real repo; otherwise the id
        // leaks through as a bogus "repo" and the engine can't find the weights.
        if let m = ModelCatalog.baseline.model(id: selector) { return m }
        if let m = ModelCatalog.baseline.models.first(where: { $0.repo == selector }) { return m }
        if Self.looksLikeHFRepo(selector) {
            return CatalogModel(
                id: selector, repo: selector,
                name: selector, downloadGB: 0, minUnifiedMemGB: 0,
                tags: ["custom"], toolCalling: .untested)
        }
        return nil
    }

    /// `org/name` shape, not a GGUF/ollama reference.
    public static func looksLikeHFRepo(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              !parts[0].isEmpty, !parts[1].isEmpty,
              !s.contains(" ") else { return false }
        return true
    }

    /// Fetch a fresh manifest, validate it parses, cache it, and adopt it.
    /// Network failures are non-fatal — we keep serving the prior catalog.
    @discardableResult
    public func refresh(from url: URL = CatalogStore.defaultRefreshURL,
                        session: URLSession = .shared) async -> Bool {
        guard !Self.refreshDisabled else { return false }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let parsed = try ModelCatalog.parse(data)
            adoptRemote(parsed)
            try? data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Installed tracking

    private func slug(_ repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "--")
    }

    /// The flat per-repo directory a download writes into (new layout):
    /// `…/BromureAC/models/<org>--<name>/`.
    public func localModelDirectory(for repo: String) -> URL {
        modelsDir.appendingPathComponent(slug(repo), isDirectory: true)
    }

    /// Where this repo's loadable `config.json` lives, if downloaded — the local
    /// models dir only. nil if absent or still downloading. This is what
    /// `MLXEngine` loads from. Legacy hub-cache models are moved here once by
    /// `migrateLegacyHubCache()`, so nothing is loaded out of `~/.cache` at runtime.
    public func resolvedModelDirectory(for repo: String) -> URL? {
        let local = localModelDirectory(for: repo)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path),
           !hasSuffixFile(local, ".partial"),
           // Never "installed" while the in-progress sentinel is present — an
           // interrupted download can have config.json yet be missing weight
           // shards (the gap between files), which would otherwise read as a
           // complete, loadable model. (Bug#2/#3.)
           !FileManager.default.fileExists(atPath: incompleteMarkerURL(for: repo).path) {
            return local
        }
        return nil
    }

    // MARK: - Download completion sentinel (interrupted-download detection)

    /// Sentinel file written into a model's dir while its download is in flight
    /// and removed only once every file has landed. A sentinel left behind after
    /// a crash/kill marks an *interrupted* download: such a dir is never treated
    /// as installed (above) and never merged into the catalog as an "installed
    /// extra", so a half-pull can't masquerade as a real model (Bug#2/#3).
    public static let incompleteMarkerName = ".incomplete"

    public func incompleteMarkerURL(for repo: String) -> URL {
        localModelDirectory(for: repo).appendingPathComponent(Self.incompleteMarkerName)
    }

    /// Begin a download: create the per-repo dir and drop the in-progress
    /// sentinel. Idempotent (safe to call again when resuming).
    public func beginDownload(repo: String) {
        let dir = localModelDirectory(for: repo)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: incompleteMarkerURL(for: repo).path, contents: nil)
    }

    /// Finish a download cleanly: remove the sentinel so the model now reads as
    /// installed.
    public func finishDownload(repo: String) {
        try? FileManager.default.removeItem(at: incompleteMarkerURL(for: repo))
    }

    /// True if `repo`'s dir exists but still carries the in-progress sentinel —
    /// a download the app didn't finish (killed/crashed mid-pull).
    public func isInterrupted(repo: String) -> Bool {
        let dir = localModelDirectory(for: repo)
        return FileManager.default.fileExists(atPath: dir.path)
            && FileManager.default.fileExists(atPath: incompleteMarkerURL(for: repo).path)
    }

    /// Every repo with a lingering in-progress sentinel — the set of interrupted
    /// downloads to offer for resume (or discard) on launch.
    public func interruptedRepos() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)
        else { return [] }
        return names.filter { $0.contains("--") }
            .map { $0.replacingOccurrences(of: "--", with: "/") }
            .filter { isInterrupted(repo: $0) }
            .sorted()
    }

    /// One-time move of models the old `hf` CLI left in the HF hub cache
    /// (`~/.cache/huggingface/hub/models--org--name/snapshots/<rev>/`) into the
    /// new flat layout. Hardlinks the resolved blobs (instant, no extra disk),
    /// so existing downloads aren't re-fetched and `~/.cache` can be deleted
    /// afterwards. Idempotent: skips a repo already present in the new layout.
    public func migrateLegacyHubCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hubCacheURL.path) else { return }
        for entry in entries where entry.hasPrefix("models--") {
            let repo = String(entry.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            let dest = localModelDirectory(for: repo)
            if fm.fileExists(atPath: dest.appendingPathComponent("config.json").path) { continue }
            let snapshots = hubCacheURL.appendingPathComponent(entry).appendingPathComponent("snapshots")
            guard let revs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
                  let rev = revs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }),
                  let files = try? fm.contentsOfDirectory(at: rev, includingPropertiesForKeys: nil),
                  (try? fm.createDirectory(at: dest, withIntermediateDirectories: true)) != nil
            else { continue }
            for f in files {
                let target = dest.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: target.path) { continue }
                // Resolve the snapshot symlink to the real blob, then hardlink it.
                let real = (try? fm.destinationOfSymbolicLink(atPath: f.path))
                    .map { URL(fileURLWithPath: $0, relativeTo: rev).standardizedFileURL } ?? f
                do { try fm.linkItem(at: real, to: target) }
                catch { try? fm.copyItem(at: real, to: target) }   // cross-volume fallback
            }
        }
    }

    private func hasSuffixFile(_ dir: URL, _ suffix: String) -> Bool {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        for case let url as URL in en where url.lastPathComponent.hasSuffix(suffix) { return true }
        return false
    }

    /// Directory a download writes into (always the new local layout).
    public func installDirectory(for repo: String) -> URL { localModelDirectory(for: repo) }

    /// Fully downloaded and loadable.
    public func isInstalled(repo: String) -> Bool { resolvedModelDirectory(for: repo) != nil }

    /// Bytes on disk for a repo (best-effort recursive sum). Prefers the local
    /// dir even mid-download so the progress poller sees it grow.
    public func installedBytes(repo: String) -> Int64 {
        let fm = FileManager.default
        let local = localModelDirectory(for: repo)
        let dir = fm.fileExists(atPath: local.path)
            ? local : (resolvedModelDirectory(for: repo) ?? local)
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Remove a repo's weights from wherever they live (new dir and/or legacy cache).
    public func removeInstalled(repo: String) throws {
        let fm = FileManager.default
        let local = localModelDirectory(for: repo)
        if fm.fileExists(atPath: local.path) { try fm.removeItem(at: local) }
        let legacy = hubCacheURL.appendingPathComponent("models--" + slug(repo), isDirectory: true)
        if fm.fileExists(atPath: legacy.path) { try? fm.removeItem(at: legacy) }
    }
}
