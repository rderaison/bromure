import Foundation
import Testing
@testable import ACLinux

/// A workspace's temporary firewall rules on the daemon (macOS:
/// FirewallRuleActions+App.swift): "until the workspace stops" rules end
/// with the workspace, and at launch for one that isn't running.
@Suite("Firewall until-stop rules", .serialized)
struct FirewallUntilStopTests {
    @Test func aStopAndTheLaunchSweepEndUntilStopRules() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prior = ProfileStore.defaultRootDir
        ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
        defer { ProfileStore.defaultRootDir = prior }
        var p = Profile(name: "fw", tool: .claude, authMode: .local)
        p.egressRules = "allow tcp temp.example #@until=stop\nallow tcp kept.example\ndefault deny"
        p = try ProfileStore().save(p)
        let id = p.id
        func rules() -> String { ProfileStore().loadAll().first { $0.id == id }?.egressRules ?? "" }

        await d.endUntilStopFirewallRules(for: id)
        #expect(rules().contains("#@off allow tcp temp.example"), "switched off: \(rules())")
        #expect(rules().contains("allow tcp kept.example") && !rules().contains("#@off allow tcp kept.example"), "the others stay")
        #expect(!rules().contains("until=stop"))

        // The launch sweep: a stopped workspace's until-stop rules end too;
        // a sweep that isn't the launch's leaves them.
        p.egressRules = "allow tcp temp.example #@until=stop\ndefault deny"
        _ = try ProfileStore().update(p)
        await d.sweepFirewallRules(launch: false)
        #expect(rules().contains("#@until=stop"), "not at a later sweep")
        await d.sweepFirewallRules(launch: true)
        #expect(rules().contains("#@off allow tcp temp.example"))

        // An expired timed rule is switched off at any sweep.
        let past = Int(Date().timeIntervalSince1970) - 60
        p.egressRules = "allow tcp temp.example #@until=\(past)\ndefault deny"
        _ = try ProfileStore().update(p)
        await d.sweepFirewallRules(launch: false)
        #expect(rules().contains("#@off allow tcp temp.example"), "\(rules())")
    }
}
