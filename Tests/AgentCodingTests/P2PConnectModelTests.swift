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
                   revoked: false, online: online, lastSeenAt: nil, isSelf: false,
                   sshUsername: nil)
    }

    @Test("a directory server maps to a .peer RemoteHost carrying the device id")
    func peerHost() {
        let host = RemoteConnectModel.peerHost(for: device(id: "server-device-123"))
        #expect(host.peerDeviceID == "server-device-123")
        #expect(host.isPeer == true)
        if case .peer(let id) = host.kind { #expect(id == "server-device-123") }
        else { Issue.record("expected .peer kind") }
    }

    /// Finding: "Reconnecting to a peer duplicates its security timeline
    /// history". A peer got a fresh id at every connect (peers aren't
    /// saved): the same machine's rows went to a new timeline bucket beside
    /// the old one, counted twice. Its id is now derived from its device id.
    @Test("a peer is the same host at every connect: one id, one timeline bucket")
    func peerIDStableAcrossConnects() {
        let first = RemoteConnectModel.peerHost(for: device(id: "server-device-123"))
        let again = RemoteConnectModel.peerHost(for: device(id: "server-device-123"))
        let other = RemoteConnectModel.peerHost(for: device(id: "server-device-456"))
        #expect(first.id == again.id)
        #expect(first.id != other.id)
        #expect(first.id == RemoteHost.stablePeerID("server-device-123"))
        // Reconnected, its rows replace its own bucket: never a second one.
        let tl = SecurityTimeline(directory: nil)
        let row: [String: Any] = ["engine": "Firewall", "condition": "c", "decision": "d", "kind": "blocked",
                                  "t": Date().timeIntervalSince1970, "profileID": UUID().uuidString]
        for host in [first, again] {
            let key = host.id.uuidString            // `securityMirrorKey`
            tl.noteMachine(key, host: host)
            tl.applyHistory([row, row], host: key)
            tl.applyMirror([row], host: key)
        }
        #expect(tl.remote.count == 1)
    }

    @Test("a peer that can't be resolved fails in the connect window, bounded")
    func peerResolveFailure() async throws {
        var captured: RemoteHost?
        let model = RemoteConnectModel { captured = $0 }
        model.peerResolver = { _ in nil }   // broker says: no path
        model.connect(toPeer: device(id: "unreachable-peer"))
        // The pipeline hops work-queue → main; suspending lets both drain.
        var polls = 0
        while polls < 100 {
            if case .unreachable = model.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            polls += 1
        }
        guard case .unreachable(let msg) = model.phase else {
            Issue.record("expected .unreachable, got \(model.phase)")
            return
        }
        #expect(msg.contains("Studio Mac"))
        // The mirror window never opened, and no peer host leaked into the
        // by-address recents list.
        #expect(captured == nil)
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
