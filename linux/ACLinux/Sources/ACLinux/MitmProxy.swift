import Crypto
import Foundation
import SandboxEngine
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import SwiftASN1
import X509

/// The workspaces' intercepting proxy on a Linux server (macOS: MitmEngine +
/// HTTPMitmConnection). agentd bridges the guest's `127.0.0.1:<proxy_port>`
/// (proxy.env's HTTP(S)_PROXY) to host vsock 8443, which Firecracker's hybrid
/// vsock delivers on `<v.sock>_8443`: one listener per VM, so a connection's
/// workspace is the listener's.
///
/// Per connection, as macOS does it: the bridge's preamble line, then
/// `CONNECT host:port` (TLS terminated with a leaf the guest trusts through
/// the Bromure CA) or a plain `http://` request; one request per connection;
/// its subscription stand-ins and fake tokens swapped for the real ones
/// (SubscriptionAuthRewrite, TokenSwapper), a sign-in's token exchange
/// answered by the host (SignInCapture), and the response streamed back.
/// Each request is traced as macOS traces it (TraceEmitter, at the
/// workspace's trace level). The workspace's policy chain runs on each
/// request first (MitmEgress.swift): OpenShell's checks, the middleware,
/// the guardrails, compromise detection and strict credential mode; then
/// the supply-chain policy (SupplyChainLinux.swift), prompt injection and PII
/// protection (its reply restored by PIIRelay).
// @port-skip linux-only: macOS's MitmEngine runs HTTPMitmConnection (SecureTransport) per VZ vsock connection
final class MitmProxy: @unchecked Sendable {
    static let vsockPort: UInt32 = 8443
    /// A request body is held in memory up to this (macOS spools to disk).
    static let maxBody = 256 << 20

    let ca: BromureCA
    let caNIO: NIOSSLCertificate
    let swapper: TokenSwapper
    /// Each workspace's model routing (MitmRouting.swift).
    let routingContexts = NIOLockedValueBox<[UUID: LLMRoutingContext]>([:])
    /// The token swaps' and the kube client certificates' consent (macOS:
    /// MitmEngine's one ConsentBroker).
    let consent: ConsentBroker
    /// Imported kubeconfigs' client certificates and cluster CAs, per workspace.
    let kubeTrust: KubeUpstreamTrust
    /// The AWS keys a workspace's VM minted (macOS: MitmEngine.awsCreds).
    let awsCreds: AWSCredentialServer
    /// Each workspace's prompt-injection policy (macOS: MitmEngine's
    /// promptInjectionPolicies), read when a traced conversation is parsed.
    private let promptInjectionPolicies = NIOLockedValueBox<[UUID: PromptInjectionPolicy]>([:])
    /// Each workspace's PII protection (setPIIPolicy), read per request.
    private let piiPolicies = NIOLockedValueBox<[UUID: PIIPolicy]>([:])
    /// Each workspace's supply-chain policy (setSupplyChainPolicy).
    private let supplyChainPolicies = NIOLockedValueBox<[UUID: SupplyChainPolicy]>([:])
    /// The supply-chain checks' engines (macOS: MitmEngine's).
    let osvClient = OSVClient()
    let socketClient = SocketDevClient()
    let publishTimeCache = PublishTimeCache()
    /// Who answers the artifact checks' questions (an override, a package
    /// with no verdict, npm ci's bypass), remembering the answers (macOS:
    /// MitmEngine's supplyChainBroker); the questions go to the client.
    let supplyChainBroker = SupplyChainConsentBroker()
    /// The checks' consent: the broker.
    // @port-skip linux-only: the Linux proxy's handle on its broker for SupplyChainProxy.artifactChecks
    var supplyChainConsent: any SupplyChainConsenting { supplyChainBroker }
    /// Each workspace's guardrails and egress policy (macOS: MitmEngine's
    /// guardrailsConfigs), read per connection and per request
    /// (MitmEgress.swift).
    let guardrailsConfigs = NIOLockedValueBox<[UUID: GuardrailsConfig]>([:])
    /// Fusion's per-workspace toggle and config (MitmFusion.swift).
    let fusionEngagedFlags = NIOLockedValueBox<[UUID: Bool]>([:])
    let fusionConfigs = NIOLockedValueBox<[UUID: Fusion.Config]>([:])
    /// Asks a workspace's agentd to reset the bridged client socket whose
    /// loopback port is given (the preamble's sport), calling back once done
    /// (macOS: EgressConnectionRegistry.guestAbort, by vsock port there).
    let bridgeAbort = NIOLockedValueBox<(@Sendable (UUID, Int, String, @escaping @Sendable () -> Void) -> Void)?>(nil)
    /// How long a cut waits for agentd's reset before closing anyway
    /// (macOS: HTTPMitmConnection.abortGrace).
    static let abortGrace: TimeAmount = .milliseconds(1500)
    /// A workspace's model socket streaming (macOS: HTTPMitmConnection.liveActivity).
    static let liveActivity = NIOLockedValueBox<(@Sendable (UUID) -> Void)?>(nil)
    /// Each workspace's current session: a stop (clearGuardrailsConfig)
    /// starts the next. What a reply from an older one would teach strict
    /// mode's guard is dropped, and so is its compromise event
    /// (MitmEgress.swift, DaemonCompromise.swift).
    let strictSessions = NIOLockedValueBox<[UUID: UInt64]>([:])
    /// The session of the request whose compromise is being raised, for the
    /// handler (DaemonCompromise.swift): TokenSwapper.detectCompromise (shared)
    /// calls it synchronously and has no way to pass it.
    @TaskLocal static var raisingSession: UInt64?
    /// `.promptOnWrite` guardrails' consent (macOS: MitmEngine.guardrailsBroker):
    /// asked of the connected client (ConsentPrompt).
    let guardrailsBroker = GuardrailsConsentBroker()
    /// Prompt injection's "ask" (macOS: HTTPMitmConnection.promptInjectionBroker):
    /// asked of the connected client (ConsentPrompt).
    let promptInjectionBroker = PromptInjectionConsentBroker()
    /// The workspaces' SSH agent (macOS: MitmEngine.sshAgent): their keys
    /// stay on the host; guests sign through vsock 8444.
    let sshAgent: SSHAgentServer
    /// Each workspace's own ssh-agent process, its imported keys loaded
    /// (macOS: MitmEngine.sshAgents; DaemonSSHKeys.swift).
    let sshAgents = NIOLockedValueBox<[UUID: WorkspaceSSHAgent]>([:])
    /// Where their sockets go: the daemon's 0700 runtime directory.
    let sshAgentDirectory = NIOLockedValueBox<String>(NSTemporaryDirectory())
    /// AWS requests re-signed with the real keys (macOS: MitmEngine.awsResigner).
    let awsResigner: AWSResigner
    /// Credentials the guest mints through the proxy: replaced by fakes in
    /// the response, kept on the host (macOS: MitmEngine.credentialMinter).
    let credentialMinter: CredentialMinter
    /// Imported kubeconfigs' exec plugins, run on the host on their interval;
    /// each token goes into its workspace's swap map under its fake.
    /// (The shared poller is main-actor: made there, on first use.)
    @MainActor lazy var execPoller = ExecCredentialPoller()
    /// The 1Password `op://` refresh loops, one per workspace (macOS:
    /// MitmEngine.opRefresher; main-actor too).
    @MainActor lazy var opRefresher = OnePasswordRefresher()
    /// The exec contexts the poller runs per workspace, so a live refresh
    /// keeps their fakes (`materialize(reusingExec:)`).
    let execContexts = NIOLockedValueBox<[UUID: [KubeconfigMaterializer.ExecContext]]>([:])
    let claudeStore: ClaudeSubscriptionStore
    let claudeRefresher: ClaudeSubscriptionRefresher
    let codexStore: CodexSubscriptionStore
    let codexRefresher: CodexSubscriptionRefresher
    let grokStore: GrokSubscriptionStore
    let grokRefresher: GrokSubscriptionRefresher
    let kimiStore: KimiSubscriptionStore
    let kimiRefresher: KimiSubscriptionRefresher
    /// Fills in a Kimi record's managed config from /models (macOS:
    /// MitmEngine.kimiProvisioner).
    let kimiProvisioner: KimiProvisioner
    let captures = SignInCaptureRegistry()
    /// The trace inspector's records (macOS: MitmEngine.traceStore), made
    /// on the main actor once the daemon is up (setUpTraceStore).
    let traces = NIOLockedValueBox<TraceStore?>(nil)
    /// Each running workspace's trace session (macOS: MitmEngine.sessionTraces).
    private let sessionTraces = NIOLockedValueBox<[UUID: TraceSession]>([:])
    /// Per-install salt for the fake tokens (macOS: MitmEngine's
    /// `fake-salt.bin` beside the CA); wiping it rotates every fake.
    let fakeTokenSalt: Data
    let group: EventLoopGroup
    /// Leaves for the hosts the guests reach (macOS: CertCache's identities).
    private let leaves = NIOLockedValueBox<(map: [String: (NIOSSLContext, UInt64)], tick: UInt64)>(([:], 0))
    static let leafCapacity = 1024
    private let upstreamContext: NIOSSLContext
    /// The same, validating nothing: an insecure request's (MitmInsecure.swift).
    private let insecureUpstreamContext: NIOSSLContext
    /// Tests: every upstream connection goes here instead (SNI kept), trusting `extraRoots`.
    var routeAllTo: (host: String, port: Int)?
    /// The read-whole budget this proxy's package replies share (the
    /// daemon's; a test's proxy has its own).
    var supplyChainBudget = ResponseRelay.supplyChainBudget
    /// An e2e run (BROMURE_AC_E2E=1): every upstream goes to the test
    /// upstream (`routeAllTo`) or is refused, never dialed; a splice goes to
    /// the test host only. Its guests' requests (and the credentials swapped
    /// into them) must reach only the local stand-in, so a build that lost
    /// the test route (a release build has none), or a route that doesn't
    /// parse, fails closed instead of falling back to the real hosts.
    var refusesRealUpstreams = false
    /// Who opened a guest socket (`sport` → `dst:dport`), as the guest's
    /// attestor says: BinaryIdentityService's (tests stub it).
    var identityLookup: @Sendable (UUID, UInt16, String, UInt16) async -> OpenShellPolicy.BinaryIdentity? = {
        await BinaryIdentityService.shared.identity(profileID: $0, sport: $1, dst: $2, dport: $3)
    }
    /// Attestor questions in flight per workspace (MitmTransparent.swift).
    let identityLookupsInFlight = NIOLockedValueBox<[UUID: Int]>([:])
    /// A multi-user server: the host's own addresses are refused too
    /// (ProxyDestination.swift), as the switch refuses them.
    var blocksHostAddresses = false
    /// What a destination is refused for, as the switch's
    /// blockedDestination: a shared server's own addresses and every LAN
    /// pool; a single-user one's other accounts' LAN pools.
    // @port-skip linux-only: multi-user isolation (macOS has one user)
    var refusedDestination: @Sendable (OpenShellPolicy.IPAddress) -> Bool {
        if blocksHostAddresses { return { ip in MitmProxy.isHostOwn(ip) } }
        return { ip in MitmProxy.isOtherLANPool(ip) }
    }

    /// The CA (`<dir>/cert.pem`, `key.pem`, made on first use) and the
    /// subscription stores the stand-in swaps read, wired where the swaps
    /// look for them (SubscriptionProviders).
    // @port-skip linux-only: MitmEngine.init's share for the Linux proxy
    init(caDirectory: URL, extraRoots: [NIOSSLCertificate] = [],
         group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) throws {
        ca = try BromureCA.loadOrCreate(at: caDirectory)
        caNIO = try NIOSSLCertificate(bytes: Array(ca.certificatePEM.utf8), format: .pem)
        let saltURL = caDirectory.appendingPathComponent("fake-salt.bin")
        if let existing = try? Data(contentsOf: saltURL), existing.count == 32 {
            fakeTokenSalt = existing
        } else {
            var g = SystemRandomNumberGenerator()
            let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })
            try fresh.write(to: saltURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: saltURL.path)
            fakeTokenSalt = fresh
        }
        let broker = ConsentBroker()
        consent = broker
        swapper = TokenSwapper(consent: broker)
        awsCreds = AWSCredentialServer(consent: broker)
        sshAgent = SSHAgentServer(consent: broker)
        // A gone daemon's agents (and their keys) go before any of ours
        // starts (macOS: the engine's reapOrphans); never in a test run.
        if !isTestRun() { WorkspaceSSHAgent.reapOrphansOfGoneDaemons() }
        awsResigner = AWSResigner(credServer: awsCreds)
        kubeTrust = KubeUpstreamTrust(extraRoots: extraRoots)
        // The user's logins (the support folder), except in a test run: a
        // test's proxy keeps its stores beside its CA, so it never reads the
        // user's real files with a test's vault key (each such read saved an
        // `.unreadable-…` copy beside them) nor writes them.
        let stores: URL? = isTestRun() ? caDirectory.appendingPathComponent("subscriptions", isDirectory: true) : nil
        claudeStore = ClaudeSubscriptionStore(fileURL: stores?.appendingPathComponent("claude-subscription.enc"))
        claudeRefresher = ClaudeSubscriptionRefresher(store: claudeStore)
        codexStore = CodexSubscriptionStore(fileURL: stores?.appendingPathComponent("codex-subscription.enc"))
        codexRefresher = CodexSubscriptionRefresher(store: codexStore)
        grokStore = GrokSubscriptionStore(fileURL: stores?.appendingPathComponent("grok-subscription.enc"))
        grokRefresher = GrokSubscriptionRefresher(store: grokStore)
        kimiStore = KimiSubscriptionStore(fileURL: stores?.appendingPathComponent("kimi-subscription.enc"))
        kimiRefresher = KimiSubscriptionRefresher(store: kimiStore)
        kimiProvisioner = KimiProvisioner(store: kimiStore, refresher: kimiRefresher)
        self.group = group
        credentialMinter = CredentialMinter(salt: fakeTokenSalt, swapper: swapper, awsCreds: awsCreds)
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = ["http/1.1"]
        // The chain and the dialed name: a DNS name against the leaf's DNS
        // SANs, an IP literal (no SNI) against its IP SANs -- NIOSSL matches
        // those to the socket's remote address, before the handshake counts
        // as complete (macOS: URLSession binds both the same way).
        cfg.certificateVerification = .fullVerification
        if !extraRoots.isEmpty { cfg.additionalTrustRoots = [.certificates(extraRoots)] }
        upstreamContext = try NIOSSLContext(configuration: cfg)
        var insecureCfg = cfg
        insecureCfg.certificateVerification = .none
        insecureUpstreamContext = try NIOSSLContext(configuration: insecureCfg)
        wireProviders()
    }

    /// The swaps reach the stores through SubscriptionProviders (macOS:
    /// MitmEngine.register sets the same closures).
    /// Those closures are unlocked process globals, so they're set once (a
    /// static let runs once, thread-safe) and read the proxy built last
    /// under a lock: proxies built at once (the tests) used to overwrite
    /// them concurrently, and the closure replaced was released twice.
    // @port-skip linux-only: MitmEngine.register's provider wiring
    private func wireProviders() {
        Self.current.withLockedValue { $0.proxy = self }
        _ = Self.providersWired
    }

    /// Tests: this proxy is the providers' live one again (the latest made
    /// is, held weakly: one made later by another suite, then gone, leaves
    /// none). A daemon has one proxy.
    // @port-skip linux-only: tests
    func becomeLiveForTesting() { wireProviders() }

    // @port-skip linux-only: MitmEngine.register's provider wiring
    private struct WeakProxy: @unchecked Sendable { weak var proxy: MitmProxy? }
    private static let current = NIOLockedValueBox(WeakProxy())
    private static let providersWired: Void = {
        let live: @Sendable () -> MitmProxy? = { current.withLockedValue { $0.proxy } }
        SubscriptionProviders.claude = { live().map { ($0.claudeStore, $0.claudeRefresher) } }
        SubscriptionProviders.codex = { live().map { ($0.codexStore, $0.codexRefresher) } }
        SubscriptionProviders.grok = { live().map { ($0.grokStore, $0.grokRefresher) } }
        SubscriptionProviders.kimi = { live().map { ($0.kimiStore, $0.kimiRefresher) } }
        SubscriptionProviders.signInCapture = { pid in live()?.captures.capture(for: pid) }
        SubscriptionProviders.credentialMinter = { live()?.credentialMinter }
    }()

    // @port MitmEngine.setSessionTrace(_: SessionTrace, for: UUID) h=488811aacd2e89b1 @8866f904
    func setSessionTrace(_ trace: TraceSession, for profileID: UUID) {
        sessionTraces.withLockedValue { $0[profileID] = trace }
    }

    // @port MitmEngine.sessionTrace(for: UUID) h=554f04c64d0e34c2 @8866f904
    func sessionTrace(for profileID: UUID) -> TraceSession? {
        sessionTraces.withLockedValue { $0[profileID] }
    }

    // @port MitmEngine.clearSessionTrace(for: UUID) h=300943c7759e489b @8866f904
    func clearSessionTrace(for profileID: UUID) {
        sessionTraces.withLockedValue { $0[profileID] = nil }
    }

    /// The trace store under `<state>/traces`, its last records read back.
    // @port-skip linux-only: MitmEngine.init's TraceStore (macOS: Application Support/BromureAC/traces)
    @MainActor
    func setUpTraceStore(rootDir: URL) {
        let store = TraceStore(rootDir: rootDir)
        store.reload()
        traces.withLockedValue { $0 = store }
    }

    /// Whether `profileID`'s requests are traced at all (the relay keeps a
    /// response copy only then).
    // @port-skip linux-only: the Linux relay's gate on its trace copy
    func traceSession(for profileID: UUID) -> TraceSession? {
        guard traces.withLockedValue({ $0 }) != nil, let s = sessionTrace(for: profileID),
              s.level.recordsActivity else { return nil }
        return s
    }

    // @port MitmEngine.setPromptInjectionPolicy(_: PromptInjectionPolicy, for: UUID) h=f909a47d707e5e1d @8e2543eb
    func setPromptInjectionPolicy(_ policy: PromptInjectionPolicy, for profileID: UUID) {
        promptInjectionPolicies.withLockedValue { $0[profileID] = policy }
    }
    // @port MitmEngine.promptInjectionPolicy(for: UUID) h=e80d49232134d71c @8e2543eb
    func promptInjectionPolicy(for profileID: UUID) -> PromptInjectionPolicy? {
        promptInjectionPolicies.withLockedValue { $0[profileID] }
    }
    // @port MitmEngine.setPIIPolicy(_: PIIPolicy, for: UUID) h=9b96102637454989 @8e2543eb
    func setPIIPolicy(_ policy: PIIPolicy, for profileID: UUID) {
        let prior = piiPolicies.withLockedValue { all -> PIIPolicy? in
            defer { all[profileID] = policy }
            return all[profileID]
        }
        if prior != policy {
            SupplyChainLog.shared.record(
                "[pii] protection \(policy.isActive ? "on" : "off") for \(profileID.uuidString.prefix(8))")
        }
    }
    // @port MitmEngine.piiPolicy(for: UUID) h=8ce35c1891f58dbf @8e2543eb
    func piiPolicy(for profileID: UUID) -> PIIPolicy? {
        piiPolicies.withLockedValue { $0[profileID] }
    }
    /// A stopped workspace's PII policy, gone with its other policies
    /// (macOS keeps its engine's until the app quits).
    // @port-skip linux-only: clearWorkspacePolicies' share (macOS's MitmEngine has no clearPIIPolicy)
    func clearPIIPolicy(for profileID: UUID) {
        piiPolicies.withLockedValue { $0[profileID] = nil }
    }
    // @port MitmEngine.setSupplyChainPolicy(_: SupplyChainPolicy, for: UUID) h=61097e8ce0be342c @8e2543eb
    func setSupplyChainPolicy(_ policy: SupplyChainPolicy, for profileID: UUID) {
        let prior = supplyChainPolicies.withLockedValue { all -> SupplyChainPolicy? in
            defer { all[profileID] = policy }
            return all[profileID]
        }
        // A one-line summary of a new or changed policy, as macOS logs it.
        if prior != policy {
            var bits: [String] = []
            if policy.ageGateEnabled { bits.append("age-gate=\(policy.ageGateDays)d") }
            if policy.osvEnabled { bits.append("osv=\(policy.osvSeverity.rawValue)") }
            if policy.socketActive {
                var sk: [String] = []
                if policy.socketBlockCompromised { sk.append("compromised") }
                if policy.socketBlockCVE { sk.append("cve=\(policy.socketCVESeverity.rawValue)") }
                bits.append("socket.dev=\(sk.joined(separator: "+"))")
            } else if policy.packageFilter == .socketDev, !policy.socketAPIKey.isEmpty {
                bits.append("socket.dev=key-set-but-no-toggle")
            }
            if policy.depiActive {
                bits.append("depi=npm→\(DepiRegistry.host)")
            } else if policy.packageFilter == .depi {
                bits.append("depi=selected-but-no-key")
            }
            if policy.stripInstallScripts { bits.append("strip-scripts") }
            let summary = bits.isEmpty ? "off" : bits.joined(separator: " ")
            SupplyChainLog.shared.record(
                "[supply-chain] policy engaged for \(profileID.uuidString.prefix(8)): \(summary)")
        }
    }
    // @port MitmEngine.supplyChainPolicy(for: UUID) h=c9f2fe57fc0db459 @8e2543eb
    func supplyChainPolicy(for profileID: UUID) -> SupplyChainPolicy? {
        supplyChainPolicies.withLockedValue { $0[profileID] }
    }
    // @port MitmEngine.clearSupplyChainPolicy(for: UUID) h=c048d601fe627e5c @8e2543eb
    func clearSupplyChainPolicy(for profileID: UUID) {
        supplyChainPolicies.withLockedValue { $0[profileID] = nil }
    }
    // @port MitmEngine.clearPromptInjectionPolicy(for: UUID) h=b926618e76eae15c @8e2543eb
    func clearPromptInjectionPolicy(for profileID: UUID) {
        promptInjectionPolicies.withLockedValue { $0[profileID] = nil }
    }

    /// A WebSocket's trace record at its close (macOS: emitWebSocketTrace's
    /// call), its transcript rendered here, on the connection's loop.
    // @port-skip linux-only: the Linux proxy's call into TraceEmitter.emitWebSocket
    func emitWebSocketTrace(_ t: RequestReader.Trace, _ ws: WSTraceSession) {
        guard let store = traces.withLockedValue({ $0 }) else { return }
        let latency = Date().timeIntervalSince(t.start) * 1000
        let clientBytes = t.request.count + ws.clientBytes, upstreamBytes = ws.handshake.count + ws.upstreamBytes
        let handshake = ws.handshake
        // Rendered off the loop, after every message fed so far.
        ws.finish { transcript, streamed in
            TraceEmitter.emitWebSocket(
                session: t.session, store: store, profileID: t.profileID, host: t.host, port: t.port,
                preSwapRequest: t.request, handshakeResponse: handshake, transcript: transcript,
                clientBytes: clientBytes, upstreamBytes: upstreamBytes, statusCode: 101,
                swaps: t.swaps, leaks: t.leaks, latencyMs: latency, skipLLMExtract: streamed)
        }
    }

    /// One request's trace record (macOS: HTTPMitmConnection.emitTrace),
    /// off the event loop. A parsed conversation gets the prompt-injection
    /// log scan when the workspace's policy is on with "log but continue"
    /// (ask and block run before the request is forwarded: policyAnswer).
    /// The token-swap events go out whether traced or not, as the request
    /// is forwarded (RequestReader.rewrite), not here.

    // @port HTTPMitmConnection.emitTrace(host: String, port: Int, preSwapRequest: Data, upstreamResponse: Data, upstreamWireBytes: Int, responseTruncated: Bool, swaps: [SwapRecord], leaks: [LeakEntry], latencyMs: Double, servedBy: String?) h=87bd4b6a9748938b @c980e76e
    func emitTrace(_ t: RequestReader.Trace, response: Data, wireBytes: Int, truncated: Bool) {
        guard let store = traces.withLockedValue({ $0 }) else { return }
        let latency = Date().timeIntervalSince(t.start) * 1000
        Task {
            await TraceEmitter.emit(
                session: t.session, store: store, profileID: t.profileID, host: t.host, port: t.port,
                preSwapRequest: t.request, upstreamResponse: response, upstreamWireBytes: wireBytes,
                responseTruncated: truncated, swaps: t.swaps, leaks: t.leaks, latencyMs: latency,
                servedBy: t.servedBy,
                onConversation: { [weak self] conv in self?.logPromptInjection(in: conv, host: t.host, profileID: t.profileID) })
        }
    }

    /// The "log but continue" scan of a conversation (macOS:
    /// HTTPMitmConnection.logPromptInjection), detached, never delaying the
    /// traffic: the newest tool output through the source classifier
    /// (PromptGuard), and the instruction files it carries through the rules
    /// scanner and the CLAUDE.md classifier (ModernBERT). Without onnxruntime
    /// or the models the classifiers are absent (logged once): the rules pass
    /// still runs.
    // @port HTTPMitmConnection.static logPromptInjection(in: Conversation, policy: PromptInjectionPolicy, host: String, profileID: UUID) h=362b005a39f1838a @141c77e1
    func logPromptInjection(in conv: Conversation, host: String, profileID: UUID) {
        guard let pi = promptInjectionPolicy(for: profileID), pi.isActive, pi.onDetection == .log else { return }
        let pid = profileID
        if pi.detectSourceInjection {
            let untrusted = PromptInjectionRedactions.scannable(ToolResultSpans.newest(in: conv))
            if !untrusted.isEmpty {
                Task.detached(priority: .utility) {
                    await PromptInjectionClassifier.shared.scanAndLog(spans: untrusted, host: host, profileID: pid)
                }
            }
        }
        if pi.detectRulesInjection {
            let extra = RulesFileScanner.scannable(RulesFileScanner.conversationInstructionSpans(conv))
            RulesFileScanner.shared.scanAndLog(systemPrompt: conv.systemPrompt, extraSpans: extra, host: host, profileID: pid)
            let ruleSpans = RulesFileScanner.classifierSpans(conv.systemPrompt, extraSpans: extra)
            if !ruleSpans.isEmpty {
                Task.detached(priority: .utility) {
                    await PromptInjectionClassifier.claudeMd.scanAndLog(spans: ruleSpans, host: host, profileID: pid)
                }
            }
        }
    }

    /// Serves one VM's `<udsPath>_8443` (or `stored`, a restarted daemon's
    /// listener from the fd store) for workspace `profileID`.
    // @port-skip linux-only: the per-VM proxy listener (macOS: MitmEngine.register on the VZ socket device)
    func serve(udsPath: String, profileID: UUID, fdStoreName: String, stored: Int32? = nil) throws -> MitmListener {
        let path = HybridVsockListener.path(uds: udsPath, port: Self.vsockPort)
        let fd: Int32
        if let stored { fd = stored } else {
            fd = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [fd])
        }
        let channel = try ServerBootstrap(group: group)
            .childChannelInitializer { [self] ch in
                ch.pipeline.addHandler(ConnectHandler(proxy: self, profileID: profileID))
            }
            .withBoundSocket(fd).wait()
        return MitmListener(channel: channel, path: path, fdStoreName: fdStoreName)
    }

    /// A server context for `host` (http/1.1), minted on a miss.
    // @port-skip linux-only: NIOSSL leaves from CertCache.mintLeaf (macOS caches SecIdentities)
    func serverContext(host: String) throws -> NIOSSLContext {
        let hit: NIOSSLContext? = leaves.withLockedValue { s in
            guard let (c, _) = s.map[host] else { return nil }
            s.tick += 1
            s.map[host] = (c, s.tick)
            return c
        }
        if let hit { return hit }
        let (leaf, key) = try CertCache.mintLeaf(for: host, ca: ca)
        var ser = DER.Serializer()
        try ser.serialize(leaf)
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: ser.serializedBytes, format: .der)),
                               .certificate(caNIO)],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
        cfg.applicationProtocols = ["http/1.1"]
        let ctx = try NIOSSLContext(configuration: cfg)
        leaves.withLockedValue { s in
            s.tick += 1
            s.map[host] = (ctx, s.tick)
            if s.map.count > Self.leafCapacity, let oldest = s.map.min(by: { $0.value.1 < $1.value.1 })?.key {
                s.map.removeValue(forKey: oldest)
            }
        }
        return ctx
    }

    /// Where a request to `host:port` goes: what the on-host engine serves
    /// (the local-inference sentinel, `bromure.llm`, always; a real cloud LLM
    /// host when the workspace's routing sends it there: LLMRouting.decide)
    /// to the repair proxy on loopback, in clear (it fronts the workspace's
    /// engine); anything else as asked.
    // @port-skip linux-only: the dial half of HTTPProxy's routing step (LLMRouting.decide, shared)
    func route(host: String, port: Int, tls: Bool, profileID: UUID?) -> (host: String, port: Int, tls: Bool, local: Bool) {
        guard servedLocally(host: host, port: port, profileID: profileID) else { return (host, port, tls, false) }
        return (InferenceService.engineHost, InferenceService.repairProxyPort, false, true)
    }

    /// Connects to `host:port` (TLS, when `tls`) on `loop`; the channel is
    /// ready to write when the future holds. The server certificate is
    /// verified against the system roots, or only against the cluster CA
    /// `profileID`'s kubeconfig pins for that endpoint, which may also give
    /// the client certificate presented.
    // @port-skip linux-only: NIO upstream (macOS: URLSession / NWConnection)
    /// `local`: the request's routing, decided once by its plan (nil: decide here).
    // partial: emitted once a handshake made with the identity succeeded (NIOSSL can't say whether the server asked for it)
    // @port HTTPMitmConnection.static emitClientCertEvent(_: ClientIdentityRegistry.Entry, host: String, port: Int, profileID: UUID) h=d0b7db658ef87141 @003f61e7
    func connectUpstream(host: String, port: Int, tls requestedTLS: Bool, profileID: UUID? = nil,
                         pinned: [IPAddress]? = nil, local: Bool? = nil,
                         identity: OpenShellPolicy.BinaryIdentity? = nil, insecure: Bool = false,
                         on loop: EventLoop) -> EventLoopFuture<Channel> {
        let routed: (host: String, port: Int, tls: Bool, local: Bool) = local.map {
            $0 ? (InferenceService.engineHost, InferenceService.repairProxyPort, false, true) : (host, port, requestedTLS, false)
        } ?? route(host: host, port: port, tls: requestedTLS, profileID: profileID)
        if routed.local {
            guard let to = try? SocketAddress(ipAddress: routed.host, port: routed.port) else {
                return loop.makeFailedFuture(ProxyDestinationUnresolved(host: host, port: port))
            }
            return dial(host: host, to: [to], tls: routed.tls, ctx: upstreamContext, on: loop)
        }
        if refusesRealUpstreams, routeAllTo == nil {
            FileHandle.standardError.write(Data("[mitm] ✗ e2e mode with no test upstream: refused \(host):\(port)\n".utf8))
            return loop.makeFailedFuture(ProxyDestinationDenied(
                host: host, port: port, reason: "e2e mode with no test upstream: no real host is dialed"))
        }
        // An insecure request (X-bromure-insecure, allowed): no validation of
        // this upstream's certificate, for this connection only.
        let endpoint = insecure ? nil : profileID.flatMap { kubeTrust.endpoint(for: host, port: port, profileID: $0) }
        let ctx = insecure ? insecureUpstreamContext : endpoint?.context ?? upstreamContext
        // A client certificate the proxy presents for the guest: on the
        // Security Timeline once the handshake with it succeeded (macOS:
        // emitClientCertEvent; NIOSSL can't say whether the server asked).
        let presented: (Channel) -> Channel = { ch in
            if routed.tls, let id = endpoint?.identity, let pid = profileID {
                BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "credential.client_cert",
                                                    eventData: Self.clientCertEventData(id, host: host, port: port))
            }
            return ch
        }
        // Only to the addresses that passed the check, in order: the name is
        // never looked up again (a rebinding answer can't slip in between).
        // One destination check per connection, the workspace's (its OpenShell
        // route's address authorization too): a CONNECT's, made before the
        // tunnel was confirmed, or made here (plain HTTP, transparent).
        // Either way the dial uses exactly the addresses it passed.
        // No pinned addresses (a name the CONNECT left to the dial): checked now.
        let checked = pinned.flatMap { $0.isEmpty ? nil : loop.makeSucceededFuture($0) }
            ?? checkDestination(host: host, port: port, profileID: profileID, identity: identity, on: loop)
        return checked.flatMap { [self] resolved in
            if let r = routeAllTo, let to = try? SocketAddress.makeAddressResolvingHost(r.host, port: r.port) {
                return dial(host: host, to: [to], tls: routed.tls, ctx: ctx, on: loop).map(presented)
            }
            if refusesRealUpstreams {
                FileHandle.standardError.write(Data("[mitm] ✗ e2e mode: the test upstream isn't usable: refused \(host):\(port)\n".utf8))
                return loop.makeFailedFuture(ProxyDestinationDenied(
                    host: host, port: port, reason: "e2e mode: the test upstream isn't usable, so no real host is dialed"))
            }
            let addrs = resolved.compactMap { try? SocketAddress(ipAddress: "\($0)", port: port) }
            return dial(host: host, to: addrs, tls: routed.tls, ctx: ctx, on: loop).map(presented)
        }
    }

    /// Connects to the first of `addresses` that answers, for `host` (its
    /// SNI and certificate name when `tls`).
    // @port-skip linux-only: NIO upstream (macOS: UpstreamPinning.connect's race over the checked addresses)
    private func dial(host: String, to addresses: [SocketAddress], tls: Bool, ctx: NIOSSLContext,
                      on loop: EventLoop) -> EventLoopFuture<Channel> {
        guard let first = addresses.first else {
            return loop.makeFailedFuture(ProxyDestinationUnresolved(host: host, port: 0))
        }
        return dialOne(host: host, to: first, tls: tls, ctx: ctx, on: loop).flatMapError { [self] e in
            addresses.count > 1 ? dial(host: host, to: Array(addresses.dropFirst()), tls: tls, ctx: ctx, on: loop)
                                : loop.makeFailedFuture(e)
        }
    }

    // @port-skip linux-only: NIO upstream (macOS: URLSession / NWConnection)
    private func dialOne(host: String, to target: SocketAddress, tls: Bool, ctx: NIOSSLContext,
                         on loop: EventLoop) -> EventLoopFuture<Channel> {
        let isIP = host.contains(":") || host.split(separator: ".").allSatisfy { UInt8($0) != nil }
        let ready = OncePromise(loop.makePromise(of: Channel.self))
        ClientBootstrap(group: loop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(15))
            .channelInitializer { ch in
                guard tls else { return ch.eventLoop.makeSucceededVoidFuture() }
                do {
                    // No SNI for an IP literal (RFC 6066); its certificate is
                    // still bound to the address (`.fullVerification`: an IP SAN
                    // equal to the connected address, or the handshake fails).
                    return ch.pipeline.addHandlers([
                        try NIOSSLClientHandler(context: ctx, serverHostname: isIP ? nil : host),
                        HandshakeWaiter(ready),
                    ])
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }
            .connect(to: target)
            .whenComplete { r in
                switch r {
                case .failure(let e): ready.fail(e)
                case .success(let ch): if !tls { ready.succeed(ch) }
                }
            }
        return ready.promise.futureResult
    }
}

/// A promise completed at most once, whichever side settles it first (all
/// on its event loop).
// @port-skip linux-only: NIO plumbing
final class OncePromise<T>: @unchecked Sendable {
    let promise: EventLoopPromise<T>
    private var settled = false
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(_ p: EventLoopPromise<T>) { promise = p }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func succeed(_ v: T) { guard !settled else { return }; settled = true; promise.succeed(v) }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func fail(_ e: Error) { guard !settled else { return }; settled = true; promise.fail(e) }
}

/// One VM's proxy listener.
// @port-skip linux-only: the per-VM proxy listener
final class MitmListener: @unchecked Sendable {
    let channel: Channel
    let path: String
    let fdStoreName: String
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(channel: Channel, path: String, fdStoreName: String) {
        self.channel = channel
        self.path = path
        self.fdStoreName = fdStoreName
    }
    /// The VM is gone: the listener closed and its socket file removed.
    // @port-skip linux-only: the per-VM proxy listener
    func stop() {
        channel.close(promise: nil)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Fulfils `promise` once the upstream TLS handshake completed, then leaves.
// @port-skip linux-only: NIO plumbing
final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    let ready: OncePromise<Channel>
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(_ r: OncePromise<Channel>) { ready = r }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            ready.succeed(context.channel)
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(error)
        context.close(promise: nil)
    }
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        ready.fail(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }
}

/// The guest side, before TLS: the bridge's `BROMURE-CLIENT` line, then
/// CONNECT (answered 200, then the ClientHello names the leaf) or a plain
/// absolute-form HTTP request, handed to a RequestReader as it is.
// @port-skip linux-only: HTTPMitmConnection.drive's CONNECT phase on NIO
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let proxy: MitmProxy
    let profileID: UUID
    private var buf = ByteBuffer()
    private enum Phase {
        case preamble, request, checking, handedOff
        /// The tunnel is confirmed; the destination's checked addresses are
        /// the only ones the upstream may dial.
        case hello(host: String, port: Int, addresses: [MitmProxy.IPAddress])
    }
    private var phase = Phase.preamble
    /// The bridge's preamble claim (its client's source port), counted when
    /// the line arrived: the proxied target is recorded under it, tying the
    /// kernel sentry's loopback flow to the process chain (macOS: drive's
    /// NetworkLineage.noteClaimant / noteProxied).
    private var claim: NetworkLineage.Claim?
    /// The bridge's client address (the preamble's `peer`), with its port
    /// what names the connection for agentd's reset.
    private var clientPeer: String?

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(proxy: MitmProxy, profileID: UUID) {
        self.proxy = proxy
        self.profileID = profileID
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Handed off (a TLS session, a request reader, a splice's relay):
        // what still arrives here goes on to them.
        if case .handedOff = phase { context.fireChannelRead(data); return }
        var b = unwrapInboundIn(data)
        buf.writeBuffer(&b)
        step(context)
    }

    // partial: the CONNECT and forward-proxy phase as a NIO handler (the preamble read inline)
    // @port HTTPMitmConnection.drive() h=7f3159458662d106 @003f61e7
    private func step(_ context: ChannelHandlerContext) {
        while true {
            switch phase {
            case .preamble:
                let prefix = Array("BROMURE-CLIENT ".utf8)
                let view = Array(buf.readableBytesView.prefix(prefix.count))
                if view.count < prefix.count, view == Array(prefix.prefix(view.count)) { return }
                if view == prefix {
                    guard let nl = buf.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                        if buf.readableBytes > 512 { context.close(promise: nil) }
                        return
                    }
                    let line = String(decoding: buf.readableBytesView[buf.readerIndex..<nl], as: UTF8.self)
                    buf.moveReaderIndex(forwardBy: nl - buf.readerIndex + 1)
                    if let sport = Self.preambleSport(line) {
                        claim = NetworkLineage.shared.noteClaimant(profileID: profileID, sport: sport)
                        clientPeer = Self.preamblePeer(line)
                    }
                }
                phase = .request
            case .request:
                guard let end = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else {
                    if buf.readableBytes > 64 << 10 { context.close(promise: nil) }
                    return
                }
                let line = String(decoding: buf.readableBytesView.prefix(while: { $0 != 13 }), as: UTF8.self)
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { return reject(context, 400, "Bad Request") }
                if parts[0] == "CONNECT" {
                    let (host, port) = Self.split(String(parts[1]), defaultPort: 443)
                    if let claim { NetworkLineage.shared.noteProxied(profileID: profileID, claim: claim, host: host, port: port) }
                    // A quarantined workspace opens no tunnel (a `tls: skip`
                    // splice included, which never reaches RequestReader).
                    if WorkspaceQuarantine.shared.contains(profileID) {
                        return answer(context, String(decoding: RequestReader.simple(403, "Forbidden", body: WorkspaceQuarantine.refusal + "\n"),
                                                      as: UTF8.self))
                    }
                    buf.moveReaderIndex(forwardBy: end.upperBound - buf.readerIndex)
                    // Connection-layer egress verdict for the cooperative-proxy
                    // path (macOS: HTTPMitmConnection.run): a deny is the
                    // CONNECT's 403.
                    let policy = proxy.guardrailsConfig(for: profileID)?.egressPolicy
                    let verdict = ProxyPolicy.egressVerdict(policy: policy, profileID: profileID,
                                                            host: host, port: port, identity: nil)
                    if verdict == .deny {
                        return answer(context, ProxyPolicy.connectDenied(policy: policy, profileID: profileID,
                                                                         host: host, port: port))
                    }
                    // The destination is checked before the tunnel is
                    // confirmed (a refusal is the CONNECT's 403).
                    phase = .checking
                    proxy.checkDestination(host: host, port: port, profileID: profileID,
                                           on: context.eventLoop).whenComplete { [self] r in
                        switch r {
                        case .failure(let e as ProxyDestinationDenied):
                            phase = .handedOff
                            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
                                bytes: MitmProxy.destinationDeniedResponse(host: host, port: port, reason: e.reason))))
                                .whenComplete { _ in context.close(promise: nil) }
                        case .failure(let e):
                            if !(e is ProxyDestinationUnresolved) {
                                FileHandle.standardError.write(Data("[mitm] CONNECT \(host):\(port) not checked: \(e)\n".utf8))
                            }
                            reject(context, 502, "Bad Gateway")
                        case .success(let addresses):
                            ProxyPolicy.reportAllowed(policy: proxy.guardrailsConfig(for: profileID)?.egressPolicy,
                                                      profileID: profileID, host: host, port: port)
                            guard proxy.trackForFirewall(context.channel, profileID: profileID,
                                                         host: host, port: port, route: "proxy",
                                                         clientSport: claim?.sport, clientPeer: clientPeer),
                                  // Tracked (cutAll reaches it from now), then
                                  // checked: a quarantine since the CONNECT is seen.
                                  !WorkspaceQuarantine.shared.contains(profileID) else {
                                phase = .handedOff
                                context.close(promise: nil)
                                return
                            }
                            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
                                string: "HTTP/1.1 200 Connection Established\r\n\r\n")), promise: nil)
                            // An OpenShell `tls: skip` endpoint is relayed raw, never terminated.
                            if verdict == .splice {
                                phase = .handedOff
                                let rest = buf
                                buf.clear()
                                proxy.splice(context.channel, to: addresses, port: port, pending: rest)
                                context.pipeline.removeHandler(self, promise: nil)
                                return
                            }
                            phase = .hello(host: host, port: port, addresses: addresses)
                            step(context)
                        }
                    }
                    return
                }
                // A plain-HTTP request through the proxy: absolute form.
                guard let url = URL(string: String(parts[1])), url.scheme?.lowercased() == "http",
                      let rawHost = url.host else { return reject(context, 405, "Method Not Allowed") }
                let host = EgressPolicy.normalizedHost(rawHost)   // as every decision sees it
                let port = url.port ?? 80
                if let claim { NetworkLineage.shared.noteProxied(profileID: profileID, claim: claim, host: host, port: port) }
                let policy = proxy.guardrailsConfig(for: profileID)?.egressPolicy
                if host.lowercased() != OpenShellAdvisor.host,
                   ProxyPolicy.egressVerdict(policy: policy, profileID: profileID, host: host, port: port,
                                             identity: nil) == .deny {
                    return answer(context, ProxyPolicy.connectDenied(policy: policy, profileID: profileID,
                                                                     host: host, port: port))
                }
                ProxyPolicy.reportAllowed(policy: policy, profileID: profileID, host: host, port: port)
                guard proxy.trackForFirewall(context.channel, profileID: profileID,
                                             host: host, port: port, route: "proxy",
                                             clientSport: claim?.sport, clientPeer: clientPeer) else {
                    phase = .handedOff
                    context.close(promise: nil)
                    return
                }
                handOff(context, RequestReader(proxy: proxy, profileID: profileID, host: host,
                                               port: port, tls: false), tlsHost: nil)
                return
            case .hello(let host, let port, let addresses):
                switch ClientHelloInfo.parse(buf) {
                case .needMore: return
                case .notTLS: return reject(context, 400, "Bad Request")
                case .hello:
                    // The tunnel is the CONNECT host's (macOS: driveTLS for
                    // the CONNECT target): every check above was made for it,
                    // so it is what the leaf names and the upstream dials —
                    // only the addresses checked for it. The ClientHello's SNI
                    // routes nothing: a client that names another host fails
                    // its own certificate check against this leaf.
                    handOff(context, RequestReader(proxy: proxy, profileID: profileID, host: host,
                                                   port: port, tls: true, pinned: addresses), tlsHost: host)
                    return
                }
            case .checking, .handedOff:
                return
            }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func handOff(_ context: ChannelHandlerContext, _ reader: RequestReader, tlsHost: String?) {
        phase = .handedOff
        do {
            let ops = context.pipeline.syncOperations
            if let tlsHost {
                let tls = NIOSSLServerHandler(context: try proxy.serverContext(host: tlsHost))
                try ops.addHandler(tls, position: .after(self))
                try ops.addHandler(reader, position: .after(tls))
            } else {
                try ops.addHandler(reader, position: .after(self))
            }
        } catch {
            context.close(promise: nil)
            return
        }
        let rest = buf
        buf.clear()
        if rest.readableBytes > 0 { context.fireChannelRead(NIOAny(rest)) }
        context.pipeline.removeHandler(self, promise: nil)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func answer(_ context: ChannelHandlerContext, _ response: String) {
        phase = .handedOff
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: response)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func reject(_ context: ChannelHandlerContext, _ status: Int, _ reason: String) {
        phase = .handedOff
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
            string: "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
            .whenComplete { _ in context.close(promise: nil) }
    }

    /// The client port a `BROMURE-CLIENT 1 sport=<n> …` line names, when
    /// well formed (macOS: stripClientPreamble's parse).
    // partial: the line's parse (the bytes are consumed by the handler, not here)
    // @port HTTPMitmConnection.static stripClientPreamble(_: inoutData) h=223c2f727a7cb008 @285807ef
    static func preambleSport(_ line: String) -> Int? {
        for field in line.split(separator: " ") where field.hasPrefix("sport=") {
            if let n = Int(field.dropFirst(6)), (1...65535).contains(n) { return n }
        }
        return nil
    }

    /// The preamble's `peer=<ip>`.
    // @port-skip linux-only: the preamble's peer, for agentd's reset
    static func preamblePeer(_ line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix("peer=") }.map { String($0.dropFirst(5)) }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func split(_ target: String, defaultPort: Int) -> (String, Int) {
        // The host every decision then sees: lowercased, a fully qualified
        // name's trailing dots gone (`registry.npmjs.org.` is npm's registry).
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let h = String(target[target.index(after: target.startIndex)..<close])
            return (h.lowercased(), Int(target[target.index(after: close)...].dropFirst()) ?? defaultPort)
        }
        if let c = target.lastIndex(of: ":"), let p = Int(target[target.index(after: c)...]) {
            return (EgressPolicy.normalizedHost(String(target[..<c])), p)
        }
        return (EgressPolicy.normalizedHost(target), defaultPort)
    }
}

/// One request from the guest (plaintext: after the TLS handler, or a plain
/// HTTP request), read whole, then rewritten and sent on (RequestReader.forward).
// @port-skip linux-only: HTTPMitmConnection.driveTLS's request phase on NIO
final class RequestReader: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let proxy: MitmProxy
    let profileID: UUID
    let host: String
    let port: Int
    let tls: Bool
    /// The addresses this connection's destination check passed (a
    /// CONNECT's): the upstream dials only these, never re-resolving.
    let pinned: [MitmProxy.IPAddress]?
    /// The program that opened a transparent flow, as the guest's attestor
    /// named it (strict sandbox + a policy's `binaries`); nil elsewhere
    /// (macOS: HTTPMitmConnection.binaryIdentity).
    let identity: OpenShellPolicy.BinaryIdentity?
    private var buf = ByteBuffer()
    private var started = false
    /// After the request went upstream: the guest's further bytes (a
    /// WebSocket's frames) go to the upstream channel, once its reply
    /// switched protocols (`upgraded`).
    private var upstream: Channel?
    /// The upstream's relay, whose one decision resumes its reads. Weak:
    /// the relay's hooks reach back here (the upstream's pipeline holds it).
    private weak var relay: ResponseRelay?
    private var pending: [ByteBuffer] = []
    private var pendingBytes = 0
    /// One request per connection (each is checked, swapped and decided
    /// alone): past the first, the guest's bytes go upstream only for an
    /// upgrade the upstream accepted (101). Until it answers they're held,
    /// up to `maxHeld`; a request pipelined behind a plain one is dropped
    /// (the guest gets its reply and the close, and asks again).
    private var awaitingUpgrade = false
    private var upgraded = false
    /// A guarded WebSocket's client → model direction (WebSocketGuardLinux.swift).
    private var wsFilter: WSClientFilter?
    /// An OpenShell WebSocket route's gate on the guest's frames, once
    /// switched (ProxyPolicy.webSocketPlan): what it lets through goes
    /// upstream; a denied message ends the session with a 1008 close.
    private var wsGate: OpenShellWebSocket.ClientStream?
    /// The filter's say on reading the guest: false while it holds too much.
    private var filterWantsGuest = true
    /// A model provider's switched socket keeps its agent "working"
    /// (ActivityBeat), from the guest's frames and the server's.
    private var beat: ActivityBeat?
    static let maxHeld = 1 << 20
    /// A streamed upload (macOS: driveTLS's 5z, a body past the 8 MiB
    /// inline cap, e.g. a docker layer PUT): its head goes through the
    /// policy alone, then its body follows upstream as it comes, neither
    /// buffered whole nor refused: `streamLeft` more bytes of it (nil:
    /// chunked, up to the reply). Not under an OpenShell policy, whose
    /// strict framing reads the request whole.
    private var streaming = false
    private var streamLeft: Int?
    /// A streamed chunked body, decoded and framed again as it goes.
    private var chunks: HTTPRequestFraming.ChunkStream?
    static let inlineCap = 8 << 20
    /// This connection's cut at its workspace's quarantine (WorkspaceQuarantine).
    private var quarantineCut: UUID?

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool,
         pinned: [MitmProxy.IPAddress]? = nil, identity: OpenShellPolicy.BinaryIdentity? = nil) {
        self.proxy = proxy
        self.profileID = profileID
        self.host = host
        self.port = port
        self.tls = tls
        self.pinned = pinned
        self.identity = identity
    }

    /// A quarantine's start closes the connection, whatever it carries (an
    /// upgraded tunnel included); one opened during a quarantine has its
    /// request refused (rewrite), not closed under the initializer.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        // Closed on the loop's next turn: never inside a channel initializer.
        quarantineCut = WorkspaceQuarantine.shared.onQuarantine(profileID, runNow: false) { [weak channel] in
            channel?.eventLoop.execute { channel?.close(promise: nil) }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if started {
            if streaming {
                // Reads are paused until the upstream is up; what was in
                // flight waits with the body's first bytes.
                if let upstream { forwardStreamed(b, to: upstream, guest: context.channel) } else {
                    pending.append(b)
                    pendingBytes += b.readableBytes
                }
                return
            }
            if upgraded, let upstream {
                relay?.wsTrace?.client(b)
                beat?.tick(Data(b.readableBytesView.prefix(64)))
                if wsGate != nil {
                    gateToUpstream(Data(b.readableBytesView), guest: context.channel, upstream: upstream)
                    return
                }
                if let wsFilter {
                    wsFilter.feed(Data(b.readableBytesView))
                    if !upstream.isWritable { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
                    return
                }
                upstream.write(b, promise: nil)
                // The upstream can't take more: the guest isn't read until it
                // drains (its ResponseRelay resumes it). Paused before the flush.
                if !upstream.isWritable { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
                upstream.flush()
                return
            }
            guard awaitingUpgrade || upstream == nil else { return }   // behind a plain request: dropped
            pendingBytes += b.readableBytes
            guard pendingBytes <= Self.maxHeld else { context.close(promise: nil); return }
            pending.append(b)
            return
        }
        buf.writeBuffer(&b)
        // Under an OpenShell policy the read is strict (OpenShell's framing
        // rules, as macOS's readRequestSpooling): a violation is a 400 that
        // says why, before any policy step.
        let strict = proxy.guardrailsConfig(for: profileID)?.egressPolicy?.openShell != nil
        if !strict, let headEnd = buf.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) {
            let head = Data(buf.readableBytesView[buf.readerIndex..<headEnd.upperBound])
            // Body framing an upstream could read otherwise than this proxy:
            // refused before any body is read or streamed.
            // OpenShell's byte-level head checks too (bare LF, folds, space
            // before a colon, control bytes, invalid UTF-8): an upstream
            // parsing the head otherwise than this proxy would frame it so.
            let parsedHead: String? = { do { _ = try OpenShellHTTP.parseHead(head); return nil }
                                        catch let e as OpenShellHTTP.Rejection { return e.reason }
                                        catch { return "the request head can't be read" } }()
            if let why = parsedHead ?? HTTPRequestFraming.headFramingProblem(String(decoding: head.dropLast(4), as: UTF8.self)) {
                reply(context, ProxyPolicy.beforePolicyAnswer(status: 400, error: "invalid_http_request", detail: why,
                                                              host: host, port: port, profileID: profileID,
                                                              scheme: tls ? "https" : "http"))
                return
            }
            let decision = Self.streamsBody(head, buffered: buf.readableBytes - head.count)
            if decision.stream {
                startStreaming(context, head: head, length: decision.length)
                return
            }
        }
        switch HTTPRequestFraming.complete(Data(buf.readableBytesView), strict: strict) {
        case .needMore:
            if buf.readableBytes > MitmProxy.maxBody { reply(context, Self.simple(413, "Payload Too Large")) }
        case .invalid:
            reply(context, Self.simple(400, "Bad Request"))
        case .rejected(let why):
            reply(context, ProxyPolicy.beforePolicyAnswer(status: 400, error: "invalid_http_request", detail: why,
                                                          host: host, port: port, profileID: profileID,
                                                          scheme: tls ? "https" : "http"))
        case .complete(let request, let extra):
            started = true
            if !extra.isEmpty {
                pending.append(context.channel.allocator.buffer(bytes: extra))
                pendingBytes += extra.count
            }
            let loop = context.eventLoop
            let channel = context.channel
            let (proxy, pid, host, port, tls) = (self.proxy, profileID, self.host, self.port, self.tls)
            let start = Date()
            // The strict-credential session this request belongs to: what its
            // reply teaches the guard counts only while it's still current.
            let session = proxy.strictSession(of: pid)
            Task {
                var trace = proxy.traceSession(for: pid).map {
                    Trace(session: $0, profileID: pid, host: host, port: port, start: start, request: request)
                }
                let plan = await Self.rewrite(request, proxy: proxy, profileID: pid, host: host, port: port, tls: tls,
                                              session: session, trace: &trace, identity: identity)
                loop.execute { self.send(plan, trace: trace, channel: channel, host: host, port: port, tls: tls, session: session) }
            }
        }
    }

    /// Whether a request's body is streamed (5z): a Content-Length past the
    /// inline cap, or a chunked body that grew past it; `length` is the
    /// declared one (nil: chunked).
    // partial: a body past the inline cap is streamed upstream as it arrives (no temp file); not under OpenShell's strict framing
    // @port readRequestSpooling(via: MitmServerStream, inlineCap: Int, strict: Bool) h=61da3613f04a2f7c @003f61e7
    static func streamsBody(_ head: Data, buffered: Int) -> (stream: Bool, length: Int?) {
        let text = String(decoding: head, as: UTF8.self)
        if let te = SubscriptionAuthRewrite.headerValue("transfer-encoding", inHeaderSection: text),
           te.lowercased().contains("chunked") {
            return (buffered > inlineCap, nil)
        }
        guard let cl = SubscriptionAuthRewrite.headerValue("content-length", inHeaderSection: text)
                .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), cl > inlineCap else { return (false, nil) }
        return (true, cl)
    }

    /// The head through the policy (spooled: the steps macOS's 5z skips
    /// aren't run), the body held (reads paused) until the upstream is up.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 5z step, on the Linux request chain
    private func startStreaming(_ context: ChannelHandlerContext, head: Data, length: Int?) {
        started = true
        streaming = true
        streamLeft = length
        if length == nil { chunks = HTTPRequestFraming.ChunkStream() }
        buf.moveReaderIndex(forwardBy: head.count)
        if buf.readableBytes > 0 {
            pending.append(buf)
            pendingBytes += buf.readableBytes
        }
        buf = ByteBuffer()
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        let loop = context.eventLoop
        let channel = context.channel
        let (proxy, pid, host, port, tls) = (self.proxy, profileID, self.host, self.port, self.tls)
        let start = Date()
        let session = proxy.strictSession(of: pid)
        FileHandle.standardError.write(Data("[mitm] streaming a \(length.map { "\($0)-byte" } ?? "chunked") request body to \(host)\n".utf8))
        Task {
            var trace = proxy.traceSession(for: pid).map {
                Trace(session: $0, profileID: pid, host: host, port: port, start: start, request: head)
            }
            let plan = await Self.rewrite(head, proxy: proxy, profileID: pid, host: host, port: port, tls: tls,
                                          session: session, trace: &trace, identity: identity, spooled: true)
            loop.execute { self.send(plan, trace: trace, channel: channel, host: host, port: port, tls: tls, session: session) }
        }
    }

    /// The streamed body's next bytes upstream, no further than its length
    /// (what follows a request isn't another one here); the guest read
    /// again only while the upstream takes more.
    // @port-skip linux-only: relayUpstream's upload of a spooled body, on NIO
    private func forwardStreamed(_ b: ByteBuffer, to upstream: Channel, guest: Channel) {
        var b = b
        if chunks != nil {
            // Chunked: decoded and framed again; nothing past the last chunk
            // goes, and broken framing ends both sides.
            guard chunks?.isDone == false else { return }
            let out = chunks!.feed(Data(b.readableBytesView))
            if chunks!.isBroken {
                FileHandle.standardError.write(Data("[mitm] a streamed chunked body to \(host) is malformed: closed\n".utf8))
                upstream.close(promise: nil)
                guest.close(promise: nil)
                return
            }
            guard !out.isEmpty else { return }
            b = upstream.allocator.buffer(bytes: out)
        } else if let left = streamLeft {
            guard left > 0 else { return }
            if b.readableBytes > left { b = b.getSlice(at: b.readerIndex, length: left) ?? b }
            streamLeft = left - b.readableBytes
        }
        upstream.write(b, promise: nil)
        if !upstream.isWritable { _ = guest.setOption(ChannelOptions.autoRead, value: false) }
        upstream.flush()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        if let quarantineCut { WorkspaceQuarantine.shared.remove(quarantineCut, for: profileID) }
        wsFilter?.cancel()           // a scan, and an ask it's waiting on, dropped
        upstream?.close(promise: nil)
        relay = nil
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    enum Plan {
        case answer(Data)
        case forward(Data, SubscriptionAuthRewrite.Injected, capture: SignInCapture?, upgrade: Bool,
                     mint: CredentialMint.Kind? = nil, ws: WSPromptGuard? = nil, pii: PIIVault? = nil,
                     supplyChain: SupplyChainRewrite? = nil, dial: (host: String, port: Int)? = nil,
                     local: Bool = false, wsPolicy: ProxyPolicy.WebSocketPolicy? = nil, squelchLearn: Bool = false,
                     insecure: Bool = false)
    }

    /// What a traced request's record is made of, besides its response.
    struct Trace {
        let session: TraceSession
        let profileID: UUID
        let host: String
        let port: Int
        let start: Date
        /// The request as the guest sent it (before any swap; its body decoded
        /// when a content scan decoded it).
        var request: Data
        var swaps: [SwapRecord] = []
        var leaks: [LeakEntry] = []
        /// Which backend served the turn (LLMRouting's marker), if routed.
        var servedBy: String?
    }

    /// The request as it goes upstream, or the host's own answer, in
    /// macOS's order: the subscription swaps (5c–5e), the token map's, then
    /// the 5f sign-in capture on what would go out.
    // partial: the Linux request chain on NIO, its steps in MitmEgress, MitmMCPAuth, MitmInsecure, SupplyChainLinux and DaemonSquelch; subscription auth before the token swap; no Fusion yet
    // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) h=6a58d8d477c0e920 @81c0b354
    static func rewrite(_ raw: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool,
                        session: UInt64, trace: inout Trace?,
                        identity: OpenShellPolicy.BinaryIdentity? = nil, spooled: Bool = false) async -> Plan {
        var req = origin(raw)
        // A quarantined workspace's requests go nowhere.
        if WorkspaceQuarantine.shared.contains(profileID) {
            return .answer(RequestReader.simple(403, "Forbidden", body: WorkspaceQuarantine.refusal + "\n"))
        }
        if let answer = await policyAnswer(&req, proxy: proxy, profileID: profileID, host: host, port: port, tls: tls,
                                           session: session, identity: identity) {
            return .answer(answer)
        }
        let head = SubscriptionAuthRewrite.rawHeaderSection(of: req) ?? ""
        let line = head.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        let method = line.first.map(String.init) ?? ""
        let path = line.count > 1 ? String(line[1]) : "/"
        // A brokered MCP server's OAuth discovery: not found (macOS: 4a).
        if let answer = mcpDiscoveryAnswer(path: path, host: host, profileID: profileID, proxy: proxy) { return .answer(answer) }
        // A local agent's non-LLM cloud calls (strictly-local routing): an
        // empty 200, never sent (macOS: HTTPProxy's short-circuit).
        if let answer = proxy.localShortCircuit(host: host, path: path, profileID: profileID) { return .answer(answer) }
        var upgrade = SubscriptionAuthRewrite.headerValue("upgrade", inHeaderSection: head) != nil
        // A package registry speaks no WebSocket (macOS refuses the upgrade
        // before its supply-chain checks would be skipped).
        if upgrade, SupplyChainRegistry.isRegistryRequest(host: host, path: path) {
            SupplyChainLog.shared.record("[supply-chain] ✗ WebSocket upgrade to \(host)\(path) refused (a package registry)")
            return .answer(RequestReader.simple(400, "Bad Request",
                body: "Bromure: a WebSocket upgrade to a package registry is refused (its requests go through the supply-chain checks).\n"))
        }
        // Only an upgrade the pump is for (macOS: pumpedUpgrade): exactly
        // one Upgrade header naming websocket or SPDY/3.1 (kubectl exec,
        // attach, port-forward) and nothing else, in a clean header block.
        // Anything else (h2c above all, which would carry every later request
        // past the per-request policy) goes on as plain HTTP/1.1, its Upgrade,
        // Connection and HTTP2-Settings dropped as hop-by-hop. The WebSocket
        // steps below read frames: an SPDY stream is an opaque pipe.
        var webSocket = false
        if upgrade, ResponseRelay.pumpedUpgrade(headerBlock: head) {
            webSocket = ResponseRelay.upgradeToken(head) == "websocket"
        } else if upgrade || SubscriptionAuthRewrite.headerValue("http2-settings", inHeaderSection: head) != nil {
            req = HTTPRequestFraming.replacingHeaders(req, drop: ["upgrade", "http2-settings", "connection"], add: nil)
            upgrade = false
        }
        // Where this request goes, decided once: the PII step, the WebSocket
        // guard, the engine's auth and the dial all follow it (a routing
        // change between them can't split a request). An upgrade to a
        // rerouted cloud host is dialled for real, PII-guarded, as macOS
        // (its WebSocket path has no routing step); the sentinel is local.
        let local = host.lowercased() == InferenceService.localMitmHost
            || (!upgrade && proxy.servedLocally(host: host, port: port, profileID: profileID))
        if trace != nil, !upgrade { trace?.servedBy = proxy.servedByMarker(host: host, port: port, profileID: profileID) }
        // The guest's `X-bromure-insecure: yes`, where the workspace allows
        // it: no upstream certificate validation, and so no real credential
        // on this request (MitmInsecure.swift).
        // Not on an upgrade: its upstream is always validated (macOS's
        // handleWebSocketUpgrade), so OpenShell's WebSocket credential
        // rewrite never puts a real secret in front of an unverified server.
        let insecure = !upgrade && insecureBypass(req, proxy: proxy, profileID: profileID, host: host)
        var injected = SubscriptionAuthRewrite.Injected()
        // Pre-swap: unswapped Bearer / x-api-key tokens, for the trace and
        // the log (our own stand-ins aren't leaks).
        let leaks = SubscriptionAuthRewrite.filterStandInLeaks(
            proxy.swapper.detectLeaks(in: req, profileID: profileID), request: req, host: host, profileID: profileID)
        trace?.leaks = leaks
        if tls, !insecure {
            switch await SubscriptionAuthRewrite.apply(rawRequest: req, host: host, method: method, path: path,
                                                       profileID: profileID, spooledBody: spooled) {
            case .answer(let reply): return .answer(reply)
            case .forward(let r, let i): req = r; injected = i
            }
        }
        let placeholderBody = resolvesPlaceholderBody(req, proxy: proxy, profileID: profileID, host: host, port: port, path: path)
        let swapped = insecure ? SwapResult(modified: req, swaps: [])
            : await proxy.swapper.swap(rawRequest: req, host: host, port: port, profileID: profileID,
                                       placeholderBody: placeholderBody)
        req = swapped.modified
        // macOS's log lines: each swap (previews only), then each leak.
        for sw in swapped.swaps {
            FileHandle.standardError.write(Data("[mitm] swapped \(sw.fakePreview) → \(sw.realPreview) on \(sw.host)\n".utf8))
        }
        for leak in leaks {
            FileHandle.standardError.write(Data(
                "[mitm] LEAK \(leak.header)=\(leak.valuePreview) on \(host) (\(leak.suspicion.rawValue))\n".utf8))
        }
        // An OpenShell placeholder still there where it would have been
        // resolved: its credential isn't bound to this host or path, and
        // OpenShell refuses the request rather than forward it; so does Bromure.
        if !insecure, let unresolved = unresolvedPlaceholder(in: req, checkBody: placeholderBody,
                                                            known: proxy.swapper.entries(for: profileID).map(\.fake)) {
            let variable = String(unresolved.dropFirst(TokenSwapper.openShellPlaceholderPrefix.count))
            return .answer(ProxyPolicy.beforePolicyAnswer(
                status: 403, error: "credential_endpoint_mismatch",
                detail: "the credential for \(variable) is not bound to \(host)\(path.split(separator: "?").first.map(String.init) ?? "")",
                host: host, port: port, profileID: profileID, scheme: tls ? "https" : "http"))
        }
        // The brokered MCP server's real bearer (macOS: 5b, after the swap).
        if !insecure { req = injectingMCPBearer(req, host: host, profileID: profileID, proxy: proxy) }
        trace?.swaps = swapped.swaps
        // The supply-chain policy: a package fetch refused, or its reply read
        // whole and rewritten (macOS: driveTLS's supply-chain block).
        var supplyChain: SupplyChainRewrite?
        // Depi's re-route: redialled to Depi with the workspace's key.
        var depiKey: String?
        // A streamed upload (5z) carries a blob, not a lookup, a package fetch
        // or a conversation: on macOS it's forwarded before the Depi,
        // supply-chain and content steps, so it skips them here too.
        if !spooled {
            switch depiRoute(&req, proxy: proxy, profileID: profileID, host: host, method: method, path: path) {
            case .none: break
            case .routed(let key): depiKey = key
            case .refused(let reply): return .answer(reply)
            }
        }
        let dial = depiKey.map { _ in (host: DepiRegistry.host, port: DepiRegistry.port) }
        switch spooled ? .none : await supplyChainStep(req, proxy: proxy, profileID: profileID, host: host, method: method,
                                                        path: path, depiKey: depiKey) {
        // @port-skip linux-only: a case of the Linux request chain's own steps (see rewrite's @port)
        case .none: break
        // @port-skip linux-only: a case of the Linux request chain's own steps (see rewrite's @port)
        case .answer(let reply): return .answer(reply)
        // @port-skip linux-only: a case of the Linux request chain's own steps (see rewrite's @port)
        case .rewrite(let forward, let rewrite, let done):
            req = Self.readWhole(forward)
            upgrade = false
            supplyChain = SupplyChainRewrite(rewrite: rewrite, bodiless: method.uppercased() == "HEAD", done: done)
        }
        // Prompt injection, ask or block, before the model sees a byte
        // (macOS: driveTLS's enforcement after the swaps; log mode stays in
        // the trace's conversation hook).
        if !spooled, let answer = await promptInjectionAnswer(&req, proxy: proxy, profileID: profileID, host: host,
                                                              path: path, trace: &trace) {
            return .answer(answer)
        }
        // Squelch: command-output noise cut before the model reads it (and
        // before PII scans it), as macOS's driveTLS does.
        if !spooled { squelchStep(&req, proxy: proxy, profileID: profileID, host: host, method: method, trace: &trace) }
        // PII protection: stand-ins for personal data before it leaves; the
        // relay restores the reply (macOS: driveTLS's PII step).
        let pii: (answer: Data?, vault: PIIVault?) = spooled ? (nil, nil) : await piiSwap(&req, proxy: proxy, profileID: profileID, host: host,
                                                         method: method, path: path, local: local)
        if let answer = pii.answer { return .answer(answer) }
        // An imported kubeconfig's client certificate flagged for approval:
        // asked before it's presented (macOS asks at the server's challenge,
        // and before an upgrade); refused with a real reply, not a close.
        if tls, let id = proxy.kubeTrust.endpoint(for: host, port: port, profileID: profileID)?.identity,
           let credID = id.consentCredentialID {
            FileHandle.standardError.write(Data("[mitm] client-cert use on \(host) gated → consent \(credID)\n".utf8))
            let allowed = await proxy.consent.consent(
                profileID: profileID, credentialID: credID, credentialDisplayName: id.consentDisplayName ?? credID,
                scopeHint: String(format: NSLocalizedString("to authenticate with the API server at %@", comment: ""), host))
            if !allowed {
                return .answer(simple(403, "Forbidden", body: "Bromure: client-certificate use denied for \(host)\n"))
            }
        }
        // A call that issues a credential (sts:AssumeRole, ecr:GetAuthorizationToken,
        // doctl registry/kubernetes …): its response is read whole and the
        // credentials in it replaced by fakes before the guest sees it; one
        // whose secret no fake can stand in for is refused (macOS: driveTLS's
        // CredentialMint step). The reply is asked for uncompressed.
        var mint: CredentialMint.Kind?
        switch CredentialMint.classify(rawRequest: req, host: host) {
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .deny(let action)?: h=874cd336f92fc431 @003f61e7
        case .deny(let action)?:
            FileHandle.standardError.write(Data("[mitm] refused \(action) on \(host): issues an unswappable credential\n".utf8))
            return .answer(CredentialMint.denial(action))
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .mint(let kind)?: h=d911a89e0b382939 @003f61e7
        case .mint(let kind)?:
            // Its reply is read whole and rewritten: not a streamed body's.
            if spooled { return .answer(CredentialMint.refusal("a streamed body")) }
            mint = kind
            req = Self.readWhole(req)
            upgrade = false
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case nil: h=100066d5d21b14d8 @003f61e7
        case nil:
            break
        }
        // 5f. A sign-in this workspace runs: its token exchange is the host's.
        var capture: SignInCapture?
        // This proxy's own captures (macOS reads them through the provider,
        // which answers for the one engine; here the proxy is at hand).
        if tls, !insecure, !spooled, let c = proxy.captures.capture(for: profileID),
           let bodyStart = req.range(of: Data("\r\n\r\n".utf8)) {
            let body = req.subdata(in: bodyStart.upperBound..<req.count)
            // An ended sign-in's late exchange (this capture spent, or any
            // of its spent endpoints): refused, never redeemed with the
            // provider (the code would be spent on a login nobody keeps).
            if c.refusesExchange(host: host, method: method, path: path, body: body) {
                return .answer(SignInCapture.notKeptReply)
            }
            if !c.spent, c.matches(host: host, method: method, path: path, body: body) {
                if let sim = c.simulatedReply {
                    // The sign-in simulator (e2e): the provider's reply is canned.
                    let (status, body) = HTTPRequestFraming.responseStatusAndBody(sim)
                    return .answer(await c.handle(status, body) ?? sim)
                }
                capture = c
                // The exchange's reply is read here, not relayed.
                req = Self.readWhole(req)
                upgrade = false
            }
        }
        // A trace that keeps this host's bodies reads them as text, and
        // strict credential mode learns the tokens a reply issues (an
        // upgrade's refusal too): the reply is asked for uncompressed (what a
        // guest behind macOS's URLSession gets; nothing here decodes gzip or br).
        let tracedBodies = !upgrade && trace.map({ $0.session.level.capturesBodyForHost(host) }) == true
        // A reply PII restores is read too (macOS's URLSession decodes it).
        if capture == nil, tracedBodies || pii.vault != nil || UnmanagedCredentialGuard.shared.isEnabled(for: profileID) {
            req = HTTPRequestFraming.replacingHeaders(req, drop: ["accept-encoding"], add: "Accept-Encoding: identity")
        }
        // An OpenShell `protocol: websocket` route (macOS: driveTLS's
        // upgrade path, ProxyPolicy.webSocketPlan): each client text message
        // is judged (for the flow's program) and rewritten before it's
        // forwarded, and permessage-deflate is offered upstream only without
        // client context takeover. Its per-message gate takes precedence
        // over the content scan below: policy enforcement is never traded
        // for scanning.
        var wsPolicy: ProxyPolicy.WebSocketPolicy?
        if upgrade, webSocket {
            switch ProxyPolicy.webSocketPlan(req, policy: proxy.guardrailsConfig(for: profileID)?.egressPolicy,
                                             entries: proxy.swapper.entries(for: profileID), host: host, port: port,
                                             reqPath: path, identity: identity) {
            case .reject(let status, let error, let detail):
                return .answer(ProxyPolicy.beforePolicyAnswer(status: status, error: error, detail: detail,
                                                              host: host, port: port, profileID: profileID,
                                                              scheme: tls ? "https" : "http"))
            case .go(let plan):
                req = plan.request
                if plan.messagePolicy != nil || plan.messageTransform != nil { wsPolicy = plan }
            }
        }
        // A model provider's WebSocket with prompt injection on: its frames are
        // read (WSClientFilter), so the upgrade declines permessage-deflate
        // and both legs carry plain frames (macOS: WSHandshake, then
        // WSTransformRelay). Otherwise the socket stays an opaque pipe.
        var ws: WSPromptGuard?
        let wsConversation = upgrade ? SquelchRewriter.sessionKey(
            headers: String(decoding: req.prefix(16 << 10), as: UTF8.self)) : nil
        // Squelch on the policy pump too: client text trimmed ahead of the
        // OpenShell rewrites, the model's messages read for the calls a
        // chained turn's bare results are matched with (macOS: squelchOnPump).
        var squelchLearnOnPump = false
        if wsPolicy != nil, !insecure, squelchApplies(host: host, profileID: profileID, local: local) {
            let then = wsPolicy?.messageTransform
            wsPolicy?.messageTransform = squelchingTransform(then: then, profileID: profileID,
                                                             conversation: wsConversation)
            squelchLearnOnPump = true
        }
        if upgrade, webSocket, wsPolicy == nil, !insecure, let g = WSPromptGuard.make(proxy: proxy, profileID: profileID, host: host, path: path, local: local,
                                                                 conversation: wsConversation) {
            ws = g
            req = WSHandshake.strippingExtensions(req).request
        }
        // Our own control header never reaches the upstream (macOS:
        // relayUpstream's header copy).
        var out = upgrade ? req : closing(req)
        if SubscriptionAuthRewrite.headerValue("x-bromure-insecure", inHeaderSection: SubscriptionAuthRewrite.rawHeaderSection(of: out) ?? "") != nil {
            out = HTTPRequestFraming.replacingHeaders(out, drop: ["x-bromure-insecure"], add: nil)
        }
        // An AWS request (SigV4 with the guest's fake keys) re-signed with the
        // real ones, last, over the headers as they go out; a use the user
        // refused is answered here (macOS: driveTLS's AWSResigner step). Not
        // an insecure request: re-signing would put the real key's signature
        // in front of an unvalidated upstream.
        // A streamed body (5z) isn't here to hash (macOS 435df2af): S3 keeps
        // the SDK's own hash, else UNSIGNED-PAYLOAD; any other service is
        // refused (its Action may sit past what was read). It keeps its own
        // framing, which the resigner drops.
        let streamedFraming = spooled ? streamedBodyFraming(out) : nil
        switch insecure ? .unchanged : await proxy.awsResigner.resign(rawRequest: out, host: host, profileID: profileID,
                                                                       bodyComplete: !spooled) {
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .unchanged: h=7ae83a8a6eda7f57 @003f61e7
        case .unchanged: break
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .resigned(let bytes): h=ef2b34394ac16b57 @003f61e7
        case .resigned(let bytes):
            out = streamedFraming.map {
                HTTPRequestFraming.replacingHeaders(bytes, drop: ["host", "content-length", "transfer-encoding", "connection"],
                                                    add: "Host: \(host)\r\n\($0)\r\nConnection: close")
            } ?? framedLikeURLSession(bytes, host: host)
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .denied(let response): h=8293f31bc4d27bcf @003f61e7
        case .denied(let response): return .answer(response)
        // @port HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data) / case .failed(let reason, let response): h=41ab3da9fe0a5276 @003f61e7
        case .failed(let reason, let response):
            FileHandle.standardError.write(Data("[mitm] AWS resign failed for \(host): \(reason)\n".utf8))
            return .answer(response)
        }
        // A turn the on-host engine serves: the engine's key, not the cloud
        // auth (macOS: relayUpstream's local swap).
        if dial == nil, local {
            out = MitmProxy.engineAuth(out, profileID: profileID)
        }
        // The swaps this request carries out, one audit event each, whatever
        // the trace level (macOS: emitTrace sends them before its trace gate):
        // a request refused above never left, so it has none.
        TraceEmitter.emitSwapEvents(swapped.swaps, host: host, path: path, profileID: profileID)
        // 6d. Fusion, a cloud turn's alternative to the relay (macOS: after
        // the routing and PII steps, before the forward).
        if !local, dial == nil, !upgrade, !spooled, mint == nil, capture == nil, supplyChain == nil,
           let fused = await fusionAnswer(out, proxy: proxy, profileID: profileID, host: host, port: port, trace: trace) {
            return .answer(fused)
        }
        return .forward(out, injected, capture: capture, upgrade: upgrade, mint: mint, ws: ws, pii: pii.vault,
                        supplyChain: supplyChain, dial: dial, local: local && dial == nil, wsPolicy: wsPolicy,
                        squelchLearn: squelchLearnOnPump, insecure: insecure)

    }

    /// The guest drained: the upstream may be read again (ResponseRelay
    /// paused it while the guest was full).
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { relay?.readUpstreamIfAllowed() }
        context.fireChannelWritabilityChanged()
    }

    // partial: the upgrade's dial, held bytes and gates as NIO handlers (ResponseRelay switches, WSClientFilter / OpenShellWebSocket gate the guest's frames)
    // @port HTTPMitmConnection.handleWebSocketUpgrade(serverTLS: MitmServerStream, rawRequest: Data, host: String, port: Int, cleartext: Bool, captureBody: Bool, messagePolicy: ((String)->OpenShellWebSocket.MessageVerdict)?, messageTransform: ((String)->OpenShellWebSocket.MessageTransform)?, onViolation: @escaping@Sendable(String,Bool)->Void, binaryPolicy: (()->OpenShellWebSocket.MessageVerdict)?, contentGuard: WSContentGuard?, squelchLearnFor: UUID?, onUpstreamMessage: (@Sendable(WSMessage)->Void)?) h=1f8ae9be73ba6ba7 @003f61e7
    private func send(_ plan: Plan, trace: Trace?, channel: Channel, host: String, port: Int, tls: Bool, session: UInt64) {
        switch plan {
        case .answer(let reply):
            write(reply, to: channel, close: true)
            if let trace { proxy.emitTrace(trace, response: reply, wireBytes: reply.count, truncated: false) }
        case .forward(let req, let injected, let capture, let upgrade, let mint, let ws, let pii, let supplyChain, let dial, let local,
                      let wsPolicy, let squelchLearn, let insecure):
            // Where it's dialed: the guest's destination, or Depi (TLS, its
            // own name: nothing the guest pinned) for a re-routed request.
            proxy.connectUpstream(host: dial?.host ?? host, port: dial?.port ?? port, tls: dial != nil || tls,
                                  profileID: profileID, pinned: dial == nil ? pinned : nil, local: local,
                                  identity: identity, insecure: insecure && dial == nil, on: channel.eventLoop).whenComplete { r in
                switch r {
                case .failure(let e):
                    let reply = (e as? ProxyDestinationDenied).map {
                        MitmProxy.destinationDeniedResponse(host: $0.host, port: $0.port, reason: $0.reason)
                    } ?? self.proxy.upstreamErrorResponse(e, host: host, profileID: self.profileID)
                    self.write(reply, to: channel, close: true)
                    if let trace { self.proxy.emitTrace(trace, response: reply, wireBytes: reply.count, truncated: false) }
                case .success(let up):
                    let relay = ResponseRelay(guest: channel, profileID: self.profileID, injected: injected,
                                              capture: capture, upgrade: upgrade, proxy: self.proxy, trace: trace, host: host,
                                              mint: mint.map { (self.proxy.credentialMinter, $0) }, strictSession: session,
                                              ws: ws, pii: pii, supplyChain: supplyChain,
                                              squelchLearnFor: squelchLearn ? self.profileID : nil,
                                              // An HTTP/1.0 guest gets a restored body up to the close, not chunks.
                                              guestHTTP11: !Self.isHTTP10(req))
                    relay.onUpstreamWritable = { [weak self] in self?.readGuestIfAllowed(channel) }
                    if upgrade { relay.requestedUpgrade = ResponseRelay.upgradeToken(SubscriptionAuthRewrite.rawHeaderSection(of: req) ?? "") }
                    // The upgrade's held bytes follow the 101; anything else's are dropped.
                    relay.onSwitched = { [weak self, weak relay] switched, server in
                        let responseHead = relay?.upgradeResponseHead ?? Data()
                        channel.eventLoop.execute {
                            guard let self else { return }
                            self.awaitingUpgrade = false
                            if switched {
                                self.upgraded = true
                                if TraceLevel.isAIHost(host) {
                                    let pid = self.profileID
                                    let beat = ActivityBeat(fire: { MitmProxy.liveActivity.withLockedValue { $0 }?(pid) })
                                    self.beat = beat
                                    relay?.beat = beat
                                }
                                // The guest's bytes held until the switch are its first frames.
                                for p in self.pending { relay?.wsTrace?.client(p) }
                                if let wsPolicy {
                                    // Keyed on the plan alone: a rewrite with
                                    // no rule still goes through the gate.
                                    let messagePolicy = wsPolicy.messagePolicy ?? { _ in .allow }
                                    // OpenShell's per-message gate on the
                                    // guest's frames (macOS: the pump's
                                    // ClientStream gate); the upstream's pass.
                                    let onViolation = ProxyPolicy.webSocketViolation(
                                        profileID: self.profileID, host: host, port: port, path: Self.requestTarget(req),
                                        scheme: tls ? "wss" : "ws")
                                    let compression = OpenShellWebSocket.negotiatedCompression(
                                        responseHeader: String(decoding: responseHead, as: UTF8.self))
                                    let onBinaryViolation = ProxyPolicy.webSocketViolation(
                                        profileID: self.profileID, host: host, port: port, path: Self.requestTarget(req),
                                        scheme: tls ? "wss" : "ws", method: "WEBSOCKET_BINARY")
                                    self.wsGate = OpenShellWebSocket.ClientStream(compression: compression, decide: { text in
                                        let v = messagePolicy(text)
                                        if case .deny(let why) = v { onViolation(why, true) }
                                        return v
                                    }, onAudit: { onViolation($0, false) }, transform: wsPolicy.messageTransform,
                                       decideBinary: wsPolicy.binaryPolicy.map { ProxyPolicy.reportingBinary($0, onBinaryViolation) })
                                    var held = Data()
                                    for p in self.pending { held.append(contentsOf: p.readableBytesView) }
                                    if !held.isEmpty { self.gateToUpstream(held, guest: channel, upstream: up) }
                                } else if let ws, let server {
                                    // The guest's frames go through the scan;
                                    // its reads pause while too much is held.
                                    self.wsFilter = WSClientFilter(
                                        guard: ws, loop: channel.eventLoop,
                                        toUpstream: { up.writeAndFlush(up.allocator.buffer(bytes: $0), promise: nil) },
                                        toGuest: { server.inject($0) },
                                        setReading: { on in
                                            self.filterWantsGuest = on
                                            self.readGuestIfAllowed(channel)
                                        },
                                        fail: { channel.close(promise: nil) })
                                    for p in self.pending { self.wsFilter?.feed(Data(p.readableBytesView)) }
                                } else {
                                    for p in self.pending { up.write(p, promise: nil) }
                                    up.flush()
                                }
                            }
                            self.pending.removeAll()
                            self.pendingBytes = 0
                        }
                    }
                    up.pipeline.addHandler(relay).whenComplete { _ in
                        // The guest left while the upstream was being set up:
                        // nobody will close it (channelInactive saw none).
                        guard channel.isActive else { up.close(promise: nil); return }
                        self.upstream = up
                        self.relay = relay
                        self.awaitingUpgrade = upgrade
                        up.writeAndFlush(up.allocator.buffer(bytes: req), promise: nil)
                        if self.streaming {
                            // The body so far, then the guest read again.
                            for p in self.pending { self.forwardStreamed(p, to: up, guest: channel) }
                            self.pending.removeAll()
                            self.pendingBytes = 0
                            self.readGuestIfAllowed(channel)
                            return
                        }
                        if !upgrade {
                            self.pending.removeAll()
                            self.pendingBytes = 0
                        }
                    }
                }
            }
        }
    }

    /// The guest's bytes on a gated WebSocket (macOS: pumpDirection's gate):
    /// forwarded as far as the gate allows; a stop tells the guest why
    /// (1008), then ends the session both ways.
    // @port-skip linux-only: the client → upstream half of macOS's WebSocket pump, on NIO
    private func gateToUpstream(_ bytes: Data, guest: Channel, upstream: Channel) {
        guard let gate = wsGate else { return }
        let (forward, stop) = gate.feed(bytes)
        if !forward.isEmpty { upstream.write(upstream.allocator.buffer(bytes: forward), promise: nil) }
        upstream.flush()
        if stop {
            let close = OpenShellWebSocket.policyCloseFrame(
                reason: gate.closeReason ?? "Bromure: client message not permitted by policy", code: gate.closeCode)
            guest.writeAndFlush(guest.allocator.buffer(bytes: close)).whenComplete { _ in guest.close(promise: nil) }
            upstream.close(promise: nil)
            return
        }
        if !upstream.isWritable { _ = guest.setOption(ChannelOptions.autoRead, value: false) }
    }

    /// The request-target of a request's first line ("/" when it has none).
    // @port-skip linux-only: the Linux proxy's request-line read
    static func requestTarget(_ req: Data) -> String {
        let line = req.prefix { $0 != 13 && $0 != 10 }.split(separator: 32)
        return line.count > 1 ? String(decoding: line[1], as: UTF8.self) : "/"
    }

    /// The upstream of an upgraded stream, for tests (on the loop).
    // @port-skip linux-only: a test seam on the NIO proxy
    var upstreamForTesting: Channel? { upstream }

    /// The one decision on reading the guest again, whichever pause ends
    /// (the upstream draining, a guarded WebSocket's filter letting go): only
    /// when the upstream can take more and the filter isn't holding too much.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func readGuestIfAllowed(_ channel: Channel) {
        let on = filterWantsGuest && (upstream?.isWritable ?? true)
        _ = channel.setOption(ChannelOptions.autoRead, value: on)
        if on, wsFilter != nil { channel.read() }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func write(_ data: Data, to channel: Channel, close: Bool) {
        channel.writeAndFlush(channel.allocator.buffer(bytes: data)).whenComplete { _ in
            if close { channel.close(promise: nil) }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func reply(_ context: ChannelHandlerContext, _ data: Data) {
        started = true
        write(data, to: context.channel, close: true)
    }

    /// Whether a request's line says HTTP/1.0 (its reply can't be chunked).
    // @port-skip linux-only: the Linux relay's re-framing of a restored reply
    static func isHTTP10(_ req: Data) -> Bool {
        let end = req.range(of: Data("\r\n".utf8))?.lowerBound ?? req.endIndex
        return String(decoding: req[req.startIndex..<end], as: UTF8.self).hasSuffix(" HTTP/1.0")
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func simple(_ status: Int, _ reason: String, body: String = "") -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }

    /// A request whose reply is read whole and rewritten before the guest
    /// sees any of it (a credential mint, a sign-in's exchange): asked for
    /// uncompressed (nothing here decodes gzip or br) and as one plain
    /// response, no Expect (a 100 Continue first) nor Upgrade (a 101):
    /// URLSession consumes those on macOS.
    // @port-skip linux-only: what URLSession settles before macOS's rewrite sees a reply
    static func readWhole(_ req: Data) -> Data {
        HTTPRequestFraming.replacingHeaders(req, drop: ["accept-encoding", "expect", "upgrade"], add: "Accept-Encoding: identity")
    }

    /// A re-signed request as macOS's URLSession puts it on the wire: the
    /// resigner leaves Host, Content-Length and Connection to it (Host is
    /// the name it signed; the body is already framed by its length, the
    /// reader de-chunks).
    // @port-skip linux-only: what URLSession adds to AWSResigner's bytes on macOS
    static func framedLikeURLSession(_ raw: Data, host: String) -> Data {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let body = raw.count - (end.upperBound - raw.startIndex)
        return HTTPRequestFraming.replacingHeaders(raw, drop: ["host", "content-length", "connection"],
                                                   add: "Host: \(host)\r\nContent-Length: \(body)\r\nConnection: close")
    }

    /// A streamed request's body framing header, as the guest sent it (its
    /// Content-Length, or chunked), for a head the resigner rebuilt.
    // @port-skip linux-only: the 5z head's framing kept through AWS re-signing
    static func streamedBodyFraming(_ raw: Data) -> String? {
        let head = SubscriptionAuthRewrite.rawHeaderSection(of: raw) ?? ""
        if let cl = SubscriptionAuthRewrite.headerValue("content-length", inHeaderSection: head) { return "Content-Length: \(cl)" }
        if SubscriptionAuthRewrite.headerValue("transfer-encoding", inHeaderSection: head) != nil { return "Transfer-Encoding: chunked" }
        return nil
    }

    /// An absolute-form request line (`GET http://h/p HTTP/1.1`) in origin
    /// form, as the origin expects it; anything else as it is.
    // @port-skip linux-only: proxy request-line handling
    static func origin(_ raw: Data) -> Data {
        guard let eol = raw.firstIndex(of: 13) else { return raw }
        let line = String(decoding: raw[raw.startIndex..<eol], as: UTF8.self)
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[1].lowercased().hasPrefix("http://"),
              let url = URL(string: String(parts[1])) else { return raw }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        return Data("\(parts[0]) \(path) \(parts[2])".utf8) + raw[eol...]
    }

    /// The request with `Connection: close` (one request per connection, as
    /// macOS does): any Connection / Keep-Alive / Proxy-Connection header replaced.
    // @port-skip linux-only: proxy request-head handling
    static func closing(_ raw: Data) -> Data {
        HTTPRequestFraming.replacingHeaders(raw, drop: ["connection", "keep-alive", "proxy-connection"],
                                            add: "Connection: close")
    }
}

/// The upstream side: its response streamed to the guest with `Connection:
/// close` in its head (a WebSocket's spliced as it is), or, for a captured
/// sign-in, read whole and answered by the capture. A 401 to a request
/// carrying a live subscription token tells the store (noteUnauthorized).
// @port-skip linux-only: HTTPMitmConnection's response relay on NIO
final class ResponseRelay: ChannelInboundHandler {
    /// The protocol the request's upgrade named: the 101 must switch to it.
    var requestedUpgrade: String?
    /// The switched model socket's activity beat (set at the switch).
    var beat: ActivityBeat?
    typealias InboundIn = ByteBuffer
    let guest: Channel
    let profileID: UUID
    let injected: SubscriptionAuthRewrite.Injected
    let capture: SignInCapture?
    /// A credential-minting call's: its response is read whole and rewritten.
    let mint: (CredentialMinter, CredentialMint.Kind)?
    let upgrade: Bool
    let proxy: MitmProxy?
    let trace: RequestReader.Trace?
    private var head = ByteBuffer()
    private var headDone = false
    /// An upgrade's reply: whether it switched protocols (a 101), and the
    /// server side of a guarded WebSocket when its frames are read.
    var onSwitched: ((Bool, WSServerSide?) -> Void)?
    /// A switched upgrade's response head (its negotiated extensions), set
    /// before onSwitched.
    private(set) var upgradeResponseHead: Data?
    /// A switched WebSocket's trace (WebSocketTraceLinux.swift): set with
    /// the 101 when the request is traced; the guest's side feeds it too.
    private(set) var wsTrace: WSTraceSession?
    /// The upstream drained: the guest may be read again, if nothing else
    /// holds it (RequestReader.readGuestIfAllowed).
    var onUpstreamWritable: (() -> Void)?
    /// The upgrade's prompt-injection guard (nil: an opaque pipe).
    private let ws: WSPromptGuard?
    private var wsServer: WSServerSide?
    /// A socket on the OpenShell policy pump with Squelch on: the model's
    /// messages read for its call registry (macOS: squelchLearnFor).
    private let squelchLearnFor: UUID?
    /// The reply PII protection restores (its stand-ins put back), if any.
    private let pii: PIIRelay?
    /// A package fetch's reply the supply-chain policy rewrites, read whole.
    let supplyChain: SupplyChainRewrite?
    /// A rewritten package reply past this is refused, not kept (a full npm
    /// packument or a tarball is read whole, as macOS's URLSession reads
    /// it): the request decoder's cap.
    static let supplyChainCap = 64 << 20
    /// What all the daemon's package replies being read whole hold at once
    /// (256 MiB), so parallel fetches can't take the host's memory.
    static let supplyChainBudget = SupplyChainBudget(limit: 256 << 20)
    /// This reply's place among the budget's holders (the oldest proceeds).
    private lazy var supplyChainTicket = budget.ticket()
    /// The budget it takes room from (its proxy's).
    private let budget: SupplyChainBudget
    /// Chunks waiting, in order, for room in the budget (reads stopped
    /// meanwhile): a batch already being read still arrives, behind them.
    private var waiting: [ByteBuffer] = []
    private var waitingBytes = 0
    /// Since when the first waiting chunk waits (one timer for them all).
    private var waitingSince: Date?
    /// How long a chunk waits with the budget idle (no reply growing or
    /// done) before the reply is refused.
    static let supplyChainWait: TimeInterval = 30
    /// Where the rewrites run: off the event loops (a packument's filter,
    /// a tarball's re-gzip; the shared rewrite may wait on the publish-time
    /// cache), on a small pool of threads of their own, not Swift's
    /// cooperative pool.
    static let supplyChainQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "bromure.supply-chain.rewrite"
        q.maxConcurrentOperationCount = 4
        return q
    }()
    /// The relay's own context (its reads are decided here).
    private var context: ChannelHandlerContext?
    /// Tests: each relay as it's made (to watch it go).
    static let madeForTesting = NIOLockedValueBox<((ResponseRelay) -> Void)?>(nil)

    /// A read-whole reply with nothing read for this long (reads not
    /// stopped for the budget) is refused: a byte trickled now and then
    /// can't hold its share for ever. (Tests shorten it.)
    static let supplyChainReadIdle = NIOLockedValueBox<TimeInterval>(30)
    /// A read-whole reply not read whole within this (from its first byte)
    /// is refused too: a byte trickled every 29 s can't hold its share for
    /// ever. (Tests shorten it.)
    static let supplyChainReadTotal = NIOLockedValueBox<TimeInterval>(300)
    /// How long the guest has to take its rewritten reply. (Tests shorten it.)
    static let supplyChainWriteDeadline = NIOLockedValueBox<TimeInterval>(60)
    /// When the reply's first byte came, and its last (the clocks start at
    /// the first: a slow first byte isn't a stall).
    private var firstRead: Date?
    private var lastRead = Date()
    private var stalled = false
    private var stallCheck: RepeatedTask?

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        guard supplyChain != nil else { return }
        let idle = Self.supplyChainReadIdle.withLockedValue { $0 }
        let total = Self.supplyChainReadTotal.withLockedValue { $0 }
        let every = TimeAmount.milliseconds(Int64(min(5, min(idle, total) / 4) * 1000))
        stallCheck = context.eventLoop.scheduleRepeatedTask(initialDelay: every, delay: every) { [weak self] _ in
            guard let self, let context = self.context, let first = self.firstRead else { return }
            let now = Date()
            let idleTooLong = self.waitingSince == nil && now.timeIntervalSince(self.lastRead) > idle
            guard idleTooLong || now.timeIntervalSince(first) > total else { return }
            self.stalled = true
            context.close(promise: nil)
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; stallCheck?.cancel() }

    /// The one decision on reading the upstream again, whichever pause ends
    /// (the guest draining, room in the budget): only when the guest can take
    /// more and no chunk waits for room.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func readUpstreamIfAllowed() {
        guard let context, context.channel.isActive else { return }
        _ = context.channel.setOption(ChannelOptions.autoRead, value: guest.isWritable && waiting.isEmpty)
    }

    /// A chunk of a package reply: kept, if the budget has room and nothing
    /// waits before it; else it waits behind the others (reads stop), with
    /// one timer retrying every 50 ms.
    // @port-skip linux-only: the Linux relay's read-whole budget
    private func takeSupplyChainChunk(_ context: ChannelHandlerContext, _ b: ByteBuffer) {
        if waiting.isEmpty, budget.reserve(b.readableBytes, for: supplyChainTicket) {
            whole.append(contentsOf: b.readableBytesView)
            return
        }
        waiting.append(b)
        waitingBytes += b.readableBytes
        guard waitingSince == nil else { return }
        waitingSince = Date()
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        retryWaiting(context)
    }

    // @port-skip linux-only: the Linux relay's read-whole budget
    private func retryWaiting(_ context: ChannelHandlerContext) {
        context.eventLoop.scheduleTask(in: .milliseconds(50)) { [self] in
            // The upstream closed meanwhile: channelInactive took the chunks.
            guard context.channel.isActive, let since = waitingSince else { return }
            while let b = waiting.first, budget.reserve(b.readableBytes, for: supplyChainTicket) {
                waiting.removeFirst()
                waitingBytes -= b.readableBytes
                    whole.append(contentsOf: b.readableBytesView)
            }
            if waiting.isEmpty {
                waitingSince = nil
                lastRead = Date()
                readUpstreamIfAllowed()
            } else if budget.idle(since: since) > Self.supplyChainWait {
                waiting.removeAll()
                waitingBytes = 0
                waitingSince = nil
                overflowed = true
                context.close(promise: nil)
            } else {
                retryWaiting(context)
            }
        }
    }
    /// Whether any of the response reached the guest; the upstream's error, if any.
    private var relayed = false
    private let host: String
    private var failure: Error?
    private var whole = Data()
    /// A read-whole reply past this is refused, not kept (a credential
    /// response is a few KiB).
    static let wholeCap = 8 << 20
    private var overflowed = false
    /// The trace's copy of what the guest got, up to `traceCap` (macOS:
    /// relayUpstream's bodyBufferCap); past it the record keeps no body.
    private var traceCopy = Data()
    private var traceWire = 0
    private var traceTruncated = false
    /// What the guest got, up to `learnCap`, for strict credential mode to
    /// learn the tokens this site issues it (a cookie, an access_token):
    /// the guest may send those back here (macOS: relayUpstream's learn).
    private var learnBuf = Data()
    static let learnCap = 256 << 10
    /// Whether this reply is one to learn from: any final response (a login
    /// redirect sets its cookie on a 302), not an upgrade's stream.
    private var learning = false
    /// The strict-credential session this reply belongs to.
    private let strictSession: UInt64
    static let traceCap = 8 * 1024 * 1024

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(guest: Channel, profileID: UUID, injected: SubscriptionAuthRewrite.Injected,
         capture: SignInCapture?, upgrade: Bool, proxy: MitmProxy? = nil, trace: RequestReader.Trace? = nil,
         host: String = "", mint: (CredentialMinter, CredentialMint.Kind)? = nil, strictSession: UInt64 = 0,
         ws: WSPromptGuard? = nil, pii: PIIVault? = nil, supplyChain: SupplyChainRewrite? = nil,
         squelchLearnFor: UUID? = nil,
         guestHTTP11: Bool = true, budget: SupplyChainBudget? = nil) {
        self.squelchLearnFor = squelchLearnFor
        self.guest = guest
        self.budget = budget ?? proxy?.supplyChainBudget ?? Self.supplyChainBudget
        self.supplyChain = supplyChain
        self.ws = ws
        self.pii = pii.map { PIIRelay(vault: $0, chunkedOut: guestHTTP11, host: host, profileID: profileID) }
        self.mint = mint
        self.host = host
        self.profileID = profileID
        self.injected = injected
        self.capture = capture
        self.upgrade = upgrade
        self.proxy = proxy
        self.trace = trace
        self.strictSession = strictSession
        Self.madeForTesting.withLockedValue { $0 }?(self)
    }

    /// What reached the guest, for the trace.
    // @port-skip linux-only: relayUpstream's response buffer for the trace, on NIO
    private func keepForTrace(_ bytes: Data) {
        guard trace != nil else { return }
        traceWire += bytes.count
        if traceCopy.count + bytes.count <= Self.traceCap {
            traceCopy.append(bytes)
        } else {
            traceCopy.append(bytes.prefix(Self.traceCap - traceCopy.count))
            traceTruncated = true
        }
    }

    // partial: the response relayed raw on NIO (no URLSession decoding: a body that has to be read is asked for identity); the 502 in UpstreamError / MitmInsecure
    // @port relayUpstream(rawRequest: Data, host: String, port: Int, session: URLSession, tls: MitmServerStream, upstreamScheme: String, bodyFile: URL?, insecureBypassAllowed: Bool, profileID: UUID, responseRestorer: ((String)->PIIResponseRestorer)?) h=c40e22316695d646 @003f61e7
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if capture != nil || mint != nil || supplyChain != nil {
            if supplyChain != nil {
                guard !overflowed, !stalled else { return }
                lastRead = Date()
                if firstRead == nil { firstRead = lastRead }
                guard whole.count + waitingBytes + b.readableBytes <= Self.supplyChainCap else {
                    overflowed = true
                    waiting.removeAll()
                    waitingBytes = 0
                    context.close(promise: nil)
                    return
                }
                // The daemon's budget is full (or chunks already wait): this
                // one waits behind them, not refused at once.
                takeSupplyChainChunk(context, b)
                return
            } else if whole.count + b.readableBytes > Self.wholeCap {
                overflowed = true
                context.close(promise: nil)
                return
            }
            whole.append(contentsOf: b.readableBytesView)
            return
        }
        if headDone {
            if let pii, pii.restoring {
                // Restored: the trace and the learning read what the guest gets.
                let out = pii.feed(Data(b.readableBytesView))
                keepForTrace(out)
                keepForLearning(out)
                relayed = true
                if !out.isEmpty { guest.write(guest.allocator.buffer(bytes: out), promise: nil) }
                // Broken framing: the guest's reply is cut here, never ended.
                if pii.failed { context.close(promise: nil); return }
                holdIfGuestFull(context)
                return
            }
            if trace != nil { keepForTrace(Data(b.readableBytesView)) }
            wsTrace?.upstream(count: b.readableBytes)
            beat?.tick(Data(b.readableBytesView.prefix(64)))
            keepForLearning(b.readableBytesView)
            relayed = true
            if let wsServer {
                // As it comes; a refused turn's event between two messages.
                guard let out = wsServer.feed(Data(b.readableBytesView)) else { context.close(promise: nil); return }
                wsTrace?.toGuest(out)
                if !out.isEmpty { guest.write(guest.allocator.buffer(bytes: out), promise: nil) }
            } else {
                wsTrace?.toGuest(b)
                guest.write(b, promise: nil)
            }
            holdIfGuestFull(context)
            return
        }
        head.writeBuffer(&b)
        guard let end = head.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if head.readableBytes > 64 << 10 { context.close(promise: nil) }
            return
        }
        let all = Data(head.readableBytesView)
        let split = end.upperBound - head.readerIndex
        // Interim answers (100 Continue, 103 Early Hints) go to the guest as
        // they are (through the same backpressure); the next head decides.
        var head0 = Data(all.prefix(split)), rest = Data(all.dropFirst(split))
        while let st = Self.status(head0), (100..<200).contains(st), st != 101 {
            relayed = true
            // Counted on the wire, not kept: the record's response is the
            // final one, as macOS records it (URLSession consumes these).
            if trace != nil { traceWire += head0.count }
            guest.write(guest.allocator.buffer(bytes: head0), promise: nil)
            holdIfGuestFull(context)
            guard let next = rest.range(of: Data("\r\n\r\n".utf8)) else {
                head.clear()
                head.writeBytes(rest)
                return
            }
            head0 = Data(rest[rest.startIndex..<next.upperBound])
            rest = Data(rest[next.upperBound...])
        }
        // A switch to a protocol the pump isn't for (an h2c answer to an
        // offer never forwarded, by a server that ignores the request's
        // Upgrade), or one nothing asked for: refused, not relayed (macOS:
        // handleWebSocketUpgrade's 502).
        if Self.status(head0) == 101,
           !upgrade || requestedUpgrade == nil
            || Self.upgradeToken(String(decoding: head0, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]) != requestedUpgrade {
            FileHandle.standardError.write(Data("[mitm] \(host): refused a 101 to a protocol other than websocket or SPDY/3.1\n".utf8))
            headDone = true
            relayed = true
            let reply = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: head0.count, truncated: false) }
            // The guest's answer first; then both sides go (the upstream's
            // close would end the guest before the answer otherwise).
            let upstream = context.channel
            guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in
                self.guest.close(promise: nil)
                upstream.close(promise: nil)
            }
            return
        }
        headDone = true
        learning = !(upgrade && Self.status(head0) == 101)
        let out: Data
        if upgrade, Self.status(head0) == 101 {
            // Switched: the head as it is, then the stream both ways.
            noteStatus(head0)
            upgradeResponseHead = head0
            if let trace {
                // An opaque stream (SPDY) is counted, never parsed as frames.
                wsTrace = WSTraceSession(handshake: head0, host: host, path: HTTPFrames.parseRequestLine(trace.request).1,
                                         profileID: trace.profileID,
                                         captureBody: trace.session.level.capturesBodyForHost(host)
                                            && Self.switchedToWebSocket(head0))
                wsTrace?.upstream(count: rest.count)
            }
            var early = rest
            if let ws {
                if let ext = WSHandshake.extensions(inResponse: head0) {
                    // An extension in use anyway (one it wasn't offered): frames
                    // that can't be read, so the opaque pipe, and said so
                    // (macOS: driveTLS's fallback to the pump).
                    ProxyPolicy.recordScanSkipped(host: ws.host, path: ws.path, engines: ["pii", "prompt_injection"],
                                                  reason: "WebSocket extension \(ext) in use", profileID: ws.profileID)
                } else {
                    let guest = self.guest
                    let pid = ws.profileID
                    let server = WSServerSide(loop: context.eventLoop,
                                              write: { [weak self] in self?.wsTrace?.toGuest($0); guest.writeAndFlush(guest.allocator.buffer(bytes: $0), promise: nil) },
                                              // Decided per message, as macOS's guard: PII
                                              // protection or Squelch turned on mid-socket
                                              // applies from the next message.
                                              makeRestorer: { ws.restoresReplies ? WSServerRestorer(vault: ws.vault) : nil },
                                              learn: { if ws.squelchLearns { SquelchCallRegistry.shared.learn(fromServerEvent: $0, profileID: pid) } })
                    wsServer = server
                    guard let read = server.feed(rest) else { context.close(promise: nil); return }
                    early = read
                }
            }
            if ws == nil, let pid = squelchLearnFor, WSHandshake.extensions(inResponse: head0) == nil {
                let guest = self.guest
                let server = WSServerSide(loop: context.eventLoop,
                                          write: { [weak self] in self?.wsTrace?.toGuest($0); guest.writeAndFlush(guest.allocator.buffer(bytes: $0), promise: nil) },
                                          learn: { SquelchCallRegistry.shared.learn(fromServerEvent: $0, profileID: pid) })
                wsServer = server
                guard let read = server.feed(rest) else { context.close(promise: nil); return }
                early = read
            }
            // The server's side as the guest gets it (restored), for the trace.
            wsTrace?.toGuest(early)
            onSwitched?(true, wsServer)
            out = head0 + early
        } else {
            // One response, then the close: an upgrade the upstream refused
            // too (the request side drops what the guest sends after it, so a
            // client reusing the connection must be told it's done).
            if upgrade { onSwitched?(false, nil) }
            let h = HTTPRequestFraming.replacingHeaders(head0, drop: ["connection", "keep-alive"], add: "Connection: close")
            noteStatus(h)
            switch pii?.head(h) {
            case .restored(let head)?:
                out = head + pii!.feed(rest)
            case .refused(let why)?:
                // A reply that can't be framed with certainty isn't passed on.
                FileHandle.standardError.write(Data("[pii] \(host): reply refused: \(why)\n".utf8))
                let reply = RequestReader.simple(502, "Bad Gateway",
                                                 body: "Bromure: the reply from \(host) couldn't be read with certainty (\(why)); it was not passed on.\n")
                onSwitched = nil
                keepForTrace(reply)
                relayed = true
                guest.write(guest.allocator.buffer(bytes: reply), promise: nil)
                context.close(promise: nil)
                return
            case .asItCame?, nil:
                out = h + rest
            }
        }
        onSwitched = nil
        keepForTrace(out)
        keepForLearning(out)
        relayed = true
        guest.write(guest.allocator.buffer(bytes: out), promise: nil)
        // Broken framing in the first read already: cut here, as the body path does.
        if pii?.failed == true { context.close(promise: nil); return }
        holdIfGuestFull(context)
    }

    /// A package reply refused, not passed on (502).
    // @port-skip linux-only: relayUpstreamBuffered's refusal, on the Linux relay
    static func supplyChainRefusal(_ host: String, _ why: String) -> Data {
        RequestReader.simple(502, "Bad Gateway", body: "Bromure: the package reply from \(host) \(why); it was not passed on.\n")
    }

    /// A read-whole package reply's rewrite (macOS: relayUpstreamBuffered's),
    /// in steps on the rewrite pool, none blocking a worker: room for its
    /// decoded copy (the cap when it's encoded, its own size when not, plus
    /// the framing's working copy), then room for its rewritten copy, each
    /// taken in line from the budget. A step with no room goes back to the
    /// queue (50 ms on). Each copy, once made, frees the one before it, and
    /// the reply's share goes back once the guest's write completes.
    // @port-skip linux-only: relayUpstreamBuffered's rewrite, off the Linux relay's loop
    final class SupplyChainJob: @unchecked Sendable {
        let supplyChain: SupplyChainRewrite
        let host: String
        let clean: Bool
        let ticket: UInt64
        let budget: SupplyChainBudget
        let guest: Channel
        let proxy: MitmProxy?
        let trace: RequestReader.Trace?
        let wire: Int
        private var raw: Data
        private var plain: Data?

        // @port-skip linux-only: see SupplyChainJob
        init(raw: Data, supplyChain: SupplyChainRewrite, host: String, clean: Bool, ticket: UInt64,
             budget: SupplyChainBudget, guest: Channel, proxy: MitmProxy?, trace: RequestReader.Trace?) {
            self.budget = budget
            self.raw = raw
            self.wire = raw.count
            self.supplyChain = supplyChain
            self.host = host
            self.clean = clean
            self.ticket = ticket
            self.guest = guest
            self.proxy = proxy
            self.trace = trace
        }

        /// Queued (the budget isn't idle until it's handed to the guest).
    // partial: the buffered relay's rewrite off the Linux relay's loop
    // @port relayUpstreamBuffered(rawRequest: Data, host: String, port: Int, session: URLSession, tls: MitmServerStream, scheme: String, rewrite: (Data)->Data) h=1d63a33b9542d796 @003f61e7
    func start() {
            budget.rewriting(true)
            ResponseRelay.supplyChainQueue.addOperation { self.step() }
        }

        // @port-skip linux-only: see SupplyChainJob
        private func later() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                ResponseRelay.supplyChainQueue.addOperation { self.step() }
            }
        }

        // @port-skip linux-only: see SupplyChainJob
        func step() {
            // The guest left meanwhile: nobody to rewrite it for.
            guard guest.isActive else { return finish(nil) }
            if plain == nil {
                let decoded = ResponseRelay.finalIsEncoded(raw) ? ResponseRelay.supplyChainCap : raw.count
                guard budget.reserve(raw.count + decoded, for: ticket) else { return later() }
                guard let final = HTTPRequestFraming.finalResponse(raw) else {
                    return finish(ResponseRelay.supplyChainRefusal(host, "couldn't be read"))
                }
                switch RequestReader.supplyChainPlain(final, cleanClose: clean, head: supplyChain.bodiless) {
                case .bodiless(let reply)?:
                    return finish(reply)
                case .whole(let p)?:
                    raw = Data()
                    plain = p
                    budget.hold(p.count, for: ticket)
                case nil:
                    return finish(ResponseRelay.supplyChainRefusal(host, "couldn't be read"))
                }
            }
            guard let p = plain else { return }
            guard budget.reserve(p.count, for: ticket) else { return later() }
            let out = supplyChain.rewrite(p)
            plain = nil
            budget.hold(out.count, for: ticket)
            finish(out)
        }

        /// The reply to the guest (nil: none, it left); the share goes back
        /// once it's written. The rewrite counts as under way up to this
        /// hand-off only, and a guest that stops reading (a suspended VM, a
        /// zero window) is closed past the write deadline, which fails the
        /// write and gives the share back.
        // @port-skip linux-only: see SupplyChainJob
        private func finish(_ reply: Data?) {
            let (budget, ticket) = (budget, ticket)
            raw = Data(); plain = nil
            budget.rewriting(false)
            guard let reply else { budget.finish(ticket); return }
            let (guest, proxy, trace, wire) = (guest, proxy, trace, wire)
            let deadline = ResponseRelay.supplyChainWriteDeadline.withLockedValue { $0 }
            guest.eventLoop.execute {
                let late = guest.eventLoop.scheduleTask(in: .milliseconds(Int64(deadline * 1000))) {
                    FileHandle.standardError.write(Data("[supply-chain] the guest didn't take its reply in \(deadline) s: closed\n".utf8))
                    guest.close(promise: nil)
                }
                guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in
                    late.cancel()
                    budget.finish(ticket)
                    guest.close(promise: nil)
                }
                if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: wire, truncated: false) }
            }
        }
    }

    /// Kept for learning while strict credential mode is on for the workspace
    /// (the final response: an upgrade's stream carries no tokens to learn).
    // @port-skip linux-only: relayUpstream's response buffer for UnmanagedCredentialGuard.learn, on NIO
    private func keepForLearning<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        guard learning, learnBuf.count < Self.learnCap, UnmanagedCredentialGuard.shared.isEnabled(for: profileID) else { return }
        learnBuf.append(contentsOf: bytes.prefix(Self.learnCap - learnBuf.count))
    }

    /// The guest can't take more: the upstream isn't read until it drains
    /// (RequestReader, on the guest's channel, resumes it). Paused before
    /// the flush: a flush that drains at once fires that resume inside it.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func holdIfGuestFull(_ context: ChannelHandlerContext) {
        guard !guest.isWritable else { return }
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        guest.flush()
    }

    /// The upstream drained: the guest (an upgraded stream's) may be read again.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { onUpstreamWritable?() }
        context.fireChannelWritabilityChanged()
    }

    /// True when the header block (a request's, or a 101's) has exactly one
    /// `Upgrade` header and every protocol it names is one the raw pump
    /// carries (`websocket`, `SPDY/3.1`). The block goes upstream as it is,
    /// so `websocket, h2c`, a second Upgrade line, or a folded continuation
    /// line (which an upstream joins to the header above) would still offer
    /// h2c: none of them is pumped.
    // @port HTTPMitmConnection.static pumpedUpgrade(headerBlock: String) h=031a5782274474c1 @a6507010
    // partial: the request half: the rule alone (the Connection header doesn't decide it)
    // @port HTTPMitmConnection.isWebSocketUpgrade(rawRequest: Data) h=b7521939c43dc0ee @003f61e7
    static func pumpedUpgrade(headerBlock: String) -> Bool {
        var protocols: [String]?
        for (i, line) in headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false).enumerated() where i > 0 {
            if line.first == " " || line.first == "\t" { return false }   // obs-fold
            // A bare CR or LF, or a NUL: a lenient upstream may split there.
            if line.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) { return false }
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" else { continue }
            guard protocols == nil else { return false }                   // a second Upgrade header
            protocols = line[line.index(after: colon)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        // One protocol only: with two on offer ("websocket, SPDY/3.1") the
        // relay can't know which the upstream will pick before its 101.
        guard let protocols, protocols.count == 1 else { return false }
        return protocols[0] == "websocket" || protocols[0] == "spdy/3.1"
    }

    /// The one protocol a pumped upgrade's header block names, lowercased.
    // @port-skip linux-only: the 101's protocol held to the request's
    static func upgradeToken(_ headerBlock: String) -> String? {
        guard pumpedUpgrade(headerBlock: headerBlock) else { return nil }
        return SubscriptionAuthRewrite.headerValue("upgrade", inHeaderSection: headerBlock)?
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The switched protocol is WebSocket (its frames can be read), not an
    /// opaque stream (SPDY).
    // @port-skip linux-only: the Linux proxy's upgrade policy
    static func switchedToWebSocket(_ responseHead: Data) -> Bool {
        let head = String(decoding: responseHead, as: UTF8.self)
        guard let v = SubscriptionAuthRewrite.headerValue("upgrade", inHeaderSection: head) else { return true }
        return v.lowercased().contains("websocket")
    }

    /// A response head's status code.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func status(_ head: Data) -> Int? {
        guard let eol = head.firstIndex(of: 0x0D) else { return nil }
        let parts = String(decoding: head[head.startIndex..<eol], as: UTF8.self).split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelReadComplete(context: ChannelHandlerContext) { guest.flush() }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        // The hooks into the request side go with the upstream.
        defer { onUpstreamWritable = nil; onSwitched = nil }
        // This reply's share of the read-whole budget goes back on every
        // path, unless the rewrite took it (it releases it when it's done).
        let ticket = supplyChainTicket
        stallCheck?.cancel()
        var handedOff = false
        defer { if !handedOff { budget.finish(ticket) } }
        if !learnBuf.isEmpty {
            // De-chunked, as macOS's URLSession hands it the body. A body still
            // encoded (gzip or br, though identity was asked for) is skipped,
            // nothing here decodes it; its head (a Set-Cookie) still counts.
            let response = Self.isEncoded(learnBuf)
                ? Data(learnBuf.prefix(through: learnBuf.range(of: Data("\r\n\r\n".utf8))!.upperBound - 1))
                : HTTPRequestFraming.dechunkedResponse(learnBuf)
            proxy?.learnIssued(response, host: host, profileID: profileID, session: strictSession)
            learnBuf = Data()
        }
        if let (minter, kind) = mint {
            // Rewritten before any byte reaches the guest, the credentials in
            // it kept on the host; a reply it can't account for (still encoded,
            // though identity was asked for) is a 502 (macOS:
            // relayUpstreamBuffered's rewrite of URLSession's decoded reply).
            // Only the final response is rewritten: interim 1xx heads before it
            // (URLSession consumes them on macOS) would carry it past the
            // rewrite, which reads the first head's status.
            let raw = whole
            noteStatus(raw)
            let rewritten: Data
            if overflowed {
                rewritten = CredentialMint.refusal("a response over \(Self.wholeCap >> 20) MiB")
            } else if let final = HTTPRequestFraming.finalResponse(raw) {
                rewritten = Self.isEncoded(final) ? CredentialMint.refusal("an encoded response")
                    : minter.process(response: HTTPRequestFraming.dechunkedResponse(final), kind: kind, profileID: profileID)
            } else {
                rewritten = CredentialMint.refusal("no final response (a 1xx only, or a protocol switch)")
            }
            let reply = HTTPRequestFraming.replacingHeaders(rewritten, drop: ["connection", "keep-alive"], add: "Connection: close")
            let guest = self.guest
            guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in guest.close(promise: nil) }
            // The trace keeps what the guest got, never the real credentials.
            if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: raw.count, truncated: false) }
            return
        }
        if let supplyChain {
            // The final response, decoded and rewritten before any byte
            // reaches the guest (macOS: relayUpstreamBuffered), off the event
            // loop; written back on it. One past the cap, or one that can't
            // be decoded, is refused, not passed on unchecked.
            // One past the cap, or stalled: refused here, its bytes let go.
            if overflowed || stalled {
                let reply = Self.supplyChainRefusal(host, overflowed
                    ? "is too large to check (over \(Self.supplyChainCap >> 20) MiB, or no room for it in time)"
                    : "stalled (too slow, or nothing came for a while)")
                whole = Data(); waiting.removeAll(); waitingBytes = 0; waitingSince = nil
                let guest = self.guest
                guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in guest.close(promise: nil) }
                if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: reply.count, truncated: false) }
                return
            }
            // Chunks still waiting for room come along, in order: already in
            // memory, they're counted, not waited for. (The buffer is moved,
            // not copied, then appended to in place.)
            var raw = Data()
            swap(&raw, &whole)
            for b in waiting { raw.append(contentsOf: b.readableBytesView) }
            budget.add(waitingBytes, for: ticket)
            waiting.removeAll()
            waitingBytes = 0
            waitingSince = nil
            noteStatus(raw)
            handedOff = true
            SupplyChainJob(raw: raw, supplyChain: supplyChain, host: host, clean: failure == nil, ticket: ticket,
                           budget: budget, guest: guest, proxy: proxy, trace: trace).start()
            return
        }
        if let capture {
            // The final response only (its 1xx heads skipped), or none: a
            // switched protocol, a reply over the cap.
            let raw = overflowed ? SignInCapture.notKeptReply
                : (HTTPRequestFraming.finalResponse(whole) ?? SignInCapture.notKeptReply)
            let (status, body) = HTTPRequestFraming.responseStatusAndBody(raw)
            noteStatus(raw)
            let guest = self.guest
            let encoded = Self.isEncoded(raw)
            let (proxy, trace) = (self.proxy, self.trace)
            Task {
                let kept = encoded ? nil : await capture.handle(status, body)
                // A successful exchange the host didn't keep never reaches
                // the guest: its real tokens would. (A pending device-code
                // poll or an error isn't a 200, and passes through; a poll's
                // error a lenient provider sends as a 200 goes on rebuilt
                // from its allowed fields, as macOS does.)
                let reply: Data
                var pollError = false
                if let kept {
                    reply = kept
                } else if status == 200 {
                    let rebuilt = encoded ? nil : SignInCapture.pollErrorReply(body)
                    pollError = rebuilt != nil
                    reply = rebuilt ?? SignInCapture.notKeptReply
                } else {
                    reply = raw
                }
                FileHandle.standardError.write(Data(
                    "[mitm] sign-in exchange → \(status), \(kept != nil ? "kept on the host" : pollError ? "a poll's error, passed on rebuilt" : status == 200 ? "NOT kept\(encoded ? " (encoded reply)" : ""): refused to the guest" : "passed through")\n".utf8))
                guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in guest.close(promise: nil) }
                // The trace keeps what the guest got, never the provider's
                // reply (its real tokens).
                if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: raw.count, truncated: false) }
            }
            return
        }
        // Gone before a byte of its response: the guest is told why, as
        // macOS answers a lost connection, not left with a bare close.
        if !relayed {
            let reply = proxy?.upstreamErrorResponse(failure ?? ChannelError.eof, host: host, profileID: profileID)
                ?? MitmProxy.upstreamErrorResponse(failure ?? ChannelError.eof, host: host)
            if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: 0, truncated: false) }
            guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in self.guest.close(promise: nil) }
            return
        }
        // A restored WebSocket that ended without a close frame: what its
        // restorer holds still reaches the client.
        if let wsServer {
            let tail = wsServer.finishAtClose()
            wsTrace?.toGuest(tail)
            if !tail.isEmpty { guest.write(guest.allocator.buffer(bytes: tail), promise: nil) }
        }
        // A restored body read up to the close: what's held, and the last
        // chunk only when the upstream closed cleanly (a reset or an unclean
        // TLS shutdown leaves the reply cut).
        if let pii, pii.restoring, !pii.ended {
            let tail = pii.finish(clean: failure == nil)
            keepForTrace(tail)
            guest.write(guest.allocator.buffer(bytes: tail), promise: nil)
        }
        if let proxy, let trace {
            if let wsTrace {
                // A WebSocket: its handshake and messages (macOS: emitWebSocketTrace).
                proxy.emitWebSocketTrace(trace, wsTrace)
            } else {
                proxy.emitTrace(trace, response: traceTruncated ? traceCopy : HTTPRequestFraming.dechunkedResponse(traceCopy),
                                wireBytes: traceWire, truncated: traceTruncated)
            }
        }
        guest.writeAndFlush(guest.allocator.buffer(capacity: 0)).whenComplete { _ in self.guest.close(promise: nil) }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if failure == nil { failure = error }
        context.close(promise: nil)
    }

    /// Whether a response's body is content-encoded (gzip, br, …).
    // @port-skip linux-only: proxy response parsing
    /// Whether the final response (past any 1xx interim heads) is
    /// content-coded, by every Content-Encoding line it has. Read in place:
    /// nothing copied before the rewrite has room for its copies.
    // @port-skip linux-only: the read-whole budget's decoded-size estimate
    static func finalIsEncoded(_ raw: Data) -> Bool {
        var start = raw.startIndex
        while let end = raw[start...].range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: raw[start..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
            if (100..<200).contains(status), status != 101 { start = end.upperBound; continue }
            return lines.dropFirst().contains { line in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-encoding" else { return false }
                return line[line.index(after: colon)...].split(separator: ",").contains {
                    let t = $0.trimmingCharacters(in: .whitespaces).lowercased()
                    return !t.isEmpty && t != "identity"
                }
            }
        }
        return false
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func isEncoded(_ raw: Data) -> Bool {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        let ce = HTTPRequestFraming.headers(head)["content-encoding"]?.lowercased() ?? "identity"
        return !ce.isEmpty && ce != "identity"
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func noteStatus(_ head: Data) {
        guard HTTPRequestFraming.responseStatusAndBody(head).status == 401 else { return }
        SubscriptionAuthRewrite.noteUnauthorized(injected, response: head, profileID: profileID)
    }
}

/// What explains a switch denial (SwitchEgressReport): the guardrails this
/// proxy enforces for each workspace (macOS: MitmEngine).
// @port-skip linux-only: the daemon's proxy as SwitchEgressReport's GuardrailsConfigSource
extension MitmProxy: GuardrailsConfigSource {}

/// A model provider's WebSocket streaming keeps its agent "working": a
/// chunk of relayed frames (not a lone ping or pong, a socket kept alive
/// while idle) fires at most every 2 s (macOS: HTTPMitmConnection.ActivityBeat).
// @port-skip linux-only: container of ActivityBeat's port
final class ActivityBeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let fire: (() -> Void)?
    // @port HTTPMitmConnection.ActivityBeat.init(fire: (()->Void)?) h=9c4f972ac6e67150 @003f61e7
    init(fire: (() -> Void)?) { self.fire = fire }

    // @port HTTPMitmConnection.ActivityBeat.tick(_: Data) h=377802138fca3f06 @003f61e7
    func tick(_ chunk: Data) {
        guard fire != nil, !Self.isKeepAlive(chunk) else { return }
        tick()
    }

    // @port HTTPMitmConnection.ActivityBeat.static isKeepAlive(_: Data) h=0b7b95527ed05916 @003f61e7
    static func isKeepAlive(_ chunk: Data) -> Bool {
        guard let first = chunk.first, chunk.count < 64 else { return false }
        let opcode = first & 0x0F
        return opcode == 0x9 || opcode == 0xA
    }

    // @port HTTPMitmConnection.ActivityBeat.tick() h=20062c8039a2c771 @003f61e7
    func tick() {
        guard let fire else { return }
        lock.lock()
        let due = Date().timeIntervalSince(last) >= 2
        if due { last = Date() }
        lock.unlock()
        if due { fire() }
    }
}
