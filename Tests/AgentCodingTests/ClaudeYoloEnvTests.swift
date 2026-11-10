import Foundation
import Testing
@testable import bromure_ac

/// Board task: Claude should run in real yolo mode. Claude Code 2.1.322's
/// bypass mode still stops at a dangerous rm (asks, then denies after 2 min)
/// unless CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1 is in its
/// process environment (it ignores the variable from settings.json). The VM's
/// api_key.env, sourced by every guest shell and agentd launch, exports it.
@Suite("Claude's bypass mode skips the dangerous-rm check in the VM")
struct ClaudeYoloEnvTests {
    @Test("api_key.env exports it, whatever the workspace's agent", arguments: [Profile.Tool.claude, .codex, .omp])
    @MainActor
    func exported(tool: Profile.Tool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yolo-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: tool, authMode: .token, apiKey: "sk-test")
        try store.save(p)
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: root.appendingPathComponent("base.img"))
        disk.tokenPlan = p.makeTokenPlan(salt: Data(repeating: 3, count: 32))
        let env = try String(contentsOf: disk.prepareMetadataShare().appendingPathComponent("api_key.env"), encoding: .utf8)
        #expect(env.split(separator: "\n").contains("export CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1"))
        #expect(SessionDisk.claudeYoloEnv == "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS")
    }

    /// Finding "Dangerous rm bypass can delete writable host shared
    /// folders": a Mac folder shared in is mounted read-write at ~/<name>;
    /// discarding the VM doesn't bring back what an rm deleted there.
    @Test("A workspace sharing a Mac folder keeps Claude Code's dangerous-rm check, even after a live refresh drops it")
    @MainActor
    func withheldWithSharedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yolo-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: "sk-test")
        p.folderPaths = [root.appendingPathComponent("project").path]
        try store.save(p)
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: root.appendingPathComponent("base.img"))
        disk.tokenPlan = p.makeTokenPlan(salt: Data(repeating: 3, count: 32))
        func exported() throws -> Bool {
            let env = try String(contentsOf: disk.prepareMetadataShare().appendingPathComponent("api_key.env"),
                                 encoding: .utf8)
            return env.contains(SessionDisk.claudeYoloEnv)
        }
        #expect(try !exported())
        // The folders removed while it runs (a restart-requiring change):
        // the share is still mounted, so still withheld.
        p.folderPaths = []
        try disk.refreshMetadataShare(profile: p, tokenPlan: disk.tokenPlan)
        #expect(try !exported())
    }
}
