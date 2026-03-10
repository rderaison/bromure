import Foundation
import Virtualization

/// Manages a pool of pre-warmed Linux VMs for instant browser windows.
///
/// Pre-boots a VM in the background so that "File > New Browser" is instant.
/// When a VM is claimed (shown to user), the next one starts booting immediately.
private let bromureDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

@MainActor
public final class VMPool {
    /// A pre-warmed VM ready to be shown to the user.
    public struct WarmVM {
        public let vm: VZVirtualMachine
        public let ephemeralDisk: EphemeralDisk
        public let serialInput: Pipe
        public let serialOutput: Pipe
    }

    private var config: VMConfig
    private let storageDir: URL
    private let imageManager: LinuxImageManager
    private var warmVM: WarmVM?
    private var isWarming = false

    public var hasWarmVM: Bool { warmVM != nil }

    public var baseImageExists: Bool { imageManager.baseImageExists }

    /// Update the config used for the next warm-up.
    public func updateConfig(_ config: VMConfig) {
        self.config = config
    }

    public init(config: VMConfig, storageDir: URL? = nil) {
        self.config = config
        let dir = storageDir ?? VMConfig.defaultStorageDirectory
        self.storageDir = dir
        self.imageManager = LinuxImageManager(storageDir: dir)
    }

    /// Pre-warm a VM by booting it to an idle shell prompt.
    ///
    /// The VM boots with no chrome-env, no services — just Alpine at a shell prompt.
    /// The guest xinitrc waits up to 120s for `/tmp/bromure/chrome-ready`, which is
    /// written later by `applyConfig(_:to:)` when the user claims the VM.
    public func warmUp() async throws {
        guard !isWarming, warmVM == nil else { return }
        guard imageManager.baseImageExists else {
            throw SandboxError.baseImageNotFound
        }

        isWarming = true
        defer { isWarming = false }

        let ephDisk = EphemeralDisk(baseImageURL: imageManager.linuxDiskURL)
        try ephDisk.create()

        let vzConfig = try imageManager.buildLinuxVMConfig(
            diskURL: ephDisk.ephemeralURL,
            config: config
        )

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serial]
        try vzConfig.validate()

        let vm = VZVirtualMachine(configuration: vzConfig)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.start { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }

        // Wait for boot (shell prompt), just create /tmp/bromure — no config yet.
        // After boot detection, the handler switches to drain mode (keeps reading
        // so the pipe buffer doesn't fill up and block the VM's shell).
        await waitForBoot(outputPipe: outputPipe, inputPipe: inputPipe, onBootDetected: "/usr/local/bin/on-boot.sh")

        warmVM = WarmVM(
            vm: vm,
            ephemeralDisk: ephDisk,
            serialInput: inputPipe,
            serialOutput: outputPipe
        )

        // Inflate balloon to reclaim unused guest memory while VM is idle.
        // The idle Alpine shell uses ~80-100 MB; reclaim the rest.
        inflateBalloon(vm: vm)
    }

    /// Claim the pre-warmed VM with a specific config applied at claim time.
    ///
    /// For persistent profiles, the profile disk image is symlinked into the
    /// virtio-fs shared directory so the guest can loop-mount it.
    /// For ephemeral sessions, the shared directory is deleted from the host
    /// so a compromised guest cannot reach any host files.
    ///
    /// Writes chrome-env, starts services, and touches chrome-ready so xinitrc
    /// proceeds. Returns nil if no VM is available.
    public func claim(
        config: VMConfig,
        profileID: UUID? = nil,
        profileImageDir: URL? = nil,
        profileDiskKey: String? = nil,
        restoreSession: Bool = false
    ) async -> WarmVM? {
        // If no pre-warmed VM is available, warm up on demand
        if warmVM == nil {
            try? await warmUp()
        }
        guard let warm = warmVM else { return nil }
        warmVM = nil
        // Deflate balloon — give all memory back before running the browser
        deflateBalloon(vm: warm.vm)

        // Point the virtio-fs share to the profile's image directory,
        // or disconnect it entirely for ephemeral sessions.
        if let fsDevice = warm.vm.directorySharingDevices.first as? VZVirtioFileSystemDevice {
            if let profileImageDir {
                fsDevice.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: profileImageDir, readOnly: false)
                )
            } else {
                fsDevice.share = nil
            }
        }

        await applyConfig(config, to: warm, profileID: profileID, hasProfileDisk: profileImageDir != nil, profileDiskKey: profileDiskKey, restoreSession: restoreSession)
        return warm
    }

    /// Schedule a warm-up after a delay, to avoid resource contention with the
    /// session that just launched.
    public func scheduleWarmUp(delay: Duration = .seconds(5)) {
        Task {
            try? await Task.sleep(for: delay)
            try? await warmUp()
        }
    }

    /// Apply a profile's config to a booted-but-idle VM.
    ///
    /// Writes chrome-env, starts network services, unlocks LUKS disk if needed,
    /// and THEN touches chrome-ready to unblock xinitrc.
    /// The output pipe must remain readable (drain handler) to prevent the VM
    /// from blocking on console writes.
    private func applyConfig(_ config: VMConfig, to warm: WarmVM, profileID: UUID?, hasProfileDisk: Bool, profileDiskKey: String?, restoreSession: Bool) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let input = warm.serialInput.fileHandleForWriting

        print("[VMPool] Applying config: homePage='\(config.homePage)' forceDarkMode=\(config.forceDarkMode) adBlocking=\(config.enableAdBlocking)")

        // Mount profile disk via virtio-fs share + loop device.
        // The host sets fsDevice.share in claim() before calling applyConfig,
        // so we mount virtio-fs here (it wasn't available at boot time).
        let profileMountPoint = profileID.map { "/home/chrome/.\($0.uuidString)" }
        if hasProfileDisk, let mountPoint = profileMountPoint {
            let t1 = CFAbsoluteTimeGetCurrent()
            let diskPath = "/mnt/share/profile.img"

            // Mount virtio-fs first (the share was just pointed to the image dir)
            input.write(Data("mount -t virtiofs share /mnt/share\n".utf8))
            try? await Task.sleep(for: .seconds(1))

            if let profileDiskKey {
                // Encrypted: LUKS format (if new), unlock, and mount via loop
                print("[VMPool] Unlocking LUKS profile disk...")
                let loopSetup = "LOOP=$(losetup -f) && losetup $LOOP \(diskPath)"
                input.write(Data((loopSetup + "\n").utf8))
                try? await Task.sleep(for: .seconds(1))

                let formatCmd = "cryptsetup isLuks $LOOP 2>/dev/null || { " + ProfileDisk.luksFormatCommand(key: profileDiskKey, device: "$LOOP") + "; }"
                input.write(Data((formatCmd + "\n").utf8))
                try? await Task.sleep(for: .seconds(2))

                let unlockCmd = ProfileDisk.luksUnlockAndMountCommand(key: profileDiskKey, device: "$LOOP", mountPoint: mountPoint)
                input.write(Data((unlockCmd + "\n").utf8))
                try? await Task.sleep(for: .seconds(2))
                print("[VMPool] LUKS unlocked in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t1))s")
            } else {
                // Unencrypted: format if new, then loop-mount
                print("[VMPool] Mounting unencrypted profile disk...")
                let mountCmd = "mkdir -p \(mountPoint) && (blkid \(diskPath) >/dev/null 2>&1 || mkfs.ext4 -q \(diskPath)) && mount -o loop \(diskPath) \(mountPoint) && chown chrome:chrome \(mountPoint)"
                input.write(Data((mountCmd + "\n").utf8))
                try? await Task.sleep(for: .seconds(1))
                print("[VMPool] Disk mounted in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t1))s")
            }
        }

        // Build environment variables for apply-config.sh
        var envVars: [String] = []
        if config.forceDarkMode { envVars.append("DARK_MODE=1") }
        if config.enableAdBlocking || config.enableWarp || config.blockMalwareSites { envVars.append("USE_PROXY=1") }
        if !config.enableGPU { envVars.append("DISABLE_GPU=1") }
        if !config.enableWebGL { envVars.append("DISABLE_WEBGL=1") }
        if config.phishingWarning { envVars.append("PHISHING_GUARD=1") }
        if let mountPoint = profileMountPoint, hasProfileDisk {
            envVars.append("PROFILE_DIR=\(mountPoint)")
            if restoreSession { envVars.append("RESTORE_SESSION=1") }
        }
        envVars.append("CHROME_URL=\(shellEscape(config.homePage))")
        if config.swapCmdCtrl { envVars.append("SWAP_CMD_CTRL=1") }
        if config.enableFileTransfer { envVars.append("FILE_TRANSFER=1") }
        if config.enableClipboardSharing { envVars.append("CLIPBOARD=1") }
        if config.blockMalwareSites { envVars.append("BLOCK_MALWARE=1") }
        if config.enableAdBlocking { envVars.append("AD_BLOCKING=1") }
        if config.enableWarp { envVars.append("ENABLE_WARP=1") }

        let cmd = envVars.joined(separator: " ") + " /usr/local/bin/apply-config.sh"
        input.write(Data((cmd + "\n").utf8))

        print("[VMPool] applyConfig total: \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s")
    }

    /// Shut down the pool and clean up.
    public func shutdown() async {
        if let warm = warmVM {
            if warm.vm.state == .running || warm.vm.state == .paused {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async {
                        warm.vm.stop { _ in cont.resume() }
                    }
                }
            }
            warm.serialOutput.fileHandleForReading.readabilityHandler = nil
            warm.serialInput.fileHandleForWriting.readabilityHandler = nil
            try? warm.serialOutput.fileHandleForReading.close()
            try? warm.serialOutput.fileHandleForWriting.close()
            try? warm.serialInput.fileHandleForReading.close()
            try? warm.serialInput.fileHandleForWriting.close()
            try? warm.ephemeralDisk.destroy()
            warmVM = nil
        }
    }

    // MARK: - Private

    /// Mutable state shared between the readability handler and timeout callback.
    private final class BootState: @unchecked Sendable {
        var resolved = false
        var accumulated = ""
    }

    /// Wait for the VM to boot (shell prompt), then switch to a drain handler
    /// that keeps reading output so the pipe buffer never fills up.
    private func waitForBoot(outputPipe: Pipe, inputPipe: Pipe, onBootDetected: String) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let state = BootState()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if bromureDebug, let text = String(data: data, encoding: .utf8) {
                    print(text, terminator: "")
                }

                if !state.resolved, let text = String(data: data, encoding: .utf8) {
                    state.accumulated += text

                    // Shell prompt means Alpine has booted
                    if state.accumulated.contains("localhost:~#") || state.accumulated.contains("login:") {
                        state.resolved = true
                        inputPipe.fileHandleForWriting.write(Data((onBootDetected + "\n").utf8))
                        // Brief delay for the command to execute, then resume.
                        // The readabilityHandler stays active as a drain — this is
                        // critical to prevent the pipe buffer from filling up and
                        // blocking the VM's shell when it writes console output.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("[VMPool] Boot detected in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s")
                            cont.resume()
                        }
                    }
                }
            }

            // Timeout after 60s — proceed anyway
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if !state.resolved {
                    state.resolved = true
                    print("[VMPool] Boot timed out after 60s")
                    cont.resume()
                }
            }
        }
        // NOTE: Do NOT nil out readabilityHandler here.
        // It must keep draining output or the VM will block.
    }

    // MARK: - Memory Balloon

    /// Inflate the balloon to reclaim unused guest memory.
    /// Keeps a small amount (128 MB) for the idle shell and kernel.
    private func inflateBalloon(vm: VZVirtualMachine) {
        guard let balloon = vm.memoryBalloonDevices.first
                as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        let keep: UInt64 = 128 * 1024 * 1024  // 128 MB for idle guest
        let total = config.memorySize
        let target = total > keep ? total - keep : 0
        balloon.targetVirtualMachineMemorySize = keep
        if bromureDebug {
            print("[VMPool] Balloon inflated: reclaiming \(target / 1024 / 1024) MB, guest keeps \(keep / 1024 / 1024) MB")
        }
    }

    /// Deflate the balloon to return all memory to the guest.
    private func deflateBalloon(vm: VZVirtualMachine) {
        guard let balloon = vm.memoryBalloonDevices.first
                as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        balloon.targetVirtualMachineMemorySize = config.memorySize
        if bromureDebug {
            print("[VMPool] Balloon deflated: guest has full \(config.memorySize / 1024 / 1024) MB")
        }
    }
}
