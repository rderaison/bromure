import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// POST /sessions/<workspace>/worktree (the remote menu's worktree
    /// actions; macOS: ACAutomationServer's /worktree branch): a command in
    /// the running workspace's outbox, 400 when it isn't running or the
    /// action is unknown.
    @Suite("Worktree route", .serialized)
    @MainActor
    struct WorktreeRouteTests {
        @Test func aWorktreeCommandIsQueuedForARunningWorkspace() async throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            let prior = LinuxSessionHost.shared
            LinuxSessionHost.shared = LinuxSessionHost(daemon: d, stateDir: dir)
            defer { LinuxSessionHost.shared = prior }
            let pid = UUID()
            let outbox = dir + "/vms/" + pid.uuidString.lowercased() + "/outbox"
            try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
            let body: JSONValue = ["action": "finish", "args": ["feature-x"]]

            var r = await d.worktreeCommand(pid.uuidString, body)
            #expect(r.status == 400, "not running here")
            LinuxSessionHost.running.withLockedValue { _ = $0.insert(pid) }
            defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(pid) } }
            r = await d.worktreeCommand(pid.uuidString, ["action": "nonsense", "args": []])
            #expect(r.status == 400, "unknown action")
            r = await d.worktreeCommand(pid.uuidString, body)
            #expect(r.status == 200, "\(r.body)")
            let files = try FileManager.default.contentsOfDirectory(atPath: outbox).filter { $0.hasPrefix("cmd-") }
            #expect(files.count == 1, "\(files)")
            let line = try String(contentsOfFile: outbox + "/" + files[0], encoding: .utf8)
            #expect(line == GuestCommand.line(action: "finish", args: ["feature-x"])! + "\n", "\(line)")
            await d.shutdown()
        }
    }
}
