import Foundation
import NIOCore
import Testing
import ACLinux

/// Boots linux/bake's amd64 image under KVM with QEMUMachine. Skipped unless
/// /dev/kvm and /dev/vhost-vsock are usable and the image exists
/// (BROMURE_AC_IMAGE, default ~/.local/share/bromure-ac/image-amd64).
enum Env {
    static let image = ProcessInfo.processInfo.environment["BROMURE_AC_IMAGE"]
        ?? NSHomeDirectory() + "/.local/share/bromure-ac/image-amd64"
    static let agentd = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py").path
    static var ready: Bool {
        access("/dev/kvm", R_OK | W_OK) == 0 && access("/dev/vhost-vsock", R_OK | W_OK) == 0
            && FileManager.default.fileExists(atPath: image + "/vmlinuz")
            && FileManager.default.fileExists(atPath: agentd)
    }
}

/// bromure-agentd's shell pool dials host CID 2 port 5800.
let agentPort: UInt32 = 5800

func ms(_ d: Duration) -> String {
    String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

/// The next connection from `stream`, or nil after `timeout`.
func next(_ stream: AsyncStream<VsockConnection>, timeout: Duration) async -> VsockConnection? {
    await withTaskGroup(of: VsockConnection?.self) { g in
        g.addTask { var it = stream.makeAsyncIterator(); return await it.next() }
        g.addTask { try? await Task.sleep(for: timeout); return nil }
        let r = await g.next() ?? nil
        g.cancelAll()
        return r
    }
}

@Suite("QEMUMachine boots the baked image", .serialized, .enabled(if: Env.ready))
struct BootTests {
    /// One VM's files: overlay, meta (agentd), outbox; sockets in a short /tmp dir.
    struct Workspace {
        let dir: String
        let cid: UInt32
        var config: QEMUMachineConfig

        init(machine: QEMUMachineConfig.MachineType) throws {
            dir = "/tmp/acl-it-\(UUID().uuidString.prefix(8))"
            for sub in ["meta/virtiofs-tags", "outbox", "run"] {
                try FileManager.default.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(atPath: Env.agentd, toPath: "\(dir)/meta/bromure-agentd.py")
            for tag in ["bromure-meta", "bromure-outbox"] {
                _ = FileManager.default.createFile(atPath: "\(dir)/meta/virtiofs-tags/\(tag)", contents: nil)
            }
            cid = try CIDAllocator.shared.allocate()
            config = try QEMUMachineConfig(name: "acl-it-\(cid)", bakedImage: Env.image,
                                           overlay: "\(dir)/disk.qcow2", vsockCID: cid,
                                           runDirectory: "\(dir)/run")
            config.machine = machine
            config.shares = [.init(tag: "bromure-meta", hostPath: "\(dir)/meta"),
                             .init(tag: "bromure-outbox", hostPath: "\(dir)/outbox")]
            // A link up front: without one, agentd's docker restart waits out
            // network-online (120 s) before the shell pool starts.
            config.network = .user
        }

        func cleanUp() {
            CIDAllocator.shared.release(cid)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    @Test("boot -> agentd dials 5800 -> host dials guest -> suspend -> restore -> dials again -> stop",
          arguments: [QEMUMachineConfig.MachineType.q35, .microvm])
    func lifecycle(machine: QEMUMachineConfig.MachineType) async throws {
        let ws = try Workspace(machine: machine)
        defer { ws.cleanUp() }
        let listener = try await VsockListener.shared(port: agentPort)
        defer { Task { await listener.forget(cid: ws.cid) } }
        let label = "[\(machine.rawValue) cid \(ws.cid)]"

        // 1. Cold boot until agentd's first dial.
        var conns = await listener.connections(from: ws.cid)
        let vm = QEMUMachine(config: ws.config)
        let stopped = StopRecorder()
        await vm.setOnStopped { stopped.record($0) }
        let t0 = ContinuousClock.now
        try await vm.start()
        let tQMP = ContinuousClock.now - t0
        let first = await next(conns, timeout: .seconds(60))
        let tBoot = ContinuousClock.now - t0
        try #require(first != nil, "\(label) agentd never dialed host :\(agentPort)")
        #expect(first?.peer.cid.rawValue == ws.cid)
        print("TIMING \(label) cold boot: QMP up \(ms(tQMP)), agentd dial on :\(agentPort) \(ms(tBoot))")

        // 2. Host -> guest: agentd's loopback relay listens on vsock 5010
        // (a supervised service, started after the session setup).
        var out: VsockConnection?
        while out == nil, ContinuousClock.now - t0 < .seconds(60) {
            out = try? await VsockConnection.connect(cid: ws.cid, port: 5010)
            if out == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(out != nil, "\(label) guest never listened on vsock 5010")
        #expect(out?.peer.cid.rawValue == ws.cid)
        await out?.close()
        print("TIMING \(label) host dial to guest :5010 accepted at \(ms(ContinuousClock.now - t0))")

        // 3. Suspend (mapped-ram) — the VM ends stopped(.suspended).
        let agentLog = ws.dir + "/outbox/agentd.log"
        func logSize() -> UInt64 {
            (try? FileManager.default.attributesOfItem(atPath: agentLog)[.size] as? UInt64) ?? 0
        }
        let sizeBefore = logSize()
        #expect(sizeBefore > 0, "\(label) agentd wrote nothing to the outbox share before suspend")
        let state = ws.dir + "/vm.state"
        let s = try await vm.suspend(to: state)
        guard case .stopped(let sInfo) = await vm.state else { Issue.record("\(label) not stopped after suspend"); return }
        #expect(sInfo.reason == .suspended(state) && sInfo.exitStatus == 0)
        #expect(stopped.infos.map(\.reason) == [.suspended(state)])
        print("TIMING \(label) suspend: save \(ms(s.save)), until QEMU exit \(ms(s.total)), state file \(s.stateBytes / 1_048_576) MiB apparent (sparse)")

        // 4. Restore into a fresh QEMUMachine; agentd re-dials (the vsock
        // transport resets on migration, so its pool reconnects).
        conns = await listener.connections(from: ws.cid)
        let vm2 = QEMUMachine(config: ws.config)
        let t1 = ContinuousClock.now
        let r = try await vm2.restore(from: state)
        let again = await next(conns, timeout: .seconds(30))
        let tRedial = ContinuousClock.now - t1
        try #require(again != nil, "\(label) agentd did not dial again after restore")
        print("TIMING \(label) restore: launch \(ms(r.launch)), load \(ms(r.load)), through cont \(ms(r.total)), agentd re-dial \(ms(tRedial))")

        // The restored guest still has its virtiofs: agentd keeps appending
        // to outbox/agentd.log, as the host user.
        var grown = false
        for _ in 0..<100 where !grown {
            grown = logSize() > sizeBefore
            if !grown { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(grown, "\(label) no outbox writes after restore")
        let owner = try FileManager.default.attributesOfItem(atPath: agentLog)[.ownerAccountID] as? Int
        #expect(owner.map { UInt32($0) } == getuid(), "\(label) outbox file not owned by the host user")

        // 5. The state belongs to the overlay as it was: once the restored
        // guest has run, the same state is refused.
        let t2 = ContinuousClock.now
        let info = await vm2.stop(timeout: .seconds(30))
        print("TIMING \(label) stop (ACPI powerdown): \(ms(ContinuousClock.now - t2)), exit \(info.exitStatus)")
        #expect(info.reason == .stopped)
        let vm3 = QEMUMachine(config: ws.config)
        await #expect(throws: MachineError.snapshotMismatch(state: state, overlay: ws.config.overlay)) {
            try await vm3.restore(from: state)
        }
    }

    @Test("kill() reports .killed, and a CID clash fails start with QEMU's error")
    func killAndClash() async throws {
        let ws = try Workspace(machine: .microvm)
        defer { ws.cleanUp() }
        let vm = QEMUMachine(config: ws.config)
        try await vm.start()
        // Same CID while the first VM holds it: QEMU refuses to start.
        let ws2 = try Workspace(machine: .microvm)
        defer { ws2.cleanUp() }
        var clash = ws2.config
        clash.vsockCID = ws.cid
        let vm2 = QEMUMachine(config: clash)
        await #expect(throws: MachineError.self) { try await vm2.start() }
        // And the allocator's probe sees it taken.
        #expect(CIDAllocator.vhostProbe(ws.cid) == .inUse)
        let info = await vm.kill()
        #expect(info.reason == .killed)
    }
}

final class StopRecorder: Sendable {
    private let box = NIOLockedValueBoxShim<[QEMUMachine.StopInfo]>([])
    func record(_ i: QEMUMachine.StopInfo) { box.mutate { $0.append(i) } }
    var infos: [QEMUMachine.StopInfo] { box.value }
}

/// A tiny lock box (the test target doesn't link NIOConcurrencyHelpers).
final class NIOLockedValueBoxShim<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
