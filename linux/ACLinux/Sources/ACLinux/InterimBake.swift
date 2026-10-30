import CACLinuxShims
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers

/// STAND-IN for UbuntuImageManager.createBaseImage on Linux: bakes the amd64
/// guest image under QEMU/KVM with the shared vm-setup scripts. The bake
/// *logic* (catalog, downloads, the serial dialogue, version stamps) moves to
/// ACCore against a `ProvisionerVM` protocol in the carve-out; until then this
/// mirrors its steps:
///   1. Alpine netboot (x86_64 here), sha256-checked, cached;
///   2. InitrdShim's `/init.bromure` appended (DHCP + MTU before Alpine's /init);
///   3. the installer VM: the target disk, virtiofs `setup` (vm-setup, read-only),
///      user-mode NAT, the serial console on a socket;
///   4. runProvisioner's console dialogue, then `setup.sh` until
///      SANDBOX_SETUP_DONE (it partitions, debootstraps, trims, e2fscks);
///   5. Linux only: the kernel and initrd copied out through a second share
///      (`out`) for direct kernel boot.
/// Output: `base.img` (raw GPT: ESP + ext4 root), `vmlinuz`, `initrd.img`,
/// `cmdline`, `kernel-release`, `base.version`, `bake.log`.
// @port-skip linux-only: interim stand-in for UbuntuImageManager's bake until ACCore ships it
public enum InterimBake {
    // @port-skip linux-only: interim bake options
    public struct Options: Sendable {
        public var outputDir: String
        public var cacheDir: String
        /// `Sources/AgentCoding/Resources/vm-setup` (setup.sh and the agents).
        public var vmSetupDir: String
        /// Written to `base.version` (UbuntuImageManager.imageVersion, copied).
        public var imageVersion: String
        public var cpus = 4
        public var memoryMiB = 4096
        public var diskGiB = 24
        public var mtu = 1500
        /// setup.sh's DISPLAY_SCALE argument (kitty's font size). Headless: 1.
        public var displayScale = 1
        /// apk's repository and the modloop: plain HTTP is fine, apk checks
        /// signatures (and setup.sh treats this exact value as "no proxy").
        public var alpineCDN = "http://dl-cdn.alpinelinux.org"
        /// Where the netboot tarball and its .sha256 come from, macOS's
        /// releasesBase: HTTPS, since a checksum fetched beside its file over
        /// plain HTTP catches corruption but not tampering. A mirror goes here.
        public var alpineReleasesBase =
            "https://dl-cdn.alpinelinux.org/alpine/v\(InterimBake.alpineVersion)/releases/\(InterimBake.alpineArch)"
        public var ubuntuMirror: String?
        public var setupTimeout: Duration = .seconds(2700)
        // @port-skip linux-only: interim bake options
        public init(outputDir: String, cacheDir: String, vmSetupDir: String, imageVersion: String) {
            self.outputDir = outputDir
            self.cacheDir = cacheDir
            self.vmSetupDir = vmSetupDir
            self.imageVersion = imageVersion
        }
    }

    // @port-skip linux-only: interim bake result
    public struct Result: Sendable {
        public let total: Duration
        public let setup: Duration
        /// base.img's size and what it occupies on the host (holes excluded:
        /// what setup.sh's fstrim, passed through as discard, gave back).
        public let imageBytes: UInt64
        public let imageAllocatedBytes: UInt64
        public let kernelRelease: String
    }

    static let alpineVersion = "3.22"
    static let alpineRelease = "3.22.3"
    static let alpineArch = "x86_64"

    /// Runs the whole bake. `progress` gets one line per step, `output` the
    /// raw serial console.
    // @port-skip linux-only: interim stand-in for UbuntuImageManager.createBaseImage
    public static func bake(_ o: Options, progress: @escaping @Sendable (String) -> Void = { _ in },
                            output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default
        let t0 = ContinuousClock.now
        try fm.createDirectory(atPath: o.outputDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: o.cacheDir, withIntermediateDirectories: true)
        let work = o.outputDir + "/.work"
        try? fm.removeItem(atPath: work)
        try fm.createDirectory(atPath: work + "/out", withIntermediateDirectories: true)
        // Sockets live in a short runtime dir (sun_path is 108 bytes).
        let runBase = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        var tmpl = Array((runBase as NSString).appendingPathComponent("bromure-bake.XXXXXX").utf8CString)
        guard let runDirC = mkdtemp(&tmpl) else { throw MachineError.io("mkdtemp", errno) }
        let runDir = String(cString: runDirC)
        defer { try? fm.removeItem(atPath: runDir); try? fm.removeItem(atPath: work) }

        // 1. Alpine netboot, cached.
        let kernel = o.cacheDir + "/alpine-vmlinuz-\(alpineArch)"
        let initrd = o.cacheDir + "/alpine-initramfs-\(alpineArch)"
        if !fm.fileExists(atPath: kernel) || !fm.fileExists(atPath: initrd) {
            progress("Downloading the Alpine \(alpineRelease) netboot installer…")
            try await downloadAlpineNetboot(cacheDir: o.cacheDir, releasesBase: o.alpineReleasesBase,
                                            kernel: kernel, initrd: initrd)
        }
        // 2. The DHCP/MTU shim.
        let shimmed = work + "/alpine-initramfs-shimmed"
        try InitrdShim.writeShimmedInitrd(original: URL(fileURLWithPath: initrd), mtu: o.mtu,
                                          to: URL(fileURLWithPath: shimmed))
        // 3. The setup share and an empty target disk.
        let setup = work + "/setup"
        try stageSetup(from: o.vmSetupDir, to: setup, alpineRepoBase: o.alpineCDN)
        let partial = o.outputDir + "/base.img.partial"
        try createSparseDisk(atPath: partial, sizeBytes: UInt64(o.diskGiB) << 30)

        let modloop = "\(o.alpineCDN)/alpine/v\(alpineVersion)/releases/\(alpineArch)/netboot-\(alpineRelease)/modloop-virt"
        var c = QEMUMachineConfig(
            name: "bromure-bake", kernel: kernel, initrd: shimmed,
            cmdline: "console=ttyS0 rdinit=/init.bromure alpine_repo=\(o.alpineCDN)/alpine/v\(alpineVersion)/main "
                + "modloop=\(modloop) modules=loop,squashfs,virtio-net,virtio-blk,virtiofs",
            baseImage: partial, overlay: "", vsockCID: 0, runDirectory: runDir)
        c.writeBaseInPlace = true
        c.vsock = false
        c.cpus = o.cpus
        c.memoryMiB = o.memoryMiB
        c.network = .user
        // Root in the installer reads and writes as the bake's user.
        c.shares = [.init(tag: "setup", hostPath: setup, readOnly: true, guestOwner: nil),
                    .init(tag: "out", hostPath: work + "/out", guestOwner: nil)]
        c.serialSocketPath = runDir + "/serial.sock"
        c.serialLog = work + "/serial.log"
        c.extraArguments = ["-device", "virtio-rng-pci"]
        let vm = QEMUMachine(config: c)
        progress("Starting the installer VM…")
        try await vm.start()

        // 4-5. The console dialogue.
        let console: SerialConsole
        do { console = try SerialConsole(path: c.serialSocketPath!, output: output) } catch {
            await vm.kill(); throw error
        }
        defer { console.close() }
        var tSetup = ContinuousClock.now
        do {
            tSetup = try await runInstaller(console, o, progress: progress)
        } catch {
            await vm.kill()
            try? fm.copyItem(atPath: work + "/serial.log", toPath: o.outputDir + "/bake.log.failed")
            throw error
        }
        let setupTime = ContinuousClock.now - tSetup
        progress("Shutting down the installer…")
        let stopped = await withTaskGroup(of: QEMUMachine.StopInfo?.self) { g in
            g.addTask { await vm.waitUntilStopped() }
            g.addTask { try? await Task.sleep(for: .seconds(30)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        if stopped == nil { progress("Forcing shutdown…"); await vm.stop(timeout: .seconds(5)) }

        // Artefacts.
        let finalImage = o.outputDir + "/base.img"
        try? fm.removeItem(atPath: finalImage)
        try fm.moveItem(atPath: partial, toPath: finalImage)
        for f in ["vmlinuz", "initrd.img", "kernel-release"] {
            try? fm.removeItem(atPath: o.outputDir + "/" + f)
            try fm.moveItem(atPath: work + "/out/" + f, toPath: o.outputDir + "/" + f)
        }
        // ia32_emulation=0 as setup.sh's GRUB line: no 32-bit syscall entry,
        // which the kernel sentry (64-bit wrappers only) doesn't watch.
        try "console=ttyS0 root=LABEL=root rootfstype=ext4 ro quiet ia32_emulation=0\n"
            .write(toFile: o.outputDir + "/cmdline", atomically: true, encoding: .utf8)
        try (o.imageVersion + "\n").write(toFile: o.outputDir + "/base.version", atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: o.outputDir + "/bake.log")
        try? fm.copyItem(atPath: work + "/serial.log", toPath: o.outputDir + "/bake.log")

        var st = stat()
        guard stat(finalImage, &st) == 0 else { throw MachineError.io("stat \(finalImage)", errno) }
        let release = ((try? String(contentsOfFile: o.outputDir + "/kernel-release", encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(total: ContinuousClock.now - t0, setup: setupTime, imageBytes: UInt64(st.st_size),
                      imageAllocatedBytes: UInt64(st.st_blocks) * 512, kernelRelease: release)
    }

    /// runProvisioner's console dialogue (UbuntuImageManager.swift, the
    /// `group.addTask` driver), plus the Linux-only kernel/initrd copy-out.
    /// Returns when setup.sh started.
    // @port-skip linux-only: interim stand-in for UbuntuImageManager.runProvisioner's dialogue (VZ-bound on macOS)
    static func runInstaller(_ con: SerialConsole, _ o: Options,
                             progress: @Sendable (String) -> Void) async throws -> ContinuousClock.Instant {
        let prompt = "localhost:~#"
        progress("Installer: waiting for the prompt…")
        try await con.buffer.wait(for: "localhost login:", timeout: 180, failures: ["Kernel panic"])
        progress("Installer: signing in…")
        con.send("root")
        try await con.buffer.wait(for: prompt, timeout: 30, failures: [])
        con.send("NIC=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|enp|ens)/ {print $2; exit}')")
        try await con.buffer.wait(for: prompt, timeout: 10, failures: [])
        progress("Installer: configuring the network…")
        con.send("[ -n \"$NIC\" ] && ip link set dev \"$NIC\" mtu \(o.mtu) 2>/dev/null || true")
        try await con.buffer.wait(for: prompt, timeout: 10, failures: [])
        progress("Installer: checking the network…")
        con.send("if [ -n \"$NIC\" ] && ! ip -4 -o addr show dev \"$NIC\" | grep -q 'inet '; then udhcpc -i \"$NIC\" -q -n 2>/dev/null || true; fi")
        try await con.buffer.wait(for: prompt, timeout: 60, failures: [])
        con.send("[ -n \"$NIC\" ] && echo \"bromure: $NIC MTU=$(cat /sys/class/net/$NIC/mtu)\"")
        try await con.buffer.wait(for: prompt, timeout: 10, failures: [])
        // The markers are split in the typed line ("…_\"OK\"") so the
        // terminal's echo of the command can't match them; only the
        // command's output can.
        con.send("if ip -4 -o addr show dev \"$NIC\" 2>/dev/null | grep -q 'inet '; then echo SANDBOX_NETWORK_\"OK\"; else echo SANDBOX_NO_\"NETWORK\"; fi")
        do {
            try await con.buffer.wait(for: "SANDBOX_NETWORK_OK", timeout: 30, failures: ["SANDBOX_NO_NETWORK"])
        } catch BakeError.installerReportedFailure {
            throw BakeError.noGuestNetwork
        }
        progress("Installer: mounting setup files…")
        con.send("modprobe virtiofs && mkdir -p /tmp/setup /tmp/out && mount -t virtiofs setup /tmp/setup && mount -t virtiofs out /tmp/out && echo MOUNTS_\"OK\"")
        try await con.buffer.wait(for: "MOUNTS_OK", timeout: 60, failures: ["mount:"])

        progress("Installer: running setup.sh…")
        let t = ContinuousClock.now
        let mirror = o.ubuntuMirror.map { "UBUNTU_MIRROR='\($0)' " } ?? ""
        con.send("\(mirror)ALPINE_REPO_BASE='\(o.alpineCDN)' sh /tmp/setup/setup.sh \(o.displayScale)")
        try await con.buffer.wait(for: "SANDBOX_SETUP_DONE", timeout: o.setupTimeout.seconds,
                                  failures: ["SANDBOX_SETUP_FAILED:", "Kernel panic", "Internal error: Oops"])
        progress("Installer: copying the kernel and initrd out…")
        con.send("mkdir -p /mnt && mount -o ro /dev/vda2 /mnt && cp -L /mnt/boot/vmlinuz /tmp/out/vmlinuz && cp -L /mnt/boot/initrd.img /tmp/out/initrd.img && ls /mnt/lib/modules > /tmp/out/kernel-release && umount /mnt && sync && echo EXTRACT_\"OK\"")
        try await con.buffer.wait(for: "EXTRACT_OK", timeout: 120, failures: ["No such file", "mount:"])
        con.send("poweroff")
        return t
    }

    /// A copy of vm-setup for the `setup` share. One rewrite, asserted:
    /// setup.sh hands ALPINE_REPO_BASE to the chroot as BROMURE_PROXY even
    /// when it's the plain CDN (no host proxy), which its outer half
    /// deliberately doesn't treat as a proxy; apt then sends every Ubuntu
    /// request to dl-cdn.alpinelinux.org as a forward proxy and fails. Same
    /// condition as the outer half here, until setup.sh fixes it.
    // @port-skip linux-only: interim bake staging (workaround for setup.sh's BROMURE_PROXY with no proxy)
    static func stageSetup(from src: String, to dst: String, alpineRepoBase: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dst)
        try fm.copyItem(atPath: src, toPath: dst)
        guard alpineRepoBase == "http://dl-cdn.alpinelinux.org" else { return }
        let path = dst + "/setup.sh"
        let s = try String(contentsOfFile: path, encoding: .utf8)
        let from = "    echo \"BROMURE_PROXY=$ALPINE_REPO_BASE\"\n"
        guard s.components(separatedBy: from).count == 2 else {
            throw BakeError.staging("setup.sh: the BROMURE_PROXY line moved; check the workaround is still needed")
        }
        let to = "    if [ \"$ALPINE_REPO_BASE\" != \"http://dl-cdn.alpinelinux.org\" ]; then echo \"BROMURE_PROXY=$ALPINE_REPO_BASE\"; fi\n"
        try s.replacingOccurrences(of: from, with: to).write(toFile: path, atomically: true, encoding: .utf8)
    }

    // @port UbuntuImageManager.downloadAlpineNetboot(progress: @escaping(String)->Void) h=896d7225fec08f0a @84e171b8
    static func downloadAlpineNetboot(cacheDir: String, releasesBase base: String,
                                      kernel: String, initrd: String) async throws {
        let tarballName = "alpine-netboot-\(alpineRelease)-\(alpineArch).tar.gz"
        let tarball = URL(fileURLWithPath: cacheDir + "/" + tarballName)
        let checksum = URL(fileURLWithPath: cacheDir + "/" + tarballName + ".sha256")
        try await downloadFile(from: URL(string: "\(base)/\(tarballName).sha256")!, to: checksum)
        let line = try String(contentsOf: checksum, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = String(line.split(separator: " ").first ?? "")
        guard expected.count == 64 else { throw BakeError.checksumInvalid("expected 64 hex chars, got \(expected.count)") }
        try await downloadFile(from: URL(string: "\(base)/\(tarballName)")!, to: tarball)
        let actual = try sha256(of: tarball)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: tarball)
            throw BakeError.checksumInvalid("\(tarballName): expected \(expected), got \(actual)")
        }
        let extract = cacheDir + "/alpine-netboot-extract"
        try? FileManager.default.removeItem(atPath: extract)
        try FileManager.default.createDirectory(atPath: extract, withIntermediateDirectories: true)
        try await ChildProcess.run("/usr/bin/tar", ["xzf", tarball.path, "-C", extract,
                                                    "boot/vmlinuz-virt", "boot/initramfs-virt"])
        // An x86 bzImage boots as-is: no extractRawKernel (arm64's PE + gzip) step.
        for (from, to) in [("vmlinuz-virt", kernel), ("initramfs-virt", initrd)] {
            try? FileManager.default.removeItem(atPath: to)
            try FileManager.default.moveItem(atPath: extract + "/boot/" + from, toPath: to)
        }
        try? FileManager.default.removeItem(atPath: extract)
        try? FileManager.default.removeItem(at: tarball)
        try? FileManager.default.removeItem(at: checksum)
    }

    // @port UbuntuImageManager.createSparseDisk(at: URL, sizeBytes: UInt64) h=11b6990305d54b00 @84e171b8
    static func createSparseDisk(atPath path: String, sizeBytes: UInt64) throws {
        try? FileManager.default.removeItem(atPath: path)
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MachineError.io("open \(path)", errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else { throw MachineError.io("ftruncate \(path)", errno) }
    }

    // @port UbuntuImageManager.static sha256(of: URL) h=435b35a458e1d3e6 @84e171b8
    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // @port UbuntuImageManager.static downloadFile(from: URL, to: URL) h=799d804ba1224018 @84e171b8
    static func downloadFile(from src: URL, to dst: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: src)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BakeError.downloadFailed(http.statusCode)
        }
        try? FileManager.default.removeItem(at: dst)
        try data.write(to: dst)
    }
}

// @port-skip linux-only: interim bake errors (UbuntuImageError's subset)
public enum BakeError: Error, CustomStringConvertible {
    case downloadFailed(Int)
    case checksumInvalid(String)
    case installerReportedFailure(String)
    case installerTimeout(String)
    case noGuestNetwork
    case staging(String)
    case serial(String)

    // @port-skip linux-only: interim bake errors
    public var description: String {
        switch self {
        case .downloadFailed(let s): return "download failed: HTTP \(s)"
        case .checksumInvalid(let m): return "checksum mismatch: \(m)"
        case .installerReportedFailure(let m): return "installer failed: \(m)"
        case .installerTimeout(let m): return "installer timed out waiting for \(m)"
        case .noGuestNetwork: return "the installer VM got no network"
        case .staging(let m): return "staging vm-setup: \(m)"
        case .serial(let m): return "serial console: \(m)"
        }
    }
}

/// Guest serial output, with "wait for a marker, fail on another".
///
/// Unlike the macOS original, a wait consumes what it matched: it searches
/// only past the previous match. The original searches the whole log, so
/// every `localhost:~#` wait after the first returns at once, and a marker
/// the terminal echoes back in the typed command (`echo SANDBOX_NETWORK_OK`)
/// matches before the command has run.
// @port-skip linux-only: container of ConsoleBuffer's port
final class ConsoleBuffer: Sendable {
    private let state = NIOLockedValueBox<(data: Data, cursor: Int)>((Data(), 0))

    // @port ConsoleBuffer.append(_: Data) h=26a1bce1a016a088 @84e171b8
    func append(_ chunk: Data) {
        state.withLockedValue { $0.data.append(chunk) }
    }

    // @port ConsoleBuffer.text() h=97f02130fe86c673 @84e171b8
    func text() -> String {
        state.withLockedValue { String(decoding: $0.data, as: UTF8.self) }
    }

    // @port ConsoleBuffer.wait(for: String, timeout: TimeInterval, failures: [String]) h=b932ab4808385daa @84e171b8
    func wait(for marker: String, timeout: TimeInterval, failures: [String]) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let r: Result<Bool, BakeError> = state.withLockedValue { s in
                let tail = s.data[(s.data.startIndex + s.cursor)...]
                let hit = tail.range(of: Data(marker.utf8))
                for f in failures {
                    if let fr = tail.range(of: Data(f.utf8)), hit == nil || fr.lowerBound < hit!.lowerBound {
                        let line = s.data[fr.lowerBound...].prefix(200).split(separator: 10).first.map { Data($0) } ?? Data()
                        return .failure(.installerReportedFailure(String(decoding: line, as: UTF8.self)))
                    }
                }
                guard let hit else { return .success(false) }
                s.cursor = hit.upperBound - s.data.startIndex
                return .success(true)
            }
            if try r.get() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BakeError.installerTimeout(marker)
    }
}

/// The installer's serial console: QEMU's `-chardev socket` (server side),
/// read by a thread into a ConsoleBuffer; lines typed with `send`.
// @port-skip linux-only: QEMU serial socket (VZFileHandleSerialPortAttachment's pipes on macOS)
final class SerialConsole: Sendable {
    let buffer = ConsoleBuffer()
    private let fd: Int32
    private let done = DispatchSemaphore(value: 0)

    // @port-skip linux-only: QEMU serial socket
    init(path: String, output: @escaping @Sendable (Data) -> Void) throws {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw MachineError.io("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in
            for (i, c) in path.utf8.prefix(b.count - 1).enumerated() { b[i] = c }
        }
        var connected = false
        for _ in 0..<200 {
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if r == 0 { connected = true; break }
            usleep(50_000)
        }
        guard connected else { Glibc.close(fd); throw BakeError.serial("connect \(path): \(String(cString: strerror(errno)))") }
        self.fd = fd
        let buffer = buffer, done = done
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    let d = Data(buf[0..<n])
                    buffer.append(d)
                    output(d)
                } else if n < 0 && errno == EINTR { continue } else { break }
            }
            done.signal()
        }
        t.name = "bake-serial"
        t.start()
    }

    /// Types `line` and Enter.
    // @port-skip linux-only: QEMU serial socket
    func send(_ line: String) {
        let d = Array((line + "\n").utf8)
        var off = 0
        while off < d.count {
            let n = d[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            off += n
        }
    }

    // @port-skip linux-only: QEMU serial socket
    func close() {
        shutdown(fd, Int32(SHUT_RDWR))
        done.wait()
        Glibc.close(fd)
    }
}

extension Duration {
    // @port-skip linux-only: Duration helper
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
