import Foundation
import Testing
@testable import ACLinux

/// The ext4 checker a cluster machine's disks are repaired with (macOS's,
/// shared): images made and damaged with the host's e2fsprogs, checked by
/// Ext4Fsck, and cross-checked read-only with e2fsck.
@Suite("Cluster disk repair", .serialized,
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/mkfs.ext4")
                    && FileManager.default.isExecutableFile(atPath: "/usr/sbin/debugfs")))
struct DiskRepairTests {
    /// Runs an e2fsprogs tool (bounded); its exit status and output.
    @discardableResult
    static func tool(_ name: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/" + name)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, text)
    }

    /// A fresh 64 MiB ext4 (with a journal) in `dir`, with a few files.
    static func image(_ dir: String, _ name: String = "fs.img") throws -> String {
        let path = dir + "/" + name
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.truncate(atOffset: 64 << 20)
        try h.close()
        let (rc, out) = try tool("mkfs.ext4", ["-q", "-F", "-L", "root", path])
        #expect(rc == 0, "mkfs: \(out)")
        try tool("debugfs", ["-w", "-R", "mkdir /var", path])
        try tool("debugfs", ["-w", "-R", "write /etc/hostname /var/hostname", path])
        return path
    }

    static func header(_ path: String) throws -> String { try tool("dumpe2fs", ["-h", path]).1 }

    @Test func aCleanImageIsClean() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = try Self.image(dir)
        let r = try Ext4Fsck.check(imagePath: img, autoFix: true)
        #expect(r.clean, "\(r.summary)\n\(r.output)")
    }

    @Test func aJournalLeftForReplayIsRepaired() throws {
        // What a VM killed mid-write leaves: INCOMPAT_RECOVER set.
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = try Self.image(dir)
        try Self.tool("debugfs", ["-w", "-R", "feature needs_recovery", img])
        #expect(try Self.header(img).contains("needs_recovery"), "the damage is in place")
        let r = try Ext4Fsck.check(imagePath: img, autoFix: true)
        #expect(r.repaired, "\(r.summary)\n\(r.output)")
        #expect(try !Self.header(img).contains("needs_recovery"), "the flag is gone, written through LibC.fsync")
        let (rc, out) = try Self.tool("e2fsck", ["-fn", img])
        #expect(rc == 0, "e2fsck (read-only) finds it consistent: \(out)")
        #expect(try Ext4Fsck.check(imagePath: img, autoFix: true).clean, "and a second pass finds nothing")
    }

    @Test func checkingWithoutRepairLeavesTheImageAlone() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = try Self.image(dir)
        try Self.tool("debugfs", ["-w", "-R", "feature needs_recovery", img])
        let r = try Ext4Fsck.check(imagePath: img, autoFix: false)
        #expect(!r.clean && !r.repaired)
        #expect(try Self.header(img).contains("needs_recovery"))
    }

    @Test func aDataDiskNeverFormattedIsNotExt4() throws {
        // A cluster machine's data.img before the guest formats it: zeros.
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = dir + "/data.img"
        _ = FileManager.default.createFile(atPath: img, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: img))
        try h.truncate(atOffset: 32 << 20)
        try h.close()
        #expect(throws: (any Error).self) { try Ext4Fsck.check(imagePath: img, autoFix: true) }
    }

    @Test func damagePastTheJournalIsNotPassedAsRepaired() throws {
        // A reachable inode whose checksum is wrong (lost+found): the quick
        // repair must say so (the engine then goes on to the e2fsck rescue),
        // never report it fixed.
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = try Self.image(dir)
        try Self.tool("debugfs", ["-w", "-R", "sif <11> checksum 0x1234", img])
        let r = try Ext4Fsck.check(imagePath: img, autoFix: true)
        #expect(!r.clean && !r.repaired, "\(r.summary)\n\(r.output)")
    }

    @Test func thePartitionedSystemDiskLayout() throws {
        // disk.raw's shape: GPT, an EFI partition, then the ext4 root.
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let fs = try Self.image(dir)
        try Self.tool("debugfs", ["-w", "-R", "feature needs_recovery", fs])
        let disk = dir + "/disk.raw"
        _ = FileManager.default.createFile(atPath: disk, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
        try h.truncate(atOffset: 80 << 20)
        try h.close()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sfdisk")
        p.arguments = ["-q", disk]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data("""
        label: gpt
        start=2048, size=8192, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
        start=10240, size=131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"

        """.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // The dirty filesystem into partition 2.
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: fs))
        let dst = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
        try dst.seek(toOffset: 10240 * 512)
        while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty { dst.write(chunk) }
        try src.close(); try dst.close()
        let r = try Ext4Fsck.check(imagePath: disk, autoFix: true)
        #expect(r.repaired, "the ext4 partition found and repaired: \(r.summary)\n\(r.output)")
        #expect(try Ext4Fsck.check(imagePath: disk, autoFix: true).clean)
    }

    /// Opt-in (BROMURE_FSCK_IMAGE=<a system disk>): the checker over a real
    /// image, read-only (nothing written), with its timing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROMURE_FSCK_IMAGE"] != nil))
    func aRealSystemDiskReadOnly() throws {
        let path = ProcessInfo.processInfo.environment["BROMURE_FSCK_IMAGE"]!
        let t0 = Date()
        let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
        print("[fsck] \(path): \(r.summary) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n\(r.output)")
        #expect(r.clean, "\(r.summary)\n\(r.output)")
    }
}

/// The gate between a cluster machine's disk repair and its start.
@Suite("Repair marks")
struct RepairMarksTests {
    static func stopped(_ id: String = UUID().uuidString.lowercased()) -> VMRecord {
        VMRecord(id: id, name: "k8s-r-1", machine: "firecracker", cid: 3, mac: "52:54:00:00:00:09",
                 state: .stopped, ip: nil, cpus: 1, memoryMiB: 512, createdAt: Date(), bootedAt: nil, statePath: nil)
    }

    @Test func aStartDuringARepairIsRefusedAndAllowedAfter() {
        let marks = RepairMarks(), rec = Self.stopped()
        #expect(Daemon.startRefusal(rec, repairing: marks) == nil, "a stopped machine starts")
        #expect(marks.insert(rec.id))
        let r = Daemon.startRefusal(rec, repairing: marks)
        #expect(r?.status == 409 && r?.body["error"]?.stringValue?.contains("disks repaired") == true)
        #expect(!marks.insert(rec.id), "a second repair doesn't take it either")
        marks.remove(rec.id)
        #expect(Daemon.startRefusal(rec, repairing: marks) == nil)
    }

    @Test func aStartRacingARepairIsRefusedUntilItEnds() async {
        let marks = RepairMarks(), rec = Self.stopped()
        #expect(marks.insert(rec.id))
        let refusedInside = NIOLockedValueBoxShim(0)
        let repair = Task {
            await marks.whileMarked(rec.id) {
                // Starts tried from elsewhere while the "checker" runs.
                for _ in 0..<20 {
                    let r = await Task.detached { Daemon.startRefusal(rec, repairing: marks) }.value
                    if r?.status == 409 { refusedInside.mutate { $0 += 1 } }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        await repair.value
        #expect(refusedInside.value == 20, "every start during the repair was refused")
        #expect(Daemon.startRefusal(rec, repairing: marks) == nil, "and the machine starts once it ended")
    }

    @Test func theMarkIsClearedAfterAThrow() async {
        struct Boom: Error {}
        let marks = RepairMarks(), id = "m"
        #expect(marks.insert(id))
        do {
            try await marks.whileMarked(id) { throw Boom() }
            Issue.record("didn't throw")
        } catch {}
        #expect(!marks.contains(id))
        #expect(marks.insert(id), "a later repair can take it again")
    }
}

/// The repair gate on a real daemon: its own `start` held at an await in
/// launch (the test hook), and a repair taken through kubeMachineDiskImages.
/// Nothing boots, so its uplink is a no-op stand-in, not passt: no passt
/// process for the passt suite's counts to trip on.
@Suite("Repair marks on a daemon", .serialized)
struct DaemonRepairGateTests {
    /// A daemon in a temp dir, with one stopped machine registered.
    static func daemon() async throws -> (Daemon, VMRecord, String) {
        let dir = try shortTempDir()
        let standIn = dir + "/uplink-standin"
        try "#!/bin/sh\nexec cat >/dev/null\n".write(toFile: standIn, atomically: true, encoding: .utf8)
        chmod(standIn, 0o755)
        let d = try await Daemon.makeForTesting(DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run",
                                                             imageDir: dir + "/image", agentdPath: dir + "/agentd.py"),
                                                uplink: standIn)
        let rec = RepairMarksTests.stopped()
        try await d.registerForTesting(rec)
        return (d, rec, dir)
    }

    /// Holds the next launch until `release` and then aborts it.
    final class Gate: @unchecked Sendable {
        let entered = NIOLockedValueBoxShim(false)
        let released = NIOLockedValueBoxShim(false)
        func install() {
            Daemon.launchHookForTesting.withLockedValue { $0 = { [self] _ in
                entered.mutate { $0 = true }
                while !released.value { try await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()        // never boot anything here
            } }
        }
        func waitEntered() async { while !entered.value { try? await Task.sleep(for: .milliseconds(10)) } }
        /// (Not in deinit: the hook holds the gate, and replacing it under
        /// the box's lock would run deinit there.)
        static func uninstall() { Daemon.launchHookForTesting.withLockedValue { $0 = nil } }
    }

    @Test func aStartHeldInLaunchKeepsARepairAndARemoveOut() async throws {
        let (d, rec, dir) = try await Self.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let gate = Gate(); gate.install()
        defer { Gate.uninstall() }
        let start = Task { await d.start(rec) }
        await gate.waitEntered()            // the start passed its checks and awaits in launch
        #expect(await d.kubeMachineDiskImages(id: rec.id) == nil, "a repair can't take a machine that's starting")
        #expect(!d.repairMarks.contains(rec.id))
        let rm = await d.remove(rec)
        #expect(rm.status == 409 && rm.body["error"]?.stringValue?.contains("starting") == true, "\(rm.body)")
        gate.released.mutate { $0 = true }
        let r = await start.value
        #expect(r.status == 500, "the held launch was aborted")
        #expect(await d.kubeMachineDiskImages(id: rec.id) != nil, "once the start ended, a repair may take it")
        d.repairMarks.remove(rec.id)
        await d.shutdown()
    }

    @Test func aRepairInProgressKeepsAStartAndARemoveOut() async throws {
        let (d, rec, dir) = try await Self.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let gate = Gate(); gate.install(); gate.released.mutate { $0 = true }
        defer { Gate.uninstall() }
        #expect(await d.kubeMachineDiskImages(id: rec.id) != nil, "the repair takes the stopped machine")
        let s = await d.start(rec)
        #expect(s.status == 409 && s.body["error"]?.stringValue?.contains("disks repaired") == true, "\(s.body)")
        #expect(!gate.entered.value, "the start never reached launch")
        let rm = await d.remove(rec)
        #expect(rm.status == 409 && rm.body["error"]?.stringValue?.contains("repaired") == true, "\(rm.body)")
        await d.repairMarks.whileMarked(rec.id) {}   // the repair ends
        let after = await d.start(rec)
        #expect(gate.entered.value && after.status == 500, "after it, the start got as far as launch (aborted by the hook)")
        await d.shutdown()
    }
}
