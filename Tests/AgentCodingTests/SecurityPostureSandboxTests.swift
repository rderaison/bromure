import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

/// Finding (CWE-451): "Security Overview marks Sandbox on for a network-only
/// OpenShell policy". The Protections grid's Sandbox column was lit by any
/// OpenShell document — its default deny is the Firewall, not confinement —
/// while the policy editor said "Not confined".
@Suite("Security Overview: Sandbox means the guest is confined")
@MainActor
struct SecurityPostureSandboxTests {
    private func profile(_ yaml: String) -> bromure_ac.Profile {
        var p = bromure_ac.Profile(name: "ws", tool: .claude, authMode: .token)
        p.networkPolicy = yaml
        return p
    }

    private func reported(_ filesystem: String) -> GuestSandboxStatusStore.Status {
        GuestSandboxStatusStore.Status(filesystem: filesystem, additionsReadWrite: [], additionsReadOnly: [],
                                       warnings: [], serverRestarts: 0, receivedAt: Date())
    }

    @Test("a network-only policy is a firewall, not a sandbox")
    func networkOnly() {
        let p = profile("version: 1\nnetwork_policies:\n  github:\n    endpoints:\n      - host: github.com\n        port: 443\n")
        let posture = SecurityPosture(profile: p)
        #expect(posture.firewall)
        #expect(!posture.sandbox)
        #expect(!SecurityPosture.confinesGuest(p, reported: reported("off")))
    }

    @Test("a filesystem_policy or process section confines the guest")
    func confined() {
        #expect(SecurityPosture(profile: profile("version: 1\nfilesystem_policy:\n  read_write: [/tmp]\nnetwork_policies: {}\n")).sandbox)
        #expect(SecurityPosture(profile: profile("version: 1\nprocess:\n  run_as_user: sandbox\nnetwork_policies: {}\n")).sandbox)
        // The editor's "confined" check is the same one.
        #expect(OpenShellSandboxSpec(policyYAML: "version: 1\nnetwork_policies: {}\n", workdirs: [],
                                     strictSandbox: false, sentry: "best_effort").confinesGuest == false)
    }

    @Test("the guest reporting its filesystem sandbox enforced counts; failed or off doesn't")
    func reportedByGuest() {
        let p = profile("version: 1\nnetwork_policies: {}\n")
        #expect(SecurityPosture.confinesGuest(p, reported: reported("enforced")))
        #expect(!SecurityPosture.confinesGuest(p, reported: reported("failed")))
        #expect(!SecurityPosture.confinesGuest(profile(""), reported: reported("off")))
    }
}
