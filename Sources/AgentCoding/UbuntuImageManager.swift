import AppKit
import CommonCrypto
import Foundation
@preconcurrency import Virtualization

/// Builds and locates the Ubuntu base image for Bromure Agentic Coding.
///
/// Strategy mirrors the browser's Alpine bootstrapping approach:
///   1. Download the Alpine netboot kernel + initramfs (small, ~25 MB).
///   2. Boot a one-shot installer VM on a fresh raw disk.
///   3. Drive the installer over its serial console: log in, mount our
///      vm-setup virtiofs share, run setup.sh.
///   4. setup.sh debootstraps Ubuntu Noble onto the disk, installs node /
///      rust / claude / codex / wezterm, and grub-installs for EFI boot.
///   5. On SANDBOX_SETUP_DONE, halt and promote the disk to base.img.
///
/// The runtime VM (UbuntuSandboxVM) boots base.img directly via
/// VZEFIBootLoader — no kernel extraction needed because GRUB is on the
/// disk's EFI partition.
public final class UbuntuImageManager {
    /// Bump to force a base-image rebuild on next launch.
    /// **NEVER bump this without explicit user approval** — base-image
    /// rebuilds cost the user ~5 minutes of install time. Prefer landing
    /// changes in host-side managed dotfiles (~/.bashrc, ~/.xinitrc via
    /// Profile.prepareHomeDirectory) which apply on the next launch with
    /// no rebuild.
    ///
    /// Bumped to 27 (with explicit approval) to add xdotool +
    /// x11-xserver-utils to the apt install for native tab switching
    /// and the resize watcher.
    /// Bumped to 28 (with explicit approval) to add `gh` (GitHub CLI)
    /// and `glab` (GitLab CLI) so HTTPS-token profiles get a working
    /// `gh` / `glab` out of the box without an extra `auth login` step.
    /// Bumped to 29 (with explicit approval) to install codex via the
    /// official Rust binary release from github.com/openai/codex
    /// instead of the flaky npm postinstall path.
    /// Bumped to 30 (with explicit approval) to run apt-get
    /// dist-upgrade after the initial bootstrap — the base image now
    /// ships with every security/bug fix that landed since the noble
    /// release, so `apt upgrade` in the user's VM is a no-op on day 1.
    /// Bumped to 31 (with explicit approval) to bake in the cloud
    /// CLIs needed for the Credentials → Cloud sections to work
    /// out of the box: kubectl, doctl, awscli v2, gcloud, az.
    public static let imageVersion = "31"

    /// Ubuntu LTS release we target. Update when a new LTS lands.
    public static let ubuntuRelease = "noble"

    /// Default size of the raw target disk. Roomy because rust toolchains,
    /// node_modules, model caches and project clones all want space.
    public static let baseDiskBytes: UInt64 = 24 * 1024 * 1024 * 1024  // 24 GB

    public static let installerCPUs: Int = 4
    public static let installerMemoryBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GB

    // Alpine netboot release used as the installer environment. Kept in sync
    // with the browser image manager so we don't fork the toolchain version.
    private static let alpineVersion = "3.22"
    private static let alpineRelease = "3.22.3"
    private static var releasesBase: String {
        "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/aarch64"
    }

    private let storageDir: URL
    private let setupDir: URL

    public init(storageDir: URL? = nil, setupDir: URL) {
        self.storageDir = storageDir ?? Self.defaultStorageDirectory
        self.setupDir = setupDir
    }

    public static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("BromureAC", isDirectory: true)
    }

    // MARK: - On-disk paths

    public var baseDiskURL: URL { storageDir.appendingPathComponent("base.img") }
    public var efiVarsURL: URL { storageDir.appendingPathComponent("efivars.bin") }
    public var versionStampURL: URL { storageDir.appendingPathComponent("base.version") }

    private var alpineKernelURL: URL { storageDir.appendingPathComponent("alpine-vmlinuz") }
    private var alpineInitrdURL: URL { storageDir.appendingPathComponent("alpine-initramfs") }

    // MARK: - Status

    /// True when the on-disk artefacts exist, regardless of version
    /// stamp. A stale image still boots — it just won't have the latest
    /// setup.sh additions. Use `baseImageNeedsUpdate` to gate a nag.
    public var hasBaseImage: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: baseDiskURL.path)
            && fm.fileExists(atPath: efiVarsURL.path)
            && fm.fileExists(atPath: versionStampURL.path)
    }

    /// True when an image is present but its stamp doesn't match the
    /// app's bundled `imageVersion`. The app surfaces a non-blocking
    /// "rebuild?" prompt when this is true.
    public var baseImageNeedsUpdate: Bool {
        guard hasBaseImage,
              let stamp = try? String(contentsOf: versionStampURL, encoding: .utf8)
        else { return false }
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines) != Self.imageVersion
    }

    /// On-disk version stamp ("31", "32", …) or nil when no image.
    public var installedImageVersion: String? {
        guard let stamp = try? String(contentsOf: versionStampURL, encoding: .utf8)
        else { return nil }
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public: build

    /// End-to-end base-image build. Idempotent: if the version stamp is
    /// current and all artefacts exist, returns immediately.
    ///
    /// `progress` receives short, human-friendly checkpoints ("Booting
    /// installer…"). `output` receives the raw, line-oriented serial
    /// stream from the installer guest (everything apt / debootstrap /
    /// setup.sh prints) — high-volume; suitable for piping straight into
    /// a console log view.
    public func createBaseImage(
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        if hasBaseImage && !baseImageNeedsUpdate {
            progress("Base image already at version \(Self.imageVersion).")
            return
        }

        // 1. Alpine netboot files. Cached across runs.
        if !fm.fileExists(atPath: alpineKernelURL.path) ||
           !fm.fileExists(atPath: alpineInitrdURL.path) {
            progress("Downloading Alpine netboot installer…")
            try await downloadAlpineNetboot(progress: progress)
        } else {
            progress("Using cached Alpine netboot.")
        }

        // 2. Fresh raw target disk. Sparse — actual size on disk grows as the
        //    installer writes blocks.
        let scratchDisk = storageDir.appendingPathComponent("base.img.partial")
        try? fm.removeItem(at: scratchDisk)
        progress("Allocating \(Self.baseDiskBytes / (1024*1024*1024))GB sparse disk…")
        try createSparseDisk(at: scratchDisk, sizeBytes: Self.baseDiskBytes)

        // 3. Drive Alpine through the install.
        progress("Booting Alpine installer (this drives the Ubuntu install)…")
        try await runInstaller(
            targetDisk: scratchDisk,
            progress: progress,
            output: output
        )

        // 4. Allocate a fresh EFI variable store. First boot of the installed
        //    Ubuntu populates it with the boot entry GRUB registers.
        try? fm.removeItem(at: efiVarsURL)
        _ = try VZEFIVariableStore(
            creatingVariableStoreAt: efiVarsURL,
            options: []
        )

        // 5. Promote.
        try? fm.removeItem(at: baseDiskURL)
        try fm.moveItem(at: scratchDisk, to: baseDiskURL)
        try Self.imageVersion.write(to: versionStampURL, atomically: true, encoding: .utf8)

        progress("Base image ready at \(baseDiskURL.path)")
    }

    // MARK: - Alpine netboot download

    private func downloadAlpineNetboot(progress: @escaping (String) -> Void) async throws {
        let tarballName = "alpine-netboot-\(Self.alpineRelease)-aarch64.tar.gz"
        let tarballURL = URL(string: "\(Self.releasesBase)/\(tarballName)")!
        let checksumURL = URL(string: "\(Self.releasesBase)/\(tarballName).sha256")!
        let tarballDest = storageDir.appendingPathComponent(tarballName)
        let checksumDest = storageDir.appendingPathComponent("\(tarballName).sha256")

        try await Self.downloadFile(from: checksumURL, to: checksumDest)
        let checksumLine = try String(contentsOf: checksumDest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHash = String(checksumLine.split(separator: " ").first ?? "")
        guard expectedHash.count == 64 else {
            throw UbuntuImageError.checksumInvalid("expected 64 hex chars, got \(expectedHash.count)")
        }

        try await Self.downloadFile(from: tarballURL, to: tarballDest)

        let actualHash = try Self.sha256(of: tarballDest)
        guard actualHash == expectedHash else {
            try? FileManager.default.removeItem(at: tarballDest)
            throw UbuntuImageError.checksumInvalid("\(tarballName): expected \(expectedHash), got \(actualHash)")
        }

        // Extract kernel + initramfs.
        let extractDir = storageDir.appendingPathComponent("alpine-netboot-extract")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try Self.runHost(
            tool: "/usr/bin/tar",
            args: ["xzf", tarballDest.path,
                   "-C", extractDir.path,
                   "boot/vmlinuz-virt", "boot/initramfs-virt"]
        )

        let extractedKernel = extractDir.appendingPathComponent("boot/vmlinuz-virt")
        let extractedInitrd = extractDir.appendingPathComponent("boot/initramfs-virt")

        // The Alpine vmlinuz is an EFI PE binary wrapping a gzip'd ARM64 Image.
        // VZLinuxBootLoader needs the raw Image, so we strip the EFI wrapper.
        try? FileManager.default.removeItem(at: alpineKernelURL)
        try Self.extractRawKernel(from: extractedKernel, to: alpineKernelURL)

        try? FileManager.default.removeItem(at: alpineInitrdURL)
        try FileManager.default.moveItem(at: extractedInitrd, to: alpineInitrdURL)

        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tarballDest)
        try? FileManager.default.removeItem(at: checksumDest)

        progress("Alpine netboot extracted.")
    }

    // MARK: - Installer VM

    /// Boot Alpine on the target disk and drive setup.sh over the serial
    /// console. Resolves on SANDBOX_SETUP_DONE; throws on failure marker,
    /// guest crash, or hard timeout.
    @MainActor
    private func runInstaller(
        targetDisk: URL,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void
    ) async throws {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = Self.installerCPUs
        config.memorySize = Self.installerMemoryBytes

        let bootLoader = VZLinuxBootLoader(kernelURL: alpineKernelURL)
        bootLoader.initialRamdiskURL = alpineInitrdURL
        bootLoader.commandLine = [
            "console=hvc0",
            "ip=dhcp",
            "alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v\(Self.alpineVersion)/main",
            "modloop=\(Self.releasesBase)/netboot-\(Self.alpineRelease)/modloop-virt",
            "modules=loop,squashfs,virtio-net,virtio-blk,virtiofs",
        ].joined(separator: " ")
        config.bootLoader = bootLoader
        config.platform = VZGenericPlatformConfiguration()

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: targetDisk, readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        // VirtioFS share: setup.sh + any sibling files in vm-setup/.
        let setupFS = VZVirtioFileSystemDeviceConfiguration(tag: "setup")
        setupFS.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: setupDir, readOnly: true)
        )

        // Share the host's macOS system + user fonts read-only so the
        // installer can `cp -a` them into /usr/share/fonts/macos/. After
        // install, the fonts live on base.img — no runtime mount needed.
        let systemFontsURL = URL(fileURLWithPath: "/System/Library/Fonts")
        let macFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "macos-fonts")
        macFontsFS.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: systemFontsURL, readOnly: true)
        )

        var shares: [VZDirectorySharingDeviceConfiguration] = [setupFS, macFontsFS]
        let userFontsURL = URL(fileURLWithPath: "/Library/Fonts")
        if FileManager.default.fileExists(atPath: userFontsURL.path) {
            let userFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "macos-user-fonts")
            userFontsFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: userFontsURL, readOnly: true)
            )
            shares.append(userFontsFS)
        }
        config.directorySharingDevices = shares

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Serial: guest-side stdin (what we type into the VM) reads from
        // the read end of stdinPipe; guest stdout writes to stdoutPipe and
        // we tail it on the host.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: stdinPipe.fileHandleForReading,
            fileHandleForWriting: stdoutPipe.fileHandleForWriting
        )
        config.serialPorts = [serial]

        try config.validate()

        let vm = VZVirtualMachine(configuration: config)

        let buffer = ConsoleBuffer()
        // Tee guest serial output to stderr (for `bromure-ac init`),
        // the in-memory buffer (for marker waits), and the caller's
        // `output` callback (for the GUI's console-log view). All three
        // see the same byte stream.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            FileHandle.standardError.write(chunk)
            buffer.append(chunk)
            if let s = String(data: chunk, encoding: .utf8) {
                output(s)
            }
        }
        defer { stdoutPipe.fileHandleForReading.readabilityHandler = nil }

        let writer = stdinPipe.fileHandleForWriting
        let send: (String) -> Void = { writer.write(Data($0.utf8)) }

        // Race the driver against a hard timeout. We don't include a
        // stop-watcher task because the driver itself is responsible for
        // halting the VM cleanly at the end — having a watcher that throws
        // on guestDidStop would race the normal poweroff and mark a
        // successful install as a crash.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 45 * 60 * 1_000_000_000)
                throw UbuntuImageError.installerTimeout
            }
            group.addTask { @MainActor in
                try await vm.start()

                progress("Waiting for Alpine login prompt…")
                try await buffer.wait(
                    for: "localhost login:",
                    timeout: 180,
                    failures: ["Kernel panic"]
                )

                progress("Logging in as root…")
                send("root\n")
                try await buffer.wait(for: "localhost:~#", timeout: 30, failures: [])

                progress("Mounting host setup share…")
                send("modprobe virtiofs\n")
                try await buffer.wait(for: "localhost:~#", timeout: 30, failures: [])
                send("mkdir -p /tmp/setup && mount -t virtiofs setup /tmp/setup\n")
                try await buffer.wait(for: "localhost:~#", timeout: 60, failures: [])

                progress("Running setup.sh (apt + npm)…")
                let scale = Self.detectDisplayScale()
                send("sh /tmp/setup/setup.sh \(scale)\n")
                try await buffer.wait(
                    for: "SANDBOX_SETUP_DONE",
                    timeout: 30 * 60,
                    failures: ["SANDBOX_SETUP_FAILED:"]
                )

                progress("Powering off installer (Alpine OpenRC stop is 5-15s)…")
                send("poweroff\n")

                // Poll for clean stop, force-stop after 30s grace period.
                let deadline = Date().addingTimeInterval(30)
                while vm.state != .stopped && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if vm.state != .stopped {
                    progress("Force-stopping installer (Alpine took >30s to halt)…")
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        vm.stop(completionHandler: { _ in cont.resume() })
                    }
                }
                progress("Installer stopped cleanly.")
            }

            // Wait for the driver to finish; cancel the timeout.
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Disk + binary helpers

    private func createSparseDisk(at url: URL, sizeBytes: UInt64) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw UbuntuImageError.hostCommandFailed("open", Int32(errno))
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw UbuntuImageError.hostCommandFailed("ftruncate", Int32(errno))
        }
    }

    /// Strip the EFI PE wrapper off Alpine's vmlinuz-virt to get the raw
    /// arm64 Image that VZLinuxBootLoader needs. The PE wraps a gzip stream.
    private static func extractRawKernel(from efi: URL, to dest: URL) throws {
        let data = try Data(contentsOf: efi)
        let magic: [UInt8] = [0x1F, 0x8B, 0x08]

        var offset: Int?
        for i in 0..<(data.count - 3) where
            data[i] == magic[0] && data[i+1] == magic[1] && data[i+2] == magic[2] {
            offset = i
            break
        }
        guard let off = offset else {
            throw UbuntuImageError.kernelExtractionFailed("no gzip stream found")
        }

        let scratch = dest.deletingLastPathComponent().appendingPathComponent("kernel-raw.gz")
        try data[off...].write(to: scratch)

        // gunzip exits non-zero with "trailing garbage ignored" because the
        // gzip stream is followed by the rest of the PE binary. The decoded
        // output is still correct — we check for the output file rather than
        // the exit status.
        let gunzip = Process()
        gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
        gunzip.arguments = ["-f", scratch.path]
        try gunzip.run()
        gunzip.waitUntilExit()

        let raw = scratch.deletingPathExtension()
        guard FileManager.default.fileExists(atPath: raw.path) else {
            throw UbuntuImageError.kernelExtractionFailed("gunzip produced no output")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: raw, to: dest)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func downloadFile(from src: URL, to dst: URL) async throws {
        let session = URLSession(configuration: .default)
        let (tmp, response) = try await session.download(from: src)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UbuntuImageError.downloadFailed(http.statusCode)
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private static func runHost(tool: String, args: [String]) throws {
        let p = Process()
        p.launchPath = tool
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UbuntuImageError.hostCommandFailed(tool, p.terminationStatus)
        }
    }

    /// 1 on a regular display, 2 on Retina. Matches the browser's pattern
    /// — passed into setup.sh so kitty's font size scales with the host.
    @MainActor
    private static func detectDisplayScale() -> Int {
        if let screen = NSScreen.main {
            return Int(screen.backingScaleFactor)
        }
        return 2  // Apple Silicon Macs all ship Retina
    }
}

// MARK: - Console buffer

/// Append-only buffer of guest serial output that supports
/// "wait for marker / fail on alternate marker" coordination.
private final class ConsoleBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    private func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Poll the buffer until `marker` appears, throwing if any of `failures`
    /// appears first or the timeout elapses.
    func wait(
        for marker: String,
        timeout: TimeInterval,
        failures: [String]
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = text()
            if snapshot.contains(marker) {
                return
            }
            for fail in failures where snapshot.contains(fail) {
                throw UbuntuImageError.installerReportedFailure(
                    "guest reported \(fail) before \(marker)"
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw UbuntuImageError.installerTimeout
    }
}

// MARK: - Errors

public enum UbuntuImageError: LocalizedError {
    case downloadFailed(Int)
    case checksumInvalid(String)
    case kernelExtractionFailed(String)
    case hostCommandFailed(String, Int32)
    case installerReportedFailure(String)
    case installerStoppedEarly
    case installerTimeout

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let code):
            return "Download failed (HTTP \(code))."
        case .checksumInvalid(let why):
            return "Checksum invalid: \(why)"
        case .kernelExtractionFailed(let why):
            return "Could not extract Alpine kernel: \(why)"
        case .hostCommandFailed(let tool, let code):
            return "\(tool) exited with status \(code)."
        case .installerReportedFailure(let msg):
            return "Installer reported failure: \(msg)"
        case .installerStoppedEarly:
            return "Installer VM stopped before reporting completion."
        case .installerTimeout:
            return "Installer timed out."
        }
    }
}
