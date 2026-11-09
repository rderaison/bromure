import Foundation
import CACLinuxShims
import NIOCore
import NIOConcurrencyHelpers
import NIOSSL
import SandboxEngine

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
    /// A new VM's home image, GiB, when set (macOS: `vm.homeImageGB`); else
    /// it is scaled to the free space where the VMs live (HomeImageSizing).
    /// Env: BROMURE_AC_HOME_GB.
    public var homeImageOverrideGB: Int?
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
    /// Where the kernel sentry's modules come from: the published, signed
    /// catalog for this host's architecture (fromEnvironment's default, as
    /// the macOS app's), or BROMURE_SENTRY_CATALOG_BASE (a local or test
    /// catalog, unsigned accepted). nil: none (a config made in code, as
    /// tests' are: they never reach the CDN).
    public var sentryCatalog: SentryCatalogSource?

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
                if let gb = env["BROMURE_AC_HOME_GB"].flatMap(Int.init) { c.homeImageOverrideGB = gb }
                c.multiUser = env["BROMURE_AC_MULTIUSER"] == "1"
                c.gatewayUser = env["BROMURE_AC_GATEWAY_USER"].flatMap { $0.isEmpty ? nil : $0 }
                c.controlSocketOverride = env["BROMURE_AC_CONTROL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
                c.sentryCatalog = SentryCatalogSource.fromEnvironment(env)
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
        /// The agents' browser MCP (vsock :5830), relayed to a fat client;
        /// none on a cluster machine.
        let browser: BrowserMCPBridge?
        /// The workspace's intercepting proxy (vsock :8443); nil without one.
        var mitm: MitmListener?
        /// The agents' MCP sockets: the coding board (:5831), automations (:5833).
        var mcp: [MCPLineListener] = []
        /// The streamed planning driver's socket (vsock :5832) and its
        /// workspace; none on a cluster machine.
        var plan: UUID?
        /// The guest's local-model bridge (vsock :8446); nil for a sign-in VM.
        var inference: InferenceBridgeListener?
        /// The guest's AWS credential_process helper's end (vsock 8445).
        var aws: VsockFDListener?
        /// The guest's SSH agent socket's end (vsock 8444).
        var ssh: VsockFDListener?
        /// The guest attestor's channel (vsock 5840), for a sandboxed workspace.
        var attest: VsockFDListener?
        /// The guest kernel sentry's channel (vsock 5841), for a sentry workspace.
        var sentry: VsockFDListener?
        /// The fd store entries holding this VM's network end and listener.
        let storedNet: String
    }

    public nonisolated let config: DaemonConfig
    var registry: VMRegistry
    // @port-skip linux-only: the daemon's running VMs
    var live: [String: Live] = [:] {
        // The session host reads which workspaces are up without a hop here.
        didSet {
            LinuxSessionHost.running.withLockedValue { $0 = Set(live.keys.compactMap { UUID(uuidString: $0) }) }
            publishSentryRunState()
        }
    }
    private let passt: PasstUplink
    let sw: InterimSwitch
    /// The workspaces' intercepting proxy (its CA in `<state>/mitm`); nil
    /// when it couldn't start, and the guests then go out directly.
    let mitm: MitmProxy?
    /// The kernel sentry's module cache (DaemonSentry.swift); nil without a catalog.
    nonisolated let sentryModules: SentryModuleStore?
    /// VMs whose stop is being recorded (vmStopped).
    private(set) var stopping: [String: Task<Void, Never>] = [:]
    /// Cluster machines whose disks the host is repairing (never started meanwhile).
    nonisolated let repairMarks = RepairMarks()
    /// VMs between start's checks and their `live` entry: launch awaits in
    /// between (releasing the actor), so a repair or a remove must see them.
    private(set) var starting: Set<String> = []
    /// Tests: called at the top of each launch (after the starting mark), so
    /// a start can be held at an await; throwing aborts that launch.
    static let launchHookForTesting = NIOLockedValueBox<(@Sendable (String) async throws -> Void)?>(nil)
    /// Workspaces between a reboot's stop and its boot: a `--rm` one isn't
    /// deleted by that stop (macOS: rebootingProfiles).
    var rebooting: Set<String> = []
    /// A workspace whose boot died on filesystem errors: the console's line
    /// (DaemonBootRemedy; also in the workspace list as bootFailure).
    var activeBootFailures: [String: String] = [:]
    /// Those whose failure got a repair already (the next offer is a reset).
    var bootRepairAttempted: Set<String> = []
    /// A remedy chosen and under way.
    var pendingBootRemedies: [String: BootRemedy] = [:]
    /// When a workspace's watched cold boot began (its roster is newer).
    var bootStartedAt: [String: Date] = [:]
    /// VMs whose guest said it's going down for a reboot (DaemonGuestReboot).
    var guestRebootIntents: Set<String> = []
    /// Stopped after such a reboot: relaunched once their stop is done.
    var pendingGuestRelaunch: Set<String> = []
    /// Stops the daemon asked for (a client's shutdown, kill, suspend; the
    /// daemon's own end): never taken for a guest's reboot, even when the
    /// guest's own exit got there first (macOS: session.stopping).
    var explicitStops: Set<String> = []
    /// A private-set refresh queued by a profile write and not yet run, this
    /// daemon's (DaemonTraceUpload.swift): a burst of writes makes one.
    nonisolated let streamingRefreshQueued = NIOLockedValueBox(false)
    /// Stops asked while a reboot was under way (the reboot route's, a
    /// guest's relaunch): kept until that reboot looks (stoppedDuringReboot),
    /// which vmStopped's own consuming of explicitStops can't take away.
    var stopsDuringReboot: Set<String> = []
    /// An adopted VM's serial log size when this daemon took it back: what
    /// came before is an earlier boot's (logs were once appended across boots).
    var serialLogStart: [String: UInt64] = [:]
    /// VMs being resumed from a snapshot: a failure leaves them suspended.
    private var restoring: Set<String> = []
    /// The sign-in VMs' Profiles (never saved), by VM id.
    var registrationProfiles: [String: Profile] = [:]
    /// Open client callback relays (/fatclient/forward), by guest address.
    var activeRelays: [String: Int] = [:]
    /// When a callback relay last opened, by guest address: an SSH-forwarded
    /// one is the shared server's to close, so its end isn't seen here.
    var relayOpened: [String: Date] = [:]
    /// The stored workspace each running VM's staging last applied, by VM
    /// id (DaemonLiveEdits.swift); unknown after a daemon restart.
    var liveApplied: [String: Profile] = [:]
    /// Each workspace's last queued live refresh (they run one at a time).
    var liveRefreshTail: [String: Task<Void, Never>] = [:]
    /// The sessions (`<workspace>#<session>`) whose compromise question is
    /// up (DaemonCompromise.swift).
    var compromiseAsking: Set<String> = []
    /// The workspaces with a launch question up (the base-image drift
    /// offer, DaemonBaseImageDrift.swift): one per workspace at a time.
    var launchQuestions = Daemon.LaunchQuestionGate()
    /// The agent watchdog's 5 s egress sampler (DaemonWatchdog.swift).
    var watchdogSampler: Task<Void, Never>?
    /// Questions holding each VM paused (DaemonWatchdog.swift), by VM id; a
    /// VM held paused sends nothing, which the sentry mustn't take for silence.
    // @port-skip linux-only: the Linux daemon's pause bookkeeping (DaemonWatchdog.swift)
    var pauseHolds: [String: Int] = [:] { didSet { publishSentryRunState() } }
    /// The one-shot wake at the soonest timed firewall rule's expiry (DaemonFirewall.swift).
    var firewallExpiryTask: Task<Void, Never>?
    /// VMs whose watchdog Release waits for the other questions holding them.
    var releaseWhenFree: Set<String> = []
    /// VMs whose watchdog question is up.
    var watchdogAsking: Set<String> = []
    /// Each running guest's heartbeat (DaemonLiveness.swift), and the ones
    /// gone silent.
    var guestLiveness: [String: GuestLiveness] = [:]
    var guestSilent: Set<String> = []
    /// Each SSO workspace's credential resolution and refresh loop (pushAWSCredentials).
    var ssoRefreshTasks: [UUID: Task<Void, Never>] = [:]
    /// VMs that took this boot's checkpoint (observeCheckpoints).
    var checkpointedBoots: Set<String> = []
    /// Whether the VM directory makes reflinks: "" yes, else why not (unprobed: nil).
    var checkpointProbe: String?
    /// What each running workspace's agents were last staged with
    /// (DaemonModelRefresh.swift), by VM id.
    var lastStagedProfiles: [String: Profile] = [:]
    var modelRefreshObserver: NSObjectProtocol?
    /// The latest /state build, and one under way (DaemonStateFeed.swift).
    var stateCache: (body: JSONValue, at: ContinuousClock.Instant, generation: Int)?
    var stateBuilding: (task: Task<JSONValue, Never>, generation: Int)?
    /// /state/subscribe's one producer (DaemonStateFeed.swift).
    nonisolated let stateFeed = StateFeed()

    /// The fd store entries a VM holds, `<prefix><short id>`: its network
    /// end and every vsock listener. Adoption takes them back, a stop
    /// removes them; one list, so a new listener can't be left out of one.
    // @port-skip linux-only: systemd fd store layout
    static let perVMStorePrefixes = ["net-", "vsock-", "bmcp-", "mitm-", "tbmcp-", "amcp-", "kmcp-", "dmcp-", "sbmcp-",
                                     "plan-", "llm-", "aws-", "ssh-", "attest-", "sentry-"]

    /// The soft open-file limit up to the hard one: systemd starts services at
    /// 1024, and every VM, SSH session and forward holds several.
    // @port-skip linux-only: Linux daemon core
    static func raiseFDLimit() {
        var l = rlimit()
        guard getrlimit(Int32(RLIMIT_NOFILE.rawValue), &l) == 0, l.rlim_cur < l.rlim_max else { return }
        l.rlim_cur = l.rlim_max
        _ = setrlimit(Int32(RLIMIT_NOFILE.rawValue), &l)
    }

    /// Tests: a record in the registry.
    // @port-skip linux-only: Linux daemon core (tests)
    func registerForTesting(_ rec: VMRecord) throws { try registry.upsert(rec) }
    /// Tests: a start under way for `id` (its disk in use), or not.
    // @port-skip linux-only: test hook
    func markStartingForTesting(_ id: String, _ on: Bool) { if on { starting.insert(id) } else { starting.remove(id) } }

    /// Tests: a daemon on its own uplink and directories, nothing else started
    /// (no session engine, remote access or adoption). `uplink`: the
    /// binary standing in for passt (tests that boot nothing give a no-op).
    // @port-skip linux-only: Linux daemon core (tests)
    static func makeForTesting(_ config: DaemonConfig, uplink: String) async throws -> Daemon {
        for dir in [config.stateDir, config.runtimeDir] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var pc = PasstUplink.Config(logPath: config.runtimeDir + "/passt.log")
        pc.binary = uplink
        let passt = try await PasstUplink.start(pc)
        return Daemon(config: config, passt: passt)
    }

    // @port-skip linux-only: Linux daemon core
    public static func start(_ config: DaemonConfig) async throws -> Daemon {
        raiseFDLimit()
        try FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Its sockets' dir: refused when someone else owns it or its parent,
        // or either is writable by others (the /tmp fallback can be squatted).
        close(try SecureDir.runtime(config.runtimeDir, create: true))
        Self.placeEngineKey(stateDir: config.stateDir)
        // The workspaces' store, before anything reads a Profile: adoption
        // and the refresh below do (setUpRemoteAccess sets the same root).
        ProfileStore.defaultRootDir = URL(fileURLWithPath: config.stateDir + "/profiles", isDirectory: true)
        // Under systemd with a fd store, the previous daemon's passt (and the
        // flows it holds) is taken back rather than replaced.
        var pc = PasstUplink.Config(logPath: config.runtimeDir + "/passt.log")
        pc.useFDStore = true
        if let warning = Self.configHomeWarning(stateDir: config.stateDir) { FileHandle.standardError.write(Data(warning.utf8)) }
        // A bake cut short after its disk went live: its boot files and stamp.
        InterimBake.finishPromotionIfIdle(imageDir: config.imageDir)
        let stored = FDStore.take()
        let adoptedPasst = PasstUplink.Adopted.fromStore(stored)
        // The workspaces' subnet (DaemonSubnet.swift): chosen before any VM,
        // unless VMs already run on one (an adopted passt, running records).
        let registryPath = config.stateDir + "/vms.json"
        let chosen = Self.chooseWorkspaceGateway(hasVMs: VMRegistry.hasRecords(path: registryPath))
        let passtGateway = adoptedPasst.flatMap { ProcFS.argv($0.pid).flatMap(Self.passtGateway(argv:)) }
        let vmGateway = VMRegistry.runningGateway(path: registryPath, isAlive: Self.isOurVM)
        pc.gateway = Self.gatewayToUse(chosen: chosen, inUse: passtGateway ?? vmGateway,
                                       vmsRunning: vmGateway != nil)
        pc.dnsForward = pc.gateway
        Self.workspaceSubnet.withLockedValue { $0 = Self.subnetCIDR(gateway: pc.gateway) }
        let passt = try await PasstUplink.start(pc, adopting: adoptedPasst)
        // The VMs' network ends (net-<short id>) and vsock listeners
        // (vsock-<short id>, bmcp-<short id>), for adoptRunning; control:
        // systemd's socket unit (multi-user), the daemon command's. Anything
        // else is stale.
        let perVM = { (name: String) in perVMStorePrefixes.contains { name.hasPrefix($0) } }
        for (name, fds) in stored where !["passt", "passt-pid", "control"].contains(name) && !(perVM(name) && fds.count == 1) {
            for fd in fds { close(fd) }
        }
        if passt.adopted { FileHandle.standardError.write(Data("bromure-ac daemon: took back passt (pid \(passt.pid ?? 0)) from the fd store\n".utf8)) }
        let d = Daemon(config: config, passt: passt)
        await d.wireCompromiseHandler()
        await d.wireBridgeAbort()
        await d.wireWatchdog()
        await d.wireSentryModules()
        await d.wireOpenShellAdvisor()
        await d.wirePolicySteering()
        refreshSquelchSettings()
        wireSquelchLedger()
        // The shared code's secrets (the enrollment's token and leaf key)
        // in this daemon's vault.
        if BACSecretStore.backend == nil { BACSecretStore.backend = VaultSecretBackend() }
        await d.wireCloudEnrollment()
        await d.installLiveModelRefresh()
        if let mitm = d.mitm { await d.wireSupplyChainOverrides(mitm.supplyChainBroker) }
        if let mitm = d.mitm {
            let root = URL(fileURLWithPath: config.stateDir + "/traces", isDirectory: true)
            // Every profile write says so (ProfileWrites.write / edit): the
            // private set follows, as macOS's profiles.didSet.
            ProfileWrites.onChange = { [weak d] in d?.refreshStreamingSoon() }
            await MainActor.run {
                mitm.setUpTraceStore(rootDir: root)
                // The proxy's model-host traffic drives hook-less agents'
                // status (macOS: traceStore.onConversationActivity and
                // HTTPMitmConnection.liveActivity → noteAgentActivity).
                mitm.traces.withLockedValue { $0 }?.onConversationActivity = { pid in
                    LinuxSessionHost.shared?.noteAgentActivity(pid)
                }
                MitmProxy.liveActivity.withLockedValue { $0 = { pid in
                    Task { @MainActor in LinuxSessionHost.shared?.noteAgentActivity(pid) }
                } }
                // Its uploader while enrolled (macOS: the engine's start).
                Self.refreshStreamingState(store: mitm.traces.withLockedValue { $0 })
            }
            // What a VM mints is saved with its workspace: the next boot's
            // swap map has it (macOS: credentialMinter.sink).
            // A Bedrock engine without a pasted key: the repair proxy signs its
            // upstream calls with the workspace's AWS credentials, through the
            // same consent-gated credential server every AWS call uses
            // (macOS: the engine's wiring at launch).
            Self.installBedrockSigner(mitm.awsCreds)
            mitm.credentialMinter.sink = { pid, minted in
                Task { @MainActor in Self.saveMintedCredential(minted, profileID: pid, store: ProfileStore()) }
            }
            // The local-model repair proxy, up before any VM (macOS: with
            // the MITM engine): the bridges read its port per connection.
            InferenceRepairProxy.shared.startIfNeeded()
        }
        let storedNet = stored.filter { perVM($0.key) && $0.value.count == 1 }.mapValues { $0[0] }
        await d.adoptRunning(storedNet: storedNet)
        // `--rm` workspaces a previous daemon left stopped.
        await d.sweepStoppedEphemeral()
        await d.startSessionEngine()
        // Taken-back workspaces: their credentials were set up as adoption
        // took them (before their proxy listeners served); their kubeconfigs
        // are rewritten now that the session host is up (the kube fakes were
        // made anew), as a live refresh does.
        let n = await d.refreshWorkspaceKubeconfigs()
        if n > 0 { FileHandle.standardError.write(Data("bromure-ac daemon: \(n) taken-back workspace(s): kubeconfigs refreshed\n".utf8)) }
        await d.setUpRemoteAccess()
        // The workspaces set to boot at login, in the background.
        Task { await d.bootFlaggedWorkspacesAtStartup() }
        return d
    }

    // @port-skip linux-only: Linux daemon core
    private init(config: DaemonConfig, passt: PasstUplink) {
        self.config = config
        self.passt = passt
        self.sentryModules = Self.makeSentryModuleStore(stateDir: config.stateDir, source: config.sentryCatalog)
        self.sw = InterimSwitch(uplink: passt, gateway: passt.config.gateway, dns: passt.config.dnsForward ?? passt.config.gateway)
        if config.multiUser {
            // The host's own addresses and every user's LAN pool, granted
            // or published (LANPools: blocked before a first publish).
            sw.blockedDestination.withLockedValue { $0 = { HostAddresses.shared.contains($0) || LANPools.shared.contains($0) } }
        } else {
            // A single-user server can hold grants too (admin pool add
            // --single-user): another account's LAN pool, published or not,
            // is refused, this account's own aside.
            sw.blockedDestination.withLockedValue { $0 = { LANPools.shared.containsOther($0) } }
        }
        // Binary identity: a new connection under a policy's `binaries` is
        // decided for the program the guest's attestor names (macOS: the
        // app sets VMNetSwitch.identityGate the same way).
        sw.egress.identityGate = { pid, sport, dst, dport, isn, hosts, policy in
            BinaryIdentityService.shared.gate(profileID: pid, sport: sport, dstIP: dst, dport: dport, isn: isn,
                                              hostnames: hosts, policy: policy)
        }
        let registry = VMRegistry(path: config.stateDir + "/vms.json", isAlive: Self.isOurVM)
        self.registry = registry
        do {
            mitm = try MitmProxy(caDirectory: URL(fileURLWithPath: config.stateDir + "/mitm", isDirectory: true),
                                 extraRoots: Self.testUpstreamRoots())
            mitm?.blocksHostAddresses = config.multiUser
            // The workspaces' ssh-agent sockets: in the 0700 runtime directory.
            mitm?.sshAgentDirectory.withLockedValue { $0 = config.runtimeDir + "/ssh-agents" }
            // A crashed ssh-add's askpass (a passphrase in it) goes first.
            Self.sweepAskpassScripts(in: config.runtimeDir)
            // No host-agent connection reaches a workspace's own agent.
            if let mitm { HostAgentClient.refusesHostAgentPeer = { [weak mitm] fd in mitm?.refusesHostAgentPeer(fd) ?? true } }
            mitm?.routeAllTo = Self.testUpstream()
            Self.applyTestSSOPortal()
            // AWS SSO reads ~/.aws where the AWS CLI writes it: $HOME (Foundation's
            // account home ignores $HOME on Linux).
            // Set once per process: a daemon made while another runs (tests)
            // doesn't replace a home already chosen.
            if AWSSSOResolver.homeOverride == nil, let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
                AWSSSOResolver.homeOverride = URL(fileURLWithPath: home, isDirectory: true)
            }
            // An e2e run marks itself: it reaches its test upstream or no
            // host at all (any build: a release build has no test route).
            if ProcessInfo.processInfo.environment["BROMURE_AC_E2E"] == "1" {
                mitm?.refusesRealUpstreams = true
                if mitm?.routeAllTo == nil {
                    FileHandle.standardError.write(Data("bromure-ac daemon: e2e mode with no test upstream: every upstream is refused\n".utf8))
                }
            }
        } catch {
            mitm = nil
            FileHandle.standardError.write(Data("bromure-ac daemon: no intercepting proxy: \(error)\n".utf8))
        }
        // Transparent host-side interception (macOS: launch's
        // setInterceptor(SwitchMitmForwarder, ports: [80, 443])): a session
        // VM's TCP to :80 and :443 goes through the MiTM whatever its proxy
        // env says, so guardrails, egress verbs and the credential swap can't
        // be skipped by unsetting HTTP(S)_PROXY. A workspace can opt out
        // (Profile.disableTransparentProxy); BROMURE_NO_TRANSPARENT forces it
        // off (debugging).
        // The switch's decisions on the Timeline, a binary-identity denial
        // with its reason from the proxy's guardrails (macOS: the egress
        // observer hands SwitchEgressReport the MiTM engine).
        if let mitm {
            sw.egress.observer = { [weak mitm] ev in SwitchEgressReport.record(ev, engine: mitm) }
        }
        if ProcessInfo.processInfo.environment["BROMURE_NO_TRANSPARENT"] == nil, let mitm {
            let egress = sw.egress
            let interceptor = SwitchInterceptor(proxy: mitm, guestMTU: passt.mtu) { portID, ip in
                egress.inject(MAC(raw: UInt64(truncatingIfNeeded: portID)), ip)
            }
            egress.setInterception(.init(interceptor: interceptor, ports: [80, 443]))
        }
    }

    /// Debug builds, VM e2e only: every upstream connection goes to a test
    /// server (`BROMURE_AC_TEST_UPSTREAM=ip:port`), whose CA the proxy trusts
    /// (`BROMURE_AC_TEST_ROOTS`, a PEM file). A release build has neither.
    // @port-skip linux-only: e2e hook of the Linux proxy
    static func testUpstream() -> (host: String, port: Int)? {
        #if DEBUG
        guard let v = ProcessInfo.processInfo.environment["BROMURE_AC_TEST_UPSTREAM"],
              let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) else { return nil }
        FileHandle.standardError.write(Data("bromure-ac daemon: DEBUG: every upstream goes to \(v)\n".utf8))
        return (String(v[..<colon]), port)
        #else
        return nil
        #endif
    }

    // @port-skip linux-only: e2e hook of the Linux proxy
    static func testUpstreamRoots() -> [NIOSSLCertificate] {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BROMURE_AC_TEST_ROOTS"],
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return (try? NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))) ?? []
        #else
        return []
        #endif
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
        // A mutating request moves /state's generation on as it starts and
        // as its response goes out (macOS: route's noteMutation pair).
        let mutating = StateGeneration.isMutating(req.method, path: req.path)
        if mutating { StateGeneration.noteMutation() }
        defer { if mutating { StateGeneration.noteMutation() } }
        let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")
        // An attached machine parks its links here, and requests aimed at it
        // go down one (DaemonMachines.swift).
        if let r = machineRoute(req, path) { return r }
        switch (req.method, path) {
        case ("GET", "/health"): return health()
        case ("GET", "/storage/defaults"): return storageDefaults()
        case ("GET", let p) where p == "/security-timeline": return await securityTimelineHistory(req.path)
        case ("GET", "/state"):
            // Only the fat client stamps its polls: it is connected, and can
            // show consent prompts (RemoteConsent.route).
            if req.headers["x-bromure-console-idle-ms"] != nil { PendingPromptBroker.recordFatClientContact() }
            return await state()
        case ("POST", let p) where p.hasPrefix("/prompts/") && p.hasSuffix("/answer"):
            return await answerPrompt(String(p.dropFirst("/prompts/".count).dropLast("/answer".count)), req.body)
        case ("GET", "/state/subscribe"): return stateSubscribe(delta: req.headers["x-bromure-state-delta"] == "1")
        case ("POST", let p) where p.hasPrefix("/sessions/") && p.hasSuffix("/tab"):
            return tabCommand(String(p.dropFirst("/sessions/".count).dropLast("/tab".count)), req.body)
        case ("POST", let p) where p.hasPrefix("/sessions/") && p.hasSuffix("/worktree"):
            return await worktreeCommand(String(p.dropFirst("/sessions/".count).dropLast("/worktree".count)), req.body)
        case ("POST", "/agent-sessions/start"): return await agentSessionCommand(nil, "start", req.body)
        case ("POST", "/agent-sessions/switchboard"): return await agentSessionCommand(nil, "switchboard", req.body)
        case ("POST", "/agent-sessions/folders"): return await workspaceRoute(req.method, req.path, req.body)!
        case ("POST", "/agent-sessions/git-state"): return await agentSessionGitState(req.body)
        case ("POST", "/agent-sessions/worktree-open"): return await agentSessionCommand(nil, "worktree-open", req.body)
        case ("POST", "/agent-sessions/worktree-discard"): return await agentSessionCommand(nil, "worktree-discard", req.body)
        case ("GET", let p) where p.hasPrefix("/agent-sessions/") && p.hasSuffix("/pending"):
            // What a session is waiting on: {question?, options?, screen}.
            guard let id = UUID(uuidString: String(p.dropFirst("/agent-sessions/".count).dropLast("/pending".count))
                .removingPercentEncoding ?? "") else { return .error(400, "Bad session id") }
            return await agentSessionPending(id)
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
        case ("POST", "/debug/sign-in-sim"): return await signInSimulator(req.body)
        case ("GET", "/profiles"): return listProfiles()
        case ("POST", "/profiles"): return await createProfile(req.body)
        case ("GET", "/vms"): return listVMs()
        case ("POST", "/vms"): return await createVMRoute(req.body)
        case (let m, let p) where p.hasPrefix("/vms/"): return await vmRoute(m, p, req.body)
        case ("GET", "/remote"): return await remoteStatus()
        case ("POST", "/remote"): return await remoteApply(req.body)
        case ("POST", "/remote/keys"): return await remoteAddKey(req.body)
        case ("POST", "/remote/code"): return remoteCode(req.body)
        case ("GET", "/remote/authorized-keys"): return await remoteAuthorizedKeys()
        case ("POST", "/remote/code/check"): return remoteCodeCheck(req.body)
        case ("GET", "/account"): return await accountStatus()
        case ("POST", "/account/sign-in"): return await accountSignIn(req.body)
        case ("POST", "/account/sign-out"): return await accountSignOut()
        case ("POST", "/account/sync"): return await accountSync()
        case ("GET", "/cloud"): return cloudStatus()
        case ("POST", "/cloud/enroll"): return await cloudEnroll(req.body)
        case ("POST", "/cloud/unenroll"): return await cloudUnenroll()
        case ("POST", "/fatclient/forward"): return await fatclientForward(req.body)
        case ("POST", let p) where p.hasPrefix("/models/"): return modelAction(p, req.body)
        case ("POST", "/fatclient/browser-mcp"): return await fatclientBrowserMCP(req.body)
        case ("DELETE", let p) where p.hasPrefix("/remote/keys/"):
            let raw = String(p.dropFirst("/remote/keys/".count))
            return await remoteRemoveKey(raw.removingPercentEncoding ?? raw)
        default:
            if let r = await boardRoute(req.method, path, req.body) { return r }
            if let r = await preferencesRoute(req.method, path, req.body) { return r }
            if let r = await subscriptionsRoute(req.method, path, req.body) { return r }
            if let r = await workspaceRoute(req.method, req.path, req.body) { return r }
            if let r = await roomsRoute(req.method, req.path, req.body) { return r }
            if let r = await traceRoute(req.method, req.path) { return r }
            if let r = await kubeRoute(req.method, path, req.body) { return r }
            return .error(404, "Not found", ["path": .string(req.path)])
        }
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/health"): h=ec3227f904b323b7 @f127f8ab
    func health() -> ControlResponse {
        ControlResponse(200, ["status": "ok", "service": "bromure-ac-automation", "debugEnabled": false])
    }

    /// `GET /security-timeline?hours=N` (default 24): this host's rows of the
    /// last N hours, for a fat client's Security window (the live mirror in
    /// /state carries only the most recent), and which run numbered them.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", let p) where p == "/security-timeline" || p.hasPrefix("/security-timeline?"): h=38a02ee17b6a23e7 @f127f8ab
    func securityTimelineHistory(_ fullPath: String) async -> ControlResponse {
        var hours = 24
        if let q = fullPath.split(separator: "?", maxSplits: 1).dropFirst().first {
            for kv in q.split(separator: "&") {
                let pair = kv.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == "hours", let h = Int(pair[1]), h >= 0 { hours = h }
            }
        }
        let (rows, epoch) = await MainActor.run { (SecurityTimeline.shared.historyRows(hours: hours), SecurityTimeline.shared.epoch) }
        return ControlResponse(200, ["rows": JSONValue(foundation: rows) ?? .array([]), "epoch": .string(epoch)])
    }

    /// `GET /storage/defaults`: the sizes a workspace made here gets when it
    /// has none of its own, for a fat client's new-workspace editor (this
    /// host's free space and setting, not the client's).
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/storage/defaults"): h=9332e5415b80ee6d @f127f8ab
    func storageDefaults() -> ControlResponse {
        ControlResponse(200, ["homeImageGB": .number(Double(newHomeDefaultGB()))])
    }

    /// `/state`: the macOS snapshot's always-present keys this host can fill
    /// (`version`, `build`, `vms`, `workspaces`, the subnet) plus `hostKind`.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/state"): h=adfaa737ba44087f @f127f8ab
    func state() async -> ControlResponse { ControlResponse(200, await cachedStateBody()) }

    /// `GET /state/subscribe`: the octet-stream header, then `/state`
    /// frames `[u32be len][u8 flag][payload]` (len counts flag + payload;
    /// flag bit 0: raw-DEFLATE compressed, when that's smaller; bit 1: a
    /// delta) whenever it changes (a running VM's uptime ticking doesn't
    /// count; frames still carry it), checked every 0.5 s, and a whole one
    /// at least every 15 s (a client resubscribes after 45 s of silence). A
    /// client that merges sections (`x-bromure-state-delta: 1`) gets, after
    /// the first whole frame, only the sections that changed
    /// (`{"set": {section: value}, "unset": [section]}`); an older one the
    /// whole state each time. One producer builds the state while anyone
    /// is subscribed (StateFeed); each subscriber only sends. Ends when a
    /// write fails; the client half-closing (the SSH bridge forwards its
    /// EOF) doesn't end it.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/state/subscribe"): h=1f85f15c8df15ffd @f127f8ab
    // @port ACAutomationServer.handleStateSubscribe(fd: Int32, delta: Bool) h=44de718c89922303 @30634ab2
    func stateSubscribe(delta: Bool = false) -> ControlResponse {
        let me = WeakDaemon(self)
        let feed = stateFeed
        return .streaming { client in
            feed.subscribe { await me.daemon?.cachedStateBody() }
            defer { feed.unsubscribe() }
            var seen = -1
            var lastSent = ContinuousClock.now - .seconds(60)
            func sendWhole() async -> Bool {
                guard let w = feed.wholeFrame() else { return true }
                do { try await client.write(ByteBuffer(bytes: w.frame)) } catch { return false }
                seen = w.seq
                lastSent = .now
                return true
            }
            while !Task.isCancelled {
                guard me.daemon != nil else { return }
                // A held push stream is a connected fat client.
                PendingPromptBroker.recordFatClientContact()
                let now = await feed.wait(after: max(seen, 0), timeout: .milliseconds(500))
                if seen < 0 || ContinuousClock.now - lastSent > .seconds(15) {
                    // The start, and a keepalive (a VM's uptime moves on in it).
                    guard await sendWhole() else { return }
                } else if now > seen {
                    if delta, let frames = feed.deltas(after: seen) {
                        for f in frames {
                            do { try await client.write(ByteBuffer(bytes: f)) } catch { return }
                        }
                        seen = now
                        lastSent = .now
                    } else {
                        guard await sendWhole() else { return }
                    }
                }
            }
        }
    }

    /// Frame: [len:u32be][flag:u8][payload], len covering flag and payload.
    /// Flag bit 0: compressed (raw DEFLATE, what macOS's `.zlib` writes),
    /// when that's smaller. Bit 1: a delta, else the whole state.
    // @port ACAutomationServer.static frame(_: Data, delta: Bool) h=e9607edbb7f0d532 @30634ab2
    static func frame(_ json: Data, delta: Bool) -> Data {
        var payload = json
        var flag: UInt8 = delta ? 2 : 0
        if let z = NPMRegistryTransforms.deflateRaw(json), z.count < json.count {
            payload = z; flag |= 1
        }
        var lenBE = UInt32(payload.count + 1).bigEndian
        var out = Data(bytes: &lenBE, count: 4)
        out.append(flag)
        out.append(payload)
        return out
    }

    /// Each top-level section as it's compared: its JSON, without the
    /// stamps that move with every request (generation, epoch) and the
    /// VMs' uptime (macOS: pushComparable).
    // @port-skip linux-only: comparableSections over JSONValue, compared as encoded bytes
    static func comparableSections(_ state: JSONValue, _ enc: JSONEncoder) -> [String: Data] {
        guard case .object(var o) = withoutUptime(state) else { return [:] }
        o["generation"] = nil
        o["epoch"] = nil
        var out: [String: Data] = [:]
        for (k, v) in o { out[k] = (try? enc.encode(v)) ?? Data() }
        return out
    }

    // @port ACAutomationServer.static changedSections(from: [String:NSObject], to: [String:NSObject]) h=09fad2eb9a7300de @30634ab2
    static func changedSections(from old: [String: Data], to new: [String: Data]) -> (set: [String], unset: [String]) {
        let set = new.compactMap { k, v in old[k] == v ? nil : k }.sorted()
        let unset = old.keys.filter { new[$0] == nil }.sorted()
        return (set, unset)
    }

    /// What changed, with the stamps that move on every build (a client
    /// orders snapshots by them).
    // @port ACAutomationServer.static deltaFrame(snapshot: [String:Any], set: [String], unset: [String]) h=9fdc0f7b359c0c64 @30634ab2
    static func deltaFrame(snapshot: JSONValue, set: [String], unset: [String], _ enc: JSONEncoder) -> Data? {
        guard case .object(let o) = snapshot else { return nil }
        var values: [String: JSONValue] = [:]
        for k in set { values[k] = o[k] }
        for k in ["generation", "epoch"] { if let v = o[k] { values[k] = v } }
        let delta: JSONValue = ["set": .object(values), "unset": .array(unset.map(JSONValue.string))]
        return (try? enc.encode(delta)).map { frame($0, delta: true) }
    }

    /// A VM's `/state` / `/vms` entry: the record, and for a running VM what
    /// macOS's entry carries: its workspace's fields (tool, folders, network
    /// mode, base image, cluster), its disk, and what its agentd reports in
    /// the outbox: the tab roster (a fat client mounts a terminal once it's
    /// non-empty: tmux is up), its vitals, its listening ports and its
    /// docker state (GuestOutboxReports, as macOS's outbox poll reads them).
    // partial: no fusion fields (fusionConfigurable/fusionEngaged: no fusion on Linux)
    // @port-skip linux-only: the per-VM half of ACAppDelegate.automationVMList (VMRecord.json, GuestOutbox)
    func vmEntry(_ rec: VMRecord) -> JSONValue {
        guard case .object(var o) = rec.json else { return rec.json }
        o["attached"] = false                         // no attached pane on Linux
        guard rec.state == .running else { o["tabs"] = []; return .object(o) }
        let outbox = vmDir(rec.id) + "/outbox/"
        o["tabs"] = .array(GuestOutbox.parseRoster(GuestOutbox.read(outbox + "tabs.txt") ?? "").map(GuestOutbox.tabJSON))
        for (k, v) in GuestOutbox.vitalsJSON(GuestOutbox.read(outbox + "vmstat.txt") ?? "") { o[k] = v }
        o["guestUnresponsive"] = .bool(guestSilent.contains(rec.id))
        o["kubeClusterID"] = .string(rec.kube ?? "")
        if let p = existingProfile(for: rec) {
            o["tool"] = .string(p.tool.rawValue)
            o["mounts"] = .array(p.folderPaths.map(JSONValue.string))
            o["networkMode"] = .string(p.networkMode.rawValue)
            o["baseImageVersion"] = .string(p.baseImageVersionAtClone ?? "unknown")
        }
        let disk = vmDir(rec.id) + "/disk.raw"
        var st = stat()
        o["diskPath"] = .string(disk)
        o["diskAllocatedBytes"] = .number(stat(disk, &st) == 0 ? Double(st.st_blocks) * 512 : 0)
        for (k, v) in Self.outboxReports(outbox) { o[k] = v }
        return .object(o)
    }

    /// The guest's listening ports and docker state from its outbox, as
    /// macOS's entry carries them (RunningSession's mirrors: a container's
    /// stats and arch merged by short id).
    // @port-skip linux-only: RunningSession.listeningPorts / dockerContainers… mirrors, read from the outbox per entry
    static func outboxReports(_ outbox: String) -> [String: JSONValue] {
        func read(_ name: String) -> String { GuestOutbox.read(outbox + name) ?? "" }
        let stats = Dictionary(GuestOutboxReports.dockerStats(read("docker-stats.txt")).map { (String($0.id.prefix(12)), $0) },
                               uniquingKeysWith: { a, _ in a })
        let arch = Dictionary(GuestOutboxReports.dockerArch(read("docker-arch.txt")).map { (String($0.id.prefix(12)), $0.arch) },
                              uniquingKeysWith: { a, _ in a })
        let containers = GuestOutboxReports.dockerContainers(read("docker.txt")).map { c -> JSONValue in
            var c = c
            if let s = stats[c.shortID] { c.cpuPerc = s.cpu; c.memUsage = s.mem }
            if let a = arch[c.shortID] { c.arch = a }
            return ["id": .string(c.id), "name": .string(c.name), "image": .string(c.image), "status": .string(c.status),
                    "state": .string(c.state), "ports": .string(c.ports), "runningFor": .string(c.runningFor),
                    "mounts": .string(c.mounts), "cpuPerc": .string(c.cpuPerc), "memUsage": .string(c.memUsage),
                    "arch": .string(c.arch)]
        }
        return [
            "listeningPorts": .array(GuestOutboxReports.listeningPorts(read("ports.txt")).map {
                ["proto": .string($0.proto), "addr": .string($0.addr), "port": .number(Double($0.port)),
                 "process": .string($0.process)]
            }),
            "dockerContainers": .array(containers),
            "dockerImages": .array(GuestOutboxReports.dockerImages(read("docker-images.txt")).map {
                ["id": .string($0.id), "repository": .string($0.repository), "tag": .string($0.tag),
                 "size": .string($0.size), "created": .string($0.created)]
            }),
            "dockerVolumes": .array(GuestOutboxReports.dockerVolumes(read("docker-volumes.txt")).map {
                ["name": .string($0.name), "driver": .string($0.driver), "mountpoint": .string($0.mountpoint),
                 "createdAt": .string($0.createdAt), "size": .string($0.size)]
            }),
            "dockerBinfmt": .array(GuestOutboxReports.dockerBinfmt(read("docker-binfmt.txt")).map(JSONValue.string)),
        ]
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
        let mitmProxy = mitm
        let (prompts, sessionEntries, statuses) = await MainActor.run {
            for (id, roster) in rosters { LinuxSessionHost.shared?.updateRoster(id, roster) }
            return (PendingPromptBroker.shared.pendingList(), (SessionStores.shared?.stateEntries() ?? [:]).merging(SessionStores.shared?.boardStateEntries() ?? [:]) { a, _ in a }
                .merging([
                    "subscriptions": JSONValue(foundation: Daemon.subscriptionStatus(mitm: mitmProxy)) ?? .object([:]),
                    "securityTimeline": JSONValue(foundation: Daemon.securityTimelineRows()) ?? .array([]),
                    // The oldest row this host still holds: a fat client drops
                    // fetched history older than that (the host pruned it).
                    "securityTimelineOldest": SecurityTimeline.shared.oldestRetained
                        .map { .number($0.timeIntervalSince1970) } ?? .null,
                    // The same, in the host's own order (a clock set back makes
                    // times go backwards): its first row's number, and whose.
                    "securityTimelineOldestSeq": SecurityTimeline.shared.oldestRetainedSeq
                        .map { .number(Double($0)) } ?? .null,
                    "securityTimelineEpoch": .string(SecurityTimeline.shared.epoch),
                    "kubeClusters": JSONValue(foundation: SessionStores.shared?.kube.snapshot() ?? ["clusters": [], "status": [:]]) ?? .object([:]),
                ]) { a, _ in a },
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
        let body: [String: JSONValue] = [
            "version": 1, "hostKind": "linux",
            "build": ["version": .string(BuildInfo.version)],
            "vms": .array(vms), "workspaces": .array(all.filter { !$0.managed }.map(compromisedRow)),
            "workspacesListed": true,
            "supportsPush": true,
            "vmnetSubnet": .string(Self.workspaceSubnet.withLockedValue { $0 }),
            "vmnetGateway": .string(passt.config.gateway),
            "uplink": ["kind": "passt", "mtu": .number(Double(passt.mtu))],
            "secretsKeySource": SecretsVault.masterKeySource.map { .string($0.rawValue) } ?? .null,
            "pendingPrompts": JSONValue(foundation: prompts) ?? .array([]),
            "localModels": Self.localModels(),
            // A server has no window, so no grid (macOS without a window).
            "gridLayout": ["cells": .array([])],
            // Ordering for clients: the generation grows within one daemon
            // run, the epoch says which run.
            "generation": .number(Double(StateGeneration.current)),
            "epoch": .string(StateGeneration.epoch),
        ].merging(sessionEntries) { a, _ in a }
        return .object(Self.withMachines(body))
    }

    // partial: entries lack fusion fields (no fusion on Linux)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/vms"): h=b80678b83121852e @f127f8ab
    func listVMs() -> ControlResponse {
        let machines = JSONValue(foundation: MachineLinkHub.shared.stateAdditions().vms) ?? .array([])
        guard case .array(let more) = machines else { return ControlResponse(200, ["vms": .array(records.map(vmEntry))]) }
        return ControlResponse(200, ["vms": .array(records.map(vmEntry) + more)])
    }

    /// Whether a new VM may not have `cid`: another record has it, or has
    /// the MAC it would give. A stopped VM keeps both across daemon restarts
    /// (the allocator knows only this process's leases), and keeps its MAC
    /// when a start moves it to a fresh CID; the MAC is its identity on the
    /// switch and in the DHCP.
    // @port-skip linux-only: Linux VM identity
    static func identityTaken(by records: [VMRecord]) -> (UInt32) -> Bool {
        let cids = Set(records.map(\.cid)), macs = Set(records.map { $0.mac.lowercased() })
        return { cids.contains($0) || macs.contains(mac(forCID: $0)) }
    }

    /// A taken-back workspace's proxy state, as its launch set it up: the
    /// swap map (Daemon.kubeconfig: the plan's fakes, minted credentials,
    /// setMinted, kube trust, exec pollers, 1Password), the AWS credential
    /// server and the SSH agent's key. The guest's files are left as they
    /// are (its kubeconfig: start's refresh).
    // @port-skip linux-only: a restarted daemon's share of ACAppDelegate.launch's proxy wiring
    func setUpWorkspaceCredentials(_ profile: Profile, meta: String) async {
        guard let mitm else { return }
        _ = await kubeconfig(for: profile, plan: sessionTokenPlan(for: profile))
        pushAWSCredentials(for: profile, meta: meta)
        // Its agent died with the previous daemon: a new one, keys and all.
        await loadWorkspaceSSHKeys(profile)
        mitm.applyWorkspacePolicies(profile)
    }

    /// Why a VM may not launch with `plan`: a workspace's needs one (no proxy
    /// would hand its credentials to the guest as they are); a sign-in VM
    /// has none by design.
    // @port-skip linux-only: the Linux launch's proxy gate
    static func launchRefusal(registration: Bool, plan: SessionTokenPlan?) -> String? {
        guard !registration, plan == nil else { return nil }
        return "this server's intercepting proxy isn't running (its CA in the state dir didn't load); "
            + "a workspace can't start without it: its credentials would reach the VM as they are"
    }

    /// The profile the guest's credential environment is built from: as it
    /// is with a plan (its fakes), stripped of every secret without one (a
    /// sign-in VM's), so no real value can fall through to the guest.
    // @port-skip linux-only: the Linux launch's proxy gate
    static func envProfile(_ profile: Profile, plan: SessionTokenPlan?) -> Profile {
        guard plan == nil else { return profile }
        var p = profile
        _ = ProfileSecrets.extract(stripping: &p)
        return p
    }

    /// A new VM's MAC, from its CID at creation (it keeps it after).
    // @port-skip linux-only: Linux VM identity
    static func mac(forCID cid: UInt32) -> String {
        String(format: "52:54:00:%02x:%02x:%02x", cid >> 16 & 0xFF, cid >> 8 & 0xFF, cid & 0xFF)
    }

    /// A VM record made, and started, detached. Body: `name?`,
    /// `machine?` (firecracker), `memoryGB?`, `cpus?`, `homeGB?`. 201
    /// `{id, shortId, name, detached}`. `id`: a workspace Profile's (POST
    /// /profiles, POST /vms), else a new one; `boot` false only registers
    /// it (stopped).
    // @port-skip linux-only: a Linux VM record (macOS: the workspace's launch makes its VM)
    func createVM(_ body: JSONValue, id fixedID: String? = nil, boot: Bool = true,
                  registration: Bool = false, kube: String? = nil, dataDiskGB: Int? = nil,
                  folders: [String]? = nil, rescueFor: String? = nil) async -> ControlResponse {
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
        guard let cid = try? CIDAllocator.shared.allocate(skip: Self.identityTaken(by: registry.records))
        else { return .error(503, "No free vsock CID") }
        let mac = Self.mac(forCID: cid)
        var rec = VMRecord(id: id, name: name, machine: machine, cid: cid, mac: mac, state: .starting, ip: nil,
                           cpus: cpus, memoryMiB: memMiB, createdAt: Date(), bootedAt: nil, statePath: nil)
        rec.homeGB = homeGB
        if registration { rec.registration = true }
        rec.kube = kube
        rec.dataDiskGB = dataDiskGB
        rec.folders = folders?.isEmpty == true ? nil : folders
        rec.rescueFor = rescueFor
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
            if let refusal = Self.launchRefusalResponse(error) { return refusal }
            return .error(500, "Failed to create VM: \(error)")
        }
    }

    // partial: no attach (a server has no pane); fusion is refused (no Fusion in the Linux proxy)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p.hasPrefix("/vms/"): h=343ebd5280ded291 @f127f8ab
    func vmRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse {
        let parts = path.dropFirst("/vms/".count).split(separator: "/", maxSplits: 1).map(String.init)
        let sub = parts.count > 1 ? parts[1] : ""
        guard let raw = parts.first, let key = raw.removingPercentEncoding,
              let rec = registry.find(key) else {
            // A client tells the type route from an older server's 404 by
            // its "typeRoute" mark: an unknown VM is just unreachable.
            if method == "POST", sub == "type" {
                return await typeRoute(nil, body, key: parts.first?.removingPercentEncoding)
            }
            return .error(404, "VM not found")
        }
        switch (method, sub) {
        case ("GET", ""): return getVM(rec)
        case ("DELETE", ""): return await deleteVM(rec, action: body["action"]?.stringValue ?? "shutdown")
        case ("POST", "exec"): return await exec(rec, body)
        case ("POST", "resume"): return await start(rec, body, resumeOnly: true)
        case ("POST", "suspend"): return await suspend(rec)
        case ("POST", "start"): return await start(rec, body)
        case ("POST", "remove"): return remove(rec)
        case ("POST", "file"): return await guestFileRoute(rec, body)
        case ("POST", "reboot"): return await rebootRoute(rec, body)
        case ("POST", "model"): return await setModelRoute(rec, body)
        case ("POST", "docker"): return dockerRoute(rec, body)
        case ("POST", "type"): return await typeRoute(rec, body)
        case ("POST", "routing"): return await routingRoute(rec, body)
        case ("POST", "fusion"): return fusionRoute(rec)
        case ("GET", "checkpoints"): return checkpointsRoute(rec)
        case ("POST", "revert"): return revertRoute(rec, body)
        case ("POST", "fsck"): return await fsckRoute(rec, body)
        default: return .error(405, "Method not allowed")
        }
    }

    // partial: the entry has no fusion fields (vmEntry)
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "GET": h=a05dae914d2f170b @7dd92fdf
    func getVM(_ rec: VMRecord) -> ControlResponse { ControlResponse(200, vmEntry(withIP(rec))) }

    /// The record's machine type: Firecracker is the only backend.
    static let machineType = "firecracker"

    /// Where a suspended VM's snapshot is kept (`vm.snap`, `vm.mem`, and the
    /// disks' identities beside `vm.snap`).
    // @port-skip linux-only: Linux daemon VM layout
    func snapshotDir(_ id: String) -> String { vmDir(id) + "/snapshot" }

    /// Suspend: a full snapshot of the running VM (its virtiofsds' state with
    /// it), its two disks' identities recorded, then the VM ends suspended.
    /// The RAM snapshot needs room: below the free-space floor the suspend
    /// is refused (409, why) before anything is touched, and the VM keeps
    /// running (macOS: stopSession's floor check).
    // @port-skip linux-only: Firecracker snapshot suspend (macOS: requestStopSession(.suspend) saves VZ state)
    func suspend(_ rec: VMRecord, floor: UInt64 = EphemeralDisk.minimumFreeBytes) async -> ControlResponse {
        guard let l = live[rec.id] else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        if let why = Self.suspendRefusal(vmDir: vmDir(rec.id), floor: floor) {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': suspend refused: \(why)\n".utf8))
            return .error(409, why)
        }
        explicitStops.insert(rec.id)
        let dir = snapshotDir(rec.id)
        try? FileManager.default.removeItem(atPath: dir)
        do {
            try await l.machine.snapshot(into: dir)
            let state = dir + "/vm.snap"
            try SnapshotIdentity.of(overlay: l.config.overlay).write(forState: state)
            try SnapshotIdentity.of(overlay: vmDir(rec.id) + "/home.img").write(forState: state, disk: 1)
        } catch {
            // A VM the snapshot ended (a refusal past the rings' stop) is
            // stopped: no half state is kept.
            if live[rec.id] == nil { try? FileManager.default.removeItem(atPath: dir) } else { explicitStops.remove(rec.id) }
            return .error(500, "Suspend failed: \(error)")
        }
        await vmStopped(rec.id, await l.machine.waitUntilStopped())
        return ControlResponse(200, ["status": "suspended"])
    }

    /// Why a suspend can't save its RAM snapshot under `vmDir` now (under
    /// the free-space floor), or nil.
    // @port-skip linux-only: stopSession's suspend floor check, testable
    static func suspendRefusal(vmDir: String, floor: UInt64 = EphemeralDisk.minimumFreeBytes) -> String? {
        do { try EphemeralDisk.checkDiskSpace(at: vmDir, minimumFreeBytes: floor) } catch { return error.localizedDescription }
        return nil
    }

    /// The snapshot in `dir` still pairs with the VM's disks.
    // @port-skip linux-only: snapshot identity for both disks
    func snapshotUsable(_ rec: VMRecord, _ dir: String) -> String? {
        let state = dir + "/vm.snap"
        guard FileManager.default.fileExists(atPath: state), FileManager.default.fileExists(atPath: dir + "/vm.mem") else {
            return "no saved state"
        }
        do {
            try SnapshotIdentity.verify(state: state, overlay: (try machineConfig(rec)).overlay)
            try SnapshotIdentity.verify(state: state, overlay: vmDir(rec.id) + "/home.img", disk: 1)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// `DELETE /vms/{id}` with `{"action": "shutdown"|"suspend"|"kill"}`; a
    /// suspend refused for lack of disk space is a 409 saying so (the VM
    /// still runs).
    // @port ACAutomationServer.handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "DELETE": h=3801d3e89fa37bfb @f127f8ab
    /// `partOfReboot`: the reboot's own stop (not one a client asked for).
    func deleteVM(_ rec: VMRecord, action: String, partOfReboot: Bool = false) async -> ControlResponse {
        if action == "suspend" { return await suspend(rec) }
        // Asked during a reboot: that reboot boots nothing (stoppedDuringReboot).
        if rebooting.contains(rec.id), !partOfReboot { stopsDuringReboot.insert(rec.id) }
        // A suspended VM shut down: its saved state goes, it's stopped.
        if live[rec.id] == nil, rec.state == .suspended {
            try? FileManager.default.removeItem(atPath: snapshotDir(rec.id))
            var r = rec
            r.state = .stopped
            try? registry.upsert(r)
            // A `--rm` workspace left suspended is over now.
            if let pid = UUID(uuidString: rec.id) { await dropAbandonedEphemeral(pid) }
            return ControlResponse(200, ["status": "stopped"])
        }
        // Already ending (its guest's own exit got there first): the user's
        // stop still wins over a reboot's relaunch.
        if let t = stopping[rec.id] {
            explicitStops.insert(rec.id)
            await t.value
            // That end was a suspend's: the suspended VM's own stop.
            if let now = registry.find(rec.id), now.state == .suspended { return await deleteVM(now, action: action, partOfReboot: partOfReboot) }
            return ControlResponse(200, ["status": "stopped"])
        }
        // Between a reboot's stop and its boot (or during that boot; a boot
        // remedy's too, its disk held meanwhile): it stays off (the relaunch
        // checks, stoppedDuringReboot; macOS: whileHoldingDisk's stop).
        if live[rec.id] == nil, rebooting.contains(rec.id) {
            return ControlResponse(200, ["status": "stopped"])
        }
        guard let l = live[rec.id] else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        explicitStops.insert(rec.id)
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

    /// Why `rec` may not be started now, or nil: not stopped or suspended, a
    /// QEMU machine, or a cluster machine whose disks the host is repairing
    /// (marked, or a rescue for it still on record: `rescued`), or one a
    /// reboot is between its stop and its boot (`rebooting`: the reboot boots
    /// it itself; a disk remedy may be working on it).
    // @port-skip linux-only: start's guards (testable)
    static func startRefusal(_ rec: VMRecord, repairing: RepairMarks, rescued: Bool = false, rebooting: Bool = false) -> ControlResponse? {
        guard rec.state == .stopped || rec.state == .suspended else {
            return .error(409, "VM '\(rec.name)' is \(rec.state.rawValue)", ["state": .string(rec.state.rawValue)])
        }
        guard rec.machine == machineType else {
            return .error(409, "'\(rec.name)' was made for QEMU, which is gone: remove it (vm rm) and create a new one")
        }
        guard !repairing.contains(rec.id), !rescued else {
            return .error(409, "'\(rec.name)' is having its disks repaired; start it once that's done")
        }
        guard !rebooting else {
            return .error(409, "'\(rec.name)' is rebooting: it boots again by itself")
        }
        return nil
    }

    /// `POST /vms/{id}/start` (Linux): boot a stopped VM again, on its own
    /// overlay and home image.
    // @port-skip linux-only: macOS starts a VM by starting its workspace again; Linux VMs are the workspaces for now
    /// `partOfReboot`: the reboot's own boot (its relaunch, the reboot route,
    /// a boot remedy), the one start a rebooting VM takes.
    /// `unattended`: nobody is there to ask (an agent's or automation's
    /// start): a launch question isn't asked (DaemonBaseImageDrift.swift).
    func start(_ rec: VMRecord, _ body: JSONValue = .object([:]), resumeOnly: Bool = false, partOfReboot: Bool = false,
               unattended: Bool = false, driftResolved: Bool = false) async -> ControlResponse {
        // A workspace made private (a clone of a private one, a save just
        // now) is in the private set before its VM can emit anything. First:
        // the checks below and the starting mark take one actor step.
        if rec.registration != true { await refreshStreamingNow() }
        if let refusal = Self.startRefusal(rec, repairing: repairMarks, rescued: hasRescue(for: rec.id),
                                           rebooting: rebooting.contains(rec.id) && !partOfReboot) { return refusal }
        // A workspace marked compromised boots only once the mark is gone
        // (macOS: launch's compromised-disk check).
        if !rec.managed, let p = existingProfile(for: rec), Self.isCompromised(p, store: profileStore) {
            return .error(409, "'\(rec.name)' is marked compromised (a credential was sent to the wrong host): "
                          + "clear the mark (POST /profiles/<id>/compromised {\"action\":\"clear\"}) or remove it",
                          ["compromised": .bool(true)])
        }
        // A cold boot of a workspace on an older base: the upgrade offer
        // (macOS: launch's drift check). The question waits on the user, so
        // the start then runs again on the record as it is now.
        if !driftResolved, !partOfReboot, !resumeOnly, rec.state == .stopped, !rec.managed {
            if let stop = await resolveDriftPrompt(rec, unattended: unattended) { return stop }
            guard let now = registry.find(rec.id) else { return .error(404, "VM '\(rec.name)' was removed") }
            return await start(now, body, unattended: unattended, driftResolved: true)
        }
        // Marked in the same actor step as the check, before any await: a
        // repair (kubeMachineDiskImages) or a remove sees the VM as busy
        // until launch has it live, or failed.
        guard starting.insert(rec.id).inserted else {
            return .error(409, "VM '\(rec.name)' is already starting")
        }
        defer { starting.remove(rec.id) }
        var r = rec
        // `homeGB`: a new home size, applied by this cold boot. Images don't shrink.
        if let gb = body["homeGB"]?.numberValue.map({ min(1024, max(8, Int($0))) }) {
            var st = stat()
            if stat(vmDir(rec.id) + "/home.img", &st) == 0, UInt64(gb) << 30 < UInt64(st.st_size) {
                return .error(400, "'\(rec.name)' has a \(UInt64(st.st_size) >> 30) GiB home image; home images don't shrink")
            }
            r.homeGB = gb
        }
        // A suspended VM resumes from its snapshot while it still pairs with
        // its disks; otherwise `resume` refuses and `start` boots it fresh.
        var restoreFrom: String?
        if rec.state == .suspended {
            let dir = snapshotDir(rec.id)
            if let why = snapshotUsable(rec, dir) {
                if resumeOnly { return .error(409, "Can't resume '\(rec.name)': \(why); start it instead") }
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': saved state not used (\(why)); booting fresh\n".utf8))
                try? FileManager.default.removeItem(atPath: dir)
            } else {
                restoreFrom = dir
            }
        } else if resumeOnly {
            return .error(409, "VM '\(rec.name)' isn't suspended", ["state": .string(rec.state.rawValue)])
        }
        if !CIDAllocator.shared.claim(rec.cid) {
            // The snapshot's vsock device keeps its CID.
            if restoreFrom != nil { return .error(503, "VM '\(rec.name)''s vsock CID \(rec.cid) is taken; can't resume it") }
            let others = Set(registry.records.filter { $0.id != rec.id }.map(\.cid))
            guard let fresh = try? CIDAllocator.shared.allocate(skip: { others.contains($0) }) else {
                return .error(503, "No free vsock CID")
            }
            r.cid = fresh
        }
        if let dir = restoreFrom {
            // The resume runs on a copy of the memory (free with reflinks):
            // the snapshot survives a resume that fails.
            let live = dir + "/" + FirecrackerMachine.liveMemoryFile
            try? FileManager.default.removeItem(atPath: live)
            do {
                try await ChildProcess.run("/usr/bin/cp", ["--reflink=auto", "--sparse=always", dir + "/vm.mem", live])
            } catch {
                CIDAllocator.shared.release(r.cid)
                return .error(500, "Can't resume '\(rec.name)': copying its memory failed: \(error)")
            }
            restoring.insert(rec.id)
        }
        defer { restoring.remove(rec.id) }
        do {
            try await launch(&r, restoreFrom: restoreFrom)
            return ControlResponse(200, ["status": "running"])
        } catch {
            CIDAllocator.shared.release(r.cid)
            if let dir = restoreFrom {
                // Still suspended, its snapshot as it was: a retry, or a
                // fresh start, is the user's call.
                try? FileManager.default.removeItem(atPath: dir + "/" + FirecrackerMachine.liveMemoryFile)
                var s = registry.find(rec.id) ?? rec
                s.state = .suspended
                try? registry.upsert(s)
                if let refusal = Self.launchRefusalResponse(error) { return refusal }
                return .error(500, "Resume failed (still suspended; resume again, or start it fresh with stop then start): \(error)")
            }
            if let refusal = Self.launchRefusalResponse(error) { return refusal }
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
        // Its files are in use: the disk checker holds them, or a start is
        // building on them.
        guard !repairMarks.contains(rec.id), !starting.contains(rec.id), !hasRescue(for: rec.id) else {
            return .error(409, "VM '\(rec.name)' is \(starting.contains(rec.id) ? "starting" : "having its disks repaired"); remove it once that's done")
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
    // partial: no dead-pool flush-and-retry beyond GuestShell's pre-write skip
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
    /// CLI and agentd's pty) until either side closes, but for the consent
    /// prompts a terminal gate shows the user in between (ConsentPump).
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
        // A GUI-fronted attach (a fat client's terminal) gets its consent
        // prompts from the fat client, never in this terminal: no gate, so
        // RemoteConsent.route doesn't see it attached. A plain CLI/SSH attach
        // registers one for its life, keyed by the workspace's UUID as the
        // consent brokers ask for it.
        let guiConsent = body["guiConsent"] == .bool(true)
        let attachKey = UUID(uuidString: rec.id)?.uuidString ?? rec.id
        FileHandle.standardError.write(Data(
            "[consent] interactive attach pid=\(attachKey.prefix(8)) guiConsent=\(guiConsent) → \(guiConsent ? "no terminal gate (fat client)" : "terminal consent gate")\n".utf8))
        let shell = l.shell
        return .streaming { client in
            let gate = guiConsent ? nil : ACAutomationServer.PumpConsentGate()
            if let gate { ACAutomationServer.registerGate(gate, for: attachKey) }
            defer { if let gate { ACAutomationServer.unregisterGate(gate, for: attachKey) } }
            _ = try? await conn.withStreams { inbound, outbound in
                var head = ByteBuffer()
                head.writeInteger(UInt32(reqData.count))
                head.writeBytes(reqData)
                try await outbound.write(head)
                await ConsentPump.run(client: client.inbound, toClient: { try await client.write($0) },
                                      guest: inbound, toGuest: { try await outbound.write($0) },
                                      gate: gate, afterConsent: {
                    // Repaint the guest's tmux over where the prompt was: a
                    // tmux command, not pane input (no keystrokes into the agent).
                    _ = try? await shell.exec("tmux refresh-client 2>/dev/null || true", timeout: 5, wait: .seconds(5))
                })
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
    private func launch(_ rec: inout VMRecord, restoreFrom: String? = nil) async throws {
        // A protection this server can't enforce refuses the launch (DaemonSandboxGuard.swift).
        try await refuseUnenforceableSandbox(rec)
        // A shared server's daemon can't see a workspace folder under /home.
        if let hidden = hiddenSharedFolders(rec) { throw hidden }
        do {
            try await launchVM(&rec, restoreFrom: restoreFrom)
        } catch {
            // What it set up for the proxy goes with it, as a stop's does
            // (a live refresh under way first, as finishStop waits for it).
            await liveRefreshTail.removeValue(forKey: rec.id)?.value
            liveApplied[rec.id] = nil
            if let pid = UUID(uuidString: rec.id) { await clearWorkspaceProxyState(pid) }
            throw error
        }
    }

    /// A VM's state in the proxy, gone with the VM (finishStop) or with a
    /// launch that failed: its trace session, SSH keys, static and minted
    /// AWS keys (macOS: MitmEngine.unregister), prompt-injection policy,
    /// swap map and kube trust, and its local engine route.
    // @port-skip linux-only: the Linux share of macOS's cleanupSessionRegistrations and MitmEngine.unregister
    func clearWorkspaceProxyState(_ pid: UUID) async {
        // macOS: cleanupSessionRegistrations' clearSessionTrace.
        mitm?.clearSessionTrace(for: pid)
        mitm?.sshAgent.clearKeys(for: pid)
        mitm?.awsCreds.clearCredentials(for: pid)
        AWSSSORefusals.set(false, for: pid)
        ssoRefreshTasks.removeValue(forKey: pid)?.cancel()
        mitm?.clearWorkspacePolicies(pid)
        if let mitm { await MainActor.run { mitm.clearKube(for: pid) } }
        // Its swap map, and the destinations a compromise alert's "Allow"
        // trusted for the session (macOS: MitmEngine.unregister's clearMap).
        mitm?.swapper.clearMap(for: pid)
        InferenceRepairProxy.shared.setExternalEngine(pid, nil)
        // "Allow for the rest of the session" ends with the session, for every
        // consent broker, and the imported-key approvals and host-agent keys
        // with it (macOS: MitmEngine.unregister).
        // A quarantine ends with its session (the next one starts unquarantined
        // unless the restart's re-ask quarantines it again).
        WorkspaceQuarantine.shared.set(false, for: pid)
        mitm?.sshAgent.clearImportedKeyApprovals(for: pid)
        mitm?.sshAgent.clearHostAgentKeys(for: pid)
        // Its own key out of its agent first, best effort (macOS:
        // cleanupSessionRegistrations' removeKeyFromHostAgent); then the
        // agent itself: the imported keys exist only in that process
        // (macOS: MitmEngine.unregister's terminateSSHAgent).
        let store = profileStore
        if mitm != nil, let profile = store.loadAll().first(where: { $0.id == pid }) {
            for key in Self.loadAgentKeys(for: profile, store: store) {
                MitmProxy.removeKeyFromHostAgent(publicKey: key.publicKey, profileID: pid)
            }
        }
        mitm?.terminateSSHAgent(for: pid)
        // The attestor's channel goes with the session (macOS: detach at teardown).
        BinaryIdentityService.shared.dropBridge(pid)?.stop()
        // The kernel sentry's too (macOS: KernelSentryService.detach at teardown).
        KernelSentryService.shared.dropBridge(pid)?.closeChannel()
        // The watchdog's window and baseline start over with the next session,
        // and no question holds the VM any more.
        AgentWatchdog.shared.reset(profileID: pid)
        clearPauseHolds(pid.uuidString.lowercased())
        lastStagedProfiles[pid.uuidString.lowercased()] = nil
        watchdogAsking.remove(pid.uuidString.lowercased())
        Self.clearQuarantineMark(vmDir(pid.uuidString.lowercased()))
        if let mitm {
            await mitm.consent.revokeAll(profileID: pid)
            await mitm.consent.clearProfileName(for: pid)
            await mitm.guardrailsBroker.revokeAll(profileID: pid)
            await mitm.guardrailsBroker.clearProfileName(for: pid)
            await mitm.supplyChainBroker.revokeAll(profileID: pid)
            await mitm.supplyChainBroker.clearProfileName(for: pid)
        }
    }

    // @port-skip linux-only: Linux daemon VM lifecycle
    private func launchVM(_ rec: inout VMRecord, restoreFrom: String? = nil) async throws {
        if let hook = Self.launchHookForTesting.withLockedValue({ $0 }) { try await hook(rec.id) }
        let dir = vmDir(rec.id)
        let run = config.runtimeDir + "/vms/" + rec.shortId
        let fm = FileManager.default
        for sub in [dir + "/meta/virtiofs-tags", run] {
            try fm.createDirectory(atPath: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // 0777 as on macOS: every guest uid (the workspace's, a run_as user's)
        // writes there through plain DAC. The VM directory above it stays 0700.
        try HomeSeed.prepareOutboxDirectory(URL(fileURLWithPath: dir + "/outbox"), forRestore: restoreFrom != nil)
        try? fm.removeItem(atPath: dir + "/meta/bromure-agentd.py")
        try fm.copyItem(atPath: config.agentdPath, toPath: dir + "/meta/bromure-agentd.py")
        for tag in ["bromure-meta", "bromure-outbox"] + shareFolders(rec).indices.map({ "share-\($0 + 1)" }) {
            _ = fm.createFile(atPath: dir + "/meta/virtiofs-tags/" + tag, contents: nil)
        }
        try writeSharesFile(rec, meta: dir + "/meta")
        // The guest MTU rule (PasstUplink.Config.mtu): 65520 behind passt;
        // VPN profiles keep the macOS 1280/1400 (no profiles on Linux yet).
        try "\(passt.mtu)\n".write(toFile: dir + "/meta/mtu", atomically: true, encoding: .utf8)
        // The home: a sparse raw image as the second disk (vdb), kept across
        // stop/start and suspend/resume, deleted with the VM. agentd sees
        // `home.mode` ext4, mkfs's the blank disk on first boot (label
        // bromure-home) and mounts it over /home/ubuntu, as on macOS.
        let home = dir + "/home.img"
        let target = Self.homeImageTargetBytes(gb: rec.homeGB,
                                               defaultGB: Self.resolvedHomeImageGB(override: config.homeImageOverrideGB,
                                                                                   freeBytes: Self.freeBytes(near: dir)))
        try Self.ensureHomeImage(atPath: home, bytes: target)
        // A size change lands at a boot (agentd's resize2fs grows the mounted ext4).
        let homeNote = try Self.growHomeImageIfNeeded(atPath: home, target: target, setting: rec.homeGB)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': \(homeNote)\n".utf8))
        // The guest's hostname (agentd's task_apply_hostname), from the VM's name.
        try (Self.sanitizeHostname(rec.name) + "\n").write(toFile: dir + "/meta/hostname.txt", atomically: true, encoding: .utf8)
        // The host's time zone (agentd's task_set_timezone applies it), read
        // again each launch so a change on the host is reflected, as on macOS.
        try (TimeZone.current.identifier + "\n").write(toFile: dir + "/meta/tz", atomically: true, encoding: .utf8)
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
        // The workspace as it is stored, for the live refresh to tell what a
        // later edit changed (macOS: the session's captured profile).
        let raw = rec.managed ? nil : existingProfile(for: rec)
        let staged = await launchProfile(for: rec, mcpTokens: true)
        var launchPlan: SessionTokenPlan?
        if let profile = staged {
            let store = profileStore
            // The stand-ins the proxy turns into the real logins (Claude's in
            // the token plan, Codex's file beside the seed's), as macOS seeds them.
            // A sign-in VM has none and no swap map: the real OAuth
            // handshake reaches upstream untouched (macOS: tokenPlan nil).
            let plan = rec.registration == true ? nil : sessionTokenPlan(for: profile)
            launchPlan = plan
            // No plan means no proxy (its CA didn't load): every credential
            // would reach the guest as itself. macOS always has one.
            if let why = Self.launchRefusal(registration: rec.registration == true, plan: plan) {
                throw MachineError.invalidConfig(why)
            }
            // A new session: no swap map or "Allow"ed destination from the last.
            if rec.registration != true, let pid = UUID(uuidString: rec.id) { mitm?.swapper.clearMap(for: pid) }
            // A Kimi record without its managed config is provisioned first
            // (macOS: launch's kimiNeedsProvisioning gate).
            if rec.registration != true { await provisionKimiIfNeeded(profile) }
            let kubeYAML = rec.registration == true ? nil : await kubeconfig(for: profile, plan: plan)
            try writeCredentialFiles(profile, plan: plan, registration: rec.registration == true,
                                     meta: meta, kubeYAML: kubeYAML)
            if rec.registration != true {
                pushAWSCredentials(for: profile, meta: meta.path)
                // The workspace's SSH keys, signing for the guest through the
                // host's agents: its own, the imported ones, those picked out
                // of host agents (macOS: launch's agent block).
                await loadWorkspaceSSHKeys(profile)
                mitm?.applyWorkspacePolicies(profile)
                // Its VM's port, governed before the VM runs (macOS: attachPort's policy).
                Self.clearQuarantineMark(vmDir(rec.id))
                sw.egress.govern(MAC(InterimSwitch.mac(rec.mac)), .init(profile))
                Self.refreshWatchdogModes()
            }
        } else {
            try HomeSeed.writeHomeSeedFiles(into: seed)
            try HomeSeed.finalizeHomeSeed(seedDir: seed)
        }
        HomeSeed.bumpGenerationCounter(named: "seed.generation", in: meta)
        let extraNoProxy = staged == nil || rec.registration == true ? [] : await kubeNoProxy(for: UUID(uuidString: rec.id) ?? UUID())
        let registries = staged == nil || rec.registration == true ? [] : await kubeRegistries(for: UUID(uuidString: rec.id) ?? UUID())
        try writeProxyMeta(meta, profile: staged, tokenPlan: launchPlan, extraNoProxy: extraNoProxy, registries: registries)
        // The agents' MCP shims (board, automations, delegation, …) and the
        // built-in browser and display servers, as macOS stages them.
        try SessionDisk.writeGuestMCPShims(into: meta)
        // A VM with a Profile got the built-ins with its MCP configs.
        if profile(for: rec) == nil { try SessionDisk.writeBuiltInMCPServers(into: meta) }

        var qc = try machineConfig(rec)
        qc.restoreFrom = restoreFrom
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
        var browser: BrowserMCPBridge?
        do {
            if rec.kube == nil {
                browser = try await MainActor.run { [qc] in
                    try BrowserMCPBridge(udsPath: qc.firecrackerVsockPath, fdStoreName: "bmcp-" + rec.shortId,
                                         profileID: UUID(uuidString: rec.id))
                }
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
        var l = Live(machine: FirecrackerMachine(config: qc), port: port, shell: shell, config: qc,
                     vsock: vsock, browser: browser, storedNet: storeName)
        l.mitm = serveProxy(rec, udsPath: qc.firecrackerVsockPath, stored: nil)
        startTraceSession(rec)
        if rec.kube == nil { l.mcp = await serveMCP(rec, udsPath: qc.firecrackerVsockPath, stored: [:]) }
        if rec.kube == nil { l.plan = await servePlanStream(rec, udsPath: qc.firecrackerVsockPath, stored: nil) }
        l.inference = serveInference(rec, udsPath: qc.firecrackerVsockPath, stored: nil)
        l.aws = serveAWSCreds(rec, udsPath: qc.firecrackerVsockPath, stored: nil)
        l.ssh = serveSSHAgent(rec, udsPath: qc.firecrackerVsockPath, stored: nil)
        l.attest = await serveAttestor(rec, profile: staged, udsPath: qc.firecrackerVsockPath, stored: nil,
                                       restoring: restoreFrom != nil)
        l.sentry = await serveSentry(rec, profile: staged, udsPath: qc.firecrackerVsockPath, stored: nil,
                                     restoring: restoreFrom != nil)
        if let staged, rec.registration != true {
            applyRouting(staged: staged)
            startLocalEngineIfNeeded(for: staged)
            lastStagedProfiles[rec.id] = staged
        }
        // The address it had last, if still free (macOS's lease store), leased
        // before the switch sees it; recorded, so a restarted daemon hands the
        // same one back (the guest keeps it) and so does its next boot.
        let leased = sw.dhcp.lease(for: InterimSwitch.mac(rec.mac), preferring: rec.lease.map(InterimSwitch.ipv4))
        sw.attach(l.port, mac: rec.mac)
        await allowLoadBalancerClaims(rec)
        rec.lease = leased?.map(String.init).joined(separator: ".")
        let machine = l.machine
        let id = rec.id
        await machine.setOnStopped { [weak self] info in Task { await self?.vmStopped(id, info) } }
        // Belt and braces: a start that a repair overtook (its marks would
        // have refused it) never attaches the disks.
        if repairMarks.contains(id) {
            await teardown(l, mac: rec.mac)
            throw KubeClusterEngine.KubeError.message("'\(rec.name)' is having its disks repaired")
        }
        live[id] = l
        if let raw { liveApplied[id] = raw }
        // A save between this launch's profile read and now found the VM not
        // running yet (profilesDidChange skipped it): its policy, as it is
        // now. Read and applied in one step on the main actor, where
        // profilesDidChange runs, so no save lands between the two: an
        // earlier save is in the store by then, a later one applies its own.
        if rec.registration != true, rec.kube == nil, let pid = UUID(uuidString: id), let mitm {
            await MainActor.run {
                if let now = ProfileStore().loadAll().first(where: { $0.id == pid }) {
                    mitm.applyWorkspacePolicies(now)
                    sw.egress.update(.init(now))
                    Self.refreshWatchdogModes()
                }
            }
            // …and its credentials and files, if it changed them.
            if existingProfile(for: rec) != raw { _ = scheduleLiveRefresh(id) }
        }
        // The start clones the base into a missing system disk (a new
        // workspace's, a reset one's): which base that was is recorded on
        // the workspace, for the drift check (DaemonBaseImageDrift.swift).
        // Recorded once the clone is there, even when the boot then fails:
        // the disk is that base's either way.
        let clones = !FileManager.default.fileExists(atPath: machine.config.overlay)
        let baseVersion = clones ? readCurrentBaseVersion() : nil
        let workspace = rec.registration != true && rec.kube == nil, overlay = machine.config.overlay
        let stampClone = { [self] in
            if let baseVersion, workspace, let pid = UUID(uuidString: id), FileManager.default.fileExists(atPath: overlay) {
                stampBaseImageVersionAtClone(baseVersion, profileID: pid)
            }
        }
        do {
            try await machine.start()
        } catch {
            stampClone()
            live[id] = nil
            await teardown(l, mac: rec.mac)
            throw error
        }
        stampClone()
        // A workspace's cold boot: its console watched for a boot that dies
        // on filesystem errors (DaemonBootRemedy; a cluster machine's has its
        // own scan). The log starts fresh with each Firecracker.
        if restoreFrom == nil, rec.registration != true, rec.kube == nil, rec.rescueFor == nil,
           let serial = machine.config.serialLog {
            startBootConsoleScan(id, console: (serial, 0))
        }
        rec.state = .running
        if let restoreFrom {
            // The resumed guest sets its clock from this (agentd's resume
            // watcher; its clock stood still while it was saved), and the
            // snapshot is spent: its memory file is the guest's memory now.
            try? "\(Int(Date().timeIntervalSince1970))".write(toFile: dir + "/meta/.resume-signal", atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: restoreFrom)
        } else {
            rec.bootedAt = Date()
        }
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
        // Host folders (a managed machine's, a workspace's shared folders):
        // the fstab's share-<N> slots.
        for (i, folder) in shareFolders(rec).enumerated() {
            qc.shares.append(.init(tag: "share-\(i + 1)", hostPath: folder))
        }
        qc.macAddress = rec.mac
        qc.extraDisks = [.init(path: dir + "/home.img")]
        // A cluster machine's data disk (Longhorn, a registry's storage): vdc.
        if rec.dataDiskGB != nil { qc.extraDisks.append(.init(path: dir + "/data.img")) }
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
        dropLeftoverRegistrations()
        await dropLeftoverRescues()
        for rec in registry.records where (rec.state == .running || rec.state == .starting) && rec.rescueFor == nil {
            var r = rec
            do {
                guard let pid = rec.pid else { throw MachineError.notRunning }
                // Its own Firecracker holds the CID.
                guard CIDAllocator.shared.adopt(rec.cid) else { throw MachineError.invalidConfig("CID \(rec.cid) is taken") }
                guard rec.machine == Self.machineType else { throw MachineError.invalidConfig("a pre-Firecracker VM") }
                // Its workspace, read first: a session VM's port is governed
                // (its egress policy, its interception opt-out) the moment it
                // is back on the switch, so one whose workspace can't be read
                // isn't taken back at all (the catch below ends it) rather
                // than attached ungoverned.
                let adoptedProfile = rec.managed ? nil : await launchProfile(for: rec, create: false)
                if !rec.managed, adoptedProfile == nil {
                    throw MachineError.invalidConfig("its workspace profile can't be read, so its network can't be governed")
                }
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
                var browser: BrowserMCPBridge?
                do {
                    if rec.kube == nil {
                        browser = try await MainActor.run { [qc] in
                            try BrowserMCPBridge(udsPath: qc.firecrackerVsockPath, fdStoreName: "bmcp-" + rec.shortId,
                                                 stored: storedBrowser, profileID: UUID(uuidString: rec.id))
                        }
                    } else if let storedBrowser {
                        close(storedBrowser)
                    }
                } catch { await vsock.close(); port.close(); throw error }
                let shell = await GuestShell(cid: rec.cid, connections: vsock.connections)
                let machine: FirecrackerMachine
                do { machine = try await FirecrackerMachine.adopt(config: qc, pid: pid) } catch {
                    await shell.stop()
                    await vsock.close()
                    await MainActor.run { browser?.stop() }
                    port.close()
                    throw error
                }
                var l = Live(machine: machine, port: port, shell: shell, config: qc, vsock: vsock, browser: browser,
                             storedNet: storeName)
                // Its console from here on (an older daemon appended across boots).
                if let serial = qc.serialLog, let size = (try? FileManager.default.attributesOfItem(atPath: serial))?[.size] as? UInt64 {
                    serialLogStart[rec.id] = size
                }
                // The workspace's credentials, before its proxy listener accepts
                // a connection (they were the previous daemon's): its swap map
                // (minted credentials and their AWS keys, so a minted key never
                // signs as the base keys), kube trust, the AWS credential server
                // and its SSH key. Trust for this server's own clusters comes
                // with start's refresh, once the session engine (and its
                // cluster engine) is up: until then they fail closed. start
                // then rewrites its kubeconfig.
                // Quarantined before the restart: cut again before any of its
                // listeners serves (or it's attached).
                let reask = readoptQuarantine(rec)
                if let profile = adoptedProfile {
                    await setUpWorkspaceCredentials(profile, meta: vmDir(rec.id) + "/meta")
                    if rec.registration != true { sw.egress.govern(MAC(InterimSwitch.mac(rec.mac)), .init(profile)) }
                }
                l.mitm = serveProxy(rec, udsPath: qc.firecrackerVsockPath,
                                    stored: storedNet.removeValue(forKey: "mitm-" + rec.shortId))
                startTraceSession(rec)
                var storedMCP: [String: Int32] = [:]
                for name in ["tbmcp-", "amcp-", "kmcp-", "dmcp-", "sbmcp-"] {
                    if let fd = storedNet.removeValue(forKey: name + rec.shortId) { storedMCP[name] = fd }
                }
                if rec.kube == nil { l.mcp = await serveMCP(rec, udsPath: qc.firecrackerVsockPath, stored: storedMCP) }
                if rec.kube == nil {
                    l.plan = await servePlanStream(rec, udsPath: qc.firecrackerVsockPath,
                                                   stored: storedNet.removeValue(forKey: "plan-" + rec.shortId))
                }
                l.inference = serveInference(rec, udsPath: qc.firecrackerVsockPath,
                                             stored: storedNet.removeValue(forKey: "llm-" + rec.shortId))
                l.aws = serveAWSCreds(rec, udsPath: qc.firecrackerVsockPath,
                                      stored: storedNet.removeValue(forKey: "aws-" + rec.shortId))
                l.ssh = serveSSHAgent(rec, udsPath: qc.firecrackerVsockPath,
                                      stored: storedNet.removeValue(forKey: "ssh-" + rec.shortId))
                l.attest = await serveAttestor(rec, profile: adoptedProfile, udsPath: qc.firecrackerVsockPath,
                                               stored: storedNet.removeValue(forKey: "attest-" + rec.shortId),
                                               restoring: true)
                l.sentry = await serveSentry(rec, profile: adoptedProfile, udsPath: qc.firecrackerVsockPath,
                                             stored: storedNet.removeValue(forKey: "sentry-" + rec.shortId),
                                             restoring: true)
                if let staged = adoptedProfile {
                    applyRouting(staged: staged)
                    startLocalEngineIfNeeded(for: staged)
                    lastStagedProfiles[rec.id] = staged
                }
                sw.attach(l.port, mac: rec.mac)
                await allowLoadBalancerClaims(rec)
                if let lease = rec.lease { sw.dhcp.assign(mac: InterimSwitch.mac(rec.mac), ip: InterimSwitch.ipv4(lease)) }
                let id = rec.id
                await l.machine.setOnStopped { [weak self] info in Task { await self?.vmStopped(id, info) } }
                live[id] = l
                // As the launch refusal (DaemonSandboxGuard.swift):
                // a VM taken back isn't stopped, but said to be unprotected.
                if let profile = adoptedProfile { Self.warnUnenforceableAdopted(rec, profile: profile, staged: URL(fileURLWithPath: vmDir(rec.id) + "/meta"), sentryCatalog: sentryCatalogCached()) }
                if reask, let pid = UUID(uuidString: id) {
                    Task { await self.quarantineAndAsk(pid, signals: []) }
                } else {
                    Task { await self.readoptPaused(id) }
                }
                r.state = .running
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': took back its Firecracker (pid \(pid)), network and vsock from the fd store\n".utf8))
            } catch {
                // A Firecracker left here would keep running and hold
                // disk.raw and home.img, and its virtiofsds (unsupervised
                // since the restart) their pid-file locks: a boot right
                // after (a cluster's auto-start) fails on them. End them
                // all, if still the processes we recorded, and wait.
                let ours = Self.isOurVM(rec)
                let gone = Self.killIfOursAndWait(rec)
                    && Self.killFirecrackers(shortId: rec.shortId)
                    && Self.killVirtiofsds(under: config.runtimeDir + "/vms/" + rec.shortId)
                if ours {
                    FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': not re-adopted (\(error)); killed its Firecracker (pid \(rec.pid ?? 0))\(gone ? "" : ", which or whose virtiofsds didn't exit in time")\n".utf8))
                }
                CIDAllocator.shared.release(rec.cid)
                r.state = .stopped
                r.pid = nil
                r.pidStart = nil
            }
            try? registry.upsert(r)
        }
    }

    /// A credential the VM minted, added to its workspace's (expired ones
    /// past their retention pruned).
    // partial: no live session or staged-profile copies to update (the daemon reads the store at each launch)
    // @port ACAppDelegate.saveMintedCredential(_: MintedCredential, profileID: Profile.ID) h=23a3ae42b9bdece5 @d2db8346
    @MainActor static func saveMintedCredential(_ minted: MintedCredential, profileID: UUID, store: ProfileStore) {
        do {
            _ = try ProfileWrites.edit(profileID, store: store) { p in
                p.mintedCredentials = MintedCredential.pruned(p.mintedCredentials) + [minted]
                return true
            }
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: minted credential: couldn't save profile: \(error)\n".utf8))
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

    /// killIfOurs, then waits (≤ `timeout`) for the process to be gone.
    /// True when it's gone (or wasn't ours to begin with: not running).
    // @port-skip linux-only: Linux process identity
    static func killIfOursAndWait(_ rec: VMRecord, timeout: Duration = .seconds(10)) -> Bool {
        guard let pid = rec.pid else { return true }
        let fd = acl_pidfd_open(pid)
        guard fd >= 0 else { return true }                 // no such process
        defer { close(fd) }
        guard isOurVM(rec) else { return true }            // a recycled pid: ours is gone
        guard acl_pidfd_send_signal(fd, SIGKILL) == 0 else { return false }
        return waitExit(pidfd: fd, timeout: timeout)
    }

    /// Whether the process behind `pidfd` exited within `timeout` (a pidfd
    /// is readable once it has).
    // @port-skip linux-only: Linux process identity
    static func waitExit(pidfd: Int32, timeout: Duration) -> Bool {
        var p = pollfd(fd: pidfd, events: Int16(POLLIN), revents: 0)
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return false }
            let ms = Int32(min(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000, 60_000))
            let n = poll(&p, 1, max(ms, 1))
            if n > 0 { return true }
            if n < 0, errno != EINTR { return false }
        }
    }

    /// This user's virtiofsd processes serving a socket in `dir` (a VM's run
    /// directory), SIGKILLed through pidfds; true when every one is gone
    /// within `timeout`. A taken-back VM's virtiofsds aren't supervised.
    // @port-skip linux-only: Linux process identity
    static func killVirtiofsds(under dir: String, timeout: Duration = .seconds(10)) -> Bool {
        killProcesses(comm: "virtiofsd", timeout: timeout) { args in
            zip(args, args.dropFirst()).contains { $0 == "--socket-path" && $1.hasPrefix(dir + "/") }
        }
    }

    /// This user's Firecracker for the VM `shortId` (`--id bromure-<short>`),
    /// whether or not its record has the pid: a crash between its spawn and
    /// the record's save leaves it running unrecorded. SIGKILLed and waited
    /// for as killVirtiofsds.
    // @port-skip linux-only: Linux process identity
    static func killFirecrackers(shortId: String, timeout: Duration = .seconds(10)) -> Bool {
        killProcesses(comm: "firecracker", timeout: timeout) { args in
            zip(args, args.dropFirst()).contains { $0 == "--id" && $1 == "bromure-" + shortId }
        }
    }

    /// This user's processes named `comm` whose arguments `matches`, each
    /// SIGKILLed through a pidfd (checked with it open: a match is the
    /// process signalled) and waited for; true when all are gone in time.
    // @port-skip linux-only: Linux process identity
    static func killProcesses(comm: String, timeout: Duration, matches: ([String]) -> Bool) -> Bool {
        let me = getuid()
        var allGone = true
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = Int32(entry) else { continue }
            var st = stat()
            guard stat("/proc/\(pid)", &st) == 0, st.st_uid == me else { continue }
            let fd = acl_pidfd_open(pid)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            // Checked again with the pidfd open: it pins this process (a pid
            // recycled since the first look can't be the one signalled).
            guard stat("/proc/\(pid)", &st) == 0, st.st_uid == me,
                  let c = ProcFS.text("/proc/\(pid)/comm"),
                  c.trimmingCharacters(in: .newlines) == comm,
                  let argv = ProcFS.argv(pid) else { continue }
            guard matches(argv) else { continue }
            if acl_pidfd_send_signal(fd, SIGKILL) != 0 || !waitExit(pidfd: fd, timeout: timeout) { allGone = false }
        }
        return allGone
    }

    /// /proc/<pid>/stat's starttime (field 22), nil if there's no such process.
    // @port-skip linux-only: Linux process identity
    static func processStartTime(_ pid: Int32) -> UInt64? {
        guard let st = ProcFS.text("/proc/\(pid)/stat"),
              let close = st.lastIndex(of: ")") else { return nil }
        let fields = st[st.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? UInt64(fields[19]) : nil       // fields[0] is field 3 (state)
    }

    /// Whether `rec`'s recorded Firecracker is still the process at that pid:
    /// same start time, and it runs this VM (`--id bromure-<short id>`).
    // @port-skip linux-only: Linux process identity
    static func isOurVM(_ rec: VMRecord) -> Bool {
        guard let pid = rec.pid, let start = rec.pidStart, processStartTime(pid) == start,
              let args = ProcFS.argv(pid) else { return false }
        return zip(args, args.dropFirst()).contains { $0 == "--id" && $1 == "bromure-\(rec.shortId)" }
    }

    /// Creates the sparse home image if missing (ftruncate: all holes). An
    /// existing one is left alone: it's the VM's home.
    // partial: no ProfileStore change notice
    // @port SessionDisk.ensureHomeImageExists() h=83d4fac81b0747d2 @25ad3a88
    static func ensureHomeImage(atPath path: String, bytes: UInt64,
                                floor: UInt64 = EphemeralDisk.minimumFreeBytes) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try EphemeralDisk.checkDiskSpace(at: (path as NSString).deletingLastPathComponent, minimumFreeBytes: floor)
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
    /// default for the free space where it lives (resolvedHomeImageGB),
    /// 8–1024 GiB.
    // partial: no legacy-home migration size (Linux homes start on ext4)
    // @port SessionDisk.var homeImageTargetBytes h=d3a08ca727957c14 @7d72a296
    static func homeImageTargetBytes(gb: Int?, defaultGB: Int) -> UInt64 {
        UInt64(min(1024, max(8, gb ?? defaultGB))) << 30
    }

    /// A new home's size, GiB: the daemon's setting (BROMURE_AC_HOME_GB)
    /// when set, else scaled to `freeBytes` (nil = unknown, the full default).
    // @port SessionDisk.static resolvedHomeImageGB(freeBytes: UInt64?) h=55629d74848e1a35 @7d72a296
    static func resolvedHomeImageGB(override: Int?, freeBytes: UInt64?) -> Int {
        min(1024, max(8, override ?? HomeImageSizing.scaledGB(freeBytes: freeBytes)))
    }

    /// What a new home is made here now (a workspace with no size of its
    /// own): the setting, else this host's free space where the VMs live.
    /// What a fat client's new-workspace editor shows (GET /storage/defaults).
    // @port SessionDisk.static newHomeDefaultGB() h=4fcd82eae3b316f0 @7d72a296
    func newHomeDefaultGB() -> Int {
        Self.resolvedHomeImageGB(override: config.homeImageOverrideGB, freeBytes: Self.freeBytes(near: config.stateDir + "/vms"))
    }

    /// Free space where `path` is, or at its nearest existing parent (a new
    /// VM's directory doesn't exist yet).
    // @port SessionDisk.static freeBytes(near: URL) h=ab739f8f43ae5569 @7d72a296
    static func freeBytes(near path: String) -> UInt64? {
        var dir = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        return EphemeralDisk.freeBytes(at: dir.path)
    }

    /// Grows an existing home image to `target` (never shrinks; it stays
    /// sparse; agentd runs resize2fs after mounting) when the VM has a size
    /// of its own (`setting`): the default, free-space scaled or set, only
    /// sizes a new home; a home made 8 GB on a full disk would otherwise grow
    /// at whichever boot found more room. Returns what it did, for the log:
    /// a grow that doesn't happen says why.
    // partial: no ProfileStore change notice, and no home checkpoints to purge after a grow
    // @port SessionDisk.growHomeImageIfNeeded() h=d288b72a68027d0d @7d72a296
    static func growHomeImageIfNeeded(atPath path: String, target: UInt64, setting: Int?,
                                      floor: UInt64 = EphemeralDisk.minimumFreeBytes) throws -> String {
        let gib = { (b: UInt64) in "\(b >> 30) GiB" }
        var st = stat()
        guard stat(path, &st) == 0 else { return "home image unreadable at \(path) — not grown (target \(gib(target)))" }
        let size = UInt64(st.st_size)
        guard size < target else {
            return "home image \(gib(size)) (setting \(setting.map { "\($0) GB" } ?? "default"), target \(gib(target))) — nothing to grow"
        }
        guard setting != nil else {
            return "home image \(gib(size)) (default size, kept: the default only sizes a new home) — nothing to grow"
        }
        try EphemeralDisk.checkDiskSpace(at: (path as NSString).deletingLastPathComponent, minimumFreeBytes: floor)
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
    // partial: one VM per workspace record (no earlier sandbox's late stop to tell apart); a reboot relaunches, an explicit stop wins
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onStopped h=63ea87a5b3a8e015 @4237c02e
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
        // Its guest rebooted itself: it boots again (DaemonGuestReboot),
        // unless a stop was asked for meanwhile.
        let explicit = explicitStops.remove(id) != nil
        if pendingGuestRelaunch.remove(id) != nil {
            if !explicit { Task { await self.relaunchAfterGuestReboot(id) } } else {
                // Stopped for good after all: a `--rm` workspace goes now.
                rebooting.remove(id)
                stopsDuringReboot.remove(id)
                if let pid = UUID(uuidString: id) { await dropAbandonedEphemeral(pid) }
            }
        }
    }

    // partial: no windows, panes, status menu or activation policy on a server; a queued boot remedy runs through this stop (it ends in performBootRemedy)
    // @port ACAppDelegate.handleSessionStopped(profileID: Profile.ID) h=772a84595772dbe3 @4237c02e
    private func finishStop(_ id: String, _ l: Live, _ info: FirecrackerMachine.StopInfo) async {
        guard var rec = registry.find(id) else { return }
        // A boot failure ends with its session (macOS: handleSessionStopped).
        activeBootFailures[id] = nil
        bootStartedAt[id] = nil
        // Did the guest reboot itself? Read before the teardown takes its run
        // directory (the serial log): its reboot marker (also one it left
        // within a poll of halting), or the kernel's own last word on the
        // console when agentd couldn't write one (a reboot before its roster
        // loop runs). Firecracker exits on the guest's reset either way.
        let marker = vmDir(id) + "/outbox/reboot-intent"
        let markerLeft = FileManager.default.fileExists(atPath: marker)
        if markerLeft { try? FileManager.default.removeItem(atPath: marker) }
        // An end from the guest's side: Firecracker's own exit, or the
        // outbox share's virtiofsd going first as the guest resets.
        let guestSide: Bool
        switch info.reason { case .guestShutdown, .virtiofsdExited: guestSide = true; default: guestSide = false }
        let from = serialLogStart.removeValue(forKey: id) ?? 0
        let guestRebooted = !explicitStops.contains(id) && guestSide && (guestRebootIntents.remove(id) != nil || markerLeft
            || l.config.serialLog.map { Self.kernelSaidRestart(serialLog: $0, from: from) } == true)
        guestRebootIntents.remove(id)
        if guestRebooted {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)' stopped as its guest rebooted (\(info.reason)): booting it again\n".utf8))
        }
        await teardown(l, mac: rec.mac)
        // A live refresh under way finishes first (a queued one sees the VM
        // gone): none puts its proxy state back after this clears it.
        await liveRefreshTail.removeValue(forKey: id)?.value
        liveApplied[id] = nil
        if let pid = UUID(uuidString: id) { await clearWorkspaceProxyState(pid) }
        // A workspace that stopped: its "until the workspace stops" firewall
        // rules end (macOS: unregisterSession).
        if rec.registration != true, rec.kube == nil, !rec.managed, let pid = UUID(uuidString: id) {
            endUntilStopFirewallRules(for: pid)
        }
        // A sign-in VM that stopped on its own ends its sign-in.
        if rec.registration == true, let pid = UUID(uuidString: id) {
            await MainActor.run { LinuxSessionHost.shared?.registrationVMStopped(pid) }
        }
        // A cluster machine that stopped: the engine counts it down.
        if let owner = rec.kube.flatMap(UUID.init(uuidString:)), let nodeID = UUID(uuidString: id) {
            await MainActor.run {
                SessionStores.shared?.kubeEngine?.nodeStopped(clusterID: owner, nodeID: nodeID, error: nil)
            }
        }
        rec = registry.find(id) ?? rec
        // A resume that failed stays suspended (start() says so too).
        rec.state = info.reason == .suspended || restoring.contains(id) ? .suspended : .stopped
        rec.ip = nil
        rec.pid = nil
        rec.pidStart = nil
        CIDAllocator.shared.release(rec.cid)
        try? registry.upsert(rec)
        // The guest rebooted itself (its intent, then its own exit; not a stop
        // the daemon asked for): kept as a reboot, relaunched once this stop
        // is done (macOS: relaunchAfterGuestReboot).
        if guestRebooted,
           rec.registration != true, rec.kube == nil, rec.rescueFor == nil {
            rebooting.insert(id)
            pendingGuestRelaunch.insert(id)
        }
        // `vm run --rm`: the workspace goes now it stopped (a suspend is a
        // stop too, as macOS's session end) -- not when it is only rebooting.
        if let pid = UUID(uuidString: id) { await dropAbandonedEphemeral(pid) }
    }

    /// The VM's proxy listener (`stored`: a restarted daemon's); nil without
    /// a proxy or when it can't listen (the guest then has no proxy to reach).
    // @port-skip linux-only: the per-VM proxy listener (macOS: MitmEngine.register)
    private func serveProxy(_ rec: VMRecord, udsPath: String, stored: Int32?) -> MitmListener? {
        guard let mitm else { if let stored { close(stored) }; return nil }
        do {
            return try mitm.serve(udsPath: udsPath, profileID: UUID(uuidString: rec.id) ?? UUID(),
                                  fdStoreName: "mitm-" + rec.shortId, stored: stored)
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no proxy listener: \(error)\n".utf8))
            return nil
        }
    }

    /// The level + session id the proxy records this launch's traffic
    /// under (a fresh session per launch, as macOS's).
    // @port-skip linux-only: the trace step of ACAppDelegate.launch (engine.setSessionTrace), per Linux launch and re-adoption
    private func startTraceSession(_ rec: VMRecord) {
        guard let mitm, let pid = UUID(uuidString: rec.id), let profile = existingProfile(for: rec) else { return }
        mitm.setSessionTrace(TraceSession(sessionID: UUID(), level: profile.traceLevel), for: pid)
    }

    // @port-skip linux-only: Linux daemon VM lifecycle
    private func teardown(_ l: Live, mac: String) async {
        sw.detach(mac: mac)
        sw.dhcp.release(mac: mac)
        await l.shell.stop()
        l.port.close()
        await l.vsock.close()
        await MainActor.run { [browser = l.browser] in browser?.stop() }
        l.mitm?.stop()
        l.inference?.stop()
        l.aws?.stop()
        l.ssh?.stop()
        l.attest?.stop()
        l.sentry?.stop()
        await MainActor.run { [mcp = l.mcp] in for m in mcp { m.stop() } }
        if let pid = l.plan { await MainActor.run { SessionStores.shared?.detachPlanBridge(pid: pid) } }
        for name in Self.perVMStorePrefixes { FDStore.remove(name + l.storedNet.dropFirst("net-".count)) }
    }

    /// Stops every VM (killed: systemd's stop is not a graceful shutdown of
    /// guests yet) and passt.
    // @port-skip linux-only: Linux daemon lifecycle
    public func shutdown() async {
        // A stopping daemon leaves nothing for a next one to take back (each
        // VM's teardown drops its fd store entries).
        unwireWatchdog()
        // Squelch's numbers written out (macOS: quit's flush).
        SquelchLedger.shared.flush()
        for id in live.keys { explicitStops.insert(id) }
        for (_, l) in live { await l.machine.kill() }
        for _ in 0..<50 where !live.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        await MainActor.run { RemoteAccessServer.shared.stop() }
        mitm?.terminateAllSSHAgents()
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
