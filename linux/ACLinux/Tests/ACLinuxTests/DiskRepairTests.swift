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

/// The boot console scan a cluster machine's start runs (the serial log
/// appended to as the guest boots).
@Suite("Boot console scan")
struct BootConsoleScanTests {
    static func append(_ path: String, _ text: String) {
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    }

    @Test func theEmergencyPromptIsCaughtWithoutANewline() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        // A previous boot's failure is before the offset: not this boot's.
        _ = FileManager.default.createFile(atPath: log, contents: Data("old boot: RUN fsck MANUALLY\n".utf8))
        let offset = UInt64(try FileManager.default.attributesOfItem(atPath: log)[.size] as! Int)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            Self.append(log, "[  OK  ] Started Journal Service.\n/dev/vda2 contains a file system with errors, check forced.\n")
            try? await Task.sleep(for: .milliseconds(300))
            Self.append(log, "/dev/vda2: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.\n\tGive root password for maintenance\n(or press Control-D to continue): ")
        }
        let t0 = Date()
        let m = await BootConsoleScan.scan(path: log, from: offset, timeout: .seconds(10), poll: .milliseconds(50)) { true }
        #expect(m?.contains("UNEXPECTED INCONSISTENCY") == true, "got \(m ?? "nil")")
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    @Test func aPromptWithoutAnyNewlineAtAll() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        _ = FileManager.default.createFile(atPath: log, contents: Data("You are in emergency mode. After logging in, type".utf8))
        let m = await BootConsoleScan.scan(path: log, from: 0, timeout: .seconds(5), poll: .milliseconds(50)) { true }
        #expect(m?.contains("emergency mode") == true)
    }

    @Test func aCleanBootIsNotReportedAndTheScanStopsWhenTold() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        _ = FileManager.default.createFile(atPath: log, contents: Data("[  OK  ] Reached target Multi-User System.\nbromure login: ".utf8))
        let polls = NIOLockedValueBoxShim(0)
        let m = await BootConsoleScan.scan(path: log, from: 0, timeout: .seconds(10), poll: .milliseconds(50)) {
            polls.mutate { $0 += 1 }
            return polls.value < 5      // the machine came up after a few polls
        }
        #expect(m == nil)
        #expect(polls.value == 5, "it stopped when told, not at the timeout")
    }

    @Test func aMissingLogIsWaitedForAndAShrunkOneReadFromItsStart() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            _ = FileManager.default.createFile(atPath: log, contents: Data("Failed to check file system on /dev/vdc\n".utf8))
        }
        // An offset past the (recreated) file's end: read from its start.
        let m = await BootConsoleScan.scan(path: log, from: 1 << 20, timeout: .seconds(5), poll: .milliseconds(50)) { true }
        #expect(m?.contains("Failed to check file system") == true)
    }
}

/// A managed machine's host folders (a disk repair's rescue): the base
/// image's virtiofs share-<N> slots, read-write.
@Suite("Managed machine folders",
       .enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.local/share/bromure-ac/image-amd64/cmdline")))
struct ManagedFolderTests {
    @Test func foldersBecomeShareSlots() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let standIn = dir + "/uplink-standin"
        try "#!/bin/sh\nexec cat >/dev/null\n".write(toFile: standIn, atomically: true, encoding: .utf8)
        chmod(standIn, 0o755)
        let d = try await Daemon.makeForTesting(DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run",
                                                             imageDir: NSHomeDirectory() + "/.local/share/bromure-ac/image-amd64",
                                                             agentdPath: dir + "/agentd.py"), uplink: standIn)
        var rec = RepairMarksTests.stopped()
        rec.folders = ["/srv/a", "/srv/b"]
        let shares = try await d.machineConfig(rec).shares
        #expect(shares.map(\.tag) == ["bromure-meta", "bromure-outbox", "share-1", "share-2"])
        #expect(shares.first { $0.tag == "share-1" }?.hostPath == "/srv/a")
        #expect(shares.first { $0.tag == "share-2" }?.readOnly == false, "the rescue's e2fsck writes through it")
        rec.folders = nil
        #expect(try await d.machineConfig(rec).shares.count == 2, "no folders, no slots")
        await d.shutdown()
    }
}

/// A daemon restarted in the middle of a deep repair: the rescue it left
/// (live or stopped) is never taken back, and its machine stays refused
/// until the rescue is gone.
@Suite("Leftover rescues", .serialized)
struct LeftoverRescueTests {
    /// A stand-in for a process: `sh` blocked on a pipe, `argv` as given.
    final class Stub {
        let p = Process(), stdin = Pipe()
        init(_ exe: String, _ args: [String]) throws {
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardInput = stdin; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
        }
        var pid: Int32 { p.processIdentifier }
        func gone(within s: Double = 5) -> Bool {
            let end = Date().addingTimeInterval(s)
            while p.isRunning, Date() < end { usleep(20_000) }
            return !p.isRunning
        }
        deinit { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }

    static func rescue(for target: VMRecord, state: VMRecord.State) -> VMRecord {
        let id = UUID().uuidString.lowercased()
        var r = VMRecord(id: id, name: "rescue-\(target.name)-\(id.prefix(8))", machine: "firecracker", cid: 4,
                         mac: "52:54:00:00:00:0a", state: state, ip: nil, cpus: 1, memoryMiB: 512,
                         createdAt: Date(), bootedAt: nil, statePath: nil)
        r.kube = UUID().uuidString.lowercased()
        r.rescueFor = target.id
        return r
    }

    /// A fake virtiofsd (its comm is the script's name) serving `socket`.
    static func virtiofsd(in dir: String, socket: String) throws -> Stub {
        let exe = dir + "/virtiofsd"
        if !FileManager.default.fileExists(atPath: exe) {
            try "#!/bin/sh\nread x\n".write(toFile: exe, atomically: true, encoding: .utf8)
            chmod(exe, 0o755)
        }
        return try Stub(exe, ["--socket-path", socket])
    }

    @Test func aLiveRescueIsEndedAndRemovedBeforeAdoptionAndItsMachineIsHeldTillThen() async throws {
        let (d, damaged, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var rescue = Self.rescue(for: damaged, state: .running)
        let vm = try Stub("/bin/sh", ["-c", "read x", "sh", "--id", "bromure-\(rescue.shortId)"])
        rescue.pid = vm.pid
        rescue.pidStart = Daemon.processStartTime(vm.pid)
        try await d.registerForTesting(rescue)
        let fs = try Self.virtiofsd(in: dir, socket: dir + "/run/vms/\(rescue.shortId)/fs2.sock")
        let decoy = try Self.virtiofsd(in: dir, socket: dir + "/run/vms/0000abcd/fs2.sock")
        usleep(100_000)

        // As a restarted daemon finds it: the damaged machine refused.
        let held = Daemon.startRefusal(damaged, repairing: d.repairMarks, rescued: await d.hasRescue(for: damaged.id))
        #expect(held?.status == 409 && held?.body["error"]?.stringValue?.contains("disks repaired") == true)
        #expect(await d.remove(damaged).status == 409, "nor removed")
        #expect(await d.kubeMachineDiskImages(id: damaged.id) == nil, "nor repaired")

        await d.adoptRunning()
        #expect(vm.gone(), "the rescue's Firecracker was ended")
        #expect(fs.gone(), "and the virtiofsd serving its share")
        #expect(!decoy.gone(within: 0.3), "another VM's virtiofsd is left alone")
        #expect(await d.registry.find(rescue.id) == nil, "its record removed")
        #expect(!d.repairMarks.contains(damaged.id))
        #expect(Daemon.startRefusal(damaged, repairing: d.repairMarks, rescued: await d.hasRescue(for: damaged.id)) == nil,
                "the machine may start (auto-start runs after adoption)")
        await d.shutdown()
    }

    /// A stand-in Firecracker (its comm is the script's name) for VM `short`.
    static func firecracker(in dir: String, short: String) throws -> Stub {
        let sub = dir + "/fcbin"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let exe = sub + "/firecracker"
        if !FileManager.default.fileExists(atPath: exe) {
            try "#!/bin/sh\nread x\n".write(toFile: exe, atomically: true, encoding: .utf8)
            chmod(exe, 0o755)
        }
        return try Stub(exe, ["--id", "bromure-" + short, "--api-sock", dir + "/run/vms/" + short + "/fc.sock"])
    }

    /// A crash between a rescue's spawn and its pid's save: the record has
    /// no pid, its Firecracker runs. Found by its `--id`, ended, then removed.
    @Test func aRescueWhosePidWasNeverSavedIsEndedToo() async throws {
        let (d, damaged, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var rescue = Self.rescue(for: damaged, state: .starting)
        rescue.pid = nil
        try await d.registerForTesting(rescue)
        let fc = try Self.firecracker(in: dir, short: rescue.shortId)
        let other = try Self.firecracker(in: dir, short: "0000abcd")
        usleep(100_000)
        await d.adoptRunning()
        #expect(fc.gone(), "its unrecorded Firecracker was ended")
        #expect(!other.gone(within: 0.3), "another VM's is left alone")
        #expect(await d.registry.find(rescue.id) == nil)
        #expect(!d.repairMarks.contains(damaged.id))
        await d.shutdown()
    }

    @Test func aStoppedRescueIsRemovedToo() async throws {
        let (d, damaged, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rescue = Self.rescue(for: damaged, state: .stopped)
        try await d.registerForTesting(rescue)
        await d.adoptRunning()
        #expect(await d.registry.find(rescue.id) == nil)
        #expect(await !d.hasRescue(for: damaged.id))
        #expect(Daemon.startRefusal(damaged, repairing: d.repairMarks, rescued: false) == nil)
        await d.shutdown()
    }

    /// A machine a restarted daemon can't take back (here: no stored
    /// network) is ended with its virtiofsds, and waited for: a boot right
    /// after would fail on their pid-file locks.
    /// The same window for any VM: starting, no pid saved, its Firecracker up.
    @Test func aVMWhosePidWasNeverSavedIsEndedAtAdoption() async throws {
        let (d, stopped, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var rec = stopped
        rec.state = .starting
        rec.pid = nil
        try await d.registerForTesting(rec)
        let fc = try Self.firecracker(in: dir, short: rec.shortId)
        usleep(100_000)
        await d.adoptRunning()
        #expect(fc.gone(within: 0.5), "gone when adoption returns")
        #expect(await d.registry.find(rec.id)?.state == .stopped)
        await d.shutdown()
    }

    @Test func aMachineNotTakenBackIsEndedWithItsVirtiofsds() async throws {
        let (d, stopped, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var rec = stopped
        rec.state = .running
        let vm = try Stub("/bin/sh", ["-c", "read x", "sh", "--id", "bromure-\(rec.shortId)"])
        rec.pid = vm.pid
        rec.pidStart = Daemon.processStartTime(vm.pid)
        try await d.registerForTesting(rec)
        let fs = try Self.virtiofsd(in: dir, socket: dir + "/run/vms/\(rec.shortId)/fs1.sock")
        usleep(100_000)
        await d.adoptRunning()
        #expect(vm.gone(within: 0.5), "its Firecracker is gone when adoption returns")
        #expect(fs.gone(within: 0.5), "and its virtiofsd")
        #expect(await d.registry.find(rec.id)?.state == .stopped)
        await d.shutdown()
    }

    /// The next deep repair clears a leftover first (unless a repair holds the machine).
    @Test func aRepairAfterALeftoverProceeds() async throws {
        let (d, damaged, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rescue = Self.rescue(for: damaged, state: .stopped)
        try await d.registerForTesting(rescue)
        #expect(await d.kubeMachineDiskImages(id: damaged.id) == nil, "refused while the leftover is on record")
        #expect(d.repairMarks.insert(damaged.id))
        #expect(await !d.removeStaleRescues(for: damaged.id), "a repair in flight keeps its rescue")
        #expect(await d.registry.find(rescue.id) != nil)
        d.repairMarks.remove(damaged.id)
        #expect(await d.removeStaleRescues(for: damaged.id))
        #expect(await d.registry.find(rescue.id) == nil)
        let images = await d.kubeMachineDiskImages(id: damaged.id)
        #expect(images?.first?.hasSuffix("/disk.raw") == true, "the repair gets the disks")
        d.repairMarks.remove(damaged.id)
        await d.shutdown()
    }
}

/// A VM's MAC (52:54:00:<cid>, fixed at its creation) is its identity on
/// the switch and in the DHCP: no new VM may take a stopped one's, though
/// a restarted daemon's allocator has leased none of them.
@Suite("VM identity across restarts")
struct VMIdentityTests {
    static func rec(cid: UInt32, mac: String) -> VMRecord {
        var r = RepairMarksTests.stopped(); r.cid = cid; r.mac = mac; return r
    }

    @Test func aNewVMTakesNeitherARecordsCIDNorItsMAC() throws {
        // As a restarted daemon finds them: stopped, none leased. One kept its
        // creation MAC (…:05) after a start moved it to CID 9.
        let records = [Self.rec(cid: 3, mac: "52:54:00:00:00:03"), Self.rec(cid: 4, mac: "52:54:00:00:00:04"),
                       Self.rec(cid: 9, mac: "52:54:00:00:00:05")]
        let alloc = CIDAllocator(range: 3...12)
        var got: [UInt32] = []
        while let c = try? alloc.allocate(skip: Daemon.identityTaken(by: records)) { got.append(c) }
        #expect(got.sorted() == [6, 7, 8, 10, 11, 12], "3, 4 and 9 are records' CIDs; 5 would be …:05's MAC")
        let macs = Set(records.map(\.mac))
        #expect(got.allSatisfy { !macs.contains(Daemon.mac(forCID: $0)) })
        // Without the rule, the first new VM would have been node 1's twin.
        #expect(try CIDAllocator(range: 3...12).allocate() == 3)
    }

    @Test func aMACIsTheCIDsLowBytes() {
        #expect(Daemon.mac(forCID: 3) == "52:54:00:00:00:03")
        #expect(Daemon.mac(forCID: 0x01_02_03) == "52:54:00:01:02:03")
    }

    /// Through the daemon: VMs created after a "restart" (records it never
    /// leased) all have MACs and CIDs of their own.
    @Test func createdVMsNeverShareAMAC() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()          // CID 3, MAC …:09
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var two = Self.rec(cid: 4, mac: "52:54:00:00:00:04"); two.name = "k8s-r-2"
        try await d.registerForTesting(two)
        for i in 0..<6 {
            let r = await d.createVM(.object(["name": .string("idt-\(i)")]), boot: false)
            #expect(r.status == 201, "\(r.body)")
        }
        let recs = await d.registry.records
        #expect(Set(recs.map(\.mac)).count == recs.count, "no two VMs share a MAC: \(recs.map(\.mac))")
        #expect(Set(recs.map(\.cid)).count == recs.count)
        await d.shutdown()
    }
}
