import CryptoKit
import Foundation
import Testing

/// Finding (CWE-754): "Failed sentry verify deletes every module signature
/// and blames the Sparkle key". Any --verify failure — a module that doesn't
/// match, a missing .sig, an unreadable catalog — deleted catalog.json and
/// every .ko.sig and said the key was wrong.
@Suite("Sentry signing: only a wrong key discards the outputs", .serialized)
struct SentryVerifyFailureTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let hash = String(repeating: "cd", count: 32)
    private static var runnable: Bool {
        (try? run(["node", "--version"], env: [:]).code) == 0
    }

    @discardableResult
    private static func run(_ argv: [String], env: [String: String]) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = root
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private struct Out {
        let dir: URL, out: URL, modules: URL, keyFile: URL, publicKey: String, otherPublicKey: String
        init() throws {
            let fm = FileManager.default
            dir = fm.temporaryDirectory.appendingPathComponent("sentry-verify-\(UUID().uuidString)")
            out = dir.appendingPathComponent("out"); modules = out.appendingPathComponent("modules")
            try fm.createDirectory(at: modules, withIntermediateDirectories: true)
            try #"{"sourceHash":"\#(SentryVerifyFailureTests.hash)","built":["6.8.0-1"]}"#
                .write(to: out.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try Data("module body".utf8).write(to: modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko"))
            let key = Curve25519.Signing.PrivateKey()
            keyFile = dir.appendingPathComponent("key")
            try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
            publicKey = key.publicKey.rawRepresentation.base64EncodedString()
            otherPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        }
        func sign(pinned: String) throws -> (code: Int32, out: String) {
            try SentryVerifyFailureTests.run(["bash", "scripts/sign-sentry-modules.sh", out.path, keyFile.path],
                                             env: ["SENTRY_CATALOG_PUBLIC_KEY": pinned])
        }
        func verify(pinned: String) throws -> Int32 {
            try SentryVerifyFailureTests.run(
                ["node", "tools/make-sentry-catalog.mjs", "--verify", out.appendingPathComponent("catalog.json").path,
                 "--source-hash", SentryVerifyFailureTests.hash, "--modules", modules.path, "--public-key", pinned],
                env: [:]).code
        }
        var sig: URL { modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko.sig") }
        var catalog: URL { out.appendingPathComponent("catalog.json") }
    }

    @Test("the verifier says wrong key (3) apart from a bad module or .sig (1)",
          .enabled(if: SentryVerifyFailureTests.runnable))
    func exitCodes() throws {
        let o = try Out(); defer { try? FileManager.default.removeItem(at: o.dir) }
        #expect(try o.sign(pinned: o.publicKey).code == 0)
        #expect(try o.verify(pinned: o.publicKey) == 0)
        #expect(try o.verify(pinned: o.otherPublicKey) == 3)
        try Data("tampered".utf8).write(to: o.modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko"))
        #expect(try o.verify(pinned: o.publicKey) == 1)
        try Data("module body".utf8).write(to: o.modules.appendingPathComponent("bromure_sentry-6.8.0-1.ko"))
        try FileManager.default.removeItem(at: o.sig)
        #expect(try o.verify(pinned: o.publicKey) == 1)
    }

    @Test("signing with a key that isn't the pinned one discards the outputs and says so; a good key keeps them",
          .enabled(if: SentryVerifyFailureTests.runnable))
    func wrongKeyDiscards() throws {
        let o = try Out(); defer { try? FileManager.default.removeItem(at: o.dir) }
        let bad = try o.sign(pinned: o.otherPublicKey)
        #expect(bad.code != 0 && bad.out.contains("isn't the app's pinned Sparkle key"))
        #expect(!FileManager.default.fileExists(atPath: o.catalog.path) && !FileManager.default.fileExists(atPath: o.sig.path))
        let good = try o.sign(pinned: o.publicKey)
        #expect(good.code == 0 && FileManager.default.fileExists(atPath: o.catalog.path))
    }
}
