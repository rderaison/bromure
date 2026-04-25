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
        /// nil when using Apple's native VZNATNetworkDeviceAttachment (default).
        /// Created at claim time only when the profile needs filtering or a specific interface.
        public var networkFilter: NetworkFilter?
        /// Monitors serial output for completion markers (used by applyConfig).
        public let serialWaiter: SerialWaiter
        /// MAC address claimed from the pool (release on teardown).
        public var macAddress: String?
        /// Whether the guest obtained an IP via DHCP during boot.
        public var networkReady: Bool = true
        /// Network mode the VM was booted/swapped to: "nat" or an interface name for bridged.
        public var bootedNetworkMode: String = "nat"
    }

    private var config: VMConfig
    private let storageDir: URL
    private let imageManager: LinuxImageManager
    private var warmVM: WarmVM?
    private var isWarming = false
    private var configListenerDelegate: ConfigListenerDelegate?
    private var configListenerCleanup: (() -> Void)?
    private var rejectListenerDelegate: RejectListenerDelegate?
    private var poolVMDelegate: PoolVMDelegate?
    private var suspendTimer: Timer?
    /// MAC address claimed by an in-flight warmUp() that hasn't set warmVM yet.
    /// Ensures shutdown() can release it even if warmUp is interrupted.
    private var warmingMAC: String?

    public var hasWarmVM: Bool { warmVM != nil }

    /// Access the pre-warmed VM (e.g. to install serial handlers before claiming).
    public var currentWarmVM: WarmVM? { warmVM }

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
        isWarming = true
        defer { isWarming = false }

        let defaults = UserDefaults.standard
        let networkMode = defaults.string(forKey: "vm.networkMode") ?? "nat"
        let bridgedIface: String?
        if networkMode == "bridged",
           let ifName = defaults.string(forKey: "vm.bridgedInterface"),
           !ifName.isEmpty {
            bridgedIface = ifName
        } else {
            bridgedIface = nil
        }

        let warm = try await bootVM(bridgedInterface: bridgedIface)
        warmVM = warm
        warmingMAC = nil  // Now tracked by warmVM.macAddress

        // Inflate balloon to reclaim unused guest memory while VM is idle.
        inflateBalloon(vm: warm.vm)

        // Suspend the pre-warmed VM after 30s to save CPU while it waits.
        // VZVirtualMachineView is created at claim time (after resume), so there's
        // no black-screen issue — the view connects to an already-running framebuffer.
        suspendTimer?.invalidate()
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let warm = self.warmVM, warm.vm.state == .running else { return }
                Task { @MainActor in
                    do {
                        try await warm.vm.pause()
                        print("[VMPool] Pre-warmed VM suspended to save CPU")
                    } catch {
                        print("[VMPool] Pre-warmed VM suspend failed: \(error)")
                    }
                }
            }
        }
    }

    /// Boot a fresh VM with the specified network mode.
    /// - Parameter bridgedInterface: Interface name for bridged mode, or nil for NAT.
    /// - Returns: A booted WarmVM ready for claim.
    private func bootVM(bridgedInterface: String?) async throws -> WarmVM {
        guard imageManager.baseImageExists else {
            throw SandboxError.baseImageNotFound
        }

        let ephDisk = EphemeralDisk(baseImageURL: imageManager.linuxDiskURL)
        try ephDisk.create()

        guard let mac = MACAddressPool.shared.claim() else {
            try? ephDisk.destroy()
            throw SandboxError.macPoolExhausted
        }
        warmingMAC = mac

        let bootedNetworkMode = bridgedInterface ?? "nat"

        // Always use VZFileHandleNetworkDeviceAttachment backed by NetworkFilter.
        // This avoids the NO-CARRIER bug from swapping attachment types at runtime.
        // Retry up to 3 times with backoff: on first launch after Gatekeeper approval
        // the vmnet entitlement may not be effective immediately.
        var networkFilter: NetworkFilter?
        for attempt in 1...3 {
            if let netInfo = HostNetworkInfo.detect() {
                networkFilter = NetworkFilter(networkInfo: netInfo, bridgedInterface: bridgedInterface)
            }
            if networkFilter != nil { break }
            if attempt < 3 {
                print("[VMPool] NetworkFilter creation failed (attempt \(attempt)/3), retrying in \(attempt)s...")
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        guard let networkFilter else {
            print("[VMPool] Failed to create NetworkFilter after 3 attempts")
            MACAddressPool.shared.release(mac)
            warmingMAC = nil
            try? ephDisk.destroy()
            throw SandboxError.networkFilterFailed
        }

        let networkAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: networkFilter.vmFileHandle)
        if bridgedInterface != nil {
            print("[VMPool] Booting VM with bridged networking on \(bridgedInterface!)")
        }

        let vzConfig = try imageManager.buildLinuxVMConfig(
            diskURL: ephDisk.ephemeralURL,
            config: config,
            networkAttachment: networkAttachment,
            macAddress: mac
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

        let onBoot = "/usr/local/bin/on-boot.sh"
        let waiter = await waitForBoot(outputPipe: outputPipe, inputPipe: inputPipe, onBootDetected: onBoot)

        let poolDelegate = PoolVMDelegate()
        vm.delegate = poolDelegate
        self.poolVMDelegate = poolDelegate

        return WarmVM(
            vm: vm,
            ephemeralDisk: ephDisk,
            serialInput: inputPipe,
            serialOutput: outputPipe,
            networkFilter: networkFilter,
            serialWaiter: waiter,
            macAddress: mac,
            networkReady: true,
            bootedNetworkMode: bootedNetworkMode
        )
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
        // If no pre-warmed VM is available, warm up on demand.
        // If another task is already warming up, wait for it to finish.
        if warmVM == nil {
            if isWarming {
                // Another task is warming up — poll until it finishes
                for _ in 0..<300 { // up to 30s
                    try? await Task.sleep(for: .milliseconds(100))
                    if warmVM != nil || !isWarming { break }
                }
            }
            if warmVM == nil {
                try? await warmUp()
            }
        }
        // If the warm VM died (e.g. pool was restarted), discard and warm a fresh one.
        // Paused is valid (pool suspends after 30s idle).
        if let warm = warmVM, warm.vm.state != .running && warm.vm.state != .paused {
            print("[VMPool] claim: discarding dead warm VM (state=\(warm.vm.state.rawValue))")
            if let mac = warm.macAddress { MACAddressPool.shared.release(mac) }
            try? warm.ephemeralDisk.destroy()
            warmVM = nil
            try? await warmUp()
        }

        // Check if the profile needs a different network mode than the pool VM.
        // If so, boot a dedicated VM with the right network from the start.
        // The pool VM is left for other profiles that match the global setting.
        let profileNetwork: String
        let profileBridgedIface: String?
        if let profileIface = config.networkInterface, !profileIface.isEmpty {
            if profileIface == "nat" {
                profileNetwork = "nat"
                profileBridgedIface = nil
            } else {
                profileNetwork = profileIface
                profileBridgedIface = profileIface
            }
        } else {
            profileNetwork = warmVM?.bootedNetworkMode ?? "nat"
            profileBridgedIface = nil  // will use pool VM as-is
        }

        if let warm = warmVM, profileNetwork != warm.bootedNetworkMode {
            print("[VMPool] claim: profile needs \(profileNetwork) but pool has \(warm.bootedNetworkMode) — booting dedicated VM")
            do {
                let dedicated = try await bootVM(bridgedInterface: profileBridgedIface)
                warmingMAC = nil
                deflateBalloon(vm: dedicated.vm)
                var warm = dedicated
                warm = applyNetworkFiltering(warm: warm, config: config)
                if let fsDevice = dedicated.vm.directorySharingDevices.first as? VZVirtioFileSystemDevice {
                    if let profileImageDir {
                        fsDevice.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: profileImageDir, readOnly: false))
                    } else {
                        fsDevice.share = nil
                    }
                }
                await applyConfig(config, to: warm, profileID: profileID, hasProfileDisk: profileImageDir != nil, profileDiskKey: profileDiskKey, restoreSession: restoreSession)
                print("[VMPool] claim: dedicated VM ready")
                // Schedule pool replacement
                scheduleWarmUp(delay: .seconds(3))
                return warm
            } catch {
                print("[VMPool] claim: dedicated VM boot failed: \(error)")
                return nil
            }
        }

        guard var warm = warmVM else {
            print("[VMPool] claim: no warm VM available")
            return nil
        }
        warmVM = nil
        suspendTimer?.invalidate()
        suspendTimer = nil
        print("[VMPool] claim: got warm VM (state=\(warm.vm.state.rawValue))")

        // Resume if the pre-warmed VM was suspended to save CPU
        if warm.vm.state == .paused {
            do {
                try await warm.vm.resume()
                print("[VMPool] Resumed pre-warmed VM for claim")
            } catch {
                print("[VMPool] Failed to resume pre-warmed VM: \(error)")
                if let mac = warm.macAddress { MACAddressPool.shared.release(mac) }
                try? warm.ephemeralDisk.destroy()
                return nil
            }
        }

        // Deflate balloon — give all memory back before running the browser
        deflateBalloon(vm: warm.vm)
        print("[VMPool] claim: balloon deflated")

        // Apply filtering to the existing NetworkFilter (same attachment type,
        // no VZ attachment swap needed — just host-side rule changes).
        warm = applyNetworkFiltering(warm: warm, config: config)
        print("[VMPool] claim: network filtering applied")

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
        print("[VMPool] claim: fs share configured, applying config...")

        await applyConfig(config, to: warm, profileID: profileID, hasProfileDisk: profileImageDir != nil, profileDiskKey: profileDiskKey, restoreSession: restoreSession)
        print("[VMPool] claim: config applied, returning VM")
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


        // Network filtering is already activated in claim() before applyConfig.

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
        // Squid always runs (unless custom proxy is set), so always flag useProxy
        if config.proxyHost == nil { cfg["useProxy"] = true }
        if !config.enableGPU { cfg["disableGPU"] = true }
        if !config.enableWebGL { cfg["disableWebGL"] = true }
        if config.enableGPU { cfg["gpuAccel"] = true }
        if config.enableZeroCopy { cfg["zeroCopy"] = true }
        if config.enableSmoothScrolling { cfg["smoothScrolling"] = true }
        if config.phishingWarning { cfg["phishingGuard"] = true }
        if config.swapCmdCtrl { cfg["swapCmdCtrl"] = true }
        if config.enableFileTransfer { cfg["fileTransfer"] = true }
        if config.enableClipboardSharing { cfg["clipboard"] = true }
        if config.enablePasskeys { cfg["passkeys"] = true }
        if config.enablePasswords { cfg["passwords"] = true }
        if config.blockMalwareSites { cfg["blockMalware"] = true }
        if config.enableAdBlocking { cfg["adBlocking"] = true }
        cfg["currentTime"] = Int(Date().timeIntervalSince1970)
        if config.vpnMode == .cloudflareWarp { cfg["enableWarp"] = true }
        if config.warpAutoConnect { cfg["warpAutoConnect"] = true }
        if config.vpnMode == .wireGuard, let wgConf = config.wireGuardConfig, !wgConf.isEmpty {
            cfg["enableWireGuard"] = true
            cfg["wireGuardConfig"] = wgConf
            if config.wireGuardAutoConnect { cfg["wireGuardAutoConnect"] = true }
        }
        if let server = config.ikev2Server, !server.isEmpty {
            cfg["enableIKEv2"] = true
            cfg["ikev2Server"] = server
            if let remoteID = config.ikev2RemoteID { cfg["ikev2RemoteID"] = remoteID }
            if let method = config.ikev2AuthMethod { cfg["ikev2AuthMethod"] = method }
            if let username = config.ikev2Username { cfg["ikev2Username"] = username }
            if let password = config.ikev2Password { cfg["ikev2Password"] = password }
            if let psk = config.ikev2PSK { cfg["ikev2PSK"] = psk }
            if let cert = config.ikev2ClientCert { cfg["ikev2ClientCert"] = cert }
            if let pass = config.ikev2CertPassphrase { cfg["ikev2CertPassphrase"] = pass }
            cfg["ikev2UseDNS"] = config.ikev2UseDNS
            if config.ikev2AutoConnect { cfg["ikev2AutoConnect"] = true }
            if let proxyHost = config.ikev2ProxyHost, !proxyHost.isEmpty,
               let proxyPort = config.ikev2ProxyPort, proxyPort > 0 {
                cfg["ikev2ProxyHost"] = proxyHost
                cfg["ikev2ProxyPort"] = proxyPort
                if let u = config.ikev2ProxyUsername { cfg["ikev2ProxyUsername"] = u }
                if let p = config.ikev2ProxyPassword { cfg["ikev2ProxyPassword"] = p }
            }
        }
        if let proxyHost = config.proxyHost, let proxyPort = config.proxyPort {
            cfg["proxyHost"] = proxyHost
            cfg["proxyPort"] = proxyPort
            if let u = config.proxyUsername { cfg["proxyUsername"] = u }
            if let p = config.proxyPassword { cfg["proxyPassword"] = p }
        }
        if config.enableLinkSender {
            cfg["linkSender"] = true
        }
        if config.enableWebcam {
            cfg["webcam"] = true
            let probeT0 = CFAbsoluteTimeGetCurrent()
            let res = WebcamBridge.queryCameraResolution(cameraID: config.webcamDeviceID, quality: config.webcamQuality)
            print("[VMPool] webcam probe: \(res.width)x\(res.height) in \(Int((CFAbsoluteTimeGetCurrent() - probeT0) * 1000))ms")
            cfg["webcamWidth"] = res.width
            cfg["webcamHeight"] = res.height
        }
        if config.enableAudio {
            cfg["audio"] = true
            if config.audioVolume < 100 { cfg["audioVolume"] = config.audioVolume }
        }
        if config.enableMicrophone { cfg["microphone"] = true }
        if config.blockDownloads { cfg["blockDownloads"] = true }
        if config.enableAutomation { cfg["automation"] = true }
        if config.nativeChrome { cfg["nativeChrome"] = true }
        if ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil {
            cfg["debugShell"] = true
        }
        if config.traceLevel != .disabled { cfg["traceLevel"] = config.traceLevel.rawValue }
        if !config.rootCAs.isEmpty { cfg["rootCAs"] = config.rootCAs }

        // Managed-profile mTLS: if this session's profile has a server-issued
        // leaf cert on disk, hand the cert + key + CA to the guest so it can
        // import them into the chrome user's NSS database before Chromium
        // starts. The private key material is kept in Keychain on the host
        // and copied into the (ephemeral) guest only for this session.
        //
        // We also pass the analytics endpoint's scheme+host so the guest can
        // drop a Chromium `AutoSelectCertificateForUrls` policy — that's
        // what stops Chrome from showing a cert-picker dialog every time
        // something under the guest hits the endpoint in-browser.
        if let pid = profileID,
           let mtls = ManagedProfileStore.shared.mtlsMaterial(profileId: pid) {
            var mtlsCfg: [String: Any] = [
                "certPem": mtls.certPem,
                "keyPem":  mtls.keyPem,
                "caPem":   mtls.caPem,
            ]
            let endpoint = CloudTracePolicy.defaultEndpoint
            if let scheme = endpoint.scheme, let host = endpoint.host {
                mtlsCfg["autoSelectURL"] = "\(scheme)://\(host)"
            }
            cfg["mtls"] = mtlsCfg

            // Corporate-site gating. `corporateWebsites` is a list of
            // hostnames (with or without www., scheme, port, path — the
            // guest-side extension normalizes them). `openExternalInPrivate`
            // toggles between the redirect-to-private and banner behaviors.
            // Managed sessions only; unmanaged flows don't get the extension
            // loaded at all (config-agent gates on cfg["corporateGuard"]).
            if let profile = ManagedProfileStore.shared.profile(id: pid) {
                var guardCfg: [String: Any] = [:]
                if case .array(let arr) = profile.settings["corporateWebsites"] {
                    let hosts = arr.compactMap { entry -> String? in
                        if case .string(let s) = entry { return s }
                        return nil
                    }
                    guardCfg["corporateWebsites"] = hosts
                }
                if case .bool(let b) = profile.settings["openExternalInPrivate"] {
                    guardCfg["openExternalInPrivate"] = b
                }
                // Only plumb when the admin actually configured at least
                // one of the keys. Absence of both → extension stays off.
                if !guardCfg.isEmpty {
                    cfg["corporateGuard"] = guardCfg
                }
            }
        }

        // Corporate-guard's `openExternalInPrivate` flow hands URLs back to
        // the host via the same cross-profile-open plumbing LinkSender uses.
        // Force link-sender on when the managed profile requires it — the
        // two features share infrastructure (vsock relay + host-side bridge),
        // and without it the handoff silently drops on the floor. Must run
        // AFTER cfg["corporateGuard"] is populated above.
        if let g = cfg["corporateGuard"] as? [String: Any],
           (g["openExternalInPrivate"] as? Bool) == true {
            cfg["linkSender"] = true
        }
        cfg["locale"] = config.locale

        // Display scale: read from UserDefaults so changing 1x/2x doesn't require image rebuild
        let displayScale = UserDefaults.standard.object(forKey: "vm.displayScale") as? Int ?? VMConfig.detectDisplayScale()
        cfg["displayScale"] = displayScale

        // App version for user-agent suffix
        if let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            cfg["appVersion"] = version
        }

        // Test suite: inject TEST_SUITE flag and expectations for guest test-runner.sh
        if config.testSuite {
            cfg["TEST_SUITE"] = "1"
            cfg["TEST_EXPECT_URL"] = config.homePage
            cfg["TEST_EXPECT_DARK_MODE"] = config.forceDarkMode ? "1" : "0"
            cfg["TEST_EXPECT_GPU"] = config.enableGPU ? "1" : "0"
            cfg["TEST_EXPECT_WEBGL"] = config.enableWebGL ? "1" : "0"
            cfg["TEST_EXPECT_AUDIO"] = config.enableAudio ? "1" : "0"
            if config.enableAudio && config.audioVolume < 100 {
                cfg["TEST_EXPECT_VOLUME"] = "\(config.audioVolume)"
            }
            cfg["TEST_EXPECT_CLIPBOARD"] = config.enableClipboardSharing ? "1" : "0"
            cfg["TEST_EXPECT_FILE_TRANSFER"] = config.enableFileTransfer ? "1" : "0"
            cfg["TEST_EXPECT_BLOCK_DOWNLOADS"] = config.blockDownloads ? "1" : "0"
            if let proxyHost = config.proxyHost {
                cfg["TEST_EXPECT_PROXY_HOST"] = proxyHost
            }
            let needsInternalProxy = config.enableAdBlocking || config.vpnMode == .cloudflareWarp || config.blockMalwareSites
            cfg["TEST_EXPECT_INTERNAL_PROXY"] = needsInternalProxy && config.proxyHost == nil ? "1" : "0"
            cfg["TEST_EXPECT_DNSMASQ"] = needsInternalProxy ? "1" : "0"
            cfg["TEST_EXPECT_SQUID"] = needsInternalProxy ? "1" : "0"
            cfg["TEST_EXPECT_MALWARE_DNS"] = config.blockMalwareSites ? "1" : "0"
            cfg["TEST_EXPECT_PHISHING"] = config.phishingWarning ? "1" : "0"
            cfg["TEST_EXPECT_LINK_SENDER"] = config.enableLinkSender ? "1" : "0"
            cfg["TEST_EXPECT_WEBCAM"] = config.enableWebcam ? "1" : "0"
            cfg["TEST_EXPECT_MICROPHONE"] = config.enableMicrophone ? "1" : "0"
            cfg["TEST_EXPECT_WEBRTC_BLOCKED"] = (!config.enableWebcam && !config.enableMicrophone) ? "1" : "0"
            cfg["TEST_EXPECT_LOCALE"] = config.locale
            cfg["TEST_EXPECT_CA_COUNT"] = "\(config.rootCAs.count)"
            cfg["TEST_EXPECT_SWAP_CMD_CTRL"] = config.swapCmdCtrl ? "1" : "0"
            cfg["TEST_EXPECT_USER_AGENT"] = "1"
        }

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

                // No timeout — the config-agent retries indefinitely and will
                // always connect eventually. A timeout here would silently
                // leave the VM without config (black screen, no Chrome).
            }
        } catch {
            print("[VMPool] ERROR: failed to serialize config JSON: \(error)")
        }

        // Close vsock for disabled agents so they exit cleanly instead of retrying.
        // Agents started at boot will connect and get an immediate EOF → clean exit.
        // For link-sender: also keep 5300 open if corporate-guard forced it on,
        // otherwise the guest's link-agent would get EOF and corporate-guard's
        // cross-profile handoff (which routes through the same channel) would
        // silently break.
        let linkSenderOn = config.enableLinkSender || (cfg["linkSender"] as? Bool == true)
        let rejectPorts: [UInt32] = [
            config.enableFileTransfer ? 0 : 5100,
            linkSenderOn              ? 0 : 5300,
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

    // MARK: - Network hot-swap

    /// Read DNS override servers from UserDefaults.
    private static func readDNSOverride() -> [UInt32] {
        guard let dnsString = UserDefaults.standard.string(forKey: "vm.dnsServers"),
              !dnsString.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return dnsString.split(separator: ",")
            .compactMap { HostNetworkInfo.parseIPv4(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// Enable filtering rules on the VM's existing NetworkFilter.
    /// The attachment type is never changed — only host-side filter rules are applied.
    private func applyNetworkFiltering(warm: WarmVM, config: VMConfig) -> WarmVM {
        let warm = warm

        if config.isolateFromLAN {
            if let filter = warm.networkFilter {
                filter.activateFiltering()
            }
        }
        if let allowedPorts = config.allowedPorts {
            if let filter = warm.networkFilter {
                // If a VPN is configured, its tunnel endpoint must stay
                // reachable regardless of how strict the user's allowlist is —
                // otherwise locking the list to e.g. "80,443" would prevent
                // WARP / WireGuard / IKEv2 from ever connecting.
                let vpnPorts = Self.vpnEndpointPorts(for: config)
                let merged: String
                if vpnPorts.isEmpty {
                    merged = allowedPorts
                } else {
                    let vpnSpec = vpnPorts.map(String.init).joined(separator: ",")
                    merged = allowedPorts.isEmpty ? vpnSpec : "\(allowedPorts),\(vpnSpec)"
                }
                filter.activatePortFiltering(merged)
            }
        }

        return warm
    }

    /// Ports the restrict-outgoing-ports filter must always allow so the
    /// configured VPN can establish its tunnel. Pure function — safe to call
    /// from any context.
    nonisolated static func vpnEndpointPorts(for config: VMConfig) -> [UInt16] {
        switch config.vpnMode {
        case .none:
            return []
        case .cloudflareWarp:
            // WARP's MASQUE tunnel runs over UDP/2408.
            return [2408]
        case .wireGuard:
            // Parse the `Endpoint = host:port` line(s) from the .conf.
            // Fall back to WireGuard's conventional port if missing.
            guard let conf = config.wireGuardConfig, !conf.isEmpty else { return [51820] }
            let ports = parseWireGuardEndpointPorts(conf)
            return ports.isEmpty ? [51820] : ports
        case .ikev2:
            // strongSwan defaults: IKE on UDP/500, NAT traversal on UDP/4500.
            return [500, 4500]
        }
    }

    nonisolated private static func parseWireGuardEndpointPorts(_ conf: String) -> [UInt16] {
        var ports: [UInt16] = []
        for line in conf.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("endpoint") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // IPv6 endpoints look like [::1]:51820; strip the bracketed host.
            let portPart: Substring
            if value.hasPrefix("["), let closeBracket = value.firstIndex(of: "]") {
                portPart = value[value.index(after: closeBracket)...].drop(while: { $0 == ":" })
            } else if let lastColon = value.lastIndex(of: ":") {
                portPart = value[value.index(after: lastColon)...]
            } else {
                continue
            }
            if let port = UInt16(portPart) { ports.append(port) }
        }
        return ports
    }

    /// Shut down the pool and clean up.
    public func shutdown() async {
        suspendTimer?.invalidate()
        suspendTimer = nil

        // Release any in-flight MAC from a warmUp() that hasn't finished yet.
        if let mac = warmingMAC {
            MACAddressPool.shared.release(mac)
            warmingMAC = nil
        }

        if let warm = warmVM {
            // Release DHCP lease so vmnet reclaims the address
            if warm.vm.state == .running {
                warm.serialInput.fileHandleForWriting.write(Data("udhcpc -R -i eth0 2>/dev/null\n".utf8))
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Release MAC address back to the pool
            if let mac = warm.macAddress {
                MACAddressPool.shared.release(mac)
            }
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
    public final class SerialWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var pending: [(marker: String, continuation: CheckedContinuation<Void, Never>)] = []
        private var probes: [(marker: String, continuation: CheckedContinuation<Bool, Never>)] = []

        /// Optional observer callback — called with every chunk of text fed to the waiter.
        public var observer: ((String) -> Void)?

        public func feed(_ text: String) {
            observer?(text)
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
            var probeResolved: [CheckedContinuation<Bool, Never>] = []
            probes.removeAll { entry in
                if buffer.contains(entry.marker) {
                    probeResolved.append(entry.continuation)
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
            for cont in probeResolved { cont.resume(returning: true) }
        }

        public func waitFor(_ marker: String, timeout: TimeInterval = 10) async {
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

        /// Wait for a marker, returning `true` if found within the timeout, `false` if timed out.
        public func probe(for marker: String, timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                self.lock.lock()
                if self.buffer.contains(marker) {
                    self.lock.unlock()
                    cont.resume(returning: true)
                    return
                }
                self.probes.append((marker: marker, continuation: cont))
                self.lock.unlock()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    if let idx = self.probes.firstIndex(where: { $0.marker == marker }) {
                        let entry = self.probes.remove(at: idx)
                        self.lock.unlock()
                        entry.continuation.resume(returning: false)
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
        let keep: UInt64 = 512 * 1024 * 1024  // 512 MB for idle guest
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

/// Delegate that logs when a pre-warmed VM stops unexpectedly.
private final class PoolVMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[VMPool] WARNING: pre-warmed VM stopped unexpectedly (guestDidStop)")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("[VMPool] WARNING: pre-warmed VM crashed: \(error)")
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
