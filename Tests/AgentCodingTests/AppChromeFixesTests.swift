import Foundation
import Testing
@testable import bromure_ac

/// QA fixes to the app chrome: partial `workspaces edit --from-json`
/// documents, readable fresh-folder names, the new-session chips, and the
/// explicit Reach default for new workspaces.
@Suite("App chrome fixes")
struct AppChromeFixesTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("bac-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("a partial document is overlaid on the stored workspace")
    func partialMerge() throws {
        var base = Profile(name: "Daily", tool: .claude, authMode: .subscription)
        base.memoryGB = 6
        base.comments = "keep me"
        let merged = try ProfileDocument.merge(["memoryGB": 12, "color": "red"], over: base).get()
        #expect(merged.memoryGB == 12)
        #expect(merged.color == .red)
        #expect(merged.name == "Daily")
        #expect(merged.comments == "keep me")
        #expect(merged.id == base.id)
    }

    @Test("an explicit null clears an optional field")
    func nullClears() throws {
        var base = Profile(name: "Daily", tool: .claude, authMode: .subscription)
        base.agentReach = [UUID()]
        let merged = try ProfileDocument.merge(["agentReach": NSNull()], over: base).get()
        #expect(merged.agentReach == nil)
    }

    @Test("a bad field is named in the error")
    func namedError() {
        let base = Profile(name: "Daily", tool: .claude, authMode: .subscription)
        switch ProfileDocument.merge(["memoryGB": "lots"], over: base) {
        case .success: Issue.record("expected a failure")
        case .failure(let e):
            #expect(e.message.contains("memoryGB"))
            #expect(e.message.contains("number"))
        }
        switch ProfileDocument.merge(["tool": "clod"], over: base) {
        case .success: Issue.record("expected a failure")
        case .failure(let e): #expect(e.message.contains("tool"))
        }
    }

    @Test("fresh folders get a short topic, not the whole prompt")
    @MainActor
    func folderNames() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 3; c.hour = 12; c.minute = 4
        let now = Calendar.current.date(from: c)!
        #expect(AgentSessionEngine.syntheticFolderName(
            message: "Run this exact shell command: sleep 2 && echo hi", tool: .claude, now: now)
            == "shell-command-1003-1204")
        #expect(AgentSessionEngine.syntheticFolderName(message: "Please fix the login redirect loop",
                                                       tool: .claude, now: now)
            == "fix-login-1003-1204")
        #expect(AgentSessionEngine.syntheticFolderName(message: nil, tool: .codex, now: now)
            == "codex-1003-1204")
        #expect(AgentSessionEngine.syntheticFolderName(message: "Hi! Can you help?", tool: .kimi, now: now)
            == "kimi-1003-1204")
    }

    @Test("minted folders are recognized, old and new formats")
    func mintedFolders() {
        #expect(NewSessionView.RecentStart.isSynthesizedFolder("~/run-this-exact-shell-command-261003-1204"))
        #expect(NewSessionView.RecentStart.isSynthesizedFolder("~/shell-command-1003-1204"))
        #expect(NewSessionView.RecentStart.isSynthesizedFolder("~/claude-1003-1204-2"))
        #expect(!NewSessionView.RecentStart.isSynthesizedFolder("~/projects/web"))
        #expect(!NewSessionView.RecentStart.isSynthesizedFolder("~/myapp"))
        #expect(!NewSessionView.RecentStart.isSynthesizedFolder("~/src/shell-command-1003-1204"))
    }

    @Test("a new workspace reaches no other workspace until the user picks some")
    func reachDefault() throws {
        let store = ProfileStore(rootDir: try tempDir())
        let p = store.newProfileFromTemplate(name: "x")
        #expect(p.agentReach == [])
    }
}
