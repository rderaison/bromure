import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A model call the provider refuses (401/402/403): Codex sessions that
    /// were mid-turn need the user (Codex fires no hook for a failed turn).
    /// A subscription agent's authentication is recorded for /state.
    @Suite("Refused model calls and subscription auth", .serialized)
    @MainActor
    struct ModelRefusalTests {
        @Test func aRefusedCallFlipsWorkingCodexSessionsToNeedsInput() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir + "/state")
            let prior = SessionStores.shared
            let stores = SessionStores(stateDir: dir + "/stores")
            SessionStores.shared = stores
            defer { SessionStores.shared = prior }
            let pid = UUID()
            var codex = AgentSession(profileID: pid, tool: .codex, title: "c", cwd: "~"); codex.windowIndex = 1
            var claude = AgentSession(profileID: pid, tool: .claude, title: "k", cwd: "~"); claude.windowIndex = 2
            stores.sessions.upsert(codex)
            stores.sessions.upsert(claude)
            host.setTabAgentStatus(pid, index: 1, .working, turnEnded: false)
            host.setTabAgentStatus(pid, index: 2, .working, turnEnded: false)
            host.noteModelCallRefused(pid, status: 500)
            #expect(host.tabStatuses()[pid]?[1] == "working", "only 401/402/403")
            host.noteModelCallRefused(pid, status: 402)
            #expect(host.tabStatuses()[pid]?[1] == "needsInput")
            #expect(host.tabStatuses()[pid]?[2] == "working", "claude reports it itself")
            await d.shutdown()
        }

        @Test func subscriptionAuthIsRecordedForState() {
            var p = Profile(name: "sub", tool: .claude, authMode: .subscription)
            p.id = UUID()
            Daemon.noteSubscriptionAuth(for: p, subscribed: [])
            #expect(Daemon.subscriptionAuthNotes.withLockedValue { $0[p.id]?[.claude] } != nil)
            #expect(Daemon.withLaunchAuth(["registeredAt": 1.0], .apiKeyFallback)["launchAuth"] as? String == "api_key_fallback")
            #expect(Daemon.withLaunchAuth(nil, .signInNeeded)["launchAuth"] as? String == "sign_in_needed")
            Daemon.subscriptionAuthNotes.withLockedValue { $0[p.id] = nil }
        }
    }
}
