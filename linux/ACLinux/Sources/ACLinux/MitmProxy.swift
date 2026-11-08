import Crypto
import Foundation
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
/// prompt injection and PII protection (its reply restored by PIIRelay).
// partial: no supply-chain policy on Linux yet, nor PII on WebSocket turns
// @port-skip linux-only: macOS's MitmEngine runs HTTPMitmConnection (SecureTransport) per VZ vsock connection
final class MitmProxy: @unchecked Sendable {
    static let vsockPort: UInt32 = 8443
    /// A request body is held in memory up to this (macOS spools to disk).
    static let maxBody = 256 << 20

    let ca: BromureCA
    let caNIO: NIOSSLCertificate
    let swapper: TokenSwapper
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
    /// Each workspace's guardrails and egress policy (macOS: MitmEngine's
    /// guardrailsConfigs), read per connection and per request
    /// (MitmEgress.swift).
    let guardrailsConfigs = NIOLockedValueBox<[UUID: GuardrailsConfig]>([:])
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
    /// Tests: every upstream connection goes here instead (SNI kept), trusting `extraRoots`.
    var routeAllTo: (host: String, port: Int)?
    /// An e2e run (BROMURE_AC_E2E=1): every upstream goes to the test
    /// upstream (`routeAllTo`) or is refused, never dialed; a splice goes to
    /// the test host only. Its guests' requests (and the credentials swapped
    /// into them) must reach only the local stand-in, so a build that lost
    /// the test route (a release build has none), or a route that doesn't
    /// parse, fails closed instead of falling back to the real hosts.
    var refusesRealUpstreams = false
    /// A multi-user server: the host's own addresses are refused too
    /// (ProxyDestination.swift), as the switch refuses them.
    var blocksHostAddresses = false

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
        awsResigner = AWSResigner(credServer: awsCreds)
        kubeTrust = KubeUpstreamTrust(extraRoots: extraRoots)
        claudeStore = ClaudeSubscriptionStore()
        claudeRefresher = ClaudeSubscriptionRefresher(store: claudeStore)
        codexStore = CodexSubscriptionStore()
        codexRefresher = CodexSubscriptionRefresher(store: codexStore)
        grokStore = GrokSubscriptionStore()
        grokRefresher = GrokSubscriptionRefresher(store: grokStore)
        kimiStore = KimiSubscriptionStore()
        kimiRefresher = KimiSubscriptionRefresher(store: kimiStore)
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
    // @port MitmEngine.clearPromptInjectionPolicy(for: UUID) h=b926618e76eae15c @8e2543eb
    func clearPromptInjectionPolicy(for profileID: UUID) {
        promptInjectionPolicies.withLockedValue { $0[profileID] = nil }
    }

    /// One request's trace record (macOS: HTTPMitmConnection.emitTrace),
    /// off the event loop. A parsed conversation gets the prompt-injection
    /// log scan when the workspace's policy is on with "log but continue"
    /// (ask and block run before the request is forwarded: not on Linux yet).
    // partial: log mode only (ask and block, which run before the request is forwarded, aren't on Linux yet)

    // @port HTTPMitmConnection.emitTrace(host: String, port: Int, preSwapRequest: Data, upstreamResponse: Data, upstreamWireBytes: Int, responseTruncated: Bool, swaps: [SwapRecord], leaks: [LeakEntry], latencyMs: Double, servedBy: String?) h=22ed0216edbd064f @cb7cdd6a
    func emitTrace(_ t: RequestReader.Trace, response: Data, wireBytes: Int, truncated: Bool) {
        guard let store = traces.withLockedValue({ $0 }) else { return }
        let latency = Date().timeIntervalSince(t.start) * 1000
        Task {
            await TraceEmitter.emit(
                session: t.session, store: store, profileID: t.profileID, host: t.host, port: t.port,
                preSwapRequest: t.request, upstreamResponse: response, upstreamWireBytes: wireBytes,
                responseTruncated: truncated, swaps: t.swaps, leaks: t.leaks, latencyMs: latency,
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

    /// Where a request to `host:port` goes: the local-inference sentinel
    /// (`bromure.llm`, what agents on a local model call) to the repair proxy
    /// on loopback, in clear (it fronts the workspace's external engine);
    /// anything else as asked.
    // partial: the sentinel only (no Local/Hybrid rerouting of real cloud hosts on Linux yet)
    // @port LLMRouting.static decide(host: String, port: Int, context: LLMRoutingContext, sessionKey: String, localHost: String, localPort: Int, now: Double) h=35267377ff44b00e @d85ba771
    static func route(host: String, port: Int, tls: Bool) -> (host: String, port: Int, tls: Bool, local: Bool) {
        guard host.lowercased() == InferenceService.localMitmHost else { return (host, port, tls, false) }
        return (InferenceService.engineHost, InferenceService.repairProxyPort, false, true)
    }

    /// Connects to `host:port` (TLS, when `tls`) on `loop`; the channel is
    /// ready to write when the future holds. The server certificate is
    /// verified against the system roots, or only against the cluster CA
    /// `profileID`'s kubeconfig pins for that endpoint, which may also give
    /// the client certificate presented.
    // @port-skip linux-only: NIO upstream (macOS: URLSession / NWConnection)
    func connectUpstream(host: String, port: Int, tls requestedTLS: Bool, profileID: UUID? = nil,
                         pinned: [IPAddress]? = nil, on loop: EventLoop) -> EventLoopFuture<Channel> {
        let routed = Self.route(host: host, port: port, tls: requestedTLS)
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
        let ctx = profileID.flatMap { kubeTrust.endpoint(for: host, port: port, profileID: $0) }?.context
            ?? upstreamContext
        // Only to the addresses that passed the check, in order: the name is
        // never looked up again (a rebinding answer can't slip in between).
        // One destination check per connection, the workspace's (its OpenShell
        // route's address authorization too): a CONNECT's, made before the
        // tunnel was confirmed, or made here (plain HTTP, transparent).
        // Either way the dial uses exactly the addresses it passed.
        let checked = pinned.map { loop.makeSucceededFuture($0) }
            ?? checkDestination(host: host, port: port, profileID: profileID, on: loop)
        return checked.flatMap { [self] resolved in
            if let r = routeAllTo, let to = try? SocketAddress.makeAddressResolvingHost(r.host, port: r.port) {
                return dial(host: host, to: [to], tls: routed.tls, ctx: ctx, on: loop)
            }
            if refusesRealUpstreams {
                FileHandle.standardError.write(Data("[mitm] ✗ e2e mode: the test upstream isn't usable: refused \(host):\(port)\n".utf8))
                return loop.makeFailedFuture(ProxyDestinationDenied(
                    host: host, port: port, reason: "e2e mode: the test upstream isn't usable, so no real host is dialed"))
            }
            let addrs = resolved.compactMap { try? SocketAddress(ipAddress: "\($0)", port: port) }
            return dial(host: host, to: addrs, tls: routed.tls, ctx: ctx, on: loop)
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

    // @port-skip linux-only: NIO plumbing of the Linux proxy
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
                    buf.moveReaderIndex(forwardBy: nl - buf.readerIndex + 1)
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
                                                         host: host, port: port, route: "proxy") else {
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
                      let host = url.host else { return reject(context, 405, "Method Not Allowed") }
                let port = url.port ?? 80
                let policy = proxy.guardrailsConfig(for: profileID)?.egressPolicy
                if host.lowercased() != OpenShellAdvisor.host,
                   ProxyPolicy.egressVerdict(policy: policy, profileID: profileID, host: host, port: port,
                                             identity: nil) == .deny {
                    return answer(context, ProxyPolicy.connectDenied(policy: policy, profileID: profileID,
                                                                     host: host, port: port))
                }
                ProxyPolicy.reportAllowed(policy: policy, profileID: profileID, host: host, port: port)
                guard proxy.trackForFirewall(context.channel, profileID: profileID,
                                             host: host, port: port, route: "proxy") else {
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

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    static func split(_ target: String, defaultPort: Int) -> (String, Int) {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let h = String(target[target.index(after: target.startIndex)..<close])
            return (h, Int(target[target.index(after: close)...].dropFirst()) ?? defaultPort)
        }
        if let c = target.lastIndex(of: ":"), let p = Int(target[target.index(after: c)...]) {
            return (String(target[..<c]), p)
        }
        return (target, defaultPort)
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
    private var buf = ByteBuffer()
    private var started = false
    /// After the request went upstream: the guest's further bytes (a
    /// WebSocket's frames) go to the upstream channel, once its reply
    /// switched protocols (`upgraded`).
    private var upstream: Channel?
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
    /// The filter's say on reading the guest: false while it holds too much.
    private var filterWantsGuest = true
    static let maxHeld = 1 << 20

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool,
         pinned: [MitmProxy.IPAddress]? = nil) {
        self.proxy = proxy
        self.profileID = profileID
        self.host = host
        self.port = port
        self.tls = tls
        self.pinned = pinned
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if started {
            if upgraded, let upstream {
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
        switch HTTPRequestFraming.complete(Data(buf.readableBytesView)) {
        case .needMore:
            if buf.readableBytes > MitmProxy.maxBody { reply(context, Self.simple(413, "Payload Too Large")) }
        case .invalid:
            reply(context, Self.simple(400, "Bad Request"))
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
                                              session: session, trace: &trace)
                loop.execute { self.send(plan, trace: trace, channel: channel, host: host, port: port, tls: tls, session: session) }
            }
        }
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        wsFilter?.cancel()           // a scan, and an ask it's waiting on, dropped
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    enum Plan {
        case answer(Data)
        case forward(Data, SubscriptionAuthRewrite.Injected, capture: SignInCapture?, upgrade: Bool,
                     mint: CredentialMint.Kind? = nil, ws: WSPromptGuard? = nil, pii: PIIVault? = nil)
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
    }

    /// The request as it goes upstream, or the host's own answer, in
    /// macOS's order: the subscription swaps (5c–5e), the token map's, then
    /// the 5f sign-in capture on what would go out.
    // @port-skip linux-only: the swap order of HTTPMitmConnection.driveTLS (5c–5f, then TokenSwapper)
    static func rewrite(_ raw: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int, tls: Bool,
                        session: UInt64, trace: inout Trace?) async -> Plan {
        var req = origin(raw)
        if let answer = await policyAnswer(&req, proxy: proxy, profileID: profileID, host: host, port: port, tls: tls,
                                           session: session) {
            return .answer(answer)
        }
        let head = SubscriptionAuthRewrite.rawHeaderSection(of: req) ?? ""
        let line = head.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        let method = line.first.map(String.init) ?? ""
        let path = line.count > 1 ? String(line[1]) : "/"
        var upgrade = SubscriptionAuthRewrite.headerValue("upgrade", inHeaderSection: head) != nil
        // Only a WebSocket upgrade is offered: another protocol (h2c above
        // all) would carry every later request past the per-request policy.
        // Every other token goes, across every Upgrade header; none left, and
        // the request is served as plain HTTP/1.1.
        if upgrade {
            switch ResponseRelay.websocketOnly(head) {
            case .some(true):
                req = HTTPRequestFraming.replacingHeaders(req, drop: ["upgrade", "http2-settings"], add: "Upgrade: websocket")
            case .some(false):
                req = HTTPRequestFraming.replacingHeaders(req, drop: ["upgrade", "http2-settings", "connection"], add: "Connection: close")
                upgrade = false
            case .none: break
            }
        }
        var injected = SubscriptionAuthRewrite.Injected()
        // Pre-swap: unswapped Bearer / x-api-key tokens, for the trace
        // (our own stand-ins aren't leaks).
        if trace != nil {
            trace?.leaks = SubscriptionAuthRewrite.filterStandInLeaks(
                proxy.swapper.detectLeaks(in: req, profileID: profileID), request: req, host: host, profileID: profileID)
        }
        if tls {
            switch await SubscriptionAuthRewrite.apply(rawRequest: req, host: host, method: method, path: path,
                                                       profileID: profileID, spooledBody: false) {
            case .answer(let reply): return .answer(reply)
            case .forward(let r, let i): req = r; injected = i
            }
        }
        let swapped = await proxy.swapper.swap(rawRequest: req, host: host, port: port, profileID: profileID)
        req = swapped.modified
        trace?.swaps = swapped.swaps
        // Prompt injection, ask or block, before the model sees a byte
        // (macOS: driveTLS's enforcement after the swaps; log mode stays in
        // the trace's conversation hook).
        if let answer = await promptInjectionAnswer(&req, proxy: proxy, profileID: profileID, host: host, path: path,
                                                    trace: &trace) {
            return .answer(answer)
        }
        // PII protection: stand-ins for personal data before it leaves; the
        // relay restores the reply (macOS: driveTLS's PII step).
        let pii = await piiSwap(&req, proxy: proxy, profileID: profileID, host: host, method: method, path: path)
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
        case .deny(let action)?:
            FileHandle.standardError.write(Data("[mitm] refused \(action) on \(host): issues an unswappable credential\n".utf8))
            return .answer(CredentialMint.denial(action))
        case .mint(let kind)?:
            mint = kind
            req = Self.readWhole(req)
            upgrade = false
        case nil:
            break
        }
        // 5f. A sign-in this workspace runs: its token exchange is the host's.
        var capture: SignInCapture?
        // This proxy's own captures (macOS reads them through the provider,
        // which answers for the one engine; here the proxy is at hand).
        if tls, let c = proxy.captures.capture(for: profileID),
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
        // A model provider's WebSocket with prompt injection on: its frames are
        // read (WSClientFilter), so the upgrade declines permessage-deflate
        // and both legs carry plain frames (macOS: WSHandshake, then
        // WSTransformRelay). Otherwise the socket stays an opaque pipe.
        var ws: WSPromptGuard?
        if upgrade, let g = WSPromptGuard.make(proxy: proxy, profileID: profileID, host: host) {
            ws = g
            req = WSHandshake.strippingExtensions(req).request
        }
        var out = upgrade ? req : closing(req)
        // An AWS request (SigV4 with the guest's fake keys) re-signed with the
        // real ones, last, over the headers as they go out; a use the user
        // refused is answered here (macOS: driveTLS's AWSResigner step).
        switch await proxy.awsResigner.resign(rawRequest: out, host: host, profileID: profileID) {
        case .unchanged: break
        case .resigned(let bytes): out = framedLikeURLSession(bytes, host: host)
        case .denied(let response): return .answer(response)
        case .failed(let reason, let response):
            FileHandle.standardError.write(Data("[mitm] AWS resign failed for \(host): \(reason)\n".utf8))
            return .answer(response)
        }
        return .forward(out, injected, capture: capture, upgrade: upgrade, mint: mint, ws: ws, pii: pii.vault)
    }

    /// The guest drained: the upstream may be read again (ResponseRelay
    /// paused it while the guest was full).
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { _ = upstream?.setOption(ChannelOptions.autoRead, value: true) }
        context.fireChannelWritabilityChanged()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    private func send(_ plan: Plan, trace: Trace?, channel: Channel, host: String, port: Int, tls: Bool, session: UInt64) {
        switch plan {
        case .answer(let reply):
            write(reply, to: channel, close: true)
            if let trace { proxy.emitTrace(trace, response: reply, wireBytes: reply.count, truncated: false) }
        case .forward(let req, let injected, let capture, let upgrade, let mint, let ws, let pii):
            proxy.connectUpstream(host: host, port: port, tls: tls, profileID: profileID, pinned: pinned,
                                  on: channel.eventLoop).whenComplete { r in
                switch r {
                case .failure(let e):
                    let reply = (e as? ProxyDestinationDenied).map {
                        MitmProxy.destinationDeniedResponse(host: $0.host, port: $0.port, reason: $0.reason)
                    } ?? MitmProxy.upstreamErrorResponse(e, host: host)
                    self.write(reply, to: channel, close: true)
                    if let trace { self.proxy.emitTrace(trace, response: reply, wireBytes: reply.count, truncated: false) }
                case .success(let up):
                    let relay = ResponseRelay(guest: channel, profileID: self.profileID, injected: injected,
                                              capture: capture, upgrade: upgrade, proxy: self.proxy, trace: trace, host: host,
                                              mint: mint.map { (self.proxy.credentialMinter, $0) }, strictSession: session,
                                              ws: ws, pii: pii,
                                              // An HTTP/1.0 guest gets a restored body up to the close, not chunks.
                                              guestHTTP11: !Self.isHTTP10(req))
                    relay.onUpstreamWritable = { self.readGuestIfAllowed(channel) }
                    // The upgrade's held bytes follow the 101; anything else's are dropped.
                    relay.onSwitched = { switched, server in
                        channel.eventLoop.execute {
                            self.awaitingUpgrade = false
                            if switched {
                                self.upgraded = true
                                if let ws, let server {
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
                        self.upstream = up
                        self.awaitingUpgrade = upgrade
                        up.writeAndFlush(up.allocator.buffer(bytes: req), promise: nil)
                        if !upgrade {
                            self.pending.removeAll()
                            self.pendingBytes = 0
                        }
                    }
                }
            }
        }
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
    /// The upstream drained: the guest may be read again, if nothing else
    /// holds it (RequestReader.readGuestIfAllowed).
    var onUpstreamWritable: (() -> Void)?
    /// The upgrade's prompt-injection guard (nil: an opaque pipe).
    private let ws: WSPromptGuard?
    private var wsServer: WSServerSide?
    /// The reply PII protection restores (its stand-ins put back), if any.
    private let pii: PIIRelay?
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
         ws: WSPromptGuard? = nil, pii: PIIVault? = nil, guestHTTP11: Bool = true) {
        self.guest = guest
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

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        if capture != nil || mint != nil {
            if whole.count + b.readableBytes > Self.wholeCap {
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
            keepForLearning(b.readableBytesView)
            relayed = true
            if let wsServer {
                // As it comes; a refused turn's event between two messages.
                guard let out = wsServer.feed(Data(b.readableBytesView)) else { context.close(promise: nil); return }
                if !out.isEmpty { guest.write(guest.allocator.buffer(bytes: out), promise: nil) }
            } else {
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
        headDone = true
        learning = !(upgrade && Self.status(head0) == 101)
        let out: Data
        if upgrade, Self.status(head0) == 101 {
            // Switched: the head as it is, then the stream both ways.
            noteStatus(head0)
            var early = rest
            if let ws {
                if let ext = WSHandshake.extensions(inResponse: head0) {
                    // An extension in use anyway (one it wasn't offered): frames
                    // that can't be read, so the opaque pipe, and said so
                    // (macOS: driveTLS's fallback to the pump).
                    ProxyPolicy.recordScanSkipped(host: ws.host, path: "", engines: ["prompt_injection"],
                                                  reason: "WebSocket extension \(ext) in use", profileID: ws.profileID)
                } else {
                    let guest = self.guest
                    let server = WSServerSide(loop: context.eventLoop,
                                              write: { guest.writeAndFlush(guest.allocator.buffer(bytes: $0), promise: nil) })
                    wsServer = server
                    guard let read = server.feed(rest) else { context.close(promise: nil); return }
                    early = read
                }
            }
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
        holdIfGuestFull(context)
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

    /// An upgrade request's tokens over every Upgrade header: nil when the
    /// only one is `websocket` (nothing to change), true when websocket is
    /// among others (the others go), false when it isn't there at all.
    // @port-skip linux-only: the Linux proxy's upgrade policy
    static func websocketOnly(_ head: String) -> Bool? {
        let tokens = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> [String]? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" else { return nil }
            return line[line.index(after: colon)...].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        }.flatMap { $0 }
        let ws = tokens.filter { $0 == "websocket" || $0.hasPrefix("websocket/") }
        if ws.isEmpty { return false }
        return ws.count == tokens.count ? nil : true
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
                // poll or an error isn't a 200, and passes through.)
                let reply: Data
                if let kept {
                    reply = kept
                } else if status == 200 {
                    reply = SignInCapture.notKeptReply
                } else {
                    reply = raw
                }
                FileHandle.standardError.write(Data(
                    "[mitm] sign-in exchange → \(status), \(kept != nil ? "kept on the host" : status == 200 ? "NOT kept\(encoded ? " (encoded reply)" : ""): refused to the guest" : "passed through")\n".utf8))
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
            let reply = MitmProxy.upstreamErrorResponse(failure ?? ChannelError.eof, host: host)
            if let proxy, let trace { proxy.emitTrace(trace, response: reply, wireBytes: 0, truncated: false) }
            guest.writeAndFlush(guest.allocator.buffer(bytes: reply)).whenComplete { _ in self.guest.close(promise: nil) }
            return
        }
        // A restored body read up to the close: what's held, and the last chunk.
        if let pii, pii.restoring, !pii.ended {
            let tail = pii.finish()
            keepForTrace(tail)
            guest.write(guest.allocator.buffer(bytes: tail), promise: nil)
        }
        if let proxy, let trace {
            proxy.emitTrace(trace, response: traceTruncated ? traceCopy : HTTPRequestFraming.dechunkedResponse(traceCopy),
                            wireBytes: traceWire, truncated: traceTruncated)
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
