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

    // MARK: Sending

    /// Send one signaling frame. Throws `frameTooLarge` if the caller built an
    /// oversized candidate list (split into trickle frames) or a transport error.
    func send(_ frame: OutgoingSignalFrame) async throws {
        let data = try frame.encoded()
        guard let str = String(data: data, encoding: .utf8) else { throw P2PSignalError.frameTooLarge(data.count) }
        lock.lock(); let t = task; lock.unlock()
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
            dispatch { self.onKeysChanged?() }
        case .unknown:
            break
        }
    }

    private func handleDrop(task t: URLSessionWebSocketTask) {
        lock.lock()
        let current = (task === t)
        let want = desiredOpen
        if current {
            task = nil
            heartbeat?.cancel(); heartbeat = nil   // no pings during backoff
        }
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
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()
        // 0.5s → cap 30s, capped exponential. (No jitter source available in
        // this build — Math.random-equivalents are fine here, but keep it simple.)
        let delay = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 6))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let want = self.desiredOpen; self.lock.unlock()
            if want { self.openSocket() }
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
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self, weak t] in
            guard let self, let t else { return }
            t.sendPing { err in
                if err != nil { self.handleDrop(task: t) }
            }
        }
        timer.resume()
    }

    private func setConnected(_ v: Bool) {
        lock.lock()
        let changed = isConnected != v
        isConnected = v
        if v { reconnectAttempt = 0 }
        lock.unlock()
        if changed { dispatch { self.onStateChange?(v) } }
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
