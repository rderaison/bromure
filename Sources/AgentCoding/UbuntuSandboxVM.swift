import Foundation
import SandboxEngine
@preconcurrency import Virtualization

/// Boots an Ubuntu base image for an interactive session.
///
/// Per-profile session: boots from a CoW clone of the base image, mounts
/// the user's project folder via virtiofs, and provides a metadata share
/// carrying the API key + SSH keys.
@MainActor
public final class UbuntuSandboxVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    public enum State { case created, starting, running, stopped, error }
    public private(set) var state: State = .created
    public var onStopped: ((Error?) -> Void)?

    /// Called when the guest writes a URL request file into the outbox
    /// share. Wire this to NSWorkspace.shared.open in the GUI layer.
    public var onURLOpen: ((URL) -> Void)?

    /// Called when the in-VM tab agent reports that a kitty process for
    /// the given tab UUID has exited. Wire this to remove the tab pill.
    public var onTabClosed: ((UUID) -> Void)?

    /// Called every ~1.5s with the set of UUIDs of every kitty
    /// currently running in the guest. The host reconciles its tab
    /// model against this so a pill whose kitty died without sending
    /// closed-* (or never spawned) gets reaped instead of orphaned.
    public var onTabRoster: ((Set<UUID>) -> Void)?

    /// Called when the guest reports a fresh foreground-process name
    /// for a kitty (every ~1.5s). Use this to drive Terminal.app-style
    /// dynamic tab labels.
    public var onTabTitleUpdate: ((UUID, String) -> Void)?

    /// Most-recently-reported title per tab. Used to suppress redundant
    /// callbacks when the title hasn't changed between polls.
    private var lastReportedTitles: [UUID: String] = [:]

    /// Called whenever the guest writes a new primary IPv4 to the outbox
    /// (every 5s while the VM is up). Wire this to surface in the UI.
    public var onIPUpdate: ((String) -> Void)?

    /// Cached most-recently-reported IP so we only call `onIPUpdate` when
    /// it actually changes (avoids spammy re-renders).
    private var lastReportedIP: String?

    private let imageManager: UbuntuImageManager
    /// Exposed so the host can write tab-agent commands into the outbox.
    public let sessionDisk: SessionDisk?

    /// MAC claimed from the shared pool. Released on stop so the same
    /// address is reused next time, keeping vmnet's DHCP lease table small.
    private var claimedMAC: String?
    /// The underlying VZ machine. Exposed so the host app can attach a
    /// VZVirtualMachineView for display.
    public private(set) var vm: VZVirtualMachine?

    private var outboxPollTask: Task<Void, Never>?

    /// CPU count for the runtime VM. RAM is per-profile (Profile.memoryGB).
    public static let runtimeCPUs: Int = 4

    /// Session-less init for legacy callers. Boots base.img directly
    /// (Phase A behaviour) — kept so tools / smoke tests still work.
    public init(imageManager: UbuntuImageManager) {
        self.imageManager = imageManager
        self.sessionDisk = nil
        super.init()
    }

    /// Profile-aware init. Boots from the per-profile CoW disk and
    /// attaches the project + metadata virtiofs shares.
    public init(imageManager: UbuntuImageManager, sessionDisk: SessionDisk) {
        self.imageManager = imageManager
        self.sessionDisk = sessionDisk
        super.init()
    }

    public func prepare() throws {
        guard imageManager.hasBaseImage else {
            throw UbuntuImageError.installerStoppedEarly
        }

        // Resolve the disk to boot. Profile sessions get their own CoW
        // clone (created on first launch); legacy mode boots base directly.
        let bootDiskURL: URL
        if let sessionDisk {
            try sessionDisk.ensureDiskExists()
            bootDiskURL = sessionDisk.diskURL
        } else {
            bootDiskURL = imageManager.baseDiskURL
        }

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = Self.runtimeCPUs
        // Per-profile RAM. Default 8 GB if no profile (legacy CLI mode).
        let memGB = sessionDisk?.profile.memoryGB ?? 8
        config.memorySize = UInt64(memGB) * 1024 * 1024 * 1024

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: imageManager.efiVarsURL)
        config.bootLoader = bootLoader

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = Self.persistentMachineIdentifier(for: sessionDisk)
        config.platform = platform

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bootDiskURL, readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]

        let net = VZVirtioNetworkDeviceConfiguration()
        // Pick attachment based on profile's networkMode. Bridged falls
        // back to NAT if the chosen interface isn't available.
        let mode = sessionDisk?.profile.networkMode ?? .nat
        switch mode {
        case .nat:
            net.attachment = VZNATNetworkDeviceAttachment()
        case .bridged:
            let bridgedID = sessionDisk?.profile.bridgedInterfaceID
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            let match = interfaces.first(where: { $0.identifier == bridgedID })
                ?? interfaces.first
            if let iface = match {
                net.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            } else {
                FileHandle.standardError.write(Data(
                    "[run] no bridged interfaces available, falling back to NAT\n".utf8))
                net.attachment = VZNATNetworkDeviceAttachment()
            }
        }
        // One deterministic MAC per profile, persisted in the profile
        // dir. Cleaner than the shared pool (no leak-on-suspend, no
        // cross-app-run collisions) and is required for save/restore
        // anyway — VZ's `restoreMachineStateFrom` rejects a config with
        // a different MAC than the one in the saved RAM snapshot.
        if let session = sessionDisk,
           let vzMAC = VZMACAddress(string: session.persistentMACAddress()) {
            net.macAddress = vzMAC
        } else if let mac = MACAddressPool.shared.claim(),
                  let vzMAC = VZMACAddress(string: mac) {
            // Legacy session-less path (CLI smoke tests) — keep the
            // pool fallback so nothing regresses.
            net.macAddress = vzMAC
            self.claimedMAC = mac
        }
        config.networkDevices = [net]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Graphics + input.
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        config.graphicsDevices = [gpu]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Serial console: tee guest stdout to host stderr so we can see boot.
        let serialIn = Pipe()
        let serialOut = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: serialIn.fileHandleForReading,
            fileHandleForWriting: serialOut.fileHandleForWriting
        )
        config.serialPorts = [serial]
        serialOut.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { FileHandle.standardError.write(data) }
        }

        // SPICE console for clipboard sharing. VZ syncs the host's
        // NSPasteboard with the guest's selection clipboard automatically;
        // the guest just needs spice-vdagent running (apt-installed in
        // setup.sh, auto-started by systemd).
        let spiceConsole = VZVirtioConsoleDeviceConfiguration()
        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spiceAttachment = VZSpiceAgentPortAttachment()
        spiceAttachment.sharesClipboard = true
        spicePort.attachment = spiceAttachment
        spiceConsole.ports[0] = spicePort
        config.consoleDevices.append(spiceConsole)

        // Virtiofs shares: project (user's folder) + bromure-meta (env, ssh).
        // Both tags are referenced by /etc/fstab in the base image so they
        // mount at boot. We always attach the meta share. The project share
        // is attached only when the profile names a folder — fstab uses
        // `nofail` so a missing project tag won't block boot.
        var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        if let session = sessionDisk {
            // Persistent home (mounts AT /home/ubuntu in guest, overlays the
            // base image's empty home). Holds .bashrc, .npm-global, .cargo,
            // .ssh, .bash_history, etc. — everything that should survive a
            // disk reset.
            let homeFS = VZVirtioFileSystemDeviceConfiguration(tag: "bromure-home")
            homeFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: session.homeDirectory, readOnly: false)
            )
            sharingDevices.append(homeFS)

            // On restore, preserve directory inodes — see comments
            // in SessionDisk for why.
            let forRestore = session.hasSavedState
            let metaDir = try session.prepareMetadataShare(forRestore: forRestore)
            let metaFS = VZVirtioFileSystemDeviceConfiguration(tag: "bromure-meta")
            metaFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: metaDir, readOnly: true)
            )
            sharingDevices.append(metaFS)

            let outboxDir = try session.prepareOutboxDirectory(forRestore: forRestore)
            let outboxFS = VZVirtioFileSystemDeviceConfiguration(tag: "bromure-outbox")
            outboxFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: outboxDir, readOnly: false)
            )
            sharingDevices.append(outboxFS)

            // One virtiofs share per folder, with stable tags share-1
            // through share-N matching the base image's fstab slots.
            // xinitrc reads /mnt/bromure-meta/shares.txt and symlinks
            // /mnt/bromure-share-N → ~/<basename> on first session boot.
            for (i, share) in session.sharedFolders.enumerated() {
                let tag = "share-\(i + 1)"
                let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
                fs.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: share.url, readOnly: false)
                )
                sharingDevices.append(fs)
            }
        }
        config.directorySharingDevices = sharingDevices

        // Vsock device — host-side MITM engine listens on this for the
        // in-VM bridge daemon's HTTPS proxy + ssh-agent connections.
        // Adding the device unconditionally even for sessions where
        // we won't yet wire listeners; it costs nothing if unused.
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try config.validate()

        let virtualMachine = VZVirtualMachine(configuration: config)
        virtualMachine.delegate = self
        self.vm = virtualMachine
    }

    public func start() async throws {
        guard let vm = vm else { throw UbuntuImageError.installerStoppedEarly }
        state = .starting
        try await vm.start()
        state = .running
        startOutboxPolling()
    }

    /// True if a saved RAM snapshot is on disk for this profile and we
    /// should attempt `restore()` instead of a fresh `start()` on the
    /// next launch.
    public var hasSavedState: Bool {
        sessionDisk?.hasSavedState ?? false
    }

    /// Cancel the outbox poll task without going through guestDidStop
    /// (which triggers full cleanup including metadata-share removal).
    /// Used by the reboot path so the previous sandbox stops touching
    /// the outbox before we hand the same directory to a fresh sandbox.
    @MainActor
    public func stopPolling() {
        outboxPollTask?.cancel()
        outboxPollTask = nil
    }

    /// Restore the VM from a previously-saved RAM snapshot. The VZ
    /// configuration built in `prepare()` must match the one that was
    /// in effect when state was saved (same RAM size, same MAC, same
    /// machine identifier, same shared-directory paths) — that's why
    /// metadata + outbox dirs use stable per-profile paths, and the
    /// MAC + machine identifier are persisted in the profile dir.
    @MainActor
    public func restore() async throws {
        guard let vm = vm, let session = sessionDisk else {
            throw UbuntuImageError.installerStoppedEarly
        }
        let stateURL = session.savedStateURL
        state = .starting
        try await vm.restoreMachineStateFrom(url: stateURL)
        try await vm.resume()
        state = .running
        startOutboxPolling()
        // Touch the resume marker on the meta share — the guest's
        // bromure-resume.path systemd unit watches it and fires
        // `rdate -n -s pool.ntp.org` to fix the clock skew that
        // built up while the VM was paused. Best-effort: if the
        // meta dir isn't there, the guest just doesn't resync now
        // and systemd-timesyncd will catch up on its own schedule.
        if let metaDir = session.metadataDirectory {
            let signal = metaDir.appendingPathComponent(".resume-signal")
            let stamp = String(Int(Date().timeIntervalSince1970))
            try? stamp.write(to: signal, atomically: true, encoding: .utf8)
        }
    }

    /// Pause the VM and write its RAM contents to the per-profile
    /// `vm.state` file. Caller is expected to drop its references to
    /// this sandbox immediately after — the VM is left in the paused
    /// state and is not resumed.
    @MainActor
    public func suspend() async throws {
        guard let vm = vm, let session = sessionDisk else {
            throw UbuntuImageError.installerStoppedEarly
        }
        guard vm.canPause else {
            throw UbuntuImageError.installerStoppedEarly
        }
        outboxPollTask?.cancel()
        try await vm.pause()
        // VZ refuses to overwrite the destination (Code 11). After a
        // restore the prior snapshot is still on disk; nuke it before
        // writing the new one so suspend → restore → suspend works.
        try? FileManager.default.removeItem(at: session.savedStateURL)
        try await vm.saveMachineStateTo(url: session.savedStateURL)
        state = .stopped
    }

    /// VZVirtioSocketDevice for this VM. Exposed so the MITM engine
    /// can register listeners on it after start. nil before `prepare()`.
    public var socketDevice: VZVirtioSocketDevice? {
        vm?.socketDevices.first as? VZVirtioSocketDevice
    }

    /// Watches the outbox share for files dropped by the guest's
    /// `bromure-open` script and forwards each one to `onURLOpen`.
    private func startOutboxPolling() {
        guard let outbox = sessionDisk?.outboxDirectory else { return }
        outboxPollTask?.cancel()
        outboxPollTask = Task { @MainActor [weak self] in
            let fm = FileManager.default
            while !Task.isCancelled {
                // Read the always-present ip.txt without consuming it —
                // the guest rewrites it every 5s.
                let ipFile = outbox.appendingPathComponent("ip.txt")
                if let raw = try? String(contentsOf: ipFile, encoding: .utf8) {
                    let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ip.isEmpty, ip != self?.lastReportedIP {
                        self?.lastReportedIP = ip
                        self?.onIPUpdate?(ip)
                    }
                }
                if let entries = try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) {
                    for entry in entries where entry.pathExtension == "txt" {
                        let name = entry.lastPathComponent
                        // url-*.txt — guest's bromure-open relayed a URL.
                        if name.hasPrefix("url-") {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8))?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            try? fm.removeItem(at: entry)
                            guard let url = URL(string: raw),
                                  let scheme = url.scheme?.lowercased(),
                                  ["http", "https", "mailto"].contains(scheme) else {
                                continue
                            }
                            self?.onURLOpen?(url)
                            continue
                        }
                        // title-<uuid>.txt — guest agent's foreground-
                        // process snapshot. Constantly rewritten;
                        // don't delete. Only fire the callback when
                        // the value actually changes.
                        if name.hasPrefix("title-") {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8))?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let uuidPart = name
                                .replacingOccurrences(of: "title-", with: "")
                                .replacingOccurrences(of: ".txt", with: "")
                            if let uuid = UUID(uuidString: uuidPart), !raw.isEmpty,
                               self?.lastReportedTitles[uuid] != raw {
                                self?.lastReportedTitles[uuid] = raw
                                self?.onTabTitleUpdate?(uuid, raw)
                            }
                            continue
                        }
                        // closed-<uuid>.txt — guest agent reports a tab's
                        // kitty has exited. Remove the matching pill.
                        if name.hasPrefix("closed-") {
                            try? fm.removeItem(at: entry)
                            let uuidPart = name
                                .replacingOccurrences(of: "closed-", with: "")
                                .replacingOccurrences(of: ".txt", with: "")
                            if let uuid = UUID(uuidString: uuidPart) {
                                self?.onTabClosed?(uuid)
                            }
                            continue
                        }
                        // tabs-alive.txt — guest agent's per-tick roster
                        // of every running kitty's UUID, one per line.
                        // Constantly rewritten atomically; don't delete.
                        // The empty-file case is meaningful (no kittys
                        // running → reap any orphan pill).
                        if name == "tabs-alive.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            let alive = Set(raw
                                .split(whereSeparator: \.isNewline)
                                .compactMap { UUID(uuidString: String($0)) })
                            self?.onTabRoster?(alive)
                            continue
                        }
                        // cmd-*.txt — host-written, consumed by the in-VM
                        // tab agent. Leave alone.
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            onStopped = { _ in cont.resume() }
        }
    }

    public nonisolated func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        Task { @MainActor in
            self.state = .error
            self.releaseMACToPool()
            self.onStopped?(error)
        }
    }

    public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            self.state = .stopped
            self.outboxPollTask?.cancel()
            self.sessionDisk?.cleanupMetadataShare()
            self.releaseMACToPool()
            self.onStopped?(nil)
        }
    }

    private func releaseMACToPool() {
        if let mac = claimedMAC {
            MACAddressPool.shared.release(mac)
            claimedMAC = nil
        }
    }

    /// Load the profile's persistent VZ machine identifier from disk, or
    /// mint and persist a fresh one on first call. Falls back to an
    /// in-memory identifier (no persistence) when there's no
    /// session disk — same as the legacy behaviour for tooling-mode
    /// boots that aren't tied to a profile.
    private static func persistentMachineIdentifier(for sessionDisk: SessionDisk?)
        -> VZGenericMachineIdentifier
    {
        guard let sessionDisk else { return VZGenericMachineIdentifier() }
        let url = sessionDisk.machineIdentifierURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? id.dataRepresentation.write(to: url, options: .atomic)
        return id
    }
}

