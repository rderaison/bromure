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
    public let sshAgent: SSHAgentServer
    public let awsCreds: AWSCredentialServer
    /// Strips the (intentionally invalid) signature on AWS-bound
    /// requests and re-signs with material that lives only on the host.
    /// See `AWSResigner` for the threat model.
    public let awsResigner: AWSResigner
    public let consent: ConsentBroker
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

    /// Per-VM listener delegates kept alive so they aren't GC'd while
    /// the VM is running. Keyed by profile UUID.
    private var listenerHolders: [UUID: ListenerHolder] = [:]

    /// Set once by the host wiring code. Fires when the proxy sees a
    /// clean Anthropic OAuth access token outbound — the receiver is
    /// expected to throttle and present the consent sheet.
    public var subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)?
    /// Codex / ChatGPT counterpart of `subscriptionTokenSeen`.
    public var codexTokenSeen: (@Sendable (UUID, String) -> Void)?
    /// Fires whenever an OAuth refresh response is rewritten and we
    /// have fresh real tokens. Receiver is expected to update any
    /// host-side default-token storage (`Profile.default*Tokens` and
    /// optionally the preferences template) so future sessions /
    /// profiles auto-seed against the rotated values.
    public var oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)?

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
        self.swapper = TokenSwapper(consent: broker)
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
        let tokenHook = self.subscriptionTokenSeen
        let codexHook = self.codexTokenSeen
        let rotatedHook = self.oauthRotated
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
            // The provider runs from a detached Task on the proxy's
            // hot path. `sessionTrace(for:)` is now nonisolated +
            // lock-protected so this is just a hash lookup behind a
            // mutex — no actor hop required.
            sessionTraceProvider: { [weak self] in
                self?.sessionTrace(for: profileID)
            },
            subscriptionTokenSeen: tokenHook,
            codexTokenSeen: codexHook,
            oauthRotated: rotatedHook
        )
        socketDevice.setSocketListener(holder.httpListener,
                                       forPort: Self.httpsVsockPort)
        socketDevice.setSocketListener(holder.sshListener,
                                       forPort: Self.sshAgentVsockPort)
        socketDevice.setSocketListener(holder.awsListener,
                                       forPort: Self.awsCredsVsockPort)
        listenerHolders[profileID] = holder
    }

    public func unregister(profileID: UUID) {
        listenerHolders.removeValue(forKey: profileID)
        swapper.clearMap(for: profileID)
        sshAgent.clearKeys(for: profileID)
        sshAgent.clearImportedKeyApprovals(for: profileID)
        awsCreds.clearCredentials(for: profileID)
        clientIdentities.clearAll(for: profileID)
        clusterCAs.clearAll(for: profileID)
        execPoller.stopAll()
        // Drop any consent grants the user issued during this session
        // — "Allow for the rest of the session" must not survive a
        // window close. Detached so we don't block the @MainActor
        // teardown path on the actor hop.
        let broker = consent
        Task.detached { await broker.revokeAll(profileID: profileID) }
        Task.detached { await broker.clearProfileName(for: profileID) }
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
    let httpListener: VZVirtioSocketListener
    let sshListener: VZVirtioSocketListener
    let awsListener: VZVirtioSocketListener

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
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)?,
         codexTokenSeen: (@Sendable (UUID, String) -> Void)?,
         oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)?)
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
            sessionTraceProvider: sessionTraceProvider,
            subscriptionTokenSeen: subscriptionTokenSeen,
            codexTokenSeen: codexTokenSeen,
            oauthRotated: oauthRotated)
        self.sshDelegate = SSHListenerDelegate(
            profileID: profileID, sshAgent: sshAgent)
        self.awsDelegate = AWSCredsListenerDelegate(
            profileID: profileID, awsCreds: awsCreds)

        self.httpListener = VZVirtioSocketListener()
        self.httpListener.delegate = httpDelegate

        self.sshListener = VZVirtioSocketListener()
        self.sshListener.delegate = sshDelegate

        self.awsListener = VZVirtioSocketListener()
        self.awsListener.delegate = awsDelegate
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
    let sessionTraceProvider: @Sendable () -> MitmEngine.SessionTrace?
    let subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)?
    let codexTokenSeen: (@Sendable (UUID, String) -> Void)?
    let oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)?

    init(profileID: UUID, certCache: CertCache, swapper: TokenSwapper,
         awsResigner: AWSResigner,
         traceStore: TraceStore,
         clientIdentities: ClientIdentityRegistry,
         clusterCAs: ClusterCATrustRegistry,
         consent: ConsentBroker,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)?,
         codexTokenSeen: (@Sendable (UUID, String) -> Void)?,
         oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)?) {
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
        self.awsResigner = awsResigner
        self.traceStore = traceStore
        self.clientIdentities = clientIdentities
        self.clusterCAs = clusterCAs
        self.consent = consent
        self.sessionTraceProvider = sessionTraceProvider
        self.subscriptionTokenSeen = subscriptionTokenSeen
        self.codexTokenSeen = codexTokenSeen
        self.oauthRotated = oauthRotated
    }

    @available(macOS, deprecated: 10.15)
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let providerCopy = sessionTraceProvider
        let tokenHook = subscriptionTokenSeen
        let codexHook = codexTokenSeen
        let rotatedHook = oauthRotated
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
            sessionTraceProvider: providerCopy,
            subscriptionTokenSeen: tokenHook,
            codexTokenSeen: codexHook,
            oauthRotated: rotatedHook
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
