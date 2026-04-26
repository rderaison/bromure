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
    public let traceStore: TraceStore

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

    /// Per-VM listener delegates kept alive so they aren't GC'd while
    /// the VM is running. Keyed by profile UUID.
    private var listenerHolders: [UUID: ListenerHolder] = [:]

    /// Our spawned ssh-agent. Owns the per-profile bromure keys
    /// (loaded via `ssh-add` at session launch) and is the back-end
    /// for the in-VM agent multiplex.
    public let privateAgent: PrivateSSHAgent

    public init() throws {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BromureAC", isDirectory: true)
        let caDir = supportDir.appendingPathComponent("ca", isDirectory: true)
        self.ca = try BromureCA.loadOrCreate(at: caDir)
        self.certCache = CertCache(ca: ca)
        self.swapper = TokenSwapper()
        self.sshAgent = SSHAgentServer()
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
        let holder = ListenerHolder(
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            sshAgent: sshAgent,
            traceStore: traceStore,
            // The provider runs from a detached Task on the proxy's
            // hot path. `sessionTrace(for:)` is now nonisolated +
            // lock-protected so this is just a hash lookup behind a
            // mutex — no actor hop required.
            sessionTraceProvider: { [weak self] in
                self?.sessionTrace(for: profileID)
            }
        )
        socketDevice.setSocketListener(holder.httpListener,
                                       forPort: Self.httpsVsockPort)
        socketDevice.setSocketListener(holder.sshListener,
                                       forPort: Self.sshAgentVsockPort)
        listenerHolders[profileID] = holder
    }

    public func unregister(profileID: UUID) {
        listenerHolders.removeValue(forKey: profileID)
        swapper.clearMap(for: profileID)
        sshAgent.clearKeys(for: profileID)
    }
}

/// Holds the listener delegates for a single VM. Owning the
/// delegates outside of the VM keeps them alive across the
/// connection lifetime.
private final class ListenerHolder {
    let profileID: UUID
    let httpDelegate: HTTPListenerDelegate
    let sshDelegate: SSHListenerDelegate
    let httpListener: VZVirtioSocketListener
    let sshListener: VZVirtioSocketListener

    init(profileID: UUID,
         certCache: CertCache,
         swapper: TokenSwapper,
         sshAgent: SSHAgentServer,
         traceStore: TraceStore,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?)
    {
        self.profileID = profileID
        self.httpDelegate = HTTPListenerDelegate(
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            traceStore: traceStore,
            sessionTraceProvider: sessionTraceProvider)
        self.sshDelegate = SSHListenerDelegate(
            profileID: profileID, sshAgent: sshAgent)

        self.httpListener = VZVirtioSocketListener()
        self.httpListener.delegate = httpDelegate

        self.sshListener = VZVirtioSocketListener()
        self.sshListener.delegate = sshDelegate
    }
}

private final class HTTPListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let profileID: UUID
    let certCache: CertCache
    let swapper: TokenSwapper
    let traceStore: TraceStore
    let sessionTraceProvider: @Sendable () -> MitmEngine.SessionTrace?

    init(profileID: UUID, certCache: CertCache, swapper: TokenSwapper,
         traceStore: TraceStore,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?) {
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
        self.traceStore = traceStore
        self.sessionTraceProvider = sessionTraceProvider
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let providerCopy = sessionTraceProvider
        let conn = HTTPMitmConnection(
            fd: fd,
            profileID: profileID,
            certCache: certCache,
            swapper: swapper,
            traceStore: traceStore,
            sessionTraceProvider: providerCopy
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
            agent.serve(fd: fd, profileID: pid)
        }
        return true
    }
}
