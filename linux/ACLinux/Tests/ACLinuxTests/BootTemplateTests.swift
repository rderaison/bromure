import CACLinuxShims
import Foundation
import Testing
@testable import ACLinux

/// Boot templates: what a template is made for, its files, and the page
/// through which a boot's parameters reach the guest.
@Suite("Boot templates")
struct BootTemplateTests {
    static func config(_ change: (inout MachineConfig) -> Void = { _ in }) -> MachineConfig {
        var c = MachineConfig(name: "vm", kernel: "/nonexistent/vmlinux", initrd: "/nonexistent/initrd", cmdline: "console=ttyS0 root=LABEL=root ro",
                              baseImage: "/nonexistent/base.img", overlay: "/nonexistent/disk.raw", vsockCID: 7, runDirectory: "/tmp/run")
        c.network = .datagram(peerFD: -1)
        c.macAddress = "52:54:00:00:00:07"
        c.shares = [.init(tag: "bromure-meta", hostPath: "/a", readOnly: true), .init(tag: "bromure-outbox", hostPath: "/b")]
        c.extraDisks = [.init(path: "/nonexistent/home.img")]
        change(&c)
        return c
    }

    static func tempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aShapeIsWhatATemplateDependsOn() throws {
        func id(_ change: (inout MachineConfig) -> Void = { _ in }, host: String = "x86_64 6.8 cpu") -> String? {
            BootTemplate.shape(of: Self.config(change), preinit: "/nonexistent/preinit", placeholder: "/p/placeholder.img", host: host)
                .map(BootTemplate.id(forShape:))
        }
        let base = try #require(id())
        #expect(base.count == 24 && base.allSatisfy(\.isHexDigit))
        // Another VM of the same shape: its own disks, shares, MAC and CID.
        #expect(id { $0.overlay = "/other/disk.raw"; $0.vsockCID = 9; $0.macAddress = "52:54:00:00:00:09"
                     $0.shares[0].hostPath = "/elsewhere"; $0.extraDisks[0].path = "/other/home.img"; $0.name = "other" } == base)
        // Anything the snapshot holds makes another shape.
        #expect(id { $0.cpus = 4 } != base)
        #expect(id { $0.memoryMiB = 4096 } != base)
        #expect(id { $0.cmdline += " quiet" } != base)
        #expect(id { $0.kernel = "/nonexistent/other" } != base)
        #expect(id { $0.shares.append(.init(tag: "share-1", hostPath: "/c")) } != base)
        #expect(id { $0.shares[1].readOnly = true } != base)
        #expect(id { $0.extraDisks.append(.init(path: "/nonexistent/data.img")) } != base)
        #expect(id { $0.macAddress = nil } != base)
        #expect(id { $0.entropy = true } != base)
        #expect(id(host: "x86_64 6.9 cpu") != base, "another host kernel: another KVM saved the state")
        // VMs that never boot from a template.
        #expect(id { $0.restoreFrom = "/snap" } == nil)
        #expect(id { $0.network = .none } == nil)
        #expect(id { $0.vsock = false } == nil)
        #expect(id { $0.writeBaseInPlace = true } == nil)
        #expect(id { $0.consolePipes = (0, 1) } == nil)
    }

    @Test func theInitramfsIsACpioArchiveOfInit() throws {
        let binary = Data((0..<1001).map { UInt8($0 % 251) })
        let archive = BootTemplate.initramfs(initBinary: binary)
        #expect(archive.count % 4 == 0)
        func field(_ entry: Data, _ i: Int) -> Int? { Int(String(decoding: entry[entry.startIndex + 6 + 8 * i ..< entry.startIndex + 14 + 8 * i], as: UTF8.self), radix: 16) }
        #expect(String(decoding: archive.prefix(6), as: UTF8.self) == "070701")
        #expect(field(archive, 1) == 0o100755, "a regular file, executable")
        #expect(field(archive, 6) == binary.count)
        #expect(field(archive, 11) == 5, "\"init\" and its NUL")
        #expect(archive[110..<115] == Data("init\0".utf8))
        let dataStart = (110 + 5 + 3) / 4 * 4
        #expect(archive[dataStart ..< dataStart + binary.count] == binary)
        let trailer = (dataStart + binary.count + 3) / 4 * 4
        #expect(String(decoding: archive[trailer ..< trailer + 6], as: UTF8.self) == "070701")
        #expect(archive[(trailer + 110) ..< (trailer + 121)] == Data("TRAILER!!!\0".utf8))
        // The kernel's own format, as cpio reads it.
        guard let cpio = KernelCache.which("cpio") else { return }
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try archive.write(to: URL(fileURLWithPath: dir + "/a.cpio"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd \"$1\" && \"$2\" -i --quiet < a.cpio && cmp init expected", "sh", dir, cpio]
        try binary.write(to: URL(fileURLWithPath: dir + "/expected"))
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(FileManager.default.isExecutableFile(atPath: dir + "/init"))
    }

    @Test func aMACAndADiskName() {
        #expect(BootTemplate.macBytes("52:54:00:ab:CD:07") == [0x52, 0x54, 0, 0xAB, 0xCD, 7])
        for bad in ["", "52:54:00:ab:cd", "52:54:00:ab:cd:07:08", "52:54:00:ab:cd:zz", "5:54:00:ab:cd:07", "52-54-00-ab-cd-07"] {
            #expect(BootTemplate.macBytes(bad) == nil, "\(bad)")
        }
        #expect((0..<3).map(BootTemplate.diskName) == ["vda", "vdb", "vdc"])
    }

    // The parameter page's layout (bromure_preinit_params.h), by its offsets.
    static let magic = Data("BROMURE-PREINIT\0".utf8)
    static func page(state: UInt32, counter: UInt64, version: UInt32 = acl_preinit_version()) -> Data {
        var p = Data(count: 4096)
        p.replaceSubrange(0..<16, with: magic)
        withUnsafeBytes(of: version.littleEndian) { p.replaceSubrange(16..<20, with: $0) }
        withUnsafeBytes(of: state.littleEndian) { p.replaceSubrange(20..<24, with: $0) }
        withUnsafeBytes(of: counter.littleEndian) { p.replaceSubrange(24..<32, with: $0) }
        return p
    }

    static func write(_ data: Data, to fd: Int32, at offset: Int) {
        data.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
    }

    static func read(_ fd: Int32, at offset: Int, count: Int) -> Data {
        var d = Data(count: count)
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        return n == count ? d : Data()
    }

    @Test func theTemplatesMemoryIsKeptSparseAndPreinitsPageFound() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let size = 64 << 20
        let src = dir + "/vm.mem"
        // As Firecracker writes it: every page, zeros included.
        #expect(FileManager.default.createFile(atPath: src, contents: Data(count: size)))
        let fd = open(src, O_RDWR)
        defer { close(fd) }
        var kernel = Data(count: 3 * 4096 + 100)
        for i in kernel.indices { kernel[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 1) | 1 }
        Self.write(kernel, to: fd, at: 5 << 20)
        Self.write(Self.page(state: 0, counter: 0), to: fd, at: 9 << 20)                       // as compiled, in the page cache
        Self.write(Self.page(state: UInt32(BROMURE_PREINIT_READY), counter: 3), to: fd, at: 20 << 20)  // a stale copy
        Self.write(Self.page(state: UInt32(BROMURE_PREINIT_READY), counter: 9), to: fd, at: 41 << 20)  // preinit's
        Self.write(Data("BROMURE-PREINIT\0 not at the start of a page".utf8), to: fd, at: (50 << 20) + 8)

        var offset: UInt64 = 0, version: UInt32 = 0, kept: UInt64 = 0
        #expect(acl_template_memory(src, dir + "/sparse", &offset, &version, &kept) == 0)
        let preinitsPage: UInt64 = 41 << 20
        #expect(offset == preinitsPage)
        #expect(version == acl_preinit_version())
        // The kernel's four pages, the three parameter pages, the stray text's one.
        let expected: UInt64 = 8 * 4096
        #expect(kept == expected, "the pages with data: \(kept)")
        var st = stat()
        #expect(stat(dir + "/sparse", &st) == 0)
        #expect(Int(st.st_size) == size)
        let onDisk = Int(st.st_blocks) * 512
        #expect(onDisk < 1 << 20, "holes where the zeros were: \(st.st_blocks) blocks")

        // A guest's memory from it: the same bytes, in a memfd of its size.
        var memSize: UInt64 = 0
        let mem = acl_memfd_from_sparse(dir + "/sparse", 4, &memSize)
        #expect(mem >= 0)
        #expect(memSize == UInt64(size))
        defer { if mem >= 0 { close(mem) } }
        #expect(Self.read(mem, at: 5 << 20, count: kernel.count) == kernel)
        #expect(Self.read(mem, at: 41 << 20, count: 4096) == Self.page(state: UInt32(BROMURE_PREINIT_READY), counter: 9))
        #expect(Self.read(mem, at: 30 << 20, count: 8192) == Data(count: 8192))
        #expect(acl_memfd_from_sparse(dir + "/missing", 4, &memSize) == -ENOENT)

        // No page: not a template's memory.
        #expect(FileManager.default.createFile(atPath: dir + "/plain", contents: kernel))
        #expect(acl_template_memory(dir + "/plain", dir + "/plain.sparse", &offset, &version, &kept) == -ENOENT)
    }

    @Test func aBootsParametersReachPreinitsPage() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mem = dir + "/mem"
        #expect(FileManager.default.createFile(atPath: mem, contents: Data(count: 1 << 20)))
        let fd = open(mem, O_RDWR)
        defer { close(fd) }
        let at = 3 * 4096
        Self.write(Self.page(state: UInt32(BROMURE_PREINIT_READY), counter: 42), to: fd, at: at)
        for (name, bytes) in [("disk.raw", 24 << 30), ("home.img", 8 << 30)] {
            #expect(FileManager.default.createFile(atPath: dir + "/" + name, contents: nil))
            #expect(truncate(dir + "/" + name, off_t(bytes)) == 0)
        }
        let t = BootTemplate(id: "x", directory: dir, paramsOffset: UInt64(at), memoryBytes: 1 << 20)
        #expect(acl_preinit_state(fd, UInt64(at)) == Int64(BROMURE_PREINIT_READY))
        let before = Date().timeIntervalSince1970
        try t.go(memfd: fd, mac: "52:54:00:00:00:07", disks: [dir + "/disk.raw", dir + "/home.img"], trace: true)
        let p = Self.read(fd, at: at, count: 448)
        func u32(_ o: Int) -> UInt32 { p.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { p.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        // preinit's own fields are untouched.
        #expect(p.prefix(16) == Self.magic)
        #expect(u32(16) == acl_preinit_version())
        #expect(u32(20) == UInt32(BROMURE_PREINIT_READY))
        #expect(u64(24) == 42)
        #expect(u32(32) == 1, "go")
        let traceAndMAC = UInt32(BROMURE_PREINIT_TRACE) | UInt32(BROMURE_PREINIT_HAS_MAC)
        #expect(u32(36) == traceAndMAC)
        let clock = Double(u64(40)) / 1e9
        #expect(clock >= before && clock < before + 10)
        #expect(Array(p[48..<54]) == [0x52, 0x54, 0, 0, 0, 7])
        #expect(u32(56) == 2)
        #expect(p[64..<128] != Data(count: 64), "a seed")
        let rootSectors: UInt64 = (24 << 30) / 512, homeSectors: UInt64 = (8 << 30) / 512
        #expect(String(decoding: p[128..<131], as: UTF8.self) == "vda")
        #expect(p[131] == 0)
        #expect(u64(144) == rootSectors)
        #expect(String(decoding: p[152..<155], as: UTF8.self) == "vdb")
        #expect(u64(168) == homeSectors)
        #expect(p[320] == 0, "root: the command line's")
        // Two boots never get the same seed.
        try t.go(memfd: fd, mac: nil, disks: [dir + "/disk.raw"], trace: false)
        let q = Self.read(fd, at: at, count: 448)
        #expect(q[64..<128] != p[64..<128])
        #expect(q.subdata(in: 36..<40) == Data(count: 4), "no flags: no MAC to set, no trace")
        #expect(throws: MachineError.self) { try t.go(memfd: fd, mac: "not a mac", disks: [dir + "/disk.raw"], trace: false) }
        #expect(throws: MachineError.self) { try t.go(memfd: fd, mac: nil, disks: [dir + "/missing"], trace: false) }
    }

    @Test func theStoreKnowsWhichTemplatesAreReady() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let preinit = dir + "/bromure-preinit"
        #expect(FileManager.default.createFile(atPath: preinit, contents: Data("x".utf8), attributes: [.posixPermissions: 0o755]))
        #expect(BootTemplateStore.make(stateDir: dir, runtimeDir: dir, preinit: preinit, environment: ["BROMURE_BOOT_TEMPLATE": "0"]) == nil)
        #expect(BootTemplateStore.make(stateDir: dir, runtimeDir: dir, preinit: dir + "/missing", environment: [:]) == nil)
        let store = try #require(BootTemplateStore.make(stateDir: dir, runtimeDir: dir, preinit: preinit, environment: [:]))
        #expect(store.root == dir + "/boot-templates")
        let c = Self.config()
        #expect(store.ready(for: c) == nil)

        func install(_ c: MachineConfig, format: Int = BootTemplate.format, shape: String? = nil) throws -> String {
            let real = try #require(store.shape(of: c))
            let id = BootTemplate.id(forShape: real)
            let d = store.root + "/" + id
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            for f in ["vm.snap", "vm.mem"] { #expect(FileManager.default.createFile(atPath: d + "/" + f, contents: Data())) }
            _ = FileManager.default.createFile(atPath: store.placeholder, contents: Data())
            let m = BootTemplate.Manifest(format: format, preinit: acl_preinit_version(), paramsOffset: 4096, memoryBytes: 8192, shape: shape ?? real)
            try JSONEncoder().encode(m).write(to: URL(fileURLWithPath: d + "/template.json"))
            return id
        }
        let id = try install(c)
        let t = try #require(store.ready(for: c))
        #expect(t == BootTemplate(id: id, directory: store.root + "/" + id, paramsOffset: 4096, memoryBytes: 8192))
        #expect(store.ready(for: Self.config { $0.cpus = 8 }) == nil, "another shape")
        // Another format, or a manifest for another shape under this name: not this daemon's.
        _ = try install(c, format: BootTemplate.format + 1)
        #expect(store.ready(for: c) == nil)
        _ = try install(c, shape: "something else")
        #expect(store.ready(for: c) == nil)
        // A file gone: not ready.
        _ = try install(c)
        try FileManager.default.removeItem(atPath: t.snapshot)
        #expect(store.ready(for: c) == nil)

        // A failed boot drops its template…
        _ = try install(c)
        store.discard(t, reason: "firecracker template load exited 400: something")
        #expect(!FileManager.default.fileExists(atPath: t.directory) && store.ready(for: c) == nil)
        // …and a Firecracker without the overrides turns templates off.
        let other = Self.config { $0.memoryMiB = 4096 }
        _ = try install(other)
        let o = try #require(store.ready(for: other))
        _ = try install(c)
        store.discard(o, reason: "firecracker template load exited 400: unknown field `fs_overrides`, expected one of …")
        #expect(store.ready(for: c) == nil, "off for every shape")
    }

    @Test func oldTemplatesArePruned() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = BootTemplateStore(root: dir, runtimeDir: dir, preinit: "/nonexistent")
        var names: [String] = []
        for i in 0..<8 {
            let name = String(format: "%024x", i)
            names.append(name)
            try FileManager.default.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)],
                                                  ofItemAtPath: dir + "/" + name)
        }
        _ = FileManager.default.createFile(atPath: dir + "/placeholder.img", contents: Data())
        try FileManager.default.createDirectory(atPath: dir + "/not-a-template", withIntermediateDirectories: true)
        store.prune(keeping: names[0], limit: 4)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir))
        #expect(left == Set([names[0], names[5], names[6], names[7], "placeholder.img", "not-a-template"]),
                "the one kept and the three newest others: \(left.sorted())")
    }
}
