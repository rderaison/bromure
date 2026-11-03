import Foundation
import CACLinuxShims
import NIOCore

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
    /// A new VM's home image, GiB (sparse: costs nothing up front). macOS:
    /// SessionDisk.defaultHomeImageGB. Env: BROMURE_AC_HOME_GB.
    public var homeImageGB = 16
    /// One of several users' daemons behind the multi-user gateway
    /// (BROMURE_AC_MULTIUSER=1): Firecracker VMs only (vhost-vsock's CIDs and
    /// ports are host-wide), and guests can't reach the host's own addresses.
    public var multiUser = false
    /// The gateway's account (BROMURE_AC_GATEWAY_USER), which may use the
    /// control socket besides its owner (and root).
    public var gatewayUser: String?
    /// The control socket, when not `runtimeDir/control.sock`
    /// (BROMURE_AC_CONTROL_SOCKET; multi-user: systemd's socket unit).
    public var controlSocketOverride: String?

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
            .with { c in
                if let gb = env["BROMURE_AC_HOME_GB"].flatMap(Int.init) { c.homeImageGB = min(1024, max(8, gb)) }
                c.multiUser = env["BROMURE_AC_MULTIUSER"] == "1"
                c.gatewayUser = env["BROMURE_AC_GATEWAY_USER"].flatMap { $0.isEmpty ? nil : $0 }
                c.controlSocketOverride = env["BROMURE_AC_CONTROL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
            }
    }

    // @port-skip linux-only: Linux daemon configuration
    func with(_ f: (inout DaemonConfig) -> Void) -> DaemonConfig {
        var c = self
        f(&c)
        return c
    }

    // @port-skip linux-only: Linux daemon configuration
    public var controlSocketPath: String { controlSocketOverride ?? runtimeDir + "/control.sock" }

    /// Who may use the control socket: its owner, root, and the gateway.
    // @port-skip linux-only: control socket peer policy
    public var controlPeers: Set<uid_t> {
        var s: Set<uid_t> = [getuid(), 0]
        if let g = gatewayUser, let pw = getpwnam(g) { s.insert(pw.pointee.pw_uid) }
        return s
    }
}

/// The headless daemon: one passt for the host, the interim switch, and the
/// Firecracker VMs. Serves the control socket's routes.
// @port-skip linux-only: the Linux daemon core (macOS: ACAppDelegate + ACAutomationServer)
public actor Daemon {
    struct Live {
        var machine: FirecrackerMachine
        let port: DgramPort
        let shell: GuestShell
        let config: MachineConfig
        /// The guest -> host vsock :5800 listener (agentd's shell pool).
        let vsock: HybridVsockListener
        /// The agents' browser MCP (vsock :5830), relayed to a fat client.
        let browser: BrowserMCPBridge
        /// The fd store entries holding this VM's network end and listener.
        let storedNet: String
    }

    public nonisolated let config: DaemonConfig
    var registry: VMRegistry
    // @port-skip linux-only: the daemon's running VMs
    var live: [String: Live] = [:] {
        // The session host reads which workspaces are up without a hop here.
        didSet { LinuxSessionHost.running.withLockedValue { $0 = Set(live.keys.compactMap { UUID(uuidString: $0) }) } }
    }
    private let passt: PasstUplink
    let sw: InterimSwitch
    /// VMs whose stop is being recorded (vmStopped).
    private var stopping: [String: Task<Void, Never>] = [:]

    /// The soft open-file limit up to the hard one: systemd starts services at
    /// 1024, and every VM, SSH session and forward holds several.
    // @port-skip linux-only: Linux daemon core
    static func raiseFDLimit() {
        var l = rlimit()
        guard getrlimit(Int32(RLIMIT_NOFILE.rawValue), &l) == 0, l.rlim_cur < l.rlim_max else { return }
        l.rlim_cur = l.rlim_max
        _ = setrlimit(Int32(RLIMIT_NOFILE.rawValue), &l)
    }

    // @port-skip linux-only: Linux daemon core
    public static func start(_ config: DaemonConfig) async throws -> Daemon {
        raiseFDLimit()
        try FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: config.runtimeDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Under systemd with a fd store, the previous daemon's passt (and the
        // flows it holds) is taken back rather than replaced.
        var pc = PasstUplink.Config(logPath: config.runtimeDir + "/passt.log")
        pc.useFDStore = true
        let stored = FDStore.take()
        let passt = try await PasstUplink.start(pc, adopting: PasstUplink.Adopted.fromStore(stored))
        // The VMs' network ends (net-<short id>) and vsock listeners
        // (vsock-<short id>, bmcp-<short id>), for adoptRunning; control:
        // systemd's socket unit (multi-user), the daemon command's. Anything
        // else is stale.
        let perVM = { (name: String) in ["net-", "vsock-", "bmcp-"].contains { name.hasPrefix($0) } }
        for (name, fds) in stored where !["passt", "passt-pid", "control"].contains(name) && !(perVM(name) && fds.count == 1) {
            for fd in fds { close(fd) }
        }
        if passt.adopted { FileHandle.standardError.write(Data("bromure-ac daemon: took back passt (pid \(passt.pid ?? 0)) from the fd store\n".utf8)) }
        let d = Daemon(config: config, passt: passt)
        let storedNet = stored.filter { perVM($0.key) && $0.value.count == 1 }.mapValues { $0[0] }
        await d.adoptRunning(storedNet: storedNet)
        await d.startSessionEngine()
        await d.setUpRemoteAccess()
        return d
    }

    // @port-skip linux-only: Linux daemon core
    private init(config: DaemonConfig, passt: PasstUplink) {
        self.config = config
        self.passt = passt
        self.sw = InterimSwitch(uplink: passt)
        if config.multiUser {
            sw.blockedDestination.withLockedValue { $0 = { HostAddresses.shared.contains($0) } }
        }
        let registry = VMRegistry(path: config.stateDir + "/vms.json", isAlive: Self.isOurVM)
        self.registry = registry
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
        case ("GET", "/state"):
            // Only the fat client stamps its polls: it is connected, and can
            // show consent prompts (RemoteConsent.route).
            if req.headers["x-bromure-console-idle-ms"] != nil { PendingPromptBroker.recordFatClientContact() }
            return await state()
        case ("POST", let p) where p.hasPrefix("/prompts/") && p.hasSuffix("/answer"):
            return await answerPrompt(String(p.dropFirst("/prompts/".count).dropLast("/answer".count)), req.body)
        case ("GET", "/state/subscribe"): return stateSubscribe()
        case ("POST", let p) where p.hasPrefix("/sessions/") && p.hasSuffix("/tab"):
            return tabCommand(String(p.dropFirst("/sessions/".count).dropLast("/tab".count)), req.body)
        case ("POST", "/agent-sessions/start"): return await agentSessionCommand(nil, "start", req.body)
        case ("GET", let p) where p.hasPrefix("/agent-sessions/") && p.hasSuffix("/transcript"):
            guard let id = UUID(uuidString: String(p.dropFirst("/agent-sessions/".count).dropLast("/transcript".count))
                .removingPercentEncoding ?? "") else { return .error(400, "Bad session id") }
            return await agentSessionTranscript(id)
        case ("POST", let p) where p.hasPrefix("/agent-sessions/"):
            let parts = p.dropFirst("/agent-sessions/".count).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0].removingPercentEncoding ?? parts[0]) else {
                return .error(400, "Bad session id or action")
            }
            return await agentSessionCommand(id, parts[1], req.body)
        case ("GET", "/profiles"): return listProfiles()
        case ("POST", "/profiles"): return await createProfile(req.body)
        case ("GET", "/vms"): return listVMs()
        case ("POST", "/vms"): return await createVM(req.body)
        case (let m, let p) where p.hasPrefix("/vms/"): return await vmRoute(m, p, req.body)
        case ("GET", "/remote"): return await remoteStatus()
        case ("POST", "/remote"): return await remoteApply(req.body)
        case ("POST", "/remote/keys"): return await remoteAddKey(req.body)
        case ("POST", "/remote/code"): return remoteCode(req.body)
        case ("GET", "/remote/authorized-keys"): return await remoteAuthorizedKeys()
        case ("POST", "/remote/code/check"): return remoteCodeCheck(req.body)
        case ("POST", "/fatclient/forward"): return await fatclientForward(req.body)
        case ("POST", "/fatclient/browser-mcp"): return await fatclientBrowserMCP(req.body)
        case ("DELETE", let p) where p.hasPrefix("/remote/keys/"):
            let raw = String(p.dropFirst("/remote/keys/".count))
            return await remoteRemoveKey(raw.removingPercentEncoding ?? raw)
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
    func state() async -> ControlResponse { ControlResponse(200, await stateBody()) }

    /// `GET /state/subscribe`: the octet-stream header, then a `/state`
    /// frame `[u32be len][u8 flag][json]` (len counts flag + json; flag 0,
    /// never compressed) whenever it changes (a running VM's uptime ticking
    /// doesn't count; frames still carry it), checked every 0.5 s, and at
    /// least every 15 s (a client resubscribes after 45 s of silence). Ends
    /// when a write fails; the client half-closing (the SSH bridge forwards
    /// its EOF) doesn't end it.
    // partial: no gzip frames (flag 1)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/state/subscribe"): h=97279e9d002810bf @7dd92fdf
    // @port ACAutomationServer.handleStateSubscribe(fd: Int32) h=7745b9b5fc280681 @7dd92fdf
    func stateSubscribe() -> ControlResponse {
        let me = WeakDaemon(self)
        return .streaming { client in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            var last = Data()
            var lastSent = ContinuousClock.now - .seconds(60)
            while !Task.isCancelled {
                guard let d = me.daemon else { return }
                // A held push stream is a connected fat client.
                PendingPromptBroker.recordFatClientContact()
                let body = await d.stateBody()
                guard let json = try? enc.encode(body), let key = try? enc.encode(Self.withoutUptime(body)) else { return }
                if key != last || ContinuousClock.now - lastSent >= .seconds(15) {
                    var frame = ByteBuffer()
                    frame.writeInteger(UInt32(json.count + 1))
                    frame.writeInteger(UInt8(0))
                    frame.writeBytes(json)
                    do { try await client.write(frame) } catch { return }
                    last = key
                    lastSent = .now
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A VM's `/state` / `/vms` entry: the record, and for a running VM what
    /// its agentd reports in the outbox: the tab roster (a fat client mounts
    /// a terminal once it's non-empty: tmux is up) and its vitals.
    // @port-skip linux-only: the per-VM half of ACAppDelegate.automationVMList (VMRecord.json, GuestOutbox)
    func vmEntry(_ rec: VMRecord) -> JSONValue {
        guard case .object(var o) = rec.json else { return rec.json }
        o["attached"] = false                         // no attached pane on Linux
        guard rec.state == .running else { o["tabs"] = []; return .object(o) }
        let outbox = vmDir(rec.id) + "/outbox/"
        o["tabs"] = .array(GuestOutbox.parseRoster(GuestOutbox.read(outbox + "tabs.txt") ?? "").map(GuestOutbox.tabJSON))
        for (k, v) in GuestOutbox.vitalsJSON(GuestOutbox.read(outbox + "vmstat.txt") ?? "") { o[k] = v }
        return .object(o)
    }

    /// `/state` as the push compares it: without the VMs' `uptimeSeconds`.
    // @port-skip linux-only: change test for stateSubscribe
    static func withoutUptime(_ state: JSONValue) -> JSONValue {
        guard case .object(var o) = state, case .array(let vms)? = o["vms"] else { return state }
        o["vms"] = .array(vms.map { v in
            guard case .object(var e) = v else { return v }
            e["uptimeSeconds"] = nil
            return .object(e)
        })
        return .object(o)
    }

    /// The `/state` snapshot (state() and stateSubscribe()); its
    /// pendingPrompts are what macOS's onListPendingPrompts gives.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListPendingPrompts h=7f92140cb6125056 @7dd92fdf
    func stateBody() async -> JSONValue {
        // Decision prompts waiting for a fat client's answer (PendingPromptBroker).
        // The session engine's tab rosters (LinuxSessionHost.tabsModel), from
        // what agentd writes to each running workspace's outbox.
        let rosters: [(UUID, [GuestTab]?)] = records.compactMap { rec in
            guard let id = UUID(uuidString: rec.id) else { return nil }
            guard rec.state == .running else { return (id, nil) }
            return (id, GuestOutbox.parseRoster(GuestOutbox.read(vmDir(rec.id) + "/outbox/tabs.txt") ?? ""))
        }
        let (prompts, sessionEntries, statuses) = await MainActor.run {
            for (id, roster) in rosters { LinuxSessionHost.shared?.updateRoster(id, roster) }
            return (PendingPromptBroker.shared.pendingList(), SessionStores.shared?.stateEntries() ?? [:],
                    LinuxSessionHost.shared?.tabStatuses() ?? [:])
        }
        // As on macOS, `vms` is the running (and booting) VMs and `workspaces`
        // every workspace; with no profiles here each VM is its own workspace,
        // same id, which is what a fat client opens a terminal on.
        let all = records
        // Each tab's hook status, as macOS's automationVMList gives it.
        let vms: [JSONValue] = all.filter { $0.state == .running || $0.state == .starting }.map { rec in
            guard case .object(var o) = vmEntry(rec), case .array(let tabs)? = o["tabs"],
                  let id = UUID(uuidString: rec.id) else { return vmEntry(rec) }
            o["tabs"] = .array(tabs.map { tab in
                guard case .object(var t) = tab, let i = tab["index"]?.numberValue.map({ Int($0) }) else { return tab }
                t["agentStatus"] = .string(statuses[id]?[i] ?? AgentStatus.done.rawValue)
                return .object(t)
            })
            return .object(o)
        }
        return .object([
            "version": 1, "hostKind": "linux",
            "build": ["version": .string(BuildInfo.version)],
            "vms": .array(vms), "workspaces": .array(all.map(\.workspaceJSON)), "workspacesListed": true,
            "supportsPush": true,
            "vmnetSubnet": "192.168.64.0/24", "vmnetGateway": "192.168.64.1",
            "uplink": ["kind": "passt", "mtu": .number(Double(passt.mtu))],
            "secretsKeySource": SecretsVault.masterKeySource.map { .string($0.rawValue) } ?? .null,
            "pendingPrompts": JSONValue(foundation: prompts) ?? .array([]),
        ].merging(sessionEntries) { a, _ in a })
    }

    // partial: entries lack tabs, stats, ports, docker, disk and kube fields (see VMRecord.json)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/vms"): h=b80678b83121852e @7dd92fdf
    func listVMs() -> ControlResponse {
        ControlResponse(200, ["vms": .array(records.map(vmEntry))])
    }

    /// `POST /vms`: create and start a VM, detached. Body: `name?`,
    /// `machine?` (q35|microvm), `memoryGB?`, `cpus?`. 201 `{id, shortId, name, detached}`.
    // partial: no profile, tool, auth, apiKey, mounts or rm; takes name/machine/memoryGB/cpus; always detached
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/vms"): h=7a7b62405e4c0dbe @7dd92fdf
    /// `id`: a workspace Profile's (POST /profiles), else a new one; `boot`
    /// false only registers it (stopped).
    func createVM(_ body: JSONValue, id fixedID: String? = nil, boot: Bool = true) async -> ControlResponse {
        let id = fixedID?.lowercased() ?? UUID().uuidString.lowercased()
        let name = body["name"]?.stringValue ?? "vm-\(id.prefix(8))"
        // `find` matches id, short id and name: a name equal to any of them
        // would make lookups ambiguous.
        if registry.records.contains(where: { $0.name == name || $0.id == name || $0.shortId == name }) {
            return .error(409, "'\(name)' is already a VM's name or id")
        }
        let machine = body["machine"]?.stringValue ?? Self.machineType
        guard machine == Self.machineType else {
            return .error(400, "Unknown machine '\(machine)': VMs are Firecracker ('\(Self.machineType)')")
        }
        guard FileManager.default.isExecutableFile(atPath: MachineConfig.defaultFirecrackerBinary) else {
            return .error(503, "No Firecracker at \(MachineConfig.defaultFirecrackerBinary) (linux/firecracker/build.sh)")
        }
        let memMiB = Int((body["memoryGB"]?.numberValue ?? 2) * 1024)
        let cpus = Int(body["cpus"]?.numberValue ?? 2)
        let homeGB = body["homeGB"]?.numberValue.map { min(1024, max(8, Int($0))) }
        guard let cid = try? CIDAllocator.shared.allocate() else { return .error(503, "No free vsock CID") }
        let mac = String(format: "52:54:00:%02x:%02x:%02x", cid >> 16 & 0xFF, cid >> 8 & 0xFF, cid & 0xFF)
        var rec = VMRecord(id: id, name: name, machine: machine, cid: cid, mac: mac, state: .starting, ip: nil,
                           cpus: cpus, memoryMiB: memMiB, createdAt: Date(), bootedAt: nil, statePath: nil)
        rec.homeGB = homeGB
        if !boot {
            rec.state = .stopped
            CIDAllocator.shared.release(cid)
        }
        do {
            try registry.upsert(rec)
            if boot { try await launch(&rec) }
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
        case ("POST", "resume"): return Self.noSuspend(rec)
        case ("POST", "start"): return await start(rec, body)
        case ("POST", "remove"): return remove(rec)
        default: return .error(405, "Method not allowed")
        }
    }

    // partial: the entry is VMRecord.json, a subset of macOS's vmEntry
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "GET": h=a05dae914d2f170b @7dd92fdf
    func getVM(_ rec: VMRecord) -> ControlResponse { ControlResponse(200, withIP(rec).json) }

    /// The record's machine type: Firecracker is the only backend.
    static let machineType = "firecracker"

    /// Suspend/resume: not until Firecracker can snapshot a VM with
    /// vhost-user-fs shares (device-state migration, in the fork).
    // @port-skip linux-only: no suspend on Linux yet
    static func noSuspend(_ rec: VMRecord) -> ControlResponse {
        .error(409, "Suspend and resume aren't available yet (Firecracker can't snapshot VMs with shared folders yet); stop and start '\(rec.name)' instead",
               ["state": .string(rec.state.rawValue)])
    }

    /// `DELETE /vms/{id}` with `{"action": "shutdown"|"suspend"|"kill"}`.
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "DELETE": h=eaa996c40011d353 @7dd92fdf
    func deleteVM(_ rec: VMRecord, action: String) async -> ControlResponse {
        if action == "suspend" { return Self.noSuspend(rec) }
        guard let l = live[rec.id] else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        switch action {
        case "kill":
            await vmStopped(rec.id, await l.machine.kill())
        default:
            await vmStopped(rec.id, await l.machine.stop(timeout: .seconds(20)))
        }
        // vmStopped ran above, not just from onStopped's Task: the record
        // says stopped before the reply does (a `start` right after works).
        return ControlResponse(200, ["status": "stopped"])
    }

    /// `POST /vms/{id}/start` (Linux): boot a stopped VM again, on its own
    /// overlay and home image.
    // @port-skip linux-only: macOS starts a VM by starting its workspace again; Linux VMs are the workspaces for now
    func start(_ rec: VMRecord, _ body: JSONValue = .object([:])) async -> ControlResponse {
        guard rec.state == .stopped || rec.state == .suspended else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        guard rec.machine == Self.machineType else {
            return .error(409, "'\(rec.name)' was made for QEMU, which is gone: remove it (vm rm) and create a new one")
        }
        var r = rec
        // `homeGB`: a new home size, applied by this cold boot. Images don't shrink.
        if let gb = body["homeGB"]?.numberValue.map({ min(1024, max(8, Int($0))) }) {
            var st = stat()
            if stat(vmDir(rec.id) + "/home.img", &st) == 0, UInt64(gb) << 30 < UInt64(st.st_size) {
                return .error(400, "'\(rec.name)' has a \(UInt64(st.st_size) >> 30) GiB home image; home images don't shrink")
            }
            r.homeGB = gb
        }
        if !CIDAllocator.shared.claim(rec.cid) {
            guard let fresh = try? CIDAllocator.shared.allocate() else { return .error(503, "No free vsock CID") }
            r.cid = fresh
        }
        do {
            try await launch(&r)
            return ControlResponse(200, ["status": "running"])
        } catch {
            CIDAllocator.shared.release(r.cid)
            return .error(500, "Start failed: \(error)")
        }
    }

    /// `POST /vms/{id}/remove` (Linux): forget a stopped or suspended VM and
    /// delete everything it had: overlay, home image, meta, outbox, saved state.
    // @port-skip linux-only: macOS deletes a workspace from its profile store; Linux VMs are the workspaces for now
    func remove(_ rec: VMRecord) -> ControlResponse {
        guard rec.state == .stopped || rec.state == .suspended, live[rec.id] == nil else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue); stop it first", ["state": .string(rec.state.rawValue)])
        }
        do {
            try registry.remove(id: rec.id)
        } catch {
            return .error(500, "Remove failed: \(error)")
        }
        // The id is a UUID we made: vmDir can't name anything but this VM's directory.
        try? FileManager.default.removeItem(atPath: vmDir(rec.id))
        try? FileManager.default.removeItem(atPath: config.runtimeDir + "/vms/" + rec.shortId)
        return ControlResponse(200, ["status": "removed"])
    }

    /// `POST /vms/{id}/exec` `{command, argv?, timeout?}` →
    /// `{stdout, stderr, exitCode}`; 409 when the VM isn't running, 502 when
    /// its shell agent doesn't come up within 10 s.
    // partial: no interactive (-it) PTY streaming; no dead-pool flush-and-retry beyond GuestShell's pre-write skip
    // @port ACAutomationServer.handleExec(fd: Int32, profileID: String, bodyJSON: [String:Any]) h=009a8b0b81d659a5 @7dd92fdf
    func exec(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        if body["interactive"] == .bool(true) { return await interactiveExec(rec, body) }
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

    /// `POST /vms/{id}/exec` `{command, interactive: true, cols, rows}`: a
    /// pooled shell connection gets `[u32be len][{"cmd", "interactive", "cols",
    /// "rows"}]`, the client gets a 200 octet-stream header, and from then on
    /// the bytes are pumped both ways unchanged (the frames are between the
    /// CLI and agentd's pty) until either side closes.
    // partial: a plain pump: no consent gate (no MITM consent on Linux yet; guiConsent is moot)
    // @port ACAutomationServer.handleInteractiveExec(clientFD: Int32, profileID: String, bodyJSON: [String:Any]) h=2d264f1f134ea9eb @7dd92fdf
    func interactiveExec(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        guard let l = live[rec.id], rec.state == .running else {
            let s = rec.state == .stopped ? "off" : rec.state.rawValue
            return .error(409, "VM '\(rec.name)' is \(s)", ["state": .string(s)])
        }
        var r: [String: JSONValue] = ["cmd": .string(body["command"]?.stringValue ?? ""), "interactive": .bool(true),
                                      "cols": .number(body["cols"]?.numberValue ?? 80),
                                      "rows": .number(body["rows"]?.numberValue ?? 24)]
        // A fat client's terminal: its own grouped tmux view of the session,
        // on window `window`, sized by another client (sizePassive).
        if let v = body["view"]?.stringValue { r["view"] = .string(v) }
        if let w = body["window"]?.numberValue { r["window"] = .number(w) }
        if body["sizePassive"] == .bool(true) { r["sizePassive"] = .bool(true) }
        let req: JSONValue = .object(r)
        guard let reqData = try? JSONEncoder().encode(req) else { return .error(500, "Failed to encode request") }
        var conn: VsockConnection?
        for _ in 0..<32 {
            guard let c = await l.shell.connection(timeout: .seconds(10)) else { break }
            if c.channel.channel.isActive { conn = c; break }
            await c.close()
        }
        guard let conn else {
            return .error(502, "No shell connection for '\(rec.name)' after 10s — its shell agent hasn't come up yet.")
        }
        return .streaming { client in
            _ = try? await conn.withStreams { inbound, outbound in
                var head = ByteBuffer()
                head.writeInteger(UInt32(reqData.count))
                head.writeBytes(reqData)
                try await outbound.write(head)
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { for await b in client.inbound { do { try await outbound.write(b) } catch { return } } }
                    g.addTask { do { for try await b in inbound { try await client.write(b) } } catch {} }
                    await g.next()
                    g.cancelAll()
                }
            }
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

    /// Stages the VM's files, plugs it into the switch, starts Firecracker.
    // @port-skip linux-only: Linux daemon VM lifecycle
    private func launch(_ rec: inout VMRecord) async throws {
        let dir = vmDir(rec.id)
        let run = config.runtimeDir + "/vms/" + rec.shortId
        let fm = FileManager.default
        for sub in [dir + "/meta/virtiofs-tags", run] {
            try fm.createDirectory(atPath: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // 0777 as on macOS: every guest uid (the workspace's, a run_as user's)
        // writes there through plain DAC. The VM directory above it stays 0700.
        try HomeSeed.prepareOutboxDirectory(URL(fileURLWithPath: dir + "/outbox"), forRestore: false)
        try? fm.removeItem(atPath: dir + "/meta/bromure-agentd.py")
        try fm.copyItem(atPath: config.agentdPath, toPath: dir + "/meta/bromure-agentd.py")
        for tag in ["bromure-meta", "bromure-outbox"] {
            _ = fm.createFile(atPath: dir + "/meta/virtiofs-tags/" + tag, contents: nil)
        }
        // The guest MTU rule (PasstUplink.Config.mtu): 65520 behind passt;
        // VPN profiles keep the macOS 1280/1400 (no profiles on Linux yet).
        try "\(passt.mtu)\n".write(toFile: dir + "/meta/mtu", atomically: true, encoding: .utf8)
        // The home: a sparse raw image as the second disk (vdb), kept across
        // stop/start and suspend/resume, deleted with the VM. agentd sees
        // `home.mode` ext4, mkfs's the blank disk on first boot (label
        // bromure-home) and mounts it over /home/ubuntu, as on macOS.
        let home = dir + "/home.img"
        let target = Self.homeImageTargetBytes(gb: rec.homeGB, defaultGB: config.homeImageGB)
        try Self.ensureHomeImage(atPath: home, bytes: target)
        // A size change lands at a boot (agentd's resize2fs grows the mounted ext4).
        let homeNote = try Self.growHomeImageIfNeeded(atPath: home, target: target, setting: rec.homeGB)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': \(homeNote)\n".utf8))
        // The guest's hostname (agentd's task_apply_hostname), from the VM's name.
        try (Self.sanitizeHostname(rec.name) + "\n").write(toFile: dir + "/meta/hostname.txt", atomically: true, encoding: .utf8)
        try "ext4\n".write(toFile: dir + "/meta/home.mode", atomically: true, encoding: .utf8)
        // The home seed agentd applies to the ext4 home before the session,
        // and the counters it polls; bumped every launch, as on macOS (on a
        // restore that's what tells the resumed agent to re-apply).
        let meta = URL(fileURLWithPath: dir + "/meta")
        HomeSeed.ensureEnvGeneration(in: meta)
        HomeSeed.ensureGenerationCounter(named: "seed.generation", in: meta)
        let seed = meta.appendingPathComponent("home-seed", isDirectory: true)
        // The workspace's own seed, as macOS writes it (ProfileStore): its
        // dotfiles, the agents' hooks (~/.bromure/agent-status.sh, omp's),
        // settings and the Claude spec. A VM with no Profile gets the
        // profile-independent subset.
        if let profile = profile(for: rec) {
            let store = profileStore
            try store.writeHomeSeedFiles(for: profile, into: seed, terminalDefaults: .fallback)
            try store.finalizeHomeSeed(for: profile, seedDir: seed)
        } else {
            try HomeSeed.writeHomeSeedFiles(into: seed)
            try HomeSeed.finalizeHomeSeed(seedDir: seed)
        }
        HomeSeed.bumpGenerationCounter(named: "seed.generation", in: meta)

        var qc = try machineConfig(rec)
        // The VM's end goes to Firecracker; ours waits in the fd store, so a
        // restarted daemon takes the same link back.
        let (port, peer) = try DgramPort.pair(name: "vm-" + rec.shortId)
        qc.network = .datagram(peerFD: peer)
        let storeName = "net-" + rec.shortId
        FDStore.store(storeName, [port.fd])
        let vsock: HybridVsockListener
        do {
            vsock = try await HybridVsockListener.listen(udsPath: qc.firecrackerVsockPath, port: 5800, cid: rec.cid,
                                                         fdStoreName: "vsock-" + rec.shortId)
        } catch {
            close(peer)
            FDStore.remove(storeName)
            port.close()
            throw error
        }
        let browser: BrowserMCPBridge
        do {
            browser = try await MainActor.run { [qc] in
                try BrowserMCPBridge(udsPath: qc.firecrackerVsockPath, fdStoreName: "bmcp-" + rec.shortId)
            }
        } catch {
            close(peer)
            FDStore.remove(storeName)
            port.close()
            await vsock.close()
            FDStore.remove("vsock-" + rec.shortId)
            throw error
        }
        let shell = await GuestShell(cid: rec.cid, connections: vsock.connections)
        let l = Live(machine: FirecrackerMachine(config: qc), port: port, shell: shell, config: qc,
                     vsock: vsock, browser: browser, storedNet: storeName)
        sw.attach(l.port, mac: rec.mac)
        // The address is leased now and recorded, so a restarted daemon hands
        // the same one back (the guest keeps it).
        rec.lease = sw.dhcp.lease(for: InterimSwitch.mac(rec.mac)).map(String.init).joined(separator: ".")
        let machine = l.machine
        let id = rec.id
        await machine.setOnStopped { [weak self] info in Task { await self?.vmStopped(id, info) } }
        live[id] = l
        do {
            try await machine.start()
        } catch {
            live[id] = nil
            await teardown(l, mac: rec.mac)
            throw error
        }
        rec.state = .running
        rec.bootedAt = Date()
        if let pid = await machine.pid {
            rec.pid = pid
            rec.pidStart = Self.processStartTime(pid)
        }
        try registry.upsert(rec)
    }

    /// A VM's machine configuration (launch and re-adoption build the same one).
    // @port-skip linux-only: Linux daemon VM layout
    func machineConfig(_ rec: VMRecord) throws -> MachineConfig {
        let dir = vmDir(rec.id), run = config.runtimeDir + "/vms/" + rec.shortId
        // The system disk: a sparse raw copy of the base (Firecracker has no qcow2).
        var qc = try MachineConfig(name: "bromure-\(rec.shortId)", bakedImage: config.imageDir,
                                   overlay: dir + "/disk.raw", vsockCID: rec.cid, runDirectory: run)
        qc.cpus = rec.cpus
        qc.memoryMiB = rec.memoryMiB
        qc.shares = [.init(tag: "bromure-meta", hostPath: dir + "/meta", readOnly: true),
                     .init(tag: "bromure-outbox", hostPath: dir + "/outbox")]
        qc.macAddress = rec.mac
        qc.extraDisks = [.init(path: dir + "/home.img")]
        return qc
    }

    /// Takes over the VMs a previous daemon left running: Firecracker by pid
    /// and API socket, its network end and vsock listener back from the fd
    /// store, the same lease, a new shell (agentd re-dials vsock 5800). Only
    /// under systemd's fd store: a daemon restarted by hand can't give a VM
    /// its network back, so it ends such VMs instead.
    // @port-skip linux-only: Linux daemon VM lifecycle (macOS VMs live in the app)
    func adoptRunning(storedNet: [String: Int32] = [:]) async {
        var storedNet = storedNet
        defer { for (_, fd) in storedNet { close(fd) } }
        for rec in registry.records where rec.state == .running || rec.state == .starting {
            var r = rec
            do {
                guard let pid = rec.pid else { throw MachineError.notRunning }
                // Its own Firecracker holds the CID.
                guard CIDAllocator.shared.adopt(rec.cid) else { throw MachineError.invalidConfig("CID \(rec.cid) is taken") }
                guard rec.machine == Self.machineType else { throw MachineError.invalidConfig("a pre-Firecracker VM") }
                let qc = try machineConfig(rec)
                // Its network is the socketpair end the fd store kept;
                // without it (no systemd store) the VM has no network back.
                let storeName = "net-" + rec.shortId
                guard let fd = storedNet.removeValue(forKey: storeName) else {
                    throw MachineError.invalidConfig("no stored network for VM \(rec.shortId)")
                }
                let port = DgramPort(name: "vm-" + rec.shortId, fd: fd)
                let vsock: HybridVsockListener
                do {
                    vsock = try await HybridVsockListener.listen(
                        udsPath: qc.firecrackerVsockPath, port: 5800, cid: rec.cid, fdStoreName: "vsock-" + rec.shortId,
                        stored: storedNet.removeValue(forKey: "vsock-" + rec.shortId))
                } catch { port.close(); throw error }
                // A VM started by a daemon from before the browser bridge has
                // none stored: it gets a fresh listener.
                let storedBrowser = storedNet.removeValue(forKey: "bmcp-" + rec.shortId)
                let browser: BrowserMCPBridge
                do {
                    browser = try await MainActor.run { [qc] in
                        try BrowserMCPBridge(udsPath: qc.firecrackerVsockPath, fdStoreName: "bmcp-" + rec.shortId,
                                             stored: storedBrowser)
                    }
                } catch { await vsock.close(); port.close(); throw error }
                let shell = await GuestShell(cid: rec.cid, connections: vsock.connections)
                let machine: FirecrackerMachine
                do { machine = try await FirecrackerMachine.adopt(config: qc, pid: pid) } catch {
                    await shell.stop()
                    await vsock.close()
                    await MainActor.run { browser.stop() }
                    port.close()
                    throw error
                }
                let l = Live(machine: machine, port: port, shell: shell, config: qc, vsock: vsock, browser: browser,
                             storedNet: storeName)
                sw.attach(l.port, mac: rec.mac)
                if let lease = rec.lease { sw.dhcp.assign(mac: InterimSwitch.mac(rec.mac), ip: InterimSwitch.ipv4(lease)) }
                let id = rec.id
                await l.machine.setOnStopped { [weak self] info in Task { await self?.vmStopped(id, info) } }
                live[id] = l
                r.state = .running
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': took back its Firecracker (pid \(pid)), network and vsock from the fd store\n".utf8))
            } catch {
                // A Firecracker left here would keep running and hold
                // disk.raw and home.img. End it, if it's still the process
                // we recorded.
                if Self.killIfOurs(rec) {
                    FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': not re-adopted (\(error)); killed its Firecracker (pid \(rec.pid ?? 0))\n".utf8))
                }
                CIDAllocator.shared.release(rec.cid)
                r.state = .stopped
                r.pid = nil
                r.pidStart = nil
            }
            try? registry.upsert(r)
        }
    }

    /// SIGKILLs `rec`'s recorded VM process if it is still ours (isOurVM:
    /// same start time, `--id bromure-<short>`), through a pidfd so
    /// a pid recycled after the check can't be hit. Returns whether it did.
    // @port-skip linux-only: Linux process identity
    @discardableResult
    static func killIfOurs(_ rec: VMRecord) -> Bool {
        guard let pid = rec.pid else { return false }
        let fd = acl_pidfd_open(pid)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Checked after the pidfd is open: it pins this process, so a match
        // now is the process the signal goes to.
        guard isOurVM(rec) else { return false }
        return acl_pidfd_send_signal(fd, SIGKILL) == 0
    }

    /// /proc/<pid>/stat's starttime (field 22), nil if there's no such process.
    // @port-skip linux-only: Linux process identity
    static func processStartTime(_ pid: Int32) -> UInt64? {
        guard let st = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = st.lastIndex(of: ")") else { return nil }
        let fields = st[st.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? UInt64(fields[19]) : nil       // fields[0] is field 3 (state)
    }

    /// Whether `rec`'s recorded Firecracker is still the process at that pid:
    /// same start time, and it runs this VM (`--id bromure-<short id>`).
    // @port-skip linux-only: Linux process identity
    static func isOurVM(_ rec: VMRecord) -> Bool {
        guard let pid = rec.pid, let start = rec.pidStart, processStartTime(pid) == start,
              let cmd = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return false }
        let args = cmd.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return zip(args, args.dropFirst()).contains { $0 == "--id" && $1 == "bromure-\(rec.shortId)" }
    }

    /// Creates the sparse home image if missing (ftruncate: all holes). An
    /// existing one is left alone: it's the VM's home.
    // partial: no free-space check (EphemeralDisk.checkDiskSpace) and no ProfileStore change notice
    // @port SessionDisk.ensureHomeImageExists() h=83d4fac81b0747d2 @25ad3a88
    static func ensureHomeImage(atPath path: String, bytes: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MachineError.io("create \(path)", errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(bytes)) == 0 else {
            let e = errno
            unlink(path)
            throw MachineError.io("ftruncate \(path)", e)
        }
    }

    /// The home image's guest-visible size: the VM's own setting, else the
    /// daemon-wide default (BROMURE_AC_HOME_GB), 8–1024 GiB.
    // partial: no legacy-home migration size (Linux homes start on ext4)
    // @port SessionDisk.var homeImageTargetBytes h=fa34eac9bb8da5e5 @25ad3a88
    static func homeImageTargetBytes(gb: Int?, defaultGB: Int) -> UInt64 {
        UInt64(min(1024, max(8, gb ?? defaultGB))) << 30
    }

    /// Grows an existing home image to `target` (never shrinks; it stays
    /// sparse; agentd runs resize2fs after mounting). Returns what it did,
    /// for the log: a grow that doesn't happen says why.
    // partial: no free-space check (EphemeralDisk.checkDiskSpace) and no ProfileStore change notice
    // @port SessionDisk.growHomeImageIfNeeded() h=594c22d9dd98aa97 @25ad3a88
    static func growHomeImageIfNeeded(atPath path: String, target: UInt64, setting: Int?) throws -> String {
        let gib = { (b: UInt64) in "\(b >> 30) GiB" }
        var st = stat()
        guard stat(path, &st) == 0 else { return "home image unreadable at \(path) — not grown (target \(gib(target)))" }
        let size = UInt64(st.st_size)
        guard size < target else {
            return "home image \(gib(size)) (setting \(setting.map { "\($0) GB" } ?? "default"), target \(gib(target))) — nothing to grow"
        }
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw MachineError.io("open \(path)", errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(target)) == 0 else { throw MachineError.io("ftruncate \(path)", errno) }
        var now = stat()
        _ = fstat(fd, &now)
        return "home image grown \(gib(size)) → \(gib(UInt64(now.st_size))) (target \(gib(target)))"
    }

    /// The guest hostname for a VM name: lowercase a-z 0-9 and hyphens, no
    /// leading or trailing hyphen, at most 32 characters, "bromure" if empty.
    // @port SessionDisk.static sanitizeHostname(_: String) h=72495a211cde5f30 @25ad3a88
    static func sanitizeHostname(_ name: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var s = String(name.lowercased().filter { allowed.contains($0) })
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        if s.isEmpty { s = "bromure" }
        if s.count > 32 { s = String(s.prefix(32)) }
        if let first = s.first, !first.isLetter && !first.isNumber { s = "x" + s }
        return s
    }

    /// Firecracker went away (any reason): unplug it, and record what it is now.
    // @port-skip linux-only: Linux daemon VM lifecycle
    func vmStopped(_ id: String, _ info: FirecrackerMachine.StopInfo) async {
        // Both onStopped's Task and a stop route call this; the first does
        // the work, and every caller returns only once it is done (the
        // teardown suspends: without this the other caller could reply, and
        // a `start` attach a new port, before the old one is detached).
        if let t = stopping[id] { return await t.value }
        guard let l = live.removeValue(forKey: id) else { return }
        let t = Task { await self.finishStop(id, l, info) }
        stopping[id] = t
        await t.value
        stopping[id] = nil
    }

    // @port-skip linux-only: Linux daemon VM lifecycle
    private func finishStop(_ id: String, _ l: Live, _ info: FirecrackerMachine.StopInfo) async {
        guard var rec = registry.find(id) else { return }
        await teardown(l, mac: rec.mac)
        rec = registry.find(id) ?? rec
        rec.state = .stopped
        rec.ip = nil
        rec.pid = nil
        rec.pidStart = nil
        CIDAllocator.shared.release(rec.cid)
        try? registry.upsert(rec)
    }

    // @port-skip linux-only: Linux daemon VM lifecycle
    private func teardown(_ l: Live, mac: String) async {
        sw.detach(mac: mac)
        sw.dhcp.release(mac: mac)
        await l.shell.stop()
        l.port.close()
        await l.vsock.close()
        await MainActor.run { [browser = l.browser] in browser.stop() }
        FDStore.remove(l.storedNet)
        FDStore.remove("vsock-" + l.storedNet.dropFirst("net-".count))
        FDStore.remove("bmcp-" + l.storedNet.dropFirst("net-".count))
    }

    /// Stops every VM (killed: systemd's stop is not a graceful shutdown of
    /// guests yet) and passt.
    // @port-skip linux-only: Linux daemon lifecycle
    public func shutdown() async {
        // A stopping daemon leaves nothing for a next one to take back (each
        // VM's teardown drops its fd store entries).
        for (_, l) in live { await l.machine.kill() }
        for _ in 0..<50 where !live.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        await MainActor.run { RemoteAccessServer.shared.stop() }
        sw.stop()
        await passt.close()
    }
}

// @port-skip linux-only: build metadata for /state
public enum BuildInfo {
    public static let version = "linux-dev"
}

extension Daemon {
    /// `POST /prompts/<id>/answer {"choice"}`: a fat client's answer to a
    /// pending decision prompt (from /state's pendingPrompts). 404 when no
    /// such prompt is waiting.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAnswerPrompt h=450bd9135b23e909 @7dd92fdf
    func answerPrompt(_ id: String, _ body: JSONValue) async -> ControlResponse {
        let choice = body["choice"]?.numberValue.map { Int($0) } ?? -1
        let ok = await MainActor.run { PendingPromptBroker.shared.answer(id: id, choice: choice) }
        return ControlResponse(ok ? 200 : 404, ["ok": .bool(ok)])
    }
}
