import Foundation
import Testing
@testable import bromure_ac

// The branch an agent's task branch is merged back into: where the work
// forked from, not whatever the repository folder has checked out.

@Suite("Task worktree parent branch")
struct WorktreeParentTests {
    private func sh(_ script: String, in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path   // no real registry
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("the fork point wins over the folder's checkout")
    func forkPoint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wtparent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sh("""
            set -e
            git init -q -b main repo && cd repo
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
            git branch older
            git checkout -q -b dev
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m dev1
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m dev2
            git worktree add -q -b wt/task ../task dev
            git -C ../task -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
            git checkout -q older      # the folder sits on an unrelated branch
            """, in: dir)
        let repo = dir.appendingPathComponent("repo").path
        let out = try sh(CodingTaskEngine.worktreeMetadataCommand(repoPath: repo, branch: "wt/task"), in: dir)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(out.count >= 3)
        #expect(out[0].hasSuffix("/task"))            // the worktree
        #expect(out[1] == "dev")                      // where it forked from, not "older"
        // The folder on a task branch (here the task's own): never the parent.
        _ = try sh("cd repo && git checkout -q --detach && git branch -f wt/other wt/task", in: dir)
        let detached = try sh(CodingTaskEngine.worktreeMetadataCommand(repoPath: repo, branch: "wt/task"), in: dir)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(detached[1] == "dev")
    }
}
