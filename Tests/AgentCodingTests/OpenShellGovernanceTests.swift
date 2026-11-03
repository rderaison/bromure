import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("OpenShell governance", .serialized)
struct OpenShellGovernanceTests {
    @Test("openshell-prover JSON maps to boundary results")
    func proverJSON() {
        #expect(OpenShellProver.parse(Data(#"{"result":"within_boundary"}"#.utf8)) == .withinBoundary)
        if case .exceedsBoundary(let c)? = OpenShellProver.parse(Data(#"{"result":"exceeds_boundary","counterexample":{"kind":"filesystem","path":"/tmp"}}"#.utf8)) {
            #expect(c.contains("/tmp"))
        } else { Issue.record("exceeds expected") }
        #expect(OpenShellProver.parse(Data(#"{"result":"unsupported","reason_code":"unsupported_policy_shape","reason":"graphql"}"#.utf8))
                == .unsupported(reason: "graphql"))
        #expect(OpenShellProver.parse(Data("junk".utf8)) == nil)
    }

    @Test("Provider rules join the candidate outside the reserved namespace")
    func candidate() throws {
        let rule = try #require(try OpenShellProviderProfile.parse(OpenShellProviderTests.githubProfile)
            .networkRule(instanceName: "gh") as OpenShellPolicy.NetworkRule?)
        let yaml = OpenShellGovernance.candidateYAML(policy: "version: 1\n", providerRules: [rule])
        let parsed = try OpenShellPolicy.parse(yaml)
        #expect(parsed.networkPolicies.map(\.key) == ["provider_gh"])
    }

    @Test("Managed documents decode; empty means none")
    func managedDecode() {
        let m = OpenShellManagedPolicySync.decode(Data(#"{"boundary_yaml":"version: 1\n","require_strict_sandbox":true,"max_advisor_mode":"review"}"#.utf8))
        #expect(m?.boundaryYAML == "version: 1\n")
        #expect(m?.requireStrictSandbox == true)
        #expect(m?.maxAdvisorMode == "review")
        #expect(OpenShellManagedPolicySync.decode(Data(#"{"boundary_yaml":"  "}"#.utf8)) == nil)
    }

    @Test("Advisor mode is clamped to the organization's maximum")
    func clamp() {
        let g = OpenShellGovernance()
        #expect(g.effectiveAdvisorMode(.auto) == .auto || g.managed != nil)
        var m = OpenShellGovernance.Managed()
        m.maxAdvisorMode = "review"
        let saved = UserDefaults.standard.data(forKey: OpenShellGovernance.managedKey)
        defer { UserDefaults.standard.set(saved, forKey: OpenShellGovernance.managedKey) }
        g.setManaged(m)
        #expect(g.effectiveAdvisorMode(.auto) == .review)
        #expect(g.effectiveAdvisorMode(.off) == .off)
    }

    /// Finding (CWE-693): "Sandbox drawer filesystem Allow bypasses the
    /// organization boundary". The drawer saved through persistEditedProfile,
    /// which ran no boundary check; the check now lives in that save path.
    @Test("A save that adds a filesystem path outside the boundary is refused; unrelated saves aren't")
    func drawerAllowRespectsBoundary() throws {
        let saved = UserDefaults.standard.string(forKey: OpenShellGovernance.localBoundaryKey)
        let savedManaged = UserDefaults.standard.data(forKey: OpenShellGovernance.managedKey)
        defer {
            UserDefaults.standard.set(saved, forKey: OpenShellGovernance.localBoundaryKey)
            UserDefaults.standard.set(savedManaged, forKey: OpenShellGovernance.managedKey)
        }
        let g = OpenShellGovernance()
        g.setManaged(nil)
        g.setLocalBoundary("""
            version: 1
            filesystem_policy:
              read_only: [/usr]
              read_write: [/tmp]
            """)
        var existing = Profile(name: "b", tool: .claude, authMode: .token)
        existing.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\n"
        #expect(g.refusal(saving: existing, editing: nil) == nil)

        // What the drawer's Allow does: splice a path in, then save.
        var outside = existing
        outside.networkPolicy = try OpenShellPolicy.addingFilesystemPath("/etc", readWrite: true, to: existing.networkPolicy)
        let refusal = try #require(g.refusal(saving: outside, editing: existing))
        #expect(refusal.description.contains("outside the organization boundary"))
        #expect(refusal.description.contains("/etc"))

        var inside = existing
        inside.networkPolicy = try OpenShellPolicy.addingFilesystemPath("/tmp", readWrite: true, to: existing.networkPolicy)
        #expect(g.refusal(saving: inside, editing: existing) == nil)

        // A workspace already outside a newer boundary can still save other edits.
        var renamed = outside
        renamed.name = "renamed"
        #expect(g.refusal(saving: renamed, editing: outside) == nil)
    }
}

/// Finding (CWE-670): "Turning the sentry off on the firewall ignores the
/// organization minimum". Turn off / switching to the firewall / Discard
/// wrote `.off`, the card then hid (it read the stored mode), while the
/// managed floor kept the sentry on — the pane said it was off.
@Suite("Firewall pane: the kernel sentry card follows the mode that applies")
struct FirewallSentryCardTests {
    @Test("With an organization minimum the card stays, without Turn off; without one it offers it")
    func card() {
        var p = Profile(name: "f", tool: .claude, authMode: .token)
        p.kernelSentry = .off
        #expect(FirewallEditor.firewallSentryCard(p, floor: .off) == .none)
        #expect(FirewallEditor.firewallSentryCard(p, floor: .bestEffort) == .required(.bestEffort))
        p.kernelSentry = .hard
        #expect(FirewallEditor.firewallSentryCard(p, floor: .off) == .canTurnOff)
        #expect(FirewallEditor.firewallSentryCard(p, floor: .bestEffort) == .canTurnOff)   // down to the floor
        #expect(FirewallEditor.firewallSentryCard(p, floor: .hard) == .required(.hard))
        // Turning it off stores `.off`; the card then says the floor is in force.
        p.kernelSentry = .off
        #expect(FirewallEditor.firewallSentryCard(p, floor: .bestEffort) == .required(.bestEffort))
    }

    /// Finding (CWE-670): "Firewall sentry card stays stale after the
    /// organization floor changes, and Turn off can save a higher mode".
    /// The card read the floor once in `body`, and Turn off stored whatever
    /// the floor was at the click, so a minimum that rose to Required after
    /// the card was drawn was saved into the workspace and outlived the
    /// organization dropping it.
    @Test("The pane's floor follows the organization's changes; Turn off stores no minimum")
    @MainActor
    func floorFollows() {
        let center = NotificationCenter()
        final class Org: @unchecked Sendable { var floor: KernelSentryMode = .off }
        let org = Org()
        let watch = KernelSentryFloorWatch(center: center, read: { org.floor })
        var p = Profile(name: "f", tool: .claude, authMode: .token)
        p.kernelSentry = .bestEffort
        #expect(FirewallEditor.firewallSentryCard(p, floor: watch.floor) == .canTurnOff)

        org.floor = .hard
        center.post(name: OpenShellGovernance.changedNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(watch.floor == .hard)
        #expect(FirewallEditor.firewallSentryCard(p, floor: watch.floor) == .required(.hard))   // no Turn off now

        // Turn off (and leaving the OpenShell engine) stores off, never the
        // minimum of the moment: the organization's floor still applies,
        // and once it drops the workspace is off again.
        p.kernelSentry = .off
        #expect(FirewallEditor.firewallSentryCard(p, floor: .hard) == .required(.hard))
        #expect(FirewallEditor.firewallSentryCard(p, floor: .off) == .none)
        let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/OpenShellPolicyEditor.swift"), encoding: .utf8)) ?? ""
        #expect(!src.contains("draft.kernelSentry = OpenShellGovernance.shared.kernelSentryFloor"))
    }

    @Test("The discard dialog says what will actually apply")
    func discardMessage() {
        #expect(FirewallEditor.discardMessage(floor: .off).contains("kernel sentry turned off"))
        let kept = FirewallEditor.discardMessage(floor: .hard)
        #expect(!kept.contains("turned off") && kept.contains("stays on") && kept.contains("Required"))
    }
}
