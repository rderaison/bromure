import Foundation
import Testing
@testable import bromure_ac

/// The Guardrails pane's grant badges and right-click actions: what the
/// broker reports for one workspace, a re-grant restarting the clock, and
/// revoke making the next use ask again.
@Suite("Guardrails grant controls")
struct ConsentGrantControlsTests {

    @Test("Allow for 5 minutes runs from now and shows as a timed grant")
    func allowFiveMinutes() async {
        let broker = ConsentBroker()
        let profile = UUID()
        let controls = ACAppDelegate.consentGrantControls(broker, profileID: profile)
        await controls.allow("aws", "AWS", 5)

        let status = await controls.status()
        let grant = try! #require(status["aws"])
        #expect(!grant.denied && !grant.sessionScoped)
        #expect(abs(grant.expiration.timeIntervalSinceNow - 300) < 5)
        // A live grant means the gated call proceeds without a prompt.
        #expect(await broker.consent(profileID: profile, credentialID: "aws",
                                     credentialDisplayName: "AWS", scopeHint: ""))
    }

    @Test("Re-granting restarts the clock instead of adding to it")
    func regrantResets() async {
        let broker = ConsentBroker()
        let profile = UUID()
        let controls = ACAppDelegate.consentGrantControls(broker, profileID: profile)
        await controls.allow("ssh:x", "key", 60)
        await controls.allow("ssh:x", "key", 5)
        let left = try! #require(await controls.status()["ssh:x"]).expiration.timeIntervalSinceNow
        #expect(abs(left - 300) < 5)
    }

    @Test("Rest of session, then revoke clears it")
    func sessionThenRevoke() async {
        let broker = ConsentBroker()
        let profile = UUID()
        let controls = ACAppDelegate.consentGrantControls(broker, profileID: profile)
        await controls.allow("linear-key", "Linear", nil)
        #expect(await controls.status()["linear-key"]?.sessionScoped == true)
        await controls.revoke("linear-key")
        #expect(await controls.status().isEmpty)
    }

    @Test("Only this workspace's grants are reported")
    func scopedToWorkspace() async {
        let broker = ConsentBroker()
        let mine = UUID(), other = UUID()
        await ACAppDelegate.consentGrantControls(broker, profileID: other).allow("aws", "AWS", 5)
        #expect(await ACAppDelegate.consentGrantControls(broker, profileID: mine).status().isEmpty)
    }

    @Test("A Guardrails row maps to the id its gated call site consents under")
    func rowIDsMatchCallSites() {
        let p = Profile(name: "t", tool: .claude, authMode: .token)
        let u = UUID()
        #expect(p.consentCredentialID(.primaryToolKey) == ConsentCredentialID.primaryToolAPIKey(tool: "claude"))
        #expect(p.consentCredentialID(.importedSSHKey(u)) == ConsentCredentialID.sshKey(u.uuidString))
        #expect(p.consentCredentialID(.managedSSHKey) == ConsentCredentialID.bromureSSHKey())
        #expect(p.consentCredentialID(.git(u)) == ConsentCredentialID.gitHTTPS(u))
        #expect(p.consentCredentialID(.kube(u)) == ConsentCredentialID.kubeconfig(u))
        #expect(p.consentCredentialID(.aws) == "aws")
    }
}

@Suite("Guardrails deny controls")
struct ConsentDenyControlsTests {

    @Test("Deny for 5 minutes replaces a grant and refuses without a prompt")
    func denyReplacesGrant() async {
        let broker = ConsentBroker()
        let profile = UUID()
        let controls = ACAppDelegate.consentGrantControls(broker, profileID: profile)
        await controls.allow("aws", "AWS", 60)
        await controls.deny("aws", "AWS", 5)

        let status = try! #require(await controls.status()["aws"])
        #expect(status.denied && !status.sessionScoped)
        #expect(abs(status.expiration.timeIntervalSinceNow - 300) < 5)
        #expect(await broker.consent(profileID: profile, credentialID: "aws",
                                     credentialDisplayName: "AWS", scopeHint: "") == false)
    }

    @Test("Deny for the session lasts until the session ends; allow replaces it")
    func sessionDeny() async {
        let broker = ConsentBroker()
        let profile = UUID()
        let controls = ACAppDelegate.consentGrantControls(broker, profileID: profile)
        await controls.deny("ssh:x", "key", nil)
        let status = try! #require(await controls.status()["ssh:x"])
        #expect(status.denied && status.sessionScoped)
        #expect(status.expiration == .distantFuture)

        await controls.allow("ssh:x", "key", 5)
        #expect(await controls.status()["ssh:x"]?.denied == false)

        await controls.deny("ssh:x", "key", nil)
        await broker.revokeAll(profileID: profile)   // session teardown
        #expect(await controls.status().isEmpty)
    }
}
