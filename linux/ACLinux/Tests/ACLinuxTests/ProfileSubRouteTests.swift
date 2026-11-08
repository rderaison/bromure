import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A workspace's sub-routes a fat client uses on a Linux server (macOS:
    /// handleProfileRoute): Squelch on or off, its policy revisions, and
    /// deleting it (refused while it runs; its VM's record and files go too).
    @Suite("Profile sub-routes", .serialized)
    struct ProfileSubRouteTests {
        static func daemon() async throws -> (Daemon, String, URL?) {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            return (d, dir, prior)
        }

        @Test func squelchIsSwitchedAndSaved() async throws {
            let (d, dir, prior) = try await Self.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            let p = try ProfileStore().save(Profile(name: "sq", tool: .claude, authMode: .token))
            let on = await d.workspaceRoute("POST", "/profiles/\(p.id.uuidString)/squelch", ["enabled": true])
            #expect(on?.status == 200 && on?.body["enabled"] == .bool(true))
            #expect(ProfileStore().loadAll().first { $0.id == p.id }?.squelch.enabled == true)
            #expect(await d.workspaceRoute("POST", "/profiles/\(p.id.uuidString)/squelch", [:])?.status == 400)
            #expect(await d.workspaceRoute("POST", "/profiles/\(UUID().uuidString)/squelch", ["enabled": false])?.status == 404)
            await d.shutdown()
        }

        @Test func policyRevisionsAreListedAndRead() async throws {
            let (d, dir, prior) = try await Self.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            let p = try ProfileStore().save(Profile(name: "rev", tool: .claude, authMode: .token))
            let pdir = ProfileStore().profileDirectory(for: p)
            PolicyHistory.shared.record(policy: "version: 1\n", source: "editor", in: pdir)
            PolicyHistory.shared.record(policy: "version: 1\nnetwork_policies: {}\n", source: "advisor", in: pdir)
            let list = try #require(await d.workspaceRoute("GET", "/profiles/\(p.id.uuidString)/policy/revisions", .null))
            #expect(list.status == 200, "\(list.body)")
            guard case .array(let revs) = list.body["revisions"] ?? .null else { Issue.record("\(list.body)"); return }
            #expect(revs.count == 2 && list.body["current"] == .number(2))
            let one = await d.workspaceRoute("GET", "/profiles/\(p.id.uuidString)/policy/revisions/1", .null)
            #expect(one?.status == 200 && one?.body["policy"] == .string("version: 1\n"))
            #expect(await d.workspaceRoute("GET", "/profiles/\(p.id.uuidString)/policy/revisions/9", .null)?.status == 404)
            #expect(await d.workspaceRoute("GET", "/profiles/\(p.id.uuidString)/bogus", .null)?.status == 404)
            // The plain describe still answers.
            #expect(await d.workspaceRoute("GET", "/profiles/\(p.id.uuidString)", .null)?.status == 200)
            await d.shutdown()
        }

        @Test func aWorkspaceIsDeletedWithItsVM() async throws {
            let (d, dir, prior) = try await Self.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            let p = try ProfileStore().save(Profile(name: "gone", tool: .claude, authMode: .token))
            let key = p.id.uuidString.lowercased()
            try await d.registerForTesting(RepairMarksTests.stopped(key))
            let vm = await d.vmDir(key)
            try FileManager.default.createDirectory(atPath: vm, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: vm + "/home.img"))
            let r = await d.workspaceRoute("DELETE", "/profiles/\(p.id.uuidString)", .null)
            #expect(r?.status == 200 && r?.body["name"] == .string("gone"), "\(String(describing: r?.body))")
            #expect(!ProfileStore().loadAll().contains { $0.id == p.id })
            #expect(await d.registry.find(key) == nil)
            #expect(!FileManager.default.fileExists(atPath: vm))
            #expect(await d.workspaceRoute("DELETE", "/profiles/\(p.id.uuidString)", .null)?.status == 409, "already gone")
            await d.shutdown()
        }
    }
}
