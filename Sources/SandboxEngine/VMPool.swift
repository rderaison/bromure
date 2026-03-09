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

    /// Pre-warm a VM by booting it and waiting for Chromium to be ready.
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
        // VZ requires the real main dispatch queue for start/stop
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

        // Build chrome-env content to write immediately on boot detection
        if bromureDebug { print("[VMPool] Writing chrome-env: homePage='\(config.homePage)' forceDarkMode=\(config.forceDarkMode) adBlocking=\(config.enableAdBlocking)") }
        var extraFlags: [String] = []
        if config.forceDarkMode {
            extraFlags.append("--force-dark-mode --enable-features=WebContentsForceDark")
        }
        if config.enableNetworking && (config.enableAdBlocking || config.enableWarp) {
            extraFlags.append("--proxy-server=http://127.0.0.1:3128")
        }
        var envLines: [String] = []
        if !extraFlags.isEmpty {
            // extraFlags are hardcoded strings, safe to interpolate
            envLines.append("EXTRA_FLAGS=\"\(extraFlags.joined(separator: " "))\"")
        }
        envLines.append("CHROME_URL=\(shellEscape(config.homePage))")
        if config.swapCmdCtrl {
            envLines.append("SWAP_CMD_CTRL=1")
        }

        // Only start dnsmasq + squid when ad blocking or WARP is enabled.
        // When neither is active, Chrome runs directly without proxy.
        var bootScript = "mkdir -p /tmp/bromure && "
            + envLines.map { "echo \(shellEscape($0)) >> /tmp/bromure/chrome-env" }.joined(separator: " && ")
            + " && touch /tmp/bromure/chrome-ready"
        if config.enableNetworking && (config.enableAdBlocking || config.enableWarp) {
            // Run dnsmasq with pihole config
            bootScript += " && dnsmasq -C /etc/dnsmasq.d/pihole.conf"
            // If ad blocking, squid should resolve via dnsmasq (127.0.0.1); otherwise use system DNS
            if config.enableAdBlocking {
                bootScript += " && sed -i 's/^dns_nameservers.*/dns_nameservers 127.0.0.1/' /etc/squid/squid.conf"
            } else {
                bootScript += " && sed -i '/^dns_nameservers/d' /etc/squid/squid.conf"
            }
            // If WARP is not enabled, start squid now; otherwise defer until after WARP is connected
            if !config.enableWarp {
                bootScript += " && squid -N -f /etc/squid/squid.conf &"
            }
        }

        // Wait for boot, then immediately write config (before the 5s X11 wait)
        await waitForBoot(outputPipe: outputPipe, inputPipe: inputPipe, onBootDetected: bootScript)

        // Start Cloudflare WARP in proxy mode when enabled
        if config.enableWarp {
            let preload = "LD_PRELOAD=/usr/lib/libresolv_stub.so"
            let warpCommands = [
                "/usr/bin/dbus-daemon --system 2>/dev/null",
                "\(preload) /bin/warp-svc 1>/dev/null 2>/dev/null &",
                "sleep 3",
                "\(preload) /bin/warp-cli --accept-tos registration new 2>&1",
                "\(preload) /bin/warp-cli --accept-tos mode proxy 2>&1",
                "\(preload) /bin/warp-cli --accept-tos connect 2>&1",
                "sleep 5",
                "\(preload) /bin/warp-cli --accept-tos status 2>&1",
            ]

            for cmd in warpCommands {
                if bromureDebug { print("[VMPool] WARP: \(cmd)") }
                inputPipe.fileHandleForWriting.write(Data((cmd + "\n").utf8))
                if cmd.hasPrefix("sleep") {
                    let secs = Int(cmd.split(separator: " ").dropFirst().first ?? "2") ?? 2
                    try? await Task.sleep(for: .seconds(secs + 1))
                } else {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            if bromureDebug { print("[VMPool] WARP setup complete") }

            // Start squid via proxychains now that WARP is connected
            if config.enableWarp {
                let squidCmd = "proxychains4 -q -f /etc/proxychains/proxychains.conf squid -N -f /etc/squid/squid.conf &"
                if bromureDebug { print("[VMPool] Starting squid via proxychains") }
                inputPipe.fileHandleForWriting.write(Data((squidCmd + "\n").utf8))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil

        warmVM = WarmVM(
            vm: vm,
            ephemeralDisk: ephDisk,
            serialInput: inputPipe,
            serialOutput: outputPipe
        )
    }

    /// Claim the pre-warmed VM. Returns nil if none ready.
    /// Automatically triggers warming the next VM in the background.
    public func claim() -> WarmVM? {
        let result = warmVM
        warmVM = nil
        Task { try? await warmUp() }
        return result
    }

    /// Shut down the pool and clean up.
    public func shutdown() async {
        if let warm = warmVM {
            // Stop VM first on the main dispatch queue (VZ requirement)
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

    private func waitForBoot(outputPipe: Pipe, inputPipe: Pipe, onBootDetected: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let state = BootState()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                if bromureDebug { print(text, terminator: "") }
                state.accumulated += text

                // Shell prompt means Alpine has booted
                if !state.resolved && (state.accumulated.contains("localhost:~#") || state.accumulated.contains("login:")) {
                    state.resolved = true
                    // Write chrome-env IMMEDIATELY — xinitrc is waiting for it
                    inputPipe.fileHandleForWriting.write(Data((onBootDetected + "\n").utf8))
                    // Then wait for X11 + Chromium to initialize
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        cont.resume()
                    }
                }
            }

            // Timeout after 60s — proceed anyway
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if !state.resolved {
                    state.resolved = true
                    cont.resume()
                }
            }
        }
    }
}
