import Foundation
import os
import Testing
@testable import bromure_ac

@Suite("Attached machines (Bromure Agent Host)")
struct MachineLinkTests {
    @Test("machine-link and machine-detach verbs parse, and nothing else does")
    func verbs() {
        let id = UUID()
        let name = Data("Renaud’s Mac".utf8).base64EncodedString()
        let link = FatClient.parseMachineLink("\(FatClient.machineLinkVerbPrefix)\(id.uuidString) \(name)")
        #expect(link?.id == id)
        #expect(link?.name == "Renaud’s Mac")
        #expect(FatClient.parseMachineLink("\(FatClient.machineLinkVerbPrefix)not-a-uuid \(name)") == nil)
        #expect(FatClient.parseMachineLink("\(FatClient.machineLinkVerbPrefix)\(id.uuidString)") == nil)
        #expect(FatClient.parseMachineLink(FatClient.controlVerb) == nil)
        #expect(FatClient.parseMachineDetach("\(FatClient.machineDetachVerbPrefix)\(id.uuidString)") == id)
        #expect(FatClient.parseMachineDetach(FatClient.controlVerb) == nil)
    }

    @Test("an agent-host key is tagged machine-only; any other account key isn't")
    func keyTags() throws {
        func key(_ capability: String?) throws -> ControlPlaneClient.DeviceSSHKey {
            var json: [String: Any] = ["id": "dev1", "sshPublicKey": "ssh-ed25519 AAAA"]
            if let capability { json["capability"] = capability }
            return try JSONDecoder().decode(ControlPlaneClient.DeviceSSHKey.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try key("agent-host").authorizedKeysComment == "\(RemoteAccessServer.machineKeyMarker)dev1")
        #expect(try key("server").authorizedKeysComment == "bromure-account:dev1")
        #expect(try key(nil).authorizedKeysComment == "bromure-account:dev1")
        // Still under the account marker, so the key sync manages (and prunes) it.
        #expect(RemoteAccessServer.machineKeyMarker.hasPrefix("bromure-account:"))
    }

    @Test("a machine is bound to the device that attached it")
    func ownership() {
        let hub = MachineLinkHub.shared
        let id = UUID()
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[1]) }
        #expect(hub.park(fd: fds[0], id: id, name: "A", owner: "device:one"))
        #expect(!hub.mayPark(id: id, owner: "device:two"))
        #expect(hub.mayPark(id: id, owner: "device:one"))
        #expect(hub.mayPark(id: id, owner: nil))            // this Mac's own socket
        #expect(!hub.detach(id: id, owner: "device:two"))
        #expect(hub.detach(id: id, owner: "device:one"))
        #expect(hub.name(id) == nil)
    }

    @Test("branch calls reach the machine whose session or workspace they name")
    func branchRouting() {
        let hub = MachineLinkHub.shared
        let id = UUID(), sid = UUID()
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[1]); _ = hub.detach(id: id, owner: nil) }
        #expect(hub.park(fd: fds[0], id: id, name: "M", owner: nil))
        hub.setFragment(id, .init(workspace: [:], vm: [:], sessions: [],
                                  sessionIDs: [sid.uuidString.uppercased()], connected: true))
        #expect(hub.target(method: "POST", path: "/agent-sessions/git-state", body: ["id": sid.uuidString.lowercased()]) == id)
        #expect(hub.target(method: "POST", path: "/agent-sessions/git-state", body: ["id": UUID().uuidString]) == nil)
        #expect(hub.target(method: "POST", path: "/agent-sessions/\(sid.uuidString)/worktree", body: [:]) == id)
        #expect(hub.target(method: "POST", path: "/agent-sessions/worktree-open", body: ["profile": id.uuidString]) == id)
        #expect(hub.target(method: "POST", path: "/agent-sessions/worktree-discard", body: ["profile": id.uuidString]) == id)
        #expect(hub.target(method: "POST", path: "/agent-sessions/worktree-open", body: ["profile": UUID().uuidString]) == nil)
    }

    /// A machine end that answers and then never closes (an SSH link whose
    /// close doesn't arrive): the reply must still come through at once.
    private static func silentMachine(reply: String) -> (fd: Int32, keepOpen: Int32) {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        let far = fds[1]
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(far, &buf, buf.count)                 // the request
            _ = reply.withCString { write(far, $0, strlen($0)) }
        }
        return (fds[0], far)
    }

    @Test("a proxied reply ends at its Content-Length, not at the machine's close")
    func relayStopsAtLength() throws {
        let body = #"{"folders":["a","b"]}"#
        let m = Self.silentMachine(reply: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        defer { close(m.keepOpen) }
        var c: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &c)
        defer { close(c[1]) }
        _ = "GET / HTTP/1.1\r\n\r\n".withCString { write(m.fd, $0, strlen($0)) }
        let t0 = Date()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { MachineLinkHub.relay(c[0], m.fd); done.signal() }
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(Date().timeIntervalSince(t0) < 2)
        var buf = [UInt8](repeating: 0, count: 4096)
        var got = Data()
        while true { let n = read(c[1], &buf, buf.count); if n <= 0 { break }; got.append(contentsOf: buf[0..<n]) }
        #expect(String(decoding: got, as: UTF8.self).hasSuffix(body))
        close(c[0]); close(m.fd)
    }

    @Test("the control client returns a complete reply without waiting for the close")
    func clientStopsAtLength() throws {
        let body = #"{"ok":true}"#
        let m = Self.silentMachine(reply: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        defer { close(m.keepOpen) }
        let client = ControlClient(socketPath: "/nonexistent", dial: { m.fd })
        let t0 = Date()
        let r = try client.request("GET", "/x", recvTimeoutSeconds: 10)
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(r.status == 200)
        #expect(r.json["ok"] as? Bool == true)
    }

    @Test("a proxied call whose machine never answers gives up at the head deadline")
    func relayHeadDeadline() throws {
        // A dead end over a relayed path: the link stays open, nothing comes.
        var m: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &m)
        defer { close(m[0]); close(m[1]) }
        var c: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &c)
        defer { close(c[0]); close(c[1]) }
        let t0 = Date()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { MachineLinkHub.relay(c[0], m[0], headWithin: 0.5); done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(Date().timeIntervalSince(t0) < 3)
        // The caller hears the end, not silence.
        var b: UInt8 = 0
        #expect(read(c[1], &b, 1) == 0)
    }

    @Test("once the head is in, a quiet stream outlives the head deadline")
    func relayStreamAfterHead() throws {
        var m: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &m)
        defer { close(m[0]) }
        let far = m[1]
        Thread.detachNewThread {
            // A terminal: the head at once, output after a pause, then the end.
            _ = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".withCString { write(far, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: 1.2)
            _ = "late output".withCString { write(far, $0, strlen($0)) }
            close(far)
        }
        var c: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &c)
        defer { close(c[1]) }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { MachineLinkHub.relay(c[0], m[0], headWithin: 0.4); done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)
        var buf = [UInt8](repeating: 0, count: 4096)
        var got = Data()
        while true { let n = read(c[1], &buf, buf.count); if n <= 0 { break }; got.append(contentsOf: buf[0..<n]) }
        #expect(String(decoding: got, as: UTF8.self).hasSuffix("late output"))
        close(c[0])
    }

    @Test("the delegation relay drops a slot nobody takes and dials a fresh one")
    func relayRedialsSilentSlot() async throws {
        // Each dial: a link whose far end never writes and never closes —
        // a Sidecar that restarted behind a relayed path.
        let farEnds = OSAllocatedUnfairLock(initialState: [Int32]())
        let relay = DelegationRelayClient(dial: {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
            farEnds.withLock { $0.append(fds[1]) }
            return fds[0]
        }, label: "test", parkedFor: 0.3, makeServer: { nil })
        relay.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        relay.stop()
        let ends = farEnds.withLock { $0 }
        #expect(ends.count >= 3)
        // Every slot but the last was given up: its far end sees the close.
        for fd in ends.dropLast() {
            var b: UInt8 = 0
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            #expect(poll(&p, 1, 1000) == 1)
            #expect(read(fd, &b, 1) == 0)
        }
        ends.forEach { close($0) }
    }

    @Test("a hello within the deadline is read, with what followed it")
    func relayHelloInTime() {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        _ = "bromure-hello w3\n{\"id\":1}\n".withCString { write(fds[1], $0, strlen($0)) }
        guard case .line(let hello, let rest) = DelegationRelayClient.readLine(fds[0], within: 1) else {
            Issue.record("no hello"); return
        }
        #expect(hello == "w3")
        #expect(String(decoding: rest, as: UTF8.self) == "{\"id\":1}\n")
        #expect(DelegationRelayClient.readLine(fds[0], within: 0.2) == .expired)
    }

    @Test("a link the machine closed while it waited is skipped, not handed a request")
    func openSkipsClosedLinks() {
        let hub = MachineLinkHub.shared
        let id = UUID()
        let (live, liveFar) = Self.link()
        let (dead, deadFar) = Self.link()
        let (half, halfFar) = Self.link()
        defer { close(liveFar); close(halfFar); hub.detach(id: id, owner: nil) }
        #expect(hub.park(fd: live, id: id, name: "M", owner: nil))
        #expect(hub.park(fd: dead, id: id, name: "M", owner: nil))
        #expect(hub.park(fd: half, id: id, name: "M", owner: nil))
        close(deadFar)                      // gone
        shutdown(halfFar, SHUT_WR)          // its EOF sent, the fd still open
        // Newest first: the half-closed one and the closed one are passed over.
        let fd = hub.open(id, verb: "control", timeout: 1)
        #expect(fd == live)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(liveFar, &buf, buf.count)
        #expect(String(decoding: buf[0..<max(0, n)], as: UTF8.self) == "control\n")
        if let fd { close(fd) }
    }

    private static func link() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return (fds[0], fds[1])
    }

    @Test("a machine may not take the id of a workspace or VM here")
    func reservedIDs() {
        let hub = MachineLinkHub.shared
        let id = UUID()
        let (a, b) = Self.link()
        defer { close(a); close(b) }
        #expect(hub.admit(id: id, owner: "device:x", reserved: [id]) == .refused("That id belongs to a workspace on this host"))
        #expect(!hub.park(fd: a, id: id, name: "M", owner: nil, reserved: [id]))
        #expect(hub.name(id) == nil)
    }

    @Test("an agent host's machine waits for the user; allowed it joins, blocked it stays out")
    func admission() {
        let hub = MachineLinkHub.shared
        let id = UUID(), sid = UUID()
        let (a, b) = Self.link()
        defer { close(b); hub.forget(id: id); _ = hub.detach(id: id, owner: nil) }
        #expect(hub.admit(id: id, owner: "device:one", reserved: []) == .pending)
        #expect(hub.park(fd: a, id: id, name: "Waiting Mac", owner: "device:one"))
        // Waiting: listed for the dialog, but nothing routes to it.
        #expect(hub.name(id) == nil)
        #expect(hub.admissionState().pending.contains { $0["id"] as? String == id.uuidString })
        hub.setFragment(id, .init(workspace: [:], vm: [:], sessions: [], sessionIDs: [sid.uuidString], connected: true))
        #expect(hub.target(method: "POST", path: "/vms/\(id.uuidString)/exec", body: [:]) == nil)
        // Another device can't answer for it by parking under its id.
        #expect(hub.admit(id: id, owner: "device:two", reserved: []) != .pending)
        // Allowed: its parked link goes live.
        #expect(hub.decide(id: id, allow: true))
        #expect(hub.name(id) == "Waiting Mac")
        #expect(hub.target(method: "POST", path: "/vms/\(id.uuidString)/exec", body: [:]) == id)
        #expect(hub.admit(id: id, owner: "device:one", reserved: []) == .allowed)
        // Blocked: dropped, and refused from now on — its own device too.
        #expect(hub.decide(id: id, allow: false))
        #expect(hub.name(id) == nil)
        if case .refused = hub.admit(id: id, owner: "device:one", reserved: []) {} else { Issue.record("not refused") }
        #expect(hub.admissionState().blocked.contains { $0["id"] as? String == id.uuidString })
        // Unblocked: it asks again.
        hub.forget(id: id)
        #expect(hub.admit(id: id, owner: "device:one", reserved: []) == .pending)
    }

    @Test("answers and owners survive a restart")
    func persistence() throws {
        let hub = MachineLinkHub.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url); hub.storeURL = nil }
        hub.storeURL = url
        let id = UUID()
        let (a, b) = Self.link()
        defer { close(b) }
        #expect(hub.park(fd: a, id: id, name: "M", owner: "device:one"))
        #expect(hub.decide(id: id, allow: true))
        _ = hub.detach(id: id, owner: "device:one")
        hub.storeURL = url          // as a relaunch reads it
        #expect(hub.admit(id: id, owner: "device:one", reserved: []) == .allowed)
        if case .refused = hub.admit(id: id, owner: "device:two", reserved: []) {} else { Issue.record("owner not kept") }
        hub.forget(id: id)
    }

    @Test("a machine's sessions are its own: no one else's id, no other workspace")
    func ownSessions() {
        let machine = UUID(), vmWorkspace = UUID(), vmSession = UUID(), mine = UUID()
        let listed: [[String: Any]] = [
            ["id": vmSession.uuidString, "profileID": vmWorkspace.uuidString, "title": "stolen"],
            ["id": mine.uuidString.lowercased(), "profileID": vmWorkspace.uuidString, "title": "mine"],
            ["id": mine.uuidString, "profileID": machine.uuidString, "title": "twin"],
            ["title": "no id"],
        ]
        let kept = AttachedMachine.ownSessions(listed, machine: machine, foreign: [vmSession])
        #expect(kept.count == 1)
        #expect(kept.first?["id"] as? String == mine.uuidString)
        #expect(kept.first?["profileID"] as? String == machine.uuidString)
    }

    @Test("a machine session's room is the host's to say; it can't seat itself or run a Switchboard")
    func machineRooms() {
        let machine = UUID(), mine = UUID(), other = UUID(), room = UUID(), claimed = UUID()
        let listed: [[String: Any]] = [
            ["id": mine.uuidString, "roomID": claimed.uuidString],
            ["id": other.uuidString, "roomID": claimed.uuidString, "role": AgentSession.switchboardRole],
        ]
        let kept = AttachedMachine.ownSessions(listed, machine: machine, foreign: [],
                                               roomOf: { $0 == mine ? room : nil })
        #expect(kept.first { $0["id"] as? String == mine.uuidString }?["roomID"] as? String == room.uuidString)
        let o = kept.first { $0["id"] as? String == other.uuidString }
        #expect(o?["roomID"] == nil)
        #expect(o?["role"] == nil)
    }

    @Test("delegation results name a native Mac's inbox files under its real home")
    func inboxOnNativeHome() throws {
        let plain = "Files landed: /home/ubuntu/.bromure/inbox/ab12/report.pdf"
        #expect(DelegationMCPServer.mapGuestHome(plain, to: "/Users/someone")
                == "Files landed: /Users/someone/.bromure/inbox/ab12/report.pdf")
        // As JSONSerialization writes it (slashes escaped), home with a trailing slash.
        let data = try JSONSerialization.data(withJSONObject: ["files": ["/home/ubuntu/.bromure/inbox/ab12/a.png"]])
        let json = String(decoding: data, as: UTF8.self)
        let mapped = DelegationMCPServer.mapGuestHome(json, to: "/Users/someone/")
        let back = try JSONSerialization.jsonObject(with: Data(mapped.utf8)) as? [String: [String]]
        #expect(back?["files"] == ["/Users/someone/.bromure/inbox/ab12/a.png"])
        // Nothing else is touched.
        #expect(DelegationMCPServer.mapGuestHome("/home/ubuntuX/a /tmp/b", to: "/Users/x") == "/home/ubuntuX/a /tmp/b")
    }

    @Test("review comments a native Mac keeps decode as this app's")
    func nativeReviewComments() throws {
        // As Bromure Sidecar writes them in /state (iso8601, whole seconds).
        let json = #"[{"createdAt":"2026-09-30T13:18:19Z","file":"a.txt","id":"9BE7B9DF-2BCF-4D43-88D5-03DB88768843","line":2,"text":"Rename this file","sentAt":"2026-09-30T13:19:00Z"},{"createdAt":"2026-09-30T13:18:20Z","id":"B0931836-17D0-48AE-BECF-59C02662FB8A","text":"Add a README"}]"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let comments = try dec.decode([ReviewComment].self, from: Data(json.utf8))
        #expect(comments.count == 2)
        #expect(comments[0].file == "a.txt" && comments[0].line == 2 && comments[0].sentAt != nil)
        #expect(comments[1].file == nil && comments[1].sentAt == nil)
    }
}
