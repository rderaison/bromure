import Foundation

// MARK: - img-catalog.json model
//
// The manifest that drives prebuilt-base-image distribution. Published to
// https://dl.bromure.io/images/img-catalog.json by scripts/publish-image.sh
// (Jenkinsfile.image, weekly); the bundled Resources/img-catalog.json is the
// canonical source of the postinstall steps and the offline fallback.
//
// Two independent update axes:
//   • `image.version` — the base-image version (same constant as
//     `UbuntuImageManager.imageVersion`). A *major* change means "offer the
//     user a full re-download". Weekly package-refresh rebuilds keep the
//     version, so only new installations pick them up.
//   • `postinstall[].uuid` — each step is identified by a stable uuid. A
//     step uuid the local image hasn't applied yet is a "new recommended
//     package": surfaced to the user for consent, then executed in a chroot
//     against base.img (postinstall.sh). Steps are ordered by `seq`.
//
// Postinstall steps are how non-free software (Claude Code, Codex, Grok,
// gcloud) reaches the user's machine: the published image itself contains
// free software only, so it can be redistributed.

/// One postinstall command from img-catalog.json. `command` is a shell
/// fragment executed as root inside a chroot on base.img (bash -e, up to
/// 3 attempts). `seq` orders execution; `uuid` identifies the step across
/// catalog updates so we can tell "already applied" from "new".
public struct PostinstallStep: Codable, Sendable, Equatable, Identifiable {
    public var uuid: String
    public var seq: Int
    public var description: String
    public var command: String

    public var id: String { uuid }

    public init(uuid: String, seq: Int, description: String, command: String) {
        self.uuid = uuid
        self.seq = seq
        self.description = description
        self.command = command
    }
}

/// The downloadable prebuilt image a published catalog points at.
public struct RemoteBaseImage: Codable, Sendable, Equatable {
    /// Compressed disk artifact, keyed under `images/<uuid>/` on the CDN.
    public struct Disk: Codable, Sendable, Equatable {
        /// Object key relative to the CDN base, e.g.
        /// `images/3f…/base.img.gz`.
        public var path: String
        /// SHA-256 (hex) of the *compressed* file — verified before
        /// decompression.
        public var sha256: String
        public var compressedBytes: Int64
        /// Logical size of the decompressed raw disk (24 GB sparse).
        public var uncompressedBytes: Int64
        /// Only "gzip" today. Anything else is rejected client-side so a
        /// future format change can't silently produce a corrupt disk.
        public var compression: String

        public init(path: String, sha256: String, compressedBytes: Int64,
                    uncompressedBytes: Int64, compression: String = "gzip") {
            self.path = path
            self.sha256 = sha256
            self.compressedBytes = compressedBytes
            self.uncompressedBytes = uncompressedBytes
            self.compression = compression
        }
    }

    /// Random uuid minted per published build — the CDN prefix the
    /// artifacts live under. A new weekly build gets a new uuid even when
    /// `version` doesn't change (the previous prefix is deleted after the
    /// new catalog is live).
    public var uuid: String
    /// Image version — mirrors `UbuntuImageManager.imageVersion` at build
    /// time ("200", possibly with a dot-revision).
    public var version: String
    /// Human description, e.g. "Ubuntu 24.04".
    public var description: String
    /// ISO-8601 build timestamp (informational).
    public var builtAt: String?
    public var disk: Disk

    public init(uuid: String, version: String, description: String,
                builtAt: String? = nil, disk: Disk) {
        self.uuid = uuid
        self.version = version
        self.description = description
        self.builtAt = builtAt
        self.disk = disk
    }
}

/// A parsed img-catalog.json.
public struct ImageCatalog: Codable, Sendable, Equatable {
    public var formatVersion: Int
    /// nil in the bundled baseline (which only carries the canonical
    /// postinstall list); always present in a published catalog.
    public var image: RemoteBaseImage?
    public var postinstall: [PostinstallStep]

    public init(formatVersion: Int = 1, image: RemoteBaseImage? = nil,
                postinstall: [PostinstallStep]) {
        self.formatVersion = formatVersion
        self.image = image
        self.postinstall = postinstall
    }

    /// Steps in execution order.
    public var sortedSteps: [PostinstallStep] {
        postinstall.sorted { ($0.seq, $0.uuid) < ($1.seq, $1.uuid) }
    }

    /// The steps not yet applied to the local image, in execution order.
    public func pendingSteps(appliedUUIDs: some Sequence<String>) -> [PostinstallStep] {
        let applied = Set(appliedUUIDs)
        return sortedSteps.filter { !applied.contains($0.uuid) }
    }

    public static func parse(_ data: Data) throws -> ImageCatalog {
        try JSONDecoder().decode(ImageCatalog.self, from: data)
    }
}

// MARK: - Baseline (shipped, offline fallback)

extension ImageCatalog {
    /// The shipped baseline — the bundled `img-catalog.json` resource, the
    /// same file `scripts/publish-image.sh` reads the postinstall list
    /// from, so shipped baseline and published manifest can never drift.
    /// Its `image` is null: with no network there is nothing to download
    /// (the local build path is the fallback), but the postinstall list
    /// still applies.
    public static let baseline: ImageCatalog = loadBundledBaseline()

    static func loadBundledBaseline() -> ImageCatalog {
        if let url = acResourceBundle.url(forResource: "img-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cat = try? parse(data) {
            return cat
        }
        return embeddedFallback
    }

    /// Last-resort safety net if the bundled JSON is ever missing/corrupt:
    /// an empty step list, so setup still completes (with a free-software
    /// image and no agents) rather than trapping.
    static let embeddedFallback = ImageCatalog(formatVersion: 1, image: nil, postinstall: [])
}

// MARK: - Store (fetch + cache)

/// Fetches and caches img-catalog.json — same pattern as the MLX
/// `CatalogStore`: remote manifest cached in Application Support, bundled
/// baseline as the offline fallback.
public final class ImageCatalogStore: @unchecked Sendable {
    public static let shared = ImageCatalogStore()

    /// Bromure-hosted manifest, published by `scripts/publish-image.sh`
    /// (Jenkinsfile.image) with a 1-second CDN cache so a weekly publish
    /// is visible to clients immediately.
    public static let defaultRefreshURL =
        URL(string: "https://dl.bromure.io/images/img-catalog.json")!

    /// Base the catalog's relative artifact paths resolve against.
    public static let defaultPublicBase = URL(string: "https://dl.bromure.io/")!

    /// `BROMURE_IMAGE_CATALOG_BASE` env override — points the catalog
    /// fetch AND artifact resolution at another root, e.g. the `file://`
    /// staging dir scripts/test-image-publish-local.sh assembles, or a
    /// localhost server in tests. Layout under the base must mirror the
    /// CDN (`images/img-catalog.json`, `images/<uuid>/base.img.gz`).
    static var overrideBase: URL? {
        guard let raw = ProcessInfo.processInfo.environment["BROMURE_IMAGE_CATALOG_BASE"],
              !raw.isEmpty else { return nil }
        return URL(string: raw.hasSuffix("/") ? raw : raw + "/")
    }

    /// The manifest URL actually in effect (override-aware).
    public static var refreshURL: URL {
        overrideBase.flatMap { URL(string: "images/img-catalog.json", relativeTo: $0)?.absoluteURL }
            ?? defaultRefreshURL
    }

    /// The artifact base actually in effect (override-aware).
    public static var publicBase: URL {
        overrideBase ?? defaultPublicBase
    }

    private let cacheURL: URL
    private let lock = NSLock()
    private var cachedRemote: ImageCatalog?

    public init(supportDir: URL? = nil) {
        let support = supportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.cacheURL = support.appendingPathComponent("img-catalog.json")
        if let data = try? Data(contentsOf: cacheURL) {
            self.cachedRemote = try? ImageCatalog.parse(data)
        }
    }

    /// The best catalog we have: last fetched manifest, else the baseline.
    public func effective() -> ImageCatalog {
        lock.lock(); defer { lock.unlock() }
        return cachedRemote ?? ImageCatalog.baseline
    }

    /// The last *fetched* catalog only — nil when we've never reached the
    /// CDN. Download decisions (is a new image version available?) use
    /// this, never the baseline, so an offline launch can't misread the
    /// null baseline image as "nothing published".
    public func remote() -> ImageCatalog? {
        lock.lock(); defer { lock.unlock() }
        return cachedRemote
    }

    /// NSLock can't be taken directly inside an async function (Swift 6
    /// error); `refresh` funnels through this sync hop instead — same
    /// shape as the MLX CatalogStore.
    private func adoptRemote(_ parsed: ImageCatalog) {
        lock.lock(); cachedRemote = parsed; lock.unlock()
    }

    /// Fetch a fresh manifest, validate it parses, cache + adopt it.
    /// Ignores every cache layer (the object is published with a 1s TTL,
    /// but URLSession's local cache would happily serve yesterday's).
    /// Network failures are non-fatal — we keep serving the prior catalog.
    @discardableResult
    public func refresh(from url: URL = ImageCatalogStore.refreshURL,
                        session: URLSession = .shared) async -> ImageCatalog? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, resp) = try await session.data(for: request)
            // Non-HTTP responses (file:// via the override base) have no
            // status to check — reaching here means the read succeeded.
            if let http = resp as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) { return nil }
            let parsed = try ImageCatalog.parse(data)
            adoptRemote(parsed)
            try? data.write(to: cacheURL, options: .atomic)
            return parsed
        } catch {
            return nil
        }
    }

    /// Absolute URL for a catalog-relative artifact path.
    public static func artifactURL(for path: String,
                                   base: URL = ImageCatalogStore.publicBase) -> URL? {
        URL(string: path, relativeTo: base)?.absoluteURL
    }
}
