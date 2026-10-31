import Crypto
import Foundation
import CACLinuxShims
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
            "-netdev stream,id=n0,server=off,addr.type=unix,addr.path=/run/acl/ws1/net.sock,reconnect-ms=250",
            "-device virtio-net-pci,netdev=n0,mac=52:54:00:00:00:2a",
            "-device vhost-vsock-pci,guest-cid=42",
            "-chardev socket,id=qmp,path=/run/acl/ws1/qmp.sock,server=on,wait=off",
            "-mon chardev=qmp,mode=control",
            "-chardev file,id=ser0,path=/run/acl/ws1/serial.log", "-serial chardev:ser0",
            "-run-with exit-with-parent=on",
        ] { #expect(p.contains(expected), "missing: \(expected)") }
        #expect(!c.arguments().contains("-incoming"))
        #expect(pairs(c.arguments(incoming: true)).contains("-incoming defer"))
        #expect(c.virtiofsdArguments(0).contains("--readonly"))
        #expect(!c.virtiofsdArguments(1).contains("--readonly"))
    }

    @Test("commas in paths and tags are doubled inside option lists, not in -kernel/-append")
    func commaEscaping() {
        var c = QEMUMachineConfig(name: "ws", kernel: "/img,a/vmlinuz", initrd: nil,
                                  cmdline: "console=ttyS0,115200", baseImage: "/img,a/base.img",
                                  overlay: "/data,x/disk.qcow2", vsockCID: 3, runDirectory: "/run/a,b")
        c.shares = [.init(tag: "t,1", hostPath: "/h,p")]
        c.network = .stream(socketPath: "/run/a,b/net.sock")
        let p = pairs(c.arguments())
        for expected in [
            "-drive if=none,id=d0,file=/data,,x/disk.qcow2,format=qcow2,cache=none,aio=io_uring,discard=unmap",
            "-chardev socket,id=fs0,path=/run/a,,b/fs0.sock",
            "-device vhost-user-fs-pci,chardev=fs0,tag=t,,1",
            "-netdev stream,id=n0,server=off,addr.type=unix,addr.path=/run/a,,b/net.sock,reconnect-ms=250",
            "-chardev socket,id=qmp,path=/run/a,,b/qmp.sock,server=on,wait=off",
            "-chardev file,id=ser0,path=/run/a,,b/serial.log",
            "-kernel /img,a/vmlinuz", "-append console=ttyS0,115200",
        ] { #expect(p.contains(expected), "missing: \(expected)") }
        // virtiofsd gets plain argv.
        #expect(c.virtiofsdArguments(0).contains("/h,p"))
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

@Suite("Stream port framing")
struct StreamPortTests {
    /// A raw client standing in for QEMU: writes bytes, collects what it reads.
    final class RawPeer: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let got = AsyncStream<ByteBuffer>.makeStream()
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { got.continuation.yield(unwrapInboundIn(data)) }
    }

    func connect(_ path: String) async throws -> (Channel, RawPeer) {
        let peer = RawPeer()
        let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { c in c.eventLoop.makeCompletedFuture { try c.pipeline.syncOperations.addHandler(peer) } }
            .connect(unixDomainSocketPath: path).get()
        return (ch, peer)
    }

    func frame(_ n: Int, fill: UInt8) -> [UInt8] { [UInt8](repeating: fill, count: n) }
    func prefixed(_ b: [UInt8]) -> [UInt8] {
        [UInt8(b.count >> 24 & 0xFF), UInt8(b.count >> 16 & 0xFF), UInt8(b.count >> 8 & 0xFF), UInt8(b.count & 0xFF)] + b
    }

    @Test("frames split across writes, bad lengths skipped without desync, replies length-prefixed, reconnect replaces")
    func framing() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let port = try await StreamPort.listen(path: dir + "/net.sock")
        var frames = port.inbound.makeAsyncIterator()
        let (ch, peer) = try await connect(port.path)

        // A good frame in two pieces; then a too-short one (10 bytes) and an
        // over-long declared length whose bytes do follow; then a good frame.
        let a = prefixed(frame(60, fill: 0xAA))
        try await ch.writeAndFlush(ByteBuffer(bytes: a[0..<30])).get()
        try await ch.writeAndFlush(ByteBuffer(bytes: a[30...])).get()
        let bad1 = prefixed(frame(10, fill: 0x01))
        let bad2 = prefixed(frame(StreamPort.maxFrame + 1, fill: 0x02))
        let b = prefixed(frame(1514, fill: 0xBB))
        try await ch.writeAndFlush(ByteBuffer(bytes: bad1 + bad2 + b)).get()

        #expect(await frames.next() == Data(frame(60, fill: 0xAA)))
        #expect(await frames.next() == Data(frame(1514, fill: 0xBB)))
        #expect(port.dropped == 2)

        // Outbound: the port prepends the length.
        for _ in 0..<100 where !port.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        port.send(Data(frame(64, fill: 0xCC)))
        var acc = ByteBuffer()
        var it = peer.got.stream.makeAsyncIterator()
        while acc.readableBytes < 68, var c = await it.next() { acc.writeBuffer(&c) }
        #expect(acc.readableBytesView.elementsEqual(prefixed(frame(64, fill: 0xCC))))

        // QEMU reconnects (as after a restore): the new connection takes over.
        let (ch2, _) = try await connect(port.path)
        try await ch2.writeAndFlush(ByteBuffer(bytes: prefixed(frame(42, fill: 0xDD)))).get()
        #expect(await frames.next() == Data(frame(42, fill: 0xDD)))
        #expect(port.connects == 2)
        for _ in 0..<100 where ch.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!ch.isActive, "the replaced connection is closed")
        try await ch2.close()
        await port.close()
    }
}

@Suite("passt uplink", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/passt")))
struct PasstUplinkTests {
    @Test("passt answers ARP for the gateway on its MAC, and exits when we close")
    func arp() async throws {
        let up = try await PasstUplink.start(.init())
        let pid = try #require(up.pid)
        // who-has 192.168.64.1 tell 192.168.64.2, from 52:54:00:00:00:01
        let me: [UInt8] = [0x52, 0x54, 0, 0, 0, 1]
        let arp = Data([UInt8](repeating: 0xFF, count: 6) + me + [0x08, 0x06, 0, 1, 0x08, 0, 6, 4, 0, 1]
                       + me + [192, 168, 64, 2] + [UInt8](repeating: 0, count: 6) + [192, 168, 64, 1]
                       + [UInt8](repeating: 0, count: 18))
        up.send(arp)
        var it = up.inbound.makeAsyncIterator()
        var reply: [UInt8] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            guard let f = await it.next() else { break }
            let b = [UInt8](f)
            if b.count >= 42, b[12] == 0x08, b[13] == 0x06, b[21] == 2 { reply = b; break }
        }
        #expect(reply.count >= 42, "no ARP reply from passt")
        #expect(Array(reply[22..<28]) == [0x9a, 0x55, 0x9a, 0x55, 0x9a, 0x55])
        #expect(Array(reply[28..<32]) == [192, 168, 64, 1])
        await up.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(pid, 0) != 0, "passt still running after close")
    }
}

@Suite("Child process supervision")
struct ChildProcessTests {
    @Test("between a child's exit and its reaping, signal() only ever hits the zombie")
    func signalVersusReap() async throws {
        // Widen the window between "exited" and "recorded": if the pid were
        // reaped first (the old order), kill() in that window would find no
        // such process (ESRCH) -- or, worse, a recycled pid.
        ChildProcess.reapPauseForTesting.withLockedValue { $0 = 0.05 }
        defer { ChildProcess.reapPauseForTesting.withLockedValue { $0 = nil } }
        for _ in 0..<20 {
            let p = try ChildProcess(name: "true", executable: "/bin/true", arguments: [], logPath: nil)
            try p.start()
            let hammer = Task.detached { () -> (sent: Int, missed: Int) in
                var sent = 0, missed = 0
                while p.exitStatus == nil {
                    // SIGCONT is harmless to /bin/true, a zombie, or anyone else.
                    let attempted = p.isRunning
                    if p.signal(SIGCONT) { sent += 1 } else if attempted && p.exitStatus == nil { missed += 1 }
                }
                return (sent, missed)
            }
            #expect(await p.waitForExit() == 0)
            let r = await hammer.value
            #expect(r.missed == 0, "kill() found no process \(r.missed) times before the exit was recorded")
            #expect(r.sent > 0)
            #expect(!p.signal(SIGCONT))
        }
    }
}

extension PasstUplinkTests {
    /// passt processes whose parent is this test process.
    static func ourPassts() -> [Int32] {
        let me = getpid()
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { d in
            guard let pid = Int32(d), let st = try? String(contentsOfFile: "/proc/\(d)/stat", encoding: .utf8),
                  let open = st.firstIndex(of: "("), let close = st.lastIndex(of: ")") else { return nil }
            let comm = st[st.index(after: open)..<close]
            let rest = st[st.index(after: close)...].split(separator: " ")
            guard comm.hasPrefix("passt"), rest.count > 2, rest[0] != "Z", Int32(rest[1]) == me else { return nil }
            return pid
        }
    }

    @Test("close() while passt is being restarted leaves no passt running")
    func closeDuringRestart() async throws {
        let up = try await PasstUplink.start(.init())
        let pid = try #require(up.pid)
        // Hold the relaunch between spawning the new passt and installing its
        // channel, then close() inside that window.
        PasstUplink.launchPauseForTesting.withLockedValue { $0 = .milliseconds(500) }
        defer { PasstUplink.launchPauseForTesting.withLockedValue { $0 = nil } }
        kill(pid, SIGKILL)
        for _ in 0..<100 where up.restarts == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(up.restarts == 1)
        try await Task.sleep(for: .milliseconds(100))   // the new passt is spawned, launch() is paused
        #expect(Self.ourPassts().count == 1)
        await up.close()
        var left = Self.ourPassts()
        for _ in 0..<60 where !left.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            left = Self.ourPassts()
        }
        #expect(left.isEmpty, "passt still running after close(): \(left)")
    }
}

@Suite("Secrets vault", .serialized)
struct SecretsVaultTests {
    /// A fresh vault directory, file-fallback key unless `systemd` is set.
    /// The fallback is forced the production way, BROMURE_VAULT_KEY_SOURCE=file,
    /// through the vault's environment override (setenv would race other
    /// suites' posix_spawn reading `environ`).
    func env(systemd: Bool, _ extra: [String: String] = [:]) -> [String: String] {
        (systemd ? [:] : ["BROMURE_VAULT_KEY_SOURCE": "file"]).merging(extra) { _, b in b }
    }

    func withVault(systemd: Bool = false, _ extra: [String: String] = [:], _ body: (String) throws -> Void) rethrows {
        let dir = "/tmp/acl-vault-\(UUID().uuidString.prefix(8))"
        SecretsVault.configure(directory: dir, environment: env(systemd: systemd, extra))
        defer {
            SecretsVault.configure(directory: SecretsVault.defaultDirectory())
            try? FileManager.default.removeItem(atPath: dir)
        }
        try body(dir)
    }

    @Test("round trip, plain and item-bound; the forced fallback is reported; key file 0600")
    func roundTrip() throws {
        try withVault { dir in
            let secret = Data("sk-ant-api03-example".utf8)
            #expect(try SecretsVault.decrypt(SecretsVault.encrypt(secret)) == secret)
            try VaultItems.set(secret, service: "io.bromure.agentic-coding.p2p", account: "device/key")
            #expect(try VaultItems.get(service: "io.bromure.agentic-coding.p2p", account: "device/key") == secret)
            #expect(try VaultItems.get(service: "io.bromure.agentic-coding.p2p", account: "nope") == nil)
            #expect(SecretsVault.masterKeySource == .fileFallback)
            let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/secrets-master.key")
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let blob = try SecretsVault.encrypt(secret)
            #expect(blob.first == 0x01 && blob.count == 1 + 12 + secret.count + 16)
            #expect(acl_get_dumpable() == 0, "resolving the key marks the process non-dumpable")
        }
    }

    @Test("a blob moved to another item's file doesn't decrypt")
    func aadSwap() throws {
        try withVault { _ in
            try VaultItems.set(Data("A-secret".utf8), service: "svc", account: "a")
            try VaultItems.set(Data("B-secret".utf8), service: "svc", account: "b")
            let a = VaultItems.path("svc", "a"), b = VaultItems.path("svc", "b")
            try FileManager.default.removeItem(atPath: b)
            try FileManager.default.copyItem(atPath: a, toPath: b)
            #expect(throws: VaultError.unreadable) { try VaultItems.get(service: "svc", account: "b") }
            #expect(try VaultItems.get(service: "svc", account: "a") == Data("A-secret".utf8))
            // An item blob doesn't open as a plain (item-less) one either.
            let blob = try #require(FileManager.default.contents(atPath: a))
            #expect(throws: VaultError.unreadable) { try SecretsVault.decrypt(blob) }
        }
    }

    @Test("any tampered byte fails")
    func tamper() throws {
        try withVault { _ in
            let blob = try SecretsVault.encrypt(Data("payload".utf8))
            for i in [1, 6, 13, blob.count - 1] {                 // nonce, nonce, ciphertext, tag
                var t = blob
                t[t.startIndex + i] ^= 0x40
                #expect(throws: VaultError.unreadable) { try SecretsVault.decrypt(t) }
            }
        }
    }

    @Test("macOS-format blobs (bare AES-GCM combined, no AAD) still decrypt")
    func legacy() throws {
        try withVault { _ in
            let key = try SecretsVault.masterKey()
            for _ in 0..<64 {      // first nonce byte 0x01 included sooner or later
                let legacy = try #require(try AES.GCM.seal(Data("old".utf8), using: key).combined)
                #expect(try SecretsVault.decrypt(legacy) == Data("old".utf8))
            }
        }
    }

    @Test("a lost master key: secrets read as unreadable (re-enter), metadata untouched, new writes work")
    func lostKey() throws {
        try withVault { dir in
            try VaultItems.set(Data("token".utf8), service: "svc", account: "x")
            let meta = dir + "/../acl-vault-meta-\(UUID().uuidString.prefix(6)).json"
            try Data(#"{"profile":"work","hasToken":true}"#.utf8).write(to: URL(fileURLWithPath: meta))
            defer { try? FileManager.default.removeItem(atPath: meta) }
            // Lose the key: a different 32-byte key in its place, cache dropped.
            try SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                .write(to: URL(fileURLWithPath: dir + "/secrets-master.key"))
            SecretsVault.configure(directory: dir, environment: env(systemd: false))
            #expect(throws: VaultError.unreadable) { try VaultItems.get(service: "svc", account: "x") }
            #expect(try String(contentsOfFile: meta, encoding: .utf8).contains("hasToken"))
            try VaultItems.set(Data("re-entered".utf8), service: "svc", account: "x")
            #expect(try VaultItems.get(service: "svc", account: "x") == Data("re-entered".utf8))
        }
    }

    static var credsWork: Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/systemd-creds") else { return false }
        return (try? ChildProcess.capture("/usr/bin/systemd-creds",
                                          ["encrypt", "--user", "--name=probe", "-", "-"], input: Data("x".utf8))) != nil
    }

    @Test("systemd-creds: sealed on first use, unsealed on the next start; a lost seal rotates",
          .enabled(if: credsWork))
    func systemdCreds() throws {
        try withVault(systemd: true) { dir in
            try VaultItems.set(Data("tpm-sealed".utf8), service: "svc", account: "y")
            #expect(SecretsVault.masterKeySource == .systemdCreds)
            #expect(FileManager.default.fileExists(atPath: dir + "/master-key.cred"))
            #expect(!FileManager.default.fileExists(atPath: dir + "/secrets-master.key"), "no key in the clear")
            SecretsVault.configure(directory: dir, environment: env(systemd: true))        // a "restart"
            #expect(try VaultItems.get(service: "svc", account: "y") == Data("tpm-sealed".utf8))
            #expect(SecretsVault.masterKeySource == .systemdCreds)

            // Corrupt the credential (a reset TPM looks the same): rotate, old
            // credential kept aside, old secrets unreadable, no crash.
            var cred = try #require(FileManager.default.contents(atPath: dir + "/master-key.cred"))
            cred[cred.count / 2] ^= 0xFF
            try cred.write(to: URL(fileURLWithPath: dir + "/master-key.cred"))
            SecretsVault.configure(directory: dir, environment: env(systemd: true))
            #expect(throws: VaultError.unreadable) { try VaultItems.get(service: "svc", account: "y") }
            #expect(SecretsVault.masterKeySource == .systemdCreds)
            let aside = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("master-key.cred.unreadable-") }
            #expect(aside.count == 1)
        }
    }

    @Test("a system unit's \\$CREDENTIALS_DIRECTORY key wins")
    func credentialsDirectory() throws {
        try withVault(systemd: true) { dir in
            let creds = dir + "-creds"
            try FileManager.default.createDirectory(atPath: creds, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: creds) }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try key.write(to: URL(fileURLWithPath: creds + "/bromure-ac-master-key"))
            SecretsVault.configure(directory: dir, environment: env(systemd: true, ["CREDENTIALS_DIRECTORY": creds]))
            let blob = try SecretsVault.encrypt(Data("unit".utf8))
            #expect(SecretsVault.masterKeySource == .credentialsDirectory)
            let sealed = try AES.GCM.SealedBox(combined: blob.dropFirst())
            #expect(try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: SecretsVault.aad(nil)) == Data("unit".utf8))
        }
    }

    @Test("key memory is page-aligned, locked and released")
    func secureMemory() {
        let k = SecureKey(Data(repeating: 7, count: 32))
        #expect(Int(bitPattern: k.pointer) % Int(sysconf(Int32(_SC_PAGESIZE))) == 0)
        #expect(k.locked, "mlock failed (RLIMIT_MEMLOCK?)")
        #expect(k.symmetricKey.withUnsafeBytes { Data($0) } == Data(repeating: 7, count: 32))
    }
}

extension ChildProcessTests {
    @Test("a child started from a thread that then exits survives (PDEATHSIG is per-thread)",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/qemu-system-x86_64")))
    func pdeathsigFollowsThread() async throws {
        let box = NIOLockedValueBoxShim<ChildProcess?>(nil)
        let started = DispatchSemaphore(value: 0)
        // Start QEMU (exit-with-parent = PR_SET_PDEATHSIG) from a thread that
        // ends right after.
        let t = Thread {
            let p = try? ChildProcess(name: "qemu", executable: "/usr/bin/qemu-system-x86_64",
                                      arguments: ["-machine", "none", "-display", "none", "-nodefaults",
                                                  "-S", "-run-with", "exit-with-parent=on"], logPath: nil)
            try? p?.start()
            box.mutate { $0 = p }
            // Outlive QEMU's own prctl(PR_SET_PDEATHSIG) (a thread that's
            // already gone by then has handed its children to another thread).
            Thread.sleep(forTimeInterval: 0.5)
            started.signal()
        }
        t.start()
        started.wait()
        let p = try #require(box.value)
        try await Task.sleep(for: .milliseconds(500))      // the starter thread has exited
        #expect(p.isRunning, "QEMU died with the thread that started it (status \\(String(describing: p.exitStatus)))")
        p.signal(SIGKILL)
        _ = await p.waitForExit()
    }
}

/// A tiny lock box for tests.
final class NIOLockedValueBoxShim<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}


extension SecretsVaultTests {
    /// A stand-in systemd-creds: prints `stderr` and exits 1, or (`passThrough`)
    /// defers to the real one.
    static func fakeCreds(in dir: String, stderr: String) throws -> String {
        let path = dir + "-fake-creds"
        try "#!/bin/sh\necho '\(stderr)' >&2\nexit 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("an unseal that fails to run (no credential service, timeout, EMFILE…) throws and leaves the credential alone",
          arguments: ["Failed to connect to io.systemd.Credentials: Connection refused",
                      "Failed to read encrypted credential data: Connection timed out",
                      "Failed to read encrypted credential data: Too many open files",
                      "TPM2 operation failed: Device or resource busy",
                      "Failed to read encrypted credential data: Broken pipe"])
    func transientUnsealFailure(stderr: String) throws {
        try withVault(systemd: true) { dir in
            // A well-formed (base64, long enough) credential, as a real one is.
            let cred = dir + "/master-key.cred"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let original = Data(Data(repeating: 0xA5, count: 300).base64EncodedString().utf8)
            try original.write(to: URL(fileURLWithPath: cred))
            let fake = try Self.fakeCreds(in: dir, stderr: stderr)
            defer { try? FileManager.default.removeItem(atPath: fake) }
            SecretsVault.configure(directory: dir, environment: env(systemd: true, ["BROMURE_SYSTEMD_CREDS": fake]))
            #expect(throws: VaultError.self) { try SecretsVault.encrypt(Data("x".utf8)) }
            #expect(FileManager.default.contents(atPath: cred) == original, "the credential must stay byte-identical")
            let rotated = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains("unreadable") }
            #expect(rotated.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: dir + "/secrets-master.key"), "no silent fallback key")
        }
    }

    @Test("a credential whose binary is missing throws, untouched")
    func missingBinary() throws {
        try withVault(systemd: true) { dir in
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let original = Data("not-really-sealed".utf8)
            try original.write(to: URL(fileURLWithPath: dir + "/master-key.cred"))
            SecretsVault.configure(directory: dir, environment: env(systemd: true, ["BROMURE_SYSTEMD_CREDS": "/nonexistent/systemd-creds"]))
            #expect(throws: VaultError.self) { try SecretsVault.encrypt(Data("x".utf8)) }
            #expect(FileManager.default.contents(atPath: dir + "/master-key.cred") == original)
        }
    }

    @Test("a positive can't-open result (authentication failed) rotates, keeping the old credential aside")
    func authFailureRotates() throws {
        try withVault(systemd: true) { dir in
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(Data(repeating: 1, count: 300).base64EncodedString().utf8)
                .write(to: URL(fileURLWithPath: dir + "/master-key.cred"))
            let fake = try Self.fakeCreds(in: dir, stderr: "Failed to read encrypted credential data: Invalid argument")
            defer { try? FileManager.default.removeItem(atPath: fake) }
            SecretsVault.configure(directory: dir, environment: env(systemd: true, ["BROMURE_SYSTEMD_CREDS": fake]))
            // The fake can't seal the new key either: rotation falls back to a
            // file key (reported), with the old credential set aside.
            _ = try SecretsVault.encrypt(Data("x".utf8))
            let aside = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("master-key.cred.unreadable-") }
            #expect(aside.count == 1)
            #expect(SecretsVault.masterKeySource == .fileFallback)
        }
    }

    @Test("file-fallback key -> systemd-creds: the same key is sealed, old secrets still open, no plaintext left",
          .enabled(if: credsWork))
    func adoptFileKey() throws {
        try withVault { dir in
            try VaultItems.set(Data("from-the-file-key-era".utf8), service: "svc", account: "old")
            #expect(SecretsVault.masterKeySource == .fileFallback)
            #expect(FileManager.default.fileExists(atPath: dir + "/secrets-master.key"))
            SecretsVault.configure(directory: dir, environment: env(systemd: true))     // systemd-creds now available
            #expect(try VaultItems.get(service: "svc", account: "old") == Data("from-the-file-key-era".utf8))
            #expect(SecretsVault.masterKeySource == .systemdCreds)
            #expect(FileManager.default.fileExists(atPath: dir + "/master-key.cred"))
            #expect(!FileManager.default.fileExists(atPath: dir + "/secrets-master.key"), "plaintext key must be gone")
            SecretsVault.configure(directory: dir, environment: env(systemd: true))     // and after a restart
            #expect(try VaultItems.get(service: "svc", account: "old") == Data("from-the-file-key-era".utf8))
        }
    }
}

@Suite("Guest shell exec")
struct GuestShellTests {
    /// A fake agentd on the far end of a socketpair: reads one request,
    /// counts it, then replies (exit 0) or just closes.
    final class FakeAgent: @unchecked Sendable {
        let lock = NSLock()
        var requests = 0
        func serve(_ fd: Int32, reply: Bool) {
            Thread {
                var hdr = [UInt8](repeating: 0, count: 4)
                guard read(fd, &hdr, 4) == 4 else { close(fd); return }
                let n = Int(hdr[0]) << 24 | Int(hdr[1]) << 16 | Int(hdr[2]) << 8 | Int(hdr[3])
                var body = [UInt8](repeating: 0, count: n)
                var got = 0
                while got < n { let r = body.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }; if r <= 0 { break }; got += r }
                self.lock.lock(); self.requests += 1; self.lock.unlock()
                if reply {
                    let json = Array(#"{"stdout":"ok\n","stderr":"","exit_code":0}"#.utf8)
                    let h: [UInt8] = [0, 0, UInt8(json.count >> 8), UInt8(json.count & 0xFF)]
                    _ = (h + json).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
                close(fd)
            }.start()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    }

    /// A VsockConnection over one end of a Unix socketpair; the other end's fd.
    func pair() async throws -> (VsockConnection, Int32) {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
        let conn = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .withConnectedSocket(fds[0]) { ch in
                ch.eventLoop.makeCompletedFuture {
                    VsockConnection(peer: VsockAddress(cid: 42, port: 5800),
                                    channel: try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch))
                }
            }
        return (conn, fds[1])
    }

    @Test("a request written but never answered is not retried: exactly one attempt, .noReply")
    func noRetryAfterWrite() async throws {
        let agent = FakeAgent()
        let (stream, sink) = AsyncStream<VsockConnection>.makeStream()
        // Three pooled connections; each would accept a request and then close.
        for _ in 0..<3 {
            let (c, far) = try await pair()
            agent.serve(far, reply: false)
            sink.yield(c)
        }
        let shell = await GuestShell(cid: 42, connections: stream)
        await #expect(throws: GuestShell.ShellError.self) {
            _ = try await shell.exec("rm -rf /important", wait: .seconds(2))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(agent.count == 1, "the command reached agentd \(agent.count) times")
        do {
            _ = try await shell.exec("true", wait: .seconds(2))
        } catch let e as GuestShell.ShellError {
            if case .noReply = e {} else { Issue.record("expected .noReply, got \(e)") }
        }
    }

    @Test("a connection already dead before the write is skipped for the next one")
    func skipDeadBeforeWrite() async throws {
        let agent = FakeAgent()
        let (stream, sink) = AsyncStream<VsockConnection>.makeStream()
        let (dead, deadFar) = try await pair()
        close(deadFar)                                       // agentd recycled it
        try await Task.sleep(for: .milliseconds(100))        // NIO sees the EOF
        sink.yield(dead)
        let (live, liveFar) = try await pair()
        agent.serve(liveFar, reply: true)
        sink.yield(live)
        let shell = await GuestShell(cid: 42, connections: stream)
        let r = try await shell.exec("echo ok", wait: .seconds(2))
        #expect(r.stdout == "ok\n" && r.exitCode == 0)
        #expect(agent.count == 1)
    }
}

@Suite("Frame port backpressure")
struct FramePortTests {
    @Test("sendDeferred queues and drops like send, in order; the writer runs after flush")
    func deferredSend() async throws {
        final class Got: @unchecked Sendable { let l = NSLock(); var frames: [UInt8] = []
            func add(_ fs: [Data]) { l.lock(); frames += fs.map { $0[0] }; l.unlock() }
            var value: [UInt8] { l.lock(); defer { l.unlock() }; return frames } }
        let got = Got()
        let core = FramePortCore(name: "deferred", queueFrames: 8) { got.add($0) }
        try await Task.sleep(for: .milliseconds(50))            // the writer is idle, waiting
        for i in 0..<10 { core.sendDeferred(Data([UInt8(i)] + [UInt8](repeating: 0, count: 13))) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(got.value.isEmpty, "nothing is written before flush")
        #expect(core.stats.dropped == 2, "frames past the queue limit are dropped and counted")
        core.flush()
        for _ in 0..<50 where got.value.count < 8 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got.value == [0, 1, 2, 3, 4, 5, 6, 7], "in order, the first 8")
        core.flush()                                            // nothing queued: a no-op
        core.finish()
    }

    @Test("with a receiver, inbound frames go straight to it: no consumer needed, the reader never pauses")
    func eagerReceiver() async throws {
        let core = FramePortCore(name: "eager", inboundLow: 2, inboundHigh: 4) { _ in }
        final class Count: @unchecked Sendable { let l = NSLock(); var n = 0
            func bump() { l.lock(); n += 1; l.unlock() }
            var value: Int { l.lock(); defer { l.unlock() }; return n } }
        let got = Count()
        core.setReceiver { _ in got.bump() }
        for _ in 0..<10_000 { #expect(await core.deliver(Data(count: 64))) }
        for _ in 0..<1_000 { #expect(core.deliverBlocking(Data(count: 64))) }
        #expect(got.value == 11_000)
        #expect(core.stats.received == 11_000 && core.stats.inboundPauses == 0)
        // Without one, the bounded sequence pauses the reader again.
        core.setReceiver(nil, batchEnd: nil)
        let t = Task { for _ in 0..<8 { _ = await core.deliver(Data(count: 64)) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.stats.inboundPauses > 0)
        core.finish()
        await t.value
    }

    @Test("a fast sender into a slow consumer: every frame arrives, in order; reading pauses instead of dropping")
    func losslessInbound() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let port = try await StreamPort.listen(path: dir + "/net.sock")
        let total = 20_000
        // The QEMU side: a blocking writer thread, as fast as the socket takes it.
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in (port.path.utf8).enumerated() { p[i] = b } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(rc == 0)
        Thread {
            var frame = [UInt8](repeating: 0xEE, count: 4 + 1500)
            frame[0...3] = [0, 0, 0x05, 0xDC]
            for i in 0..<total {
                frame[4] = UInt8(i >> 24 & 0xFF); frame[5] = UInt8(i >> 16 & 0xFF); frame[6] = UInt8(i >> 8 & 0xFF); frame[7] = UInt8(i & 0xFF)
                var off = 0
                while off < frame.count {
                    let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
                    if n <= 0 { return }
                    off += n
                }
            }
        }.start()
        var expected = 0
        for await f in port.inbound {
            let seq = Int(f[f.startIndex]) << 24 | Int(f[f.startIndex + 1]) << 16 | Int(f[f.startIndex + 2]) << 8 | Int(f[f.startIndex + 3])
            #expect(seq == expected, "frame \(seq) where \(expected) was expected")
            if seq != expected { break }
            expected += 1
            if expected % 2000 == 0 { try await Task.sleep(for: .milliseconds(30)) }   // a slow switch
            if expected == total { break }
        }
        #expect(expected == total)
        #expect(port.stats.inboundPauses > 0, "the port never had to pause reading")
        #expect(port.dropped == 0)
        close(fd)
        await port.close()
    }

    @Test("a stalled destination fills only its own queue: drops counted there; sendWaiting waits instead")
    func perDestinationLimits() async throws {
        let release = AsyncStream<Void>.makeStream()
        // A destination whose wire never drains (a paused VM), until released.
        let stalled = FramePortCore(name: "stalled", queueFrames: 64, maxBatch: 1) { _ in
            var it = release.stream.makeAsyncIterator()
            _ = await it.next()
        }
        let healthy = FramePortCore(name: "healthy", queueFrames: 64) { _ in }
        var stalledResults: [FrameSendResult] = []
        for _ in 0..<200 {
            stalledResults.append(stalled.send(Data(count: 1500)))
            #expect(healthy.send(Data(count: 1500)) == .queued)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stalledResults.filter { $0 == .dropped }.count >= 200 - 64 - 1)
        #expect(stalled.stats.dropped >= 200 - 64 - 1)
        #expect(!stalled.isWritable)
        #expect(healthy.stats.dropped == 0 && healthy.stats.sent == 200)
        // sendWaiting doesn't drop: it completes once the destination drains.
        let waiter = Task { await stalled.sendWaiting(Data(count: 1500)) }
        try await Task.sleep(for: .milliseconds(100))
        let droppedBefore = stalled.stats.dropped
        for _ in 0..<70 { release.continuation.yield() }
        await waiter.value
        #expect(stalled.stats.dropped == droppedBefore, "sendWaiting must not count a drop")
        release.continuation.finish()
        stalled.finish()
        healthy.finish()
    }
}

@Suite("Tap uplink close")
struct TapUplinkCloseTests {
    /// A send storm racing close(): no write may reach the closed fd, nor the
    /// descriptor the kernel hands out next under the same number. A regression
    /// guard only: close() already waits out the reader's poll (≤200 ms) before
    /// closing, so an unlocked writer passes this too in practice; the lock in
    /// TapUplink is what makes it a guarantee.
    @Test("a send storm racing close() never writes to the closed or reused fd")
    func closeDuringSendStorm() async throws {
        for _ in 0..<20 {
            var sv: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0, &sv) == 0)
            let tapFD = sv[0], peer = sv[1]
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK)
            let tap = TapUplink(name: "fake-tap", fd: tapFD)
            let frame = Data(repeating: 0xAB, count: 1500)
            let stop = ManagedAtomicFlag()
            let senders = (0..<4).map { _ in
                Task.detached { while !stop.isSet { tap.send(frame); await Task.yield() } }
            }
            // Drain the peer so writes keep succeeding up to the close.
            let drain = Task.detached {
                var buf = [UInt8](repeating: 0, count: 2048)
                while !stop.isSet { if buf.withUnsafeMutableBytes({ read(peer, $0.baseAddress, $0.count) }) <= 0 { await Task.yield() } }
            }
            try await Task.sleep(for: .milliseconds(20))
            tap.close()
            // Reuse the number at once: a stray write would land in this pipe.
            var p: [Int32] = [-1, -1]
            #expect(pipe(&p) == 0)
            let reused = p[0] == tapFD ? p[0] : (p[1] == tapFD ? p[1] : -1)
            try await Task.sleep(for: .milliseconds(30))
            stop.set()
            for s in senders { await s.value }
            await drain.value
            #expect(tap.badFDWrites == 0)
            if reused == p[1] {
                // The write end took the tap's number: nothing may have arrived.
                _ = fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK)
                var b = [UInt8](repeating: 0, count: 16)
                #expect(b.withUnsafeMutableBytes { read(p[0], $0.baseAddress, $0.count) } < 0, "a frame went to the reused fd")
            } else if reused == p[0] {
                // A write to a pipe's read end fails EBADF: badFDWrites above.
            }
            Glibc.close(p[0]); Glibc.close(p[1]); Glibc.close(peer)
        }
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Suite("Interim bake")
struct InterimBakeTests {
    @Test("an extra disk is a second virtio-blk after the system disk, raw, with discard")
    func extraDisk() throws {
        var c = QEMUMachineConfig(name: "ws", kernel: "/k", initrd: nil, cmdline: "", baseImage: "/b.img",
                                  overlay: "/vm/disk.qcow2", vsockCID: 9, runDirectory: "/run/x")
        c.extraDisks = [.init(path: "/vm/home,1.img")]
        let a = c.arguments().joined(separator: " ")
        let sys = try #require(a.range(of: "file=/vm/disk.qcow2"))
        let home = try #require(a.range(of: "-drive if=none,id=d1,file=/vm/home,,1.img,format=raw,cache=none,aio=io_uring,discard=unmap -device virtio-blk-pci,drive=d1"))
        #expect(sys.lowerBound < home.lowerBound)
    }

    @Test("the bake VM's argv: the target disk written in place, no vsock, the serial console on a socket with a log")
    func bakeArgv() throws {
        var c = QEMUMachineConfig(name: "bromure-bake", kernel: "/c/vmlinuz", initrd: "/w/initrd", cmdline: "console=ttyS0",
                                  baseImage: "/o/base.img.partial", overlay: "", vsockCID: 0, runDirectory: "/run/b")
        c.writeBaseInPlace = true
        c.vsock = false
        c.network = .user
        c.serialSocketPath = "/run/b/serial.sock"
        c.serialLog = "/w/serial.log"
        try c.validate()
        let a = c.arguments().joined(separator: " ")
        #expect(a.contains("-drive if=none,id=d0,file=/o/base.img.partial,format=raw,cache=none,aio=io_uring,discard=unmap"))
        #expect(!a.contains("vhost-vsock"))
        #expect(a.contains("-chardev socket,id=ser0,path=/run/b/serial.sock,server=on,wait=off,logfile=/w/serial.log,logappend=on -serial chardev:ser0"))
        #expect(a.contains("-netdev user,id=n0"))
    }

    @Test("a console wait consumes its match: the next wait for the same prompt needs a new one; echoed commands don't match split markers")
    func consoleBuffer() async throws {
        let b = ConsoleBuffer()
        b.append(Data("localhost login: root\nlocalhost:~# ".utf8))
        try await b.wait(for: "localhost:~#", timeout: 1, failures: [])
        await #expect(throws: BakeError.self) { try await b.wait(for: "localhost:~#", timeout: 0.3, failures: []) }
        b.append(Data("echo SANDBOX_NETWORK_\"OK\"\r\n".utf8))     // the terminal's echo
        await #expect(throws: BakeError.self) { try await b.wait(for: "SANDBOX_NETWORK_OK", timeout: 0.3, failures: []) }
        b.append(Data("SANDBOX_NETWORK_OK\nlocalhost:~# ".utf8))
        try await b.wait(for: "SANDBOX_NETWORK_OK", timeout: 1, failures: ["SANDBOX_NO_NETWORK"])
        try await b.wait(for: "localhost:~#", timeout: 1, failures: [])
        b.append(Data("[ac-setup] x\nSANDBOX_SETUP_FAILED: debootstrap\n".utf8))
        do {
            try await b.wait(for: "SANDBOX_SETUP_DONE", timeout: 1, failures: ["SANDBOX_SETUP_FAILED:"])
            Issue.record("no failure")
        } catch BakeError.installerReportedFailure(let line) {
            #expect(line == "SANDBOX_SETUP_FAILED: debootstrap")
        }
    }

    @Test("staging rewrites setup.sh's BROMURE_PROXY line only without a proxy, and fails loudly if the line moved")
    func staging() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("acl-stage-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: d) }
        try fm.createDirectory(atPath: d + "/src", withIntermediateDirectories: true)
        let line = "    echo \"BROMURE_PROXY=$ALPINE_REPO_BASE\"\n"
        try "{\n\(line)} > env\n".write(toFile: d + "/src/setup.sh", atomically: true, encoding: .utf8)
        try InterimBake.stageSetup(from: d + "/src", to: d + "/a", alpineRepoBase: "http://dl-cdn.alpinelinux.org")
        let a = try String(contentsOfFile: d + "/a/setup.sh", encoding: .utf8)
        #expect(a.contains("if [ \"$ALPINE_REPO_BASE\" != \"http://dl-cdn.alpinelinux.org\" ]; then echo \"BROMURE_PROXY=$ALPINE_REPO_BASE\"; fi"))
        try InterimBake.stageSetup(from: d + "/src", to: d + "/b", alpineRepoBase: "http://192.168.64.1:3128")
        #expect(try String(contentsOfFile: d + "/b/setup.sh", encoding: .utf8).contains(line))
        try "echo moved\n".write(toFile: d + "/src/setup.sh", atomically: true, encoding: .utf8)
        #expect(throws: BakeError.self) { try InterimBake.stageSetup(from: d + "/src", to: d + "/c", alpineRepoBase: "http://dl-cdn.alpinelinux.org") }
    }

    @Test("the real setup.sh still has the BROMURE_PROXY line the staging rewrites")
    func realSetup() throws {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Sources/AgentCoding/Resources/vm-setup").standardized.path
        let d = fm.temporaryDirectory.appendingPathComponent("acl-stage-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: d) }
        try InterimBake.stageSetup(from: src, to: d, alpineRepoBase: "http://dl-cdn.alpinelinux.org")
    }

    @Test("the shimmed initrd: original, NUL padding to 4 bytes, then a newc cpio with init.bromure and the MTU")
    func shim() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("acl-shim-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: d) }
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4, 5]).write(to: d.appendingPathComponent("orig"))
        try InitrdShim.writeShimmedInitrd(original: d.appendingPathComponent("orig"), mtu: 1400, to: d.appendingPathComponent("out"))
        let out = try Data(contentsOf: d.appendingPathComponent("out"))
        #expect(Array(out.prefix(8)) == [1, 2, 3, 4, 5, 0, 0, 0])
        #expect(String(decoding: out[8..<14], as: UTF8.self) == "070701")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("init.bromure") && text.contains("echo 1400 >") && text.contains("TRAILER!!!"))
    }
}

@Suite("Home seed and outbox")
struct HomeSeedTests {
    static let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("HomeSeedContent.generated.swift matches macOS's Profile.swift (re-run scripts/gen-home-seed.py if not)")
    func generatedIsCurrent() async throws {
        try await ChildProcess.run("/usr/bin/python3", [Self.pkg.path + "/scripts/gen-home-seed.py", "--check"])
    }

    @Test("the staged seed: managed dotfiles overwritten, .bashrc.local only if missing, cleanup sweeps, spec")
    func staged() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("acl-seed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: d) }
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try "stale".write(to: d.appendingPathComponent("old"), atomically: true, encoding: .utf8)
        try HomeSeed.writeHomeSeedFiles(into: d)
        try HomeSeed.finalizeHomeSeed(seedDir: d)
        #expect(!fm.fileExists(atPath: d.appendingPathComponent("old").path), "the previous seed is cleared")
        let m = try String(contentsOf: d.appendingPathComponent("manifest.tsv"), encoding: .utf8)
        for line in ["D\t755\t.npm-global", "o\t644\t.bashrc", "o\t644\t.bash_profile", "o\t644\t.profile",
                     "o\t644\t.npmrc", "o\t644\t.tmux.conf", "m\t644\t.bashrc.local",
                     "d\t-\t.git-credentials", "j\t-\t.claude/.credentials.json\t_bromureManaged"] {
            #expect(m.contains(line + "\n"), "manifest lacks \(line)")
        }
        let bashrc = try String(contentsOf: d.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        #expect(bashrc.hasPrefix("# ─── Managed by Bromure Agentic Coding"))
        let npmrc = try String(contentsOf: d.appendingPathComponent("files/.npmrc"), encoding: .utf8)
        #expect(npmrc.hasPrefix("prefix=/home/ubuntu/.npm-global\nallow-scripts[]=@anthropic-ai/claude-code\n"))
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("claude-settings.spec.json")))
        #expect((spec as? [String: Any])?["usesClaude"] as? Bool == false)
    }

    @Test("the outbox is 0777 whatever the umask; a fresh boot empties it, a restore drops only one-shot events")
    func outbox() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("acl-outbox-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: d) }
        let old = umask(0o077)
        defer { umask(old) }
        try HomeSeed.prepareOutboxDirectory(d, forRestore: false)
        var st = stat()
        #expect(stat(d.path, &st) == 0 && st.st_mode & 0o7777 == 0o777)
        for f in ["agentd.log", "closed-1", "diag-2", "reboot-intent"] {
            try "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try HomeSeed.prepareOutboxDirectory(d, forRestore: true)
        #expect(try fm.contentsOfDirectory(atPath: d.path) == ["agentd.log"])
        try HomeSeed.prepareOutboxDirectory(d, forRestore: false)
        #expect(try fm.contentsOfDirectory(atPath: d.path).isEmpty)
    }
}

@Suite("passt routing inbox")
struct EagerInboxTests {
    final class Gate: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        let l = NSLock(); var got = 0, bytes = 0
        func take(_ d: Data) { open.wait(); open.signal(); l.lock(); got += 1; bytes += d.count; l.unlock() }
        var counts: (Int, Int) { l.lock(); defer { l.unlock() }; return (got, bytes) }
    }

    @Test("at the byte limit the reader waits (large frames), and nothing is dropped")
    func byteLimit() async throws {
        let core = FramePortCore(name: "inbox") { _ in }
        let gate = Gate()
        core.setReceiver { gate.take($0) }        // routing blocks until the gate opens
        let inbox = EagerInbox(core: core, frameLimit: 1 << 18, byteLimit: 1 << 20)
        let frame = Data(count: 65_000), n = 64           // 64 x 65 KB = ~4 MiB, 4x the bound
        let pushed = DispatchSemaphore(value: 0)
        Thread { for _ in 0..<n { inbox.push(frame) }; pushed.signal() }.start()
        try await Task.sleep(for: .milliseconds(300))
        let s = inbox.stats
        #expect(s.waits == 1, "the reader waits at the byte limit")
        #expect(s.peakBytes <= 1 << 20 && s.peakFrames <= 17, "peak \(s.peakBytes) bytes, \(s.peakFrames) frames")
        #expect(pushed.wait(timeout: .now()) == .timedOut, "the reader is still waiting")
        gate.open.signal()                               // routing proceeds
        #expect(pushed.wait(timeout: .now() + 5) == .success)
        for _ in 0..<100 where gate.counts.0 < n { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gate.counts == (n, n * 65_000), "every frame was routed")
        inbox.close()
    }

    @Test("the frame limit binds for small frames")
    func frameLimit() async throws {
        let core = FramePortCore(name: "inbox") { _ in }
        let gate = Gate()
        core.setReceiver { gate.take($0) }
        let inbox = EagerInbox(core: core, frameLimit: 100, byteLimit: 64 << 20)
        let pushed = DispatchSemaphore(value: 0)
        Thread { for _ in 0..<1000 { inbox.push(Data(count: 60)) }; pushed.signal() }.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(inbox.stats.peakFrames <= 100 && inbox.stats.waits >= 1)
        gate.open.signal()
        #expect(pushed.wait(timeout: .now() + 5) == .success)
        for _ in 0..<100 where gate.counts.0 < 1000 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gate.counts.0 == 1000)
        inbox.close()
    }
}

@Suite("Switch routing")
struct SwitchRoutingTests {
    @Test("MAC values round-trip; a routed frame gets its VM's MAC written in place")
    func macRewrite() async throws {
        let m = MAC([0x52, 0x54, 0x00, 0xab, 0xcd, 0xef])
        #expect(m.bytes == [0x52, 0x54, 0x00, 0xab, 0xcd, 0xef])
        #expect(m == MAC(InterimSwitch.mac("52:54:00:ab:cd:ef")))
        let up = RouteBench.DirectUplink()
        let sw = InterimSwitch(uplink: up)
        let port = RouteBench.SinkPort("vm")
        sw.attach(port, mac: "52:54:00:ab:cd:ef")
        let ip = sw.dhcp.lease(for: m.bytes)
        var bytes = [UInt8](repeating: 0xff, count: 60)     // to the broadcast MAC (passt's single-guest MAC in reality)
        bytes[0] = 0x9a                                     // unicast, not ours
        bytes[12] = 0x08; bytes[13] = 0x00; bytes[14] = 0x45
        for i in 0..<4 { bytes[30 + i] = ip[i] }
        var f = Data(bytes)
        let route = try #require(up.receiver)
        route(&f)
        up.batchEnd?()
        #expect(Array(f.prefix(6)) == m.bytes, "rewritten in place")
        #expect(port.stats.queued + port.stats.sent == 1)
        sw.stop()
    }
}

@Suite("Control socket streaming")
struct ControlStreamTests {
    @Test("PTY frames: encode, then split across partial reads")
    func frames() {
        let a = PTYFrame.encode(PTYFrame.data, Array("hi".utf8))
        let b = PTYFrame.encode(PTYFrame.resize, PTYFrame.resizePayload(cols: 132, rows: 40))
        let c = PTYFrame.encode(PTYFrame.exit, [0xff, 0xff, 0xff, 0xf9])
        #expect(a == [0, 0, 0, 0, 2, 0x68, 0x69])
        #expect(b == [1, 0, 0, 0, 4, 0, 132, 0, 40])
        var buf: [UInt8] = []
        var got: [(UInt8, [UInt8])] = []
        for byte in a + b + c { buf.append(byte); got += PTYFrame.take(&buf) }
        #expect(buf.isEmpty)
        #expect(got.map(\.0) == [0, 1, 2])
        #expect(got[0].1 == Array("hi".utf8) && got[2].1 == [0xff, 0xff, 0xff, 0xf9])
        #expect(PTYFrame.resizePayload(cols: 70_000, rows: -1) == [0xff, 0xff, 0, 0])
    }

    @Test("a streaming reply: octet-stream header, then raw bytes both ways; an error reply throws its message")
    func stream() async throws {
        let path = NSTemporaryDirectory() + "acl-cs-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = try await ControlServer.start(path: path) { req in
            guard req.path == "/echo" else { return .error(409, "VM 'x' is off") }
            return .streaming { s in
                // Upper-cases until "bye", then closes.
                for await b in s.inbound {
                    let text = String(buffer: b)
                    try? await s.write(ByteBuffer(string: text.uppercased()))
                    if text.contains("bye") { return }
                }
            }
        }
        let client = ControlClient(socketPath: path)
        #expect(throws: ControlClient.ClientError.self) { try client.openStream("POST", "/nope", body: .object([:])) }
        do {
            _ = try client.openStream("POST", "/nope", body: .object([:]))
        } catch let e as ControlClient.ClientError {
            #expect(e.description.contains("VM 'x' is off"))
        }
        let fd = try client.openStream("POST", "/echo", body: .object([:]))
        defer { close(fd) }
        #expect(ControlClient.writeAll(fd, Data("hello ".utf8)))
        #expect(ControlClient.writeAll(fd, Data("bye".utf8)))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        #expect(String(decoding: out, as: UTF8.self) == "HELLO BYE")
        await server.close()
    }
}

@Suite("systemd stop-post")
struct StopPostTests {
    @Test("sweep on a stop/restart job or a clean exit; keep for a crash restart")
    func decision() {
        typealias F = StopPost.Facts
        #expect(StopPost.shouldSweep(F(serviceResult: "timeout", job: "2318\n")))      // stop, daemon hung
        #expect(StopPost.shouldSweep(F(serviceResult: "success", job: "41")))          // stop, clean
        #expect(StopPost.shouldSweep(F(serviceResult: "success", job: "")))            // exited 0 alone: no restart
        #expect(!StopPost.shouldSweep(F(serviceResult: "signal", job: "\n")))          // crash: restart re-adopts
        #expect(!StopPost.shouldSweep(F(serviceResult: "core-dump", job: "")))
        #expect(!StopPost.shouldSweep(F(serviceResult: "watchdog", job: "0")))
    }

    @Test("its own unit from /proc/self/cgroup")
    func unit() {
        let u = StopPost.ownUnit("0::/user.slice/user-1000.slice/user@1000.service/app.slice/bromure-ac.service\n")
        #expect(u?.unit == "bromure-ac.service" && u?.user == true)
        #expect(u?.cgroup == "/user.slice/user-1000.slice/user@1000.service/app.slice/bromure-ac.service")
        #expect(StopPost.ownUnit("0::/system.slice/bromure-ac-kvm.service")?.user == false)
        #expect(StopPost.ownUnit("0::/user.slice/user-1000.slice/session-3.scope") == nil)
    }
}

@Suite("VM hostname and home size")
struct HostnameHomeTests {
    @Test("hostname from the VM name, as macOS sanitizes a workspace name")
    func hostname() {
        #expect(Daemon.sanitizeHostname("My Workspace_2") == "myworkspace2")
        #expect(Daemon.sanitizeHostname("--uk--") == "uk")
        #expect(Daemon.sanitizeHostname("Ünïcode!") == "ncode")
        #expect(Daemon.sanitizeHostname("___") == "bromure")
        #expect(Daemon.sanitizeHostname(String(repeating: "a", count: 40)).count == 32)
    }

    @Test("target size: the VM's own, else the default, clamped to 8-1024 GiB; grows, never shrinks, stays sparse")
    func grow() throws {
        #expect(Daemon.homeImageTargetBytes(gb: nil, defaultGB: 16) == 16 << 30)
        #expect(Daemon.homeImageTargetBytes(gb: 2, defaultGB: 16) == 8 << 30)
        #expect(Daemon.homeImageTargetBytes(gb: 4096, defaultGB: 16) == 1024 << 30)
        let path = NSTemporaryDirectory() + "acl-home-\(UUID().uuidString).img"
        defer { unlink(path) }
        try Daemon.ensureHomeImage(atPath: path, bytes: 8 << 30)
        var st = stat()
        let grown = try Daemon.growHomeImageIfNeeded(atPath: path, target: 12 << 30, setting: 12)
        #expect(grown == "home image grown 8 GiB → 12 GiB (target 12 GiB)")
        _ = stat(path, &st)
        #expect(st.st_size == 12 << 30 && st.st_blocks == 0, "sparse: \(st.st_blocks) blocks")
        let kept = try Daemon.growHomeImageIfNeeded(atPath: path, target: 8 << 30, setting: nil)
        #expect(kept == "home image 12 GiB (setting default, target 8 GiB) — nothing to grow")
        _ = stat(path, &st)
        #expect(st.st_size == 12 << 30)
        #expect(try Daemon.growHomeImageIfNeeded(atPath: path + ".missing", target: 8 << 30, setting: nil).hasPrefix("home image unreadable"))
    }
}
