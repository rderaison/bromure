import CryptoKit
import Foundation

// MARK: - img-catalog.json model (shared by every prebuilt-image channel)
//
// The manifest format that drives prebuilt-base-image distribution. Two
// channels publish it today, each under its own CDN prefix:
//
//   • Bromure Agentic Coding — https://dl.bromure.io/images/img-catalog.json
//     (scripts/publish-image.sh, Jenkinsfile.image). Single EFI-bootable
//     disk artifact (base.img.gz).
//   • Bromure Web            — https://dl.bromure.io/browser-images/img-catalog.json
//     (scripts/publish-browser-image.sh, Jenkinsfile.browser-image). Disk
//     artifact plus `boot` files (vmlinuz.gz, initrd.gz) because the
//     browser image boots via VZLinuxBootLoader, not EFI/GRUB.
//
// The channel-specific bits (CDN prefix, signing-payload magic, bundled
// baseline, support dir) live in `ImageDistribution`; everything else —
// parsing, signature verification, fetch/cache — is common. Bromure
// Agentic Coding reuses the browser distribution as-is when the user opts
// into installing the web-browser image from AC.
//
// Two independent update axes:
//   • `image.version` — the base-image version (mirrors the app's
//     imageVersion constant at publish time). Weekly package-refresh
//     rebuilds keep the version, so only new installations pick them up.
//   • `postinstall[].uuid` — each step is identified by a stable uuid. A
//     step uuid the local image hasn't applied yet is a "new recommended
//     package": surfaced to the user for consent, then executed in a
//     chroot against the base image (postinstall.sh). Steps are ordered
//     by `seq`.
//
// Postinstall steps are how non-free software (Claude Code, Codex, Grok,
// gcloud for AC; Cloudflare WARP for the browser) reaches the user's
// machine: the published images contain free software only, so they can
// be redistributed.

/// One postinstall command from img-catalog.json. `command` is a shell
/// fragment executed as root inside a chroot on the base image (shell -e,
/// up to 3 attempts). `seq` orders execution; `uuid` identifies the step
/// across catalog updates so we can tell "already applied" from "new".
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
    /// Compressed disk artifact, keyed under `<prefix>/<uuid>/` on the CDN.
    public struct Disk: Codable, Sendable, Equatable {
        /// Object key relative to the CDN base, e.g.
        /// `images/3f…/base.img.gz`.
        public var path: String
        /// SHA-256 (hex) of the *compressed* file — verified before
        /// decompression.
        public var sha256: String
        public var compressedBytes: Int64
        /// Logical size of the decompressed raw disk.
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

    /// A compressed non-disk boot artifact published alongside the disk.
    /// The browser image needs `vmlinuz` and `initrd` on the host because
    /// it boots via VZLinuxBootLoader (direct kernel boot); the AC image
    /// has none (GRUB lives on its EFI partition).
    public struct BootFile: Codable, Sendable, Equatable {
        /// Stable artifact name the client keys on: "vmlinuz" | "initrd".
        public var name: String
        /// Object key relative to the CDN base.
        public var path: String
        /// SHA-256 (hex) of the compressed file.
        public var sha256: String
        public var compressedBytes: Int64
        public var uncompressedBytes: Int64
        public var compression: String

        public init(name: String, path: String, sha256: String,
                    compressedBytes: Int64, uncompressedBytes: Int64,
                    compression: String = "gzip") {
            self.name = name
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
    /// Image version — mirrors the publishing app's imageVersion constant
    /// at build time, possibly with a dot-revision.
    public var version: String
    /// Human description, e.g. "Ubuntu 24.04" or "Alpine Linux 3.22 + Chromium".
    public var description: String
    /// ISO-8601 build timestamp (informational).
    public var builtAt: String?
    public var disk: Disk
    /// nil for catalogs that publish a single self-booting disk (AC).
    public var boot: [BootFile]?

    public init(uuid: String, version: String, description: String,
                builtAt: String? = nil, disk: Disk, boot: [BootFile]? = nil) {
        self.uuid = uuid
        self.version = version
        self.description = description
        self.builtAt = builtAt
        self.disk = disk
        self.boot = boot
    }

    /// The boot artifact named `name`, if the catalog carries one.
    public func bootFile(named name: String) -> BootFile? {
        boot?.first { $0.name == name }
    }
}

/// A parsed img-catalog.json.
public struct ImageCatalog: Codable, Sendable, Equatable {
    /// Ed25519 signature over `signingPayload(signedAt:magic:)`, made by
    /// the publish pipeline with the same Sparkle key that signs app
    /// updates (SUPublicEDKey verifies both). It covers the image identity
    /// + sha256 AND every postinstall command — the commands run as root
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
    /// both places (and bump the magic line). Free-text fields are
    /// base64'd so embedded newlines can't smuggle extra payload lines.
    /// nil when there's no image (a baseline is never signed).
    ///
    /// `magic` is the distribution's domain separator
    /// (`ImageDistribution.signingMagic`) — it's what stops a validly
    /// signed AC catalog from being replayed at the browser catalog URL
    /// (and vice versa), since both channels sign with the same key.
    public func signingPayload(signedAt: String, magic: String) -> Data? {
        guard let image else { return nil }
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        var lines = [
            magic,
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
        // Boot artifacts (browser channel). Absent entirely for AC
        // catalogs, which keeps their payload byte-identical to the
        // pre-boot-files format.
        for file in (image.boot ?? []).sorted(by: { $0.name < $1.name }) {
            lines.append("boot.\(file.name).path=\(file.path)")
            lines.append("boot.\(file.name).sha256=\(file.sha256.lowercased())")
            lines.append("boot.\(file.name).compressedBytes=\(file.compressedBytes)")
            lines.append("boot.\(file.name).uncompressedBytes=\(file.uncompressedBytes)")
            lines.append("boot.\(file.name).compression=\(file.compression)")
        }
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

    public static func parse(_ data: Data) throws -> ImageCatalog {
        try JSONDecoder().decode(ImageCatalog.self, from: data)
    }

    /// Load a bundled baseline resource; falls back to an empty step list
    /// if the resource is missing/corrupt, so setup still completes (with
    /// a free-software image and no extra packages) rather than trapping.
    public static func loadBaseline(bundle: Bundle, resource: String) -> ImageCatalog {
        if let url = bundle.url(forResource: resource, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cat = try? parse(data) {
            return cat
        }
        return embeddedFallback
    }

    /// Last-resort safety net if a bundled baseline JSON is ever
    /// missing/corrupt.
    static let embeddedFallback = ImageCatalog(formatVersion: 1, image: nil, postinstall: [])
}

// MARK: - Distribution (per-channel configuration)

/// Everything that differs between prebuilt-image channels. The catalog
/// format, signature scheme, fetch/cache logic, and download plumbing are
/// shared; a distribution supplies the CDN prefix, the signing-payload
/// domain separator, the cache file name, and the bundled baseline.
public struct ImageDistribution: Sendable {
    /// CDN path prefix the channel publishes under: `<prefix>/img-catalog.json`
    /// and `<prefix>/<uuid>/<artifact>`.
    public let catalogPrefix: String
    /// First line of the signing payload — a domain separator so a
    /// catalog signed for one channel can't be replayed on another
    /// (both channels sign with the same Sparkle key).
    public let signingMagic: String
    /// File name the fetched catalog is cached under in Application
    /// Support. Distinct per channel so one app can hold both (AC caches
    /// the browser catalog next to its own when the user installs the
    /// web browser).
    public let cacheFileName: String
    /// Application Support subdirectory used when no explicit support
    /// dir is passed to the store.
    public let defaultSupportDirName: String
    /// Loads the bundled baseline catalog (canonical postinstall list,
    /// offline fallback).
    public let loadBaseline: @Sendable () -> ImageCatalog

    public init(catalogPrefix: String, signingMagic: String, cacheFileName: String,
                defaultSupportDirName: String,
                loadBaseline: @escaping @Sendable () -> ImageCatalog) {
        self.catalogPrefix = catalogPrefix
        self.signingMagic = signingMagic
        self.cacheFileName = cacheFileName
        self.defaultSupportDirName = defaultSupportDirName
        self.loadBaseline = loadBaseline
    }

    /// The Bromure Web browser image (Alpine + Chromium, three boot
    /// artifacts). Lives in SandboxEngine so Bromure Agentic Coding can
    /// download/postinstall the browser image with the exact same code
    /// when the user opts into the embedded web browser.
    public static let browser = ImageDistribution(
        catalogPrefix: "browser-images",
        signingMagic: "bromure-browser-img-catalog-v1",
        cacheFileName: "browser-img-catalog.json",
        defaultSupportDirName: "Bromure",
        loadBaseline: {
            ImageCatalog.loadBaseline(bundle: LinuxImageManager.resourceBundle,
                                      resource: "browser-img-catalog")
        }
    )
}

// MARK: - Store (fetch + cache)

/// Fetches and caches a channel's img-catalog.json — same pattern as the
/// MLX `CatalogStore`: remote manifest cached in Application Support,
/// bundled baseline as the offline fallback.
public final class ImageCatalogStore: @unchecked Sendable {
    /// The browser-image channel store (shared instance).
    public static let browser = ImageCatalogStore(distribution: .browser)

    /// Base the catalog's relative artifact paths resolve against.
    public static let defaultPublicBase = URL(string: "https://dl.bromure.io/")!

    /// `BROMURE_IMAGE_CATALOG_BASE` env override — points the catalog
    /// fetch AND artifact resolution at another root, e.g. the `file://`
    /// staging dir the local pipeline-test scripts assemble, or a
    /// localhost server in tests. Layout under the base must mirror the
    /// CDN (`<prefix>/img-catalog.json`, `<prefix>/<uuid>/<artifact>`).
    static var overrideBase: URL? {
        guard let raw = ProcessInfo.processInfo.environment["BROMURE_IMAGE_CATALOG_BASE"],
              !raw.isEmpty else { return nil }
        return URL(string: raw.hasSuffix("/") ? raw : raw + "/")
    }

    /// The artifact base actually in effect (override-aware).
    public static var publicBase: URL {
        overrideBase ?? defaultPublicBase
    }

    public let distribution: ImageDistribution
    /// The channel's bundled baseline (canonical postinstall list).
    public let baseline: ImageCatalog

    private let cacheURL: URL
    private let lock = NSLock()
    private var cachedRemote: ImageCatalog?

    /// The manifest URL actually in effect for this channel (override-aware).
    public var refreshURL: URL {
        let path = "\(distribution.catalogPrefix)/img-catalog.json"
        return Self.overrideBase.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
            ?? URL(string: path, relativeTo: Self.defaultPublicBase)!.absoluteURL
    }

    public init(distribution: ImageDistribution, supportDir: URL? = nil) {
        self.distribution = distribution
        self.baseline = distribution.loadBaseline()
        let support = supportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(distribution.defaultSupportDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.cacheURL = support.appendingPathComponent(distribution.cacheFileName)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? ImageCatalog.parse(data) {
            // The cache is re-verified on load: it sits on disk where
            // anything running as the user could edit it, and trusting
            // it unsigned would bypass the fetch-time check below.
            if Self.overrideBase != nil || isSignatureValid(cached) {
                self.cachedRemote = cached
            }
        }
    }

    // MARK: - Signature verification

    /// The ed25519 public key catalog signatures verify against — the
    /// same Sparkle key that signs app updates. Read from Info.plist
    /// (SUPublicEDKey) when running from an app bundle; the constant
    /// covers bare-binary contexts (swift build output, unit tests) and
    /// MUST match Sources/Browser/Info.plist and
    /// Sources/AgentCoding/Info.plist (they carry the same key).
    public static var pinnedPublicKeyBase64: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            ?? "G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8="
    }

    /// True when `catalog` carries a signature that verifies against
    /// `publicKeyBase64` over the canonical payload built with `magic`.
    public static func isSignatureValid(
        _ catalog: ImageCatalog,
        magic: String,
        publicKeyBase64: String = ImageCatalogStore.pinnedPublicKeyBase64
    ) -> Bool {
        guard let sig = catalog.signature,
              let payload = catalog.signingPayload(signedAt: sig.signedAt, magic: magic),
              let sigData = Data(base64Encoded: sig.edSignature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(sigData, for: payload)
    }

    /// Channel-scoped convenience over the static verifier.
    public func isSignatureValid(_ catalog: ImageCatalog) -> Bool {
        Self.isSignatureValid(catalog, magic: distribution.signingMagic)
    }

    // MARK: - Access

    /// The best catalog we have: last fetched manifest, else the baseline.
    public func effective() -> ImageCatalog {
        lock.lock(); defer { lock.unlock() }
        return cachedRemote ?? baseline
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
    public func refresh(from url: URL? = nil,
                        session: URLSession = .shared) async -> ImageCatalog? {
        var request = URLRequest(url: url ?? refreshURL)
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
                guard isSignatureValid(parsed) else { return nil }
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

// MARK: - Image state (source + applied postinstall steps)

/// Sidecar to the version stamp: which published image build the on-disk
/// base image came from (nil = built locally) and which img-catalog
/// postinstall steps have been applied to it. The diff between the
/// catalog's steps and `appliedStepUUIDs` drives the "new packages are
/// recommended" consent prompt. Shared by both channels.
public struct BaseImageState: Codable, Sendable, Equatable {
    public var imageUUID: String?
    public var version: String
    public var appliedStepUUIDs: [String]

    public init(imageUUID: String?, version: String, appliedStepUUIDs: [String]) {
        self.imageUUID = imageUUID
        self.version = version
        self.appliedStepUUIDs = appliedStepUUIDs
    }
}
