import Foundation
import Testing
@testable import bromure_ac

// The merged connect window's model — the parts that don't need a live control
// plane or the keychain: building a peer host, and the security guard that
// stops an unsolicited bromure://enroll link from enrolling this Mac.

@Suite("Merged connect model")
@MainActor
struct P2PConnectModelTests {

    private func device(id: String, online: Bool = true) -> DeviceInfo {
        DeviceInfo(id: id, name: "Studio Mac", capability: "server",
                   revoked: false, online: online, lastSeenAt: nil, isSelf: false)
    }

    @Test("connecting to a peer builds a .peer RemoteHost carrying the device id")
    func peerHost() {
        var captured: RemoteHost?
        let model = RemoteConnectModel { captured = $0 }
        model.connect(toPeer: device(id: "server-device-123"))
        let host = try? #require(captured)
        #expect(host?.peerDeviceID == "server-device-123")
        #expect(host?.isPeer == true)
        if case .peer(let id)? = host?.kind { #expect(id == "server-device-123") }
        else { Issue.record("expected .peer kind") }
        // Peer hosts don't leak into the by-address recents list.
        #expect(RemoteHostStore.shared.hosts.allSatisfy { $0.peerDeviceID == nil })
    }

    @Test("an unsolicited enroll callback (no pending sign-in) is ignored")
    func enrollGuard() {
        // A fresh coordinator has no in-flight sign-in, so a callback carrying
        // any state must be dropped without kicking off enrollment.
        let coord = P2PEnrollmentCoordinator()
        let link = EnrollLink(code: "abcd1234abcd1234", apiBase: "https://bromure.io/api")
        coord.complete(link, state: "attacker-supplied-state")
        #expect(coord.busy == false)
    }
}
