import Crypto
import Foundation
import SandboxEngine
import Testing

// The browser prebuilt-image channel (browser-images/ on the CDN):
// boot-artifact handling, the browser signing domain, and the
// SandboxEngine-bundled baseline. The channel-agnostic machinery is
// covered by ImageCatalogTests.

@Suite("Browser image catalog")
struct BrowserImageCatalogTests {

    /// A published-style browser manifest, as scripts/publish-browser-image.sh
    /// emits via tools/make-img-catalog.mjs: disk + vmlinuz + initrd.
    private static let publishedJSON = """
    {
      "formatVersion": 1,
      "image": {
        "uuid": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        "version": "365",
        "description": "Alpine Linux 3.22 + Chromium",
        "builtAt": "2026-07-06T04:02:11Z",
        "disk": {
          "path": "browser-images/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/base.img.gz",
          "sha256": "aabbcc",
          "compressedBytes": 1500000000,
          "uncompressedBytes": 4831838208,
          "compression": "gzip"
        },
        "boot": [
          {"name": "vmlinuz", "path": "browser-images/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/vmlinuz.gz",
           "sha256": "ddeeff", "compressedBytes": 12000000, "uncompressedBytes": 40000000,
           "compression": "gzip"},
          {"name": "initrd", "path": "browser-images/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/initrd.gz",
           "sha256": "112233", "compressedBytes": 9000000, "uncompressedBytes": 9500000,
           "compression": "gzip"}
        ]
      },
      "postinstall": [
        {"uuid": "w1", "seq": 10, "description": "Cloudflare WARP client", "command": "echo warp"}
      ]
    }
    """

    @Test("Browser distribution constants: prefix, magic, distinct cache file")
    func distributionConstants() {
        let browser = ImageDistribution.browser
        #expect(browser.catalogPrefix == "browser-images")
        #expect(browser.signingMagic == "bromure-browser-img-catalog-v1")
        // AC eventually holds BOTH catalogs in one support dir (when the
        // user installs the web browser from AC) — the cache file names
        // must never collide.
        #expect(browser.cacheFileName == "browser-img-catalog.json")
        #expect(browser.cacheFileName != "img-catalog.json")
        #expect(browser.signingMagic != "bromure-img-catalog-v1")
    }

    @Test("Store refreshURL lands under the channel prefix")
    func storeRefreshURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-browsercat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ImageCatalogStore(distribution: .browser, supportDir: dir)
        #expect(store.refreshURL.absoluteString
            == "https://dl.bromure.io/browser-images/img-catalog.json")
    }

    @Test("Published browser catalog decodes with boot artifacts")
    func decodePublished() throws {
        let cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        let image = try #require(cat.image)
        #expect(image.boot?.count == 2)
        let kernel = try #require(image.bootFile(named: "vmlinuz"))
        #expect(kernel.path.hasSuffix("/vmlinuz.gz"))
        #expect(kernel.uncompressedBytes == 40_000_000)
        #expect(image.bootFile(named: "initrd") != nil)
        #expect(image.bootFile(named: "nonexistent") == nil)
    }

    @Test("AC-shaped catalogs (no boot array) still decode")
    func decodeWithoutBoot() throws {
        let json = """
        {"formatVersion": 1,
         "image": {"uuid": "u", "version": "200", "description": "Ubuntu 24.04",
                   "disk": {"path": "images/u/base.img.gz", "sha256": "aa",
                            "compressedBytes": 1, "uncompressedBytes": 2,
                            "compression": "gzip"}},
         "postinstall": []}
        """
        let cat = try ImageCatalog.parse(Data(json.utf8))
        #expect(cat.image?.boot == nil)
        #expect(cat.image?.bootFile(named: "vmlinuz") == nil)
    }

    @Test("Bundled browser baseline loads with unique step uuids and no image")
    func bundledBaseline() {
        let baseline = ImageDistribution.browser.loadBaseline()
        // The published image itself must be free software; Cloudflare
        // WARP arrives via these steps, so the baseline can never be
        // empty.
        #expect(!baseline.postinstall.isEmpty)
        #expect(baseline.image == nil)
        let uuids = baseline.postinstall.map(\.uuid)
        #expect(Set(uuids).count == uuids.count)
        #expect(baseline.postinstall.allSatisfy { !$0.command.isEmpty })
        #expect(baseline.postinstall.contains { $0.description.contains("WARP") })
    }

    // MARK: - Signature (browser domain + boot artifacts)

    private func makeSignedCatalog(
        key: Curve25519.Signing.PrivateKey,
        magic: String = ImageDistribution.browser.signingMagic
    ) throws -> ImageCatalog {
        var cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        let signedAt = "2026-07-06T10:00:00.000Z"
        let payload = try #require(cat.signingPayload(signedAt: signedAt, magic: magic))
        let sig = try key.signature(for: payload)
        cat.signature = .init(signedAt: signedAt, edSignature: sig.base64EncodedString())
        return cat
    }

    @Test("Signature covers the boot artifacts")
    func bootArtifactsPinned() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let magic = ImageDistribution.browser.signingMagic
        let cat = try makeSignedCatalog(key: key)
        #expect(ImageCatalogStore.isSignatureValid(cat, magic: magic, publicKeyBase64: pub))

        // A swapped kernel is exactly what the signature must catch — it
        // boots with ring-0 in the user's VM.
        var evilKernel = cat
        evilKernel.image?.boot?[0].sha256 = "0000000000"
        #expect(!ImageCatalogStore.isSignatureValid(evilKernel, magic: magic, publicKeyBase64: pub))

        var evilPath = cat
        evilPath.image?.boot?[1].path = "browser-images/evil/initrd.gz"
        #expect(!ImageCatalogStore.isSignatureValid(evilPath, magic: magic, publicKeyBase64: pub))

        // Dropping the boot array entirely must invalidate too.
        var noBoot = cat
        noBoot.image?.boot = nil
        #expect(!ImageCatalogStore.isSignatureValid(noBoot, magic: magic, publicKeyBase64: pub))
    }

    @Test("Boot payload canonicalization: array order irrelevant, sha case-insensitive")
    func bootCanonicalization() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let magic = ImageDistribution.browser.signingMagic
        var cat = try makeSignedCatalog(key: key)
        cat.image?.boot?.reverse()
        let upper = try #require(cat.image?.boot?[0].sha256.uppercased())
        cat.image?.boot?[0].sha256 = upper
        #expect(ImageCatalogStore.isSignatureValid(cat, magic: magic, publicKeyBase64: pub))
    }

    @Test("bromureac step flag: decode, default, and AC filtering")
    func bromureacFlag() throws {
        let json = """
        {"formatVersion": 1, "image": null, "postinstall": [
          {"uuid": "a", "seq": 10, "description": "Web only", "command": "echo w"},
          {"uuid": "b", "seq": 20, "description": "Both", "command": "echo b", "bromureac": true},
          {"uuid": "c", "seq": 30, "description": "Explicit web", "command": "echo c", "bromureac": false}
        ]}
        """
        let cat = try ImageCatalog.parse(Data(json.utf8))
        #expect(cat.postinstall[0].bromureac == nil)
        #expect(!cat.postinstall[0].appliesToAgentCoding)
        #expect(cat.postinstall[1].appliesToAgentCoding)
        #expect(!cat.postinstall[2].appliesToAgentCoding)
        // What Bromure Web runs vs what AC runs.
        #expect(cat.sortedSteps.map(\.uuid) == ["a", "b", "c"])
        #expect(cat.sortedSteps.filter(\.appliesToAgentCoding).map(\.uuid) == ["b"])
    }

    @Test("bromureac is signed only when present — old signatures keep verifying")
    func bromureacSigning() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let magic = ImageDistribution.browser.signingMagic

        // A catalog whose step has NO bromureac field: its payload must
        // carry no line for it (byte-compat with pre-field signatures)…
        var cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        let signedAt = "2026-07-11T10:00:00.000Z"
        let payload = try #require(cat.signingPayload(signedAt: signedAt, magic: magic))
        #expect(!String(decoding: payload, as: UTF8.self).contains("bromureac"))

        // …and with the field set, the line appears and is pinned: a
        // signature over bromureac=true must not verify after a flip.
        cat.postinstall[0].bromureac = true
        let payload2 = try #require(cat.signingPayload(signedAt: signedAt, magic: magic))
        #expect(String(decoding: payload2, as: UTF8.self).contains(".bromureac=true"))
        let sig = try key.signature(for: payload2)
        cat.signature = .init(signedAt: signedAt, edSignature: sig.base64EncodedString())
        #expect(ImageCatalogStore.isSignatureValid(cat, magic: magic, publicKeyBase64: pub))
        var flipped = cat
        flipped.postinstall[0].bromureac = false
        #expect(!ImageCatalogStore.isSignatureValid(flipped, magic: magic, publicKeyBase64: pub))
        var stripped = cat
        stripped.postinstall[0].bromureac = nil
        #expect(!ImageCatalogStore.isSignatureValid(stripped, magic: magic, publicKeyBase64: pub))
    }

    @Test("Cross-channel replay: an AC-signed catalog never verifies as a browser catalog")
    func crossChannelReplay() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        // Signed under the AC domain separator (same key — production
        // uses one Sparkle key for both channels)…
        let acSigned = try makeSignedCatalog(
            key: key, magic: ImageDistribution.agentCoding.signingMagic)
        // …must not verify under the browser domain, and vice versa.
        #expect(!ImageCatalogStore.isSignatureValid(
            acSigned, magic: ImageDistribution.browser.signingMagic, publicKeyBase64: pub))
        #expect(ImageCatalogStore.isSignatureValid(
            acSigned, magic: ImageDistribution.agentCoding.signingMagic, publicKeyBase64: pub))
    }
}

@Suite("Browser image state")
struct BrowserImageStateTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-browserstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Image state round-trips through the manager")
    func stateRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = LinuxImageManager(storageDir: dir)
        #expect(manager.loadImageState() == nil)
        let state = BaseImageState(
            imageUUID: "abc", version: "365", appliedStepUUIDs: ["s1", "s2"])
        manager.writeImageState(state)
        #expect(manager.loadImageState() == state)
    }

    @Test("Legacy migration marks the baseline steps applied (old images baked WARP)")
    func legacyMigration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = LinuxImageManager(storageDir: dir)

        // No boot files → nothing to migrate.
        manager.migrateLegacyImageStateIfNeeded()
        #expect(manager.loadImageState() == nil)

        // Fake a pre-existing local image (all three artifacts + stamp).
        for name in ["linux-base.img", "vmlinuz", "initrd"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        try "364".write(to: manager.imageVersionURL, atomically: true, encoding: .utf8)

        manager.migrateLegacyImageStateIfNeeded()
        let state = try #require(manager.loadImageState())
        #expect(state.imageUUID == nil)
        #expect(state.version == "364")
        let baselineUUIDs = ImageDistribution.browser.loadBaseline().postinstall.map(\.uuid)
        #expect(Set(state.appliedStepUUIDs) == Set(baselineUUIDs))

        // Idempotent: a second run must not clobber the state.
        manager.writeImageState(BaseImageState(
            imageUUID: "keep", version: "364", appliedStepUUIDs: []))
        manager.migrateLegacyImageStateIfNeeded()
        #expect(manager.loadImageState()?.imageUUID == "keep")
    }
}
