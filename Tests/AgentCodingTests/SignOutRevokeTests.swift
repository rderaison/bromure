import Testing
import Foundation
@testable import bromure_ac

// Regression (CWE-613): sign-out fire-and-forgot the device self-revoke (or
// swallowed its error), then erased the local identity, so a failed revoke
// left the device's token and SSH key live on bromure.io with nothing left to
// retry it with. The identity may only be erased when this says the revoke is
// done.
@Suite("Sign-out revoke")
struct SignOutRevokeTests {
    @Test("A confirmed revoke is done")
    func confirmed() async {
        var calls = 0
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut { calls += 1 }
        #expect(failure == nil)
        #expect(calls == 1)
    }

    @Test("A 401 is done: the credential is already revoked or dead")
    func alreadyRevoked() async {
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut {
            throw ControlPlaneError.http(status: 401, code: "unauthorized")
        }
        #expect(failure == nil)
    }

    @Test("Any other failure keeps the identity and says why",
          arguments: [ControlPlaneError.transport("The Internet connection appears to be offline."),
                      .http(status: 500, code: nil),
                      .http(status: 403, code: "forbidden"),
                      .decode])
    func failed(_ e: ControlPlaneError) async {
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut { throw e }
        #expect(failure != nil)
        #expect(failure?.contains("still registered") == true)
    }

    @Test("An unrelated error is a failure too")
    func otherError() async {
        struct Boom: Error {}
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut { throw Boom() }
        #expect(failure != nil)
    }
}
