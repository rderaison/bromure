import Foundation

// @port-skip linux-only: errors of the VM backend
public enum MachineError: Error, CustomStringConvertible, Equatable {
    case socketPathTooLong(String)
    case invalidConfig(String)
    case toolFailed(String, Int32, String)
    case io(String, Int32)
    case notRunning
    case alreadyStarted
    case exitedDuringStart(Int32, String)
    /// The share's tag, then virtiofsd's own last words (its log), if any.
    case virtiofsdNotReady(String, String = "")
    case snapshotMissing(String)
    case snapshotMismatch(state: String, overlay: String)

    // @port-skip linux-only: error text
    public var description: String {
        switch self {
        case .socketPathTooLong(let p): return "unix socket path over 107 bytes: \(p)"
        case .invalidConfig(let m): return "invalid VM config: \(m)"
        case .toolFailed(let t, let s, let o): return "\(t) exited \(s): \(o)"
        case .io(let what, let e): return "\(what): \(String(cString: strerror(e)))"
        case .notRunning: return "VM is not running"
        case .alreadyStarted: return "VM was already started"
        case .exitedDuringStart(let s, let log): return "Firecracker exited \(s) during start: \(log)"
        case .virtiofsdNotReady(let tag, let log):
            return "virtiofsd for '\(tag)' did not come up" + (log.isEmpty ? "" : ": \(log)")
        case .snapshotMissing(let p): return "no snapshot identity at \(p)"
        case .snapshotMismatch(let s, let o): return "\(s) was not saved with \(o) as it is now; refusing to restore"
        }
    }
}

/// Everything one workspace VM is made of: FirecrackerMachine renders it into
/// Firecracker's config (`firecrackerConfig(netFD:)`).
// @port-skip linux-only: the Linux equivalent of VZVirtualMachineConfiguration
public struct MachineConfig: Sendable {
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

    // @port-skip linux-only: the VM's network
    public enum Network: Sendable {
        case none
        /// The VM's end of a DgramPort socketpair, inherited by the
        /// firecracker process (FirecrackerMachine.start closes it here).
        case datagram(peerFD: Int32)
    }

    /// A further virtio-blk disk after the system disk (vdb, vdc, …): the
    /// workspace's home image (macOS: SessionDisk's second VZ block device).
    // @port-skip linux-only: block devices
    public struct Disk: Sendable {
        public var path: String
        // @port-skip linux-only: block devices
        public init(path: String) { self.path = path }
    }

    public var name: String
    public var cpus: Int = 2
    public var memoryMiB: Int = 2048
    /// Direct kernel boot: the bake's vmlinuz, initrd and cmdline.
    public var kernel: String
    public var initrd: String?
    public var cmdline: String
    /// The read-only base image, and the VM's system disk: a sparse raw copy
    /// of it made on first start (Firecracker has no qcow2).
    public var baseImage: String
    public var overlay: String
    /// The image bake writes `baseImage` itself (no copy).
    public var writeBaseInPlace = false
    /// A snapshot to resume instead of booting (`vm.snap` and `vm.mem` in
    /// this directory, made by FirecrackerMachine.snapshot).
    public var restoreFrom: String?
    /// A boot template of this VM's shape to start from instead of booting
    /// the kernel (BootTemplate; a failed start from it boots the ordinary
    /// way).
    public var bootTemplate: BootTemplate?
    /// Firecracker records which pages the guest writes, so a snapshot can
    /// hold only those (a boot template's own VM; it costs a running guest
    /// write faults, so nothing else sets it).
    public var trackDirtyPages = false
    public var extraDisks: [Disk] = []
    public var shares: [Share] = []
    public var network: Network = .none
    public var macAddress: String?
    public var vsockCID: UInt32
    /// No vsock device (the bake's installer has no agentd to dial).
    public var vsock = true
    /// A virtio-rng device (the bake's installer wants entropy early).
    public var entropy = false
    /// Holds the API, vsock and virtiofs sockets and the logs. Keep it short:
    /// Unix socket paths are limited to 107 bytes.
    public var runDirectory: String
    /// The guest's serial console (Firecracker's stdout), or nil for /dev/null.
    public var serialLog: String?
    /// The serial console as pipes instead (the bake types into it): the
    /// read end Firecracker's stdin takes, the write end its stdout goes to.
    /// FirecrackerMachine.start closes both here once Firecracker has them.
    public var consolePipes: (input: Int32, output: Int32)?
    public var virtiofsd = Self.defaultVirtiofsd
    /// BROMURE_VIRTIOFSD, else the one installed beside this executable (the
    /// package's, linux/virtiofsd/build.sh: Ubuntu 24.04's 1.10 refuses the
    /// options virtiofsdArguments passes), else the system's.
    // @port-skip linux-only: virtiofsd supervision
    public static var defaultVirtiofsd: String {
        bundledHelper("virtiofsd", env: "BROMURE_VIRTIOFSD", system: "/usr/libexec/virtiofsd")
    }

    /// A helper the package ships beside bromure-ac (virtiofsd, passt): `env`
    /// when set, else the one beside this executable, else the system's.
    // @port-skip linux-only: helper binaries
    public static func bundledHelper(_ name: String, env: String, system: String) -> String {
        resolveHelper(name, env: ProcessInfo.processInfo.environment[env],
                      executable: try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"),
                      system: system, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // @port-skip linux-only: helper binaries
    static func resolveHelper(_ name: String, env: String?, executable: String?, system: String,
                              isExecutable: (String) -> Bool) -> String {
        if let env, !env.isEmpty { return env }
        if let executable {
            let beside = (executable as NSString).deletingLastPathComponent + "/" + name
            if isExecutable(beside) { return beside }
        }
        return system
    }

    // @port-skip linux-only: virtiofsd supervision
    static func resolveVirtiofsd(env: String?, executable: String?, isExecutable: (String) -> Bool) -> String {
        resolveHelper("virtiofsd", env: env, executable: executable, system: "/usr/libexec/virtiofsd", isExecutable: isExecutable)
    }
    /// BROMURE_FIRECRACKER, else the package's beside bromure-ac, else
    /// linux/firecracker/build.sh's output in the user's home. (A daemon
    /// run by hand on a packaged server has no BROMURE_FIRECRACKER: the
    /// units set it.)
    public var firecrackerBinary = Self.defaultFirecrackerBinary
    // @port-skip linux-only: Firecracker backend
    public static var defaultFirecrackerBinary: String {
        bundledHelper("firecracker", env: "BROMURE_FIRECRACKER",
                      system: NSHomeDirectory() + "/.local/share/bromure-ac/bin/firecracker")
    }

    // @port-skip linux-only: VM config
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
    // @port-skip linux-only: VM config validation
    public func validate() throws {
        let socks = shares.indices.map(shareSocketPath)
            + [firecrackerAPISocketPath, HybridVsockListener.path(uds: firecrackerVsockPath, port: 65_535)]
        for s in socks where s.utf8.count > 107 { throw MachineError.socketPathTooLong(s) }
        if cpus < 1 || memoryMiB < 128 { throw MachineError.invalidConfig("cpus/memory") }
        if Set(shares.map(\.tag)).count != shares.count { throw MachineError.invalidConfig("duplicate share tag") }
    }

    /// virtiofsd's argv for share `index`.
    // @port-skip linux-only: virtiofsd command line
    func virtiofsdArguments(_ index: Int) -> [String] {
        let s = shares[index]
        var a = ["--shared-dir", s.hostPath, "--socket-path", shareSocketPath(index),
                 "--sandbox", "namespace", "--migration-mode", "find-paths",
                 // A snapshot of a share whose files the host removes under the
                 // guest (the outbox's one-shot reports) can't name every inode
                 // the guest holds: those few fail in the guest after a resume,
                 // instead of the whole restore.
                 "--migration-on-error", "guest-error"]
        if s.readOnly { a.append("--readonly") }
        if let o = s.guestOwner {
            // Every guest id writes as the user running virtiofsd; that user's
            // files read back as the guest owner. In the host's ids: run
            // unprivileged, virtiofsd's namespace sandbox maps no ids (it logs
            // "Couldn't set the process uid as root"), so it sees the files'
            // real owners. Mapping from 0 only worked where the user was 1000.
            let uid = getuid(), gid = getgid()
            a += ["--translate-uid", "squash-guest:0:\(uid):4294967295", "--translate-uid", "host:\(uid):\(o.uid):1",
                  "--translate-gid", "squash-guest:0:\(gid):4294967295", "--translate-gid", "host:\(gid):\(o.gid):1"]
        }
        return a
    }
}
