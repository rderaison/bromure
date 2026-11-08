import Foundation
import Testing
@testable import bromure_ac

/// A panic on a Mac starting five workspaces at once: the APFS container's
/// transaction flusher, every VM's disk threads and logd waited two minutes on
/// one event, and the app's main thread hung reading the guest outbox.
@Suite("Starting many VMs goes easy on the disk", .serialized)
struct APFSCalmTests {
    private static let top = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.top.appendingPathComponent(path), encoding: .utf8)
    }
    private func body(of signature: String, in src: String) throws -> Substring {
        let r = try #require(src.range(of: signature))
        let rest = src[r.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("calm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: The start gate

    @MainActor final class Box { var order: [Int] = [] }

    @Test("no more starts at once than the limit, and the next goes when one is done")
    @MainActor func gateLimits() async throws {
        let gate = VMStartGate(limit: 2)
        await gate.acquire(); await gate.acquire()
        #expect(gate.inUse == 2)
        let box = Box()
        // Waits on the gate's own state, not a sleep: under a full suite the
        // main actor can be busy for seconds.
        func waitFor(_ n: Int) async throws {
            for _ in 0..<600 where gate.waiting < n { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let third = Task { @MainActor in await gate.acquire(); box.order.append(3) }
        try await waitFor(1)   // the fourth queues after the third
        let fourth = Task { @MainActor in await gate.acquire(); box.order.append(4) }
        try await waitFor(2)
        #expect(box.order.isEmpty && gate.waiting == 2)
        gate.release()
        await third.value
        #expect(box.order == [3] && gate.inUse == 2)
        gate.release()
        await fourth.value
        #expect(box.order == [3, 4])
        gate.release(); gate.release()
        #expect(gate.inUse == 0 && gate.waiting == 0)
    }

    @Test("a slot held until settled goes when it settles, or at the cap")
    @MainActor func gateSettles() async throws {
        let gate = VMStartGate(limit: 1)
        await gate.acquire()
        let flag = SettleFlag()
        gate.release(whenSettled: { flag.value }, cap: 30)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(gate.inUse == 1)
        flag.value = true
        for _ in 0..<40 where gate.inUse != 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(gate.inUse == 0)

        await gate.acquire()
        gate.release(whenSettled: { false }, cap: 0.2)
        for _ in 0..<40 where gate.inUse != 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(gate.inUse == 0)
    }

    final class SettleFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    @Test("a guest is up once it writes ip.txt after its start, not before")
    func addressSignal() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ip = dir.appendingPathComponent("ip.txt")
        try "10.0.0.2".write(to: ip, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: ip.path)
        let began = Date(timeIntervalSinceNow: -1)
        #expect(!VMStartGate.guestReportedAddress(outbox: dir, since: began))   // the last boot's
        try "10.0.0.3".write(to: ip, atomically: true, encoding: .utf8)
        #expect(VMStartGate.guestReportedAddress(outbox: dir, since: began))
        #expect(!VMStartGate.guestReportedAddress(outbox: dir.appendingPathComponent("none"), since: began))
    }

    @Test("a boot and a restore both take a slot, and give it back when they fail")
    func startAndRestoreUseTheGate() throws {
        let src = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        let start = try body(of: "public func start() async throws {", in: src)
        #expect(start.contains("await gate.acquire()"))
        #expect(start.contains("do { try await vm.start() } catch { gate.release(); throw error }"))
        #expect(start.contains("gate.release(whenSettled:"))
        let restore = try body(of: "public func restore() async throws {", in: src)
        #expect(restore.contains("await gate.acquire()"))
        #expect(restore.contains("do { try await vm.restoreMachineStateFrom(url: stateURL) } catch { gate.release(); throw error }"))
        #expect(restore.contains("do { try await vm.resume() } catch { gate.release(); throw error }"))
        #expect(restore.contains("cap: VMStartGate.restoreSettle"))
    }

    // MARK: Disk flushes

    @Test("a workspace's disks flush with fsync, not a full sync")
    func disksUseFsync() throws {
        let src = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        #expect(src.contains("synchronizationMode: .fsync"))
        // Every writable disk goes through the one helper.
        #expect(!src.contains("VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)"))
        #expect(!src.contains("VZDiskImageStorageDeviceAttachment(\n            url: bootDiskURL"))
        #expect(src.contains("try Self.diskAttachment(bootDiskURL)"))
        #expect(src.contains("try Self.diskAttachment(session.homeImageURL)"))
    }

    // MARK: The outbox, off the main thread

    @Test("the outbox poll reads no file on the main actor")
    func pollerOffMain() throws {
        let src = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        let poll = try body(of: "private func startOutboxPolling() {", in: src)
        #expect(poll.contains("await scanner.tick()"))
        for io in ["FileManager", "boundedText", "removeItem", "contentsOfDirectory", "attributesOfItem"] {
            #expect(!poll.contains(io), "\(io) in the main-actor poll")
        }
    }

    @Test("a scan off the main thread finds what the guest wrote, and consumes the one-shots")
    @MainActor func scannerFinds() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try put("reboot-intent", "")
        try put("ip.txt", "192.168.64.7\n")
        try put("url-1.txt", "https://example.com/login")
        try put("url-2.txt", "file:///etc/passwd")
        try put("agent-status-3.txt", "working")
        try put("tabs.txt", "0\t1\tshell\t-\n")
        try put("ports.txt", "tcp LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*\n")

        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var reboots = 0, ips: [String] = [], urls: [URL] = [], statuses: [(Int, String)] = []
        var tabs = 0, ports: [[ListeningPort]] = []
        vm.onGuestReboot = { reboots += 1 }
        vm.onIPUpdate = { ips.append($0) }
        vm.onURLOpen = { urls.append($0) }
        vm.onAgentStatus = { statuses.append(($0, $1)) }
        vm.onTabList = { _ in tabs += 1 }
        vm.onPortsList = { ports.append($0) }

        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        for _ in 0..<24 {   // two heavy ticks
            for apply in await scanner.tick().all { apply(vm) }
        }
        #expect(reboots == 1 && tabs == 1)
        #expect(ips == ["192.168.64.7"])           // reported once, though read twice
        #expect(urls == [URL(string: "https://example.com/login")!])
        #expect(statuses.count == 1 && statuses.first?.0 == 3 && statuses.first?.1 == "working")
        #expect(ports.count == 1 && ports.first?.first?.port == 8080)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["ip.txt", "tabs.txt", "ports.txt"])
    }

    /// The finding (CWE-367): a relaunch cancelled the poll task, but a tick
    /// already queued on the outbox's queue still ran: it removed one-shot
    /// files the new guest wrote (reboot-intent, a URL to open, the home's
    /// migration mark), and its events were applied anyway, to the outgoing
    /// sandbox, whose callbacks reach the workspace's new session.
    @Test("a cancelled scanner's tick, queued or not, consumes nothing; a cancelled poll applies nothing")
    func cancelledScannerConsumesNothing() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String) throws { try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try put("reboot-intent"); try put("url-1.txt")
        // Cancelled before it ticks.
        let old = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        old.cancel()
        #expect(await old.tick().all.isEmpty)
        // Queued behind a stalled tick, then cancelled before its turn.
        let stalled = DispatchSemaphore(value: 0)
        let q = UbuntuSandboxVM.OutboxScanner.queue(for: dir)
        q.async { stalled.wait() }
        let queuedScanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        async let queued = queuedScanner.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        queuedScanner.cancel()
        stalled.signal()
        #expect(await queued.all.isEmpty)
        // The next guest's one-shots are still there, for the new scanner.
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left.isSuperset(of: ["reboot-intent", "url-1.txt"]))
        let fresh = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        #expect(!(await fresh.tick()).all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("reboot-intent").path))
        // The poll: a tick that finished after the cancel isn't applied, and
        // every stop goes through the one that cancels the scanner too.
        let src = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        let poll = try body(of: "private func startOutboxPolling() {", in: src)
        #expect(poll.contains("guard !Task.isCancelled, !scanner.isCancelled else {"))
        #expect(src.components(separatedBy: "outboxPollTask?.cancel()").count - 1 == 1)   // only in cancelOutboxPoll
        #expect(src.components(separatedBy: "cancelOutboxPoll()").count - 1 >= 6)
    }

    /// The finding (CWE-367): a scan removed a one-shot file (reboot-intent,
    /// home-migrated.txt) and the poll was cancelled before its events were
    /// applied: the guard dropped them all, the file already gone. The host
    /// never stamped the migrated home, or took a guest reboot for a
    /// shutdown. What a removed one-shot said is applied even when
    /// cancelled; a stop waits for the last tick before it decides.
    @Test("a cancelled poll still applies the one-shots its last tick removed; a stop waits for it")
    @MainActor
    func cancelledPollKeepsRemovedOneShots() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String, _ body: String) throws {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try put("reboot-intent", "")
        try put("home-migrated.txt", "ok")
        try put("agent-status-2.txt", "idle")
        try put("ip.txt", "192.168.64.9")
        try put("tabs.txt", "0\t1\tshell\t-\n")
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var reboots = 0, migrated = 0, statuses = 0, ips = 0, tabs = 0
        vm.onGuestReboot = { reboots += 1 }
        vm.onHomeMigrated = { migrated += 1 }
        vm.onAgentStatus = { _, _ in statuses += 1 }
        vm.onIPUpdate = { _ in ips += 1 }
        vm.onTabList = { _ in tabs += 1 }
        // A heavy tick's worth: the one-shots are marked as such; the reads
        // (roster, IP) aren't, so a cancelled poll leaves them out.
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        var all = 0
        for _ in 0..<12 {
            let found = await scanner.tick()
            all += found.all.count
            for apply in found.oneShots { apply(vm) }
        }
        #expect(reboots == 1 && migrated == 1 && statuses == 1)
        #expect(ips == 0 && tabs == 0)
        #expect(all > 3)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["ip.txt", "tabs.txt"])

        // settle: back when the task is, or after the bound, whichever first.
        var t0 = Date()
        await UbuntuSandboxVM.settle(Task { _ = try? await Task.sleep(nanoseconds: 50_000_000) }, within: 5)
        #expect(Date().timeIntervalSince(t0) < 2)
        t0 = Date()
        let long = Task { _ = try? await Task.sleep(nanoseconds: 20_000_000_000) }
        await UbuntuSandboxVM.settle(long, within: 0.2)
        #expect(Date().timeIntervalSince(t0) < 3)
        long.cancel()
        await UbuntuSandboxVM.settle(nil, within: 5)

        // Wired: the cancelled poll applies the removed one-shots; a scan a
        // cancel stops keeps what it took; the guest's stop settles the last
        // tick before onStopped decides reboot or shutdown.
        let src = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        let poll = try body(of: "private func startOutboxPolling() {", in: src)
        let cancelled = try #require(poll.range(of: "guard !Task.isCancelled, !scanner.isCancelled else {"))
        #expect(poll[cancelled.upperBound...].prefix(120).contains("for apply in found.oneShots { apply(self) }"))
        let scan = try #require(src.range(of: "private func scan() -> Found {"))
        let scanBody = src[scan.upperBound...].prefix(30_000)
        let scanEnd = scanBody.range(of: "\n        }\n")?.lowerBound ?? scanBody.endIndex
        #expect(!scanBody[..<scanEnd].contains("return []"))
        for marker in ["oneShot { $0.onGuestReboot?() }", "oneShot { $0.onHomeMigrated?() }", "oneShot { $0.onURLOpen?(url) }"] {
            #expect(scanBody[..<scanEnd].contains(marker), "\(marker)")
        }
        let stop = try body(of: "public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {", in: src)
        let settle = try #require(stop.range(of: "await Self.settle(self.cancelOutboxPoll(), within: 2)"))
        let stopped = try #require(stop.range(of: "self.onStopped?(nil)"))
        #expect(settle.lowerBound < stopped.lowerBound)
    }

    @Test("two scanners of one outbox share a queue, so a relaunch's waits behind the old tick")
    func scannersShareAQueue() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let other = try tempDir(); defer { try? FileManager.default.removeItem(at: other) }
        let q = UbuntuSandboxVM.OutboxScanner.queue(for: dir)
        #expect(q === UbuntuSandboxVM.OutboxScanner.queue(for: dir.appendingPathComponent(".").standardizedFileURL))
        #expect(q !== UbuntuSandboxVM.OutboxScanner.queue(for: other))
    }

    // MARK: BROMURE_NO_REAPER

    @Test("BROMURE_NO_REAPER=1, and only that, turns the reaper off")
    func reaperSwitch() {
        #expect(CheckpointReaper.enabled(in: [:]))
        #expect(CheckpointReaper.enabled(in: ["BROMURE_NO_REAPER": "0"]))
        #expect(!CheckpointReaper.enabled(in: ["BROMURE_NO_REAPER": "1"]))
    }

    @Test("with the reaper off, a snapshot prunes nothing and sweeps nothing")
    func reaperOffKeepsAll() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let off = CheckpointReaper(step: 4096, stepPause: 0, filePause: 0, enabled: false)
        let store = ProfileStore(rootDir: root, reaper: off)
        let profile = Profile(name: "keep", tool: .claude, authMode: .token)
        let disk = store.diskURL(for: profile)
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 16_384).write(to: disk)
        let dir = store.checkpointsDirectory(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let leftover = dir.appendingPathComponent("1.img.deleting")
        try Data(repeating: 1, count: 4096).write(to: leftover)
        let now = Date()
        for weeks in 20...24 {
            _ = try store.snapshotDisk(for: profile, at: now.addingTimeInterval(-Double(weeks) * 7 * 86_400))
        }
        _ = try store.snapshotDisk(for: profile, at: now)
        #expect(!store.pruneCheckpoints(for: profile, now: now))
        off.drain()
        #expect(store.listCheckpoints(for: profile).count == 6)
        #expect(FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("with the reaper off, a session start takes no checkpoint")
    func noSessionStartCheckpoint() throws {
        let src = try source("Sources/AgentCoding/BromureAC.swift")
        let guardAt = try #require(src.range(of: "guard CheckpointReaper.shared.enabled else {"))
        let snap = try #require(src.range(of: "self.store.takeSessionStartCheckpoints(for: profile)"))
        #expect(guardAt.lowerBound < snap.lowerBound)
        #expect(src[guardAt.upperBound..<snap.lowerBound].contains("return"))
        #expect(src[guardAt.upperBound..<snap.lowerBound].count < 400)
    }
}
