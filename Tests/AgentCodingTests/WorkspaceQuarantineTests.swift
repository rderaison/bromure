import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// A quarantine cuts every host channel that reaches the network: the
/// registry's state and cuts, the MCP gate, the SSH agent, the AWS
/// credentials, and the proxy's tracked connections.
@Suite("Workspace quarantine")
struct WorkspaceQuarantineTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func cutsRunAtEachStartUntilRemoved() {
        let q = WorkspaceQuarantine(), pid = UUID(), other = UUID()
        let cuts = Counter(), others = Counter()
        let token = q.onQuarantine(pid) { cuts.bump() }
        q.onQuarantine(other) { others.bump() }
        #expect(!q.contains(pid) && cuts.value == 0)
        q.set(true, for: pid)
        #expect(q.contains(pid) && cuts.value == 1 && others.value == 0, "only that workspace's")
        q.set(false, for: pid)
        q.set(true, for: pid)
        #expect(cuts.value == 2, "at every start")
        let late = Counter()
        q.onQuarantine(pid) { late.bump() }
        #expect(late.value == 1, "registered while quarantined: cut at once")
        q.remove(token, for: pid)
        q.set(false, for: pid)
        q.set(true, for: pid)
        #expect(cuts.value == 2 && late.value == 2, "a removed cut never runs again")
        q.set(false, for: pid)
    }

    @Test func aGuestPageIsNotOpenedWhileQuarantined() throws {
        let pid = UUID()
        let url = try #require(URL(string: "https://signin.example/authorize?state=secret"))
        #expect(!WorkspaceQuarantine.shared.refusesURLOpen(url, for: pid))
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        #expect(WorkspaceQuarantine.shared.refusesURLOpen(url, for: pid))
    }

    @Test func aCutRegisteredWithoutRunNowWaitsForTheNextStart() {
        let q = WorkspaceQuarantine(), pid = UUID(), cuts = Counter()
        q.set(true, for: pid)
        q.onQuarantine(pid, runNow: false) { cuts.bump() }
        #expect(cuts.value == 0, "the caller refuses its requests itself")
        q.set(false, for: pid)
        q.set(true, for: pid)
        #expect(cuts.value == 1)
        q.set(false, for: pid)
    }

    /// A slow MCP call in flight (a delegation's wait) when the quarantine
    /// starts: cancelled, and the refusal is what the guest gets.
    final class Slow: MCPLineHandler {
        func handle(line: String, branch: String?) async -> String? {
            for _ in 0..<500 {
                if Task.isCancelled { return "cancelled-result" }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return "late-result"
        }
    }

    @MainActor @Test func aCallInFlightIsCancelledAndItsResultNotRelayed() async throws {
        let pid = UUID()
        let gated = QuarantineGatedMCP(Slow(), profileID: pid)
        let started = ContinuousClock.now
        let answer = Task { await gated.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call"}"#, branch: nil) }
        try await Task.sleep(for: .milliseconds(100))
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        let reply = try #require(await answer.value)
        #expect(reply.contains("quarantined") && !reply.contains("result"), "\(reply)")
        #expect(ContinuousClock.now - started < .seconds(3), "cancelled, not run to its end")
    }

    /// A cut that runs after the channel closed (copied out by `set` just as
    /// it ended) never reaches the descriptor its number was reused for.
    @Test func aLateCutNeverReachesAReusedDescriptor() {
        var a: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, LibC.sockStream, 0, &a) == 0)
        let fds = CuttableFDs([a[0]])
        fds.close()
        Foundation.close(a[1])
        var b: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, LibC.sockStream, 0, &b) == 0)
        defer { Foundation.close(b[0]); Foundation.close(b[1]) }
        fds.cut()                                  // late: a no-op
        let byte: [UInt8] = [42]
        #expect(byte.withUnsafeBytes { write(b[0], $0.baseAddress, 1) } == 1, "the reused number still writes")
        var got: UInt8 = 0
        #expect(read(b[1], &got, 1) == 1 && got == 42)
        // While open, the cut shuts it: the peer reads the end.
        let live = CuttableFDs([b[0]])
        live.cut()
        #expect(read(b[1], &got, 1) == 0, "shut down by the cut")
        live.markClosing()
    }

    final class Echo: MCPLineHandler {
        func handle(line: String, branch: String?) async -> String? { "served" }
    }

    @MainActor @Test func theMCPServersAnswerNothingWhileQuarantined() async throws {
        let pid = UUID()
        let gated = QuarantineGatedMCP(Echo(), profileID: pid)
        #expect(await gated.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#, branch: nil) == "served")
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        let refused = try #require(await gated.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#, branch: nil))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(refused.utf8)) as? [String: Any])
        #expect(obj["id"] as? Int == 7)
        #expect(((obj["error"] as? [String: Any])?["message"] as? String)?.contains("quarantined") == true)
        #expect(await gated.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, branch: nil) == nil,
                "a notification gets nothing")
    }

    @Test func theProxysTrackedConnectionsAreCut() {
        let pid = UUID(), other = UUID()
        let cut = Counter(), kept = Counter()
        let a = EgressConnectionRegistry.shared.register(profileID: pid, host: "a.example", port: 443, route: "proxy", rule: nil) { cut.bump() }
        let b = EgressConnectionRegistry.shared.register(profileID: other, host: "b.example", port: 443, route: "proxy", rule: nil) { kept.bump() }
        defer { EgressConnectionRegistry.shared.unregister(a); EgressConnectionRegistry.shared.unregister(b) }
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        #expect(cut.value == 1 && kept.value == 0)
        #expect(EgressConnectionRegistry.shared.openConnections(profileID: pid).isEmpty)
    }

    /// A socketpair's SSH-agent round trip: REQUEST_IDENTITIES answered with
    /// FAILURE while the workspace is quarantined.
    @Test func theSSHAgentListsNothingWhileQuarantined() async throws {
        let pid = UUID()
        var sv: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, LibC.sockStream, 0, &sv) == 0)
        let agent = SSHAgentServer(consent: ConsentBroker())
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        let agentFD = sv[1]
        let served = Task { await agent.serve(fd: agentFD, profileID: pid) }
        let frame: [UInt8] = [0, 0, 0, 1, 11]
        _ = frame.withUnsafeBytes { write(sv[0], $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 5)
        let n = read(sv[0], &reply, 5)
        close(sv[0])
        await served.value
        #expect(n == 5 && reply == [0, 0, 0, 1, 5], "SSH_AGENT_FAILURE: \(reply)")
    }

    @Test func theAWSCredentialsAreWithheld() async throws {
        let pid = UUID()
        var sv: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, LibC.sockStream, 0, &sv) == 0)
        let creds = AWSCredentialServer(consent: ConsentBroker())
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        await creds.serve(fd: sv[1], profileID: pid)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(sv[0], &buf, buf.count)
        close(sv[0])
        let text = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
        #expect(text.contains("quarantined") && !text.contains("SecretAccessKey"), "\(text)")
    }
}
