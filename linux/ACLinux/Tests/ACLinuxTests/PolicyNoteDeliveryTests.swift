import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Policy steering's delivery on a Linux server (macOS:
    /// deliverPolicyNote): a Claude tab's note is a file in the workspace's
    /// meta share its hook claims; a non-Claude tab's is typed once its turn
    /// is over (only the attributed tab, or the sole one); nothing for a
    /// workspace that isn't running here.
    @Suite("Policy note delivery", .serialized)
    @MainActor
    struct PolicyNoteDeliveryTests {
        @Test func notesReachTheRunningWorkspacesAgents() async throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir)
            let priorStores = SessionStores.shared
            let stores = SessionStores(stateDir: dir + "/stores")
            SessionStores.shared = stores
            defer { SessionStores.shared = priorStores }
            let pid = UUID()
            var claude = AgentSession(profileID: pid, tool: .claude, title: "c", cwd: "~")
            claude.windowIndex = 2
            var codex = AgentSession(profileID: pid, tool: .codex, title: "x", cwd: "~")
            codex.windowIndex = 3
            var codex2 = AgentSession(profileID: pid, tool: .codex, title: "y", cwd: "~")
            codex2.windowIndex = 4
            for s in [claude, codex, codex2] { stores.sessions.upsert(s) }

            // Not running here: nothing.
            #expect(await host.deliverPolicyNote(profileID: pid, window: nil, text: "n0", soleOnly: false) == false)

            LinuxSessionHost.running.withLockedValue { _ = $0.insert(pid) }
            defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(pid) } }
            #expect(await host.deliverPolicyNote(profileID: pid, window: nil, text: "curl to evil.example was blocked",
                                                 soleOnly: false))
            let notes = dir + "/vms/" + pid.uuidString.lowercased() + "/meta/" + PolicyNotes.shareDir
            let files = try FileManager.default.contentsOfDirectory(atPath: notes)
            #expect(files.count == 1 && files[0].hasPrefix("w2-") && files[0].hasSuffix(".note"), "\(files)")
            #expect(try String(contentsOfFile: notes + "/" + files[0], encoding: .utf8) == "curl to evil.example was blocked\n")
            // Unattributed, with two non-Claude tabs: neither typed into (macOS's rule).
            #expect(LinuxSessionHost.typedPolicyNotes.isEmpty)
            // Attributed to a Codex tab: typed there, once its turn is over.
            #expect(await host.deliverPolicyNote(profileID: pid, window: 3, text: "n2", soleOnly: false))
            #expect(LinuxSessionHost.typedPolicyNotes["\(pid.uuidString)|3"] == ["n2"])
            LinuxSessionHost.typedPolicyNotes = [:]
            await d.shutdown()
        }
    }
}
