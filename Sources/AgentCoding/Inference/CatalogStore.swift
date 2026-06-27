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

    private func adoptRemote(_ parsed: ModelCatalog) {
        lock.lock(); cachedRemote = parsed; lock.unlock()
    }

    /// The merged, display-ready catalog.
    public func effective() -> ModelCatalog {
        lock.lock(); let remote = cachedRemote; lock.unlock()
        // The fetched catalog fully REPLACES the bundled baseline — no merging
        // of stale entries (a retired model disappears the moment it's dropped
        // from the published catalog.json). The bundled baseline is only the
        // offline day-one fallback.
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
        let fm = FileManager.default
        var repos = Set<String>()
        if let names = try? fm.contentsOfDirectory(atPath: modelsDir.path) {
            for n in names where n.contains("--") {
                let repo = n.replacingOccurrences(of: "--", with: "/")
                if isInstalled(repo: repo) { repos.insert(repo) }
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: hubCacheURL.path) {
            for n in names where n.hasPrefix("models--") {
                let repo = String(n.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
                if isInstalled(repo: repo) { repos.insert(repo) }
            }
        }
        return repos.sorted()
    }

    /// Resolve a user-supplied selector to a catalog entry. Accepts a
    /// catalog id, or a raw `org/repo` (the §5.5 escape hatch) which is
    /// synthesized into an `untested` entry.
    public func resolve(_ selector: String) -> CatalogModel? {
        let cat = effective()
        if let m = cat.model(id: selector) { return m }
        if let m = cat.models.first(where: { $0.repo == selector }) { return m }
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

    /// Where this repo's loadable `config.json` lives, if downloaded — the new
    /// local models dir first, then the legacy hub-cache snapshot. nil if absent
    /// or still downloading. This is what `MLXEngine` loads from.
    public func resolvedModelDirectory(for repo: String) -> URL? {
        let fm = FileManager.default
        let local = localModelDirectory(for: repo)
        if fm.fileExists(atPath: local.appendingPathComponent("config.json").path),
           !hasSuffixFile(local, ".partial") {
            return local
        }
        // Legacy: models--org--name/snapshots/<rev>/config.json (from the old hf CLI).
        let legacy = hubCacheURL.appendingPathComponent("models--" + slug(repo), isDirectory: true)
        let snapshots = legacy.appendingPathComponent("snapshots", isDirectory: true)
        if !hasSuffixFile(legacy, ".incomplete"),
           let revs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
            return revs.first { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
        }
        return nil
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
