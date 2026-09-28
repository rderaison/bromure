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
}
