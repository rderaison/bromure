import Foundation
import Glibc
import Testing
@testable import ACLinux

/// A guest planning driver's end of the plan-stream socket.
final class FakeDriver: @unchecked Sendable {
    let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in path.utf8.enumerated() { p[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { Glibc.close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    func send(_ lines: String...) {
        let s = lines.map { $0 + "\n" }.joined()
        _ = s.withCString { write(fd, $0, strlen($0)) }
    }
    /// What the host wrote within `ms`.
    func read(ms: Int32 = 1500) async -> String {
        let fd = self.fd
        return await Task.detached {
            var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while poll(&p, 1, ms) > 0 {
                let n = Glibc.read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
                if out.last == 0x0A { break }
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }
    func close() { Glibc.close(fd) }
}

@Suite("Plan streams", .serialized)
@MainActor
struct PlanStreamTests {
    /// Waits (yielding to the main queue the listener reads on) until `cond`.
    func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<200 { if cond() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return cond()
    }

    final class Rig {
        let dir: String
        let stores: SessionStores
        let pid = UUID()
        let task: CodingTask
        let bridge: PlanStreamListener
        let ended = Box<[(String, Bool, String?)]>([])
        let priorShared: SessionStores?
        final class Box<T> { var v: T; init(_ v: T) { self.v = v } }
        @MainActor init() throws {
            dir = try shortTempDir()
            stores = SessionStores(stateDir: dir)
            // The engine host reads the daemon's stores through `shared`.
            priorShared = SessionStores.shared
            SessionStores.shared = stores
            var t = CodingTask(title: "Plan the thing", profileID: pid)
            t.branchSlug = "plan-thing"
            task = t
            stores.codingTasks.upsert(t)
            stores.codingTaskEngine = CodingTaskEngine(store: stores.codingTasks, delegate: nil)
            bridge = try PlanStreamListener(udsPath: dir + "/v.sock", fdStoreName: "test-plan")
            stores.attachPlanBridge(bridge, pid: pid)
            let ended = self.ended
            stores.planStreamHub.onEnded = { _, branch, ok, err in ended.v.append((branch, ok, err)) }
        }
        @MainActor func stop() {
            stores.detachPlanBridge(pid: pid)
            SessionStores.shared = priorShared
            FDStore.remove("test-plan")
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    @Test func eventsBecomeTheItemsTheClientPolls() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let d = try FakeDriver(path: rig.bridge.path); defer { d.close() }
        d.send(#"{"ev":"text","role":"assistant","text":"before any hello: dropped"}"#,
               #"{"ev":"hello","branch":"wt/plan-thing","tool":"claude"}"#,
               #"{"ev":"text","role":"assistant","text":"Let me look at the repo."}"#,
               #"{"ev":"tool","name":"Read","summary":"README.md"}"#,
               #"{"ev":"thinking","text":"hmm"}"#,
               "not json at all",
               #"{"ev":"from-a-newer-guest","x":1}"#)
        #expect(await until { rig.stores.planStreamHub.session(profileID: rig.pid, branch: "wt/plan-thing")?.items.count == 3 })
        let out = rig.stores.taskCommand(rig.task.id, "plan-events", ["since": 0])
        #expect(out["live"] as? Bool == true)
        let items = out["items"] as? [[String: Any]] ?? []
        #expect(items.map { $0["k"] as? String } == ["assistant", "tool", "thinking"], "\(items)")
        #expect(items.first?["text"] as? String == "Let me look at the repo.")
        #expect(out["session"] as? String != nil)
        // The cursor: only what's new.
        let next = rig.stores.taskCommand(rig.task.id, "plan-events", ["since": 2])
        #expect((next["items"] as? [[String: Any]])?.count == 1 && next["since"] as? Int == 2)
        // The engine's watchdog signal (CodingTaskHost.planStreamLive).
        let (host, _, hdir) = try await SessionListModelTests.host()
        defer { try? FileManager.default.removeItem(atPath: hdir) }
        #expect(host.planStreamLive(profileID: rig.pid, branch: "wt/plan-thing"))
        #expect(!host.planStreamLive(profileID: rig.pid, branch: "wt/other"))
    }

    @Test func turnsAndAnswersGoBackToTheDriver() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let d = try FakeDriver(path: rig.bridge.path); defer { d.close() }
        // Nothing is live yet: refused.
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "user", "text": "hi"])["error"] as? String == "no live plan stream")
        d.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"codex"}"#)
        #expect(await until { rig.bridge.isBound(branch: "wt/plan-thing") })
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "user", "text": "go on"])["ok"] as? Bool == true)
        let userLine = await d.read()
        #expect((try? JSONSerialization.jsonObject(with: Data(userLine.utf8)) as? [String: Any])?["text"] as? String == "go on", "\(userLine)")
        // No pending question: an answer is refused.
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "answer", "answers": []])["error"] as? String == "no pending question")
        d.send(#"{"ev":"question","qid":"q1","questions":[{"question":"Which DB?","header":"DB","multiSelect":false,"options":[{"label":"Postgres","description":""},{"label":"SQLite","description":""}]}]}"#)
        #expect(await until { rig.stores.planStreamHub.session(profileID: rig.pid, branch: "wt/plan-thing")?.pendingQID == "q1" })
        let r = rig.stores.taskCommand(rig.task.id, "plan-cmd",
                                       ["type": "answer", "answers": [["question": "Which DB?", "labels": ["SQLite"]]]])
        #expect(r["ok"] as? Bool == true)
        let line = await d.read()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(line)")
        #expect(obj["cmd"] as? String == "answer" && obj["qid"] as? String == "q1")
        #expect((obj["answers"] as? [[String: Any]])?.first?["labels"] as? [String] == ["SQLite"])
        #expect((obj["answers"] as? [[String: Any]])?.first?["other"] is NSNull, "an explicit null, as the protocol shows")
        // Consumed: a second submit reports it.
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "answer", "answers": []])["error"] as? String == "no pending question")
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "bogus"])["error"] as? String == "unknown plan-cmd type")
        // The engine's end: the driver is told.
        let (host, _, hdir) = try await SessionListModelTests.host()
        defer { try? FileManager.default.removeItem(atPath: hdir) }
        host.endPlanStream(profileID: rig.pid, branch: "wt/plan-thing")
        #expect(await d.read() == #"{"cmd":"end"}"# + "\n")
    }

    @Test func aTerminalEventEndsThePlanAndLaterEventsAreDropped() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let d = try FakeDriver(path: rig.bridge.path); defer { d.close() }
        d.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"claude"}"#,
               #"{"ev":"text","role":"assistant","text":"done"}"#,
               #"{"ev":"result","ok":true}"#,
               #"{"ev":"text","role":"assistant","text":"a straggler"}"#)
        #expect(await until { rig.ended.v.count == 1 })
        #expect(rig.ended.v.first?.0 == "wt/plan-thing" && rig.ended.v.first?.1 == true)
        #expect(!rig.bridge.isBound(branch: "wt/plan-thing"), "commands refused after the terminal event")
        let out = rig.stores.taskCommand(rig.task.id, "plan-events", ["since": 0])
        #expect(out["live"] as? Bool == false)
        #expect((out["items"] as? [[String: Any]])?.count == 1, "the straggler isn't shown")
        #expect((out["ended"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func aReconnectReplacesTheOldConnectionAndALostDriverIsDeclaredDead() async throws {
        let rig = try Rig(); defer { rig.stop() }
        SessionStores.planReconnectGrace = 200_000_000   // 0.2 s here (macOS: 90 s)
        defer { SessionStores.planReconnectGrace = 90_000_000_000 }
        let a = try FakeDriver(path: rig.bridge.path); defer { a.close() }
        a.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"claude"}"#)
        #expect(await until { rig.bridge.isBound(branch: "wt/plan-thing") })
        // The driver reconnects (a socket drop): the newest socket wins.
        let b = try FakeDriver(path: rig.bridge.path); defer { b.close() }
        b.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"claude"}"#)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "interrupt"])["ok"] as? Bool == true)
        #expect(await b.read() == #"{"cmd":"interrupt"}"# + "\n", "to the new connection")
        #expect(rig.ended.v.isEmpty, "the replaced connection closing isn't a loss")
        // Now the driver dies without a terminal event, and doesn't come back.
        b.close()
        #expect(await until { rig.ended.v.count == 1 })
        #expect(rig.ended.v.first?.1 == false)
        #expect(rig.ended.v.first?.2?.contains("did not reconnect") == true)
    }

    @Test func aGuestReachesOnlyItsOwnWorkspacesPlans() async throws {
        // Each VM has its own socket, bound to its workspace: B's driver
        // claiming A's task branch makes a session under B, never A's.
        let rig = try Rig(); defer { rig.stop() }
        let pidB = UUID()
        let bridgeB = try PlanStreamListener(udsPath: rig.dir + "/vb.sock", fdStoreName: "test-plan-b")
        rig.stores.attachPlanBridge(bridgeB, pid: pidB)
        defer { rig.stores.detachPlanBridge(pid: pidB); FDStore.remove("test-plan-b") }
        let d = try FakeDriver(path: bridgeB.path); defer { d.close() }
        d.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"claude"}"#,
               #"{"ev":"text","role":"assistant","text":"from B"}"#,
               #"{"ev":"result","ok":true}"#)
        #expect(await until { rig.stores.planStreamHub.session(profileID: pidB, branch: "wt/plan-thing")?.items.count == 1 })
        #expect(rig.stores.planStreamHub.session(profileID: rig.pid, branch: "wt/plan-thing") == nil, "A's task has no session")
        let out = rig.stores.taskCommand(rig.task.id, "plan-events", ["since": 0])
        #expect(out["live"] as? Bool == false && (out["items"] as? [Any])?.isEmpty == true, "A's client sees nothing of B's")
        #expect(rig.ended.v.isEmpty || rig.ended.v.allSatisfy { $0.0 == "wt/plan-thing" })
        #expect(rig.stores.taskCommand(rig.task.id, "plan-cmd", ["type": "user", "text": "x"])["error"] as? String == "no live plan stream",
                "and nothing of A's reaches B's driver")
    }

    @Test func aStoppedWorkspaceTakesItsSessionsWithIt() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let d = try FakeDriver(path: rig.bridge.path); defer { d.close() }
        d.send(#"{"ev":"hello","branch":"wt/plan-thing","tool":"grok"}"#)
        #expect(await until { rig.stores.planStreamHub.isLive(profileID: rig.pid, branch: "wt/plan-thing") })
        rig.stores.detachPlanBridge(pid: rig.pid)
        #expect(!rig.stores.planStreamHub.isLive(profileID: rig.pid, branch: "wt/plan-thing"))
        #expect(rig.stores.planBridges[rig.pid] == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.bridge.path), "the socket file removed")
    }
}

extension FakeDriver {
    /// The host closed its end (EOF within `ms`).
    func closedByHost(ms: Int32 = 5000) async -> Bool {
        let fd = self.fd
        return await Task.detached {
            var buf = [UInt8](repeating: 0, count: 4096)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while poll(&p, 1, ms) > 0 {
                let n = Glibc.read(fd, &buf, buf.count)
                if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { return true }
            }
            return false
        }.value
    }
}

/// The plan-stream listener against a hostile guest: the main queue is
/// never held, and nothing the guest sends grows without end.
@Suite("Plan-stream bounds", .serialized)
@MainActor
struct PlanStreamBoundsTests {
    final class Rig {
        let dir: String
        let listener: PlanStreamListener
        var events: [(String, String)] = []
        var lost: [String] = []
        @MainActor init(_ limits: PlanStreamListener.Limits = .init()) throws {
            dir = try shortTempDir()
            listener = try PlanStreamListener(udsPath: dir + "/v.sock", fdStoreName: "test-plan-bounds", limits: limits)
            listener.onEvent = { [unowned self] b, e in
                if case .hello = e { events.append((b, "hello")) } else { events.append((b, "event")) }
            }
            listener.onConnectionLost = { [unowned self] b in lost.append(b) }
        }
        @MainActor func driver() throws -> FakeDriver { try FakeDriver(path: listener.path) }
        @MainActor func stop() {
            listener.stop()
            FDStore.remove("test-plan-bounds")
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if cond() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return cond()
    }

    static func hello(_ b: String) -> String { #"{"ev":"hello","branch":"\#(b)","tool":"claude"}"# }
    static let text = #"{"ev":"text","role":"assistant","text":"x"}"#

    /// 16 MiB of newlines and junk lines as fast as the guest can write:
    /// no read callback holds the main queue for long (the listener's own
    /// callbacks timed, so other tests' main-queue work doesn't count), the
    /// writes all go in, and the connection still works after.
    @Test func aFloodNeverHoldsTheMainQueue() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let d = try rig.driver(); defer { d.close() }
        let fd = d.fd
        let writer = Task.detached {
            let chunk = [UInt8](String(repeating: "\n{}\n", count: 16 << 10).utf8)   // 64 KiB
            for _ in 0..<256 {
                var off = 0
                while off < chunk.count {
                    let n = chunk[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if n <= 0 { return false }
                    off += n
                }
            }
            return true
        }
        #expect(await writer.value, "the guest's writes all went in")
        #expect(rig.listener.readTurns >= 256, "16 MiB at 64 KiB a turn at most: \(rig.listener.readTurns)")
        #expect(rig.listener.longestTurn < .milliseconds(250), "no callback held the main queue: \(rig.listener.longestTurn)")
        d.send(Self.hello("after"), Self.text)
        #expect(await until { rig.events.count == 2 }, "\(rig.events)")
    }

    /// What a guest already wrote is read a budget at a time, each on its
    /// own turn of the main queue, never all in one callback.
    @Test func whatIsWaitingIsReadABudgetPerTurn() async throws {
        var l = PlanStreamListener.Limits()
        l.readBudget = 1024
        let rig = try Rig(l); defer { rig.stop() }
        let d = try rig.driver(); defer { d.close() }
        // 100 KB of empty lines and then a plan, in the socket before the
        // listener reads any of it (this test holds the main queue).
        let junk = String(repeating: "\n", count: 100_000) + Self.hello("budget") + "\n"
        let n = junk.withCString { write(d.fd, $0, strlen($0)) }
        #expect(n == junk.utf8.count)
        #expect(await until { rig.events.count == 1 })
        #expect(rig.listener.readTurns >= 90, "a turn per KiB: \(rig.listener.readTurns)")
    }

    @Test func aLineOverTheCapClosesTheConnection() async throws {
        var l = PlanStreamListener.Limits()
        l.lineBytes = 1024
        let rig = try Rig(l); defer { rig.stop() }
        let d = try rig.driver(); defer { d.close() }
        d.send(Self.hello("long"))
        #expect(await until { rig.events.count == 1 })
        _ = String(repeating: "a", count: 4000).withCString { write(d.fd, $0, 4000) }   // no newline
        #expect(await d.closedByHost(), "closed on the long line")
        #expect(await until { rig.lost == ["long"] }, "its plan hears the driver lost")
        // One that ends inside the same read: closed too, never delivered.
        let whole = try rig.driver(); defer { whole.close() }
        whole.send(Self.hello("whole"), #"{"ev":"text","role":"assistant","text":""# + String(repeating: "c", count: 4000) + #""}"#)
        #expect(await whole.closedByHost())
        #expect(rig.events.filter { $0.0 == "whole" }.count == 1, "the hello only: \(rig.events.map(\.0))")
        // A line at the cap is fine.
        let ok = try rig.driver(); defer { ok.close() }
        ok.send(Self.hello("ok"), #"{"ev":"text","role":"assistant","text":""# + String(repeating: "b", count: 900) + #""}"#)
        #expect(await until { rig.events.filter { $0.0 == "ok" }.count == 2 })
    }

    @Test func pastTheConnectionCapTheOldestUnboundGoesFirst() async throws {
        var l = PlanStreamListener.Limits()
        l.connections = 2
        let rig = try Rig(l); defer { rig.stop() }
        let a = try rig.driver(); defer { a.close() }
        a.send(Self.hello("a"))
        #expect(await until { rig.events.count == 1 })
        let b = try rig.driver(); defer { b.close() }     // unbound
        try await Task.sleep(nanoseconds: 50_000_000)
        let c = try rig.driver(); defer { c.close() }
        #expect(await b.closedByHost(), "the unbound one made room")
        a.send(Self.text)
        c.send(Self.hello("c"))
        #expect(await until { rig.events.count == 3 }, "the bound one and the new one work: \(rig.events)")
        // Every one bound: the oldest bound goes.
        let e = try rig.driver(); defer { e.close() }
        #expect(await a.closedByHost(), "the oldest bound one made room")
        e.send(Self.hello("e"))
        #expect(await until { rig.events.contains { $0.0 == "e" } })
    }

    @Test func pastTheBranchCapAHelloIsRefused() async throws {
        var l = PlanStreamListener.Limits()
        l.branches = 2
        let rig = try Rig(l); defer { rig.stop() }
        let d1 = try rig.driver(), d2 = try rig.driver(), d3 = try rig.driver()
        defer { d1.close(); d2.close(); d3.close() }
        d1.send(Self.hello("b1"))
        d2.send(Self.hello("b2"))
        #expect(await until { rig.events.count == 2 })
        d3.send(Self.hello("b3"))
        #expect(await d3.closedByHost(), "a third branch is refused")
        #expect(!rig.events.contains { $0.0 == "b3" })
        // A known branch reconnecting is not a new one.
        let again = try rig.driver(); defer { again.close() }
        again.send(Self.hello("b1"))
        #expect(await until { rig.events.filter { $0.0 == "b1" }.count == 2 })
    }

    @Test func pastItsShareABranchIsCutOff() async throws {
        var l = PlanStreamListener.Limits()
        l.eventsPerBranch = 3
        let rig = try Rig(l); defer { rig.stop() }
        let d = try rig.driver(); defer { d.close() }
        d.send(Self.hello("n"), Self.text, Self.text, Self.text, Self.text)
        #expect(await d.closedByHost())
        #expect(rig.events.count == 3, "the hello and two events, then nothing: \(rig.events)")
        #expect(rig.lost == ["n"])
        // Reconnecting doesn't reset its share.
        let again = try rig.driver(); defer { again.close() }
        again.send(Self.hello("n"))
        #expect(await again.closedByHost())
        #expect(rig.events.count == 3)

        var b = PlanStreamListener.Limits()
        b.bytesTotal = 200
        let rig2 = try Rig(b); defer { rig2.stop() }
        let x = try rig2.driver(), y = try rig2.driver()
        defer { x.close(); y.close() }
        x.send(Self.hello("x"), Self.text)
        #expect(await until { rig2.events.count == 2 })
        y.send(Self.hello("y"), Self.text, Self.text, Self.text)
        #expect(await y.closedByHost(), "the listener's total is spent across branches")
    }

    @Test func aRestartedDaemonTakesThePlanListenerBack() {
        #expect(Daemon.perVMStorePrefixes.contains { ("plan-" + "abc123").hasPrefix($0) },
                "kept for adoption, not closed as stale")
    }
}
