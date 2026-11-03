import Foundation
import NIOCore
import Testing
import ACLinux

/// Boots linux/bake's amd64 image under Firecracker/KVM. Skipped unless
/// /dev/kvm is usable and the image, agentd and Firecracker exist
/// (BROMURE_AC_IMAGE, default ~/.local/share/bromure-ac/image-amd64).
enum Env {
    static let image = ProcessInfo.processInfo.environment["BROMURE_AC_IMAGE"]
        ?? NSHomeDirectory() + "/.local/share/bromure-ac/image-amd64"
    static let agentd = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py").path
    static var ready: Bool {
        access("/dev/kvm", R_OK | W_OK) == 0
            && FileManager.default.fileExists(atPath: image + "/vmlinuz")
            && FileManager.default.fileExists(atPath: agentd)
            && FileManager.default.isExecutableFile(atPath: MachineConfig.defaultFirecrackerBinary)
    }
}

/// bromure-agentd's shell pool dials host CID 2 port 5800.
let agentPort: UInt32 = 5800

func ms(_ d: Duration) -> String {
    String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

/// Connections from one listener, drained by a single long-lived consumer.
/// Waiting with a timeout must not cancel a task blocked in the stream's
/// iterator: cancelling a pending `next()` finishes an AsyncStream for good,
/// and every later wait would come back empty.
actor ConnQueue {
    private var buffer: [VsockConnection] = []
    private var waiters: [Int: CheckedContinuation<VsockConnection?, Never>] = [:]
    private var nextWaiter = 0
    private var finished = false

    init(_ stream: AsyncStream<VsockConnection>) {
        Task { [weak self] in
            for await c in stream { await self?.push(c) }
            await self?.finish()
        }
    }

    private func push(_ c: VsockConnection) {
        if let (id, w) = waiters.min(by: { $0.key < $1.key }) {
            waiters.removeValue(forKey: id)
            w.resume(returning: c)
        } else {
            buffer.append(c)
        }
    }

    private func finish() {
        finished = true
        for w in waiters.values { w.resume(returning: nil) }
        waiters = [:]
    }

    private func expire(_ id: Int) { waiters.removeValue(forKey: id)?.resume(returning: nil) }

    /// The next connection, or nil after `timeout` (or once the stream ended).
    func take(timeout: Duration) async -> VsockConnection? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { return nil }
        nextWaiter += 1
        let id = nextWaiter
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }
}

func next(_ q: ConnQueue, timeout: Duration) async -> VsockConnection? {
    await q.take(timeout: timeout)
}

/// One VM's files and its network: overlay, meta (agentd), outbox, a short
/// run dir for the sockets; passt behind an interim switch on a datagram
/// port (agentd's docker restart waits out network-online without a link).
struct Workspace {
    let dir: String
    let cid: UInt32
    var config: MachineConfig
    /// Its own network (the boot tests'); nil when a test's switch provides it.
    let passt: PasstUplink?
    let sw: InterimSwitch?
    let port: DgramPort?

    /// The image's cmdline without `quiet`, with systemd's unit status and
    /// kernel timestamps on the serial console.
    static func diagnosableCmdline(_ c: String) -> String {
        (c.split(separator: " ").filter { $0 != "quiet" }.map(String.init)
         + ["systemd.show_status=1", "printk.time=1"]).joined(separator: " ")
    }

    init(ownNetwork: Bool = true) async throws {
        dir = "/tmp/acl-it-\(UUID().uuidString.prefix(8))"
        for sub in ["meta/virtiofs-tags", "outbox", "run"] {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(atPath: Env.agentd, toPath: "\(dir)/meta/bromure-agentd.py")
        for tag in ["bromure-meta", "bromure-outbox"] {
            _ = FileManager.default.createFile(atPath: "\(dir)/meta/virtiofs-tags/\(tag)", contents: nil)
        }
        cid = try CIDAllocator.shared.allocate()
        config = try MachineConfig(name: "acl-it-\(cid)", bakedImage: Env.image, overlay: "\(dir)/disk.raw",
                                   vsockCID: cid, runDirectory: "\(dir)/run")
        config.cmdline = Self.diagnosableCmdline(config.cmdline)
        config.shares = [.init(tag: "bromure-meta", hostPath: "\(dir)/meta", readOnly: true),
                         .init(tag: "bromure-outbox", hostPath: "\(dir)/outbox")]
        config.macAddress = String(format: "52:54:00:%02x:%02x:%02x", cid >> 16 & 0xFF, cid >> 8 & 0xFF, cid & 0xFF)
        guard ownNetwork else { passt = nil; sw = nil; port = nil; return }
        let up = try await PasstUplink.start(PasstUplink.Config(logPath: "\(dir)/passt.log"))
        let s = InterimSwitch(uplink: up)
        let (p, peer) = try DgramPort.pair(name: "it-\(cid)")
        s.attach(p, mac: config.macAddress!)
        config.network = .datagram(peerFD: peer)
        passt = up; sw = s; port = p
    }

    func cleanUp() async {
        sw?.detach(mac: config.macAddress!)
        port?.close()
        sw?.stop()
        await passt?.close()
        CIDAllocator.shared.release(cid)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

@Suite("FirecrackerMachine boots the baked image", .serialized, .enabled(if: Env.ready))
struct BootTests {
    @Test("boot -> agentd dials 5800 -> host dials guest :5010 -> outbox writes as the host user -> stop")
    func lifecycle() async throws {
        let ws = try await Workspace()
        let label = "[cid \(ws.cid)]"
        let listener = try await HybridVsockListener.listen(udsPath: ws.config.firecrackerVsockPath, port: agentPort, cid: ws.cid)
        let conns = ConnQueue(listener.connections)
        let vm = FirecrackerMachine(config: ws.config)
        let stopped = StopRecorder()
        await vm.setOnStopped { stopped.record($0) }

        // 1. Cold boot until agentd's first dial.
        let t0 = ContinuousClock.now
        try await vm.start()
        let tAPI = ContinuousClock.now - t0
        let first = await next(conns, timeout: .seconds(60))
        let tBoot = ContinuousClock.now - t0
        #expect(first != nil, "\(label) agentd never dialed host :\(agentPort)")
        #expect(first?.peer.cid.rawValue == ws.cid)
        print("TIMING \(label) cold boot: API up \(ms(tAPI)), agentd dial on :\(agentPort) \(ms(tBoot))")

        // 2. Host -> guest: agentd's loopback relay listens on vsock 5010.
        var fd: Int32 = -1
        while fd < 0, ContinuousClock.now - t0 < .seconds(60) {
            fd = await ws.config.dialGuest(port: 5010)
            if fd < 0 { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(fd >= 0, "\(label) guest never listened on vsock 5010")
        if fd >= 0 { close(fd) }
        print("TIMING \(label) host dial to guest :5010 accepted at \(ms(ContinuousClock.now - t0))")

        // 3. virtiofs: agentd writes its log to the outbox share, as the host user.
        let agentLog = ws.dir + "/outbox/agentd.log"
        var size: UInt64 = 0
        for _ in 0..<100 where size == 0 {
            size = (try? FileManager.default.attributesOfItem(atPath: agentLog)[.size] as? UInt64) ?? 0
            if size == 0 { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(size > 0, "\(label) agentd wrote nothing to the outbox share")
        let owner = try? FileManager.default.attributesOfItem(atPath: agentLog)[.ownerAccountID] as? Int
        #expect(owner.map { UInt32($0) } == getuid(), "\(label) outbox file not owned by the host user")

        // 4. Stop: Ctrl-Alt-Del, the guest reboots, Firecracker (reboot=k) exits.
        let t2 = ContinuousClock.now
        let info = await vm.stop(timeout: .seconds(30))
        print("TIMING \(label) stop (Ctrl-Alt-Del): \(ms(ContinuousClock.now - t2)), exit \(info.exitStatus)")
        #expect(info.reason == .stopped)
        #expect(stopped.infos.map(\.reason) == [.stopped])
        await listener.close()
        await ws.cleanUp()
    }

    @Test("kill() reports .killed; a VM whose virtiofsd dies is taken down")
    func killAndVirtiofsd() async throws {
        let ws = try await Workspace()
        let vm = FirecrackerMachine(config: ws.config)
        try await vm.start()
        let info = await vm.kill()
        #expect(info.reason == .killed)
        await ws.cleanUp()

        let ws2 = try await Workspace()
        let vm2 = FirecrackerMachine(config: ws2.config)
        try await vm2.start()
        let pidFile = ws2.config.shareSocketPath(1) + ".pid"
        if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            Glibc.kill(pid, SIGKILL)
            let down = await vm2.waitUntilStopped()
            #expect(down.reason == .virtiofsdExited(tag: "bromure-outbox"))
        } else {
            Issue.record("no virtiofsd pid file at \(pidFile)")
            await vm2.kill()
        }
        await ws2.cleanUp()
    }
}

final class StopRecorder: Sendable {
    private let box = NIOLockedValueBoxShim<[FirecrackerMachine.StopInfo]>([])
    func record(_ i: FirecrackerMachine.StopInfo) { box.mutate { $0.append(i) } }
    var infos: [FirecrackerMachine.StopInfo] { box.value }
}

/// A tiny lock box (the test target doesn't link NIOConcurrencyHelpers).
final class NIOLockedValueBoxShim<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
