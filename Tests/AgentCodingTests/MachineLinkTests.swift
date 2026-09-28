import Foundation
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
}
