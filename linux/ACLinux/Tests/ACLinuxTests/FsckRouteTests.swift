import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// POST /vms/<id>/fsck (`workspaces fsck`): the daemon checks its own
    /// image under the VM's repair mark, never one a VM has open.
    @Suite("fsck route", .serialized,
           .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/mkfs.ext4")
                        && FileManager.default.isExecutableFile(atPath: "/usr/sbin/debugfs")))
    struct FsckRouteTests {
        @Test func aStoppedVMsImageIsCheckedUnderItsMark() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let vmDir = dir + "/state/vms/" + rec.id
            try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)

            var r = await d.fsckRoute(rec, ["repair": false])
            #expect(r.status == 404, "no image yet: \(r.body)")
            _ = try DiskRepairTests.image(vmDir, "disk.raw")
            r = await d.fsckRoute(rec, ["repair": false])
            #expect(r.status == 200 && r.body["status"] == .number(0), "\(r.body)")
            #expect(r.body["summary"]?.stringValue == "Filesystem is clean.")
            #expect(!d.repairMarks.contains(rec.id), "the mark is released")

            // Another repair holds it: refused, the mark left alone.
            #expect(d.repairMarks.insert(rec.id))
            r = await d.fsckRoute(rec, ["repair": true])
            #expect(r.status == 409 && "\(r.body)".contains("already being repaired"), "\(r.body)")
            #expect(d.repairMarks.contains(rec.id))
            // Nor may a revert replace the image under the checker.
            let rv = await d.revertRoute(rec, ["checkpoint": "x", "target": "disk"])
            #expect(rv.status == 400 && "\(rv.body)".contains("being repaired"), "\(rv.body)")
            d.repairMarks.remove(rec.id)

            // Running, starting, or (for a repair) suspended: refused.
            for state in [VMRecord.State.running, .starting] {
                var live = rec; live.state = state
                r = await d.fsckRoute(live, ["repair": false])
                #expect(r.status == 409 && "\(r.body)".contains("stop it first"), "\(state): \(r.body)")
            }
            var suspended = rec; suspended.state = .suspended
            r = await d.fsckRoute(suspended, ["repair": true])
            #expect(r.status == 409 && "\(r.body)".contains("suspended"), "\(r.body)")
            r = await d.fsckRoute(suspended, ["repair": false])
            #expect(r.status == 200, "a read-only check of a suspended VM's disk: \(r.body)")
            await d.shutdown()
        }
    }
}
