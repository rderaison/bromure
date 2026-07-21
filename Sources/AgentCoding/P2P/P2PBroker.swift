import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Per-connection signaling session

/// One in-flight connection attempt (one grant / connectionId). Owns the
/// strictly-increasing outgoing `seq` the gateway enforces, and accumulates the
/// peer's advertised candidates. Thread-safe: `receive` is called from the
/// device-channel's main-queue callback while establishment polls `candidates`
/// from a background thread.
final class P2PSession: @unchecked Sendable {
    enum Role { case dialer, listener }
    let grant: ConnectionGrant
    let role: Role

    private let lock = NSLock()
    private var outSeq = 0
    private var received: [P2PCandidate] = []
    private var sawPeerFrame = false

    init(grant: ConnectionGrant, role: Role) {
        self.grant = grant
        self.role = role
    }

    private func nextSeq() -> Int { lock.lock(); defer { lock.unlock() }; outSeq += 1; return outSeq }

    var candidates: [P2PCandidate] { lock.lock(); defer { lock.unlock() }; return received }
    var gotPeerFrame: Bool { lock.lock(); defer { lock.unlock() }; return sawPeerFrame }

    /// A relayed frame from the peer arrived (routed by the broker).
    func receive(kind: SignalKind, payload: P2PSignalPayload) {
        let incoming = payload.allCandidates
        lock.lock()
        sawPeerFrame = true
        for c in incoming where !received.contains(c) { received.append(c) }
        lock.unlock()
    }

    /// Send one frame over the shared device channel with the next seq.
    func send(_ kind: SignalKind, payload: P2PSignalPayload, via channel: DeviceChannel) async throws {
        let frame = OutgoingSignalFrame(connectionId: grant.id, seq: nextSeq(), kind: kind, payload: payload)
        try await channel.send(frame)
    }
}

// MARK: - Loopback shim

/// Presents a stable `127.0.0.1:port` on the dialer and, per accepted
/// connection (one per SSH ControlMaster / stream), opens a fresh transport
/// connection to the winning candidate and byte-pumps the two together. The
/// endpoint is always loopback so nothing above SSH learns which rung won
/// (REMOTE_P2P_PLAN.md §"The broker's loopback-shim interface").
final class P2PLoopbackShim: @unchecked Sendable {
    let port: Int
    let winner: P2PCandidate
    private let lfd: Int32
    private var stopped = false
    private let lock = NSLock()

    init?(winner: P2PCandidate) {
        let (fd, port) = FatForward.listenEphemeral(bindAll: false)   // loopback only
        guard fd >= 0 else { return nil }
        self.lfd = fd
        self.port = port
        self.winner = winner
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let cfd = Darwin.accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }   // lfd closed → stop
            let w = winner
            Thread.detachNewThread {
                guard let rfd = P2PTCP.connect(ip: w.ip, port: w.port, timeout: 5) else {
                    Darwin.close(cfd); return
                }
                FatForward.splice(cfd, rfd)
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        Darwin.close(lfd)
    }
}

// MARK: - The broker

/// The app-facing P2P engine: one per instance, lifecycle-managed like the
/// existing `ssh`/`cloudflared` helpers. Holds the device identity + the single
/// outbound device channel, serves inbound connection offers (listener role),
/// and resolves a peer device id to a live loopback endpoint the existing SSH
/// stack dials unchanged (dialer role).
///
/// Not `@MainActor`: the SSH dial path runs on background queues and resolves
/// peers synchronously, so the broker guards its own state with a lock (like
/// `SSHTunnel`) rather than hopping to the main actor.
final class P2PBroker: @unchecked Sendable {
    static let shared = P2PBroker()

    private let lock = NSLock()
    private var channel: DeviceChannel?
    private var channelToken: String?
    private var sessions: [String: P2PSession] = [:]
    private var liveShims: [String: (shim: P2PLoopbackShim, path: P2PPath)] = [:]
    private var serving = false
    private var serveSSHPort = 2222

    // MARK: Identity

    /// Enrolled = has a usable control-plane identity from EITHER a browser P2P
    /// enrollment or the existing enterprise/managed enrollment.
    var isEnrolled: Bool { P2PIdentity.current() != nil }
    func currentIdentity() -> P2PIdentity? { P2PIdentity.current() }

    private func makeClient(_ id: P2PIdentity) -> ControlPlaneClient? {
        guard let ep = try? ControlPlaneEndpoint(base: id.apiBase) else { return nil }
        return ControlPlaneClient(endpoint: ep)
    }

    /// Report a session's path/quality summary — but ONLY for organization
    /// workspaces. A personal (individual) account never records a session:
    /// the `POST /v1/connections/:id/complete` telemetry is simply not sent, so
    /// no outcome/path/timing ever reaches the cloud. The grant then closes on
    /// its own 45 s TTL instead of being closed early by the report.
    private func reportComplete(_ client: ControlPlaneClient, _ id: P2PIdentity,
                                connectionId: String, report: ConnectionReport) async {
        guard id.recordsSessionTelemetry else {
            FatClientLog.log("p2p: personal account — session telemetry suppressed for \(connectionId)")
            return
        }
        _ = try? await client.complete(bearer: id.bearer, connectionId: connectionId, report: report)
    }

    /// The sshd port to advertise, from the same UserDefaults key the remote-
    /// access front door uses (default 2222). Read directly so callers without
    /// a `RemoteAccessServer.Config` in hand (the enroll UI) stay consistent.
    static func configuredSSHPort() -> Int {
        let p = UserDefaults.standard.integer(forKey: "remoteAccess.port")
        return p > 0 ? p : 2222
    }

    /// Whether the SSH front door is enabled — the P2P listener only makes sense
    /// when there's an sshd for candidates to reach.
    static var remoteAccessEnabled: Bool {
        UserDefaults.standard.bool(forKey: "remoteAccess.enabled")
    }

    // MARK: Shared device channel

    /// Return a connected device channel for the current identity, creating it
    /// on first use and wiring the routing callbacks. Blocks up to ~5s for the
    /// WebSocket to open. Returns nil if not enrolled or the channel won't open.
    private func ensureChannel(_ id: P2PIdentity) -> DeviceChannel? {
        lock.lock()
        if let ch = channel, channelToken == id.bearer {
            lock.unlock()
            return waitConnected(ch) ? ch : nil
        }
        // Bearer changed (re-enroll / different identity) or first use — rebuild.
        channel?.close()
        guard let ep = try? ControlPlaneEndpoint(base: id.apiBase) else { lock.unlock(); return nil }
        let ch = DeviceChannel(endpoint: ep, token: id.bearer)
        channel = ch
        channelToken = id.bearer
        lock.unlock()

        ch.onSignal = { [weak self] connId, _, kind, _, payload in
            self?.route(connectionId: connId, kind: kind, payload: payload)
        }
        ch.onConnectionOffered = { [weak self] grant in
            self?.handleOffered(grant)
        }
        ch.onError = { code, connId in
            FatClientLog.log("p2p: signaling error \(code) conn=\(connId ?? "-")")
        }
        ch.onRevoked = { [weak self] in
            // Only a browser-enrolled device record is ours to erase; the
            // enterprise identity is managed by BACEnrollment's own lifecycle.
            FatClientLog.log("p2p: device channel reported revoked")
            if case .found = DeviceIdentityStore.load() { DeviceIdentityStore.erase() }
            self?.stopServing()
        }
        ch.connect()
        return waitConnected(ch) ? ch : nil
    }

    private func waitConnected(_ ch: DeviceChannel, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ch.connected && Date() < deadline { usleep(50_000) }
        return ch.connected
    }

    private func route(connectionId: String, kind: SignalKind, payload: P2PSignalPayload) {
        lock.lock(); let s = sessions[connectionId]; lock.unlock()
        s?.receive(kind: kind, payload: payload)
    }

    // MARK: Listener role

    /// Become a reachable server: flip the control plane's `p2p_server` flag on
    /// and hold the device channel open so clients see us online. Call when
    /// Remote Access is enabled. No-op without a control-plane identity (a Mac
    /// with no bromure.io enrollment can still serve plain SSH, just not P2P).
    ///
    /// Independent of the client role — the same shared channel also carries
    /// this Mac's outbound dials, so one install is a server AND a client at
    /// once. Idempotent.
    func startServing(sshPort: Int) {
        guard let id = currentIdentity() else { return }
        lock.lock()
        serveSSHPort = sshPort
        if serving { lock.unlock(); return }
        serving = true
        lock.unlock()
        Task.detached { [weak self] in
            guard let self else { return }
            if let client = self.makeClient(id) {
                do { _ = try await client.setServerMode(bearer: id.bearer, enabled: true) }
                catch { FatClientLog.log("p2p: server-mode on failed: \(error)") }
            }
            _ = self.ensureChannel(id)   // registers presence
        }
    }

    /// Stop being a server: clear `p2p_server` and drop the channel. Outbound
    /// dials still work (they re-open the channel on demand).
    func stopServing() {
        lock.lock()
        let wasServing = serving
        serving = false
        let ch = channel
        channel = nil
        channelToken = nil
        sessions.removeAll()
        lock.unlock()
        ch?.close()
        if wasServing, let id = currentIdentity(), let client = makeClient(id) {
            Task.detached { _ = try? await client.setServerMode(bearer: id.bearer, enabled: false) }
        }
    }

    /// A client was granted a connection to us. Answer with our reachable
    /// candidates; for a same-LAN / globally-reachable path the dialer then
    /// connects straight to our embedded sshd (0.0.0.0:2222) — no splice needed
    /// on this side.
    private func handleOffered(_ grant: ConnectionGrant) {
        guard let id = currentIdentity(), let client = makeClient(id) else { return }
        let session = P2PSession(grant: grant, role: .listener)
        lock.lock(); sessions[grant.id] = session; let port = serveSSHPort; lock.unlock()
        guard let ch = channel else { return }

        let candidates = P2PCandidateGatherer.hostCandidates(sshPort: port)
        Task { [weak self] in
            let payload = P2PSignalPayload(candidates: Array(candidates.prefix(8)))
            try? await session.send(.answer, payload: payload, via: ch)
            // A completed grant closes signaling; the listener reports success
            // best-effort (first report wins — the dialer usually reports first).
            // Suppressed entirely for personal accounts.
            await self?.reportComplete(client, id, connectionId: grant.id,
                                       report: .connected(pathKind: .direct, timeToConnectedMs: 0))
            // Signaling is done; drop the session after a grace window for any
            // late dialer trickle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.lock.lock(); self?.sessions[grant.id] = nil; self?.lock.unlock()
        }
    }

    // MARK: Dialer role

    struct ResolvedEndpoint {
        let host: String       // always "127.0.0.1"
        let port: Int
        let path: P2PPath
        let peerDeviceID: String
    }

    /// Resolve a peer device id to a live loopback endpoint. Synchronous (the
    /// SSH dial path is synchronous and runs off-main). Caches the live shim so
    /// repeated dials of the same peer reuse one path. MUST NOT be called on the
    /// main thread — it blocks on network establishment.
    func endpoint(forPeer id: String, timeout: TimeInterval = 12) -> ResolvedEndpoint? {
        lock.lock()
        if let live = liveShims[id] {
            let ep = ResolvedEndpoint(host: "127.0.0.1", port: live.shim.port,
                                      path: live.path, peerDeviceID: id)
            lock.unlock()
            return ep
        }
        lock.unlock()

        let sem = DispatchSemaphore(value: 0)
        var result: ResolvedEndpoint?
        Task.detached { [weak self] in
            result = await self?.establish(peerDeviceID: id, timeout: timeout)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout + 3) == .timedOut { return nil }
        return result
    }

    /// Non-blocking cache lookup — a live path for `id` if one exists, else nil.
    /// Safe to call on the main thread (never establishes).
    func cachedEndpoint(forPeer id: String) -> ResolvedEndpoint? {
        lock.lock(); defer { lock.unlock() }
        guard let live = liveShims[id] else { return nil }
        return ResolvedEndpoint(host: "127.0.0.1", port: live.shim.port,
                                path: live.path, peerDeviceID: id)
    }

    /// Tear down a peer's path (call from the mirror controller's stop()).
    func closePeer(_ id: String) {
        lock.lock()
        let live = liveShims[id]
        liveShims[id] = nil
        lock.unlock()
        live?.shim.stop()
    }

    private func establish(peerDeviceID: String, timeout: TimeInterval) async -> ResolvedEndpoint? {
        guard let id = currentIdentity(), let client = makeClient(id) else { return nil }
        guard let ch = ensureChannel(id) else { return nil }

        // 1. Authorize the connection (45s grant, both peers now parties).
        let grant: ConnectionGrant
        do {
            grant = try await client.requestConnection(bearer: id.bearer, targetDeviceId: peerDeviceID)
        } catch {
            FatClientLog.log("p2p: connection request failed: \(error)")
            return nil
        }

        let session = P2PSession(grant: grant, role: .dialer)
        lock.lock(); sessions[grant.id] = session; lock.unlock()
        defer { lock.lock(); sessions[grant.id] = nil; lock.unlock() }

        // 2. Offer (seq 1). The dialer carries no candidates in V1 (it connects;
        // its srflx becomes relevant only for the later hole-punch/relay rung).
        do {
            try await session.send(.offer, payload: P2PSignalPayload(note: "connect"), via: ch)
        } catch {
            FatClientLog.log("p2p: offer send failed: \(error)")
            await reportComplete(client, id, connectionId: grant.id, report: .failed(stage: .signaling))
            return nil
        }

        // 3. Collect the listener's answer + trickle candidates.
        let deadline = Date().addingTimeInterval(min(timeout, 8))
        while session.candidates.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !session.candidates.isEmpty {
            try? await Task.sleep(nanoseconds: 400_000_000)   // grace for trickle
        }
        let candidates = session.candidates
        guard !candidates.isEmpty else {
            FatClientLog.log("p2p: no candidates from peer \(peerDeviceID.prefix(8))")
            await reportComplete(client, id, connectionId: grant.id, report: .failed(stage: .signaling))
            return nil
        }

        // 4. Dial best-first. (Relay is a later rung; direct only for now.)
        let t0 = Date()
        guard let win = P2PDirectDialer.dial(candidates: candidates,
                                             overallDeadline: Date().addingTimeInterval(8)) else {
            FatClientLog.log("p2p: all \(candidates.count) candidates unreachable")
            await reportComplete(client, id, connectionId: grant.id, report: .failed(stage: .ice))
            return nil
        }
        Darwin.close(win.fd)   // the shim re-dials per SSH connection

        // 5. Stand up the loopback shim.
        guard let shim = P2PLoopbackShim(winner: win.candidate) else {
            await reportComplete(client, id, connectionId: grant.id, report: .failed(stage: .transport))
            return nil
        }
        lock.lock(); liveShims[peerDeviceID] = (shim, win.path); lock.unlock()

        // 6. Report the path/quality summary (first report wins, closes the
        // grant) — organizations only; a personal account records nothing.
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        await reportComplete(client, id, connectionId: grant.id,
                             report: .connected(pathKind: win.path.reportKind, timeToConnectedMs: ms))

        FatClientLog.log("p2p: peer \(peerDeviceID.prefix(8)) path=\(win.path.uiLabel) via \(win.candidate.ip):\(win.candidate.port) → 127.0.0.1:\(shim.port)")
        return ResolvedEndpoint(host: "127.0.0.1", port: shim.port, path: win.path, peerDeviceID: peerDeviceID)
    }
}
