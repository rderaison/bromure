import Foundation
import Testing
@testable import bromure_ac

// The fat-client browser relay carries every agent of a workspace on ONE
// channel by rewriting JSON-RPC ids: each agent's request goes out with a
// channel-unique id, and the answer comes back to that agent with the id it
// used. Notifications pass through; an answer for an agent that left is
// dropped.

@Suite("Browser MCP relay id map")
struct BrowserMCPRelayTests {
    private final class Agent {}

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    @Test("two agents with clashing ids get distinct channel ids and their own answers back")
    func interleave() {
        var map = BrowserMCPRelayIDMap()
        let a = ObjectIdentifier(Agent()), b = ObjectIdentifier(Agent())
        // Both agents start with id 1 (every MCP client does).
        let outA = map.outbound(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, from: a)
        let outB = map.outbound(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, from: b)
        let idA = json(outA)["id"] as? Int, idB = json(outB)["id"] as? Int
        #expect(idA != nil && idB != nil && idA != idB)
        #expect(json(outA)["method"] as? String == "initialize")
        #expect(map.pendingCount == 2)

        // Answers come back in any order; each lands with the agent's own id.
        let replyB = map.inbound(#"{"jsonrpc":"2.0","id":\#(idB!),"result":{"tools":[]}}"#)
        guard case .reply(let agentB, let lineB) = replyB else { Issue.record("expected a reply"); return }
        #expect(agentB == b)
        #expect(json(lineB)["id"] as? Int == 1)
        let replyA = map.inbound(#"{"jsonrpc":"2.0","id":\#(idA!),"result":{}}"#)
        guard case .reply(let agentA, let lineA) = replyA else { Issue.record("expected a reply"); return }
        #expect(agentA == a)
        #expect(json(lineA)["id"] as? Int == 1)
        #expect(map.pendingCount == 0)
    }

    @Test("string ids survive the round trip")
    func stringIDs() {
        var map = BrowserMCPRelayIDMap()
        let a = ObjectIdentifier(Agent())
        let out = map.outbound(#"{"jsonrpc":"2.0","id":"req-7","method":"ping"}"#, from: a)
        let mid = json(out)["id"] as? Int
        #expect(mid != nil)
        guard case .reply(_, let line) = map.inbound(#"{"jsonrpc":"2.0","id":\#(mid!),"result":{}}"#)
        else { Issue.record("expected a reply"); return }
        #expect(json(line)["id"] as? String == "req-7")
    }

    @Test("notifications pass through untouched; unknown or forgotten answers are stale")
    func notificationsAndStale() {
        var map = BrowserMCPRelayIDMap()
        let a = ObjectIdentifier(Agent())
        let note = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        #expect(map.outbound(note, from: a) == note)
        #expect(map.pendingCount == 0)
        #expect(map.inbound(note) == .notification)
        #expect(map.inbound(#"{"jsonrpc":"2.0","id":99,"result":{}}"#) == .stale)
        let out = map.outbound(#"{"jsonrpc":"2.0","id":3,"method":"tools/call"}"#, from: a)
        let mid = json(out)["id"] as? Int
        map.forget(agent: a)   // the agent's shim went away before the answer
        #expect(map.inbound(#"{"jsonrpc":"2.0","id":\#(mid!),"result":{}}"#) == .stale)
        #expect(map.inbound("not json") == .stale)
    }
}
