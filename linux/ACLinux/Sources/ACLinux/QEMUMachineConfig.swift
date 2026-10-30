import Foundation

/// Everything one QEMU/KVM workspace VM is made of, rendered into argv by
/// `arguments(incoming:)`.
// @port-skip linux-only: QEMU's equivalent of VZVirtualMachineConfiguration
public struct QEMUMachineConfig: Sendable {
    // @port-skip linux-only: QEMU machine types
    public enum MachineType: String, Sendable {
        /// PCI machine (virtio-*-pci devices).
        case q35
        /// Minimal virtio-mmio machine: about 0.5 s faster to the agent.
        case microvm
    }

    /// A host folder shared over virtiofs; each gets its own virtiofsd.
    // @port-skip linux-only: virtiofsd + vhost-user-fs (VZVirtioFileSystemDevice on macOS)
    public struct Share: Sendable {
        public var tag: String
        public var hostPath: String
        public var readOnly: Bool
        /// Whom the guest sees owning the host's files, and as whom every
        /// guest write lands on the host (the user running virtiofsd) — what
        /// a VZ share does. The default is the image's `ubuntu` (1000:1000),
        /// which runs bromure-agentd. nil: no translation (namespace root only).
        public var guestOwner: (uid: UInt32, gid: UInt32)?
        // @port-skip linux-only: virtiofs share
        public init(tag: String, hostPath: String, readOnly: Bool = false,
                    guestOwner: (uid: UInt32, gid: UInt32)? = (1000, 1000)) {
            self.tag = tag
            self.hostPath = hostPath
            self.readOnly = readOnly
            self.guestOwner = guestOwner
        }
    }

    // @port-skip linux-only: QEMU netdevs
    public enum Network: Sendable {
        case none
        /// `-netdev stream` to a Unix socket our L2 switch listens on (QEMU
        /// connects; each frame is prefixed with a 4-byte big-endian length).
        case stream(socketPath: String)
        /// QEMU user-mode NAT (tests and the image bake).
        case user
    }

    // @port-skip linux-only: disk image formats
    public enum ImageFormat: String, Sendable { case raw, qcow2 }

    public var name: String
    public var machine: MachineType = .q35
    public var cpus: Int = 2
    public var memoryMiB: Int = 2048
    /// Direct kernel boot: the bake's vmlinuz, initrd and cmdline.
    public var kernel: String
    public var initrd: String?
    public var cmdline: String
    /// The read-only base image, and the per-VM qcow2 overlay on it (created
    /// on first start). The overlay stands in for APFS clonefile.
    public var baseImage: String
    public var baseFormat: ImageFormat = .raw
    public var overlay: String
    /// The image bake writes `baseImage` itself (read-write, no overlay).
    public var writeBaseInPlace = false
    public var shares: [Share] = []
    public var network: Network = .none
    public var macAddress: String?
    public var vsockCID: UInt32
    /// No vhost-vsock device (the bake's installer has no agentd to dial).
    public var vsock = true
    /// Holds the QMP and virtiofs sockets and the logs. Keep it short:
    /// Unix socket paths are limited to 107 bytes.
    public var runDirectory: String
    public var qmpSocketPath: String
    public var serialLog: String?
    /// The serial console as a Unix socket QEMU listens on, for a host that
    /// types into it (the bake's console dialogue). `serialLog` still records
    /// the guest's output.
    public var serialSocketPath: String?
    public var qemuBinary = "/usr/bin/qemu-system-x86_64"
    public var qemuImg = "/usr/bin/qemu-img"
    public var virtiofsd = "/usr/libexec/virtiofsd"
    public var extraArguments: [String] = []
    /// QEMU exits when the process that started it does (`-run-with
    /// exit-with-parent=on`), so a crashed daemon leaves no orphan VMs; their
    /// virtiofsds follow when QEMU disconnects. Off for a daemon that should
    /// re-adopt running VMs across its own restarts (not implemented yet).
    public var exitWithParent = true

    // @port-skip linux-only: QEMU config
    public init(name: String, kernel: String, initrd: String?, cmdline: String,
                baseImage: String, overlay: String, vsockCID: UInt32, runDirectory: String) {
        self.name = name
        self.kernel = kernel
        self.initrd = initrd
        self.cmdline = cmdline
        self.baseImage = baseImage
        self.overlay = overlay
        self.vsockCID = vsockCID
        self.runDirectory = runDirectory
        self.qmpSocketPath = (runDirectory as NSString).appendingPathComponent("qmp.sock")
        self.serialLog = (runDirectory as NSString).appendingPathComponent("serial.log")
    }

    /// The bake's output directory (`vmlinuz`, `initrd.img`, `cmdline`, raw `base.img`).
    // @port-skip linux-only: reads linux/bake's artefacts
    public init(name: String, bakedImage dir: String, overlay: String, vsockCID: UInt32,
                runDirectory: String) throws {
        let cmdline = try String(contentsOfFile: dir + "/cmdline", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name, kernel: dir + "/vmlinuz", initrd: dir + "/initrd.img", cmdline: cmdline,
                  baseImage: dir + "/base.img", overlay: overlay, vsockCID: vsockCID,
                  runDirectory: runDirectory)
    }

    // @port-skip linux-only: virtiofsd socket naming
    public func shareSocketPath(_ index: Int) -> String {
        (runDirectory as NSString).appendingPathComponent("fs\(index).sock")
    }

    /// Unix socket paths this config needs, each checked against sun_path.
    // @port-skip linux-only: QEMU config validation
    public func validate() throws {
        var socks = [qmpSocketPath] + shares.indices.map(shareSocketPath) + [serialSocketPath].compactMap { $0 }
        if case .stream(let p) = network { socks.append(p) }
        for s in socks where s.utf8.count > 107 {
            throw MachineError.socketPathTooLong(s)
        }
        if cpus < 1 || memoryMiB < 128 { throw MachineError.invalidConfig("cpus/memory") }
        if Set(shares.map(\.tag)).count != shares.count { throw MachineError.invalidConfig("duplicate share tag") }
    }

    /// QEMU's argv (without the binary). `incoming` adds `-incoming defer`
    /// for a restore.
    // @port-skip linux-only: QEMU command line
    public func arguments(incoming: Bool = false) -> [String] {
        let pci = machine == .q35
        func dev(_ base: String) -> String { base + (pci ? "-pci" : "-device") }
        var a: [String] = ["-name", name]
        switch machine {
        case .q35: a += ["-machine", "q35,accel=kvm"]
        case .microvm: a += ["-machine", "microvm,accel=kvm,pit=off,pic=off,rtc=on,isa-serial=on"]
        }
        a += ["-cpu", "host", "-smp", "\(cpus)", "-m", "\(memoryMiB)M",
              // memfd shared RAM: required by vhost-user-fs, and what mapped-ram saves.
              "-object", "memory-backend-memfd,id=mem,size=\(memoryMiB)M,share=on",
              "-numa", "node,memdev=mem",
              "-kernel", kernel, "-append", cmdline]
        if let initrd { a += ["-initrd", initrd] }
        let disk = writeBaseInPlace ? "file=\(Self.optValue(baseImage)),format=\(baseFormat.rawValue)"
                                    : "file=\(Self.optValue(overlay)),format=qcow2"
        a += ["-drive", "if=none,id=d0,\(disk),cache=none,aio=io_uring,discard=unmap",
              "-device", "\(dev("virtio-blk")),drive=d0"]
        for (i, s) in shares.enumerated() {
            a += ["-chardev", "socket,id=fs\(i),path=\(Self.optValue(shareSocketPath(i)))",
                  "-device", "\(dev("vhost-user-fs")),chardev=fs\(i),tag=\(Self.optValue(s.tag))"]
        }
        let mac = macAddress.map { ",mac=\($0)" } ?? ""
        switch network {
        case .none: break
        case .stream(let path):
            a += ["-netdev", "stream,id=n0,server=off,addr.type=unix,addr.path=\(Self.optValue(path))",
                  "-device", "\(dev("virtio-net")),netdev=n0\(mac)"]
        case .user:
            a += ["-netdev", "user,id=n0", "-device", "\(dev("virtio-net")),netdev=n0\(mac)"]
        }
        if vsock { a += ["-device", "\(dev("vhost-vsock")),guest-cid=\(vsockCID)"] }
        a += ["-chardev", "socket,id=qmp,path=\(Self.optValue(qmpSocketPath)),server=on,wait=off",
              "-mon", "chardev=qmp,mode=control"]
        if let serialSocketPath {
            let log = serialLog.map { ",logfile=\(Self.optValue($0)),logappend=on" } ?? ""
            a += ["-chardev", "socket,id=ser0,path=\(Self.optValue(serialSocketPath)),server=on,wait=off\(log)",
                  "-serial", "chardev:ser0"]
        } else if let serialLog {
            a += ["-chardev", "file,id=ser0,path=\(Self.optValue(serialLog))", "-serial", "chardev:ser0"]
        } else {
            a += ["-serial", "null"]
        }
        a += ["-display", "none", "-nodefaults", "-no-user-config"]
        if exitWithParent { a += ["-run-with", "exit-with-parent=on"] }
        if incoming { a += ["-incoming", "defer"] }
        return a + extraArguments
    }

    /// A value inside a QEMU `key=value,…` option list: QEMU reads a doubled
    /// comma as a literal one. (`-kernel`, `-initrd` and `-append` take their
    /// argument whole and need no escaping.)
    // @port-skip linux-only: QEMU option syntax
    public static func optValue(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ",,")
    }

    /// virtiofsd's argv for share `index`.
    // @port-skip linux-only: virtiofsd command line
    func virtiofsdArguments(_ index: Int) -> [String] {
        let s = shares[index]
        var a = ["--shared-dir", s.hostPath, "--socket-path", shareSocketPath(index),
                 "--sandbox", "namespace", "--migration-mode", "find-paths"]
        if s.readOnly { a.append("--readonly") }
        if let o = s.guestOwner {
            // In the namespace sandbox the host user is uid/gid 0. Every guest
            // id writes as it; it reads back as the guest owner.
            a += ["--translate-uid", "squash-guest:0:0:4294967295", "--translate-uid", "host:0:\(o.uid):1",
                  "--translate-gid", "squash-guest:0:0:4294967295", "--translate-gid", "host:0:\(o.gid):1"]
        }
        return a
    }
}
