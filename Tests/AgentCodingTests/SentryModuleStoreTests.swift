import CryptoKit
import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// Serves canned responses for the sentry store's session, per host (tests
/// run in parallel, each with its own host).
final class SentryStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: [String: (Int, Data)]] = [:]
    nonisolated(unsafe) static var hits: [String: [String]] = [:]
    static let lock = NSLock()
    static func serve(_ host: String, _ path: String, _ status: Int, _ body: Data) {
        lock.lock(); routes[host, default: [:]][path] = (status, body); lock.unlock()
    }
    static func hitCount(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return hits[host]?.count ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        let r = Self.routes[url.host ?? ""]?[url.path]
        Self.hits[url.host ?? "", default: []].append(url.path)
        Self.lock.unlock()
        let (status, body) = r ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Kernel sentry modules from the CDN")
struct SentryModuleStoreTests {
    /// Signed by tools/make-sentry-catalog.mjs with a throwaway key (the
    /// public half below): the Swift verifier must accept Node's bytes.
    static let nodeSigned = #"""
{
  "formatVersion": 1,
  "sourceHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "modules": [
    {
      "kernel": "6.8.0-139-generic",
      "path": "sentry/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/6.8.0-139-generic/bromure_sentry-6.8.0-139-generic-a0656a0f8ff3.ko",
      "sha256": "a0656a0f8ff326f90b7373204b4c3dac0fedc4576db88e24d7df61f31845e8aa",
      "bytes": 8,
      "builtAt": "2026-10-03T18:54:42.496Z",
      "signature": "Pd6Qr80gRenJ3F3IBb/It/f1TEwDfnAL3t/Z2ADb7cRGI0BrVAMXokjcvNOPWD5q25hdnGZ+mJt14d8kuFCvCw=="
    },
    {
      "kernel": "6.8.0-142-generic",
      "path": "sentry/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/6.8.0-142-generic/bromure_sentry-6.8.0-142-generic-b714b2e23f3f.ko",
      "sha256": "b714b2e23f3fd76e4d8f0b7f50d44c915ee358c0c085ecca1ed1c65a01f25905",
      "bytes": 14,
      "builtAt": "2026-10-03T18:54:42.501Z",
      "signature": "n2oy5tZnLwHK8f/ZUWTjB/5akPw/DbagrJPVkpGMzcUYm4NUyIW2QmhbR5Vkk2WcakucyksmDWcrz6DivNYdAA=="
    }
  ],
  "signature": {
    "signedAt": "2026-10-03T18:54:42.501Z",
    "edSignature": "SnHHCNoU48QPYEutvAKFa6ofi/0FPc3Bjq+ssmF1/oZFNSnLpSjGoyi1vl2cxsafhiuPjTut+zv1VPIajy8BAg=="
  }
}
"""#
    static let testPublicKey = "EF4W/MAp9ZmLXzSPquq34DlErSKulVvL7r2QLUs+V78="
    static let hash = String(repeating: "a", count: 64)

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sentry-store-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func store(host: String, root: URL, requireSignature: Bool = true) -> SentryModuleStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SentryStubProtocol.self]
        return SentryModuleStore(root: root, base: URL(string: "https://\(host)/")!, requireSignature: requireSignature,
                                 publicKeyBase64: Self.testPublicKey, session: URLSession(configuration: config))
    }

    func serveCatalog(_ host: String, _ json: String = SentryModuleStoreTests.nodeSigned) {
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/catalog.json", 200, Data(json.utf8))
        // The fixture's module bodies (see make-sentry-catalog's test run).
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/6.8.0-142-generic/bromure_sentry-6.8.0-142-generic-b714b2e23f3f.ko",
                                 200, Data("module-A-bytes".utf8))
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/6.8.0-139-generic/bromure_sentry-6.8.0-139-generic-a0656a0f8ff3.ko",
                                 200, Data("module-B".utf8))
    }

    @Test("A catalog signed by the Node publisher verifies in Swift; any edit breaks it")
    func crossLanguageSignature() throws {
        let c = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        #expect(c.isSignatureValid(publicKeyBase64: Self.testPublicKey))
        #expect(c.isWellFormed(for: Self.hash))
        #expect(!c.isSignatureValid(publicKeyBase64: ImageCatalogStore.pinnedPublicKeyBase64))
        var edited = c
        edited.modules[0].sha256 = String(repeating: "0", count: 64)
        #expect(!edited.isSignatureValid(publicKeyBase64: Self.testPublicKey))
        var moved = c
        moved.modules[0].path = "sentry/\(Self.hash)/../../elsewhere.ko"
        #expect(!moved.isWellFormed(for: Self.hash))
        #expect(!c.isWellFormed(for: String(repeating: "b", count: 64)))
    }

    @Test("Source hash matches scripts/openshell-guest/sentry/source-hash.sh")
    func sourceHashVector() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("obj-m := x.o\n".utf8).write(to: dir.appendingPathComponent("Makefile"))
        try Data("int x;\n".utf8).write(to: dir.appendingPathComponent("bromure_sentry.c"))
        try Data("#define Y 1\n".utf8).write(to: dir.appendingPathComponent("bromure_sentry.h"))
        // Computed by source-hash.sh over the same three files.
        #expect(SentryModuleStore.sourceHash(of: dir) == "ce5871986055601b2c373551dd5915bfe18b6be62419036566a2cb194ad87a9a")
    }

    @Test("Download, verify, cache, stage; a second ask doesn't hit the network")
    func downloadAndStage() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        serveCatalog(host)
        let s = store(host: host, root: root)
        #expect(await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
        let hitsAfterFirst = SentryStubProtocol.hitCount(host)
        #expect(await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
        #expect(SentryStubProtocol.hitCount(host) == hitsAfterFirst)
        let meta = root.appendingPathComponent("meta/sentry")
        #expect(s.stage(kernels: ["6.8.0-142-generic", "6.8.0-139-generic"], hash: Self.hash, into: meta) == ["6.8.0-142-generic"])
        #expect(try Data(contentsOf: meta.appendingPathComponent("bromure_sentry-6.8.0-142-generic.ko")) == Data("module-A-bytes".utf8))
        // A "none coming" marker for a kernel is cleared once it's staged.
        s.markUnavailable(["6.8.0-139-generic": "no module published for 6.8.0-139-generic yet",
                           "6.8.0-142-generic": "stale"], in: meta)
        #expect(try String(contentsOf: meta.appendingPathComponent("bromure_sentry-6.8.0-139-generic.unavailable"), encoding: .utf8)
                == "no module published for 6.8.0-139-generic yet\n")
        s.stage(kernels: ["6.8.0-142-generic"], hash: Self.hash, into: meta)
        #expect(!FileManager.default.fileExists(atPath: meta.appendingPathComponent("bromure_sentry-6.8.0-142-generic.unavailable").path))
        // A cached file edited on disk is never staged.
        try Data("evil".utf8).write(to: root.appendingPathComponent("\(Self.hash)/bromure_sentry-6.8.0-142-generic.ko"))
        let meta2 = root.appendingPathComponent("meta2/sentry")
        #expect(s.stage(kernels: ["6.8.0-142-generic"], hash: Self.hash, into: meta2).isEmpty)
    }

    @Test("A module whose bytes don't match the signed catalog is refused")
    func badModuleRefused() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        serveCatalog(host)
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/6.8.0-142-generic/bromure_sentry-6.8.0-142-generic-b714b2e23f3f.ko",
                                 200, Data("module-A-bytez".utf8))
        let s = store(host: host, root: root)
        let why = await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash)
        #expect(why?.contains("signed checksum") == true)
        #expect(s.verifiedModule(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
    }

    @Test("Unsigned or foreign-key catalogs are refused; unknown kernels say so")
    func refusals() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        var c = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        c.signature = nil
        serveCatalog(host, String(data: try JSONEncoder().encode(c), encoding: .utf8)!)
        let s = store(host: host, root: root)
        #expect(await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash)?.contains("no module catalog") == true)
        // With an override base (tests / staging) unsigned is accepted…
        let lax = store(host: host, root: tempDir(), requireSignature: false)
        #expect(await lax.ensure(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
        // …and a kernel nobody built is named in the reason.
        #expect(await lax.ensure(kernel: "6.8.0-150-generic", hash: Self.hash) == "no module published for 6.8.0-150-generic yet")
        #expect(await lax.ensure(kernel: "../../etc", hash: Self.hash)?.hasPrefix("not a kernel release") == true)
    }

    @Test("An older catalog never replaces a newer cached one")
    func rollbackGuard() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        serveCatalog(host)
        let s = store(host: host, root: root, requireSignature: false)
        let first = await s.refreshCatalog(Self.hash, force: true)
        var older = first!
        older.signature?.signedAt = "2020-01-01T00:00:00.000Z"
        older.modules = []
        serveCatalog(host, String(data: try JSONEncoder().encode(older), encoding: .utf8)!)
        let second = await s.refreshCatalog(Self.hash, force: true)
        #expect(second?.modules.count == 2)
    }

    @Test("Kernels are remembered per workspace, running kernel first, junk dropped")
    func knownKernels() {
        let s = SentryModuleStore(root: tempDir(), base: URL(string: "https://x.test/")!, requireSignature: true)
        let a = UUID(), b = UUID()
        #expect(s.record(kernels: ["6.8.0-142-generic", "6.8.0-139-generic", "6.8.0-142-generic", "../x"], for: a))
        #expect(!s.record(kernels: ["6.8.0-142-generic", "6.8.0-139-generic"], for: a))
        s.record(kernels: ["6.8.0-150-generic"], for: b)
        #expect(s.knownKernels(for: a) == ["6.8.0-142-generic", "6.8.0-139-generic"])
        #expect(s.knownKernels(for: b) == ["6.8.0-150-generic"])
    }

    @Test("Each module carries its own signature over a domain-separated statement")
    func moduleSignatures() throws {
        let c = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        for m in c.modules { #expect(c.isModuleSignatureValid(m, publicKeyBase64: Self.testPublicKey)) }
        // Moving a valid signature to another module, or editing what it covers, breaks it.
        var swapped = c.modules[0]; swapped.signature = c.modules[1].signature
        #expect(!c.isModuleSignatureValid(swapped, publicKeyBase64: Self.testPublicKey))
        var resized = c.modules[0]; resized.bytes += 1
        #expect(!c.isModuleSignatureValid(resized, publicKeyBase64: Self.testPublicKey))
        // The statement is never the raw module bytes (a Sparkle update
        // signature covers raw bytes; the two must not be interchangeable).
        let payload = SentryModuleCatalog.moduleSigningPayload(sourceHash: c.sourceHash, c.modules[0])
        #expect(String(decoding: payload, as: UTF8.self).hasPrefix("bromure-sentry-module-v1\n"))
    }

    @Test("A module without its own valid signature is refused even when the catalog is signed")
    func unsignedModuleRefused() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        var c = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        // Strip the module signature but keep the catalog signature valid
        // (module signatures aren't part of the catalog payload).
        c.modules = c.modules.map { var m = $0; if m.kernel == "6.8.0-142-generic" { m.signature = nil }; return m }
        #expect(c.isSignatureValid(publicKeyBase64: Self.testPublicKey))
        serveCatalog(host, String(data: try JSONEncoder().encode(c), encoding: .utf8)!)
        let s = store(host: host, root: root)
        #expect(await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash) == "the 6.8.0-142-generic module isn't signed by Bromure")
        #expect(await s.ensure(kernel: "6.8.0-139-generic", hash: Self.hash) == nil)
    }

}
