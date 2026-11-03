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

    /// The module CI builds (scripts/openshell-guest/sentry, Jenkinsfile.sentry's
    /// SENTRY_DIR) and the copy the app ships and hashes (vm-setup/sentry-dist)
    /// must be the same bytes: otherwise the app asks for a source hash nothing
    /// is published under, and a fix to one never reaches a guest.
    @Test("The bundled sentry source is the one CI builds")
    func bundledSourceMatchesCI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ci = root.appendingPathComponent("scripts/openshell-guest/sentry")
        let bundled = root.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/sentry-dist/src")
        for f in ["Makefile", "bromure_sentry.c", "bromure_sentry.h"] {
            #expect(try Data(contentsOf: ci.appendingPathComponent(f)) == Data(contentsOf: bundled.appendingPathComponent(f)),
                    "\(f) differs")
        }
        #expect(SentryModuleStore.sourceHash(of: ci) == SentryModuleStore.sourceHash(of: bundled))
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

    /// Finding (CWE-670): "A transient module download failure aborts the
    /// guest wait for good". Every failure wrote the `.unavailable` marker
    /// that ends the guest's 45 s wait — a failed download or an offline
    /// catalog included. Only a definitive one does now.
    @Test("A missing or untrusted module is definitive; offline, a failed or corrupted download aren't")
    func definitiveOrTransient() async throws {
        let k = "6.8.0-142-generic"
        // Offline / refused catalog: retry.
        let off = "cdn-\(UUID().uuidString.prefix(8)).test"
        let s1 = store(host: off, root: tempDir())
        #expect(await s1.ensureOutcome(kernel: k, hash: Self.hash)?.definitive == false)
        // A kernel the signed catalog doesn't list: stop waiting.
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        serveCatalog(host)
        let s2 = store(host: host, root: tempDir())
        let none = await s2.ensureOutcome(kernel: "6.8.0-150-generic", hash: Self.hash)
        #expect(none?.definitive == true && none?.reason.contains("no module published") == true)
        #expect(await s2.ensureOutcome(kernel: "../../etc", hash: Self.hash)?.definitive == true)
        // A failed download, then a corrupted one: retry.
        let s3 = store(host: host, root: tempDir())
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/\(k)/bromure_sentry-\(k)-b714b2e23f3f.ko", 503, Data())
        #expect(await s3.ensureOutcome(kernel: k, hash: Self.hash)?.definitive == false)
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/\(k)/bromure_sentry-\(k)-b714b2e23f3f.ko", 200, Data("module-A-bytez".utf8))
        #expect(await s3.ensureOutcome(kernel: k, hash: Self.hash)?.definitive == false)
        // …and once it's served right, the retry succeeds.
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/\(k)/bromure_sentry-\(k)-b714b2e23f3f.ko", 200, Data("module-A-bytes".utf8))
        #expect(await s3.ensureOutcome(kernel: k, hash: Self.hash) == nil)
    }

    /// Finding (CWE-670): "A failed sentry-catalog refresh is treated as
    /// proof the kernel was never published". A cached catalog without the
    /// kernel forces a refresh; when that failed, the cached one came back
    /// and its missing entry was reported definitive, ending the guest's wait.
    @Test("A kernel missing from the cached catalog is definitive only when a fresh catalog agrees")
    func failedRefreshIsTransient() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let k = "6.8.0-150-generic"          // published after the cached catalog
        serveCatalog(host)
        let s = store(host: host, root: root)
        #expect(await s.refreshCatalog(Self.hash, force: true)?.modules.count == 2)
        let path = "/sentry/\(Self.hash)/catalog.json"
        // The refresh fails: a server error, a body that doesn't decode, a
        // catalog that doesn't verify, the server gone — all retried.
        var unsigned = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        unsigned.signature = nil
        for (status, body) in [(503, Data()), (200, Data("<html>".utf8)),
                               (200, try JSONEncoder().encode(unsigned)), (404, Data())] {
            SentryStubProtocol.serve(host, path, status, body)
            let f = await s.ensureOutcome(kernel: k, hash: Self.hash)
            #expect(f?.definitive == false, "HTTP \(status) \(body.count) bytes: \(f?.reason ?? "nil")")
        }
        // The server's current catalog still doesn't list it: now it's definitive.
        serveCatalog(host)
        let none = await s.ensureOutcome(kernel: k, hash: Self.hash)
        #expect(none?.definitive == true && none?.reason.contains("no module published") == true)
    }

    @Test("With nothing cached, a rejected first catalog doesn't stop the retries from fetching")
    func rejectedFirstCatalogRetries() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        var unsigned = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        unsigned.signature = nil
        serveCatalog(host, String(data: try JSONEncoder().encode(unsigned), encoding: .utf8)!)
        let s = store(host: host, root: root)
        #expect(await s.ensureOutcome(kernel: "6.8.0-142-generic", hash: Self.hash)?.definitive == false)
        // Fixed on the server seconds later: the next retry gets it.
        serveCatalog(host)
        #expect(await s.ensureOutcome(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
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

    /// Finding (CWE-347): "Sentry catalog signature omits module
    /// signatures, so a bucket write disables every prebuilt module" — the
    /// catalog signature doesn't cover the per-module signatures, so a
    /// bucket write could strip them and the still-"valid" catalog replaced
    /// the good cached one. A catalog is taken only when every module's own
    /// signature verifies too.
    @Test("A catalog with a stripped module signature is refused whole, and the cached one is kept")
    func strippedModuleSignatureKeepsCache() async throws {
        let host = "cdn-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(host: host, root: root)
        serveCatalog(host)
        #expect(await s.refreshCatalog(Self.hash, force: true)?.modules.count == 2)

        var c = try JSONDecoder().decode(SentryModuleCatalog.self, from: Data(Self.nodeSigned.utf8))
        c.modules = c.modules.map { var m = $0; if m.kernel == "6.8.0-142-generic" { m.signature = nil }; return m }
        // Module signatures aren't part of the catalog payload: still "valid".
        #expect(c.isSignatureValid(publicKeyBase64: Self.testPublicKey))
        // Same signedAt: the rollback guard lets it through, only the module check stops it.
        serveCatalog(host, String(data: try JSONEncoder().encode(c), encoding: .utf8)!)
        let kept = await s.refreshCatalog(Self.hash, force: true)
        #expect(kept?.modules.allSatisfy { $0.signature != nil } == true)
        #expect(await s.ensure(kernel: "6.8.0-142-generic", hash: Self.hash) == nil)
        #expect(await s.ensure(kernel: "6.8.0-139-generic", hash: Self.hash) == nil)

        // With nothing cached there's no catalog to fall back to.
        let fresh = store(host: host, root: tempDir())
        #expect(await fresh.ensure(kernel: "6.8.0-139-generic", hash: Self.hash)?.contains("no module catalog") == true)
    }

    @Test("The publisher re-signs kept statements a bucket write stripped, and refuses when nothing vouches for them")
    func publisherResignsStrippedModules() throws {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/make-sentry-catalog.mjs")
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let driver = dir.appendingPathComponent("drive.mjs")
        try #"""
        import { generateKeyPairSync, createPublicKey } from "node:crypto";
        import { execFileSync } from "node:child_process";
        import { mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
        const [tool, dir] = process.argv.slice(2);
        const hash = "a".repeat(64);
        const { privateKey } = generateKeyPairSync("ed25519");
        const env = { ...process.env, SPARKLE_PRIVATE_KEY: privateKey.export({ format: "der", type: "pkcs8" }).subarray(16).toString("base64") };
        const pub = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(12).toString("base64");
        const run = (mods, extra) => { try { execFileSync("node", [tool, "--source-hash", hash, "--modules", mods, "--public-key", pub, ...extra], { env, stdio: "pipe" }); return 0; } catch (e) { return e.status; } };
        const a = `${dir}/a`, b = `${dir}/b`, none = `${dir}/none`;
        for (const d of [a, b, none]) mkdirSync(d);
        writeFileSync(`${a}/bromure_sentry-6.8.0-139-generic.ko`, "module-A");
        writeFileSync(`${a}/bromure_sentry-6.8.0-142-generic.ko`, "module-B-bytes");
        const out = {};
        out.first = run(a, ["--out", `${dir}/c1.json`]);
        const c1 = JSON.parse(readFileSync(`${dir}/c1.json`, "utf8"));
        // A bucket write strips every module signature; the catalog signature still verifies.
        const stripped = { ...c1, modules: c1.modules.map(({ signature, ...m }) => m) };
        writeFileSync(`${dir}/stripped.json`, JSON.stringify(stripped));
        out.verifyStripped = run(none, ["--verify", `${dir}/stripped.json`]);
        out.merge = run(none, ["--previous", `${dir}/stripped.json`, "--out", `${dir}/c2.json`]);
        const c2 = JSON.parse(readFileSync(`${dir}/c2.json`, "utf8"));
        out.resignedSame = c2.modules.every((m, i) => m.signature === c1.modules[i].signature);
        out.verifyMerged = run(none, ["--verify", `${dir}/c2.json`]);
        // Unsigned previous with stripped entries: nothing vouches for them.
        const { signature, ...unsignedPrev } = stripped;
        writeFileSync(`${dir}/unsigned.json`, JSON.stringify(unsignedPrev));
        out.unvouched = run(none, ["--previous", `${dir}/unsigned.json`, "--out", `${dir}/c3.json`]);
        // …unless the kernels are rebuilt in this run: their old entries aren't checked.
        out.rebuilt = run(a, ["--previous", `${dir}/unsigned.json`, "--out", `${dir}/c4.json`]);
        console.log(JSON.stringify(out));
        """#.write(to: driver, atomically: true, encoding: .utf8)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", driver.path, tools.path, dir.path]
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let r = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "driver said: \(text)")
        #expect(r["first"] as? Int == 0)
        #expect(r["verifyStripped"] as? Int == 3)   // a module signature that doesn't verify: the wrong-key exit
        #expect(r["merge"] as? Int == 0)
        #expect(r["resignedSame"] as? Bool == true)
        #expect(r["verifyMerged"] as? Int == 0)
        #expect(r["unvouched"] as? Int == 1)
        #expect(r["rebuilt"] as? Int == 0)
    }

}
