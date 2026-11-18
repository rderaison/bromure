import CryptoKit
import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// bromure_zeropages rides the sentry's module store (SentryModuleStore with
/// module "zeropages"): its own CDN prefix, file stem and signing domains, so
/// nothing signed for one module is ever accepted as the other's.
@Suite("bromure_zeropages modules from the CDN")
struct ZeropagesModuleStoreTests {
    static let hash = String(repeating: "b", count: 64)
    static let kernel = "6.8.0-149-generic"
    static let body = Data("zeropages-module-bytes".utf8)
    let key = Curve25519.Signing.PrivateKey()

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("zeropages-store-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func store(_ module: String, host: String, root: URL) -> SentryModuleStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SentryStubProtocol.self]
        return SentryModuleStore(module: module, root: root, base: URL(string: "https://\(host)/")!,
                                 requireSignature: true,
                                 publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                 session: URLSession(configuration: config))
    }

    /// What tools/make-sentry-catalog.mjs --module <signedAs> would publish
    /// under `<prefix>/`: the module's own signature and the catalog's.
    func catalog(signedAs: String, prefix: String = "zeropages") throws -> (json: Data, path: String) {
        let sha = SHA256.hash(data: Self.body).map { String(format: "%02x", $0) }.joined()
        let path = "\(prefix)/\(Self.hash)/\(Self.kernel)/bromure_\(prefix)-\(Self.kernel)-\(sha.prefix(12)).ko"
        var m = SentryModuleCatalog.Module(kernel: Self.kernel, path: path, sha256: sha, bytes: Self.body.count)
        m.signature = try key.signature(for: SentryModuleCatalog.moduleSigningPayload(
            module: signedAs, sourceHash: Self.hash, m)).base64EncodedString()
        var c = SentryModuleCatalog(formatVersion: 1, sourceHash: Self.hash, modules: [m], module: signedAs)
        let at = "2026-11-18T00:00:00.000Z"
        c.signature = .init(signedAt: at, edSignature: try key.signature(for: c.signingPayload(signedAt: at)).base64EncodedString())
        return (try JSONEncoder().encode(c), path)
    }

    @Test("Download, verify, cache and stage under zeropages/ and bromure_zeropages-<kernel>.ko")
    func downloadAndStage() async throws {
        let host = "zp-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let (json, path) = try catalog(signedAs: "zeropages")
        SentryStubProtocol.serve(host, "/zeropages/\(Self.hash)/catalog.json", 200, json)
        SentryStubProtocol.serve(host, "/" + path, 200, Self.body)
        let s = store("zeropages", host: host, root: root)
        #expect(await s.ensure(kernel: Self.kernel, hash: Self.hash) == nil)
        let meta = root.appendingPathComponent("meta/zeropages")
        #expect(s.stage(kernels: [Self.kernel], hash: Self.hash, into: meta) == [Self.kernel])
        #expect(try Data(contentsOf: meta.appendingPathComponent("bromure_zeropages-\(Self.kernel).ko")) == Self.body)
        // A kernel the catalog doesn't list is definitive (the catalog is fresh).
        #expect(await s.ensureOutcome(kernel: "6.8.0-150-generic", hash: Self.hash)?.definitive == true)
    }

    @Test("A catalog signed in the sentry's domain is never a zeropages catalog, and vice versa")
    func signingDomainsDontCross() async throws {
        let host = "zp-\(UUID().uuidString.prefix(8)).test"
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        // Sentry-signed, served (with zeropages paths) where zeropages looks.
        let (sentrySigned, path) = try catalog(signedAs: "sentry")
        SentryStubProtocol.serve(host, "/zeropages/\(Self.hash)/catalog.json", 200, sentrySigned)
        SentryStubProtocol.serve(host, "/" + path, 200, Self.body)
        let zp = store("zeropages", host: host, root: root.appendingPathComponent("zp"))
        #expect(await zp.ensure(kernel: Self.kernel, hash: Self.hash) != nil)
        #expect(zp.verifiedModule(kernel: Self.kernel, hash: Self.hash) == nil)
        // Zeropages-signed, with sentry paths, where the sentry looks.
        let (zpSigned, spath) = try catalog(signedAs: "zeropages", prefix: "sentry")
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/catalog.json", 200, zpSigned)
        SentryStubProtocol.serve(host, "/" + spath, 200, Self.body)
        let sentry = store("sentry", host: host, root: root.appendingPathComponent("sentry"))
        #expect(await sentry.ensure(kernel: Self.kernel, hash: Self.hash) != nil)
        // The same catalog signed in its own domain is accepted.
        let (ok, _) = try catalog(signedAs: "sentry", prefix: "sentry")
        SentryStubProtocol.serve(host, "/sentry/\(Self.hash)/catalog.json", 200, ok)
        #expect(await sentry.ensure(kernel: Self.kernel, hash: Self.hash) == nil)
    }

    @Test("The shipped source hash is the browser engine's vm-setup/zeropages, as source-hash.sh frames it")
    func shippedSourceHash() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = repo.appendingPathComponent("Sources/SandboxEngine/Resources/vm-setup/zeropages")
        var hasher = SHA256()
        for name in ["Makefile", "bromure_zeropages.c"] {
            let data = try Data(contentsOf: src.appendingPathComponent(name))
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        let expected = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(SentryModuleStore.shippedZeropagesSourceHash() == expected)
    }

    @Test("agentd's kernels.json is untrusted: junk names dropped, duplicates removed, at most 16")
    func kernelsReport() {
        #expect(UbuntuSandboxVM.parseKernelsReport(#"{"running":"6.8.0-149-generic","kernels":["6.8.0-149-generic","6.8.0-142-generic"]}"#)
                == ["6.8.0-149-generic", "6.8.0-142-generic"])
        #expect(UbuntuSandboxVM.parseKernelsReport(#"{"kernels":["../../etc","6.8.0-149-generic","6.8.0-149-generic","x y"]}"#)
                == ["6.8.0-149-generic"])
        let many = (100..<140).map { "\"6.8.0-\($0)-generic\"" }.joined(separator: ",")
        #expect(UbuntuSandboxVM.parseKernelsReport("{\"kernels\":[\(many)]}").count == 16)
        #expect(UbuntuSandboxVM.parseKernelsReport("not json").isEmpty)
    }
}
