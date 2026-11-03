import Foundation
import Testing

/// Jenkinsfile.sentry's no-build gate: on a day nothing was built, the
/// Publish stage skips the publisher only when every published catalog still
/// verifies. Its shell lives in a Groovy `'''` string, whose backslash
/// escapes Groovy processes first (`\\` → `\`, as the stage's own
/// `grep '"built": \\[\\]'` and Jenkinsfile.e2e's `"^0\\."` filters rely
/// on), so the test renders it the same way and runs what the shell gets:
/// a signed catalog skips; one whose module signature was stripped falls
/// through to the republish. (Finding CWE-670, "No-build sentry catalog
/// check is over-escaped and never verifies", read the raw text as shell.)
@Suite("Sentry publish: the no-build gate verifies the published catalogs", .serialized)
struct SentryPublishGateTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var node: String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A Groovy single-quoted string's escapes, as Groovy applies them; an
    /// escape Groovy rejects is an error (the stage wouldn't compile).
    static func groovyUnescape(_ s: String) throws -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { throw Unescape.dangling }
            switch e {
            case "\\": out.append("\\")
            case "'": out.append("'")
            case "\"": out.append("\"")
            case "$": out.append("$")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\n": break                          // line continuation
            default: throw Unescape.unknown(e)
            }
        }
        return out
    }
    enum Unescape: Error { case dangling, unknown(Character) }

    /// The gate, from `if ! grep -L` to its closing `fi`, as the shell gets it.
    static func gate() throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent("Jenkinsfile.sentry"), encoding: .utf8)
        let start = try #require(text.range(of: "if ! grep -L '\"built\""))
        let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let indent = String(text[lineStart..<start.lowerBound])
        let end = try #require(text.range(of: "\n" + indent + "fi\n", range: start.upperBound..<text.endIndex))
        return try groovyUnescape(String(text[start.lowerBound..<end.upperBound]))
    }

    private func sh(_ script: String, cwd: URL, path: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = cwd
        p.environment = ["PATH": path, "HOME": NSTemporaryDirectory()]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the gate's shell is well-escaped Groovy and parses")
    func parses() throws {
        let g = try Self.gate()
        #expect(g.contains(#"sed -n 's/.*SENTRY_CATALOG_PUBLIC_KEY:-\([^}]*\)}.*/\1/p'"#))
        #expect(g.contains(#"require(\"fs\")"#))
        #expect(g.contains("--source-hash \"$h\" \\\n"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("gate.sh")
        try g.write(to: f, atomically: true, encoding: .utf8)
        #expect(try sh("bash -n gate.sh && echo OK", cwd: dir, path: "/usr/bin:/bin").contains("OK"))
    }

    @Test("a signed catalog skips the publisher; a stripped one falls through to republish",
          .enabled(if: SentryPublishGateTests.node != nil))
    func verifies() throws {
        let node = try #require(Self.node)
        let fm = FileManager.default
        let ws = fm.temporaryDirectory.appendingPathComponent("gate-ws-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: ws) }
        for d in ["tools", "scripts", "bin", "mods", "sentry-ci/out-head", "sentry-ci/out-v1"] {
            try fm.createDirectory(at: ws.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: Self.root.appendingPathComponent("tools/make-sentry-catalog.mjs"),
                        to: ws.appendingPathComponent("tools/make-sentry-catalog.mjs"))
        // A throwaway key, pinned in the publish script the gate reads it from.
        let keys = try sh(#"""
            "\#(node)" -e 'const {generateKeyPairSync,createPublicKey}=require("crypto");const {privateKey}=generateKeyPairSync("ed25519");
            console.log(privateKey.export({format:"der",type:"pkcs8"}).subarray(16).toString("base64"));
            console.log(createPublicKey(privateKey).export({format:"der",type:"spki"}).subarray(12).toString("base64"))'
            """#, cwd: ws, path: "/usr/bin:/bin").split(separator: "\n").map(String.init)
        try #require(keys.count == 2)
        let publish = try String(contentsOf: Self.root.appendingPathComponent("scripts/publish-sentry-modules.sh"), encoding: .utf8)
        let pinned = try #require(publish.range(of: #"SENTRY_CATALOG_PUBLIC_KEY:-[^}]*\}"#, options: .regularExpression))
        try publish.replacingCharacters(in: pinned, with: "SENTRY_CATALOG_PUBLIC_KEY:-\(keys[1])}")
            .write(to: ws.appendingPathComponent("scripts/publish-sentry-modules.sh"), atomically: true, encoding: .utf8)
        // `docker run … sh -euc SCRIPT` → run SCRIPT here, its /w a temp dir.
        try #"""
            #!/bin/bash
            while [ "$1" != "sh" ]; do case "$1" in -e) export "$2"; shift 2;; *) shift;; esac; done
            T=$(mktemp -d); script="${3//\/w/$T}"; exec sh -euc "$script"
            """#.write(to: ws.appendingPathComponent("bin/docker"), atomically: true, encoding: .utf8)
        chmod(ws.appendingPathComponent("bin/docker").path, 0o755)
        try "abc".write(to: ws.appendingPathComponent("mods/bromure_sentry-6.8.0-1-generic.ko"), atomically: true, encoding: .utf8)
        let hash = String(repeating: "b", count: 64)
        let path = "\(ws.path)/bin:\((node as NSString).deletingLastPathComponent):/usr/bin:/bin"
        _ = try sh("SPARKLE_PRIVATE_KEY='\(keys[0])' node tools/make-sentry-catalog.mjs --source-hash \(hash) "
                   + "--modules mods --public-key '\(keys[1])' --out good.json", cwd: ws, path: path)
        for d in ["head", "v1"] {
            try #"{"built": []}"#.write(to: ws.appendingPathComponent("sentry-ci/out-\(d)/manifest.json"), atomically: true, encoding: .utf8)
            try fm.copyItem(at: ws.appendingPathComponent("good.json"),
                            to: ws.appendingPathComponent("sentry-ci/out-\(d)/previous-catalog.json"))
        }
        let gate = try Self.gate()
        let run = { try self.sh("set -eu\n" + gate + "\necho FELL-THROUGH\n", cwd: ws, path: path) }

        let good = try run()
        #expect(good.contains("nothing to publish") && !good.contains("FELL-THROUGH"), Comment(rawValue: good))

        // A bucket write strips v1's module signatures: republish.
        _ = try sh(#"node -e 'const f=process.argv[1];const c=require(f);c.modules.forEach(m=>delete m.signature);require("fs").writeFileSync(f,JSON.stringify(c))' "$PWD/sentry-ci/out-v1/previous-catalog.json""#,
                   cwd: ws, path: path)
        let stripped = try run()
        #expect(stripped.contains("fails verification: republishing") && stripped.contains("FELL-THROUGH"),
                Comment(rawValue: stripped))
    }
}
