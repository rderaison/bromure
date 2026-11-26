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
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: true) { calls += 1 }
        #expect(failure == nil)
        #expect(calls == 1)
    }

    @Test("A 401 for a credential bromure.io accepted before is done: it's revoked")
    func alreadyRevoked() async {
        var calls = 0
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: true) {
            calls += 1
            throw ControlPlaneError.http(status: 401, code: "unauthorized")
        }
        #expect(failure == nil)
        #expect(calls == 1)
    }

    // Regression (CWE-613): a 401 right after enrollment can be propagation
    // lag, not a revocation. Treating it as done erased the only bearer that
    // could still revoke a live device.
    @Test("A 401 for a credential never accepted is retried, then keeps the identity")
    func unconfirmed401() async {
        var calls = 0
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: false, retries: 3, retryDelay: 0) {
            calls += 1
            throw ControlPlaneError.http(status: 401, code: "unauthorized")
        }
        #expect(calls == 4)
        #expect(failure != nil)
        #expect(failure?.contains("may still be registered") == true)
    }

    @Test("A 401 that clears once the credential propagates is done")
    func propagationLag() async {
        var calls = 0
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: false, retries: 3, retryDelay: 0) {
            calls += 1
            if calls < 3 { throw ControlPlaneError.http(status: 401, code: nil) }
        }
        #expect(failure == nil)
        #expect(calls == 3)
    }

    @Test("A credential counts as accepted once a call with it succeeded, and only that one")
    func acceptedMark() throws {
        let d = try #require(UserDefaults(suiteName: "SignOutRevokeTests-\(UUID().uuidString)"))
        #expect(!AcceptedCredential.wasAccepted("tok-a", defaults: d))
        AcceptedCredential.note("tok-a", defaults: d)
        #expect(AcceptedCredential.wasAccepted("tok-a", defaults: d))
        #expect(!AcceptedCredential.wasAccepted("tok-b", defaults: d))
        #expect(d.string(forKey: AcceptedCredential.defaultsKey)?.contains("tok-a") == false)
        AcceptedCredential.forget(defaults: d)
        #expect(!AcceptedCredential.wasAccepted("tok-a", defaults: d))
    }

    @Test("Any other failure keeps the identity and says why",
          arguments: [ControlPlaneError.transport("The Internet connection appears to be offline."),
                      .http(status: 500, code: nil),
                      .http(status: 403, code: "forbidden"),
                      .decode])
    func failed(_ e: ControlPlaneError) async {
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: true) { throw e }
        #expect(failure != nil)
        #expect(failure?.contains("still registered") == true)
    }

    @Test("An unrelated error is a failure too")
    func otherError() async {
        struct Boom: Error {}
        let failure = await P2PEnrollmentCoordinator.revokeForSignOut(accepted: true) { throw Boom() }
        #expect(failure != nil)
    }
}
