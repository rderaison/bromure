import Foundation
import Testing
@testable import bromure_ac

/// Board finding: the Sidecar delegation shim closed "fd 7" from whichever
/// thread saw a write fail — a reconnect reuses the number, so a late drop
/// from a stream already replaced closed the new one, and a call written on
/// it stayed pending on a socket nobody read (a `delegate` hung for good)
/// while the hub had run it. Only the reader closes a stream now; the others
/// shut down the one they saw, and only while it's still current.
@Suite("Sidecar delegation shim: who ends a stream", .serialized)
struct DelegationShimStreamTests {
    private func call(_ id: Int, _ tool: String, _ args: [String: Any] = [:]) -> Data {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                  "params": ["name": tool, "arguments": args]]
        return (try! JSONSerialization.data(withJSONObject: obj)) + Data([0x0A])
    }

    /// A connected pair: (ours, the hub's end).
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// Whether `fd` still carries bytes to its peer.
    private func carries(_ fd: Int32, to peer: Int32) -> Bool {
        guard DelegationShimStream.writeAll(Data("x\n".utf8), fd) else { return false }
        var b = [UInt8](repeating: 0, count: 8)
        return read(peer, &b, b.count) > 0
    }

    @Test("a late drop of a replaced stream leaves the new one alone — same fd number")
    func lateDropSparesReplacement() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream()
        let (a, hubA) = pair()
        let genA = s.open(a)
        _ = s.ended(a, genA)                       // stream A ends; its number is free
        close(hubA)
        let (b, hubB) = pair()                     // the reconnect usually gets it back
        defer { close(hubB) }
        let genB = s.open(b)
        // A writer still holding stream A (whatever its number now names).
        s.abandon(a, genA)
        #expect(s.send(call(1, "list_peers"), a, genA) == .stale)
        // Stream B is untouched, still current, still connected.
        let cur = s.current(timeout: 0)
        #expect(cur?.fd == b && cur?.gen == genB)
        #expect(carries(b, to: hubB))
        _ = s.ended(b, genB)
    }

    @Test("a failed write shuts the stream down for its reader, never closes it")
    func failedWriteShutsDown() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream(writeLine: { _, _ in false })
        let (a, hubA) = pair()
        defer { close(hubA) }
        let gen = s.open(a)
        #expect(s.send(call(1, "list_peers"), a, gen) == .failed)
        #expect(s.inFlight.isEmpty)                // taken back: the writer sends it again
        #expect(s.current(timeout: 0) == nil)      // writers wait for the reader's reconnect
        #expect(fcntl(a, F_GETFD) != -1)           // still open: the number isn't free
        var b = [UInt8](repeating: 0, count: 4)
        #expect(read(a, &b, b.count) == 0)         // the reader sees EOF
        _ = s.ended(a, gen)
        #expect(fcntl(a, F_GETFD) == -1)           // the reader closes it
    }

    @Test("a stream's end hands back every call on it, delegate and file copies included")
    func endedHandsBackHeld() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream()
        let (a, hubA) = pair()
        defer { close(hubA) }
        let gen = s.open(a)
        #expect(s.send(call(1, "delegate"), a, gen) == .sent)
        #expect(s.send(call(2, "request", ["files": ["x"]]), a, gen) == .sent)
        #expect(s.send(call(3, "list_peers"), a, gen) == .sent)
        s.answered(Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8))
        s.markLocal(gen)
        let (wasLocal, held, open) = s.ended(a, gen)
        #expect(wasLocal)
        #expect(open)
        #expect(Set(held.map(\.key)) == [DelegationShimCalls.key(1), DelegationShimCalls.key(2)])
        #expect(s.inFlight.isEmpty)
    }

    @Test("the watchdog answers calls on a gone stream, shuts down only the current one")
    func watchdogScope() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream()
        let (a, hubA) = pair()
        defer { close(hubA) }
        let genA = s.open(a)
        #expect(s.send(call(1, "list_peers"), a, genA) == .sent)
        s.abandon(a, genA)                         // A died; its reader hasn't caught up
        let (b, hubB) = pair()
        defer { close(hubB) }
        let genB = s.open(b)
        #expect(s.send(call(2, "list_peers"), b, genB) == .sent)
        #expect(s.send(call(3, "delegate"), b, genB) == .sent)

        // Nothing late yet.
        let quiet = s.watchdog(now: Date())
        #expect(quiet.orphans.isEmpty && quiet.late == nil)
        #expect(carries(b, to: hubB))

        // Past the 5-minute limit: A's call is answered here, B is shut down
        // (its reader answers 2 and 3); `delegate` is never late by itself.
        let r = s.watchdog(now: Date().addingTimeInterval(400))
        #expect(r.orphans.map(\.key) == [DelegationShimCalls.key(1)])
        #expect(r.late?.key == DelegationShimCalls.key(2))
        #expect(s.current(timeout: 0) == nil)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(read(b, &buf, buf.count) == 0)
        let (_, held, _) = s.ended(b, genB)
        #expect(Set(held.map(\.key)) == [DelegationShimCalls.key(2), DelegationShimCalls.key(3)])
        _ = s.ended(a, genA)
    }

    @Test("after shutting a late stream down, the watchdog leaves its calls to the reader")
    func watchdogLeavesShutStreamToReader() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream()
        let (a, hubA) = pair()
        defer { close(hubA) }
        let gen = s.open(a)
        #expect(s.send(call(1, "list_peers"), a, gen) == .sent)
        let later = Date().addingTimeInterval(400)
        let first = s.watchdog(now: later)
        #expect(first.late?.key == DelegationShimCalls.key(1))
        #expect(first.orphans.isEmpty)
        // The reader hasn't reached EOF yet — its reply may be in its buffer.
        let second = s.watchdog(now: later.addingTimeInterval(2))
        #expect(second.orphans.isEmpty && second.late == nil)
        s.answered(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        let (_, held, _) = s.ended(a, gen)
        #expect(held.isEmpty)                      // one reply, the real one
    }

    @Test("stdin closing half-closes the current stream and the next one")
    func inputClosedHalfCloses() {
        signal(SIGPIPE, SIG_IGN)
        let s = DelegationShimStream()
        let (a, hubA) = pair()
        defer { close(hubA) }
        let gen = s.open(a)
        s.inputClosed()
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(read(hubA, &buf, buf.count) == 0)  // the hub hears the end of input
        let (_, _, open) = s.ended(a, gen)
        #expect(!open)
        let (b, hubB) = pair()
        defer { close(hubB) }
        let genB = s.open(b)
        #expect(read(hubB, &buf, buf.count) == 0)
        _ = s.ended(b, genB)
    }
}
