import Foundation
@preconcurrency import Virtualization

/// Process-lifetime MITM coordinator. Owns the CA, the cert cache,
/// the token swap maps, and the ssh-agent keystore. ACAppDelegate
/// builds one at app launch, and registers the per-VM listeners
/// against it whenever a session opens.
@MainActor
public final class MitmEngine {
    public let ca: BromureCA
    public let certCache: CertCache
    public let swapper: TokenSwapper
    /// Host-owned shared Claude subscription credential + the bogus-key
    /// registry the proxy consults. One per process, shared by every session.
    public let claudeSubscriptionStore: ClaudeSubscriptionStore
    /// Serializes Claude OAuth refresh so concurrent VMs share one refresh.
    public let claudeRefresher: ClaudeSubscriptionRefresher
    /// Codex / ChatGPT counterparts of the Claude subscription store + refresher.
    public let codexSubscriptionStore: CodexSubscriptionStore
    public let codexRefresher: CodexSubscriptionRefresher
    /// Grok (xAI) counterparts.
    public let grokSubscriptionStore: GrokSubscriptionStore
    public let grokRefresher: GrokSubscriptionRefresher
    public let sshAgent: SSHAgentServer
    public let awsCreds: AWSCredentialServer
    /// Strips the (intentionally invalid) signature on AWS-bound
    /// requests and re-signs with material that lives only on the host.
    /// See `AWSResigner` for the threat model.
    public let awsResigner: AWSResigner
    public let consent: ConsentBroker
    /// Per-profile, per-scope consent for the `.promptOnWrite`
    /// guardrails mode. Lives alongside the credential `consent`
    /// broker but uses a different decision set (Allow once / 15 min /
    /// session / Don't allow) tailored to "should this write fire?".
    public let guardrailsBroker: GuardrailsConsentBroker
    /// Per-profile, per-scope consent for supply-chain policy
    /// prompts (lockfile-pinned bypass, per-package overrides).
    public let supplyChainBroker: SupplyChainConsentBroker
    /// Process-wide OSV (osv.dev) client. Caches lookups across all
    /// profiles so a popular package + version answered once is
    /// cheap thereafter.
    public let osvClient: OSVClient
    /// Same for socket.dev. The API key is per-profile, so calls
    /// look it up off the SupplyChainPolicy at request time.
    public let socketClient: SocketDevClient
    /// `(ecosystem, name, version) → publishedAt` map populated as
    /// metadata responses flow through. Used by the artifact-fetch
    /// backstop (don't allow pinned-too-fresh tarball requests).
    public let publishTimeCache: PublishTimeCache
    public let traceStore: TraceStore
    /// Per-profile, per-host SecIdentity table for upstream client-cert
    /// auth (Kubernetes API servers, internal mTLS APIs, etc.). The
    /// proxy's URLSession delegate looks up here when an upstream
    /// challenge comes in.
    public let clientIdentities = ClientIdentityRegistry()
    /// Per-profile, per-host CA the proxy must trust when reaching
    /// the upstream API server. Used by the HTTPProxy URLSession
    /// delegate's serverTrust handler.
    public let clusterCAs = ClusterCATrustRegistry()
    /// Owner of the exec-credential poller tasks. One Task per
    /// kubeconfig entry; cancelled in `unregister(profileID:)`.
    public let execPoller = ExecCredentialPoller()
    /// Owner of the 1Password `op://` refresh loops (one per profile), which
    /// re-resolve op-sourced credentials every 120 s and update the swap map
    /// in place. Cancelled in `unregister(profileID:)`.
    public let opRefresher = OnePasswordRefresher()

    /// Per-profile trace level + session id, set by ACAppDelegate at
    /// session launch. The HTTPProxy connection looks these up to
    /// decide whether to record + capture bodies. Lock-protected
    /// (rather than @MainActor) because the proxy hot path runs on
    /// a detached Task — `MainActor.assumeIsolated` would trap there.
    public struct SessionTrace: Sendable {
        public let sessionID: UUID
        public let level: TraceLevel
        public init(sessionID: UUID, level: TraceLevel) {
            self.sessionID = sessionID
            self.level = level
        }
    }
    private let sessionTraceLock = NSLock()
    nonisolated(unsafe) private var sessionTraces: [UUID: SessionTrace] = [:]

    public nonisolated func setSessionTrace(_ trace: SessionTrace, for profileID: UUID) {
        sessionTraceLock.lock(); defer { sessionTraceLock.unlock() }
        sessionTraces[profileID] = trace
    }
    public nonisolated func sessionTrace(for profileID: UUID) -> SessionTrace? {
        sessionTraceLock.lock(); defer { sessionTraceLock.unlock() }
        return sessionTraces[profileID]
    }
    public nonisolated func clearSessionTrace(for profileID: UUID) {
        sessionTraceLock.lock(); defer { sessionTraceLock.unlock() }
        sessionTraces.removeValue(forKey: profileID)
    }

    // Per-profile "Guardrails" guard config (host-side destructive-verb removal).
    // Lock-protected like sessionTraces so the proxy hot path reads it without
    // an actor hop.
    private let guardrailsLock = NSLock()
    nonisolated(unsafe) private var guardrailsConfigs: [UUID: GuardrailsConfig] = [:]

    public nonisolated func setGuardrailsConfig(_ config: GuardrailsConfig, for profileID: UUID) {
        guardrailsLock.lock(); defer { guardrailsLock.unlock() }
        guardrailsConfigs[profileID] = config
    }
    public nonisolated func guardrailsConfig(for profileID: UUID) -> GuardrailsConfig? {
        guardrailsLock.lock(); defer { guardrailsLock.unlock() }
        return guardrailsConfigs[profileID]
    }
    public nonisolated func clearGuardrailsConfig(for profileID: UUID) {
        guardrailsLock.lock(); defer { guardrailsLock.unlock() }
        guardrailsConfigs.removeValue(forKey: profileID)
    }

    // Same shape for supply-chain policy. Looked up per-request
    // on the proxy hot path; lock-guarded so the host can update
    // it live (profile editor save) without an actor hop.
    private let supplyChainLock = NSLock()
    nonisolated(unsafe) private var supplyChainPolicies: [UUID: SupplyChainPolicy] = [:]

    public nonisolated func setSupplyChainPolicy(_ policy: SupplyChainPolicy, for profileID: UUID) {
        supplyChainLock.lock()
        let prior = supplyChainPolicies[profileID]
        supplyChainPolicies[profileID] = policy
        supplyChainLock.unlock()
        // Emit a one-line summary every time the proxy sees a *new*
        // or *changed* policy, so the user has a visible confirmation
        // in the log that their toggles actually landed. Cheap; only
        // fires on session start and live profile saves.
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
            if policy.delpiActive {
                bits.append("delpi=npm→\(DelpiRegistry.host)")
            } else if policy.packageFilter == .delpi {
                bits.append("delpi=selected-but-no-key")
            }
            if policy.stripInstallScripts { bits.append("strip-scripts") }
            let summary = bits.isEmpty ? "off" : bits.joined(separator: " ")
            SupplyChainLog.shared.record(
                "[supply-chain] policy engaged for \(profileID.uuidString.prefix(8)): \(summary)")
        }
    }
    public nonisolated func supplyChainPolicy(for profileID: UUID) -> SupplyChainPolicy? {
        supplyChainLock.lock(); defer { supplyChainLock.unlock() }
        return supplyChainPolicies[profileID]
    }
    public nonisolated func clearSupplyChainPolicy(for profileID: UUID) {
        supplyChainLock.lock(); defer { supplyChainLock.unlock() }
        supplyChainPolicies.removeValue(forKey: profileID)
    }

    private let promptInjectionLock = NSLock()
    nonisolated(unsafe) private var promptInjectionPolicies: [UUID: PromptInjectionPolicy] = [:]

    public nonisolated func setPromptInjectionPolicy(_ policy: PromptInjectionPolicy, for profileID: UUID) {
        promptInjectionLock.lock()
        let prior = promptInjectionPolicies[profileID]
        promptInjectionPolicies[profileID] = policy
        promptInjectionLock.unlock()
        if prior != policy {
            var bits: [String] = []
            if policy.detectSourceInjection { bits.append("source") }
            if policy.detectRulesInjection { bits.append("rules") }
            let what = bits.isEmpty ? "off" : bits.joined(separator: "+") + " → \(policy.onDetection.rawValue)"
            SupplyChainLog.shared.record(
                "[prompt-injection] policy engaged for \(profileID.uuidString.prefix(8)): \(what)")
        }
    }
    public nonisolated func promptInjectionPolicy(for profileID: UUID) -> PromptInjectionPolicy? {
        promptInjectionLock.lock(); defer { promptInjectionLock.unlock() }
        return promptInjectionPolicies[profileID]
    }
    public nonisolated func clearPromptInjectionPolicy(for profileID: UUID) {
        promptInjectionLock.lock(); defer { promptInjectionLock.unlock() }
        promptInjectionPolicies.removeValue(forKey: profileID)
    }

    // MARK: - Fusion engaged state
    //
    // Per-profile runtime flag for whether Fusion is currently engaged.
    // Written from the @MainActor UI (the title-bar lightning toggle and
    // session launch) and read from the proxy's non-MainActor hot path,
    // so it lives behind a lock rather than on the UI's @Observable model.
    private let fusionLock = NSLock()
    nonisolated(unsafe) private var fusionEngagedFlags: [UUID: Bool] = [:]

    public nonisolated func setFusionEngaged(_ engaged: Bool, for profileID: UUID) {
        fusionLock.lock()
        let prior = fusionEngagedFlags[profileID]
        fusionEngagedFlags[profileID] = engaged
        fusionLock.unlock()
        if prior != engaged {
            SupplyChainLog.shared.record(
                "[fusion] \(engaged ? "engaged" : "disengaged") for \(profileID.uuidString.prefix(8))")
        }
    }
    public nonisolated func fusionEngaged(for profileID: UUID) -> Bool {
        fusionLock.lock(); defer { fusionLock.unlock() }
        return fusionEngagedFlags[profileID] ?? false
    }
    public nonisolated func clearFusionEngaged(for profileID: UUID) {
        fusionLock.lock(); defer { fusionLock.unlock() }
        fusionEngagedFlags.removeValue(forKey: profileID)
    }

    /// Per-profile Fusion config (legs + judge + auth modes), pushed at session
    /// launch. Read by the proxy's `fusionConfigProvider` on the hot path.
    nonisolated(unsafe) private var fusionConfigs: [UUID: Fusion.Config] = [:]
    nonisolated func setFusionConfig(_ config: Fusion.Config?, for profileID: UUID) {
        fusionLock.lock(); defer { fusionLock.unlock() }
        fusionConfigs[profileID] = config
    }
    nonisolated func fusionConfig(for profileID: UUID) -> Fusion.Config? {
        fusionLock.lock(); defer { fusionLock.unlock() }
        return fusionConfigs[profileID]
    }
    nonisolated func clearFusionConfig(for profileID: UUID) {
        fusionLock.lock(); defer { fusionLock.unlock() }
        fusionConfigs.removeValue(forKey: profileID)
    }

    /// Per-profile LLM routing context (Cloud/Local/Hybrid + hybrid policy
    /// engine). Pushed at session launch and on `vm routing` changes; read
    /// by the proxy's `routingProvider` on the hot path. Same lock + same
    /// MainActor-write / hot-path-read rationale as Fusion above.
    nonisolated(unsafe) private var routingContexts: [UUID: LLMRoutingContext] = [:]

    public nonisolated func setRouting(_ routing: Profile.Routing,
                                       modelLabel: String,
                                       hybrid: HybridConfig,
                                       localCloudHosts: Set<String> = [],
                                       for profileID: UUID) {
        fusionLock.lock()
        if let existing = routingContexts[profileID] {
            existing.routing = routing
            existing.localModelLabel = modelLabel
            existing.hybrid.update(config: hybrid)
            existing.localCloudHosts = localCloudHosts
        } else {
            routingContexts[profileID] = LLMRoutingContext(
                routing: routing, localModelLabel: modelLabel,
                hybrid: HybridRouter(config: hybrid),
                localCloudHosts: localCloudHosts)
        }
        fusionLock.unlock()
        SupplyChainLog.shared.record(
            "[routing] \(routing.rawValue) for \(profileID.uuidString.prefix(8))")
    }

    nonisolated func routingContext(for profileID: UUID) -> LLMRoutingContext? {
        fusionLock.lock(); defer { fusionLock.unlock() }
        return routingContexts[profileID]
    }

    public nonisolated func clearRouting(for profileID: UUID) {
        fusionLock.lock(); defer { fusionLock.unlock() }
        routingContexts.removeValue(forKey: profileID)
    }

    /// Per-install 32-byte salt for deriving fake tokens from real
    /// ones via HKDF. Generated once, persisted under app support so
    /// a given real key always maps to the same fake on this Mac —
    /// otherwise Claude Code (and probably others) detect the rotating
    /// identity on every session and re-prompt the user.
    public let fakeTokenSalt: Data

    /// Vsock port the in-VM bridge connects to for HTTPS proxy.
    public static let httpsVsockPort: UInt32 = 8443
    /// Vsock port the in-VM bridge connects to for the ssh-agent.
    public static let sshAgentVsockPort: UInt32 = 8444
    /// Vsock port the in-VM AWS credential_process helper connects to.
    /// Host pushes a SDK-format JSON payload per connection.
    public static let awsCredsVsockPort: UInt32 = 8445
    /// Vsock port the in-VM bridge connects to reach the local inference
    /// engine (Path 1, §2.2). Spliced to 127.0.0.1:<enginePort> on host.
    public static let inferenceVsockPort: UInt32 = 8446

    /// Per-VM listener delegates kept alive so they aren't GC'd while
    /// the VM is running. Keyed by profile UUID.
    private var listenerHolders: [UUID: ListenerHolder] = [:]

    /// Our spawned ssh-agent. Owns the per-profile bromure keys
    /// (loaded via `ssh-add` at session launch) plus any keys the
    /// user explicitly imported through the profile UI; sole back-
    /// end for the in-VM agent socket.
    public let privateAgent: PrivateSSHAgent

    public init() throws {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        let caDir = supportDir.appendingPathComponent("ca", isDirectory: true)
        self.ca = try BromureCA.loadOrCreate(at: caDir)
        self.certCache = CertCache(ca: ca)
        // Construct the consent broker first — every cred-vending
        // server takes a reference to it.
        let broker = ConsentBroker()
        self.consent = broker
        self.guardrailsBroker = GuardrailsConsentBroker()
        self.supplyChainBroker = SupplyChainConsentBroker()
        self.osvClient = OSVClient()
        self.socketClient = SocketDevClient()
        self.publishTimeCache = PublishTimeCache()
        self.swapper = TokenSwapper(consent: broker)
        let claudeStore = ClaudeSubscriptionStore()
        self.claudeSubscriptionStore = claudeStore
        self.claudeRefresher = ClaudeSubscriptionRefresher(store: claudeStore)
        let codexStore = CodexSubscriptionStore()
        self.codexSubscriptionStore = codexStore
        self.codexRefresher = CodexSubscriptionRefresher(store: codexStore)
        let grokStore = GrokSubscriptionStore()
        self.grokSubscriptionStore = grokStore
        self.grokRefresher = GrokSubscriptionRefresher(store: grokStore)
        self.sshAgent = SSHAgentServer(consent: broker)
        self.awsCreds = AWSCredentialServer(consent: broker)
        self.awsResigner = AWSResigner(credServer: awsCreds)
        self.traceStore = TraceStore()
        // Spawn our dedicated ssh-agent BEFORE anyone reads the
        // HostAgentClient lazy vars — that way `_bromurePrivate` is
        // set by the time any session-launch code asks for it.
        self.privateAgent = try PrivateSSHAgent()
        HostAgentClient._bromurePrivate = HostAgentClient(socketPath: privateAgent.socketPath)

        // Per-install salt for fake-token derivation. Stored alongside
        // the CA. Wiping the file rotates every fake on this Mac.
        let saltURL = supportDir.appendingPathComponent("fake-salt.bin")
        if let existing = try? Data(contentsOf: saltURL), existing.count == 32 {
            self.fakeTokenSalt = existing
        } else {
            let fresh = Data(randomBytes(32))
            try? FileManager.default.createDirectory(
                at: supportDir, withIntermediateDirectories: true)
            try fresh.write(to: saltURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: saltURL.path)
            self.fakeTokenSalt = fresh
        }
    }

    /// Wire vsock listeners on the VM's socket device. Call once per
    /// session right after `vm.start()` (but before traffic flows).
    /// Releases on `unregister(profileID:)` or VM teardown.
    public func register(socketDevice: VZVirtioSocketDevice, profileID: UUID) {
        // Wire the proxy's static prompt-injection policy hook to this engine.
        // Set every register (cheap, idempotent); routes by the profile id the
        // proxy passes, so one closure serves all connections.
        HTTPMitmConnection.promptInjectionPolicyProvider = { [weak self] pid in
            self?.promptInjectionPolicy(for: pid)
        }
        // Same idea for Fusion: one closure routes by profile id and lets
        // the proxy ask "is Fusion engaged for this session right now?".
        HTTPMitmConnection.fusionEngagedProvider = { [weak self] pid in
            self?.fusionEngaged(for: pid) ?? false
        }
        HTTPMitmConnection.fusionConfigProvider = { [weak self] pid in
            self?.fusionConfig(for: pid)
        }
        HTTPMitmConnection.routingProvider = { [weak self] pid in
            self?.routingContext(for: pid)
        }
        // Claude subscription auth: one closure lets the proxy reach the shared
        // store (bogus-key lookup) + refresher (live access token).
        HTTPMitmConnection.claudeSubscriptionProvider = { [weak self] in
            guard let self else { return nil }
            return (self.claudeSubscriptionStore, self.claudeRefresher)
        }
        HTTPMitmConnection.codexSubscriptionProvider = { [weak self] in
            guard let self else { return nil }
            return (self.codexSubscriptionStore, self.codexRefresher)
        }
        HTTPMitmConnection.grokSubscriptionProvider = { [weak self] in
            guard let self else { return nil }
            return (self.grokSubscriptionStore, self.grokRefresher)
        }
        let holder = ListenerHolder(
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            sshAgent: sshAgent,
            awsCreds: awsCreds,
            awsResigner: awsResigner,
            traceStore: traceStore,
            clientIdentities: clientIdentities,
            clusterCAs: clusterCAs,
            consent: consent,
            guardrailsBroker: guardrailsBroker,
            supplyChainBroker: supplyChainBroker,
            osvClient: osvClient,
            socketClient: socketClient,
            publishTimeCache: publishTimeCache,
            // The provider runs from a detached Task on the proxy's
            // hot path. `sessionTrace(for:)` is now nonisolated +
            // lock-protected so this is just a hash lookup behind a
            // mutex — no actor hop required.
            sessionTraceProvider: { [weak self] in
                self?.sessionTrace(for: profileID)
            },
            guardrailsProvider: { [weak self] in
                self?.guardrailsConfig(for: profileID)
            },
            supplyChainProvider: { [weak self] in
                self?.supplyChainPolicy(for: profileID)
            }
        )
        socketDevice.setSocketListener(holder.httpListener,
                                       forPort: Self.httpsVsockPort)
        socketDevice.setSocketListener(holder.sshListener,
                                       forPort: Self.sshAgentVsockPort)
        socketDevice.setSocketListener(holder.awsListener,
                                       forPort: Self.awsCredsVsockPort)
        socketDevice.setSocketListener(holder.inferenceListener,
                                       forPort: Self.inferenceVsockPort)
        listenerHolders[profileID] = holder
    }

    public func unregister(profileID: UUID) {
        listenerHolders.removeValue(forKey: profileID)
        clearGuardrailsConfig(for: profileID)
        clearSupplyChainPolicy(for: profileID)
        clearFusionEngaged(for: profileID)
        clearRouting(for: profileID)
        swapper.clearMap(for: profileID)
        sshAgent.clearKeys(for: profileID)
        sshAgent.clearImportedKeyApprovals(for: profileID)
        awsCreds.clearCredentials(for: profileID)
        clientIdentities.clearAll(for: profileID)
        clusterCAs.clearAll(for: profileID)
        execPoller.stopAll()
        opRefresher.stop(profileID: profileID)
        // Drop any consent grants the user issued during this session
        // — "Allow for the rest of the session" must not survive a
        // window close. Detached so we don't block the @MainActor
        // teardown path on the actor hop.
        let broker = consent
        Task.detached { await broker.revokeAll(profileID: profileID) }
        Task.detached { await broker.clearProfileName(for: profileID) }
        // Same lifetime rules for guardrails consent: session-scope
        // "Allow until the session ends" grants must not survive a
        // window close.
        let gBroker = guardrailsBroker
        Task.detached { await gBroker.revokeAll(profileID: profileID) }
        Task.detached { await gBroker.clearProfileName(for: profileID) }
        let scBroker = supplyChainBroker
        Task.detached { await scBroker.revokeAll(profileID: profileID) }
        Task.detached { await scBroker.clearProfileName(for: profileID) }
    }
}

/// Holds the listener delegates for a single VM. Owning the
/// delegates outside of the VM keeps them alive across the
/// connection lifetime.
private final class ListenerHolder {
    let profileID: UUID
    let httpDelegate: HTTPListenerDelegate
    let sshDelegate: SSHListenerDelegate
    let awsDelegate: AWSCredsListenerDelegate
    let inferenceDelegate: InferenceListenerDelegate
    let httpListener: VZVirtioSocketListener
    let sshListener: VZVirtioSocketListener
    let awsListener: VZVirtioSocketListener
    let inferenceListener: VZVirtioSocketListener

    init(profileID: UUID,
         certCache: CertCache,
         swapper: TokenSwapper,
         sshAgent: SSHAgentServer,
         awsCreds: AWSCredentialServer,
         awsResigner: AWSResigner,
         traceStore: TraceStore,
         clientIdentities: ClientIdentityRegistry,
         clusterCAs: ClusterCATrustRegistry,
         consent: ConsentBroker,
         guardrailsBroker: GuardrailsConsentBroker,
         supplyChainBroker: SupplyChainConsentBroker,
         osvClient: OSVClient,
         socketClient: SocketDevClient,
         publishTimeCache: PublishTimeCache,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         guardrailsProvider: @escaping @Sendable () -> GuardrailsConfig?,
         supplyChainProvider: @escaping @Sendable () -> SupplyChainPolicy?)
    {
        self.profileID = profileID
        self.httpDelegate = HTTPListenerDelegate(
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            awsResigner: awsResigner,
            traceStore: traceStore,
            clientIdentities: clientIdentities,
            clusterCAs: clusterCAs,
            consent: consent,
            guardrailsBroker: guardrailsBroker,
            supplyChainBroker: supplyChainBroker,
            osvClient: osvClient,
            socketClient: socketClient,
            publishTimeCache: publishTimeCache,
            sessionTraceProvider: sessionTraceProvider,
            guardrailsProvider: guardrailsProvider,
            supplyChainProvider: supplyChainProvider)
        self.sshDelegate = SSHListenerDelegate(
            profileID: profileID, sshAgent: sshAgent)
        self.awsDelegate = AWSCredsListenerDelegate(
            profileID: profileID, awsCreds: awsCreds)
        self.inferenceDelegate = InferenceListenerDelegate()

        self.httpListener = VZVirtioSocketListener()
        self.httpListener.delegate = httpDelegate

        self.sshListener = VZVirtioSocketListener()
        self.sshListener.delegate = sshDelegate

        self.awsListener = VZVirtioSocketListener()
        self.awsListener.delegate = awsDelegate

        self.inferenceListener = VZVirtioSocketListener()
        self.inferenceListener.delegate = inferenceDelegate
    }
}

private final class HTTPListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let profileID: UUID
    let certCache: CertCache
    let swapper: TokenSwapper
    let awsResigner: AWSResigner
    let traceStore: TraceStore
    let clientIdentities: ClientIdentityRegistry
    let clusterCAs: ClusterCATrustRegistry
    let consent: ConsentBroker
    let guardrailsBroker: GuardrailsConsentBroker
    let supplyChainBroker: SupplyChainConsentBroker
    let osvClient: OSVClient
    let socketClient: SocketDevClient
    let publishTimeCache: PublishTimeCache
    let sessionTraceProvider: @Sendable () -> MitmEngine.SessionTrace?
    let guardrailsProvider: @Sendable () -> GuardrailsConfig?
    let supplyChainProvider: @Sendable () -> SupplyChainPolicy?

    init(profileID: UUID, certCache: CertCache, swapper: TokenSwapper,
         awsResigner: AWSResigner,
         traceStore: TraceStore,
         clientIdentities: ClientIdentityRegistry,
         clusterCAs: ClusterCATrustRegistry,
         consent: ConsentBroker,
         guardrailsBroker: GuardrailsConsentBroker,
         supplyChainBroker: SupplyChainConsentBroker,
         osvClient: OSVClient,
         socketClient: SocketDevClient,
         publishTimeCache: PublishTimeCache,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         guardrailsProvider: @escaping @Sendable () -> GuardrailsConfig?,
         supplyChainProvider: @escaping @Sendable () -> SupplyChainPolicy?) {
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
        self.awsResigner = awsResigner
        self.traceStore = traceStore
        self.clientIdentities = clientIdentities
        self.clusterCAs = clusterCAs
        self.consent = consent
        self.guardrailsBroker = guardrailsBroker
        self.supplyChainBroker = supplyChainBroker
        self.osvClient = osvClient
        self.socketClient = socketClient
        self.publishTimeCache = publishTimeCache
        self.sessionTraceProvider = sessionTraceProvider
        self.guardrailsProvider = guardrailsProvider
        self.supplyChainProvider = supplyChainProvider
    }

    @available(macOS, deprecated: 10.15)
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let providerCopy = sessionTraceProvider
        let guardrailsCopy = guardrailsProvider
        let supplyChainCopy = supplyChainProvider
        let conn = HTTPMitmConnection(
            fd: fd,
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            awsResigner: awsResigner,
            traceStore: traceStore,
            clientIdentities: clientIdentities,
            clusterCAs: clusterCAs,
            consent: consent,
            guardrailsBroker: guardrailsBroker,
            supplyChainBroker: supplyChainBroker,
            osvClient: osvClient,
            socketClient: socketClient,
            publishTimeCache: publishTimeCache,
            sessionTraceProvider: providerCopy,
            guardrailsProvider: guardrailsCopy,
            supplyChainProvider: supplyChainCopy
        )
        Task.detached(priority: .userInitiated) {
            await conn.run()
        }
        return true
    }
}

private final class SSHListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let profileID: UUID
    let sshAgent: SSHAgentServer

    init(profileID: UUID, sshAgent: SSHAgentServer) {
        self.profileID = profileID
        self.sshAgent = sshAgent
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let pid = profileID
        let agent = sshAgent
        Task.detached(priority: .userInitiated) {
            await agent.serve(fd: fd, profileID: pid)
        }
        return true
    }
}

private final class AWSCredsListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let profileID: UUID
    let awsCreds: AWSCredentialServer

    init(profileID: UUID, awsCreds: AWSCredentialServer) {
        self.profileID = profileID
        self.awsCreds = awsCreds
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let pid = profileID
        let server = awsCreds
        Task.detached(priority: .userInitiated) {
            await server.serve(fd: fd, profileID: pid)
        }
        return true
    }
}
