import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Claude Code's `/ship` watch on a Linux server (macOS:
    /// wireSandboxCallbacks' onAgentStatus and cleanupSessionRegistrations):
    /// the guest's hook reports the watch on the third line of a turn's-end
    /// status file, the daemon records it on the tab's session, and a
    /// workspace that stops watches nothing any more. (The model itself is
    /// the shared ClaudeShipTests.)
    @Suite("Ship watch", .serialized)
    @MainActor
    struct ShipWatchLinuxTests {
        /// A status report as the guest's hook leaves it in the outbox.
        static func report(_ outbox: String, window: Int, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
            try text.write(toFile: outbox + "/agent-status-\(window).txt", atomically: true, encoding: .utf8)
        }

        @Test func aTurnsEndReportsTheWatchAndAStoppedWorkspaceHasNone() async throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir)
            let priorStores = SessionStores.shared
            let stores = SessionStores(stateDir: dir + "/stores")
            SessionStores.shared = stores
            defer { SessionStores.shared = priorStores }
            let pid = UUID(), other = UUID()
            var tab = AgentSession(profileID: pid, tool: .claude, title: "c", cwd: "~")
            tab.windowIndex = 2
            var elsewhere = AgentSession(profileID: other, tool: .claude, title: "o", cwd: "~")
            elsewhere.windowIndex = 2
            for s in [tab, elsewhere] { stores.sessions.upsert(s) }
            LinuxSessionHost.running.withLockedValue { $0.insert(pid); $0.insert(other) }
            defer { LinuxSessionHost.running.withLockedValue { $0.remove(pid); $0.remove(other) } }
            let outbox = dir + "/vms/" + pid.uuidString.lowercased() + "/outbox"

            // Mid-turn: nothing said about a watch.
            try Self.report(outbox, window: 2, "working\nconv-1")
            host.readAgentStatus()
            #expect(stores.sessions.session(tab.id)?.shipWatch == nil)
            // A turn's end, watching pull request #41.
            try Self.report(outbox, window: 2, "done\nconv-1\nship #41")
            host.readAgentStatus()
            #expect(stores.sessions.session(tab.id)?.shipWatch == "#41")
            #expect(stores.sessions.session(tab.id)?.shipWatchSeen != nil)
            #expect(stores.sessions.liveShipWatches() == 1)
            #expect(SessionHome.shipWatching(try #require(stores.sessions.session(tab.id))) == "#41")
            #expect(!FileManager.default.fileExists(atPath: outbox + "/agent-status-2.txt"), "a report is read once")
            // A report without the line (an older hook, another event) keeps it.
            try Self.report(outbox, window: 2, "done\nconv-1")
            host.readAgentStatus()
            #expect(stores.sessions.session(tab.id)?.shipWatch == "#41")
            // The watch ended.
            try Self.report(outbox, window: 2, "done\nconv-1\nship")
            host.readAgentStatus()
            #expect(stores.sessions.session(tab.id)?.shipWatch == nil)
            #expect(stores.sessions.liveShipWatches() == 0)

            // Both workspaces watching; one stops: its tabs watch nothing, the
            // other's still do.
            stores.sessions.setShipWatch(tab.id, "#41")
            stores.sessions.setShipWatch(elsewhere.id, "feature/x")
            #expect(stores.sessions.liveShipWatches() == 2)
            await d.clearWorkspaceProxyState(pid)
            #expect(stores.sessions.session(tab.id)?.shipWatch == nil)
            #expect(stores.sessions.session(elsewhere.id)?.shipWatch == "feature/x")
            #expect(stores.sessions.liveShipWatches() == 1)
            await d.shutdown()
        }
    }
}
