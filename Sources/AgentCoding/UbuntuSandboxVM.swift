import Foundation
import SandboxEngine
@preconcurrency import Virtualization

// MARK: - docker `--format '{{json .}}'` line shapes

/// One line of `docker ps -a --format '{{json .}}'`. Field names match docker's
/// JSON keys exactly. `State` is absent on very old docker, so it's optional and
/// we fall back to the `Status` text.
private struct DockerPSJSON: Decodable {
    let ID: String
    let Names: String
    let Image: String
    let Status: String
    let Ports: String?
    let RunningFor: String?
    private let StateRaw: String?
    var State: String { StateRaw ?? (Status.hasPrefix("Up") ? "running" : "exited") }
    enum CodingKeys: String, CodingKey { case ID, Names, Image, Status, Ports, RunningFor, StateRaw = "State" }
}

private struct DockerStatsJSON: Decodable {
    let ID: String
    let CPUPerc: String?
    let MemUsage: String?
}

private struct DockerImageJSON: Decodable {
    let ID: String
    let Repository: String
    let Tag: String
    let Size: String?
    let CreatedSince: String?
}

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

    /// Called every ~0.7s with the current tmux window list — each entry is
    /// (window index, whether it's the active window, foreground command,
    /// and the @container option if the window is a docker-exec attach tab).
    /// tmux is the source of truth, so the host mirrors this directly as the
    /// tab bar; there's no per-process liveness reconciliation.
    public var onTabList: (([(index: Int, active: Bool, label: String, containerID: String?)]) -> Void)?

    /// Called ~every 2s with the guest's container list (from `docker ps -a`,
    /// running + stopped). Empty when docker is absent / the daemon is down.
    /// Drives the "Docker" sub-tree and the dashboard.
    public var onDockerList: (([DockerContainer]) -> Void)?

    /// Called ~every 2s WHILE a dashboard is open with per-container CPU/mem
    /// (from `docker stats --no-stream`). Keyed by full container id.
    public var onDockerStats: (([(id: String, cpu: String, mem: String)]) -> Void)?

    /// VM vitals for the workspace dashboard (~every 1.5s): aggregate CPU%,
    /// memory used/total (KB), and 1-minute load average.
    public var onVMStats: ((_ cpu: Double, _ memUsedKB: Int, _ memTotalKB: Int, _ load: Double) -> Void)?

    /// Called ~every 2s WHILE a dashboard is open with the local image list
    /// (from `docker images`).
    public var onDockerImages: (([DockerImage]) -> Void)?

    /// Called when a docker action (run / start / stop / remove) fails in the
    /// guest — carries docker's stderr. One-shot: the file is consumed on read.
    public var onDockerError: ((String) -> Void)?

    /// Called (dashboard-only) with the qemu arch suffixes registered+enabled in
    /// binfmt_misc (e.g. ["x86_64","arm"]). Empty = emulation not installed.
    public var onDockerBinfmt: (([String]) -> Void)?

    /// Called (dashboard-only) with each running container's architecture
    /// (id, arch e.g. "amd64"/"arm64"/"arm/v7").
    public var onDockerArch: (([(id: String, arch: String)]) -> Void)?

    /// Called with the current "run job" progress while a detached `docker run`
    /// is pulling/starting — (state, image, done, total). state is "" when idle.
    public var onDockerRunStatus: (((state: String, image: String, done: Int, total: Int)) -> Void)?

    /// Called when the guest bounces a host-owned keychord (⌘T/⌘W/⌘N/⌘1-9)
    /// back to the host. While the VM holds keyboard focus the VZ view
    /// forwards every chord to the guest before AppKit can intercept it, so
    /// Openbox in the guest globally grabs these chords (consuming them so
    /// kitty never acts) and drops a `shortcut-<key>.txt` marker in the
    /// outbox. The value is the bare key ("t", "w", "n", "1"…"9"). Wire to
    /// the same action the host key monitor runs — the two paths are mutually
    /// exclusive by focus, so a single press fires exactly one of them.
    public var onShortcut: ((String) -> Void)?

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
    /// VM-side handle of this VM's port on the shared `VMNetSwitch` (NAT mode
    /// only). Detached on stop so the switch forgets its learned MACs.
    private var switchPort: FileHandle?
    /// The underlying VZ machine. Exposed so the host app can attach a
    /// VZVirtualMachineView for display.
    public private(set) var vm: VZVirtualMachine?

    private var outboxPollTask: Task<Void, Never>?

    /// CPU count for the runtime VM. RAM is per-profile (Profile.memoryGB).
    public static let runtimeCPUs: Int = 4

    /// Session-less init for legacy callers. Boots base.img directly
    /// (no per-profile disk) — kept so tools / smoke tests still work.
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

    deinit {
        // Safety net for teardown paths that never run `guestDidStop` — notably
        // `suspend()`, which only *pauses* the VM, saves a RAM snapshot, and
        // expects the caller to drop this object. Without this the switch would
        // keep that VM's host fd, read loop and MAC-table entry forever. Keep
        // the DHCP lease (releaseLease: false): a resumed snapshot restores with
        // the same IP and never re-DHCPs, so the address must stay reserved.
        // The normal stop path already detached (and freed the lease) and set
        // `switchPort` to nil, so this is a no-op there.
        if let switchPort {
            VMNetSwitch.shared.detachPort(switchPort, releaseLease: false)
        }
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
            // Attach to the process-wide software switch so every AC VM shares
            // one vmnet/NAT segment: distinct DHCP IPs + mutual reachability,
            // instead of each VM getting its own island that collides on .2.
            // Fall back to Apple's NAT if the switch can't bring up vmnet.
            if let port = VMNetSwitch.shared.attachPort() {
                net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: port)
                self.switchPort = port
            } else {
                net.attachment = VZNATNetworkDeviceAttachment()
            }
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

    /// Save the RAM state of an already-paused VM. Used by the
    /// compromise handler, which pauses the VM the moment exfiltration
    /// is detected and then asks the user what to do — by the time
    /// "Save for Investigation" lands here, `canPause` is false because
    /// we're already paused, so the regular `suspend()` would refuse.
    @MainActor
    public func saveAlreadyPausedState() async throws {
        guard let vm = vm, let session = sessionDisk else {
            throw UbuntuImageError.installerStoppedEarly
        }
        outboxPollTask?.cancel()
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
            // One task, two cadences. Host-owned keychords (⌘T/⌘W/⌘N/⌘1-9)
            // that the guest bounced are drained every tick (~40ms) so the pill
            // appears the instant the chord lands — routing them through the
            // 500ms heavy cadence is what made ⌘T feel sluggish. Everything else
            // in the outbox (ip / url relay / titles / roster) is latency-
            // tolerant and stays on the ~480ms cadence via the tick gate below.
            var ticks = 0
            while !Task.isCancelled {
                // FAST PATH — shortcut-<key>.txt: a host-owned chord Openbox
                // grabbed in the guest and bounced back while the VM held
                // keyboard focus. Fixed filename per key, so a held chord's
                // autorepeat just overwrites it; we delete on read and the sink
                // (performACShortcut) collapses what's left. Body is empty —
                // the key is in the filename.
                if let entries = try? fm.contentsOfDirectory(
                    at: outbox, includingPropertiesForKeys: nil) {
                    for entry in entries
                    where entry.lastPathComponent.hasPrefix("shortcut-") {
                        try? fm.removeItem(at: entry)
                        let key = entry.lastPathComponent
                            .replacingOccurrences(of: "shortcut-", with: "")
                            .replacingOccurrences(of: ".txt", with: "")
                        if !key.isEmpty { self?.onShortcut?(key) }
                    }
                }

                // Throttle the heavier scan to ~every 12th tick (~480ms) so
                // titles / roster / url relay keep their original cadence.
                ticks &+= 1
                if ticks % 12 != 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    continue
                }

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
                // Bound how much guest-driven URL relay work happens
                // per poll tick. A compromised guest could otherwise
                // flood the outbox with url-*.txt files and use the
                // host's default browser as a spam cannon. The cap
                // resets every poll iteration, so legitimate OAuth
                // URLs are only delayed (~ticks-to-drain), never
                // dropped.
                let maxURLsPerTick = 8
                // Real OAuth URLs are well under 4 KB. Anything larger
                // is either junk or an attempt to flood the host's
                // memory + URL parser with a huge body.
                let maxURLFileSize = 8 * 1024
                var urlsProcessedThisTick = 0
                if let entries = try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) {
                    for entry in entries where entry.pathExtension == "txt" {
                        let name = entry.lastPathComponent
                        // url-*.txt — guest's bromure-open relayed a URL.
                        if name.hasPrefix("url-") {
                            // Hit the per-tick cap: leave the file on
                            // disk so the next tick can pick it up
                            // (rather than dropping a legitimate URL
                            // that lost a race with a flood).
                            if urlsProcessedThisTick >= maxURLsPerTick {
                                continue
                            }
                            urlsProcessedThisTick += 1
                            let size = (try? entry.resourceValues(
                                forKeys: [.fileSizeKey]).fileSize) ?? 0
                            let raw: String
                            if size > 0, size <= maxURLFileSize,
                               let body = try? String(contentsOf: entry, encoding: .utf8) {
                                raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else {
                                // Empty / oversize / unreadable —
                                // consume + drop so it can't recur.
                                raw = ""
                            }
                            try? fm.removeItem(at: entry)
                            // mailto: is intentionally NOT here.
                            // Historically Mail.app / Outlook /
                            // Thunderbird have leaked local file paths
                            // via mailto:?attach= parameters
                            // (CVE-2020-9922 and friends). CLIs that
                            // call xdg-open / $BROWSER for login are
                            // always http(s); we don't lose anything
                            // real by dropping it.
                            guard let url = URL(string: raw),
                                  let scheme = url.scheme?.lowercased(),
                                  ["http", "https"].contains(scheme) else {
                                continue
                            }
                            self?.onURLOpen?(url)
                            continue
                        }
                        // tabs.txt — the tmux window list, one line per tab:
                        // "<index>\t<active 0|1>\t<foreground command>\t<@container>".
                        // The 4th column is empty unless the window is a docker
                        // attach tab. Constantly rewritten atomically; don't
                        // delete. tmux is the source of truth, so the host
                        // mirrors it directly (no liveness guessing).
                        if name == "tabs.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var tabs: [(index: Int, active: Bool, label: String, containerID: String?)] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                                guard cols.count >= 3, let idx = Int(cols[0]) else { continue }
                                let cid = cols.count >= 4
                                    ? String(cols[3]).trimmingCharacters(in: .whitespaces) : ""
                                tabs.append((index: idx, active: cols[1] == "1",
                                             label: String(cols[2]).trimmingCharacters(in: .whitespaces),
                                             containerID: cid.isEmpty ? nil : cid))
                            }
                            tabs.sort { $0.index < $1.index }
                            self?.onTabList?(tabs)
                            continue
                        }
                        // docker.txt — `docker ps -a --format '{{json .}}'`, one
                        // JSON object per line (running + stopped). Rewritten
                        // atomically every ~2s; empty when there's no docker.
                        if name == "docker.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var containers: [DockerContainer] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                guard let data = line.data(using: .utf8),
                                      let ps = try? JSONDecoder().decode(DockerPSJSON.self, from: data)
                                else { continue }
                                containers.append(DockerContainer(
                                    id: ps.ID, name: ps.Names, image: ps.Image,
                                    status: ps.Status, state: ps.State.lowercased(),
                                    ports: ps.Ports ?? "", runningFor: ps.RunningFor ?? ""))
                            }
                            self?.onDockerList?(containers)
                            continue
                        }
                        // docker-stats.txt — `docker stats --no-stream` NDJSON;
                        // dashboard-only (gated by the .docker-watch marker).
                        if name == "docker-stats.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var stats: [(id: String, cpu: String, mem: String)] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                guard let data = line.data(using: .utf8),
                                      let s = try? JSONDecoder().decode(DockerStatsJSON.self, from: data)
                                else { continue }
                                stats.append((id: s.ID, cpu: s.CPUPerc ?? "", mem: s.MemUsage ?? ""))
                            }
                            self?.onDockerStats?(stats)
                            continue
                        }
                        // vmstat.txt — VM vitals (key value per line) for the
                        // workspace dashboard: cpu / mem_used_kb / mem_total_kb / load.
                        if name == "vmstat.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var cpu = 0.0, used = 0, total = 0, load = 0.0
                            for line in raw.split(whereSeparator: \.isNewline) {
                                let p = line.split(separator: " ")
                                guard p.count == 2 else { continue }
                                let v = String(p[1])
                                switch p[0] {
                                case "cpu":          cpu = Double(v) ?? 0
                                case "mem_used_kb":  used = Int(v) ?? 0
                                case "mem_total_kb": total = Int(v) ?? 0
                                case "load":         load = Double(v) ?? 0
                                default: break
                                }
                            }
                            self?.onVMStats?(cpu, used, total, load)
                            continue
                        }
                        // docker-images.txt — `docker images` NDJSON; dashboard-only.
                        if name == "docker-images.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var images: [DockerImage] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                guard let data = line.data(using: .utf8),
                                      let im = try? JSONDecoder().decode(DockerImageJSON.self, from: data)
                                else { continue }
                                images.append(DockerImage(
                                    id: im.ID, repository: im.Repository, tag: im.Tag,
                                    size: im.Size ?? "", created: im.CreatedSince ?? ""))
                            }
                            self?.onDockerImages?(images)
                            continue
                        }
                        // docker-binfmt.txt — space-separated qemu arch suffixes
                        // currently emulated; may be empty (probed, none).
                        if name == "docker-binfmt.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            let arches = raw.split(whereSeparator: { $0 == " " || $0.isNewline })
                                .map(String.init)
                            self?.onDockerBinfmt?(arches)
                            continue
                        }
                        // docker-arch.txt — "id<TAB>arch" per running container.
                        if name == "docker-arch.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var out: [(id: String, arch: String)] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                                guard cols.count >= 2 else { continue }
                                out.append((id: String(cols[0]).trimmingCharacters(in: .whitespaces),
                                            arch: String(cols[1]).trimmingCharacters(in: .whitespaces)))
                            }
                            self?.onDockerArch?(out)
                            continue
                        }
                        // docker-run-status.txt — "state\timage\tdone\ttotal" while
                        // a detached run pulls/starts; empty when idle.
                        if name == "docker-run-status.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            let cols = raw.split(separator: "\t", omittingEmptySubsequences: false)
                            if cols.count >= 4, !cols[0].isEmpty {
                                self?.onDockerRunStatus?((
                                    state: String(cols[0]), image: String(cols[1]),
                                    done: Int(cols[2]) ?? 0, total: Int(cols[3]) ?? 0))
                            } else {
                                self?.onDockerRunStatus?((state: "", image: "", done: 0, total: 0))
                            }
                            continue
                        }
                        // docker-error.txt — one-shot: a failed docker action's
                        // stderr. Read, delete, surface. (Deleting makes it fire
                        // once rather than every 40ms poll.)
                        if name == "docker-error.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8))?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            try? fm.removeItem(at: entry)
                            if !raw.isEmpty { self?.onDockerError?(raw) }
                            continue
                        }
                        // shortcut-<key>.txt is handled by the fast path at the
                        // top of the loop; it never reaches this scan.
                        //
                        // cmd-*.txt — host-written, consumed by the in-VM
                        // tab agent. Leave alone.
                    }
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
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
        if let port = switchPort {
            VMNetSwitch.shared.detachPort(port)
            switchPort = nil
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

