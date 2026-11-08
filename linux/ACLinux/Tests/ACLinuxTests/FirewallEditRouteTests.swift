import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A fat client's firewall drawer on a Linux server (main: POST
    /// /profiles/<id>/firewall-edit, and /firewall's replies): an edit is
    /// applied to the rules as they are now and the reply says whether it
    /// changed, was already so, or why it couldn't be made, never a success
    /// for an Allow that installed nothing.
    @Suite("Firewall edit route", .serialized)
    struct FirewallEditRouteTests {
        @Test func editsSayHowTheyWent() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "fw", tool: .claude, authMode: .token)
            p.egressRules = "default allow"
            p = try ProfileStore().save(p)
            let key = p.id.uuidString

            let insert: JSONValue = ["op": "insert", "rule": "deny tcp 203.0.113.7"]
            let first = await d.firewallEditRoute(key, insert)
            #expect(first.status == 200 && first.body["changed"] == .bool(true), "\(first.body)")
            #expect(ProfileStore().loadAll().first { $0.id == p.id }?.egressRules.contains("deny tcp 203.0.113.7") == true)
            let again = await d.firewallEditRoute(key, insert)
            #expect(again.status == 200 && again.body["changed"] == .bool(false), "already so")

            let gone = await d.firewallEditRoute(key, ["op": "disable", "ruleText": "allow tcp nowhere.example"])
            #expect(gone.status == 409 && gone.body["ok"] == .bool(false), "\(gone.body)")
            #expect(gone.body["error"]?.stringValue?.contains("no longer") == true)

            #expect(await d.firewallEditRoute(key, ["op": "bogus"]).status == 400)
            #expect(await d.firewallEditRoute(UUID().uuidString, insert).status == 404)

            #expect(await d.firewallRoute(key, ["rules": "this is not a rule"]).status == 400)
            let whole = await d.firewallRoute(key, ["rules": "default deny"])
            #expect(whole.status == 200 && whole.body["changed"] == .bool(true))
            await d.shutdown()
        }
    }
}
