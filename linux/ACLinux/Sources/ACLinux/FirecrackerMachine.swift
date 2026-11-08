import CACLinuxShims
import Foundation
import SandboxEngine

/// One Firecracker VM: the firecracker process, a virtiofsd per share, and
/// its API socket. MachineConfig, rendered into Firecracker's JSON by
/// `firecrackerConfig(netFD:)`:
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
/// Suspend is a full snapshot (`snapshot(into:)`: the vCPUs paused, each
/// share's virtiofsd handing its state over through the fork's vhost-user-fs
/// device), then the processes end; resume (`config.restoreFrom`) starts
/// fresh virtiofsds and loads the snapshot into a new Firecracker.
// @port-skip linux-only: Firecracker backend (macOS: UbuntuSandboxVM on Virtualization.framework)
public actor FirecrackerMachine {
    // @port-skip linux-only: VM backend
    public enum StopReason: Sendable, Equatable {
        /// The guest rebooted or powered itself off.
        case guestShutdown
        /// `stop()`: Ctrl-Alt-Del, SIGKILL if the guest ignored it.
        case stopped
        case killed
        /// A share's virtiofsd died; the VM was taken down with it.
        case virtiofsdExited(tag: String)
        /// Firecracker exited on its own with a failure.
        case crashed
        /// `snapshot(into:)`: saved, then ended.
        case suspended
    }

    // @port-skip linux-only: VM backend
    public struct StopInfo: Sendable, Equatable {
        public let reason: StopReason
        /// Firecracker's exit status (128 + signal when killed by one; -1 for
        /// an adopted process, whose status isn't ours to read).
        public let exitStatus: Int32
    }

    // @port-skip linux-only: VM backend
    public enum State: Sendable, Equatable {
        case idle, starting, running, stopping, stopped(StopInfo)
    }

    public nonisolated let config: MachineConfig
    public nonisolated let api: FirecrackerAPI
    public private(set) var state: State = .idle
    private var onStopped: (@Sendable (StopInfo) -> Void)?
    private var process: ChildProcess?
    private var daemons: [(tag: String, process: ChildProcess)] = []
    private var pendingReason: StopReason?
    private var stopWaiters: [CheckedContinuation<StopInfo, Never>] = []

    // @port-skip linux-only: Firecracker backend
    public init(config: MachineConfig) {
        self.config = config
        self.api = FirecrackerAPI(socketPath: config.firecrackerAPISocketPath)
    }

    /// Takes over a Firecracker a previous daemon started (`pid`, running
    /// `config`): checks its API answers and watches the process. Its
    /// virtiofsds are not supervised (they exit when it does).
    // @port-skip linux-only: Firecracker backend (daemon restart)
    public static func adopt(config: MachineConfig, pid: Int32) async throws -> FirecrackerMachine {
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
    public func setOnStopped(_ handler: @escaping @Sendable (StopInfo) -> Void) {
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
        let pipes = config.consolePipes
        defer {
            if peerFD >= 0 { close(peerFD) }
            if let pipes { close(pipes.input); close(pipes.output) }
        }
        try config.validate()
        state = .starting
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: config.runDirectory, withIntermediateDirectories: true)
            if !config.writeBaseInPlace, !fm.fileExists(atPath: config.overlay) {
                // The copy grows as the guest writes: a nearly full host would
                // wedge the session mid-run, so it isn't made under the floor
                // (macOS: SessionDisk's disk clone; SandboxError.diskFull).
                try EphemeralDisk.checkDiskSpace(at: (config.overlay as NSString).deletingLastPathComponent)
                // A sparse copy: ~1 s for the 3.7 GB the base holds.
                let tmp = config.overlay + ".tmp"
                try? fm.removeItem(atPath: tmp)
                try await ChildProcess.run("/usr/bin/cp", ["--sparse=always", "--reflink=auto", config.baseImage, tmp])
                // Its own machine-id from the first boot on (the copy has the bake's).
                try await GuestDisk.setMachineID(image: tmp, id: GuestDisk.newMachineID())
                guard rename(tmp, config.overlay) == 0 else { throw MachineError.io("rename \(tmp)", errno) }
            }
            try await startDaemons()
            for p in [config.firecrackerAPISocketPath, config.firecrackerVsockPath] { try? fm.removeItem(atPath: p) }
            let log = (config.runDirectory as NSString).appendingPathComponent("firecracker.log")
            try? fm.removeItem(atPath: log)
            var args = ["--id", config.name, "--api-sock", config.firecrackerAPISocketPath,
                        "--log-path", log, "--level", "Warning"]
            // A resume loads its snapshot through the API once it's up; a
            // boot is configured from the start.
            if config.restoreFrom == nil {
                let json = try JSONEncoder().encode(config.firecrackerConfig(netFD: peerFD >= 0 ? 3 : nil))
                let cfgPath = (config.runDirectory as NSString).appendingPathComponent("firecracker.json")
                try json.write(to: URL(fileURLWithPath: cfgPath))
                args += ["--config-file", cfgPath]
            }
            // stdout is the guest's serial console.
            let p = try ChildProcess(name: "firecracker", executable: config.firecrackerBinary,
                                     arguments: args,
                                     logPath: config.serialLog, standardInput: pipes?.input,
                                     standardOutput: pipes?.output, inheritedFDs: peerFD >= 0 ? [peerFD] : [])
            try p.start()
            process = p
            Task { [weak self] in
                let status = await p.waitForExit()
                await self?.exited(status)
            }
            if let dir = config.restoreFrom { try await loadSnapshot(dir, p, log: log) }
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

    /// What a resume maps as the guest's memory: a copy of `vm.mem` (mapped
    /// shared, the running guest writes into it), so a failed resume leaves
    /// the snapshot as it was.
    static let liveMemoryFile = "vm.mem.live"

    /// The snapshot in `dir` into the Firecracker just started, resumed. Its
    /// network is the backend the snapshot names (`fd:3`, inherited again).
    // @port-skip linux-only: Firecracker snapshot load (macOS: VZVirtualMachine.restoreMachineStateFrom)
    private func loadSnapshot(_ dir: String, _ p: ChildProcess, log: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: config.firecrackerAPISocketPath) {
            if let status = p.exitStatus {
                let out = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                throw MachineError.exitedDuringStart(status, String(out.suffix(2000)))
            }
            if ContinuousClock.now > deadline { throw MachineError.io("firecracker API \(config.firecrackerAPISocketPath)", ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let r = try await api.request("PUT", "/snapshot/load", [
            "snapshot_path": .string(dir + "/vm.snap"),
            "mem_backend": ["backend_type": "File", "backend_path": .string(dir + "/" + Self.liveMemoryFile)],
            "resume_vm": true,
        ], timeout: .seconds(300))
        guard r.ok else { throw MachineError.toolFailed("firecracker snapshot load", Int32(r.status), r.fault) }
    }

    /// Suspend: the vCPUs paused, a full snapshot (`vm.snap`, `vm.mem`) into
    /// `dir`, every share's virtiofsd handing its state over, then
    /// Firecracker and the virtiofsds end (`.suspended`). A failed snapshot
    /// leaves the VM running.
    // @port-skip linux-only: Firecracker snapshot (macOS: VZVirtualMachine.saveMachineStateTo)
    public func snapshot(into dir: String) async throws {
        guard state == .running, let process else { throw MachineError.notRunning }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try await pause()
        let r: FirecrackerAPI.Response
        do {
            r = try await api.request("PUT", "/snapshot/create", [
                "snapshot_type": "Full",
                "snapshot_path": .string(dir + "/vm.snap"),
                "mem_file_path": .string(dir + "/vm.mem"),
            ], timeout: .seconds(300))
        } catch {
            try? await resume()
            throw error
        }
        guard r.ok else {
            // The vhost-user-fs rings are stopped once their state was taken:
            // a refusal after that can't resume cleanly, so the VM ends.
            pendingReason = .crashed
            process.signal(SIGKILL)
            _ = await waitUntilStopped()
            throw MachineError.toolFailed("firecracker snapshot create", Int32(r.status), r.fault)
        }
        pendingReason = .suspended
        state = .stopping
        process.signal(SIGKILL)
        _ = await waitUntilStopped()
    }

    /// Ctrl-Alt-Del, SIGKILL after `timeout`.
    // @port-skip linux-only: Firecracker backend
    @discardableResult
    public func stop(timeout: Duration = .seconds(30)) async -> StopInfo {
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
    public func kill() async -> StopInfo {
        if case .stopped(let info) = state { return info }
        guard let process else { return finishIdle(.killed) }
        pendingReason = .killed
        process.signal(SIGKILL)
        return await waitUntilStopped()
    }

    // @port-skip linux-only: Firecracker backend
    public func waitUntilStopped() async -> StopInfo {
        if case .stopped(let info) = state { return info }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }



    /// Freezes the guest's vCPUs (`PATCH /vm {"state": "Paused"}`): its
    /// devices stop taking work too (a paused NIC stops draining).
    // @port-skip linux-only: Firecracker backend (macOS: VZVirtualMachine.pause)
    public func pause() async throws {
        let r = try await api.request("PATCH", "/vm", ["state": "Paused"])
        guard r.ok else { throw MachineError.toolFailed("firecracker pause", Int32(r.status), r.fault) }
    }

    // @port-skip linux-only: Firecracker backend (macOS: VZVirtualMachine.resume)
    public func resume() async throws {
        let r = try await api.request("PATCH", "/vm", ["state": "Resumed"])
        guard r.ok else { throw MachineError.toolFailed("firecracker resume", Int32(r.status), r.fault) }
    }

    // MARK: virtiofsd

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
        // reconnect): take the VM down.
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
        finish(StopInfo(reason: reason, exitStatus: status))
    }

    // @port-skip linux-only: Firecracker backend
    private func finishIdle(_ reason: StopReason) -> StopInfo {
        let info = StopInfo(reason: reason, exitStatus: 0)
        finish(info)
        return info
    }

    // @port-skip linux-only: Firecracker backend
    private func finish(_ info: StopInfo) {
        if case .stopped = state { return }
        state = .stopped(info)
        for w in stopWaiters { w.resume(returning: info) }
        stopWaiters = []
        onStopped?(info)
    }
}

// @port-skip linux-only: Firecracker backend
extension MachineConfig {
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
        // Writeback: the guest's flushes reach the host file (fdatasync).
        // Firecracker's default, Unsafe, drops them: a host crash could lose
        // what the guest had synced.
        var drives: [JSONValue] = [[
            "drive_id": "root", "path_on_host": .string(writeBaseInPlace ? baseImage : overlay),
            "is_root_device": false, "is_read_only": false, "cache_type": "Writeback",
        ]]
        for (i, d) in extraDisks.enumerated() {
            drives.append(["drive_id": .string("disk\(i + 1)"), "path_on_host": .string(d.path),
                           "is_root_device": false, "is_read_only": false, "cache_type": "Writeback"])
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
        if entropy { o["entropy"] = [:] }
        return .object(o)
    }
}

// @port-skip linux-only: host -> guest vsock dial (macOS: VZVirtioSocketDevice.connect(toPort:))
extension MachineConfig {
    /// A connected stream to the guest's vsock `port`: Firecracker's hybrid
    /// vsock socket with its CONNECT handshake. -errno on failure.
    // @port-skip linux-only: host -> guest vsock dial
    public func dialGuest(port: UInt32, timeoutMs: Int32 = 3000) async -> Int32 {
        let path = firecrackerVsockPath
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: acl_hybrid_vsock_connect(path, port, timeoutMs)) }
        }
    }
}
