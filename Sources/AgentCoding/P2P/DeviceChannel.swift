import Foundation

// MARK: - Device channel (persistent outbound signaling WebSocket)

/// The single outbound control connection every P2P-enabled Bromure holds to
/// the control plane (REMOTE_P2P_PLAN.md §Architecture: "outbound is the whole
/// trick — NATs allow outbound freely"). It carries presence (the server marks
/// us online while it's up) and grant-bound signaling frames both ways.
///
/// `WS /v1/device-channel`, authed with the same `Authorization: Bearer
/// <deviceToken>` header as the REST calls. The connection reconnects with
/// capped backoff on unexpected drops; a 401/403 on the upgrade means the token
/// was revoked, so it stops permanently and reports it (revocation must close
/// access, not spin).
final class DeviceChannel: NSObject, @unchecked Sendable {
    // Callbacks (always delivered on the main queue).
    var onSignal: ((_ connectionId: String, _ seq: Int, _ kind: SignalKind,
                    _ from: String, _ payload: P2PSignalPayload) -> Void)?
    /// The listener is offered a new client connection (server-device only).
    var onConnectionOffered: ((ConnectionGrant) -> Void)?
    var onError: ((_ code: String, _ connectionId: String?) -> Void)?
    var onStateChange: ((_ connected: Bool) -> Void)?
    /// The token is dead (revoked / invalid). Terminal — no reconnect.
    var onRevoked: (() -> Void)?
    /// A peer's SSH key was published/withdrawn — re-pull authorized keys now.
    var onKeysChanged: (() -> Void)?
    /// Connected again after a drop that lasted at least `outageThreshold`
    /// (the argument): the internet came back — a captive portal let us
    /// through, a dead Wi-Fi recovered — without the path changing.
    var onRecovered: ((_ downFor: TimeInterval) -> Void)?

    private let endpoint: ControlPlaneEndpoint
    private let token: String
    private let lock = NSLock()

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var desiredOpen = false
    private var isConnected = false
    private var reconnectAttempt = 0
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.bromure.p2p.device-channel")
    /// Our ping cadence, and how long its pong may take. A ping on a half-open
    /// socket (a train out of a tunnel: no reset ever arrives) never completes
    /// at all, so the deadline — not the ping — is what notices. (Vars for
    /// tests.)
    var pingInterval: TimeInterval = 25
    var pongTimeout: TimeInterval = 15
    /// A socket younger than this isn't recycled: it's fresh enough, and a
    /// peer that's merely offline mustn't churn ours on every attempt.
    var recycleMinAge: TimeInterval = 30
    private var openedAt: Date?
    /// A drop shorter than this (a recycle, a blip) isn't an outage.
    var outageThreshold: TimeInterval = 5
    /// When the socket last dropped while wanted; nil while connected.
    private var downSince: Date?
    /// Bumped by `reconnectNow`: a backoff timer from before it stands down.
    private var reconnectGen: UInt64 = 0

    init(endpoint: ControlPlaneEndpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        let dq = OperationQueue()
        dq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: dq)
    }

    // MARK: Lifecycle

    func connect() {
        lock.lock()
        guard !desiredOpen else { lock.unlock(); return }
        desiredOpen = true
        lock.unlock()
        openSocket()
    }

    func close() {
        lock.lock()
        desiredOpen = false
        let t = task
        task = nil
        heartbeat?.cancel(); heartbeat = nil
        lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
        setConnected(false)
    }

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return isConnected }

    /// Drop the current socket and open a fresh one now: the caller has
    /// reason to think it's dead though it reads connected (signaling that
    /// went unanswered).
    /// `force`: the network path changed under it, so however fresh, the
    /// socket is bound to a route that's gone.
    func recycle(force: Bool = false) {
        lock.lock()
        let t = task
        let want = desiredOpen
        let young = openedAt.map { Date().timeIntervalSince($0) < recycleMinAge } ?? false
        lock.unlock()
        guard want, let t, force || !young else { return }
        FatClientLog.log("p2p: device channel recycled")
        t.cancel(with: .goingAway, reason: nil)
        handleDrop(task: t, immediate: true)
    }

    /// Down — waiting out a reconnect backoff (up to 30 s), or an attempt
    /// begun on the network just left (its 30 s timeout): try now instead.
    /// No-op while connected. Runs on `queue`, as the backoff timer does, so
    /// the two never both open a socket.
    func reconnectNow() {
        queue.async { [self] in
            lock.lock()
            guard desiredOpen, !isConnected else { lock.unlock(); return }
            let stale = task
            task = nil                 // its drop, when it comes, is no longer ours
            reconnectGen &+= 1
            if downSince == nil { downSince = Date() }
            lock.unlock()
            stale?.cancel(with: .goingAway, reason: nil)
            FatClientLog.log("p2p: network changed — device channel reconnecting now")
            openSocket()
        }
    }

    // MARK: Sending

    /// Send one signaling frame. Throws `frameTooLarge` if the caller built an
    /// oversized candidate list (split into trickle frames) or a transport error.
    func send(_ frame: OutgoingSignalFrame) async throws {
        let data = try frame.encoded()
        guard let str = String(data: data, encoding: .utf8) else { throw P2PSignalError.frameTooLarge(data.count) }
        let t = lock.withLock { task }
        guard let t else { throw ControlPlaneError.transport("device channel not connected") }
        try await t.send(.string(str))
    }

    // MARK: Internals

    private func openSocket() {
        var req = URLRequest(url: endpoint.deviceChannelURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let t = session.webSocketTask(with: req)
        lock.lock(); task = t; lock.unlock()
        t.resume()
        receiveLoop(on: t)
    }

    private func receiveLoop(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                // Only keep looping on the still-current task.
                self.lock.lock(); let current = (self.task === t); self.lock.unlock()
                if current { self.receiveLoop(on: t) }
            case .failure:
                self.handleDrop(task: t)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return
        }
        guard let frame = IncomingServerFrame.decode(data) else { return }
        switch frame {
        case .signal(let connId, let seq, let kind, let from, let payload):
            dispatch { self.onSignal?(connId, seq, kind, from, payload) }
        case .connection(let grant):
            dispatch { self.onConnectionOffered?(grant) }
        case .error(let code, let connId):
            dispatch { self.onError?(code, connId) }
        case .keysChanged:
            coalesceKeysChanged()
        case .unknown:
            break
        }
    }

    /// Fold a burst of `keysChanged` frames into a single `onKeysChanged`
    /// callback per window. The control plane can emit a flood of these (backlog
    /// replay, or a fleet-wide re-sync loop); firing a full authorized-keys
    /// re-sync per frame hops to the main queue and round-trips to bromure.io
    /// thousands of times a second, starving real work (P2P establishment) —
    /// observed as a ~100/s storm that blocked new connections entirely. One
    /// fire conveys the same information as N: the listener re-pulls the WHOLE
    /// key set anyway, and a 180 s timer already backstops propagation, so
    /// collapsing the burst loses nothing. Runs on `queue`, so a storm never
    /// touches the main queue more than once per window.
    private var keysChangedCoalescing = false
    private static let keysChangedCoalesceWindow: TimeInterval = 2.0

    private func coalesceKeysChanged() {
        lock.lock()
        if keysChangedCoalescing { lock.unlock(); return }
        keysChangedCoalescing = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + Self.keysChangedCoalesceWindow) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.keysChangedCoalescing = false; self.lock.unlock()
            self.dispatch { self.onKeysChanged?() }
        }
    }

    private func handleDrop(task t: URLSessionWebSocketTask, immediate: Bool = false) {
        lock.lock()
        let current = (task === t)
        let want = desiredOpen
        if current {
            task = nil
            heartbeat?.cancel(); heartbeat = nil   // no pings during backoff
        }
        if current, want, downSince == nil { downSince = Date() }
        lock.unlock()
        guard current else { return }
        setConnected(false)

        // A 401/403 on the upgrade = the token is revoked/invalid. Terminal.
        if let http = t.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            lock.lock(); desiredOpen = false; lock.unlock()
            dispatch { self.onRevoked?() }
            return
        }
        guard want else { return }
        scheduleReconnect(immediate: immediate)
    }

    private func scheduleReconnect(immediate: Bool = false) {
        lock.lock()
        reconnectAttempt += 1
        let attempt = immediate ? 0 : reconnectAttempt
        lock.unlock()
        // 0.5s → cap 30s, capped exponential, with ±25% jitter so many devices
        // (or many sessions) knocked off by the same outage don't retry in
        // lockstep and hammer the link/relay the instant it returns.
        let base = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 6))))
        let delay = base * Double.random(in: 0.75...1.25)
        let gen = lock.withLock { reconnectGen }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Not if reconnectNow got there first (its socket is the task).
            self.lock.lock()
            let go = self.desiredOpen && self.reconnectGen == gen && self.task == nil
            self.lock.unlock()
            if go { self.openSocket() }
        }
    }

    private func startHeartbeat(on t: URLSessionWebSocketTask) {
        lock.lock()
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        heartbeat = timer
        lock.unlock()
        // Server pings every 30s (presence TTL 90s = 3 missed). We ping too so a
        // half-open TCP is detected and reconnected rather than lingering.
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        let pongTimeout = self.pongTimeout
        timer.setEventHandler { [weak self, weak t] in
            guard let self, let t else { return }
            let answered = PongFlag()
            t.sendPing { err in
                answered.set()
                if err != nil { self.handleDrop(task: t) }
            }
            self.queue.asyncAfter(deadline: .now() + pongTimeout) { [weak self, weak t] in
                guard let self, let t, !answered.isSet else { return }
                FatClientLog.log("p2p: device channel ping unanswered for \(Int(pongTimeout)) s — reconnecting")
                t.cancel(with: .goingAway, reason: nil)
                self.handleDrop(task: t)
            }
        }
        timer.resume()
    }

    private func setConnected(_ v: Bool) {
        lock.lock()
        let changed = isConnected != v
        isConnected = v
        var recoveredAfter: TimeInterval?
        if v {
            reconnectAttempt = 0
            if let since = downSince {
                let down = Date().timeIntervalSince(since)
                if down >= outageThreshold { recoveredAfter = down }
            }
            downSince = nil
        }
        lock.unlock()
        if changed { dispatch { self.onStateChange?(v) } }
        if let d = recoveredAfter {
            FatClientLog.log("p2p: device channel back after \(Int(d)) s down")
            dispatch { self.onRecovered?(d) }
        }
    }

    private func dispatch(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - URLSession delegate (reliable open/close signals)

extension DeviceChannel: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock(); let current = (task === webSocketTask); lock.unlock()
        guard current else { return }
        lock.lock(); openedAt = Date(); lock.unlock()
        setConnected(true)
        startHeartbeat(on: webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Application close codes (4000 replaced / 4001 revoked / 4002 idle /
        // 4003 rate) can't round-trip through CloseCode, so the reconnect
        // policy in handleDrop (with the 401/403 upgrade check) is what
        // actually distinguishes terminal from transient — this is just cleanup.
        handleDrop(task: webSocketTask)
    }
}

/// Whether a ping's pong (or its error) came back.
private final class PongFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
