import Foundation
import Testing
@testable import ACLinux

// The server's sign-out revoke (Daemon.revokeForSignOut, the port of
// P2PEnrollmentCoordinator.revokeForSignOut): the identity may only be
// forgotten here when this says the revoke is done, or the user was told
// bromure.io refuses the credentials. macOS's twin:
// Tests/AgentCodingTests/SignOutRevokeTests.swift (CWE-613).
@Suite("Sign-out revoke")
struct SignOutRevokeLinuxTests {
    @Test("A confirmed revoke is done")
    func confirmed() async {
        var calls = 0
        let outcome = await Daemon.revokeForSignOut(final: true) { calls += 1 }
        #expect(outcome == .done)
        #expect(calls == 1)
    }

    // bromure.io answers the same 401 for a revoked device and for a token
    // that merely expired, with the device still live: `.refused`, not done.
    @Test("A 401 for a credential whose refusal is final is refused, not a confirmed revoke")
    func finalRefusalIsNotRevoked() async {
        var calls = 0
        let outcome = await Daemon.revokeForSignOut(final: true) {
            calls += 1
            throw ControlPlaneError.http(status: 401, code: "unauthorized")
        }
        #expect(outcome == .refused)
        #expect(calls == 1)
    }

    // A 401 right after enrollment can be propagation lag, not a revocation.
    @Test("A 401 for a credential never accepted is retried, then keeps the identity")
    func unconfirmed401() async {
        var calls = 0
        let outcome = await Daemon.revokeForSignOut(final: false, retries: 3, retryDelay: 0) {
            calls += 1
            throw ControlPlaneError.http(status: 401, code: "unauthorized")
        }
        #expect(calls == 4)
        guard case .failed(let failure) = outcome else { Issue.record("\(outcome)"); return }
        #expect(failure.contains("may still be registered"))
    }

    @Test("A 401 that clears once the credential propagates is done")
    func propagationLag() async {
        var calls = 0
        let outcome = await Daemon.revokeForSignOut(final: false, retries: 3, retryDelay: 0) {
            calls += 1
            if calls < 3 { throw ControlPlaneError.http(status: 401, code: nil) }
        }
        #expect(outcome == .done)
        #expect(calls == 3)
    }

    @Test("Any other failure keeps the identity and says why",
          arguments: [ControlPlaneError.transport("The Internet connection appears to be offline."),
                      .http(status: 500, code: nil),
                      .http(status: 403, code: "forbidden"),
                      .decode])
    func failed(_ e: ControlPlaneError) async {
        let outcome = await Daemon.revokeForSignOut(final: true) { throw e }
        guard case .failed(let failure) = outcome else { Issue.record("\(outcome)"); return }
        #expect(failure.contains("still registered"))
    }

    @Test("An unrelated error is a failure too")
    func otherError() async {
        struct Boom: Error {}
        let outcome = await Daemon.revokeForSignOut(final: true) { throw Boom() }
        guard case .failed = outcome else { Issue.record("\(outcome)"); return }
    }

    // The shared half, on swift-corelibs' UserDefaults and swift-crypto.
    @Test("A credential counts as accepted once a call with it succeeded, and only that one")
    func acceptedMark() throws {
        let d = try #require(UserDefaults(suiteName: "SignOutRevokeLinuxTests-\(UUID().uuidString)"))
        #expect(!AcceptedCredential.wasAccepted("tok-a", defaults: d))
        AcceptedCredential.note("tok-a", defaults: d)
        #expect(AcceptedCredential.wasAccepted("tok-a", defaults: d))
        #expect(!AcceptedCredential.wasAccepted("tok-b", defaults: d))
        #expect(d.string(forKey: AcceptedCredential.defaultsKey)?.contains("tok-a") == false)
        #expect(d.string(forKey: AcceptedCredential.defaultsKey)?.count == 64, "a SHA-256, in hex")
        AcceptedCredential.forget(defaults: d)
        #expect(!AcceptedCredential.wasAccepted("tok-a", defaults: d))
    }

    @Test("A 401 is final once accepted, expired, past propagation, or for a record from before enrolledAt")
    func refusalIsFinal() throws {
        let d = try #require(UserDefaults(suiteName: "SignOutRevokeLinuxTests-final-\(UUID().uuidString)"))
        let now = Date()
        func rec(enrolled: Date?, expires: Date? = nil, token: String = "tok") -> DeviceRecord {
            DeviceRecord(privateKeyHex: "", deviceToken: token, deviceTokenExpiresAt: expires, deviceId: "d",
                         capability: "server", orgSlug: nil, orgKind: nil, apiBase: "https://x", enrolledAt: enrolled)
        }
        #expect(!AcceptedCredential.refusalIsFinal(bearer: "tok", record: rec(enrolled: now.addingTimeInterval(-30)), now: now, defaults: d))
        #expect(AcceptedCredential.refusalIsFinal(bearer: "tok", record: rec(enrolled: nil), now: now, defaults: d))
        #expect(AcceptedCredential.refusalIsFinal(bearer: "tok", record: rec(enrolled: now.addingTimeInterval(-3600)), now: now, defaults: d))
        #expect(AcceptedCredential.refusalIsFinal(bearer: "tok",
            record: rec(enrolled: now.addingTimeInterval(-30), expires: now.addingTimeInterval(-1)), now: now, defaults: d))
        AcceptedCredential.note("tok", defaults: d)
        #expect(AcceptedCredential.refusalIsFinal(bearer: "tok", record: rec(enrolled: now), now: now, defaults: d))
        #expect(!AcceptedCredential.refusalIsFinal(bearer: "other", record: rec(enrolled: nil), now: now, defaults: d))
    }

    @Test("A record saved before enrolledAt decodes with none; one saved now keeps it")
    func recordRoundTrip() throws {
        let json = #"{"privateKeyHex":"","deviceToken":"t","deviceId":"d","capability":"server","apiBase":"https://x"}"#
        let r = try JSONDecoder().decode(DeviceRecord.self, from: Data(json.utf8))
        #expect(r.enrolledAt == nil)
        var now = r
        now.enrolledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let back = try JSONDecoder().decode(DeviceRecord.self, from: JSONEncoder().encode(now))
        #expect(back.enrolledAt == now.enrolledAt)
    }

    /// The daemon's claim on the one sign-out, and what it remembers about a
    /// refusal (macOS: `busy`, `refusalShownFor`).
    @MainActor
    @Test("One sign-out at a time; a refusal explained lets the next one forget the identity")
    func claim() throws {
        let keys = LinuxAccountKeys.shared
        defer { keys.forgetRefusal(); keys.endSignOut() }
        keys.forgetRefusal(); keys.endSignOut()
        // Not explained yet.
        #expect(try #require(keys.beginSignOut(bearer: "tok-1")) == false)
        // A second one while it's under way is refused.
        #expect(keys.beginSignOut(bearer: "tok-1") == nil)
        // The refusal is explained while the first is in flight: that
        // sign-out's own answer was fixed when it began (CWE-362).
        keys.noteCredentialRefused(bearer: "tok-1")
        keys.endSignOut()
        // The next one knows.
        #expect(try #require(keys.beginSignOut(bearer: "tok-1")) == true)
        keys.endSignOut()
        // Only for that credential.
        #expect(try #require(keys.beginSignOut(bearer: "tok-2")) == false)
        keys.endSignOut()
        // What `account status` shows comes with a problem only.
        #expect(keys.credentialProblem == nil)
        keys.noteCredentialRefused(bearer: "tok-1", problem: "refused")
        #expect(keys.credentialProblem == "refused")
        keys.forgetRefusal()
        #expect(keys.credentialProblem == nil)
        #expect(try #require(keys.beginSignOut(bearer: "tok-1")) == false)
    }
}
