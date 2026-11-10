import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Starting a workspace marked compromised asks its owner to wipe it
    /// (macOS: confirmWipeAndProceedAsync): Cancel (and nobody answering)
    /// leaves it marked and off; Wipe and Launch wipes, then boots.
    @Suite("Wipe and Launch", .serialized)
    struct WipeAndLaunchTests {
        static func marked() async throws -> (Daemon, VMRecord, Profile, String) {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            let store = ProfileStore()
            var p = Profile(name: "wipe-\(UUID().uuidString.prefix(6))", tool: .claude, authMode: .token)
            p.folderPaths = ["/srv/shared"]
            p = try store.save(p)
            var rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            rec.name = p.name
            try await d.registerForTesting(rec)
            Daemon.markCompromised(p, store: store)
            let vmDir = dir + "/state/vms/" + rec.id
            try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
            try Data("disk".utf8).write(to: URL(fileURLWithPath: vmDir + "/disk.raw"))
            return (d, rec, p, dir)
        }

        @Test func cancelLeavesItMarkedAndOff() async throws {
            let (d, rec, p, dir) = try await Self.marked()
            defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(at: ProfileStore().profileDirectory(for: p)) }
            let (title, info) = Daemon.compromisePromptParts(profile: p)
            #expect(title.contains(p.name) && info.contains("/srv/shared") && info.contains("NOT wiped"))
            Daemon.wipeAnswerForTesting.withLockedValue { $0 = { _ in 1 } }
            defer { Daemon.wipeAnswerForTesting.withLockedValue { $0 = nil } }
            let r = await d.start(rec)
            #expect(r.status == 409 && r.body["cancelled"] == .bool(true))
            #expect(Daemon.isCompromised(p, store: ProfileStore()))
            #expect(FileManager.default.fileExists(atPath: dir + "/state/vms/" + rec.id + "/disk.raw"))
            let unattended = await d.start(rec, unattended: true)
            #expect(unattended.status == 409 && unattended.body["compromised"] == .bool(true), "nobody to ask")
            await d.shutdown()
        }

        @Test func wipeAndLaunchWipesThenBoots() async throws {
            let (d, rec, p, dir) = try await Self.marked()
            defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(at: ProfileStore().profileDirectory(for: p)) }
            Daemon.wipeAnswerForTesting.withLockedValue { $0 = { _ in 0 } }
            defer { Daemon.wipeAnswerForTesting.withLockedValue { $0 = nil } }
            let r = await d.start(rec)
            #expect(r.body["cancelled"] == nil && r.body["compromised"] == nil, "wiped, then on to the boot")
            #expect(!Daemon.isCompromised(p, store: ProfileStore()))
            #expect(!FileManager.default.fileExists(atPath: dir + "/state/vms/" + rec.id + "/disk.raw"))
            await d.shutdown()
        }

        @Test func aMarkClearedMeanwhileWipesNothing() async throws {
            let (d, rec, p, dir) = try await Self.marked()
            defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(at: ProfileStore().profileDirectory(for: p)) }
            Daemon.wipeAnswerForTesting.withLockedValue { $0 = { _ in
                try? FileManager.default.removeItem(at: Daemon.compromiseMarkURL(p, store: ProfileStore()))
                return 0
            } }
            defer { Daemon.wipeAnswerForTesting.withLockedValue { $0 = nil } }
            let r = await d.start(rec)
            #expect(r.status == 409 && (r.body["error"]?.stringValue ?? "").contains("wasn't wiped"))
            #expect(FileManager.default.fileExists(atPath: dir + "/state/vms/" + rec.id + "/disk.raw"))
            await d.shutdown()
        }
    }
}
