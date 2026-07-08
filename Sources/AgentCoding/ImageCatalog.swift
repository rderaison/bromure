import Crypto
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
    /// Ed25519 signature over `signingPayload(signedAt:)`, made by the
    /// publish pipeline with the same Sparkle key that signs app updates
    /// (SUPublicEDKey verifies both). It covers the image identity +
    /// sha256 AND every postinstall command — the commands run as root
    /// inside users' base images, so a compromised CDN bucket must not
    /// be able to alter them.
    public struct Signature: Codable, Sendable, Equatable {
        /// ISO-8601 signing timestamp. Also the rollback guard: clients
        /// never adopt a catalog signed earlier than one they've already
        /// adopted (UTC ISO-8601 compares lexically).
        public var signedAt: String
        /// base64 ed25519 signature.
        public var edSignature: String

        public init(signedAt: String, edSignature: String) {
            self.signedAt = signedAt
            self.edSignature = edSignature
        }
    }

    public var formatVersion: Int
    /// nil in the bundled baseline (which only carries the canonical
    /// postinstall list); always present in a published catalog.
    public var image: RemoteBaseImage?
    public var postinstall: [PostinstallStep]
    /// Required on catalogs fetched from the production CDN; nil in the
    /// bundled baseline and in test catalogs served via the
    /// BROMURE_IMAGE_CATALOG_BASE override.
    public var signature: Signature?

    public init(formatVersion: Int = 1, image: RemoteBaseImage? = nil,
                postinstall: [PostinstallStep], signature: Signature? = nil) {
        self.formatVersion = formatVersion
        self.image = image
        self.postinstall = postinstall
        self.signature = signature
    }

    /// The canonical byte string the signature covers — semantic fields,
    /// not raw JSON bytes, so formatting/key-order can never break
    /// verification. tools/make-img-catalog.mjs builds the IDENTICAL
    /// string; any change here is a format break that must be made in
    /// both places (and bump the version line). Free-text fields are
    /// base64'd so embedded newlines can't smuggle extra payload lines.
    /// nil when there's no image (a baseline is never signed).
    public func signingPayload(signedAt: String) -> Data? {
        guard let image else { return nil }
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        var lines = [
            "bromure-img-catalog-v1",
            "signedAt=\(signedAt)",
            "formatVersion=\(formatVersion)",
            "image.uuid=\(image.uuid)",
            "image.version=\(image.version)",
            "image.description.b64=\(b64(image.description))",
            "image.builtAt=\(image.builtAt ?? "")",
            "image.disk.path=\(image.disk.path)",
            "image.disk.sha256=\(image.disk.sha256.lowercased())",
            "image.disk.compressedBytes=\(image.disk.compressedBytes)",
            "image.disk.uncompressedBytes=\(image.disk.uncompressedBytes)",
            "image.disk.compression=\(image.disk.compression)",
        ]
        for step in postinstall.sorted(by: { $0.uuid < $1.uuid }) {
            lines.append("step.\(step.uuid).seq=\(step.seq)")
            lines.append("step.\(step.uuid).description.b64=\(b64(step.description))")
            lines.append("step.\(step.uuid).command.b64=\(b64(step.command))")
        }
        return Data(lines.joined(separator: "\n").utf8)
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

    /// This catalog with any baseline step it doesn't already carry
    /// appended (matched by uuid). The bundled img-catalog.json is the
    /// canonical postinstall list, but the *published* catalog lags an app
    /// release by up to a week — without this union, a step shipped in the
    /// app binary can't reach existing images until the next image
    /// publish. Bundled steps carry the app's own distribution trust, so
    /// this doesn't weaken the signature gate on fetched catalogs.
    public func includingBaselineSteps(_ baseline: ImageCatalog = .baseline) -> ImageCatalog {
        let known = Set(postinstall.map(\.uuid))
        let extra = baseline.postinstall.filter { !known.contains($0.uuid) }
        guard !extra.isEmpty else { return self }
        var merged = self
        merged.postinstall += extra
        return merged
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
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? ImageCatalog.parse(data) {
            // The cache is re-verified on load: it sits on disk where
            // anything running as the user could edit it, and trusting
            // it unsigned would bypass the fetch-time check below.
            if Self.overrideBase != nil || Self.isSignatureValid(cached) {
                self.cachedRemote = cached
            }
        }
    }

    // MARK: - Signature verification

    /// The ed25519 public key catalog signatures verify against — the
    /// same Sparkle key that signs app updates. Read from Info.plist
    /// (SUPublicEDKey) when running from the app bundle; the constant
    /// covers bare-binary contexts (swift build output, unit tests) and
    /// MUST match Sources/AgentCoding/Info.plist.
    static var pinnedPublicKeyBase64: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            ?? "G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8="
    }

    /// True when `catalog` carries a signature that verifies against
    /// `publicKeyBase64` over the canonical payload.
    static func isSignatureValid(
        _ catalog: ImageCatalog,
        publicKeyBase64: String = ImageCatalogStore.pinnedPublicKeyBase64
    ) -> Bool {
        guard let sig = catalog.signature,
              let payload = catalog.signingPayload(signedAt: sig.signedAt),
              let sigData = Data(base64Encoded: sig.edSignature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(sigData, for: payload)
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
            // Production catalogs MUST carry a valid signature: the
            // postinstall commands run as root in every user's base
            // image, so TLS + bucket ACLs alone aren't enough — the
            // catalog is anchored to the (Jenkins-held) Sparkle key.
            // Only the explicit BROMURE_IMAGE_CATALOG_BASE override
            // (local pipeline tests) skips this; a missing signature is
            // as fatal as a bad one so it can't be stripped.
            if Self.overrideBase == nil {
                guard Self.isSignatureValid(parsed) else { return nil }
                // Rollback guard: never adopt a catalog signed earlier
                // than one already adopted — replaying an old, validly
                // signed catalog could reintroduce a retired image or
                // step. (UTC ISO-8601 timestamps compare lexically.)
                if let prev = remote()?.signature?.signedAt,
                   let fresh = parsed.signature?.signedAt,
                   fresh < prev {
                    return nil
                }
            }
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
