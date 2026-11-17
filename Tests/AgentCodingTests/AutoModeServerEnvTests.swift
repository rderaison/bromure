import Foundation
import Testing
@testable import bromure_ac

/// With PII swapping on, Claude Code keeps auto mode's classifier checks to
/// itself (CLAUDE_CODE_AUTO_MODE_SERVER=0): the server-side checks' fields
/// pass the MITM untouched, so they'd reach the API unswapped.
@Suite("Auto mode's server-side checks are off where PII swapping is on")
struct AutoModeServerEnvTests {
    @MainActor
    private func env(pii: Bool, refreshTo after: Bool? = nil) throws -> (before: [Substring], after: [Substring]?) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("automode-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: "sk-test")
        p.pii = PIIPolicy(enabled: pii)
        try store.save(p)
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: root.appendingPathComponent("base.img"))
        disk.tokenPlan = p.makeTokenPlan(salt: Data(repeating: 3, count: 32))
        let file = try disk.prepareMetadataShare().appendingPathComponent("api_key.env")
        let before = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        guard let after else { return (before, nil) }
        p.pii = PIIPolicy(enabled: after)
        try disk.refreshMetadataShare(profile: p, tokenPlan: disk.tokenPlan)
        return (before, try String(contentsOf: file, encoding: .utf8).split(separator: "\n"))
    }

    @Test("PII swapping on: exported; off: not")
    @MainActor
    func exported() throws {
        #expect(try env(pii: true).before.contains("export CLAUDE_CODE_AUTO_MODE_SERVER=0"))
        #expect(try !env(pii: false).before.contains { $0.contains("CLAUDE_CODE_AUTO_MODE_SERVER") })
    }

    @Test("Turned on while it runs: the next Claude launched gets it")
    @MainActor
    func liveRefresh() throws {
        let r = try env(pii: false, refreshTo: true)
        #expect(r.after?.contains("export CLAUDE_CODE_AUTO_MODE_SERVER=0") == true)
    }
}
