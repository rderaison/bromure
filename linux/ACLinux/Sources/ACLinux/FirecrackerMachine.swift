import Foundation

/// What the daemon needs of a VM backend: QEMUMachine, FirecrackerMachine.
// @port-skip linux-only: Linux VM backends (macOS: VZVirtualMachine)
public protocol VMMachine: Actor {
    var pid: Int32? { get }
    func setOnStopped(_ handler: @escaping @Sendable (QEMUMachine.StopInfo) -> Void)
    func start() async throws
    @discardableResult func stop(timeout: Duration) async -> QEMUMachine.StopInfo
    @discardableResult func kill() async -> QEMUMachine.StopInfo
    func waitUntilStopped() async -> QEMUMachine.StopInfo
    @discardableResult func suspend(to statePath: String) async throws -> QEMUMachine.SuspendTimings
    @discardableResult func restore(from statePath: String) async throws -> QEMUMachine.RestoreTimings
}

// @port-skip linux-only: Linux VM backends
extension QEMUMachine: VMMachine {}

/// One Firecracker VM: the firecracker process, a virtiofsd per share, and
/// its API socket. The same config as QEMU's (`machine == .firecracker`),
/// rendered into Firecracker's JSON by `firecrackerConfig()`:
/// - the system disk is a raw copy of the base image (`overlay`, made
///   sparse on first start: Firecracker has no qcow2);
/// - the network is the VM's end of a DgramPort socketpair, inherited as
///   descriptor 3 (`host_dev_name: "fd:3"`);
/// - vsock is hybrid: guest connections to host port P arrive on the Unix
///   socket `<runDirectory>/v.sock_P` (HybridVsockListener);
/// - stop is Ctrl-Alt-Del (the guest reboots; `reboot=k` makes Firecracker
///   exit), then SIGKILL.
/// virtiofsd must be listening before Firecracker loads the config: the
/// vhost-user-fs device connects to it while the config is applied, so
/// `start()` brings every share's virtiofsd up and waits for its socket
/// first, and a virtiofsd that dies before then fails the start cleanly
/// (`virtiofsdNotReady`, or Firecracker's own exit with its log).
/// No suspend/restore: Firecracker refuses to snapshot a VM with
/// vhost-user-fs devices.
// @port-skip linux-only: Firecracker backend (macOS: UbuntuSandboxVM on Virtualization.framework)
public actor FirecrackerMachine: VMMachine {
    public nonisolated let config: QEMUMachineConfig
    public nonisolated let api: FirecrackerAPI
    public private(set) var state: QEMUMachine.State = .idle
    private var onStopped: (@Sendable (QEMUMachine.StopInfo) -> Void)?
    private var process: ChildProcess?
    private var daemons: [(tag: String, process: ChildProcess)] = []
    private var pendingReason: QEMUMachine.StopReason?
    private var stopWaiters: [CheckedContinuation<QEMUMachine.StopInfo, Never>] = []

    // @port-skip linux-only: Firecracker backend
    public init(config: QEMUMachineConfig) {
        self.config = config
        self.api = FirecrackerAPI(socketPath: config.firecrackerAPISocketPath)
    }

    /// Takes over a Firecracker a previous daemon started (`pid`, running
    /// `config`): checks its API answers and watches the process. Its
    /// virtiofsds are not supervised (they exit when it does).
    // @port-skip linux-only: Firecracker backend (daemon restart)
    public static func adopt(config: QEMUMachineConfig, pid: Int32) async throws -> FirecrackerMachine {
        let m = FirecrackerMachine(config: config)
        try await m.attach(pid: pid)
        return m
    }

    // @port-skip linux-only: Firecracker backend
    private func attach(pid: Int32) async throws {
        guard state == .idle else { throw MachineError.alreadyStarted }
        let p = try ChildProcess.adopt(name: "firecracker", pid: pid)
        _ = try await api.instanceState()
        process = p
        state = .running
        Task { [weak self] in
            let status = await p.waitForExit()
            await self?.exited(status)
        }
    }

    // @port-skip linux-only: Firecracker backend
    public func setOnStopped(_ handler: @escaping @Sendable (QEMUMachine.StopInfo) -> Void) {
        onStopped = handler
    }

    // @port-skip linux-only: Firecracker backend
    public var pid: Int32? { process?.pid }

    /// Makes the system disk if needed, starts the virtiofsds, then
    /// Firecracker, and returns once its API reports the VM running. Owns
    /// the network peer descriptor (`.datagram(peerFD:)`): closed here once
    /// Firecracker has its copy, or on failure.
    // @port-skip linux-only: Firecracker backend
    public func start() async throws {
        guard state == .idle else { throw MachineError.alreadyStarted }
        var peerFD: Int32 = -1
        if case .datagram(let fd) = config.network { peerFD = fd }
        defer { if peerFD >= 0 { close(peerFD) } }
        try config.validate()
        state = .starting
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: config.runDirectory, withIntermediateDirectories: true)
            if !config.writeBaseInPlace, !fm.fileExists(atPath: config.overlay) {
                // A sparse copy: ~1 s for the 3.7 GB the base holds.
                let tmp = config.overlay + ".tmp"
                try? fm.removeItem(atPath: tmp)
                try await ChildProcess.run("/usr/bin/cp", ["--sparse=always", "--reflink=auto", config.baseImage, tmp])
                guard rename(tmp, config.overlay) == 0 else { throw MachineError.io("rename \(tmp)", errno) }
            }
            try await startDaemons()
            for p in [config.firecrackerAPISocketPath, config.firecrackerVsockPath] { try? fm.removeItem(atPath: p) }
            let json = try JSONEncoder().encode(config.firecrackerConfig(netFD: peerFD >= 0 ? 3 : nil))
            let cfgPath = (config.runDirectory as NSString).appendingPathComponent("firecracker.json")
            try json.write(to: URL(fileURLWithPath: cfgPath))
            let log = (config.runDirectory as NSString).appendingPathComponent("firecracker.log")
            try? fm.removeItem(atPath: log)
            // stdout is the guest's serial console.
            let p = try ChildProcess(name: "firecracker", executable: config.firecrackerBinary,
                                     arguments: ["--id", config.name, "--api-sock", config.firecrackerAPISocketPath,
                                                 "--config-file", cfgPath, "--log-path", log, "--level", "Warning"],
                                     logPath: config.serialLog, inheritedFDs: peerFD >= 0 ? [peerFD] : [])
            try p.start()
            process = p
            Task { [weak self] in
                let status = await p.waitForExit()
                await self?.exited(status)
            }
            try await waitRunning(p, log: log)
            state = .running
        } catch {
            if let p = process, p.isRunning { p.signal(SIGKILL); _ = await p.waitForExit() }
            stopDaemons()
            if state == .starting { state = .idle }
            throw error
        }
    }

    // @port-skip linux-only: Firecracker backend
    private func waitRunning(_ p: ChildProcess, log: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if let status = p.exitStatus {
                let out = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                throw MachineError.exitedDuringStart(status, String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)))
            }
            if FileManager.default.fileExists(atPath: config.firecrackerAPISocketPath),
               (try? await api.instanceState()) == "Running" { return }
            if ContinuousClock.now > deadline { throw MachineError.io("firecracker API \(config.firecrackerAPISocketPath)", ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Ctrl-Alt-Del, SIGKILL after `timeout`.
    // @port-skip linux-only: Firecracker backend
    @discardableResult
    public func stop(timeout: Duration = .seconds(30)) async -> QEMUMachine.StopInfo {
        if case .stopped(let info) = state { return info }
        guard let process else { return finishIdle(.stopped) }
        state = .stopping
        pendingReason = pendingReason ?? .stopped
        try? await api.action("SendCtrlAltDel")
        if await process.waitForExit(timeout: timeout) == nil { process.signal(SIGKILL) }
        return await waitUntilStopped()
    }

    // @port-skip linux-only: Firecracker backend
    @discardableResult
    public func kill() async -> QEMUMachine.StopInfo {
        if case .stopped(let info) = state { return info }
        guard let process else { return finishIdle(.killed) }
        pendingReason = .killed
        process.signal(SIGKILL)
        return await waitUntilStopped()
    }

    // @port-skip linux-only: Firecracker backend
    public func waitUntilStopped() async -> QEMUMachine.StopInfo {
        if case .stopped(let info) = state { return info }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    // @port-skip linux-only: Firecracker backend
    public func suspend(to statePath: String) async throws -> QEMUMachine.SuspendTimings {
        throw MachineError.invalidConfig("suspend is not available for Firecracker VMs (vhost-user-fs has no snapshot)")
    }

    // @port-skip linux-only: Firecracker backend
    public func restore(from statePath: String) async throws -> QEMUMachine.RestoreTimings {
        throw MachineError.invalidConfig("restore is not available for Firecracker VMs (vhost-user-fs has no snapshot)")
    }

    // MARK: virtiofsd (as QEMUMachine's)

    // @port-skip linux-only: virtiofsd supervision
    private func startDaemons() async throws {
        for (i, share) in config.shares.enumerated() {
            let sock = config.shareSocketPath(i)
            try? FileManager.default.removeItem(atPath: sock)
            let log = (config.runDirectory as NSString).appendingPathComponent("virtiofsd-\(share.tag).log")
            let d = try ChildProcess(name: "virtiofsd[\(share.tag)]", executable: config.virtiofsd,
                                     arguments: config.virtiofsdArguments(i), logPath: log)
            try d.start()
            daemons.append((share.tag, d))
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: sock) {
                if !d.isRunning || ContinuousClock.now > deadline { throw MachineError.virtiofsdNotReady(share.tag) }
                try await Task.sleep(for: .milliseconds(5))
            }
            let tag = share.tag
            Task { [weak self] in
                _ = await d.waitForExit()
                await self?.daemonExited(tag)
            }
        }
    }

    // @port-skip linux-only: virtiofsd supervision
    private func daemonExited(_ tag: String) {
        // The guest lost a filesystem it can't get back (no vhost-user
        // reconnect): take the VM down, as QEMUMachine does.
        guard state == .running || state == .starting, pendingReason == nil, let process else { return }
        pendingReason = .virtiofsdExited(tag: tag)
        process.signal(SIGKILL)
    }

    // @port-skip linux-only: virtiofsd supervision
    private func stopDaemons() {
        for d in daemons { d.process.signal(SIGTERM) }
        daemons = []
    }

    // MARK: exit

    // @port-skip linux-only: Firecracker backend
    private func exited(_ status: Int32) {
        stopDaemons()
        // Firecracker exits 0 when the guest reboots or powers off.
        let reason = pendingReason ?? (status == 0 ? .guestShutdown : .crashed)
        finish(QEMUMachine.StopInfo(reason: reason, exitStatus: status))
    }

    // @port-skip linux-only: Firecracker backend
    private func finishIdle(_ reason: QEMUMachine.StopReason) -> QEMUMachine.StopInfo {
        let info = QEMUMachine.StopInfo(reason: reason, exitStatus: 0)
        finish(info)
        return info
    }

    // @port-skip linux-only: Firecracker backend
    private func finish(_ info: QEMUMachine.StopInfo) {
        if case .stopped = state { return }
        state = .stopped(info)
        for w in stopWaiters { w.resume(returning: info) }
        stopWaiters = []
        onStopped?(info)
    }
}

// @port-skip linux-only: Firecracker backend
extension QEMUMachineConfig {
    // @port-skip linux-only: Firecracker backend
    public var firecrackerAPISocketPath: String { (runDirectory as NSString).appendingPathComponent("fc.sock") }
    /// Hybrid vsock's base path: Firecracker listens on it for host-initiated
    /// connections, and dials `<it>_<port>` for the guest's.
    // @port-skip linux-only: Firecracker backend
    public var firecrackerVsockPath: String { (runDirectory as NSString).appendingPathComponent("v.sock") }

    /// Firecracker's `--config-file` JSON. `netFD`: the descriptor number
    /// the network socket has in the firecracker process.
    // @port-skip linux-only: Firecracker backend
    public func firecrackerConfig(netFD: Int32?) -> JSONValue {
        // reboot=k: a guest reboot (Ctrl-Alt-Del) ends Firecracker. Firecracker
        // adds pci=off and the virtio-mmio devices itself.
        var o: [String: JSONValue] = [
            "boot-source": .object([
                "kernel_image_path": .string(kernel),
                "boot_args": .string(cmdline + " reboot=k panic=1"),
            ].merging(initrd.map { ["initrd_path": .string($0)] } ?? [:]) { a, _ in a }),
            "machine-config": ["vcpu_count": .number(Double(cpus)), "mem_size_mib": .number(Double(memoryMiB))],
        ]
        var drives: [JSONValue] = [[
            "drive_id": "root", "path_on_host": .string(writeBaseInPlace ? baseImage : overlay),
            "is_root_device": false, "is_read_only": false,
        ]]
        for (i, d) in extraDisks.enumerated() {
            drives.append(["drive_id": .string("disk\(i + 1)"), "path_on_host": .string(d.path),
                           "is_root_device": false, "is_read_only": false])
        }
        o["drives"] = .array(drives)
        if !shares.isEmpty {
            o["fs"] = .array(shares.enumerated().map { i, s in
                ["fs_id": .string("fs\(i)"), "tag": .string(s.tag), "socket": .string(shareSocketPath(i))]
            })
        }
        if let netFD {
            var nic: [String: JSONValue] = ["iface_id": "eth0", "host_dev_name": .string("fd:\(netFD)")]
            if let macAddress { nic["guest_mac"] = .string(macAddress) }
            o["network-interfaces"] = .array([.object(nic)])
        }
        if vsock { o["vsock"] = ["guest_cid": .number(Double(vsockCID)), "uds_path": .string(firecrackerVsockPath)] }
        return .object(o)
    }
}
