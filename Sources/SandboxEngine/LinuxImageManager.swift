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
    private let storageDir: URL

    public init(storageDir: URL? = nil) {
        self.storageDir = storageDir ?? VMConfig.defaultStorageDirectory
    }

    // MARK: - Public

    /// Whether a valid Linux base image already exists.
    public var baseImageExists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: linuxDiskURL.path)
            && fm.fileExists(atPath: linuxKernelURL.path)
            && fm.fileExists(atPath: linuxInitrdURL.path)
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
        bootLoader.commandLine = "console=tty1 console=hvc0 root=/dev/vda rootfstype=ext4 modules=virtio_blk rw"
        vzConfig.bootLoader = bootLoader

        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySize

        // Platform
        vzConfig.platform = VZGenericPlatformConfiguration()

        // Storage
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: readOnlyDisk
        )
        vzConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Network
        if config.enableNetworking {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            vzConfig.networkDevices = [net]
        }

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

        return vzConfig
    }

    // MARK: - Private

    private static let alpineVersion = "3.21"
    private static let alpineRelease = "3.21.3"
    private static let netbootBase =
        "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/aarch64/netboot"

    private func downloadNetbootFiles(
        kernelDest: URL,
        initrdDest: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let kernelURL = URL(string: "\(Self.netbootBase)/vmlinuz-virt")!
        let initrdURL = URL(string: "\(Self.netbootBase)/initramfs-virt")!

        // Download kernel (EFI stub format)
        progress(.message("Downloading kernel..."))
        let efiKernelDest = kernelDest.deletingLastPathComponent()
            .appendingPathComponent("netboot-vmlinuz-efi")
        try await downloadFile(from: kernelURL, to: efiKernelDest, progress: progress)

        // Extract raw ARM64 Image from EFI stub.
        // VZLinuxBootLoader requires a raw ARM64 Image, not the EFI PE wrapper.
        // The gzip-compressed Image is embedded after the EFI headers.
        progress(.message("Extracting raw kernel..."))
        try extractRawKernel(from: efiKernelDest, to: kernelDest)
        try? FileManager.default.removeItem(at: efiKernelDest)

        // Download initramfs
        progress(.message("Downloading initramfs..."))
        try await downloadFile(from: initrdURL, to: initrdDest, progress: progress)
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
        bootLoader.commandLine = "console=hvc0 ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v\(Self.alpineVersion)/main modloop=https://dl-cdn.alpinelinux.org/alpine/v\(Self.alpineVersion)/releases/aarch64/netboot/modloop-virt modules=loop,squashfs,virtio-net,virtio-blk"
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

        progress(.message("Running setup script (installing packages, this may take a few minutes)..."))

        // Send each command and wait for the shell prompt before sending the next.
        // This prevents commands from interleaving when apk downloads take time.
        let hostConfig = VMConfig()
        let scriptLines = Self.setupScript(
            keyboardLayout: keyboardLayout ?? hostConfig.keyboardLayout,
            naturalScrolling: naturalScrolling ?? hostConfig.naturalScrolling,
            locale: locale ?? hostConfig.locale,
            displayScale: displayScale ?? VMConfig.detectDisplayScale()
        ).components(separatedBy: "\n")
        for line in scriptLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            writer.write(Data((line + "\n").utf8))
            // Wait for either the shell prompt or our completion marker
            if trimmed.contains("SANDBOX_SETUP_DONE") {
                break
            }
            try await consoleOutput.waitFor(
                marker: "localhost:~#",
                timeout: 900,
                progress: progress
            )
        }

        try await consoleOutput.waitFor(marker: "SANDBOX_SETUP_DONE", timeout: 60, progress: progress)

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

    /// Shell script lines to install Alpine + Chromium to /dev/vda.
    ///
    /// Each line is sent individually over the serial console, so we avoid
    /// heredocs (which break when lines have leading whitespace). Instead
    /// we use `printf` + `>>`/`>` for file creation.
    private static func setupScript(
        keyboardLayout: String,
        naturalScrolling: Bool,
        locale: String,
        displayScale: Int
    ) -> String {
        // Lines are joined with \n; each is sent to the serial console individually.
        // No heredocs — they don't work reliably over serial with line-by-line sending.
        return [
            "# Load ext4 module and format target disk",
            "modprobe ext4",
            "apk add e2fsprogs",
            "mkfs.ext4 -q -F /dev/vda",
            "mkdir -p /mnt",
            "mount -t ext4 /dev/vda /mnt",
            "",
            "# Install Alpine base",
            "apk add alpine-base --root /mnt --initdb --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories",
            "",
            "# Repos",
            "mkdir -p /mnt/etc/apk",
            "printf '%s\\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.21/main' 'https://dl-cdn.alpinelinux.org/alpine/v3.21/community' > /mnt/etc/apk/repositories",
            "",
            "# DNS",
            "cp /etc/resolv.conf /mnt/etc/resolv.conf",
            "",
            "# Bind-mount for chroot",
            "mount -t proc proc /mnt/proc",
            "mount -t sysfs sys /mnt/sys",
            "mount --bind /dev /mnt/dev",
            "",
            "# Chroot: update and install packages",
            "chroot /mnt apk update || echo 'APK_UPDATE_FAILED'",
            "chroot /mnt apk add openrc linux-virt linux-firmware-none mkinitfs || echo 'APK_ADD_BASE_FAILED'",
            "chroot /mnt apk add chromium xorg-server xinit mesa-dri-gallium mesa-egl mesa-gl mesa-gles mesa-gbm eudev dbus ttf-freefont ttf-dejavu font-noto-emoji font-liberation xf86-input-libinput agetty util-linux openbox xrandr xdotool setxkbmap pulseaudio pulseaudio-alsa alsa-utils alsa-plugins-pulse adwaita-icon-theme || echo 'APK_ADD_CHROMIUM_FAILED'",
            "ls -la /mnt/sbin/init || echo 'WARNING: /sbin/init not found!'",
            "",
            "# Install Cloudflare WARP (glibc binary on musl Alpine)",
            "chroot /mnt apk add gcompat libstdc++ ca-certificates nftables iproute2 glib nss nspr libgcc",
            "apk add binutils",
            #"WARP_DEB=$(wget -qO- 'https://pkg.cloudflareclient.com/dists/bookworm/main/binary-arm64/Packages' | grep '^Filename:' | tail -1 | cut -d' ' -f2)"#,
            #"wget -q "https://pkg.cloudflareclient.com/$WARP_DEB" -O /tmp/warp.deb || echo 'WARP_DOWNLOAD_FAILED'"#,
            "cd /tmp && ar x warp.deb 2>/dev/null",
            "tar xf /tmp/data.tar.* -C /mnt 2>/dev/null || echo 'WARP_EXTRACT_FAILED'",
            "rm -f /tmp/warp.deb /tmp/data.tar.* /tmp/control.tar.* /tmp/debian-binary",
            "mkdir -p /mnt/var/lib/cloudflare-warp /mnt/var/log/cloudflare-warp",
            "ls -la /mnt/bin/warp-cli 2>/dev/null && echo 'WARP_INSTALLED_OK' || echo 'WARP_INSTALL_FAILED'",
            "",
            "# Build glibc resolver stub for WARP (gcompat lacks __res_init)",
            "apk add gcc musl-dev",
            #"printf '#include <stddef.h>\nint __res_init(void) { return 0; }\nint res_init(void) { return 0; }\nint __res_nclose(void *s) { return 0; }\nint __res_ninit(void *s) { return 0; }\n' > /tmp/resolv_stub.c"#,
            "gcc -shared -o /mnt/usr/lib/libresolv_stub.so /tmp/resolv_stub.c",
            "rm -f /tmp/resolv_stub.c",
            "",
            "# Install Squid proxy, dnsmasq, and proxychains for ad blocking / WARP",
            "chroot /mnt apk add squid dnsmasq proxychains-ng",
            "",
            "# proxychains config for WARP SOCKS5 proxy",
            "printf '%s\\n' '[ProxyList]' 'socks5 \t127.0.0.1 40000' > /mnt/etc/proxychains/proxychains.conf",
            "",
            "# Pi-hole directory structure",
            "mkdir -p /mnt/etc/pihole /mnt/var/log/pihole /mnt/etc/dnsmasq.d",
            "",
            "# Download ad blocklist (Steven Black unified hosts)",
            "wget -qO /mnt/etc/pihole/gravity.list 'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts' || echo 'BLOCKLIST_DOWNLOAD_FAILED'",
            "touch /mnt/etc/pihole/local.list /mnt/etc/pihole/custom.list",
            "",
            "# Pi-hole setupVars.conf",
            "printf '%s\\n' 'PIHOLE_INTERFACE=eth0' 'IPV4_ADDRESS=0.0.0.0/0' 'QUERY_LOGGING=true' 'INSTALL_WEB_SERVER=true' 'INSTALL_WEB_INTERFACE=true' 'LIGHTTPD_ENABLED=true' 'CACHE_SIZE=10000' 'DNS_FQDN_REQUIRED=true' 'DNS_BOGUS_PRIV=true' 'DNSMASQ_LISTENING=all' 'WEBPASSWORD=32ff1e004f32399ace3c36d63612719c3abc0e96c27895709db3996601b98073' 'BLOCKING_ENABLED=true' 'PIHOLE_DNS_1=1.1.1.3' 'PIHOLE_DNS_2=1.0.0.3' 'DNSSEC=false' 'REV_SERVER=false' > /mnt/etc/pihole/setupVars.conf",
            "",
            "# dnsmasq config for Pi-hole",
            "printf '%s\\n' 'addn-hosts=/etc/pihole/gravity.list' 'addn-hosts=/etc/pihole/local.list' 'addn-hosts=/etc/pihole/custom.list' 'localise-queries' 'no-resolv' 'log-queries' 'log-facility=/var/log/pihole/pihole.log' 'log-async' 'cache-size=10000' 'server=1.1.1.1' 'server=1.0.0.1' 'domain-needed' 'expand-hosts' 'bogus-priv' 'except-interface=nonexisting' > /mnt/etc/dnsmasq.d/pihole.conf",
            "",
            "# Chromium enterprise policies",
            "mkdir -p /mnt/etc/chromium/policies/managed",
            "printf '%s\\n' '{' '  \"HighEfficiencyModeEnabled\": true,' '  \"MemorySaverModeSavings\": 1,' '  \"URLBlocklist\": [\"file://*\"]' '}' > /mnt/etc/chromium/policies/managed/bromure.json",
            "",
            "# Squid proxy config",
            "printf '%s\\n' 'dns_nameservers 127.0.0.1' 'forwarded_for off' 'http_port 127.0.0.1:3128' 'acl blocked_ip dst 0.0.0.0/32' 'acl all src 0.0.0.0/0' 'http_access deny blocked_ip' 'http_access allow all' 'cache_mem 32 MB' 'maximum_object_size_in_memory 512 KB' 'cache deny all' 'max_filedescriptors 4096' 'memory_pools off' 'memory_pools_limit none' > /mnt/etc/squid/squid.conf",
            "",
            "# Network stack tuning (prevent exhaustion under heavy browsing)",
            "printf '%s\\n' 'net.core.somaxconn=1024' 'net.core.netdev_max_backlog=2000' 'net.core.rmem_max=4194304' 'net.core.wmem_max=4194304' 'net.ipv4.tcp_rmem=4096 87380 4194304' 'net.ipv4.tcp_wmem=4096 65536 4194304' 'net.ipv4.tcp_max_syn_backlog=2048' 'net.ipv4.tcp_tw_reuse=1' 'net.ipv4.ip_local_port_range=1024 65535' 'net.ipv4.tcp_fin_timeout=15' 'net.ipv4.tcp_max_tw_buckets=16384' 'net.nf_conntrack_max=32768' > /mnt/etc/sysctl.d/99-bromure.conf",
            "",
            "# Locale (mirrored from macOS host)",
            "printf '%s\\n' 'export LANG=\(locale).UTF-8' 'export LC_ALL=\(locale).UTF-8' 'export LD_PRELOAD=/usr/lib/libresolv_stub.so' > /mnt/etc/profile.d/locale.sh",
            "",
            "# Empty root password and create chrome user",
            "chroot /mnt sh -c 'echo \"root:\" | chpasswd'",
            "chroot /mnt adduser -D -s /bin/sh chrome",
            "chroot /mnt addgroup chrome video",
            "chroot /mnt addgroup chrome render",
            "chroot /mnt addgroup chrome input",
            "chroot /mnt addgroup chrome audio",
            "chroot /mnt apk add doas",
            "printf '%s\\n' 'permit nopass chrome as root cmd poweroff' 'permit nopass chrome as root cmd warp-cli' > /mnt/etc/doas.d/chrome.conf",
            "",
            "# Enable services",
            "chroot /mnt rc-update add devfs sysinit",
            "chroot /mnt rc-update add dmesg sysinit",
            "chroot /mnt rc-update add udev sysinit",
            "chroot /mnt rc-update add networking boot",
            "chroot /mnt rc-update add modules boot",
            "chroot /mnt rc-update add dbus default",
            "",
            "# Networking config",
            "printf '%s\\n' 'auto lo' 'iface lo inet loopback' '' 'auto eth0' 'iface eth0 inet dhcp' > /mnt/etc/network/interfaces",
            "",
            "# Auto-login chrome user on tty1 + debug on serial",
            "sed -i 's|^tty1::.*|tty1::respawn:/bin/login -f chrome|' /mnt/etc/inittab",
            "echo 'hvc0::respawn:/bin/login -f root' >> /mnt/etc/inittab",
            "# Root auto-debug: dump info to serial after boot",
            "printf '%s\\n' '#!/bin/sh' 'sleep 15' 'echo === PCI DEVICES ===' 'cat /proc/bus/pci/devices 2>/dev/null || echo no-pci' 'ls -la /sys/bus/pci/devices/ 2>/dev/null' 'for d in /sys/bus/pci/devices/*; do echo \"$d: $(cat $d/vendor 2>/dev/null) $(cat $d/device 2>/dev/null) $(cat $d/class 2>/dev/null)\"; done' 'echo === USB MODULES AVAIL ===' 'find /lib/modules/*/kernel/drivers/usb -name \"*.ko*\" 2>/dev/null || echo none' 'find /lib/modules/*/kernel/drivers/hid -name \"*.ko*\" 2>/dev/null || echo none' 'echo === USB/INPUT ===' 'lsmod 2>/dev/null' 'ls -la /dev/input/ 2>/dev/null || echo no-input-devs' 'cat /proc/bus/input/devices 2>/dev/null || echo no-input-proc' 'dmesg | grep -iE \"usb|hid|input|keyboard|xhci|pci\" 2>/dev/null' 'echo === END DEBUG ===' > /mnt/root/debug.sh",
            "chmod +x /mnt/root/debug.sh",
            "printf '%s\\n' '/root/debug.sh &' > /mnt/root/.profile",
            "",
            "# Udev rule for DRI device permissions (GPU access for render group)",
            "mkdir -p /mnt/etc/udev/rules.d",
            "printf '%s\\n' 'SUBSYSTEM==\"drm\", KERNEL==\"renderD*\", GROUP=\"render\", MODE=\"0666\"' 'SUBSYSTEM==\"drm\", KERNEL==\"card*\", GROUP=\"video\", MODE=\"0666\"' > /mnt/etc/udev/rules.d/70-dri.rules",
            "",
            "# Default cursor theme (so X11/Chromium find the Adwaita cursors)",
            "mkdir -p /mnt/usr/share/icons/default",
            "printf '%s\\n' '[Icon Theme]' 'Inherits=Adwaita' > /mnt/usr/share/icons/default/index.theme",
            "",
            "# Xorg config for virtio-gpu (use modesetting driver)",
            "mkdir -p /mnt/etc/X11/xorg.conf.d",
            "printf '%s\\n' 'Section \"Device\"' '  Identifier \"virtio\"' '  Driver \"modesetting\"' 'EndSection' '' 'Section \"ServerFlags\"' '  Option \"DRI2\" \"true\"' 'EndSection' > /mnt/etc/X11/xorg.conf.d/10-virtio.conf",
            "",
            "# Keyboard layout (mirrored from macOS host)",
            "printf '%s\\n' 'Section \"InputClass\"' '  Identifier \"keyboard-layout\"' '  MatchIsKeyboard \"on\"' '  Option \"XkbLayout\" \"\(keyboardLayout)\"' 'EndSection' > /mnt/etc/X11/xorg.conf.d/20-keyboard.conf",
            "",
            "# Scrolling direction (mirrored from macOS host)",
            "printf '%s\\n' 'Section \"InputClass\"' '  Identifier \"scrolling\"' '  MatchIsPointer \"on\"' '  Option \"NaturalScrolling\" \"\(naturalScrolling)\"' 'EndSection' > /mnt/etc/X11/xorg.conf.d/30-scrolling.conf",
            "",
            "# Allow non-root users to start X",
            "printf '%s\\n' 'allowed_users=anybody' 'needs_root_rights=yes' > /mnt/etc/X11/Xwrapper.config",
            "",
            "# Resize watcher — monitors virtio-gpu display changes and applies them",
            #"printf '#!/bin/sh\nOUTPUT=$(xrandr 2>/dev/null | grep " connected" | cut -d" " -f1 | head -1)\nif [ -z "$OUTPUT" ]; then OUTPUT="Virtual-1"; fi\nLAST=""\nwhile true; do\n  CUR=$(xrandr 2>/dev/null | grep "^$OUTPUT " | grep -o "[0-9]*x[0-9]*+[0-9]*+[0-9]*" | head -1 | cut -d+ -f1)\n  BEST=$(xrandr 2>/dev/null | grep -A1 "^$OUTPUT " | tail -1 | sed "s/^ *//" | cut -d" " -f1)\n  if [ -n "$BEST" ] && [ "$BEST" != "$CUR" ]; then\n    xrandr --output "$OUTPUT" --mode "$BEST" 2>/dev/null\n    LAST="$BEST"\n  fi\n  sleep 1\ndone\n' > /mnt/usr/local/bin/resize-watcher.sh"#,
            "chmod +x /mnt/usr/local/bin/resize-watcher.sh",
            "",
            "# xinitrc for chrome user - openbox WM + Chromium maximized",
            "printf '%s\\n' '#!/bin/sh' 'export XCURSOR_SIZE=\(displayScale * 24)' 'export XCURSOR_THEME=Adwaita' 'echo \"Xcursor.size: \(displayScale * 24)\" | xrdb -merge' '/usr/local/bin/resize-watcher.sh &' 'openbox &' 'cat /proc/asound/cards > /dev/hvc0 2>&1' 'pulseaudio --start --exit-idle-time=-1 2>/dev/null' 'sleep 0.5' 'pactl list sinks short > /dev/hvc0 2>&1' 'for i in $(seq 1 20); do [ -f /tmp/bromure/chrome-ready ] && break; sleep 0.2; done' 'EXTRA_FLAGS=' 'CHROME_URL=' 'SWAP_CMD_CTRL=' '[ -f /tmp/bromure/chrome-env ] && . /tmp/bromure/chrome-env' '[ \"$SWAP_CMD_CTRL\" = \"1\" ] && setxkbmap -option ctrl:swap_lwin_lctl,ctrl:swap_rwin_rctl' 'echo \"xinitrc: EXTRA_FLAGS=$EXTRA_FLAGS CHROME_URL=$CHROME_URL SWAP_CMD_CTRL=$SWAP_CMD_CTRL\" > /dev/hvc0' 'export LIBGL_ALWAYS_SOFTWARE=1' 'chromium-browser --no-first-run --disable-dev-shm-usage --start-maximized --force-device-scale-factor=\(displayScale) --use-gl=angle --use-angle=gl --ignore-gpu-blocklist --enable-gpu-rasterization --disable-vulkan --in-process-gpu $EXTRA_FLAGS $CHROME_URL' 'doas poweroff' > /mnt/home/chrome/.xinitrc",
            "chroot /mnt chown chrome:chrome /home/chrome/.xinitrc",
            "# Configure openbox: no decorations (no close/minimize/maximize buttons)",
            "mkdir -p /mnt/home/chrome/.config/openbox",
            "cp /mnt/etc/xdg/openbox/rc.xml /mnt/home/chrome/.config/openbox/rc.xml",
            "sed -i 's|<focusNew>yes</focusNew>|<focusNew>yes</focusNew>|' /mnt/home/chrome/.config/openbox/rc.xml",
            "sed -i 's|<followMouse>no</followMouse>|<followMouse>yes</followMouse>|' /mnt/home/chrome/.config/openbox/rc.xml",
            "sed -i 's|<raiseOnFocus>no</raiseOnFocus>|<raiseOnFocus>yes</raiseOnFocus>|' /mnt/home/chrome/.config/openbox/rc.xml",
            "sed -i 's|<decor>yes</decor>|<decor>no</decor>|g' /mnt/home/chrome/.config/openbox/rc.xml",
            "mkdir -p /mnt/home/chrome/.cache/openbox/sessions",
            "chroot /mnt chown -R chrome:chrome /home/chrome/.config /home/chrome/.cache",
            "",
            "# Auto-start X on login for chrome user",
            #"printf '%s\n' 'echo "profile: DISPLAY=$DISPLAY tty=$(tty)" > /dev/hvc0 2>/dev/null' 'if [ -z "$DISPLAY" ]; then' '  echo "starting X..." > /dev/hvc0 2>/dev/null' '  startx > /tmp/startx.log 2>&1' '  echo "startx exited: $?" > /dev/hvc0 2>/dev/null' '  cat /tmp/startx.log > /dev/hvc0 2>/dev/null' '  doas poweroff' 'fi' > /mnt/home/chrome/.profile"#,
            "chroot /mnt chown chrome:chrome /home/chrome/.profile",
            "",
            "# mkinitfs config for virtio — include all virtio and scsi modules",
            "printf '%s\\n' 'features=\"ata base ext4 virtio scsi\"' > /mnt/etc/mkinitfs/mkinitfs.conf",
            "# Also list available features for debugging",
            "chroot /mnt ls /etc/mkinitfs/features.d/ 2>/dev/null || true",
            "",
            "# Rebuild initramfs",
            "chroot /mnt sh -c 'mkinitfs $(ls /lib/modules/)'",
            "",
            "# Ensure USB HID modules load at boot (needed for VZ keyboard/mouse)",
            "printf '%s\\n' 'xhci_pci' 'usbhid' 'hid_generic' 'tun' 'nf_tables' 'nft_reject_inet' 'virtio_snd' >> /mnt/etc/modules",
            "",
            "# Sysctl settings for Cloudflare WARP",
            "printf '%s\\n' 'net.ipv4.conf.all.src_valid_mark=1' 'net.ipv6.conf.all.disable_ipv6=0' > /mnt/etc/sysctl.d/warp.conf",
            "",
            "# fstab",
            "printf '%s\\n' '/dev/vda  /  ext4  defaults,noatime  0 1' > /mnt/etc/fstab",
            "",
            "# Unmount",
            "umount /mnt/dev",
            "umount /mnt/sys",
            "umount /mnt/proc",
            "umount /mnt",
            "",
            "echo SANDBOX_SETUP_DONE",
        ].joined(separator: "\n")
    }
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
