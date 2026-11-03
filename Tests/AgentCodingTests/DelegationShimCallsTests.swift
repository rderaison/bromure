import Foundation
import Testing
@testable import bromure_ac

/// Board report: in a Sidecar session the delegation tools said "No Bromure
/// AC is connected" while ark was up (a relay gap landed calls on the local
/// fallback), a call hung until Claude's 30-minute limit, and a `wait` ran
/// far past its timeout (calls lost with a dropped or silent relay stream).
@Suite("Sidecar delegation shim: calls in flight")
struct DelegationShimCallsTests {
    private func line(_ obj: [String: Any]) -> Data {
        (try! JSONSerialization.data(withJSONObject: obj)) + Data([0x0A])
    }
    private func call(_ id: Any, _ tool: String, _ args: [String: Any] = [:]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]])
    }

    @Test("a request is in flight until its reply; notifications and replies aren't calls")
    func tracking() {
        var c = DelegationShimCalls()
        c.sent(call(1, "wait", ["timeout_seconds": 50]), on: 1)
        c.sent(call("a", "deliver"), on: 1)
        c.sent(line(["jsonrpc": "2.0", "method": "notifications/initialized"]), on: 1)
        #expect(c.calls.count == 2)
        c.answered(line(["jsonrpc": "2.0", "id": 1, "result": [:]]))
        #expect(c.calls.map(\.key) == [DelegationShimCalls.key("a")])
        // A request from the server (method + id) doesn't settle ours.
        c.answered(line(["jsonrpc": "2.0", "id": "a", "method": "ping"]))
        #expect(c.calls.count == 1)
    }

    @Test("what a stream held comes back with it; others stay")
    func takeByStream() {
        var c = DelegationShimCalls()
        let first = call(1, "list_peers")
        c.sent(first, on: 1)
        c.sent(call(2, "wait"), on: 2)
        let held = c.take(gen: 1)
        #expect(held.count == 1 && held[0].line == first)
        #expect(c.calls.count == 1 && c.calls[0].gen == 2)
    }

    @Test("a blocking call's deadline is its timeout plus a margin; anything else a generous bound")
    func deadlines() {
        let t0 = Date()
        var c = DelegationShimCalls()
        c.sent(call(1, "wait", ["timeout_seconds": 50]), on: 1, now: t0)
        c.sent(call(2, "wait", ["timeout_seconds": 600]), on: 1, now: t0)   // capped at 50
        c.sent(call(3, "deliver"), on: 1, now: t0)
        #expect(c.overdue(now: t0.addingTimeInterval(80)).isEmpty)
        #expect(Set(c.overdue(now: t0.addingTimeInterval(91)).map(\.key))
                == [DelegationShimCalls.key(1), DelegationShimCalls.key(2)])
        #expect(c.overdue(now: t0.addingTimeInterval(301)).count == 3)
        // Review: a call that copies files (or starts a delegate, booting a
        // workspace) may run past a boot and a 30-minute copy — not cut at
        // 90 s or 5 min while the work goes on.
        var long = DelegationShimCalls()
        long.sent(call(4, "request", ["timeout_seconds": 30, "files": ["~/a.txt"]]), on: 1, now: t0)
        long.sent(call(5, "delegate"), on: 1, now: t0)
        long.sent(call(6, "deliver", ["files": ["~/out.tgz"]]), on: 1, now: t0)
        long.sent(call(7, "request", ["timeout_seconds": 30, "files": []]), on: 1, now: t0)
        #expect(long.overdue(now: t0.addingTimeInterval(1900)).map(\.key) == [DelegationShimCalls.key(7)])
        // No bound fits a copy (folders, many files, a tunnel): never timed out.
        #expect(long.overdue(now: t0.addingTimeInterval(7 * 24 * 3600)).map(\.key) == [DelegationShimCalls.key(7)])
    }

    @Test("a lost call gets an error reply with its own id — a tool result for a tool call")
    func lostReply() throws {
        var c = DelegationShimCalls()
        c.sent(call(7, "request"), on: 1)
        c.sent(line(["jsonrpc": "2.0", "id": "x", "method": "tools/list"]), on: 1)
        let lost = c.take(gen: 1)
        let tool = try #require(JSONSerialization.jsonObject(with: DelegationShimCalls.lostReply(lost[0])) as? [String: Any])
        #expect(tool["id"] as? Int == 7)
        let result = try #require(tool["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("list_delegations"))
        let other = try #require(JSONSerialization.jsonObject(with: DelegationShimCalls.lostReply(lost[1])) as? [String: Any])
        #expect(other["id"] as? String == "x" && other["error"] != nil)
    }
}
