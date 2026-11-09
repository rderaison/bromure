import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Model traffic drives a hook-less agent's tab (macOS: noteAgentActivity
    /// → setNonClaudeAgentTabs): working while it flows, done 4 s after it
    /// stops; a hook-driven agent's tab is the hooks' alone.
    @Suite("Agent activity from the proxy", .serialized)
    @MainActor
    struct AgentActivityTests {
        @Test func aHooklessAgentWorksWhileItsTrafficFlowsAndIsDoneAfter() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir + "/state")
            let pid = UUID()
            LinuxSessionHost.running.withLockedValue { _ = $0.insert(pid) }
            defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(pid) } }
            let outbox = dir + "/state/vms/" + pid.uuidString.lowercased() + "/outbox"
            try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
            try "0\t1\tgemini\n1\t0\tclaude\n2\t0\tbash\n".write(toFile: outbox + "/tabs.txt", atomically: true, encoding: .utf8)

            host.noteAgentActivity(pid)
            #expect(host.tabStatuses()[pid]?[0] == "working", "gemini reports no hooks: the traffic says")
            #expect(host.tabStatuses()[pid]?[1] == nil, "claude's hooks say, not the proxy")
            #expect(host.tabStatuses()[pid]?[2] == nil, "a shell isn't an agent")
            // More traffic within 4 s keeps it working.
            try await Task.sleep(for: .seconds(2))
            host.noteAgentActivity(pid)
            try await Task.sleep(for: .seconds(3))
            #expect(host.tabStatuses()[pid]?[0] == "working")
            try await Task.sleep(for: .seconds(2))
            #expect(host.tabStatuses()[pid]?[0] == "done", "quiet for 4 s")
            await d.shutdown()
        }

        @Test func aKeepAliveDoesNotCountAndBeatsAreTwoSecondsApart() {
            #expect(ActivityBeat.isKeepAlive(Data([0x89, 0x00])), "a ping")
            #expect(ActivityBeat.isKeepAlive(Data([0x8A, 0x00])), "a pong")
            #expect(!ActivityBeat.isKeepAlive(Data([0x81, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f])), "a text frame")
            #expect(!ActivityBeat.isKeepAlive(Data([0x89] + [UInt8](repeating: 0, count: 70))), "a chunk with more than a ping")
            let fired = NIOLockedValueBoxShim(0)
            let beat = ActivityBeat(fire: { fired.mutate { $0 += 1 } })
            beat.tick(Data([0x81, 0x01, 0x61]))
            beat.tick(Data([0x81, 0x01, 0x61]))
            beat.tick(Data([0x89, 0x00]))
            #expect(fired.value == 1, "once per 2 s, pings aside")
        }
    }
}
