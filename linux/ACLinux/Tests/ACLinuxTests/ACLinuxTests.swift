import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux

/// A tiny QMP server: greeting, `id` echo, one error command, one event.
final class FakeQMPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        send(context, #"{"QMP": {"version": {"qemu": {"major": 10, "minor": 2, "micro": 1}}, "capabilities": []}}"#)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        let msg = try! JSONDecoder().decode(JSONValue.self, from: Data(line.readableBytesView))
        let id = msg["id"]?.stringValue.map { #","id":"\#($0)""# } ?? ""
        switch msg["execute"]?.stringValue {
        case "query-status":
            send(context, #"{"return": {"status": "running", "running": true}\#(id)}"#)
        case "fail-me":
            send(context, #"{"error": {"class": "GenericError", "desc": "nope"}\#(id)}"#)
        case "emit":
            send(context, #"{"event": "STOP", "data": {}, "timestamp": {"seconds": 1700000000, "microseconds": 500000}}"#)
            send(context, #"{"return": {}\#(id)}"#)
        case "hang":
            break
        case "echo":
            send(context, #"{"return": \#(String(decoding: try! JSONEncoder().encode(msg["arguments"] ?? .null), as: UTF8.self))\#(id)}"#)
        default:
            send(context, #"{"return": {}\#(id)}"#)
        }
    }

    private func send(_ context: ChannelHandlerContext, _ s: String) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: s + "\r\n")), promise: nil)
    }
}

func shortTempDir() throws -> String {
    let d = "/tmp/acl-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

@Suite("QMP client")
struct QMPClientTests {
    func withServer(_ body: (String) async throws -> Void) async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/qmp.sock"
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder()))
                    try ch.pipeline.syncOperations.addHandler(FakeQMPHandler())
                }
            }
            .bind(unixDomainSocketPath: path).get()
        do { try await body(path) } catch { try? await server.close(); throw error }
        try await server.close()
    }

    @Test("greeting, capabilities, typed replies, errors, events and timeouts")
    func roundTrip() async throws {
        try await withServer { path in
            let qmp = try await QMPClient.connect(socketPath: path)
            #expect(await qmp.version["qemu"]?["major"] == 10)

            struct Status: Decodable { let status: String; let running: Bool }
            let st = try await qmp.execute("query-status", as: Status.self)
            #expect(st.status == "running" && st.running)

            let echoed = try await qmp.execute("echo", arguments: ["a": 1, "b": "x", "c": [true, .null]])
            #expect(echoed == ["a": 1, "b": "x", "c": [true, .null]])

            await #expect(throws: QMPError.commandFailed(command: "fail-me", errorClass: "GenericError", description: "nope")) {
                try await qmp.execute("fail-me")
            }

            try await qmp.execute("emit")
            var it = qmp.events.makeAsyncIterator()
            let ev = await it.next()
            #expect(ev?.name == "STOP")
            #expect(ev?.timestamp == 1_700_000_000.5)

            await #expect(throws: QMPError.timeout("hang")) {
                try await qmp.execute("hang", timeout: .milliseconds(100))
            }
            // Still usable after a timeout.
            _ = try await qmp.execute("query-status")
            await qmp.close()
            await #expect(throws: QMPError.disconnected) { try await qmp.execute("query-status") }
        }
    }

    @Test("connect fails cleanly when nothing listens")
    func noServer() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await QMPClient.connect(socketPath: "/tmp/acl-nonexistent-\(UUID().uuidString.prefix(6)).sock")
        }
    }
}

@Suite("QEMU machine config")
struct ConfigTests {
    func config(_ m: QEMUMachineConfig.MachineType) -> QEMUMachineConfig {
        var c = QEMUMachineConfig(name: "ws1", kernel: "/img/vmlinuz", initrd: "/img/initrd.img",
                                  cmdline: "console=ttyS0 root=LABEL=root", baseImage: "/img/base.img",
                                  overlay: "/vm/disk.qcow2", vsockCID: 42, runDirectory: "/run/acl/ws1")
        c.machine = m
        c.cpus = 4
        c.memoryMiB = 4096
        c.shares = [.init(tag: "bromure-meta", hostPath: "/vm/meta", readOnly: true),
                    .init(tag: "bromure-outbox", hostPath: "/vm/outbox")]
        c.network = .stream(socketPath: "/run/acl/ws1/net.sock")
        c.macAddress = "52:54:00:00:00:2a"
        return c
    }

    func pairs(_ a: [String]) -> [String] { zip(a, a.dropFirst()).map { "\($0) \($1)" } }

    @Test("q35 argv: KVM, memfd RAM, direct boot, overlay, virtiofs, stream net, vsock, QMP")
    func q35() throws {
        let c = config(.q35)
        try c.validate()
        let p = pairs(c.arguments())
        for expected in [
            "-machine q35,accel=kvm", "-cpu host", "-smp 4", "-m 4096M",
            "-object memory-backend-memfd,id=mem,size=4096M,share=on", "-numa node,memdev=mem",
            "-kernel /img/vmlinuz", "-initrd /img/initrd.img", "-append console=ttyS0 root=LABEL=root",
            "-drive if=none,id=d0,file=/vm/disk.qcow2,format=qcow2,cache=none,aio=io_uring,discard=unmap",
            "-device virtio-blk-pci,drive=d0",
            "-chardev socket,id=fs0,path=/run/acl/ws1/fs0.sock",
            "-device vhost-user-fs-pci,chardev=fs0,tag=bromure-meta",
            "-device vhost-user-fs-pci,chardev=fs1,tag=bromure-outbox",
            "-netdev stream,id=n0,server=off,addr.type=unix,addr.path=/run/acl/ws1/net.sock",
            "-device virtio-net-pci,netdev=n0,mac=52:54:00:00:00:2a",
            "-device vhost-vsock-pci,guest-cid=42",
            "-qmp unix:/run/acl/ws1/qmp.sock,server=on,wait=off",
            "-run-with exit-with-parent=on",
        ] { #expect(p.contains(expected), "missing: \(expected)") }
        #expect(!c.arguments().contains("-incoming"))
        #expect(pairs(c.arguments(incoming: true)).contains("-incoming defer"))
        #expect(c.virtiofsdArguments(0).contains("--readonly"))
        #expect(!c.virtiofsdArguments(1).contains("--readonly"))
    }

    @Test("microvm uses virtio-mmio devices")
    func microvm() {
        let a = config(.microvm).arguments()
        #expect(a.contains("virtio-blk-device,drive=d0"))
        #expect(a.contains("vhost-vsock-device,guest-cid=42"))
        #expect(!a.joined(separator: " ").contains("-pci"))
    }

    @Test("socket paths over 107 bytes and duplicate tags are rejected")
    func validation() {
        var c = config(.q35)
        c.qmpSocketPath = "/" + String(repeating: "x", count: 120)
        #expect(throws: MachineError.self) { try c.validate() }
        c = config(.q35)
        c.shares.append(.init(tag: "bromure-meta", hostPath: "/x"))
        #expect(throws: MachineError.invalidConfig("duplicate share tag")) { try c.validate() }
    }
}

@Suite("CID allocation")
struct CIDTests {
    @Test("skips host-taken CIDs and this process's leases; reuses released ones on wrap")
    func allocation() throws {
        let a = CIDAllocator(range: 3...8, probe: { $0 == 4 || $0 == 6 ? .inUse : .free })
        #expect(try a.allocate() == 3)
        #expect(try a.allocate() == 5)
        #expect(try a.allocate() == 7)
        #expect(try a.allocate() == 8)
        #expect(throws: CIDError.self) { try a.allocate() }
        a.release(5)
        #expect(try a.allocate() == 5)
    }

    @Test("an unavailable probe falls back to in-process leases")
    func unavailableProbe() throws {
        let a = CIDAllocator(range: 3...4, probe: { _ in .unavailable(errno: EACCES) })
        #expect(try a.allocate() == 3)
        #expect(try a.allocate() == 4)
    }

    @Test("the vhost probe answers on this host when /dev/vhost-vsock is usable")
    func vhostProbe() throws {
        guard access("/dev/vhost-vsock", R_OK | W_OK) == 0 else { return }
        #expect(CIDAllocator.vhostProbe(0xFFFF_FFF0) == .free)
    }
}

@Suite("Snapshot identity")
struct SnapshotTests {
    @Test("a state verifies against its overlay and is refused once the overlay changes")
    func pairing() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let overlay = dir + "/disk.qcow2", state = dir + "/state"
        try Data(repeating: 7, count: 100_000).write(to: URL(fileURLWithPath: overlay))
        try SnapshotIdentity.of(overlay: overlay).write(forState: state)
        try SnapshotIdentity.verify(state: state, overlay: overlay)

        let h = FileHandle(forWritingAtPath: overlay)!
        h.seek(toFileOffset: 10)
        h.write(Data([1]))
        try h.close()
        #expect(throws: MachineError.snapshotMismatch(state: state, overlay: overlay)) {
            try SnapshotIdentity.verify(state: state, overlay: overlay)
        }
        #expect(throws: MachineError.self) { try SnapshotIdentity.verify(state: dir + "/none", overlay: overlay) }
    }
}
