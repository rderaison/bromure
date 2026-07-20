import Foundation
import SandboxEngine
@preconcurrency import Virtualization

/// One tmux window as the guest roster reports it. `label` is the resolved
/// foreground program (claude/codex/shell — drives the icon + thinking dots);
/// `display` overrides the shown text for worktree tabs. The worktree fields
/// are set for windows created via `worktree-create` and describe where the
/// checkout lives and where it can merge to; an attached terminal
/// (`worktree-terminal`) carries only `parentBranch`/`rootRepo`, which nests
/// it under its worktree without making it a worktree itself.
public struct GuestTab: Sendable {
    public var index: Int
    public var active: Bool
    public var label: String
    public var containerID: String?
    /// The tab's working directory (tmux `pane_current_path`).
    public var cwd: String?
    /// This worktree's branch (`wt/<slug>`), if the window is a worktree.
    public var worktreeBranch: String?
    /// The branch the worktree was cut from — the immediate merge parent.
    public var parentBranch: String?
    /// The main (primary) worktree's path — where merges/removes run.
    public var rootRepo: String?
    /// Pretty label ("Website refactoring") shown instead of `label`.
    public var display: String?
    /// The cwd's git toplevel, if it's inside a repo (gates "New worktree"
    /// and roots the file-explorer pane). Empty for non-repo cwds. For a
    /// worktree tab this is the worktree checkout dir.
    public var repoRoot: String?

    public var isWorktree: Bool { !(worktreeBranch?.isEmpty ?? true) }
    /// A tab sitting inside a git repo (worktree checkouts included) →
    /// eligible to spawn a (nested) worktree; roots the file pane.
    public var isGitRepo: Bool { !(repoRoot?.isEmpty ?? true) }
}

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
    let Mounts: String?
    private let StateRaw: String?
    var State: String { StateRaw ?? (Status.hasPrefix("Up") ? "running" : "exited") }
    enum CodingKeys: String, CodingKey { case ID, Names, Image, Status, Ports, RunningFor, Mounts, StateRaw = "State" }
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

/// One line of the guest's docker-volumes.txt — `docker volume inspect` fields
/// plus the Size the agent merges in from its `docker system df -v` probe.
private struct DockerVolumeJSON: Decodable {
    let Name: String
    let Driver: String?
    let Mountpoint: String?
    let CreatedAt: String?
    let Size: String?
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

    /// Called every ~0.7s with the current tmux window list. tmux is the source
    /// of truth, so the host mirrors this directly as the tab bar; there's no
    /// per-process liveness reconciliation.
    public var onTabList: (([GuestTab]) -> Void)?

    /// Called ~every 2s with the guest's container list (from `docker ps -a`,
    /// running + stopped). Empty when docker is absent / the daemon is down.
    /// Drives the "Docker" sub-tree and the dashboard.
    public var onDockerList: (([DockerContainer]) -> Void)?

    /// Called ~every 2s WHILE a dashboard is open with per-container CPU/mem
    /// (from `docker stats --no-stream`). Keyed by full container id.
    public var onDockerStats: (([(id: String, cpu: String, mem: String)]) -> Void)?

    /// VM vitals for the workspace dashboard (~every 1.5s): aggregate CPU%,
    /// memory used/total (KB), 1-minute load average, and the root FS's
    /// used/total (KB) as the GUEST sees them (df) — the host-side CoW clone
    /// allocation overstates real usage. 0/0 from an older guest agent.
    public var onVMStats: ((_ cpu: Double, _ memUsedKB: Int, _ memTotalKB: Int, _ load: Double,
                            _ diskUsedKB: Int, _ diskTotalKB: Int) -> Void)?

    /// Called ~every 2s WHILE a dashboard is open with the local image list
    /// (from `docker images`).
    public var onDockerImages: (([DockerImage]) -> Void)?

    /// Called ~every 2s WHILE a dashboard is open with the named volume list
    /// (from `docker volume inspect`, sizes from a slower `system df` probe).
    public var onDockerVolumes: (([DockerVolume]) -> Void)?

    /// Called when a docker action (run / start / stop / remove) fails in the
    /// guest — carries docker's stderr. One-shot: the file is consumed on read.
    public var onDockerError: ((String) -> Void)?

    /// Called when a git worktree action (create / merge / remove) fails in the
    /// guest — carries git's stderr. One-shot: the file is consumed on read.
    public var onWorktreeError: ((String) -> Void)?

    /// Per-tab coding-agent status from the guest (Claude hooks). `(windowIndex,
    /// signal)` where signal ∈ "working"/"done"/"needsInput". One-shot per file.
    public var onAgentStatus: ((Int, String) -> Void)?

    /// Called (dashboard-only) with the qemu arch suffixes registered+enabled in
    /// binfmt_misc (e.g. ["x86_64","arm"]). Empty = emulation not installed.
    public var onDockerBinfmt: (([String]) -> Void)?

    /// Called (dashboard-only) with each running container's architecture
    /// (id, arch e.g. "amd64"/"arm64"/"arm/v7").
    public var onDockerArch: (([(id: String, arch: String)]) -> Void)?

    /// Called with the current "run job" progress while a detached `docker run`
    /// is pulling/starting — (state, image, done, total). state is "" when idle.
    public var onDockerRunStatus: (((state: String, image: String, done: Int, total: Int)) -> Void)?

    /// Fired when the guest signals it's going down for a *reboot* (the guest
    /// writes a `reboot-intent` marker before halting). Lets the host relaunch
    /// the VM in place instead of tearing the session down — a guest `reboot`
    /// then behaves like the app's Reboot rather than a shutdown.
    public var onGuestReboot: (() -> Void)?

    /// Home-storage upgrade progress from the guest agent (migrate boots
    /// only): (phase, copiedBytes, totalBytes). totalBytes is 0 until the
    /// guest's size scan finishes. Feeds the boot-overlay status line.
    public var onHomeMigrationProgress: ((String, Int64, Int64) -> Void)?

    /// One-shot: the guest agent verified the home copy and mounted the
    /// image over /home/ubuntu. The host stamps the profile `.ext4` so the
    /// next boot stops attaching the old virtiofs home.
    public var onHomeMigrated: (() -> Void)?

    /// Listening sockets published by the guest's ports loop (`ss -tulnH` →
    /// ports.txt, every ~3s). Fired only when the set changes. Drives the
    /// workspace dashboard's Ports row and the `/vms` record.
    public var onPortsList: (([ListeningPort]) -> Void)?
    /// Raw ports.txt from the last delivery, to skip re-parsing/re-firing when
    /// nothing changed (the guest rewrites the file even when idle).
    private var lastPortsRaw: String?

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
    /// Per-VM vmnet interface in bridged mode (the uplink for `.bridged`
    /// profiles). Kept alive for the VM's lifetime; torn down alongside the VM.
    private var networkFilter: NetworkFilter?
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
        networkFilter?.stop()
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

        // ext4 home model: the persistent /home/ubuntu is a sparse raw
        // image attached as a SECOND virtio-blk device (stable inodes
        // across suspend/restore; fstrim punches freed blocks back out of
        // the host file). The guest agent formats it when blank, mounts it
        // over /home/ubuntu and applies the home seed — no fstab change
        // needed, so existing base images work as-is. Attached for both
        // .ext4 and .migrate boots (a migrate boot copies the virtiofs
        // home into it first).
        if let session = sessionDisk, session.homeAttachMode != .virtiofs {
            try session.ensureHomeImageExists()
            let homeAttachment = try VZDiskImageStorageDeviceAttachment(
                url: session.homeImageURL, readOnly: false)
            config.storageDevices.append(
                VZVirtioBlockDeviceConfiguration(attachment: homeAttachment))
        }

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
            // Bridge via vmnet's bridged mode (kVmnetBridgedMode), which is
            // authorized by `com.apple.developer.networking.vmnet` — the
            // entitlement we already ship — rather than
            // `VZBridgedNetworkDeviceAttachment`, which demands the *restricted*
            // `com.apple.vm.networking`. This is exactly how Bromure Web bridges
            // (NetworkFilter → VZFileHandleNetworkDeviceAttachment). Enumerating
            // interfaces via VZBridgedNetworkInterface is read-only and needs no
            // special entitlement; only the VZ attachment did.
            let bridgedID = sessionDisk?.profile.bridgedInterfaceID
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            let iface = interfaces.first(where: { $0.identifier == bridgedID }) ?? interfaces.first
            if let ifName = iface?.identifier,
               let netInfo = HostNetworkInfo.detect(),
               let filter = NetworkFilter(networkInfo: netInfo, bridgedInterface: ifName) {
                net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: filter.vmFileHandle)
                self.networkFilter = filter
            } else {
                FileHandle.standardError.write(Data(
                    "[run] bridged networking unavailable, falling back to NAT\n".utf8))
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

        // No graphics or USB input devices: the terminal renders host-side
        // (libghostty over the vsock pty pump) and keystrokes travel as
        // bytes, not HID events. X11/kitty stay on the image's disk but
        // nothing starts them (plan phase 3).

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

        // (SPICE clipboard console removed with the framebuffer: clipboard
        // now flows through the terminal surfaces — OSC 52 out of tmux,
        // bracketed paste in.)

        // Virtiofs shares: project (user's folder) + bromure-meta (env, ssh).
        // Both tags are referenced by /etc/fstab in the base image so they
        // mount at boot. We always attach the meta share. The project share
        // is attached only when the profile names a folder — fstab uses
        // `nofail` so a missing project tag won't block boot.
        var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        if let session = sessionDisk {
            // The `bromure-home` virtiofs tag — every base image's fstab
            // mounts it at /home/ubuntu (nofail). What it carries depends
            // on the home model:
            // - .virtiofs (legacy): the full persistent host-side home.
            // - .migrate: same — this boot's guest agent copies it into
            //   the blank home image, then mounts the image on top.
            // - .ext4: a tiny bootstrap dir holding just the managed
            //   .bash_profile. tty1's autologin shell sources it, which
            //   installs/starts the guest agent even on a freshly-cloned
            //   system disk (Reset Disk); the agent then mounts the ext4
            //   image OVER /home/ubuntu, shadowing this share entirely.
            let homeShareURL: URL
            switch session.homeAttachMode {
            case .virtiofs, .migrate:
                homeShareURL = session.homeDirectory
            case .ext4:
                try session.prepareBootstrapHomeDirectory()
                homeShareURL = session.bootstrapHomeDirectory
            }
            let homeFS = VZVirtioFileSystemDeviceConfiguration(tag: "bromure-home")
            homeFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: homeShareURL, readOnly: false)
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

    /// Parse a tabs.txt body into the tmux window list. Columns: idx, active,
    /// label, container, cwd, worktree, parent_branch, root_repo, display,
    /// repoRoot. Older guests send only the first 4 — trailing fields default
    /// to nil, so a stale image degrades to plain tabs instead of misparsing.
    static func parseRoster(_ raw: String) -> [GuestTab] {
        var tabs: [GuestTab] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let idx = Int(cols[0]) else { continue }
            func col(_ i: Int) -> String? {
                guard cols.count > i else { return nil }
                let s = String(cols[i]).trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            tabs.append(GuestTab(
                index: idx, active: cols[1] == "1",
                label: String(cols[2]).trimmingCharacters(in: .whitespaces),
                containerID: col(3),
                cwd: col(4), worktreeBranch: col(5),
                parentBranch: col(6), rootRepo: col(7),
                display: col(8), repoRoot: col(9)))
        }
        tabs.sort { $0.index < $1.index }
        return tabs
    }

    /// Watches the outbox share for files dropped by the guest's
    /// `bromure-open` script and forwards each one to `onURLOpen`.
    private func startOutboxPolling() {
        guard let outbox = sessionDisk?.outboxDirectory else { return }
        outboxPollTask?.cancel()
        outboxPollTask = Task { @MainActor [weak self] in
            let fm = FileManager.default
            // Roster mtime seen last, so the fast tick can re-parse tabs.txt
            // only when it actually changed (a new/closed tab shows up in
            // ~one fast tick instead of waiting for the ~480ms heavy scan).
            var lastTabsMTime: Date?
            // One task, two cadences. The reboot-intent marker is drained
            // every tick (~40ms); everything else in the outbox (ip / url
            // relay / titles / roster) is latency-tolerant and stays on the
            // ~480ms cadence via the tick gate below.
            var ticks = 0
            while !Task.isCancelled {
                // FAST PATH — reboot-intent: the guest is going down for a
                // reboot (systemd reboot.target), not a user-closed session.
                // Drained on the fast tick so the host flags the reboot BEFORE
                // the slow-path roster scan publishes the empty tabs.txt that
                // would otherwise trigger the close-action shutdown.
                let rebootMarker = outbox.appendingPathComponent("reboot-intent")
                if fm.fileExists(atPath: rebootMarker.path) {
                    try? fm.removeItem(at: rebootMarker)
                    self?.onGuestReboot?()
                }

                // FAST PATH — roster. Tab open/close/switch is felt directly
                // (the pill appears / the grid cell mounts), so read tabs.txt
                // on the fast tick, but only re-parse when its mtime changed —
                // the guest publishes it immediately after any tab command, so
                // this picks the change up in ~one 40ms tick instead of up to
                // the ~480ms heavy cadence.
                let tabsFile = outbox.appendingPathComponent("tabs.txt")
                if let mtime = try? fm.attributesOfItem(atPath: tabsFile.path)[.modificationDate] as? Date,
                   mtime != lastTabsMTime {
                    lastTabsMTime = mtime
                    let raw = (try? String(contentsOf: tabsFile, encoding: .utf8)) ?? ""
                    self?.onTabList?(Self.parseRoster(raw))
                }

                // Throttle the heavier scan to ~every 12th tick (~480ms) so
                // titles / url relay keep their original cadence.
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
                        // tabs.txt is read on the fast tick above (mtime-gated),
                        // not here — skip it in the heavy scan.
                        if name == "tabs.txt" { continue }
                        // home-migrate.txt — live progress of the home-storage
                        // upgrade copy ("<phase> <copied> <total>"), rewritten
                        // by the guest agent ~2×/s. Read, never consumed.
                        if name == "home-migrate.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            let p = raw.split(whereSeparator: { $0 == " " || $0.isNewline })
                            if p.count >= 3, let done = Int64(p[1]), let total = Int64(p[2]) {
                                self?.onHomeMigrationProgress?(String(p[0]), done, total)
                            }
                            continue
                        }
                        // home-migrated.txt — one-shot completion marker: the
                        // copy is verified and the image is mounted over
                        // /home/ubuntu. Consumed; host stamps homeModel=.ext4.
                        if name == "home-migrated.txt" {
                            try? fm.removeItem(at: entry)
                            self?.onHomeMigrated?()
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
                                    ports: ps.Ports ?? "", runningFor: ps.RunningFor ?? "",
                                    mounts: ps.Mounts ?? ""))
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
                        // workspace dashboard: cpu / mem_used_kb / mem_total_kb /
                        // load / disk_used_kb / disk_total_kb (guest root FS, df).
                        if name == "vmstat.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var cpu = 0.0, used = 0, total = 0, load = 0.0
                            var diskUsed = 0, diskTotal = 0
                            for line in raw.split(whereSeparator: \.isNewline) {
                                let p = line.split(separator: " ")
                                guard p.count == 2 else { continue }
                                let v = String(p[1])
                                switch p[0] {
                                case "cpu":           cpu = Double(v) ?? 0
                                case "mem_used_kb":   used = Int(v) ?? 0
                                case "mem_total_kb":  total = Int(v) ?? 0
                                case "load":          load = Double(v) ?? 0
                                case "disk_used_kb":  diskUsed = Int(v) ?? 0
                                case "disk_total_kb": diskTotal = Int(v) ?? 0
                                default: break
                                }
                            }
                            self?.onVMStats?(cpu, used, total, load, diskUsed, diskTotal)
                            continue
                        }
                        // ports.txt — raw `ss -tulnH` lines from the guest's
                        // ports loop (~3s cadence). Parse → dashboard/API; only
                        // fire when the content actually changed.
                        if name == "ports.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            if raw != self?.lastPortsRaw {
                                self?.lastPortsRaw = raw
                                self?.onPortsList?(Self.parseListeningPorts(raw))
                            }
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
                        // docker-volumes.txt — `docker volume inspect` NDJSON
                        // (+ merged Size); dashboard-only.
                        if name == "docker-volumes.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                            var volumes: [DockerVolume] = []
                            for line in raw.split(whereSeparator: \.isNewline) {
                                guard let data = line.data(using: .utf8),
                                      let vol = try? JSONDecoder().decode(DockerVolumeJSON.self, from: data)
                                else { continue }
                                volumes.append(DockerVolume(
                                    name: vol.Name, driver: vol.Driver ?? "",
                                    mountpoint: vol.Mountpoint ?? "",
                                    createdAt: vol.CreatedAt ?? "", size: vol.Size ?? ""))
                            }
                            self?.onDockerVolumes?(volumes)
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
                        // worktree-error.txt — one-shot, same pattern: a failed
                        // git worktree create/merge/remove surfaced to the host.
                        if name == "worktree-error.txt" {
                            let raw = (try? String(contentsOf: entry, encoding: .utf8))?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            try? fm.removeItem(at: entry)
                            if !raw.isEmpty { self?.onWorktreeError?(raw) }
                            continue
                        }
                        // agent-status-<windowIndex>.txt — one-shot: a Claude
                        // hook reporting working/done/needsInput for that tab's
                        // status dot. Per-window filename so two tabs signalling
                        // at once don't clobber each other.
                        if name.hasPrefix("agent-status-"), name.hasSuffix(".txt") {
                            let idxStr = name.dropFirst("agent-status-".count).dropLast(".txt".count)
                            let raw = (try? String(contentsOf: entry, encoding: .utf8))?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            try? fm.removeItem(at: entry)
                            if let idx = Int(idxStr), !raw.isEmpty { self?.onAgentStatus?(idx, raw) }
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

    /// Parse `ss -tuln` output (one socket per line: netid, state, queues,
    /// local, peer, and — under sudo `-p` — the users:(("name",pid,fd))
    /// process column) into listening ports. Header-tolerant and
    /// column-count-tolerant so the same parser serves the guest's ports loop
    /// and the CLI's on-demand query. De-dupes identical entries.
    nonisolated static func parseListeningPorts(_ raw: String) -> [ListeningPort] {
        var out: [ListeningPort] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5 else { continue }
            let proto = String(f[0])
            guard proto == "tcp" || proto == "udp" else { continue }   // skips headers
            guard let (addr, port) = splitLocalAddress(f[4]) else { continue }
            // Distinct process names from the users:(…) column, when present —
            // e.g. users:(("nginx",pid=91,fd=6),("nginx",pid=92,fd=6)) → nginx.
            var names: [String] = []
            if let usersRange = line.range(of: "users:") {
                var rest = line[usersRange.upperBound...]
                while let open = rest.firstIndex(of: "\"") {
                    let after = rest.index(after: open)
                    guard let close = rest[after...].firstIndex(of: "\"") else { break }
                    let name = String(rest[after..<close])
                    if !names.contains(name) { names.append(name) }
                    rest = rest[rest.index(after: close)...]
                }
            }
            let p = ListeningPort(proto: proto, addr: addr, port: port,
                                  process: names.joined(separator: ", "))
            if !out.contains(p) { out.append(p) }
        }
        return out.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    /// "0.0.0.0:22" / "[::]:80" / "127.0.0.53%lo:53" / "*:8080" → (addr, port).
    /// Strips the %scope/iface suffix; normalizes `*` to 0.0.0.0.
    nonisolated static func splitLocalAddress(_ s: Substring) -> (addr: String, port: Int)? {
        guard let colon = s.lastIndex(of: ":"),
              let port = Int(s[s.index(after: colon)...]) else { return nil }
        var addr = String(s[..<colon])
            .replacingOccurrences(of: #"%[^\]]*"#, with: "", options: .regularExpression)
        if addr == "*" { addr = "0.0.0.0" }
        return (addr, port)
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
        networkFilter?.stop()
        networkFilter = nil
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

