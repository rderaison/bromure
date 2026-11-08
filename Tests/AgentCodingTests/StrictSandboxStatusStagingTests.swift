import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// attestd builds `sandbox_status` with bromure_sandbox_status.py: a strict
/// workspace with no sandbox spec gets it in its meta share too, or its state
/// never reaches the host.
@Suite("Strict sandbox status module staging")
struct StrictSandboxStatusStagingTests {
    static let module = "bromure_sandbox_status.py"

    /// A guest-scripts directory with the files writeSandboxFiles copies.
    static func setupDir(_ root: URL) throws -> URL {
        let dir = root.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["bromure-attestd.py", "bromure-strict.py", "bromure-sandboxd", "bromure-sentryd",
                     "bromure_openshell.py", "bromure_idmap.py", module] {
            try Data("# \(name)\n".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func aStrictOnlyWorkspaceGetsTheStatusModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strict-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try Self.setupDir(root)
        let meta = root.appendingPathComponent("meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        func stage(_ p: Profile) throws {
            try SessionDisk.writeSandboxFiles(into: meta, profile: p, setupDir: setup, workdirs: [],
                                              stageSentryModules: { _ in })
        }
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: meta.appendingPathComponent(name).path) }

        var p = Profile(name: "strict-only", tool: .claude, authMode: .token)
        p.strictSandbox = true
        try stage(p)
        #expect(has("strict-sandbox") && has("bromure-attestd.py"))
        #expect(!has("openshell-sandbox.json"), "no spec for strict alone")
        #expect(has(Self.module), "attestd's status module is staged with it")
        #expect(!has("bromure-sandboxd"), "the spec's launcher isn't")
        let mode = try FileManager.default.attributesOfItem(atPath: meta.appendingPathComponent(Self.module).path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)

        // Strict off: gone again.
        p.strictSandbox = false
        try stage(p)
        #expect(!has("strict-sandbox") && !has(Self.module))
    }
}
