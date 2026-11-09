import CACLinuxShims
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers
import SandboxEngine

/// STAND-IN for UbuntuImageManager.createBaseImage on Linux: bakes the amd64
/// guest image under Firecracker/KVM with the shared vm-setup scripts. The bake
/// *logic* (catalog, downloads, the serial dialogue, version stamps) moves to
/// ACCore against a `ProvisionerVM` protocol in the carve-out; until then this
/// mirrors its steps:
///   1. Alpine netboot (x86_64 here), sha256-checked, cached;
///   2. InitrdShim's `/init.bromure` appended (DHCP + MTU before Alpine's /init);
///   3. the installer VM (Firecracker): the target disk, virtiofs `setup`
///      (vm-setup, read-only), passt behind the interim switch, the serial
///      console on pipes;
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
        /// The catalog's postinstall steps (the agent CLIs: Claude Code,
        /// Codex, Grok, …), applied after setup.sh as macOS's
        /// createBaseImage(postinstallSteps:) does. Empty: none.
        public var postinstallSteps: [PostinstallStep] = []
        /// The user's customize script, run as root in the image after the
        /// steps (macOS: UbuntuImageManager.customizeScript). nil: none.
        public var customizeScript: String?
        /// Where the customize run's output is kept (the whole postinstall
        /// phase), when there's a script.
        public var customizeLogPath: String?
        public var postinstallTimeout: Duration = .seconds(1800)
        /// Amend the live base.img instead of building one (macOS:
        /// applyPostinstallSteps): `postinstallSteps` (the ones published
        /// since) run on a copy of it, setup.sh doesn't run, no customize
        /// script, and the image's applied steps gain them.
        public var amend = false
        /// A downloaded image to finish instead of building one (macOS:
        /// downloadBaseImage's postinstall boot): its expanded disk becomes
        /// the scratch disk, setup.sh doesn't run, postinstall.sh always
        /// does (every catalog step, then the customize script).
        public var downloaded: Downloaded?
        // @port-skip linux-only: see Options.downloaded
        public struct Downloaded: Sendable {
            /// The expanded disk, in the output dir (moved, not copied).
            public var disk: String
            public var imageUUID: String
            public var version: String
            // @port-skip linux-only: see Options.downloaded
            public init(disk: String, imageUUID: String, version: String) {
                self.disk = disk
                self.imageUUID = imageUUID
                self.version = version
            }
        }
        /// The image an amend starts from, when not the output dir's own
        /// (a multi-user daemon's first amend of the shared image: its copy
        /// goes to the user's image dir). nil: the output dir's.
        public var amendFrom: String?
        /// The bundled catalog, for an image older than image-state.json
        /// (its steps count as applied: Daemon.appliedPostinstallSteps).
        public var baseline: ImageCatalog?
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
    // partial: Firecracker's installer (Alpine netboot, one boot for setup.sh and postinstall.sh); no EFI vars; always a full build (init's force)
    // @port UbuntuImageManager.createBaseImage(progress: @escaping(String)->Void, output: @escaping(String)->Void, force: Bool, postinstallSteps: [PostinstallStep]) h=a645adca91f3f760 @84e171b8
    // partial: an amend (Options.amend) is a bake on a copy of the live disk: postinstall.sh in the Firecracker installer, promoted as a bake's is
    // @port UbuntuImageManager.applyPostinstallSteps(_: [PostinstallStep], progress: @escaping(String)->Void, output: @escaping(String)->Void) h=6a3b25f95c4159bc @84e171b8
    public static func bake(_ o: Options, progress: @escaping @Sendable (String) -> Void = { _ in },
                            output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Result {
        // An amend runs the catalog's new steps only (macOS: runPostinstall
        // with customize false).
        var o = o
        if o.amend { o.customizeScript = nil }
        let fm = FileManager.default
        let t0 = ContinuousClock.now
        try fm.createDirectory(atPath: o.outputDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(atPath: o.cacheDir, withIntermediateDirectories: true)
        // One bake per output dir: two would share .work and the partial disk.
        let lock = open(o.outputDir + "/.bake.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw MachineError.io("open \(o.outputDir)/.bake.lock", errno) }
        defer { Glibc.close(lock) }
        // A daemon's start holds it a moment (finishPromotionIfIdle): waited for.
        var locked = false
        for _ in 0..<50 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard locked else { throw BakeError.staging("another bake is running into \(o.outputDir)") }
        // The stamp on disk before this bake, for the next revision: a
        // rebuild at the same major bumps 201 → 201.1; a new major writes fresh.
        // A promotion a crash cut short (its disk live): finished first, or
        // the stamp below would be the old one's.
        if !fm.fileExists(atPath: o.outputDir + "/base.img.partial") { _ = finishPromotion(imageDir: o.outputDir) }
        // An amend's image is its source's (the output dir's, or the one it
        // copies from).
        let source = o.amend ? o.amendFrom ?? o.outputDir : o.outputDir
        let priorStamp = (try? String(contentsOfFile: source + "/base.version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var priorApplied: [String] = []
        if o.amend {
            guard fm.fileExists(atPath: source + "/base.img"), priorStamp != nil else {
                throw BakeError.staging("no base image to amend")
            }
            // Read under the lock: what the image has now, not when the
            // question was asked (it may have been rebuilt or amended since).
            priorApplied = Daemon.appliedPostinstallSteps(imageDir: source, baseline: o.baseline ?? ImageCatalog(postinstall: []))
            o.postinstallSteps.removeAll { priorApplied.contains($0.uuid) }
            guard !o.postinstallSteps.isEmpty else { throw BakeError.staging("no steps to amend the image with") }
        }
        // An amend keeps the image's own major (macOS: applyPostinstallSteps'
        // bundledMajor): a dot revision, which the drift check offers.
        // A download's is the published image's major (macOS: the same).
        let bundled = o.downloaded.map { majorVersion(of: $0.version) }
            ?? (o.amend ? priorStamp.map(majorVersion(of:)) ?? o.imageVersion : o.imageVersion)
        let newStamp = nextStamp(priorStamp: priorStamp, bundled: bundled)
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
        // 3. The setup share, the catalog's postinstall steps and an empty
        // target disk.
        let setup = work + "/setup"
        try stageSetup(from: o.vmSetupDir, to: setup, alpineRepoBase: o.alpineCDN)
        let postinstall = work + "/postinstall"
        let steps = try stagePostinstall(o.postinstallSteps, to: postinstall)
        if let script = o.customizeScript { try stageCustomize(script, to: postinstall) }
        // A download's postinstall boot runs even with no steps: it also
        // restores resolv.conf and checks the downloaded file system.
        let runsPostinstall = !steps.isEmpty || o.customizeScript != nil || o.downloaded != nil
        if runsPostinstall { try fm.createDirectory(atPath: postinstall + "/steps", withIntermediateDirectories: true) }
        let partial = o.outputDir + "/base.img.partial"
        // An amend's scratch disk is a copy of the live one (macOS: an APFS
        // clone; here a reflink where the filesystem has them, holes kept).
        let applied: [String]
        if let d = o.downloaded {
            try? fm.removeItem(atPath: partial)
            guard rename(d.disk, partial) == 0 else { throw MachineError.io("rename \(d.disk)", errno) }
            progress(steps.isEmpty ? "Finalizing image…"
                     : "Installing recommended packages (\(steps.count) step(s), ~2-5 min)…")
            applied = steps
        } else if o.amend {
            try? fm.removeItem(atPath: partial)
            progress("Installing recommended packages (\(steps.count) step(s))…")
            try await ChildProcess.run("/usr/bin/cp", ["--reflink=auto", "--sparse=always", source + "/base.img", partial])
            // Ours to write (a shared image's copy would keep its read-only mode).
            guard chmod(partial, 0o644) == 0 else { throw MachineError.io("chmod \(partial)", errno) }
            applied = Self.amendedSteps(prior: priorApplied, adding: steps)
        } else {
            try createSparseDisk(atPath: partial, sizeBytes: UInt64(o.diskGiB) << 30)
            applied = steps
        }
        // A failed bake discards its scratch disk, as macOS's createBaseImage
        // does: the live image is untouched.
        var promoted = false
        defer {
            if !promoted {
                // The .new set first: without it, nothing can roll forward
                // over the old disk, whatever happens to the partial.
                discardPromotion(imageDir: o.outputDir)
                try? fm.removeItem(atPath: partial)
            }
        }

        let modloop = "\(o.alpineCDN)/alpine/v\(alpineVersion)/releases/\(alpineArch)/netboot-\(alpineRelease)/modloop-virt"
        var c = MachineConfig(
            name: "bromure-bake", kernel: kernel, initrd: shimmed,
            cmdline: "console=ttyS0 rdinit=/init.bromure alpine_repo=\(o.alpineCDN)/alpine/v\(alpineVersion)/main "
                + "modloop=\(modloop) modules=loop,squashfs,virtio_mmio,virtio-net,virtio-blk,virtiofs",
            baseImage: partial, overlay: "", vsockCID: 3, runDirectory: runDir)
        c.writeBaseInPlace = true
        c.vsock = false
        c.entropy = true
        c.cpus = o.cpus
        c.memoryMiB = o.memoryMiB
        // Root in the installer reads and writes as the bake's user.
        c.shares = [.init(tag: "setup", hostPath: setup, readOnly: true, guestOwner: nil),
                    .init(tag: "out", hostPath: work + "/out", guestOwner: nil)]
        if runsPostinstall { c.shares.append(.init(tag: "postinstall", hostPath: postinstall, readOnly: true, guestOwner: nil)) }
        c.serialLog = work + "/firecracker-stderr.log"
        c.macAddress = "52:54:00:ba:4e:01"
        // The network the daemon's VMs have: passt behind the interim switch
        // (its DHCP), over a datagram socketpair.
        let passt = try await PasstUplink.start(PasstUplink.Config(logPath: work + "/passt.log"))
        let sw = InterimSwitch(uplink: passt, mtu: { [mtu = o.mtu] _ in mtu })
        let port: DgramPort, peer: Int32
        do { (port, peer) = try DgramPort.pair(name: "bake") } catch { sw.stop(); await passt.close(); throw error }
        sw.attach(port, mac: c.macAddress!)
        c.network = .datagram(peerFD: peer)
        defer { sw.detach(mac: c.macAddress!); port.close(); sw.stop() }
        // The serial console: Firecracker's stdin and stdout, as pipes.
        var toGuest: [Int32] = [-1, -1], fromGuest: [Int32] = [-1, -1]
        guard acl_pipe_cloexec(&toGuest) == 0, acl_pipe_cloexec(&fromGuest) == 0 else {
            let e = errno
            for fd in toGuest + fromGuest where fd >= 0 { Glibc.close(fd) }
            await passt.close()
            throw MachineError.io("pipe", e)
        }
        c.consolePipes = (input: toGuest[0], output: fromGuest[1])
        let customizeLog = CustomizeLog(path: o.customizeScript != nil ? o.customizeLogPath : nil)
        let console = SerialConsole(readFD: fromGuest[0], writeFD: toGuest[1], log: work + "/serial.log",
                                    output: { customizeLog.write($0); output($0) })
        defer { console.close(); customizeLog.close() }
        let vm = FirecrackerMachine(config: c)
        progress("Starting the installer VM…")
        do { try await vm.start() } catch { await passt.close(); throw error }

        // 4-5. The console dialogue.
        var tSetup = ContinuousClock.now
        do {
            tSetup = try await runInstaller(console, o, postinstallSteps: steps.count, progress: progress,
                                            postinstallStarts: { customizeLog.start() })
        } catch {
            await vm.kill()
            await passt.close()
            try? fm.copyItem(atPath: work + "/serial.log", toPath: o.outputDir + "/bake.log.failed")
            throw customizeFailure(error, o)
        }
        let setupTime = ContinuousClock.now - tSetup
        progress("Shutting down the installer…")
        // The dialogue ends with `reboot`: with reboot=k, Firecracker exits.
        let stopped = await withTaskGroup(of: FirecrackerMachine.StopInfo?.self) { g in
            g.addTask { await vm.waitUntilStopped() }
            g.addTask { try? await Task.sleep(for: .seconds(30)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        if stopped == nil { progress("Forcing shutdown…"); await vm.stop(timeout: .seconds(5)) }
        await passt.close()

        // Artefacts.
        let finalImage = o.outputDir + "/base.img"
        // Firecracker's virtio-blk has no discard: setup.sh's fstrim freed
        // nothing on the host, and the image is allocated to its full size.
        // Its zero blocks become holes again (24 GiB -> ~7 GiB).
        progress("Making the image sparse…")
        do { try await ChildProcess.run("/usr/bin/fallocate", ["--dig-holes", partial]) }
        catch { progress("fallocate --dig-holes failed (\(error)); the image stays fully allocated") }
        // Promote (macOS: step 5): the boot files staged under temp names
        // beside the image first, so nothing live changes until the disk's
        // rename(2) over base.img; then each boot file the same way, and
        // the stamp last. A failure before the disk's rename leaves the
        // live image whole.
        // ia32_emulation=0 as setup.sh's GRUB line: no 32-bit syscall entry,
        // which the kernel sentry (64-bit wrappers only) doesn't watch.
        try "console=ttyS0 root=LABEL=root rootfstype=ext4 ro quiet ia32_emulation=0\n"
            .write(toFile: work + "/out/cmdline", atomically: true, encoding: .utf8)
        try (newStamp + "\n").write(toFile: work + "/out/base.version", atomically: true, encoding: .utf8)
        // Which catalog steps the image has, as macOS records a local build.
        try ImageState.encoded(BaseImageState(imageUUID: o.downloaded?.imageUUID
                                                  ?? (o.amend ? ImageState.load(imageDir: source)?.imageUUID : nil),
                                              version: newStamp, appliedStepUUIDs: applied))
            .write(to: URL(fileURLWithPath: work + "/out/image-state.json"))
        discardPromotion(imageDir: o.outputDir)
        for f in promotedFiles {
            try fm.moveItem(atPath: work + "/out/" + f, toPath: o.outputDir + "/" + f + ".new")
        }
        // Which disk the set belongs to: the partial's identity, which the
        // rename carries over to base.img. Written last, so a set without it
        // is incomplete (never rolled forward).
        guard let identity = diskIdentity(partial) else { throw MachineError.io("stat \(partial)", errno) }
        try identity.write(toFile: o.outputDir + "/" + promotionMarker, atomically: true, encoding: .utf8)
        guard rename(partial, finalImage) == 0 else { throw MachineError.io("rename \(partial)", errno) }
        promoted = true
        // From here the new disk is live: the rest rolls forward (here, or
        // at the next bake's or daemon's start: finishPromotion).
        if let left = finishPromotion(imageDir: o.outputDir) {
            throw MachineError.io("rename \(left).new (the next bake or daemon start finishes it)", errno)
        }
        try? fm.removeItem(atPath: o.outputDir + "/postinstall-steps")
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
    static func runInstaller(_ con: SerialConsole, _ o: Options, postinstallSteps: Int = 0,
                             progress: @Sendable (String) -> Void,
                             postinstallStarts: () -> Void = {}) async throws -> ContinuousClock.Instant {
        let prompt = "localhost:~#"
        progress("Installer: waiting for the prompt…")
        try await con.buffer.wait(for: "localhost login:", timeout: 180, failures: ["Kernel panic"])
        progress("Installer: signing in…")
        con.send("root")
        try await con.buffer.wait(for: prompt, timeout: 30, failures: [])
        con.send("NIC=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|enp|ens)/ {print $2; exit}')")
        try await con.buffer.wait(for: prompt, timeout: 10, failures: [])
        // Firecracker gives the guest no RTC: its wall clock starts far in
        // the past, and apt refuses the archive's Release files as "not
        // valid yet". The host's time, before anything checks a date.
        con.send("date -s @\(Int(Date().timeIntervalSince1970)) >/dev/null")
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

        let t = ContinuousClock.now
        // An amend's or a download's disk is a finished image:
        // postinstall.sh alone (macOS: runPostinstall's own installer boot).
        if !o.amend, o.downloaded == nil {
            progress("Installer: running setup.sh…")
            let mirror = o.ubuntuMirror.map { "UBUNTU_MIRROR='\($0)' " } ?? ""
            con.send("\(mirror)ALPINE_REPO_BASE='\(o.alpineCDN)' sh /tmp/setup/setup.sh \(o.displayScale)")
            try await con.buffer.wait(for: "SANDBOX_SETUP_DONE", timeout: o.setupTimeout.seconds,
                                      failures: ["SANDBOX_SETUP_FAILED:", "Kernel panic", "Internal error: Oops"])
        }
        if postinstallSteps > 0 || o.customizeScript != nil || o.downloaded != nil {
            // macOS runs postinstall.sh in a second installer boot on the
            // finished disk; the same installer is still up here.
            progress("Installer: installing the agent CLIs (\(postinstallSteps) catalog step(s))…")
            if o.customizeScript != nil, let log = o.customizeLogPath {
                progress("Your customize script runs after the recommended packages (log: \(log))")
            }
            postinstallStarts()
            con.send("sh /tmp/setup/postinstall.sh")
            // A customize script compiling a toolchain can take a while
            // (macOS: 90 minutes for the phase with one, else 20).
            let timeout = o.customizeScript == nil ? o.postinstallTimeout : max(o.postinstallTimeout, .seconds(90 * 60))
            // The markers only at a line's start: the customize step's
            // `set -x` trace ("+ [customize] echo …") can't end the wait.
            try await con.buffer.wait(for: "\nSANDBOX_POSTINSTALL_DONE", timeout: timeout.seconds,
                                      failures: ["\nSANDBOX_POSTINSTALL_FAILED:", "Kernel panic", "Internal error: Oops"])
        }
        progress("Installer: copying the kernel and initrd out…")
        con.send("mkdir -p /mnt && mount -o ro /dev/vda2 /mnt && cp -L /mnt/boot/vmlinuz /tmp/out/vmlinuz && cp -L /mnt/boot/initrd.img /tmp/out/initrd.img && ls /mnt/lib/modules > /tmp/out/kernel-release && umount /mnt && sync && echo EXTRACT_\"OK\"")
        try await con.buffer.wait(for: "EXTRACT_OK", timeout: 120, failures: ["No such file", "mount:"])
        // A reboot, not a poweroff: Firecracker (reboot=k) exits on it; x86
        // has no ACPI poweroff it would see.
        con.send("reboot")
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
    /// The postinstall steps as `steps/NNNN-<uuid8>.sh` (lexical order is
    /// execution order; line 1 is the description postinstall.sh echoes),
    /// exactly as UbuntuImageManager.runPostinstall writes them. Returns
    /// the steps' uuids, in order; none staged for none.
    // partial: the staging half; the run is runInstaller's postinstall.sh (no customize script on Linux yet)
    // @port UbuntuImageManager.runPostinstall(steps: [PostinstallStep], targetDisk: URL, environmentOverride: InstallerEnvironment?, customize: Bool, progress: @escaping(String)->Void, output: @escaping(String)->Void) h=200f100bc32062a1 @84e171b8
    static func stagePostinstall(_ steps: [PostinstallStep], to dir: String) throws -> [String] {
        guard !steps.isEmpty else { return [] }
        let stepsDir = dir + "/steps"
        try FileManager.default.createDirectory(atPath: stepsDir, withIntermediateDirectories: true)
        let ordered = steps.sorted { ($0.seq, $0.uuid) < ($1.seq, $1.uuid) }
        for step in ordered {
            let title = step.description.replacingOccurrences(of: "\n", with: " ")
            try "# \(title)\nset -e\n\(step.command)\n".write(
                toFile: stepsDir + "/" + String(format: "%04d-%@.sh", step.seq, String(step.uuid.prefix(8))),
                atomically: true, encoding: .utf8)
        }
        return ordered.map(\.uuid)
    }

    /// An amended image's applied steps: what it had, and the new ones
    /// (macOS: applyPostinstallSteps' union, sorted).
    // @port-skip linux-only: see bake's amend (macOS: inline in applyPostinstallSteps)
    static func amendedSteps(prior: [String], adding steps: [String]) -> [String] {
        Set(prior).union(steps).sorted()
    }

    /// What a bake promotes beside base.img, staged as `<name>.new` before
    /// the disk's rename: the boot files, then the stamp and image state.
    static let promotedFiles = ["vmlinuz", "initrd.img", "kernel-release", "cmdline", "base.version", "image-state.json"]

    /// The `.new` set's marker: the identity of the disk it belongs to.
    static let promotionMarker = "promotion.new"

    /// A disk's identity (device, inode, size, mtime): what a rename keeps.
    // @port-skip linux-only: the bake's roll-forward
    static func diskIdentity(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev) \(st.st_ino) \(st.st_size) \(st.st_mtim.tv_sec) \(st.st_mtim.tv_nsec)\n"
    }

    /// The `.new` set and its marker, gone.
    // @port-skip linux-only: the bake's roll-forward
    static func discardPromotion(imageDir dir: String) {
        for f in promotedFiles { try? FileManager.default.removeItem(atPath: dir + "/" + f + ".new") }
        try? FileManager.default.removeItem(atPath: dir + "/" + promotionMarker)
    }

    /// Finishes a promotion whose disk is live but whose `.new` files
    /// aren't all in place: renames them over, in order, the stamp last,
    /// then its marker. Only when base.img is the disk the marker names: a
    /// set without it, or for another disk (a failed bake's, its partial
    /// gone), is discarded, never rolled over the live image. A partial
    /// beside the set is a bake under way or cut short before its disk's
    /// rename: left for the next bake. Nil when done (or nothing to do),
    /// else the file that couldn't be renamed.
    // @port-skip linux-only: the bake's roll-forward
    @discardableResult
    public static func finishPromotion(imageDir dir: String) -> String? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir + "/base.img.partial") else { return nil }
        let marker = dir + "/" + promotionMarker
        let pending = promotedFiles.contains { fm.fileExists(atPath: dir + "/" + $0 + ".new") }
        guard pending || fm.fileExists(atPath: marker) else { return nil }
        guard let want = try? String(contentsOfFile: marker, encoding: .utf8),
              want == diskIdentity(dir + "/base.img") else {
            discardPromotion(imageDir: dir)
            return nil
        }
        for f in promotedFiles where fm.fileExists(atPath: dir + "/" + f + ".new") {
            // ENOENT: another finisher (the bake, a daemon start) got there first.
            guard rename(dir + "/" + f + ".new", dir + "/" + f) == 0 || errno == ENOENT else { return f }
        }
        try? fm.removeItem(atPath: marker)
        return nil
    }

    /// finishPromotion at a daemon's start, unless a bake holds the dir (it
    /// finishes its own) or the dir isn't this user's to write.
    // @port-skip linux-only: the bake's roll-forward
    public static func finishPromotionIfIdle(imageDir dir: String) {
        let lock = open(dir + "/.bake.lock", O_RDWR | O_CLOEXEC)
        guard lock >= 0 else {
            // No lock file: no bake ever ran here with the lock.
            if errno == ENOENT, access(dir, W_OK) == 0 { finishPromotion(imageDir: dir) }
            return
        }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        if let left = finishPromotion(imageDir: dir) {
            FileHandle.standardError.write(Data("bromure-ac daemon: the image's last bake left \(left).new: couldn't rename it (\(String(cString: strerror(errno))))\n".utf8))
        }
    }

    /// The major component of a version stamp: everything before the first
    /// dot. "200" → "200", "200.3" → "200".
    // @port UbuntuImageManager.static majorVersion(of: String) h=70093b72eb8a901b @84e171b8
    static func majorVersion(of stamp: String) -> String {
        String(stamp.prefix { $0 != "." })
    }

    /// The stamp to write for the image about to be promoted: a rebuild at
    /// the same major bumps a dot-revision so existing workspaces (which
    /// recorded the prior stamp at clone time) detect drift and get offered
    /// a reset: 200 → 200.1 → 200.2 …; a different major, or no prior
    /// stamp, writes the bundled version fresh.
    /// Linux: a dotted `--image-version` (201.3) bumps from there once the
    /// stamp on disk has reached it (macOS's bundled version has no dot).
    // partial: a dotted bundled version bumps too
    // @port UbuntuImageManager.static nextStamp(priorStamp: String?, bundled: String) h=d0a2eebb43a83c3a @84e171b8
    static func nextStamp(priorStamp: String?, bundled: String) -> String {
        guard let prior = priorStamp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prior.isEmpty,
              majorVersion(of: prior) == majorVersion(of: bundled),
              bundled == majorVersion(of: bundled) || !Daemon.baseVersion(bundled, isNewerThan: prior)
        else { return bundled }
        let rev: Int
        if let dot = prior.firstIndex(of: "."),
           let n = Int(prior[prior.index(after: dot)...]) {
            rev = n
        } else {
            rev = 0
        }
        return "\(majorVersion(of: bundled)).\(rev + 1)"
    }

    /// Where the last customize run's output is kept (the whole postinstall
    /// phase, the script's `bash -x` trace included): the daemon's state
    /// dir, the XDG home for logs (macOS: ~/Library/Logs/BromureAC).
    // @port UbuntuImageManager.static var customizeLogURL h=c75adbd0980e1172 @84e171b8
    public static var customizeLogPath: String {
        DaemonConfig.fromEnvironment().stateDir + "/base-image-customize.log"
    }

    /// The step file for the user's script: traced (`set -x`, each line
    /// tagged), so the log shows every command it ran; named so
    /// postinstall.sh runs it last and only once (`*-customize.sh`).
    /// Linux: "zzzz-", past any %04d seq (macOS: "9999-", which a seq of
    /// 9999 or more would sort after).
    static let customizeStepName = "zzzz-customize.sh"
    // @port UbuntuImageManager.static customizeStep(_: String) h=f9234cd17d64ecf3 @84e171b8
    static func customizeStep(_ script: String) -> String {
        "# Your customize script\nexport PS4='+ [customize] '\nset -x\n" + script + "\n"
    }

    /// `script` as the last step file (macOS: runPostinstall's customize half).
    // partial: the customize half of runPostinstall's staging
    // @port-skip linux-only: see stagePostinstall
    static func stageCustomize(_ script: String, to dir: String) throws {
        let stepsDir = dir + "/steps"
        try FileManager.default.createDirectory(atPath: stepsDir, withIntermediateDirectories: true)
        try customizeStep(script).write(toFile: stepsDir + "/" + customizeStepName, atomically: true, encoding: .utf8)
    }

    /// The installer's failure as the user's script's when it was theirs
    /// (postinstall.sh names the step: "… attempt(s): Your customize
    /// script"), so it doesn't read as Bromure's installer breaking.
    // @port-skip linux-only: runPostinstall's customize-failure mapping (CustomizeFailureFlag on macOS)
    static func customizeFailure(_ error: Error, _ o: Options) -> Error {
        guard o.customizeScript != nil, case BakeError.installerReportedFailure(let line) = error,
              line.contains("attempt(s): Your customize script") else { return error }
        // As macOS abbreviates it (corelibs Foundation has no abbreviatingWithTildeInPath).
        let log = o.customizeLogPath ?? "the bake log", home = NSHomeDirectory()
        return BakeError.customizeScriptFailed(log: log.hasPrefix(home + "/") ? "~" + log.dropFirst(home.count) : log)
    }

    // @port-skip linux-only: the Linux bake fetches Alpine's netboot kernel itself
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
    case customizeScriptFailed(log: String)
    case serial(String)

    // @port-skip linux-only: interim bake errors
    public var description: String {
        switch self {
        case .downloadFailed(let s): return "download failed: HTTP \(s)"
        case .checksumInvalid(let m): return "checksum mismatch: \(m)"
        case .installerReportedFailure(let m): return "installer failed: \(m)"
        case .customizeScriptFailed(let log): return "Your customize script failed — the current image is kept. See \(log)"
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

/// The installer's serial console: Firecracker's stdout read by a thread
/// into a ConsoleBuffer (and the log), lines typed into its stdin with `send`.
// @port-skip linux-only: serial console pipes (VZFileHandleSerialPortAttachment's pipes on macOS)
final class SerialConsole: Sendable {
    let buffer = ConsoleBuffer()
    private let readFD: Int32
    private let fd: Int32
    private let done = DispatchSemaphore(value: 0)

    // @port-skip linux-only: serial console pipes
    init(readFD: Int32, writeFD: Int32, log: String?, output: @escaping @Sendable (Data) -> Void) {
        self.readFD = readFD
        self.fd = writeFD
        let buffer = buffer, done = done
        let logFD = log.map { open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644) } ?? -1
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n > 0 {
                    let d = Data(buf[0..<n])
                    buffer.append(d)
                    if logFD >= 0 { _ = buf.withUnsafeBytes { write(logFD, $0.baseAddress, n) } }
                    output(d)
                } else if n < 0 && errno == EINTR { continue } else { break }
            }
            if logFD >= 0 { Glibc.close(logFD) }
            done.signal()
        }
        t.name = "bake-serial"
        t.start()
    }

    /// Types `line` and Enter.
    // @port-skip linux-only: serial console pipes
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

    /// Closes the typing end; the reader ends when Firecracker's stdout
    /// does (it exited).
    // @port-skip linux-only: serial console pipes
    func close() {
        Glibc.close(fd)
        done.wait()
        Glibc.close(readFD)
    }
}

extension Duration {
    // @port-skip linux-only: Duration helper
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

/// The customize run's log: the serial output from the start of the
/// postinstall phase on (macOS: runPostinstall's log handle on
/// customizeLogURL, the whole phase kept). No path: nothing kept.
// @port-skip linux-only: the log half of runPostinstall's customize run
final class CustomizeLog: Sendable {
    private let path: String?
    private let handle = NIOLockedValueBox<FileHandle?>(nil)

    // @port-skip linux-only: see CustomizeLog
    init(path: String?) { self.path = path }

    /// Truncates the log to a header and keeps what follows.
    // @port-skip linux-only: see CustomizeLog
    func start() {
        guard let path else { return }
        let fm = FileManager.default
        // The script's `bash -x` trace may hold anything it used: the
        // owner's alone.
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        try? fm.removeItem(atPath: path)
        fm.createFile(atPath: path, contents: Data("Base image customize run — \(Date())\n".utf8),
                      attributes: [.posixPermissions: 0o600])
        let h = FileHandle(forWritingAtPath: path)
        _ = try? h?.seekToEnd()
        handle.withLockedValue { $0 = h }
    }

    // @port-skip linux-only: see CustomizeLog
    func write(_ data: Data) {
        handle.withLockedValue { try? $0?.write(contentsOf: data) }
    }

    // @port-skip linux-only: see CustomizeLog
    func close() {
        handle.withLockedValue { try? $0?.close(); $0 = nil }
    }
}
