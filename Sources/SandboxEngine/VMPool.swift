import Foundation
import os
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
        /// Host-side network filter (must stay alive for the VM's lifetime).
        public var networkFilter: NetworkFilter?
        /// Monitors serial output for completion markers (used by applyConfig).
        let serialWaiter: SerialWaiter
    }

    private var config: VMConfig
    private let storageDir: URL
    private let imageManager: LinuxImageManager
    private var warmVM: WarmVM?
    private var isWarming = false
    private var configListenerDelegate: ConfigListenerDelegate?
    private var configListenerCleanup: (() -> Void)?
    private var rejectListenerDelegate: RejectListenerDelegate?

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

        // Network mode: NAT (default, via vmnet shared) or Bridged (via vmnet bridged)
        let defaults = UserDefaults.standard
        let networkMode = defaults.string(forKey: "vm.networkMode") ?? "nat"

        var networkFilter: NetworkFilter?
        var networkAttachment: VZNetworkDeviceAttachment?

        // Read DNS override from preferences (e.g. "1.1.1.1,1.0.0.1")
        let dnsOverride: [UInt32]
        if let dnsString = defaults.string(forKey: "vm.dnsServers"),
           !dnsString.trimmingCharacters(in: .whitespaces).isEmpty {
            dnsOverride = dnsString.split(separator: ",")
                .compactMap { HostNetworkInfo.parseIPv4(String($0).trimmingCharacters(in: .whitespaces)) }
        } else {
            dnsOverride = []
        }

        if let netInfo = HostNetworkInfo.detect() {
            let bridgedIface: String? = (networkMode == "bridged")
                ? defaults.string(forKey: "vm.bridgedInterface")
                : nil

            if let filter = NetworkFilter(
                networkInfo: netInfo,
                dnsOverrideServers: dnsOverride,
                bridgedInterface: bridgedIface
            ) {
                networkFilter = filter
                networkAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: filter.vmFileHandle)
                if bridgedIface != nil {
                    print("[VMPool] Using bridged networking via vmnet on \(bridgedIface!)")
                }
            } else {
                print("[VMPool] NetworkFilter unavailable (missing vmnet entitlement?), falling back to NAT")
            }
        } else {
            print("[VMPool] Could not detect host network info, falling back to NAT")
        }

        let vzConfig = try imageManager.buildLinuxVMConfig(
            diskURL: ephDisk.ephemeralURL,
            config: config,
            networkAttachment: networkAttachment
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
        let onBoot = "/usr/local/bin/on-boot.sh"
        let waiter = await waitForBoot(outputPipe: outputPipe, inputPipe: inputPipe, onBootDetected: onBoot)

        warmVM = WarmVM(
            vm: vm,
            ephemeralDisk: ephDisk,
            serialInput: inputPipe,
            serialOutput: outputPipe,
            networkFilter: networkFilter,
            serialWaiter: waiter
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
    public func scheduleWarmUp(delay: Duration = .seconds(20)) {
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
    /// Send a shell command over serial and wait for a unique marker in the output.
    private func serialExec(_ cmd: String, marker: String, input: FileHandle, waiter: SerialWaiter, timeout: TimeInterval = 10) async {
        input.write(Data((cmd + " && echo \(marker)\n").utf8))
        await waiter.waitFor(marker, timeout: timeout)
    }

    /// Config agent vsock port — must match config-agent.py.
    private static let configPort: UInt32 = 5000

    private func applyConfig(_ config: VMConfig, to warm: WarmVM, profileID: UUID?, hasProfileDisk: Bool, profileDiskKey: String?, restoreSession: Bool) async {
        let t0 = CFAbsoluteTimeGetCurrent()

        print("[VMPool] Applying config: homePage='\(config.homePage)' forceDarkMode=\(config.forceDarkMode) adBlocking=\(config.enableAdBlocking)")

        // Activate network filtering based on profile config
        if config.isolateFromLAN {
            if let filter = warm.networkFilter {
                filter.activateFiltering()
            } else {
                print("[VMPool] WARNING: isolateFromLAN=true but no NetworkFilter available")
            }
        }
        if let allowedPorts = config.allowedPorts {
            if let filter = warm.networkFilter {
                filter.activatePortFiltering(allowedPorts)
            } else {
                print("[VMPool] WARNING: port restriction requested but no NetworkFilter available")
            }
        }

        // Build JSON config for the guest config-agent
        let profileMountPoint = profileID.map { "/home/chrome/.\($0.uuidString)" }
        var cfg: [String: Any] = [
            "chromeURL": config.homePage
        ]

        // Profile disk
        if hasProfileDisk, let mountPoint = profileMountPoint {
            cfg["profileDisk"] = true
            cfg["profileMount"] = mountPoint
            cfg["profileDir"] = mountPoint
            if let profileDiskKey { cfg["profileDiskKey"] = profileDiskKey }
            if restoreSession { cfg["restoreSession"] = true }
        }

        if config.forceDarkMode { cfg["darkMode"] = true }
        if config.enableAdBlocking || config.enableWarp || config.blockMalwareSites { cfg["useProxy"] = true }
        if !config.enableGPU { cfg["disableGPU"] = true }
        if !config.enableWebGL { cfg["disableWebGL"] = true }
        if config.phishingWarning { cfg["phishingGuard"] = true }
        if config.swapCmdCtrl { cfg["swapCmdCtrl"] = true }
        if config.enableFileTransfer { cfg["fileTransfer"] = true }
        if config.enableClipboardSharing { cfg["clipboard"] = true }
        if config.blockMalwareSites { cfg["blockMalware"] = true }
        if config.enableAdBlocking { cfg["adBlocking"] = true }
        if config.enableWarp { cfg["enableWarp"] = true }
        if let proxyHost = config.proxyHost, let proxyPort = config.proxyPort {
            cfg["proxyHost"] = proxyHost
            cfg["proxyPort"] = proxyPort
            if let u = config.proxyUsername { cfg["proxyUsername"] = u }
            if let p = config.proxyPassword { cfg["proxyPassword"] = p }
        }
        if config.enableLinkSender { cfg["linkSender"] = true }
        if config.enableWebcam {
            cfg["webcam"] = true
            let res = WebcamBridge.queryCameraResolution(cameraID: config.webcamDeviceID)
            cfg["webcamWidth"] = res.width
            cfg["webcamHeight"] = res.height
        }
        if config.enableAudio {
            cfg["audio"] = true
            if config.audioVolume < 100 { cfg["audioVolume"] = config.audioVolume }
        }
        if config.enableMicrophone { cfg["microphone"] = true }
        if !config.rootCAs.isEmpty { cfg["rootCAs"] = config.rootCAs }
        cfg["locale"] = config.locale

        // Send config to guest via vsock.
        // Host listens on port 5000; guest config-agent.py connects to it.
        guard let socketDevice = warm.vm.socketDevices.first as? VZVirtioSocketDevice else {
            print("[VMPool] ERROR: no vsock device available for config agent")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: cfg)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Guard against double-resume (timeout vs cancel handler race)
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let safeResume = {
                    let alreadyResumed = resumed.withLock { val -> Bool in
                        if val { return true }
                        val = true
                        return false
                    }
                    if !alreadyResumed { cont.resume() }
                }

                let cleanup = {
                    socketDevice.removeSocketListener(forPort: Self.configPort)
                    self.configListenerDelegate = nil
                    self.configListenerCleanup = nil
                }
                let delegate = ConfigListenerDelegate(jsonData: jsonData, onDone: {
                    cleanup()
                    safeResume()
                })
                let listener = VZVirtioSocketListener()
                listener.delegate = delegate
                socketDevice.setSocketListener(listener, forPort: Self.configPort)
                self.configListenerDelegate = delegate
                self.configListenerCleanup = cleanup

                // Timeout after 30s
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if self.configListenerDelegate != nil {
                        print("[VMPool] config-agent timed out")
                        cleanup()
                        safeResume()
                    }
                }
            }
        } catch {
            print("[VMPool] ERROR: failed to serialize config JSON: \(error)")
        }

        // Close vsock for disabled agents so they exit cleanly instead of retrying.
        // Agents started at boot will connect and get an immediate EOF → clean exit.
        let rejectPorts: [UInt32] = [
            config.enableFileTransfer ? 0 : 5100,
            config.enableLinkSender   ? 0 : 5300,
            config.enableWebcam       ? 0 : 5400,
        ].filter { $0 != 0 }

        if !rejectPorts.isEmpty {
            let rejectDelegate = RejectListenerDelegate()
            for port in rejectPorts {
                let listener = VZVirtioSocketListener()
                listener.delegate = rejectDelegate
                socketDevice.setSocketListener(listener, forPort: port)
            }
            self.rejectListenerDelegate = rejectDelegate
            // Remove reject listeners after a few seconds (agents will have connected and exited)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                for port in rejectPorts {
                    socketDevice.removeSocketListener(forPort: port)
                }
                self?.rejectListenerDelegate = nil
            }
        }

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

    /// Tracks pending marker waits so the drain handler can resolve them.
    final class SerialWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var pending: [(marker: String, continuation: CheckedContinuation<Void, Never>)] = []

        func feed(_ text: String) {
            lock.lock()
            buffer += text
            var resolved: [CheckedContinuation<Void, Never>] = []
            pending.removeAll { entry in
                if buffer.contains(entry.marker) {
                    resolved.append(entry.continuation)
                    return true
                }
                return false
            }
            // Clear old data but keep the tail for partial marker matches
            if buffer.count > 4096 {
                buffer = String(buffer.suffix(1024))
            }
            lock.unlock()
            for cont in resolved { cont.resume() }
        }

        func waitFor(_ marker: String, timeout: TimeInterval = 10) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                if self.buffer.contains(marker) {
                    self.lock.unlock()
                    cont.resume()
                    return
                }
                self.pending.append((marker: marker, continuation: cont))
                self.lock.unlock()

                // Timeout fallback
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    if let idx = self.pending.firstIndex(where: { $0.marker == marker }) {
                        let entry = self.pending.remove(at: idx)
                        self.lock.unlock()
                        print("[VMPool] Marker wait timed out: \(marker)")
                        entry.continuation.resume()
                    } else {
                        self.lock.unlock()
                    }
                }
            }
        }
    }

    /// Wait for the VM to boot (shell prompt), then switch to a drain handler
    /// that keeps reading output so the pipe buffer never fills up.
    /// Returns a SerialWaiter that continues to monitor drain output for markers.
    private func waitForBoot(outputPipe: Pipe, inputPipe: Pipe, onBootDetected: String) async -> SerialWaiter {
        let waiter = SerialWaiter()
        let t0 = CFAbsoluteTimeGetCurrent()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let state = BootState()

            outputPipe.fileHandleForReading.readabilityHandler = { [waiter] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(data: data, encoding: .utf8)
                if bromureDebug, let text {
                    print(text, terminator: "")
                }

                // After boot, feed the waiter so applyConfig can wait on markers
                if state.resolved {
                    if let text { waiter.feed(text) }
                    return
                }

                if let text {
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
        return waiter
    }

    // MARK: - Memory Balloon

    /// Inflate the balloon to reclaim unused guest memory.
    /// Keeps a small amount (128 MB) for the idle shell and kernel.
    private func inflateBalloon(vm: VZVirtualMachine) {
        guard let balloon = vm.memoryBalloonDevices.first
                as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        let keep: UInt64 = 256 * 1024 * 1024  // 256 MB for idle guest
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

// MARK: - Config agent vsock listener delegate

/// Accepts a single vsock connection from the guest config-agent,
/// sends length-prefixed JSON config, waits for "OK", then calls onDone.
private final class ConfigListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let jsonData: Data
    private let onDone: () -> Void
    private var handled = false

    init(jsonData: Data, onDone: @escaping () -> Void) {
        self.jsonData = jsonData
        self.onDone = onDone
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        guard !handled else { return false }
        handled = true

        let fd = conn.fileDescriptor
        // Send [u32be length][json]
        var length = UInt32(jsonData.count).bigEndian
        _ = withUnsafeBytes(of: &length) { Darwin.write(fd, $0.baseAddress!, 4) }
        jsonData.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }

        // Wait for "OK" response on a background queue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                print("[VMPool] config-agent responded: \(String(bytes: buf[0..<n], encoding: .utf8) ?? "?")")
            }
            source.cancel()
        }
        source.setCancelHandler {
            _ = conn  // prevent conn from being deallocated before cancel
            self.onDone()
        }
        source.resume()
        return true
    }
}

/// Accepts vsock connections and immediately closes them,
/// signalling pre-started guest agents to exit for disabled features.
private final class RejectListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // Close the fd immediately so the guest agent gets EOF and exits.
        Darwin.close(conn.fileDescriptor)
        return true
    }
}
