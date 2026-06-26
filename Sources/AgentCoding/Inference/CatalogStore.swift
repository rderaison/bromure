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
    /// HF hub cache root where pulled weights land (§5.6).
    private let hubCacheURL: URL
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

    /// HF repos fully downloaded in the hub cache (`models--org--name`).
    public func installedRepos() -> [String] {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: hubCacheURL.path) else { return [] }
        return names.compactMap { name -> String? in
            guard name.hasPrefix("models--") else { return nil }
            let repo = String(name.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")
            return isInstalled(repo: repo) ? repo : nil
        }.sorted()
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

    /// HF caches a repo `org/name` under `models--org--name`.
    public func installDirectory(for repo: String) -> URL {
        let slug = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        return hubCacheURL.appendingPathComponent(slug, isDirectory: true)
    }

    /// True only when the repo is **fully** downloaded — not merely that
    /// the cache dir exists (it appears the moment a pull starts, with
    /// partial `.incomplete` blobs). A complete pull has no `.incomplete`
    /// files and a snapshot containing `config.json` (a loadable model).
    public func isInstalled(repo: String) -> Bool {
        let fm = FileManager.default
        let dir = installDirectory(for: repo)
        guard fm.fileExists(atPath: dir.path) else { return false }
        // Any in-flight blob → not done.
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.lastPathComponent.hasSuffix(".incomplete") {
                return false
            }
        }
        // A usable snapshot must carry config.json.
        let snapshots = dir.appendingPathComponent("snapshots", isDirectory: true)
        guard let revs = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return false }
        return revs.contains { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    }

    /// Bytes on disk for an installed repo (best-effort recursive sum).
    public func installedBytes(repo: String) -> Int64 {
        let dir = installDirectory(for: repo)
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Remove a pulled repo's weights from the hub cache.
    public func removeInstalled(repo: String) throws {
        try FileManager.default.removeItem(at: installDirectory(for: repo))
    }
}
