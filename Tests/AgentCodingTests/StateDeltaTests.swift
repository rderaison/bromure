import Foundation
import Testing
@testable import bromure_ac

@Suite("The state feed sends only the sections that changed")
struct StateDeltaTests {
    typealias Server = ACAutomationServer
    private func json(_ d: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data() }
    /// Built once per test: the same delegation has the same messages in every state.
    private static let texts: [String: [[String: Any]]] = Dictionary(uniqueKeysWithValues: ["d1", "d2", "d9"].map { d in
        (d, (0..<40).map { i in ["text": "\(d)-\(i)-" + (0..<8).map { _ in UUID().uuidString }.joined()] })
    })
    private func state(cpu: Double, uptime: Int, delegations: [String], generation: Int) -> [String: Any] {
        ["version": 3, "generation": generation, "epoch": "e1",
         "vms": [["id": "vm1", "cpu": cpu, "uptimeSeconds": uptime]],
         // Text that doesn't compress to nothing, as real messages don't.
         "delegations": delegations.map { d in ["id": d, "messages": Self.texts[d] ?? []] },
         "tasks": [["id": "t1"]]]
    }
    /// The client's side: frames off the wire, the last whole one and the deltas after it, merged.
    private func receive(_ frames: [Data], into state: [String: Any]?) -> [String: Any]? {
        var buf = [UInt8](frames.reduce(Data(), +))
        var s = state
        let got = SnapshotFrames.takeAll(from: &buf)
        #expect(!got.bogus && buf.isEmpty)
        for f in SnapshotFrames.fromLastWhole(got.frames) {
            var data = f.payload
            if f.compressed, let inflated = try? (data as NSData).decompressed(using: .zlib) { data = inflated as Data }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            s = f.delta ? s.map { SnapshotFrames.merge($0, delta: obj) } : obj
        }
        return s
    }

    @Test("a CPU figure moving sends the VMs, not the delegations; merged, it's the new state")
    func onlyWhatChanged() throws {
        let a = state(cpu: 1, uptime: 10, delegations: ["d1", "d2"], generation: 1)
        let b = state(cpu: 42, uptime: 11, delegations: ["d1", "d2"], generation: 2)
        let (set, unset) = Server.changedSections(from: Server.comparableSections(a), to: Server.comparableSections(b))
        #expect(set == ["vms"] && unset.isEmpty)
        let whole = Server.wholeFrame(a), delta = Server.deltaFrame(snapshot: b, set: set, unset: unset)
        #expect(delta.count * 10 < whole.count)                 // a fraction of the whole state
        let merged = try #require(receive([whole, delta], into: nil))
        #expect(json(merged) == json(b))                        // generation and uptime came along
    }

    @Test("uptime alone isn't a change; a section gone is removed; sections come and go in order")
    func sequence() throws {
        let a = state(cpu: 1, uptime: 10, delegations: ["d1"], generation: 1)
        let tick = state(cpu: 1, uptime: 99, delegations: ["d1"], generation: 1)
        #expect(Server.changedSections(from: Server.comparableSections(a), to: Server.comparableSections(tick)) == ([], []))
        var b = state(cpu: 1, uptime: 12, delegations: ["d1", "d2"], generation: 2)
        b["tasks"] = nil
        b["pendingMachines"] = [["id": "m1"]]
        let ab = Server.changedSections(from: Server.comparableSections(a), to: Server.comparableSections(b))
        // The VM's CPU didn't move, only its uptime: not a change.
        #expect(ab.set == ["delegations", "pendingMachines"] && ab.unset == ["tasks"])
        let c = state(cpu: 3, uptime: 13, delegations: ["d2"], generation: 3)
        let bc = Server.changedSections(from: Server.comparableSections(b), to: Server.comparableSections(c))
        let frames = [Server.wholeFrame(a), Server.deltaFrame(snapshot: b, set: ab.set, unset: ab.unset),
                      Server.deltaFrame(snapshot: c, set: bc.set, unset: bc.unset)]
        // Arriving together or one read at a time, it ends the same.
        #expect(json(try #require(receive(frames, into: nil))) == json(c))
        var s = receive([frames[0]], into: nil)
        s = receive([frames[1]], into: s)
        s = receive([frames[2]], into: s)
        #expect(json(try #require(s)) == json(c))
    }

    @Test("a whole frame after deltas replaces them; deltas before it aren't read")
    func wholeResets() throws {
        let a = state(cpu: 1, uptime: 1, delegations: ["d1"], generation: 1)
        let b = state(cpu: 2, uptime: 2, delegations: ["d9"], generation: 2)
        let stray = Server.deltaFrame(snapshot: ["vms": "garbage"], set: ["vms"], unset: [])
        var buf = [UInt8]([stray, Server.wholeFrame(b)].reduce(Data(), +))
        let got = SnapshotFrames.takeAll(from: &buf)
        #expect(SnapshotFrames.fromLastWhole(got.frames).count == 1)
        #expect(json(try #require(receive([stray, Server.wholeFrame(b)], into: a))) == json(b))
    }

    @Test("an older server's frames (flag 0 and 1) still read as whole states")
    func olderServer() throws {
        let a = state(cpu: 1, uptime: 1, delegations: ["d1"], generation: 1)
        let raw = json(a)
        var lenBE = UInt32(raw.count + 1).bigEndian
        var plain = Data(bytes: &lenBE, count: 4); plain.append(0); plain.append(raw)
        #expect(json(try #require(receive([plain], into: nil))) == raw)
        #expect(json(try #require(receive([Server.wholeFrame(a)], into: nil))) == raw)   // zlib, flag 1
    }

    @Test("the client asks for deltas; the server only sends them to a client that asked")
    func negotiated() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fc = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(fc.contains(#"openStream("GET", "/state/subscribe", body: [:], headers: ["X-Bromure-State-Delta": "1"])"#))
        let srv = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AutomationServer.swift"), encoding: .utf8)
        #expect(srv.contains(#"let stateDelta = headerBlock.range(of: "x-bromure-state-delta: 1", options: .caseInsensitive) != nil"#))
        // Negotiated inside the owner-only route, never dispatched before it.
        #expect(srv.contains("""
                    guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
                    handleStateSubscribe(fd: fd, delta: stateDelta)
        """))
        #expect(srv.components(separatedBy: "handleStateSubscribe(fd: fd").count - 1 == 1)
        #expect(srv.contains("if delta, let frames = feedDeltas(after: seen) {"))
    }
}

@Suite("The live state feed, over a socket")
struct StateFeedLiveTests {
    final class Box: @unchecked Sendable { let lock = NSLock(); var cpu = 1.0
        func get() -> Double { lock.lock(); defer { lock.unlock() }; return cpu }
        func set(_ v: Double) { lock.lock(); cpu = v; lock.unlock() } }

    /// A subscriber: frames until its first one, then `then`, then until
    /// `done` says it has what it waits for. Bounded, so a feed that never
    /// sends fails the test instead of hanging it; not timed, so a loaded
    /// machine only makes it slower.
    private static func subscribe(_ path: String, delta: Bool, then: (() -> Void)? = nil,
                                  done: ([SnapshotFrames.Frame]) -> Bool) throws -> [SnapshotFrames.Frame] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in path.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, 103) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
        let req = "GET /state/subscribe HTTP/1.1\r\nHost: localhost\r\n" + (delta ? "X-Bromure-State-Delta: 1\r\n" : "")
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var raw = [UInt8](), frames: [SnapshotFrames.Frame] = [], headerDone = false
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        func pump(until stop: () -> Bool) {
            let end = Date().addingTimeInterval(20)
            while Date() < end, !stop() {
                let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
                if n > 0 { raw += chunk[0..<n] }
                if !headerDone, let r = Data(raw).range(of: Data("\r\n\r\n".utf8)) { raw.removeFirst(r.upperBound); headerDone = true }
                if headerDone { frames += SnapshotFrames.takeAll(from: &raw).frames }
            }
        }
        pump { !frames.isEmpty }
        then?()
        pump { done(frames) }
        return frames
    }

    private static func decode(_ f: SnapshotFrames.Frame) -> [String: Any] {
        var data = f.payload
        if f.compressed, let inflated = try? (data as NSData).decompressed(using: .zlib) { data = inflated as Data }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test("a delta subscriber starts whole, then gets only the VMs when a CPU figure moves; an older one gets it all")
    func live() async throws {
        let path = NSTemporaryDirectory() + "sf-\(UUID().uuidString.prefix(6)).sock"
        let server = ACAutomationServer(unixSocketPath: path)
        let box = Box()
        server.onListVMs = { [["id": "vm1", "cpu": box.get(), "uptimeSeconds": 5]] }
        server.onListDelegations = { (0..<30).map { ["id": "d\($0)", "text": String(repeating: "x", count: 500)] } }
        server.start()
        defer { server.stop(); unlink(path) }
        try await Task.sleep(for: .milliseconds(200))
        func cpu(_ f: SnapshotFrames.Frame) -> Double? {
            let o = Self.decode(f)
            let vms = (f.delta ? (o["set"] as? [String: Any])?["vms"] : o["vms"]) as? [[String: Any]]
            return vms?.first?["cpu"] as? Double
        }
        async let deltaFrames = Task.detached {
            try Self.subscribe(path, delta: true, then: { box.set(77) }, done: { $0.contains { $0.delta && cpu($0) == 77 } })
        }.value
        async let wholeFrames = Task.detached {
            try Self.subscribe(path, delta: false, done: { $0.contains { !$0.delta && cpu($0) == 77 } })
        }.value
        let d = try await deltaFrames, w = try await wholeFrames
        // Delta subscriber: a whole frame, then a delta of the VMs alone.
        #expect(d.first?.delta == false)
        let deltas = d.dropFirst().filter(\.delta)
        #expect(!deltas.isEmpty)
        var state = Self.decode(try #require(d.first))
        for f in d.dropFirst() { state = f.delta ? SnapshotFrames.merge(state, delta: Self.decode(f)) : Self.decode(f) }
        #expect(((state["vms"] as? [[String: Any]])?.first?["cpu"] as? Double) == 77)
        #expect((state["delegations"] as? [[String: Any]])?.count == 30)
        for f in deltas {
            let set = Self.decode(f)["set"] as? [String: Any] ?? [:]
            #expect(set["delegations"] == nil, "a delta resent the delegations")
        }
        // The older subscriber never gets a delta, and ends on the same state.
        #expect(!w.isEmpty && w.allSatisfy { !$0.delta })
        let last = Self.decode(try #require(w.last))
        #expect(((last["vms"] as? [[String: Any]])?.first?["cpu"] as? Double) == 77)
    }
}

/// The loopback TCP listener is reachable by any local process: the state feed,
/// delta or not, is only for the owner-only Unix socket. A delta request was
/// dispatched before the route's guard and got the whole state, then deltas
/// (CWE-862).
@Suite("The state feed refuses the TCP listener, delta or not")
struct StateFeedTCPGuardTests {
    private static func request(port: UInt16, _ path: String, headers: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
        let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var raw = [UInt8](), chunk = [UInt8](repeating: 0, count: 1 << 16)
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
            if n > 0 { raw += chunk[0..<n] } else if n == 0 { break }
            if raw.count > 12, String(decoding: raw, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return String(decoding: raw, as: UTF8.self)
    }

    @Test("GET /state/subscribe over TCP is 403, with or without X-Bromure-State-Delta")
    func refused() async throws {
        var lastError: Error?
        for _ in 0..<5 {
            let port = UInt16.random(in: 40_000...60_000)
            let server = ACAutomationServer(port: port)
            server.onListVMs = { [["id": "vm-secret", "cpu": 1.0]] }
            server.start()
            defer { server.stop() }
            try await Task.sleep(for: .milliseconds(200))
            do {
                let delta = try Self.request(port: port, "/state/subscribe", headers: "X-Bromure-State-Delta: 1\r\n")
                let whole = try Self.request(port: port, "/state/subscribe", headers: "")
                let lower = try Self.request(port: port, "/state/subscribe", headers: "x-bromure-state-delta: 1\r\n")
                for r in [delta, whole, lower] {
                    #expect(r.hasPrefix("HTTP/1.1 403"), "\(r.prefix(80))")
                    #expect(!r.contains("vm-secret"))
                }
                return
            } catch { lastError = error }   // port taken: try another
        }
        throw try #require(lastError)
    }

    @Test("a TCP request stamped as a fat client's poll doesn't count as one")
    func noFatClientClaim() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let server = ACAutomationServer(port: port)
        server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        // Another suite records a contact of its own now and then: one clean
        // pass is enough, and the bug fails every one.
        var claimed = true
        for _ in 0..<3 where claimed {
            PendingPromptBroker.resetFatClientContact()
            let r = try Self.request(port: port, "/state", headers: "X-Bromure-Console-Idle-Ms: 0\r\n")
            #expect(r.hasPrefix("HTTP/1.1 403"))
            claimed = PendingPromptBroker.hasLiveListener()
        }
        PendingPromptBroker.resetFatClientContact()
        #expect(!claimed)
    }
}
