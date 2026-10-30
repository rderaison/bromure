import Foundation

/// Where the daemon keeps things.
// @port-skip linux-only: Linux daemon configuration (XDG layout)
public struct DaemonConfig: Sendable {
    /// `$XDG_STATE_HOME/bromure-ac`: vms.json and each VM's overlay, meta, outbox, state.
    public var stateDir: String
    /// `$XDG_RUNTIME_DIR/bromure-ac`: control.sock and the VMs' sockets (short paths).
    public var runtimeDir: String
    /// linux/bake's output: base.img, vmlinuz, initrd.img, cmdline.
    public var imageDir: String
    /// bromure-agentd.py, staged into each VM's meta share.
    public var agentdPath: String

    // @port-skip linux-only: Linux daemon configuration
    public init(stateDir: String, runtimeDir: String, imageDir: String, agentdPath: String) {
        self.stateDir = stateDir
        self.runtimeDir = runtimeDir
        self.imageDir = imageDir
        self.agentdPath = agentdPath
    }

    /// From the environment: XDG dirs, BROMURE_AC_IMAGE, BROMURE_AGENTD.
    // @port-skip linux-only: Linux daemon configuration
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> DaemonConfig {
        let home = env["HOME"] ?? NSHomeDirectory()
        func xdg(_ key: String, _ fallback: String) -> String { env[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        let data = xdg("XDG_DATA_HOME", home + "/.local/share")
        return DaemonConfig(
            stateDir: xdg("XDG_STATE_HOME", home + "/.local/state") + "/bromure-ac",
            runtimeDir: xdg("XDG_RUNTIME_DIR", "/tmp/bromure-ac-\(getuid())") + "/bromure-ac",
            imageDir: env["BROMURE_AC_IMAGE"] ?? data + "/bromure-ac/image-amd64",
            agentdPath: env["BROMURE_AGENTD"] ?? data + "/bromure-ac/vm-setup/bromure-agentd.py")
    }

    // @port-skip linux-only: Linux daemon configuration
    public var controlSocketPath: String { runtimeDir + "/control.sock" }
}

/// The headless daemon: one passt for the host, the interim switch, the
/// shared vsock listener, and the VMs. Serves the control socket's routes.
// @port-skip linux-only: the Linux daemon core (macOS: ACAppDelegate + ACAutomationServer)
public actor Daemon {
    struct Live {
        var machine: QEMUMachine
        let port: StreamPort
        let shell: GuestShell
        let config: QEMUMachineConfig
    }

    public nonisolated let config: DaemonConfig
    private var registry: VMRegistry
    private var live: [String: Live] = [:]
    private let passt: PasstUplink
    private let sw: InterimSwitch
    private let listener: VsockListener
    /// CIDs of suspended VMs, leased at load so a new VM can't take them.
    private var reservedCIDs: Set<UInt32> = []

    // @port-skip linux-only: Linux daemon core
    public static func start(_ config: DaemonConfig) async throws -> Daemon {
        try FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: config.runtimeDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let passt = try await PasstUplink.start(.init(logPath: config.runtimeDir + "/passt.log"))
        let listener = try await VsockListener.shared(port: 5800)
        return Daemon(config: config, passt: passt, listener: listener)
    }

    // @port-skip linux-only: Linux daemon core
    private init(config: DaemonConfig, passt: PasstUplink, listener: VsockListener) {
        self.config = config
        self.passt = passt
        self.listener = listener
        self.sw = InterimSwitch(uplink: passt)
        let registry = VMRegistry(path: config.stateDir + "/vms.json")
        self.registry = registry
        // Suspended VMs keep their CID across daemon restarts.
        self.reservedCIDs = Set(registry.records.filter { $0.state == .suspended && CIDAllocator.shared.claim($0.cid) }.map(\.cid))
    }

    // @port-skip linux-only: Linux daemon core
    public var records: [VMRecord] { registry.records.map(withIP) }

    // @port-skip linux-only: Linux daemon core
    private func withIP(_ r: VMRecord) -> VMRecord {
        var r = r
        if r.state == .running { r.ip = sw.dhcp.leasedIP(for: r.mac) } else { r.ip = nil }
        return r
    }

    // MARK: routes

    /// The control socket's router: the subset of macOS's routes the Linux
    /// daemon has, same paths and JSON; anything else is 404 with a JSON error.
    // @port-skip linux-only: the Linux router (each route below carries its own @port)
    public func handle(_ req: ControlRequest) async -> ControlResponse {
        let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")
        switch (req.method, path) {
        case ("GET", "/health"): return health()
        case ("GET", "/state"): return state()
        case ("GET", "/vms"): return listVMs()
        case ("POST", "/vms"): return await createVM(req.body)
        case (let m, let p) where p.hasPrefix("/vms/"): return await vmRoute(m, p, req.body)
        default: return .error(404, "Not found", ["path": .string(req.path)])
        }
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/health"): h=ec3227f904b323b7 @7dd92fdf
    func health() -> ControlResponse {
        ControlResponse(200, ["status": "ok", "service": "bromure-ac-automation", "debugEnabled": false])
    }

    /// `/state`: the macOS snapshot's always-present keys this host can fill
    /// (`version`, `build`, `vms`, `workspaces`, the subnet) plus `hostKind`.
    // partial: no gridLayout, automations, tasks, pendingPrompts, subscriptions, securityTimeline, localModels, kubeClusters, generation/epoch, or agent sessions yet
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/state"): h=adfaa737ba44087f @7dd92fdf
    func state() -> ControlResponse {
        let vms = records.map(\.json)
        return ControlResponse(200, [
            "version": 1, "hostKind": "linux",
            "build": ["version": .string(BuildInfo.version)],
            "vms": .array(vms), "workspaces": [], "workspacesListed": true,
            "vmnetSubnet": "192.168.64.0/24", "vmnetGateway": "192.168.64.1",
            "uplink": ["kind": "passt", "mtu": .number(Double(passt.mtu))],
            "secretsKeySource": SecretsVault.masterKeySource.map { .string($0.rawValue) } ?? .null,
        ])
    }

    // partial: entries lack tabs, stats, ports, docker, disk and kube fields (see VMRecord.json)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/vms"): h=b80678b83121852e @7dd92fdf
    func listVMs() -> ControlResponse {
        ControlResponse(200, ["vms": .array(records.map(\.json))])
    }

    /// `POST /vms`: create and start a VM, detached. Body: `name?`,
    /// `machine?` (q35|microvm), `memoryGB?`, `cpus?`. 201 `{id, shortId, name, detached}`.
    // partial: no profile, tool, auth, apiKey, mounts or rm; takes name/machine/memoryGB/cpus; always detached
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/vms"): h=7a7b62405e4c0dbe @7dd92fdf
    func createVM(_ body: JSONValue) async -> ControlResponse {
        let id = UUID().uuidString.lowercased()
        let name = body["name"]?.stringValue ?? "vm-\(id.prefix(8))"
        // `find` matches id, short id and name: a name equal to any of them
        // would make lookups ambiguous.
        if registry.records.contains(where: { $0.name == name || $0.id == name || $0.shortId == name }) {
            return .error(409, "'\(name)' is already a VM's name or id")
        }
        let machine = body["machine"]?.stringValue ?? "microvm"
        guard QEMUMachineConfig.MachineType(rawValue: machine) != nil else {
            return .error(400, "Unknown machine '\(machine)' (q35 or microvm)")
        }
        let memMiB = Int((body["memoryGB"]?.numberValue ?? 2) * 1024)
        let cpus = Int(body["cpus"]?.numberValue ?? 2)
        guard let cid = try? CIDAllocator.shared.allocate() else { return .error(503, "No free vsock CID") }
        let mac = String(format: "52:54:00:%02x:%02x:%02x", cid >> 16 & 0xFF, cid >> 8 & 0xFF, cid & 0xFF)
        var rec = VMRecord(id: id, name: name, machine: machine, cid: cid, mac: mac, state: .starting, ip: nil,
                           cpus: cpus, memoryMiB: memMiB, createdAt: Date(), bootedAt: nil, statePath: nil)
        do {
            try registry.upsert(rec)
            try await launch(&rec, restoreFrom: nil)
            return ControlResponse(201, ["id": .string(id), "shortId": .string(rec.shortId),
                                         "name": .string(name), "tool": .null, "detached": true])
        } catch {
            CIDAllocator.shared.release(cid)
            try? registry.remove(id: id)
            return .error(500, "Failed to create VM: \(error)")
        }
    }

    // partial: only GET, DELETE, exec (+ Linux resume); no attach, reboot, file, docker, fusion, routing, model, checkpoints, revert, type
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case (let m, let p) where p.hasPrefix("/vms/"): h=343ebd5280ded291 @7dd92fdf
    func vmRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse {
        let parts = path.dropFirst("/vms/".count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let raw = parts.first, let key = raw.removingPercentEncoding,
              let rec = registry.find(key) else { return .error(404, "VM not found") }
        let sub = parts.count > 1 ? parts[1] : ""
        switch (method, sub) {
        case ("GET", ""): return getVM(rec)
        case ("DELETE", ""): return await deleteVM(rec, action: body["action"]?.stringValue ?? "shutdown")
        case ("POST", "exec"): return await exec(rec, body)
        case ("POST", "resume"): return await resume(rec)
        default: return .error(405, "Method not allowed")
        }
    }

    // partial: the entry is VMRecord.json, a subset of macOS's vmEntry
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "GET": h=a05dae914d2f170b @7dd92fdf
    func getVM(_ rec: VMRecord) -> ControlResponse { ControlResponse(200, withIP(rec).json) }

    /// `DELETE /vms/{id}` with `{"action": "shutdown"|"suspend"|"kill"}`.
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "DELETE": h=eaa996c40011d353 @7dd92fdf
    func deleteVM(_ rec: VMRecord, action: String) async -> ControlResponse {
        guard let l = live[rec.id] else {
            return rec.state == .suspended && action != "suspend"
                ? ControlResponse(200, ["status": "stopped"]) : .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)",
                                                                         ["state": .string(rec.state.rawValue)])
        }
        switch action {
        case "suspend":
            let statePath = vmDir(rec.id) + "/vm.state"
            var r = rec
            r.statePath = statePath
            r.state = .suspended
            try? registry.upsert(r)             // before QEMU exits: onStopped sees .suspended
            do {
                _ = try await l.machine.suspend(to: statePath)
                return ControlResponse(200, ["status": "suspended"])
            } catch {
                r.state = .running
                try? registry.upsert(r)
                return .error(500, "Suspend failed: \(error)")
            }
        case "kill":
            await l.machine.kill()
        default:
            await l.machine.stop(timeout: .seconds(20))
        }
        return ControlResponse(200, ["status": "stopped"])
    }

    /// `POST /vms/{id}/resume` (Linux): restore a suspended VM.
    // @port-skip linux-only: macOS resumes by starting the workspace again; the Linux CLI has an explicit resume
    func resume(_ rec: VMRecord) async -> ControlResponse {
        guard rec.state == .suspended, let statePath = rec.statePath else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        var r = rec
        // Its own CID if we reserved or can claim it; otherwise a new one. A
        // restore under another CID works: the vhost-vsock transport reset
        // makes the guest re-read guest_cid (CIDChangeTests).
        if reservedCIDs.remove(rec.cid) == nil, !CIDAllocator.shared.claim(rec.cid) {
            guard let fresh = try? CIDAllocator.shared.allocate() else { return .error(503, "No free vsock CID") }
            r.cid = fresh
        }
        do {
            try await launch(&r, restoreFrom: statePath)
            return ControlResponse(200, ["status": "running"])
        } catch {
            CIDAllocator.shared.release(r.cid)
            return .error(500, "Resume failed: \(error)")
        }
    }

    /// `POST /vms/{id}/exec` `{command, argv?, timeout?}` →
    /// `{stdout, stderr, exitCode}`; 409 when the VM isn't running, 502 when
    /// its shell agent doesn't come up within 10 s.
    // partial: no interactive (-it) PTY streaming; no dead-pool flush-and-retry beyond GuestShell's pre-write skip
    // @port ACAutomationServer.handleExec(fd: Int32, profileID: String, bodyJSON: [String:Any]) h=009a8b0b81d659a5 @7dd92fdf
    func exec(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        if body["interactive"] == .bool(true) { return .error(400, "Interactive exec isn't supported on Linux yet") }
        var command = body["command"]?.stringValue ?? ""
        if case .array(let argv) = body["argv"] ?? .null, !argv.isEmpty {
            command = argv.compactMap(\.stringValue).map(Self.shellQuote).joined(separator: " ")
        }
        guard !command.isEmpty else { return .error(400, "Missing 'command' field") }
        guard let l = live[rec.id], rec.state == .running else {
            let s = rec.state == .stopped ? "off" : rec.state.rawValue
            return .error(409, "VM '\(rec.name)' is \(s)", ["state": .string(s)])
        }
        let timeout = Int(body["timeout"]?.numberValue ?? 30)
        do {
            let r = try await l.shell.exec(command, timeout: timeout, wait: .seconds(10))
            return ControlResponse(200, ["stdout": .string(r.stdout), "stderr": .string(r.stderr),
                                         "exitCode": .number(Double(r.exitCode))])
        } catch GuestShell.ShellError.noReply(let why) {
            return .error(502, "The command may have run; no reply from '\(rec.name)' (\(why)). Not retried.")
        } catch {
            return .error(502, "No shell connection for '\(rec.name)' after 10s — its shell agent hasn't come up yet.")
        }
    }

    // @port-skip linux-only: argv quoting for the guest shell
    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,@%+".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: VM plumbing

    // @port-skip linux-only: Linux daemon VM layout
    func vmDir(_ id: String) -> String { config.stateDir + "/vms/" + id }

    /// Stages the VM's files, plugs it into the switch, starts (or restores) QEMU.
    // @port-skip linux-only: Linux daemon VM lifecycle
    private func launch(_ rec: inout VMRecord, restoreFrom statePath: String?) async throws {
        let dir = vmDir(rec.id)
        let run = config.runtimeDir + "/vms/" + rec.shortId
        let fm = FileManager.default
        for sub in [dir + "/meta/virtiofs-tags", dir + "/outbox", run] {
            try fm.createDirectory(atPath: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.removeItem(atPath: dir + "/meta/bromure-agentd.py")
        try fm.copyItem(atPath: config.agentdPath, toPath: dir + "/meta/bromure-agentd.py")
        for tag in ["bromure-meta", "bromure-outbox"] {
            _ = fm.createFile(atPath: dir + "/meta/virtiofs-tags/" + tag, contents: nil)
        }
        // The guest MTU rule (PasstUplink.Config.mtu): 65520 behind passt;
        // VPN profiles keep the macOS 1280/1400 (no profiles on Linux yet).
        try "\(passt.mtu)\n".write(toFile: dir + "/meta/mtu", atomically: true, encoding: .utf8)

        var qc = try QEMUMachineConfig(name: "bromure-\(rec.shortId)", bakedImage: config.imageDir,
                                       overlay: dir + "/disk.qcow2", vsockCID: rec.cid, runDirectory: run)
        qc.machine = QEMUMachineConfig.MachineType(rawValue: rec.machine) ?? .microvm
        qc.cpus = rec.cpus
        qc.memoryMiB = rec.memoryMiB
        qc.shares = [.init(tag: "bromure-meta", hostPath: dir + "/meta", readOnly: true),
                     .init(tag: "bromure-outbox", hostPath: dir + "/outbox")]
        qc.network = .stream(socketPath: run + "/net.sock")
        qc.macAddress = rec.mac

        let port = try await StreamPort.listen(path: run + "/net.sock")
        sw.attach(port, mac: rec.mac)
        let shell = await GuestShell(cid: rec.cid, listener: listener)
        let machine = QEMUMachine(config: qc)
        let id = rec.id
        await machine.setOnStopped { [weak self] info in Task { await self?.vmStopped(id, info) } }
        live[id] = Live(machine: machine, port: port, shell: shell, config: qc)
        do {
            if let statePath { _ = try await machine.restore(from: statePath) } else { try await machine.start() }
        } catch {
            live[id] = nil
            await teardown(Live(machine: machine, port: port, shell: shell, config: qc), mac: rec.mac)
            throw error
        }
        rec.state = .running
        rec.bootedAt = statePath == nil ? Date() : (rec.bootedAt ?? Date())
        if statePath != nil {
            try? fm.removeItem(atPath: statePath!)
            try? fm.removeItem(atPath: SnapshotIdentity.sidecarPath(forState: statePath!))
            rec.statePath = nil
        }
        try registry.upsert(rec)
    }

    /// QEMU went away (any reason): unplug it, and record what it is now.
    // @port-skip linux-only: Linux daemon VM lifecycle
    func vmStopped(_ id: String, _ info: QEMUMachine.StopInfo) async {
        guard let l = live.removeValue(forKey: id), var rec = registry.find(id) else { return }
        await teardown(l, mac: rec.mac)
        if case .suspended = info.reason { rec.state = .suspended } else if rec.state != .suspended { rec.state = .stopped }
        rec.ip = nil
        CIDAllocator.shared.release(rec.cid)
        try? registry.upsert(rec)
    }

    // @port-skip linux-only: Linux daemon VM lifecycle
    private func teardown(_ l: Live, mac: String) async {
        sw.detach(mac: mac)
        sw.dhcp.release(mac: mac)
        await l.shell.stop()
        await l.port.close()
        await listener.forget(cid: l.config.vsockCID)
    }

    /// Stops every VM (killed: systemd's stop is not a graceful shutdown of
    /// guests yet) and passt.
    // @port-skip linux-only: Linux daemon lifecycle
    public func shutdown() async {
        for (_, l) in live { await l.machine.kill() }
        for _ in 0..<50 where !live.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        sw.stop()
        await passt.close()
    }
}

// @port-skip linux-only: build metadata for /state
public enum BuildInfo {
    public static let version = "linux-dev"
}
