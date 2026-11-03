import CryptoKit
import Foundation
import Testing

/// Finding (CWE-59): "Sentry signing follows symlinks in the CI out dir and
/// clobbers or publishes the target". The out dir comes from the build
/// container (`docker cp` keeps links) and is signed on the key holder's Mac:
/// a `catalog.json` link let the catalog overwrite its target, and a module
/// link got its target hashed, signed and uploaded public-read.
@Suite("Sentry signing: links in the CI out dir are refused, never followed", .serialized)
struct SentrySigningSymlinkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let hash = String(repeating: "ab", count: 32)
    private static var runnable: Bool {
        (try? run(["node", "--version"], in: FileManager.default.temporaryDirectory).code) == 0
    }

    @discardableResult
    private static func run(_ argv: [String], in dir: URL, env: [String: String] = [:]) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A CI out dir (manifest + one module) plus a victim file outside it,
    /// and a throwaway signing key.
    private struct Fixture {
        let dir: URL, out: URL, modules: URL, victim: URL, keyFile: URL, publicKey: String
        let victimBytes = "do not touch\n"
        init() throws {
            let fm = FileManager.default
            dir = fm.temporaryDirectory.appendingPathComponent("sentry-link-\(UUID().uuidString)")
            out = dir.appendingPathComponent("out")
            modules = out.appendingPathComponent("modules")
            try fm.createDirectory(at: modules, withIntermediateDirectories: true)
            try #"{"sourceHash":"\#(SentrySigningSymlinkTests.hash)","built":["6.8.0-1"]}"#
                .write(to: out.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try Data("module body".utf8).write(to: modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko"))
            victim = dir.appendingPathComponent("secret.txt")
            try victimBytes.write(to: victim, atomically: true, encoding: .utf8)
            let key = Curve25519.Signing.PrivateKey()
            keyFile = dir.appendingPathComponent("key")
            try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
            publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        }
        func link(_ path: URL, to target: URL) throws {
            try? FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        }
        var victimIntact: Bool { (try? String(contentsOf: victim, encoding: .utf8)) == victimBytes }
        func catalog(env extra: [String: String] = [:]) throws -> (code: Int32, out: String) {
            try SentrySigningSymlinkTests.run(
                ["node", "tools/make-sentry-catalog.mjs", "--source-hash", SentrySigningSymlinkTests.hash,
                 "--modules", modules.path, "--public-key", publicKey,
                 "--out", out.appendingPathComponent("catalog.json").path],
                in: SentrySigningSymlinkTests.root,
                env: ["SPARKLE_PRIVATE_KEY": try String(contentsOf: keyFile, encoding: .utf8)].merging(extra) { $1 })
        }
    }

    @Test("the signing script signs a clean out dir, and refuses one holding any link",
          .enabled(if: SentrySigningSymlinkTests.runnable))
    func signScript() throws {
        let f = try Fixture()
        let sign = { try Self.run(["bash", "scripts/sign-sentry-modules.sh", f.out.path, f.keyFile.path],
                                  in: Self.root, env: ["SENTRY_CATALOG_PUBLIC_KEY": f.publicKey]) }
        let ok = try sign()
        #expect(ok.code == 0, "\(ok.out)")
        #expect(FileManager.default.fileExists(atPath: f.out.appendingPathComponent("catalog.json").path))

        try FileManager.default.removeItem(at: f.out.appendingPathComponent("catalog.json"))
        try f.link(f.modules.appendingPathComponent("bromure_sentry-6.9.0-1.ko"), to: f.victim)
        let refused = try sign()
        #expect(refused.code != 0)
        #expect(refused.out.contains("is a symlink"), "\(refused.out)")
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("catalog.json").path))
        #expect(f.victimIntact)
    }

    @Test("the catalog tool never writes through a link at catalog.json or a .ko.sig",
          .enabled(if: SentrySigningSymlinkTests.runnable))
    func writesReplaceLinks() throws {
        let f = try Fixture()
        let catalog = f.out.appendingPathComponent("catalog.json")
        try f.link(catalog, to: f.victim)
        try f.link(f.modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko.sig"), to: f.victim)
        let r = try f.catalog()
        #expect(r.code == 0, "\(r.out)")
        #expect(f.victimIntact, "the link's target was overwritten")
        let attrs = try FileManager.default.attributesOfItem(atPath: catalog.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
    }

    @Test("a module that is a link is refused, not hashed and signed as its target",
          .enabled(if: SentrySigningSymlinkTests.runnable))
    func moduleLinkRefused() throws {
        let f = try Fixture()
        try f.link(f.modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko"), to: f.victim)
        let r = try f.catalog()
        #expect(r.code != 0)
        #expect(r.out.contains("symlink"), "\(r.out)")
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("catalog.json").path))
    }

    @Test("spaces-put refuses to upload a link", .enabled(if: SentrySigningSymlinkTests.runnable))
    func uploadRefusesLink() throws {
        let f = try Fixture()
        let link = f.out.appendingPathComponent("upload.ko")
        try f.link(link, to: f.victim)
        let env = ["DO_SPACES_KEY": "k", "DO_SPACES_SECRET": "s", "DO_SPACES_ENDPOINT": "https://example.invalid",
                   "DO_SPACES_REGION": "r", "DO_SPACES_BUCKET": "b", "DO_SPACES_PUBLIC_BASE": "https://example.invalid"]
        let r = try Self.run(["node", "tools/spaces-put.mjs", link.path, "x/upload.ko"], in: Self.root, env: env)
        #expect(r.code != 0)
        #expect(r.out.contains("is a symlink"), "\(r.out)")
    }
}
