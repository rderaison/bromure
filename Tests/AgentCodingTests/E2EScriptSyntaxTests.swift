import Foundation
import Testing

/// The E2E suites (Tests/*.mjs) only run on a Jenkins agent with a VM, so a
/// syntax error in one -- a duplicate `const` in a test's callback -- went
/// unnoticed until that run failed before its first test (Finding "New inbox
/// path constant prevents E2E suite from parsing"). JavaScriptCore's shell,
/// on every Mac, parses each as a module here.
@Suite("E2E scripts parse")
struct E2EScriptSyntaxTests {
    static let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

    @Test("Every Tests/*.mjs is a syntactically valid module")
    func modulesParse() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.jsc) else { return }
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scripts = try FileManager.default.contentsOfDirectory(atPath: tests.path)
            .filter { $0.hasSuffix(".mjs") }.sorted()
        #expect(!scripts.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in scripts {
            let path = tests.appendingPathComponent(name).path
            let check = dir.appendingPathComponent("check.js")
            let quoted = String(data: try JSONSerialization.data(withJSONObject: [path]), encoding: .utf8)!
            try #"try { checkModuleSyntax(read(\#(quoted)[0])); print("ok") } catch (e) { print(String(e)) }"#
                .write(to: check, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.jsc)
            p.arguments = [check.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text == "ok", "\(name): \(text)")
        }
    }
}
