import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The agents' tool-call reports on a Linux server (macOS: the outbox
    /// poll's agent-tool logs and onAgentToolCall): each line read once, from
    /// the outbox or its hooks' folder, tells PolicySteering which tab the
    /// agent's pid is, and joins the call to the network lineage.
    @Suite("Agent tool-call reports", .serialized)
    @MainActor
    struct AgentToolReportTests {
        @Test func eachAgentsPidIsMappedToItsOwnTab() async throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir)
            let pid = UUID()
            defer { PolicySteering.shared.reset(profileID: pid); NetworkLineage.shared.reset(profileID: pid) }
            let outbox = dir + "/vms/" + pid.uuidString.lowercased() + "/outbox"
            try HomeSeed.prepareOutboxDirectory(URL(fileURLWithPath: outbox), forRestore: false)
            func line(_ id: String, _ agentPid: Int) -> String {
                #"{"agent":"claude","tool_use_id":"\#(id)","tool":"Bash","command":"curl x","pid":\#(agentPid)}"# + "\n"
            }
            // One agent reports in the outbox (tab 2), the other in agent/ (tab 5).
            try (line("t1", 4242) + "{not json}\n").write(toFile: outbox + "/agent-tool-2.jsonl", atomically: true, encoding: .utf8)
            try line("t2", 5353).write(toFile: outbox + "/agent/agent-tool-5.jsonl", atomically: true, encoding: .utf8)

            host.readAgentToolCalls()
            #expect(PolicySteering.shared.agentWindows(profileID: pid).isEmpty, "not running here: not read")

            LinuxSessionHost.running.withLockedValue { _ = $0.insert(pid) }
            defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(pid) } }
            host.readAgentToolCalls()
            #expect(PolicySteering.shared.agentWindows(profileID: pid) == [2, 5])
            // And each call is in the network lineage, with its agent's pid.
            let call = try #require(NetworkLineage.shared.toolCall(profileID: pid, id: "t1"))
            #expect(call.agentPid == 4242 && call.tool == "Bash" && call.command == "curl x" && call.agent == "claude")
            #expect(NetworkLineage.shared.toolCall(profileID: pid, id: "t2")?.agentPid == 5353)
            // A line read once isn't read again; a new one is.
            PolicySteering.shared.reset(profileID: pid)
            host.readAgentToolCalls()
            #expect(PolicySteering.shared.agentWindows(profileID: pid).isEmpty)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: outbox + "/agent-tool-2.jsonl"))
            try h.seekToEnd(); try h.write(contentsOf: Data(line("t3", 4242).utf8)); try h.close()
            host.readAgentToolCalls()
            #expect(PolicySteering.shared.agentWindows(profileID: pid) == [2])
            await d.shutdown()
        }
    }
}
