import CommonCrypto
import Foundation
import Virtualization

/// Manages creation of a minimal Linux disk image with Chromium for instant-on browsing.
///
/// Uses Alpine Linux ARM64 with:
/// - Minimal base system
/// - Chromium browser in kiosk mode
/// - Auto-login, auto-start X + Chromium fullscreen
/// - virtio drivers for GPU, network, and disk
public final class LinuxImageManager {
    /// Bump this to force a rebuild of the base image on next launch.
    public static let imageVersion = "11"

    private let storageDir: URL

    public init(storageDir: URL? = nil) {
        self.storageDir = storageDir ?? VMConfig.defaultStorageDirectory
    }

    // MARK: - Public

    /// Whether image files exist on disk (regardless of version).
    public var hasImageFiles: Bool {
        FileManager.default.fileExists(atPath: linuxDiskURL.path)
    }

    /// Whether a valid Linux base image exists and matches the current image version.
    public var baseImageExists: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: linuxDiskURL.path),
              fm.fileExists(atPath: linuxKernelURL.path),
              fm.fileExists(atPath: linuxInitrdURL.path) else {
            return false
        }
        // Check version stamp
        guard let stored = try? String(contentsOf: imageVersionURL, encoding: .utf8) else {
            return false
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == Self.imageVersion
    }

    /// Create a Linux base image: download Alpine netboot, install to disk, add Chromium.
    public func createBaseImage(
        diskSizeGB: UInt64 = 4,
        keyboardLayout: String? = nil,
        naturalScrolling: Bool? = nil,
        locale: String? = nil,
        displayScale: Int? = nil,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // 1. Download Alpine netboot kernel and initramfs
        let netbootKernel = storageDir.appendingPathComponent("netboot-vmlinuz")
        let netbootInitrd = storageDir.appendingPathComponent("netboot-initramfs")

        if !fm.fileExists(atPath: netbootKernel.path) ||
           !fm.fileExists(atPath: netbootInitrd.path) {
            progress(.stepStart("Downloading Alpine Linux netboot files"))
            try await downloadNetbootFiles(
                kernelDest: netbootKernel,
                initrdDest: netbootInitrd,
                progress: progress
            )
            progress(.stepDone("Downloading Alpine Linux netboot files"))
        } else {
            progress(.stepDone("Using cached Alpine netboot files"))
        }

        // 2. Create raw disk image
        progress(.stepStart("Creating \(diskSizeGB)GB disk image"))
        try createRawDisk(at: linuxDiskURL, sizeGB: diskSizeGB)
        progress(.stepDone("Creating \(diskSizeGB)GB disk image"))

        // 3. Boot Alpine netboot, install to disk, add Chromium.
        progress(.stepStart("Installing Alpine Linux with Chromium"))
        try await installLinux(
            netbootKernel: netbootKernel,
            netbootInitrd: netbootInitrd,
            targetDisk: linuxDiskURL,
            keyboardLayout: keyboardLayout,
            naturalScrolling: naturalScrolling,
            locale: locale,
            displayScale: displayScale,
            progress: progress
        )
        progress(.stepDone("Installing Alpine Linux with Chromium"))

        // 4. Read kernel + initramfs from the transfer disk (written by install VM).
        //    The installed kernel and mkinitfs initramfs must match versions.
        progress(.stepStart("Preparing boot files"))
        let transferDisk = storageDir.appendingPathComponent("transfer.img")
        let efiKernel = storageDir.appendingPathComponent("installed-vmlinuz-efi")
        try Self.readBootFilesFromTransfer(
            transferDisk: transferDisk,
            kernelDest: efiKernel,
            initrdDest: linuxInitrdURL
        )
        try? fm.removeItem(at: transferDisk)

        // Extract raw ARM64 Image from the installed EFI stub kernel
        try? fm.removeItem(at: linuxKernelURL)
        try extractRawKernel(from: efiKernel, to: linuxKernelURL)
        try? fm.removeItem(at: efiKernel)
        progress(.stepDone("Preparing boot files"))

        // 6. Clean up
        try? fm.removeItem(at: netbootKernel)
        try? fm.removeItem(at: netbootInitrd)

        // 7. Write version stamp
        try Self.imageVersion.write(to: imageVersionURL, atomically: true, encoding: .utf8)

        progress(.message("Linux image created at \(linuxDiskURL.path)"))
    }

    // MARK: - URLs

    public var linuxDiskURL: URL {
        storageDir.appendingPathComponent("linux-base.img")
    }

    public var linuxKernelURL: URL {
        storageDir.appendingPathComponent("vmlinuz")
    }

    public var linuxInitrdURL: URL {
        storageDir.appendingPathComponent("initrd")
    }

    public var imageVersionURL: URL {
        storageDir.appendingPathComponent("image-version")
    }

    // MARK: - VM Configuration

    /// Build a VZVirtualMachineConfiguration for a Linux VM.
    public func buildLinuxVMConfig(
        diskURL: URL,
        config: VMConfig,
        readOnlyDisk: Bool = false
    ) throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // Linux boot loader — direct kernel boot
        // console=tty1 shows boot on the graphical display;
        // console=hvc0 also outputs to serial for logging.
        let bootLoader = VZLinuxBootLoader(kernelURL: linuxKernelURL)
        bootLoader.initialRamdiskURL = linuxInitrdURL
        // Alpine init reads modules= to know what to modprobe at boot.
        // We need virtio_blk (for /dev/vda) and ext4 (for root filesystem).
        // dm-crypt is needed for LUKS-encrypted profile disks.
        bootLoader.commandLine = "console=tty1 console=hvc0 root=/dev/vda rootfstype=ext4 modules=virtio_blk,virtiofs,loop,dm-crypt rw"
        vzConfig.bootLoader = bootLoader

        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySize

        // Platform
        vzConfig.platform = VZGenericPlatformConfiguration()

        // Storage — root disk (vda)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: readOnlyDisk
        )
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        ]

        // Virtio-fs device for sharing profile disk images with the guest.
        // The share is initially empty; it's pointed to the profile's image
        // directory at claim time via VZVirtioFileSystemDevice.share.
        let shareDevice = VZVirtioFileSystemDeviceConfiguration(tag: "share")
        vzConfig.directorySharingDevices = [shareDevice]

        // Network — NAT mode (bridged networking requires com.apple.vm.networking
        // entitlement which needs an Apple Developer provisioning profile)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        vzConfig.networkDevices = [net]

        // Graphics — virtio GPU
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        // Audio
        if config.enableAudio {
            let audio = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            audio.streams = [outputStream]
            vzConfig.audioDevices = [audio]
        }

        // Input
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Entropy
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon — allows host to reclaim unused guest memory
        vzConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Vsock device — always enabled (used by credential bridge and file transfer)
        vzConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]


        // SPICE agent for clipboard sharing
        if config.enableClipboardSharing {
            let spiceConsole = VZVirtioConsoleDeviceConfiguration()
            let spicePort = VZVirtioConsolePortConfiguration()
            spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            let spiceAttachment = VZSpiceAgentPortAttachment()
            spiceAttachment.sharesClipboard = true
            spicePort.attachment = spiceAttachment
            spiceConsole.ports[0] = spicePort
            vzConfig.consoleDevices.append(spiceConsole)
        }

        return vzConfig
    }

    // MARK: - Private

    private static let alpineVersion = "3.23"
    private static let alpineRelease = "3.23.3"
    private static let releasesBase =
        "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/aarch64"
    private static let netbootBase = "\(releasesBase)/netboot-\(alpineRelease)"

    private func downloadNetbootFiles(
        kernelDest: URL,
        initrdDest: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let tarballName = "alpine-netboot-\(Self.alpineRelease)-aarch64.tar.gz"
        let tarballURL = URL(string: "\(Self.releasesBase)/\(tarballName)")!
        let checksumURL = URL(string: "\(Self.releasesBase)/\(tarballName).sha256")!
        let tarballDest = storageDir.appendingPathComponent(tarballName)
        let checksumDest = storageDir.appendingPathComponent("\(tarballName).sha256")

        // Download checksum file
        progress(.message("Downloading checksum..."))
        try await downloadFile(from: checksumURL, to: checksumDest, progress: progress)
        let checksumLine = try String(contentsOf: checksumDest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHash = String(checksumLine.split(separator: " ").first ?? "")
        guard expectedHash.count == 64 else {
            throw SandboxError.diskCreationFailed("Invalid SHA-256 checksum file")
        }

        // Download tarball
        progress(.message("Downloading Alpine netboot tarball..."))
        try await downloadFile(from: tarballURL, to: tarballDest, progress: progress)

        // Verify SHA-256 checksum
        progress(.message("Verifying checksum..."))
        let actualHash = try sha256(of: tarballDest)
        guard actualHash == expectedHash else {
            try? FileManager.default.removeItem(at: tarballDest)
            throw SandboxError.diskCreationFailed(
                "Checksum mismatch for \(tarballName): expected \(expectedHash), got \(actualHash)"
            )
        }

        // Extract vmlinuz-virt and initramfs-virt from tarball
        progress(.message("Extracting netboot files..."))
        let extractDir = storageDir.appendingPathComponent("netboot-extract")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = [
            "xzf", tarballDest.path,
            "-C", extractDir.path,
            "boot/vmlinuz-virt", "boot/initramfs-virt"
        ]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw SandboxError.diskCreationFailed("Failed to extract netboot tarball")
        }

        // Move extracted files to destinations
        let extractedKernel = extractDir.appendingPathComponent("boot/vmlinuz-virt")
        let extractedInitrd = extractDir.appendingPathComponent("boot/initramfs-virt")

        // Extract raw ARM64 Image from EFI stub kernel
        progress(.message("Extracting raw kernel..."))
        try extractRawKernel(from: extractedKernel, to: kernelDest)

        try? FileManager.default.removeItem(at: initrdDest)
        try FileManager.default.moveItem(at: extractedInitrd, to: initrdDest)

        // Clean up
        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tarballDest)
        try? FileManager.default.removeItem(at: checksumDest)
    }

    /// Compute SHA-256 hash of a file.
    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Extract the raw ARM64 Image from an EFI stub vmlinuz.
    ///
    /// Alpine's vmlinuz-virt is an EFI PE binary that wraps a gzip-compressed
    /// ARM64 Image. VZLinuxBootLoader cannot boot EFI stubs directly — it
    /// needs the raw Image. We find the embedded gzip stream (magic bytes
    /// 1F 8B 08) and decompress it.
    private func extractRawKernel(from efiKernel: URL, to destination: URL) throws {
        let data = try Data(contentsOf: efiKernel)
        let gzipMagic: [UInt8] = [0x1F, 0x8B, 0x08]

        // Find gzip stream in the binary
        var gzipOffset: Int?
        for i in 0..<(data.count - 3) {
            if data[i] == gzipMagic[0] && data[i+1] == gzipMagic[1] && data[i+2] == gzipMagic[2] {
                gzipOffset = i
                break
            }
        }

        guard let offset = gzipOffset else {
            throw SandboxError.diskCreationFailed(
                "Could not find gzip stream in EFI stub kernel"
            )
        }

        // Write the gzip data to a temp file and decompress
        let gzipFile = destination.deletingLastPathComponent()
            .appendingPathComponent("kernel-raw.gz")
        try data[offset...].write(to: gzipFile)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gunzip")
        process.arguments = ["-f", gzipFile.path]
        try process.run()
        process.waitUntilExit()

        let rawFile = gzipFile.deletingPathExtension()
        guard FileManager.default.fileExists(atPath: rawFile.path) else {
            throw SandboxError.diskCreationFailed("Failed to decompress kernel")
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: rawFile, to: destination)
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                destination: destination,
                progress: progress,
                completion: { result in continuation.resume(with: result) }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    private func createRawDisk(at url: URL, sizeGB: UInt64) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw SandboxError.diskCreationFailed(
                "Failed to create disk: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(fd) }

        let size = Int64(sizeGB * 1024 * 1024 * 1024)
        guard ftruncate(fd, size) == 0 else {
            throw SandboxError.diskCreationFailed(
                "Failed to set disk size: \(String(cString: strerror(errno)))"
            )
        }
    }

    /// Boot Alpine netboot, install to disk, configure Chromium kiosk,
    /// and write the initramfs to a transfer disk (vdb).
    @MainActor
    private func installLinux(
        netbootKernel: URL,
        netbootInitrd: URL,
        targetDisk: URL,
        keyboardLayout: String? = nil,
        naturalScrolling: Bool? = nil,
        locale: String? = nil,
        displayScale: Int? = nil,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        // Create transfer disk for extracting initramfs
        let transferDisk = storageDir.appendingPathComponent("transfer.img")
        try? FileManager.default.removeItem(at: transferDisk)
        let tfd = open(transferDisk.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard tfd >= 0 else {
            throw SandboxError.diskCreationFailed("Failed to create transfer disk")
        }
        ftruncate(tfd, 128 * 1024 * 1024)
        close(tfd)

        let vzConfig = VZVirtualMachineConfiguration()

        let bootLoader = VZLinuxBootLoader(kernelURL: netbootKernel)
        bootLoader.initialRamdiskURL = netbootInitrd
        bootLoader.commandLine = "console=hvc0 ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v\(Self.alpineVersion)/main modloop=\(Self.netbootBase)/modloop-virt modules=loop,squashfs,virtio-net,virtio-blk"
        vzConfig.bootLoader = bootLoader

        vzConfig.platform = VZGenericPlatformConfiguration()
        vzConfig.cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        vzConfig.memorySize = 2 * 1024 * 1024 * 1024

        // Target disk (vda) + transfer disk (vdb)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: targetDisk, readOnly: false
        )
        let transferAttachment = try VZDiskImageStorageDeviceAttachment(
            url: transferDisk, readOnly: false
        )
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
            VZVirtioBlockDeviceConfiguration(attachment: transferAttachment),
        ]

        // Network (needed for apk)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        vzConfig.networkDevices = [net]

        // Serial console via pipe
        let consolePipe = Pipe()
        let inputPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: consolePipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serial]

        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        try vzConfig.validate()

        let vm = VZVirtualMachine(configuration: vzConfig)

        let runLoopPump = DispatchSource.makeTimerSource(queue: .main)
        runLoopPump.schedule(deadline: .now(), repeating: .milliseconds(100))
        runLoopPump.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
        }
        runLoopPump.resume()
        defer { runLoopPump.cancel() }

        try await vm.start()

        let consoleOutput = ConsoleBuffer()
        consolePipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                consoleOutput.append(text)
                progress(.consoleOutput(text))
                if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                    FileHandle.standardError.write(data)
                }
            }
        }
        defer {
            consolePipe.fileHandleForReading.readabilityHandler = nil
        }

        let writer = inputPipe.fileHandleForWriting

        progress(.message("Waiting for Alpine to boot..."))
        try await consoleOutput.waitFor(
            marker: "localhost login:",
            timeout: 120,
            progress: progress
        )

        progress(.message("Logging in..."))
        writer.write(Data("root\n".utf8))
        try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)

        progress(.message("Transferring setup files..."))

        // Create a tar.gz archive of the bundled vm-setup resources and
        // transfer it to the installer VM via base64 over serial.
        let archive = try Self.createSetupArchive()
        let base64 = archive.base64EncodedString()
        let chunkSize = 800
        writer.write(Data("mkdir -p /tmp/vm-setup\n".utf8))
        try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = base64[offset..<end]
            writer.write(Data("echo '\(chunk)' >> /tmp/s.b64\n".utf8))
            try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)
            offset = end
        }
        writer.write(Data("base64 -d /tmp/s.b64 | tar xz -C /tmp\n".utf8))
        try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)
        writer.write(Data("rm -f /tmp/s.b64\n".utf8))
        try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)

        progress(.message("Running setup script (installing packages, this may take a few minutes)..."))

        // Run the setup script as a single command. It will print
        // SANDBOX_SETUP_DONE on success or SANDBOX_SETUP_FAILED on error.
        let hostConfig = VMConfig()
        let kbLayout = Self.shellEscape(keyboardLayout ?? hostConfig.keyboardLayout)
        let natScroll = (naturalScrolling ?? hostConfig.naturalScrolling) ? "true" : "false"
        let loc = Self.shellEscape(locale ?? hostConfig.locale)
        let scale = displayScale ?? VMConfig.detectDisplayScale()
        writer.write(Data("sh /tmp/vm-setup/setup.sh \(kbLayout) \(natScroll) \(loc) \(scale) \(Self.alpineVersion)\n".utf8))

        do {
            try await consoleOutput.waitFor(marker: "SANDBOX_SETUP_DONE", timeout: 900, progress: progress)
        } catch {
            let snapshot = consoleOutput.pollAndTrim(marker: "SANDBOX_SETUP_FAILED")
            if snapshot.found {
                throw SandboxError.diskCreationFailed(
                    "The image could not be created. Package installation failed, likely due to network issues. Please check your internet connection and try again."
                )
            }
            throw error
        }

        // Extract initramfs to the transfer disk (vdb).
        // We're still in the netboot environment, so ext4 is available via the
        // already-mounted target disk. We need to copy the mkinitfs-generated
        // initramfs to vdb so we can read it on macOS.
        progress(.message("Extracting initramfs to transfer disk..."))
        let extractLines = [
            "modprobe ext4 2>/dev/null",
            "mount -t ext4 /dev/vda /mnt",
            // Ensure mkinitfs config includes virtio_blk for boot
            "printf '%s\\n' 'features=\"base ext4 virtio\"' > /mnt/etc/mkinitfs/mkinitfs.conf",
            // Rebuild initramfs with correct modules
            "chroot /mnt sh -c 'KVER=$(ls /lib/modules/ | head -1) && mkinitfs -o /boot/initramfs-custom $KVER'",
            // Find the installed kernel (vmlinuz-virt is the EFI stub,
            // but we need the raw Image for VZLinuxBootLoader)
            "KERNEL=/mnt/boot/vmlinuz-virt",
            "INITRD=/mnt/boot/initramfs-custom",
            "KSIZE=$(stat -c%s $KERNEL)",
            "ISIZE=$(stat -c%s $INITRD)",
            "echo \"KERNEL_SIZE=$KSIZE INITRD_SIZE=$ISIZE\"",
            // Write header: 16 bytes kernel size + 16 bytes initrd size at offset 0
            // Kernel data at offset 4096
            // Initrd data at offset 4096 + kernel size (rounded up to 4096)
            "printf '%016d%016d' $KSIZE $ISIZE | dd of=/dev/vdb bs=1 count=32 2>/dev/null",
            "dd if=$KERNEL of=/dev/vdb bs=4096 seek=1 2>/dev/null",
            // Calculate initrd offset: 4096 + ceil(KSIZE/4096)*4096
            "KBLOCKS=$(( (KSIZE + 4095) / 4096 + 1 ))",
            "dd if=$INITRD of=/dev/vdb bs=4096 seek=$KBLOCKS 2>/dev/null",
            "sync",
            "umount /mnt",
            "echo EXTRACT_DONE",
        ]
        for line in extractLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            writer.write(Data((line + "\n").utf8))
            if trimmed.contains("EXTRACT_DONE") { break }
            try await consoleOutput.waitFor(
                marker: "localhost:~#",
                timeout: 120,
                progress: progress
            )
        }
        try await consoleOutput.waitFor(marker: "EXTRACT_DONE", timeout: 60, progress: progress)

        progress(.message("Shutting down installer VM..."))
        writer.write(Data("poweroff\n".utf8))
        try await Task.sleep(for: .seconds(3))

        let deadline = Date().addingTimeInterval(30)
        while vm.state != .stopped && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        if vm.state != .stopped {
            try? await vm.stop()
        }
    }

    /// Read kernel + initramfs from the transfer disk.
    /// Format: 32-byte header (16 bytes kernel size + 16 bytes initrd size),
    /// kernel at offset 4096, initrd at offset 4096 + ceil(kernelSize/4096)*4096.
    private static func readBootFilesFromTransfer(
        transferDisk: URL,
        kernelDest: URL,
        initrdDest: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: transferDisk)
        defer { handle.closeFile() }

        guard let headerData = try? handle.read(upToCount: 32),
              headerData.count == 32,
              let headerStr = String(data: headerData, encoding: .utf8) else {
            throw SandboxError.diskCreationFailed(
                "Transfer disk has no valid header — boot file extraction failed in VM"
            )
        }

        let kSizeStr = String(headerStr.prefix(16)).trimmingCharacters(in: .whitespacesAndNewlines)
        let iSizeStr = String(headerStr.suffix(16)).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let kSize = Int(kSizeStr), kSize > 0,
              let iSize = Int(iSizeStr), iSize > 0 else {
            throw SandboxError.diskCreationFailed(
                "Invalid sizes in transfer header: kernel='\(kSizeStr)' initrd='\(iSizeStr)'"
            )
        }

        // Read kernel at offset 4096
        handle.seek(toFileOffset: 4096)
        guard let kernelData = try? handle.read(upToCount: kSize),
              kernelData.count == kSize else {
            throw SandboxError.diskCreationFailed("Failed to read kernel from transfer disk")
        }
        try? FileManager.default.removeItem(at: kernelDest)
        try kernelData.write(to: kernelDest)

        // Read initrd at offset 4096 + ceil(kSize/4096)*4096
        let kBlocks = (kSize + 4095) / 4096 + 1
        let initrdOffset = UInt64(kBlocks * 4096)
        handle.seek(toFileOffset: initrdOffset)
        guard let initrdData = try? handle.read(upToCount: iSize),
              initrdData.count == iSize else {
            throw SandboxError.diskCreationFailed("Failed to read initramfs from transfer disk")
        }
        try? FileManager.default.removeItem(at: initrdDest)
        try initrdData.write(to: initrdDest)
    }

    /// Create a tar.gz archive of the bundled vm-setup resources.
    private static func createSetupArchive() throws -> Data {
        guard let setupDir = Self.resourceBundle.url(forResource: "vm-setup", withExtension: nil) else {
            throw SandboxError.diskCreationFailed("vm-setup resources not found in bundle")
        }
        let tempTar = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-setup-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: tempTar) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-czf", tempTar.path,
            "-C", setupDir.deletingLastPathComponent().path,
            setupDir.lastPathComponent,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SandboxError.diskCreationFailed("Failed to create setup archive (tar exit \(process.terminationStatus))")
        }
        return try Data(contentsOf: tempTar)
    }

    /// Escape a string for safe use in a shell command.
    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// SPM resource bundle, checking Contents/Resources/ for app bundles.
    private static let resourceBundle: Bundle = {
        let bundleName = "bromure_SandboxEngine"
        // SPM's auto-generated accessor checks Bundle.main.bundleURL (the .app root),
        // but codesign requires resources in Contents/Resources/.
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }
        // Fallback to SPM's default (works during development)
        return Bundle.module
    }()
}

// MARK: - Console Buffer

/// Thread-safe buffer for reading VM console output asynchronously.
private final class ConsoleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var captureStart = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    struct PollResult {
        let found: Bool
        let length: Int
        let recentOutput: String
    }

    func pollAndTrim(marker: String) -> PollResult {
        withLock {
            let found = buffer.contains(marker)
            let length = buffer.count
            let recent = String(buffer.suffix(1024))
            if buffer.count > 64_000 {
                buffer = String(buffer.suffix(32_000))
            }
            return PollResult(found: found, length: length, recentOutput: recent)
        }
    }

    func append(_ text: String) {
        withLock { buffer += text }
    }

    func startCapture() {
        withLock { captureStart = buffer.count }
    }

    func extractBetween(start: String, end: String) -> String {
        let captured = withLock {
            String(buffer.suffix(from: buffer.index(buffer.startIndex, offsetBy: min(captureStart, buffer.count))))
        }

        guard let startRange = captured.range(of: start),
              let endRange = captured.range(of: end) else {
            return ""
        }
        return String(captured[startRange.upperBound..<endRange.lowerBound])
    }

    func waitFor(
        marker: String,
        timeout: TimeInterval,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        var deadline = Date().addingTimeInterval(timeout)
        var lastBufferLength = 0
        var recentOutput = ""
        while Date() < deadline {
            let snapshot = pollAndTrim(marker: marker)
            recentOutput = snapshot.recentOutput

            if snapshot.found { return }
            // Reset deadline whenever new console output appears
            if snapshot.length != lastBufferLength {
                lastBufferLength = snapshot.length
                deadline = Date().addingTimeInterval(timeout)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Check if the last console output suggests a network issue
        let networkHints = ["fetch ", "Connecting to ", "APKINDEX", "downloading", "wget", "transfer"]
        let looksLikeNetwork = networkHints.contains { recentOutput.localizedCaseInsensitiveContains($0) }
        let detail = looksLikeNetwork
            ? "The VM appears to be waiting on a network operation. Check your internet connection and try again."
            : "No console output received for \(Int(timeout))s."
        throw SandboxError.vmStartFailed(
            "Timed out waiting for '\(marker)' — \(detail)"
        )
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: (ProgressEvent) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var completed = false

    init(
        destination: URL,
        progress: @escaping (ProgressEvent) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(.download(
            bytesReceived: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
                ? 0 : totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(session, result: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            finish(session, result: .failure(error))
        } else if let http = task.response as? HTTPURLResponse,
                  !(200...299).contains(http.statusCode) {
            finish(session, result: .failure(
                SandboxError.downloadFailed("HTTP \(http.statusCode)")
            ))
        } else {
            finish(session, result: .success(()))
        }
    }

    private func finish(_ session: URLSession, result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
