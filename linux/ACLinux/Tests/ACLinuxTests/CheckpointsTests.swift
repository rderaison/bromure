import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A Linux server's VM checkpoints (macOS: ProfileStore's disk and home
    /// checkpoints): copy-on-write only. Where the filesystem can't reflink
    /// (this host's ext4 / tmpfs) none are taken and the routes say why; with
    /// a cloner that works (here one that copies), macOS's behaviour: one
    /// automatic a day, the ladder, a revert that puts the image back, the
    /// current home checkpointed first, never over a VM that holds its disks.
    @Suite("VM checkpoints", .serialized)
    struct CheckpointsTests {
        static let copying: VMCheckpoints.Cloner = { src, dst in
            do { try FileManager.default.copyItem(atPath: src, toPath: dst) } catch { return "\(error)" }
            return nil
        }

        @Test func noReflinkHereSaysWhy() async throws {
            let dir = NSTemporaryDirectory() + "cp-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/a"))
            let why = VMCheckpoints.reflink(dir + "/a", dir + "/b")
            #expect(why == VMCheckpoints.unsupportedReason, "\(why ?? "cloned")")
            #expect(VMCheckpoints.unsupportedReason.hasSuffix("put the state directory on btrfs (or XFS with reflink) to have them"),
                    "it says what to do")
            #expect(!FileManager.default.fileExists(atPath: dir + "/b"), "nothing left behind")

            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            let rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            let list = await d.vmRoute("GET", "/vms/\(rec.id)/checkpoints", .null)
            guard case .object(let o) = list.body else { Issue.record("no body"); return }
            #expect(list.status == 200 && o["checkpoints"] == .array([]))
            #expect(o["note"]?.stringValue?.contains("copy-on-write") == true)
            let revert = await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": "1", "target": "disk"])
            #expect(revert.status == 400 && revert.body["error"]?.stringValue?.hasPrefix("Nothing to revert to") == true)
            await d.shutdown()
        }

        @Test func withACloneMacOSsBehaviour() async throws {
            let (d, _, ddir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: ddir) }
            Daemon.checkpointCloner.withLockedValue { $0 = .init(clone: Self.copying) }
            defer { Daemon.checkpointCloner.withLockedValue { $0 = .init(clone: VMCheckpoints.reflink) } }
            await d.resetCheckpointProbeForTesting()
            var rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            let vm = await d.vmDir(rec.id)
            try FileManager.default.createDirectory(atPath: vm, withIntermediateDirectories: true)
            func put(_ s: String, _ t: VMCheckpoints.Target) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: VMCheckpoints.image(vm, t))) }
            func get(_ t: VMCheckpoints.Target) -> String { (try? String(contentsOfFile: VMCheckpoints.image(vm, t), encoding: .utf8)) ?? "" }
            let diskDir = VMCheckpoints.directory(vm, .disk), homeDir = VMCheckpoints.directory(vm, .home)
            let day = Date(timeIntervalSince1970: 1_800_000_000)

            try put("disk-v1", .disk)
            #expect(VMCheckpoints.snapshot(VMCheckpoints.image(vm, .disk), into: diskDir, at: day, automatic: true, clone: Self.copying).checkpoint != nil)
            #expect(VMCheckpoints.snapshot(VMCheckpoints.image(vm, .disk), into: diskDir, at: day.addingTimeInterval(60), automatic: true,
                                           clone: Self.copying).checkpoint == nil, "one automatic a day")
            // The ladder: many old ones, pruned to macOS's retention.
            for k in 2...6 {
                _ = VMCheckpoints.snapshot(VMCheckpoints.image(vm, .disk), into: diskDir, at: day.addingTimeInterval(-Double(k) * 86_400),
                                           automatic: false, clone: Self.copying)
            }
            VMCheckpoints.prune(diskDir, now: day)
            let kept = VMCheckpoints.list(diskDir).map(\.createdAt)
            #expect(Set(kept) == ProfileStore.checkpointRetention(kept, now: day) && kept.count <= 3 && kept.first == day)

            // Listed newest first, disk then home.
            try put("home-v1", .home)
            _ = VMCheckpoints.snapshot(VMCheckpoints.image(vm, .home), into: homeDir, at: day, automatic: true, clone: Self.copying)
            let list = await d.vmRoute("GET", "/vms/\(rec.id)/checkpoints", .null)
            guard case .array(let rows)? = list.body["checkpoints"] else { Issue.record("no list"); return }
            #expect(rows.first?["target"] == "disk" && rows.last?["target"] == "home" && list.body["note"] == nil)

            // Revert the disk: back to v1.
            try put("disk-v2", .disk)
            let id = String(Int(day.timeIntervalSince1970))
            let r = await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": .string(id), "target": "disk"])
            #expect(r.status == 200 && get(.disk) == "disk-v1")
            // The home: the current one checkpointed first, then put back.
            try put("home-v2", .home)
            let before = VMCheckpoints.list(homeDir).count
            let h = await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": .string(id), "target": "home"])
            #expect(h.status == 200 && get(.home) == "home-v1")
            #expect(VMCheckpoints.list(homeDir).count == before + 1, "a safety net of the home as it was")
            // Refused: an unknown checkpoint, a bad target, a suspended VM.
            #expect(await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": "../x", "target": "disk"]).status == 400)
            #expect(await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": .string(id), "target": "boot"]).status == 400)
            rec.state = .suspended
            try await d.registerForTesting(rec)
            let s = await d.vmRoute("POST", "/vms/\(rec.id)/revert", ["checkpoint": .string(id), "target": "disk"])
            #expect(s.status == 400 && s.body["error"]?.stringValue?.contains("suspended") == true)
            await d.shutdown()
        }
    }
}
