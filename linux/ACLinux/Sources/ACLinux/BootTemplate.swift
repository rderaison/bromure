import CACLinuxShims
import Crypto
import Foundation
import NIOConcurrencyHelpers

/// A guest stopped right after its kernel booted, before it read anything of
/// a workspace: every later boot of the same shape starts from its snapshot
/// instead of booting the kernel again (~0.3 s of each boot).
///
/// The template is a VM of that shape (same kernel, command line, CPUs,
/// memory, as many disks, the same share tags, a NIC, vsock) booted once
/// with `bromure-preinit` as its whole initramfs and placeholder disks, then
/// snapshotted while preinit waits. A boot from it (FirecrackerMachine):
/// the template's memory copied into a memfd, the snapshot loaded with this
/// VM's backends, the placeholder disks swapped for the workspace's, the
/// boot's own clock, random seed and MAC written into preinit's page of that
/// memory, and the vCPUs resumed. preinit then mounts the root file system
/// and starts its init, as the image's initramfs does.
///
/// Templates are a cache, per user and per host: made in the background
/// after an ordinary boot of a shape that has none, never waited for, thrown
/// away when a boot from one fails (that boot goes on the ordinary way).
// @port-skip linux-only: Firecracker boot snapshot (VZ has no equivalent hook before the guest's init)
public struct BootTemplate: Sendable, Equatable {
    public var id: String
    public var directory: String
    /// Where preinit's parameter page is in the memory file.
    public var paramsOffset: UInt64
    public var memoryBytes: UInt64

    // @port-skip linux-only: boot template
    public var snapshot: String { directory + "/vm.snap" }
    // @port-skip linux-only: boot template
    public var memory: String { directory + "/vm.mem" }

    /// The on-disk format: the files' layout and what a boot does with them.
    static let format = 1
    /// The NIC's address in a template (this boot's replaces it in preinit).
    static let placeholderMAC = "02:00:00:00:00:01"
    static let placeholderBytes = 1 << 20
    static let placeholderCID: UInt32 = 3

    // @port-skip linux-only: boot template
    struct Manifest: Codable, Equatable {
        var format: Int
        var preinit: UInt32
        var paramsOffset: UInt64
        var memoryBytes: UInt64
        var shape: String
    }

    // MARK: shape

    /// A file as a template depends on it: replaced, it is another file.
    // @port-skip linux-only: boot template
    static func identity(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "\(path):missing" }
        return "\(path):\(st.st_size):\(st.st_mtim.tv_sec).\(st.st_mtim.tv_nsec)"
    }

    /// This machine as a snapshot depends on it: the CPU it saved the state
    /// of and the kernel whose KVM saved it.
    // @port-skip linux-only: boot template
    static let host: String = {
        var u = utsname()
        uname(&u)
        let release = withUnsafeBytes(of: &u.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let cpuinfo = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)) ?? ""
        let model = cpuinfo.split(separator: "\n").first { $0.hasPrefix("model name") || $0.hasPrefix("CPU part") }
        let microcode = cpuinfo.split(separator: "\n").first { $0.hasPrefix("microcode") }
        return "\(machine) \(release) \(model.map(String.init) ?? "?") \(microcode.map(String.init) ?? "")"
    }()

    /// What a VM must share with a template to boot from it, or nil for a
    /// VM that never does (a resume, the bake, one without a NIC or vsock).
    // @port-skip linux-only: boot template
    static func shape(of c: MachineConfig, preinit: String, placeholder: String, host: String = BootTemplate.host) -> String? {
        guard c.restoreFrom == nil, c.consolePipes == nil, !c.writeBaseInPlace, c.vsock,
              c.extraDisks.count < Int(BROMURE_PREINIT_MAX_DISKS) else { return nil }
        guard case .datagram = c.network else { return nil }
        return [
            "format=\(format) preinit=\(acl_preinit_version())",
            "kernel=\(identity(c.kernel))",
            "firecracker=\(identity(c.firecrackerBinary))",
            "virtiofsd=\(identity(c.virtiofsd))",
            "preinit=\(identity(preinit))",
            "placeholder=\(placeholder)",
            "args=\(c.cmdline) \(MachineConfig.kernelArguments)",
            "cpus=\(c.cpus) memory=\(c.memoryMiB)",
            "disks=\(1 + c.extraDisks.count)",
            "shares=" + c.shares.map { "\($0.tag):\($0.readOnly ? "ro" : "rw"):\($0.guestOwner.map { "\($0.uid).\($0.gid)" } ?? "-")" }.joined(separator: ","),
            "mac=\(c.macAddress != nil) entropy=\(c.entropy)",
            "host=\(host)",
        ].joined(separator: "\n")
    }

    // @port-skip linux-only: boot template
    static func id(forShape shape: String) -> String {
        SHA256.hash(data: Data(shape.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the template's initramfs

    /// A newc cpio archive holding one file, `init`: the kernel unpacks it
    /// as the initramfs and runs it.
    // @port-skip linux-only: boot template
    static func initramfs(initBinary: Data) -> Data {
        var out = Data()
        func entry(_ name: String, mode: UInt32, data: Data, ino: UInt32) {
            let nameBytes = Array(name.utf8) + [0]
            let fields: [UInt32] = [ino, mode, 0, 0, 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(nameBytes.count), 0]
            out.append(Data(("070701" + fields.map { String(format: "%08X", $0) }.joined()).utf8))
            out.append(contentsOf: nameBytes)
            out.append(Data(count: (4 - out.count % 4) % 4))
            out.append(data)
            out.append(Data(count: (4 - out.count % 4) % 4))
        }
        entry("init", mode: 0o100755, data: initBinary, ino: 1)
        entry("TRAILER!!!", mode: 0, data: Data(), ino: 0)
        return out
    }

    // MARK: a boot's parameters

    /// "aa:bb:cc:dd:ee:ff" as its six bytes.
    // @port-skip linux-only: boot template
    static func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard p.count == 2, let b = UInt8(p, radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }

    /// The guest's name for its `index`th virtio disk: vda … vdz.
    // @port-skip linux-only: boot template
    static func diskName(_ index: Int) -> String {
        "vd" + String(UnicodeScalar(UInt8(97 + index)))
    }

    /// Writes this boot's parameters into preinit's page of the guest's
    /// memory and tells it to go. `disks`: the VM's disk files, in order.
    // @port-skip linux-only: boot template
    func go(memfd: Int32, mac: String?, disks: [String], trace: Bool) throws {
        var sectors: [UInt64] = []
        for path in disks {
            var st = stat()
            guard stat(path, &st) == 0 else { throw MachineError.io("stat \(path)", errno) }
            sectors.append(UInt64(st.st_size) / 512)
        }
        var seed = [UInt8](repeating: 0, count: 64)
        var rng = SystemRandomNumberGenerator()
        for i in seed.indices { seed[i] = UInt8.random(in: .min ... .max, using: &rng) }
        let macBytes = mac.flatMap(Self.macBytes)
        if mac != nil, macBytes == nil { throw MachineError.invalidConfig("MAC address \(mac ?? "")") }
        let names = disks.indices.map { strdup(Self.diskName($0)) }
        defer { for n in names { free(n) } }
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let now = UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        let r = names.map { UnsafePointer<CChar>($0) }.withUnsafeBufferPointer { n in
            acl_preinit_go(memfd, paramsOffset, trace ? UInt32(BROMURE_PREINIT_TRACE) : 0, now, macBytes, seed,
                           UInt32(disks.count), n.baseAddress, sectors, "")
        }
        guard r == 0 else { throw MachineError.io("writing the boot's parameters", -r) }
    }
}

/// The boot templates of one daemon (one user): which exist, which are being
/// made, which failed.
// @port-skip linux-only: boot template
public final class BootTemplateStore: Sendable {
    public let root: String
    let runtimeDir: String
    public let preinit: String
    private let state = NIOLockedValueBox<(building: Set<String>, failed: Set<String>, disabled: String?)>(([], [], nil))

    /// What a template's disks are until a boot swaps the workspace's in.
    // @port-skip linux-only: boot template
    var placeholder: String { root + "/placeholder.img" }

    /// How long after an ordinary boot its shape's template is made:
    /// BROMURE_BOOT_TEMPLATE_DELAY_MS, else 3 s (the boot's own work first).
    // @port-skip linux-only: boot template
    static let buildDelay: Duration = {
        let ms = ProcessInfo.processInfo.environment["BROMURE_BOOT_TEMPLATE_DELAY_MS"].flatMap(Int.init) ?? 3000
        return .milliseconds(max(0, ms))
    }()

    /// bromure-preinit: BROMURE_PREINIT, else the package's beside bromure-ac,
    /// else linux/preinit/build.sh's output in the user's home.
    // @port-skip linux-only: boot template
    public static var defaultPreinit: String {
        MachineConfig.bundledHelper("bromure-preinit", env: "BROMURE_PREINIT",
                                    system: NSHomeDirectory() + "/.local/share/bromure-ac/bin/bromure-preinit")
    }

    /// nil when templates are off: BROMURE_BOOT_TEMPLATE=0, or no preinit.
    // @port-skip linux-only: boot template
    public static func make(stateDir: String, runtimeDir: String, preinit: String = defaultPreinit,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> BootTemplateStore? {
        if environment["BROMURE_BOOT_TEMPLATE"] == "0" { return nil }
        guard FileManager.default.isExecutableFile(atPath: preinit) else { return nil }
        return BootTemplateStore(root: stateDir + "/boot-templates", runtimeDir: runtimeDir, preinit: preinit)
    }

    // @port-skip linux-only: boot template
    public init(root: String, runtimeDir: String, preinit: String) {
        self.root = root
        self.runtimeDir = runtimeDir
        self.preinit = preinit
    }

    // @port-skip linux-only: boot template
    func shape(of c: MachineConfig) -> String? {
        BootTemplate.shape(of: c, preinit: preinit, placeholder: placeholder)
    }

    /// The template `c` can boot from, if there is one.
    // @port-skip linux-only: boot template
    public func ready(for c: MachineConfig) -> BootTemplate? {
        guard state.withLockedValue({ $0.disabled }) == nil, let shape = shape(of: c) else { return nil }
        return load(BootTemplate.id(forShape: shape), shape: shape)
    }

    // @port-skip linux-only: boot template
    func load(_ id: String, shape: String) -> BootTemplate? {
        let dir = root + "/" + id
        guard let data = FileManager.default.contents(atPath: dir + "/template.json"),
              let m = try? JSONDecoder().decode(BootTemplate.Manifest.self, from: data),
              m.format == BootTemplate.format, m.preinit == acl_preinit_version(), m.shape == shape else { return nil }
        let t = BootTemplate(id: id, directory: dir, paramsOffset: m.paramsOffset, memoryBytes: m.memoryBytes)
        let fm = FileManager.default
        guard fm.fileExists(atPath: t.snapshot), fm.fileExists(atPath: t.memory), fm.fileExists(atPath: placeholder) else { return nil }
        return t
    }

    /// A boot from `template` failed: it is removed and not made again by
    /// this daemon. A Firecracker that doesn't know the load's overrides
    /// (one built before them) turns templates off altogether.
    // @port-skip linux-only: boot template
    public func discard(_ template: BootTemplate, reason: String) {
        let off = reason.contains("unknown field")
        state.withLockedValue {
            $0.failed.insert(template.id)
            if off { $0.disabled = reason }
        }
        try? FileManager.default.removeItem(atPath: template.directory)
        Self.log("boot template \(template.id) dropped: \(reason)" + (off ? " (templates off: this Firecracker predates them)" : ""))
    }

    // @port-skip linux-only: boot template
    static func log(_ line: String) {
        FileHandle.standardError.write(Data("[boot-template] \(line)\n".utf8))
    }

    /// Makes the template for `c`'s shape unless there is one, one is being
    /// made, or one failed. Returns whether it made one.
    // @port-skip linux-only: boot template
    @discardableResult
    public func build(for c: MachineConfig, readyTimeout: Duration = .seconds(15)) async -> Bool {
        guard let shape = shape(of: c) else { return false }
        let id = BootTemplate.id(forShape: shape)
        if load(id, shape: shape) != nil { return false }
        let claimed = state.withLockedValue { s -> Bool in
            // One at a time: a template's own boot takes CPU from whatever boots meanwhile.
            guard s.disabled == nil, s.building.isEmpty, !s.failed.contains(id) else { return false }
            s.building.insert(id)
            return true
        }
        guard claimed else { return false }
        defer { state.withLockedValue { _ = $0.building.remove(id) } }
        let started = ContinuousClock.now
        do {
            let kept = try await make(id: id, shape: shape, like: c, readyTimeout: readyTimeout)
            let ms = (ContinuousClock.now - started) / .milliseconds(1)
            Self.log("boot template \(id) made in \(Int(ms)) ms (\(kept >> 20) MB of guest memory)")
            prune(keeping: id)
            return true
        } catch {
            state.withLockedValue { _ = $0.failed.insert(id) }
            Self.log("boot template \(id) not made: \(error)")
            return false
        }
    }

    // @port-skip linux-only: boot template
    private func make(id: String, shape: String, like c: MachineConfig, readyTimeout: Duration) async throws -> UInt64 {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: placeholder) {
            let tmp = placeholder + ".\(getpid()).tmp"
            guard fm.createFile(atPath: tmp, contents: nil, attributes: [.posixPermissions: 0o600]),
                  truncate(tmp, off_t(BootTemplate.placeholderBytes)) == 0, rename(tmp, placeholder) == 0 else {
                throw MachineError.io("create \(placeholder)", errno)
            }
        }
        let build = root + "/" + id + ".build"
        let run = runtimeDir + "/tpl-" + id.prefix(8)
        try? fm.removeItem(atPath: build)
        try? fm.removeItem(atPath: run)
        try fm.createDirectory(atPath: build + "/empty", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? fm.removeItem(atPath: build)
            try? fm.removeItem(atPath: run)
        }
        guard let initBinary = fm.contents(atPath: preinit) else { throw MachineError.io("read \(preinit)", ENOENT) }
        try BootTemplate.initramfs(initBinary: initBinary).write(to: URL(fileURLWithPath: build + "/initramfs.cpio"))

        var t = MachineConfig(name: "tpl-" + id.prefix(8), kernel: c.kernel, initrd: build + "/initramfs.cpio", cmdline: c.cmdline,
                              baseImage: placeholder, overlay: placeholder, vsockCID: BootTemplate.placeholderCID, runDirectory: run)
        t.writeBaseInPlace = true
        t.cpus = c.cpus
        t.memoryMiB = c.memoryMiB
        t.extraDisks = c.extraDisks.map { _ in .init(path: placeholder) }
        t.shares = c.shares.map { .init(tag: $0.tag, hostPath: build + "/empty", readOnly: $0.readOnly, guestOwner: $0.guestOwner) }
        t.macAddress = c.macAddress == nil ? nil : BootTemplate.placeholderMAC
        t.entropy = c.entropy
        // The snapshot's memory file then holds the pages the kernel wrote,
        // not the guest's whole memory.
        t.trackDirtyPages = true
        t.firecrackerBinary = c.firecrackerBinary
        t.virtiofsd = c.virtiofsd
        // A NIC nobody is on the other end of: the template never brings it up.
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &pair) == 0 else {
            throw MachineError.io("socketpair", errno)
        }
        defer { close(pair[1]) }
        t.network = .datagram(peerFD: pair[0])   // the machine's start closes it

        let machine = FirecrackerMachine(config: t)
        try await machine.start()
        do {
            guard let serial = t.serialLog else { throw MachineError.invalidConfig("template without a console") }
            let marker = Data(String(cString: acl_preinit_ready_line()).utf8)
            let deadline = ContinuousClock.now + readyTimeout
            while fm.contents(atPath: serial)?.range(of: marker) == nil {
                if case .stopped(let info) = await machine.state {
                    throw MachineError.exitedDuringStart(info.exitStatus, "the template's guest ended before preinit was ready")
                }
                if ContinuousClock.now > deadline { throw MachineError.io("waiting for preinit in the template's guest", ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(5))
            }
            // preinit is in its wait loop a moment after its line.
            try await Task.sleep(for: .milliseconds(20))
            try await machine.snapshot(into: build, writtenPagesOnly: true)
        } catch {
            await machine.kill()
            throw error
        }
        // The pages with something in them (whatever Firecracker wrote
        // around them), and preinit's among them.
        var offset: UInt64 = 0, version: UInt32 = 0, kept: UInt64 = 0
        let r = acl_template_memory(build + "/vm.mem", build + "/vm.mem.sparse", &offset, &version, &kept)
        guard r == 0 else { throw MachineError.io("preparing the template's memory", -r) }
        guard version == acl_preinit_version() else {
            throw MachineError.invalidConfig("\(preinit) is preinit version \(version), this daemon expects \(acl_preinit_version())")
        }
        guard rename(build + "/vm.mem.sparse", build + "/vm.mem") == 0 else { throw MachineError.io("rename vm.mem", errno) }
        var st = stat()
        guard stat(build + "/vm.mem", &st) == 0 else { throw MachineError.io("stat vm.mem", errno) }
        let manifest = BootTemplate.Manifest(format: BootTemplate.format, preinit: version, paramsOffset: offset,
                                             memoryBytes: UInt64(st.st_size), shape: shape)
        try JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: build + "/template.json"))
        try? fm.removeItem(atPath: build + "/empty")
        try? fm.removeItem(atPath: build + "/initramfs.cpio")
        let final = root + "/" + id
        try? fm.removeItem(atPath: final)
        guard rename(build, final) == 0 else { throw MachineError.io("rename \(build)", errno) }
        return kept
    }

    /// Templates of shapes no longer booted (another kernel, an upgraded
    /// Firecracker…) go: the newest few stay, and the one just made.
    // @port-skip linux-only: boot template
    func prune(keeping id: String, limit: Int = 6) {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { name in
            name != id && name.count == 24 && name.allSatisfy(\.isHexDigit)
        }
        let dated = dirs.map { name -> (String, Date) in
            let attrs = try? fm.attributesOfItem(atPath: root + "/" + name)
            return (name, (attrs?[.modificationDate] as? Date) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in dated.dropFirst(max(0, limit - 1)) { try? fm.removeItem(atPath: root + "/" + name) }
        // What a daemon that died while making one left behind.
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".build") && name != id + ".build" {
            let made = (try? fm.attributesOfItem(atPath: root + "/" + name))?[.modificationDate] as? Date
            if let made, Date().timeIntervalSince(made) > 600 { try? fm.removeItem(atPath: root + "/" + name) }
        }
    }
}
