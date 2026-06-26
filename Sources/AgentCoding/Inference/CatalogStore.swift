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
        lock.lock(); defer { lock.unlock() }
        if let remote = cachedRemote { return ModelCatalog.baseline.merged(with: remote) }
        return ModelCatalog.baseline
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

    public func isInstalled(repo: String) -> Bool {
        FileManager.default.fileExists(atPath: installDirectory(for: repo).path)
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
