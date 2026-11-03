import Foundation
import os
import Testing
@testable import bromure_ac

/// Board report: over a slow link the window doesn't move for a while after
/// Send, and the clicks that follow each started an identical session.
@Suite("New session: the same start twice is one session", .serialized)
struct SessionStartCoalescerTests {
    private func key(_ message: String = "fix the tests") -> String {
        SessionStartCoalescer.key(profile: "P", tool: "claude", cwd: "~", cloneURL: nil, message: message,
                                  instructions: nil, room: nil, attachments: [])
    }

    /// A clock the test moves; read from any thread.
    private final class Clock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date())
        var now: Date { lock.withLock { $0 } }
        func advance(_ s: TimeInterval) { lock.withLock { $0 += s } }
    }

    @Test("again within 10 s of its start: the first's session; after, or different, a new one")
    func window() {
        let c = SessionStartCoalescer()
        let clock = Clock()
        var started = 0
        func start(_ k: String) -> String? {
            c.run(k, now: { clock.now }) { started += 1; return ["ok": true, "id": "S\(started)"] }["id"] as? String
        }
        #expect(start(key()) == "S1")
        clock.advance(3)
        #expect(start(key()) == "S1")   // Send clicked again
        #expect(start(key("something else")) == "S2")
        clock.advance(11)
        #expect(start(key()) == "S3")   // a deliberate second one, later
        #expect(started == 3)
        // "~", "" and "~/" are the same folder; surrounding blanks don't count.
        #expect(SessionStartCoalescer.key(profile: "p", tool: "claude", cwd: "", cloneURL: nil, message: " fix the tests ",
                                          instructions: nil, room: nil, attachments: []) == key())
    }

    @Test("a start that failed isn't remembered: the retry goes through")
    func failureNotRemembered() {
        let c = SessionStartCoalescer()
        var calls = 0
        _ = c.run(key()) { calls += 1; return ["error": "no machine"] }
        let r = c.run(key()) { calls += 1; return ["ok": true, "id": "S"] }
        #expect(calls == 2 && r["id"] as? String == "S")
    }

    /// Review: a second Send 11 s into a minute-long start (an attached
    /// machine's) didn't wait, started another session, and the first's
    /// completion was written on the second's slot.
    @Test("a Send while the first still starts — however long it takes — waits, and gets its session")
    func pendingIsWaitedFor() async {
        let c = SessionStartCoalescer()
        let clock = Clock()
        let k = key()
        let gate = DispatchSemaphore(value: 0)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        @Sendable func work() -> [String: Any] {
            let n = counter.withLock { $0 += 1; return $0 }
            gate.wait()
            return ["ok": true, "id": "S\(n)"]
        }
        let first = Task.detached { c.run(k, now: { clock.now }, work)["id"] as? String }
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(11)   // the machine is slow
        let second = Task.detached { c.run(k, now: { clock.now }, work)["id"] as? String }
        try? await Task.sleep(nanoseconds: 100_000_000)
        gate.signal()
        let a = await first.value, b = await second.value
        #expect(a == "S1" && b == "S1")
        #expect(counter.withLock { $0 } == 1)
    }

    /// Review: after a long failed start the retry's slot was stamped with
    /// the time before it waited — already "old" — so the next identical
    /// Send didn't wait for the retry and started a second session.
    @Test("after a failed start, the retry is waited for by the next Send too")
    func retryAfterFailureIsWaitedFor() async {
        let c = SessionStartCoalescer()
        let clock = Clock()
        let k = key()
        let failGate = DispatchSemaphore(value: 0), okGate = DispatchSemaphore(value: 0)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let a = Task.detached { c.run(k, now: { clock.now }) {
            counter.withLock { $0 += 1 }; failGate.wait(); return ["error": "timed out"] } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let b = Task.detached { c.run(k, now: { clock.now }) {
            counter.withLock { $0 += 1 }; okGate.wait(); return ["ok": true, "id": "B"] }["id"] as? String }
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(50)
        failGate.signal()   // A fails; B (waiting) becomes the retry
        try? await Task.sleep(nanoseconds: 200_000_000)
        let third = Task.detached { c.run(k, now: { clock.now }) {
            counter.withLock { $0 += 1 }; return ["ok": true, "id": "C"] }["id"] as? String }
        try? await Task.sleep(nanoseconds: 100_000_000)
        okGate.signal()
        _ = await a.value
        let rb = await b.value, rc = await third.value
        #expect(rb == "B" && rc == "B")
        #expect(counter.withLock { $0 } == 2)
    }

    private func token(_ c: SessionStartCoalescer.Claim) -> UUID? {
        if case .mine(let t) = c { return t }
        return nil
    }
    private func underWay(_ c: SessionStartCoalescer.Claim) -> Bool {
        if case .underWay = c { return true }
        return false
    }
    private func doneID(_ c: SessionStartCoalescer.Claim) -> String? {
        if case .done(let r) = c { return r["id"] as? String }
        return nil
    }

    @Test("a start that can't wait: told to wait while the same one runs; its reply, id and all, answers the rest")
    func claim() {
        let c = SessionStartCoalescer()
        let now = Date()
        let t1 = token(c.claim(key(), now: now))
        #expect(t1 != nil)
        #expect(underWay(c.claim(key(), now: now + 30)))   // still under way
        c.finish(key(), token: t1!, reply: nil, now: now + 31)   // it failed: a retry may go
        let t2 = token(c.claim(key(), now: now + 32))
        #expect(t2 != nil)
        // A stale finish (the first, again) can't touch the new attempt.
        c.finish(key(), token: t1!, reply: nil, now: now + 33)
        #expect(underWay(c.claim(key(), now: now + 33)))
        c.finish(key(), token: t2!, reply: ["ok": true, "id": "M"], now: now + 34)
        // A client's same start through the hub gets the session's id.
        let r = c.run(key(), now: { now + 36 }) { ["ok": true, "id": "other"] }
        #expect(r["id"] as? String == "M")
    }

    /// Finding (CWE-670): a local Start clicked while the same start (a
    /// client's, through the hub) had just finished was dropped — the window
    /// stayed on the new-session screen instead of opening that session.
    @Test("a local Start after the hub's same start: that session's id, to open")
    func claimAfterHubStart() {
        let c = SessionStartCoalescer()
        let now = Date()
        _ = c.run(key(), now: { now }) { ["ok": true, "id": "HUB"] }
        #expect(doneID(c.claim(key(), now: now + 3)) == "HUB")
        // The window's key for a start on a machine is the hub's for the
        // same body — files and all.
        let m = UUID()
        let file = DroppedFile(name: "a.txt", data: Data("hello".utf8), isImage: false)
        var req = AgentSessionRequest(profileID: UUID(), tool: .claude, cwd: "~")
        req.openingMessage = "go"; req.instructions = "be terse"; req.attachments = [file]
        let hub = SessionStartCoalescer.key(profile: m.uuidString, tool: "claude", cwd: "~", cloneURL: nil,
                                            message: "go", instructions: "be terse", room: nil,
                                            attachments: [SessionStartCoalescer.attachment(wire: file.wireDictionary)])
        #expect(SessionStartCoalescer.machineKey(req, machine: m, room: nil) == hub)
        // Finding (CWE-670): another preset, or a folder dropped too, is
        // another start — never the first one's session.
        var otherPreset = req; otherPreset.instructions = "be thorough"
        #expect(SessionStartCoalescer.machineKey(otherPreset, machine: m, room: nil) != hub)
        var noPreset = req; noPreset.instructions = nil
        #expect(SessionStartCoalescer.machineKey(noPreset, machine: m, room: nil) != hub)
        var withFolder = req
        withFolder.attachments.append(DroppedFile(name: "src", data: Data(), isImage: false,
                                                  folder: URL(fileURLWithPath: "/tmp/src")))
        #expect(SessionStartCoalescer.machineKey(withFolder, machine: m, room: nil) != hub)
        var otherFolder = req
        otherFolder.attachments.append(DroppedFile(name: "src", data: Data(), isImage: false,
                                                   folder: URL(fileURLWithPath: "/tmp/other/src")))
        #expect(SessionStartCoalescer.machineKey(otherFolder, machine: m, room: nil)
                != SessionStartCoalescer.machineKey(withFolder, machine: m, room: nil))
        // Past the window: a deliberate new one.
        #expect(token(c.claim(key(), now: now + 11)) != nil)
    }

    /// Finding (CWE-362): the fat client read the start's reply with the 12 s
    /// default while the server held it up to a minute (an attached
    /// machine's call), so the client gave up and the next click raced the
    /// first start. The client now waits as long as the server can hold it:
    /// a repeat's wait for the first, then its own machine call (up to 10 s
    /// waiting for a parked link, then 60 s for the answer).
    @Test("a client's Start waits as long as the server may hold it")
    func clientOutlastsServer() {
        #expect(TimeInterval(RemoteHostController.sessionStartTimeout) > SessionStartCoalescer.pendingWait + 10 + 60)
    }

    @Test("the composer's file and a client's same file make the same key")
    func attachmentsMatch() {
        let data = Data("hello".utf8)
        let wire: [String: Any] = ["name": "a.txt", "data": data.base64EncodedString(), "isImage": false]
        #expect(SessionStartCoalescer.attachment(wire: wire) == SessionStartCoalescer.attachment(name: "a.txt", bytes: data.count))
    }
}
