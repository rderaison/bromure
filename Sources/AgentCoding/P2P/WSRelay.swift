import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ws-relay listener (browser / web-client dialers)
//
// A browser can't open TCP or speak TURN, so the web client (hosted on
// bromure.io, and the Electron app for peers) reaches a server through a
// bromure.io WebSocket byte relay: it takes a connection grant, sends the
// usual signaling `offer` with payload note "ws-relay", and joins
// `wss://…/v1/connections/<id>/relay` as the dialer. On that offer this
// listener joins the same relay as the server party and splices it to its own
// sshd on 127.0.0.1. bromure.io only pipes opaque bytes: SSH (host-key pinning,
// key auth) stays end to end — the P2P plan's invariant holds.
//
// The relay authorizes the join itself (only the grant's server install may
// join as listener), so acting on any ws-relay offer is safe: at worst it opens
// a socket the relay refuses.

enum WSRelayNote {
    static let value = "ws-relay"
}

final class WSRelayListener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    private static var live: [String: WSRelayListener] = [:]
    /// Bound on concurrent relayed SSH sessions this server carries.
    static let maxConcurrent = 8

    private let connectionId: String
    private let url: URL
    private let bearer: String
    private let sshPort: Int
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var fd: Int32 = -1
    private let stateLock = NSLock()
    private var closed = false

    /// Join the relay for `connectionId` and splice it to the local sshd.
    /// Idempotent per connection.
    /// A grant id is a UUID-like token; anything else never reaches a URL.
    static func isValidConnectionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func join(connectionId: String, endpoint: ControlPlaneEndpoint, bearer: String, sshPort: Int) {
        guard isValidConnectionId(connectionId) else {
            FatClientLog.log("ws-relay: refusing malformed connection id")
            return
        }
        lock.lock()
        if live[connectionId] != nil || live.count >= maxConcurrent {
            let full = live.count >= maxConcurrent
            lock.unlock()
            if full { FatClientLog.log("ws-relay: at capacity — ignoring \(connectionId)") }
            return
        }
        var comps = URLComponents(url: endpoint.base.appendingPathComponent("/v1/connections/\(connectionId)/relay"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = endpoint.base.scheme == "http" ? "ws" : "wss"
        let l = WSRelayListener(connectionId: connectionId, url: comps.url!, bearer: bearer, sshPort: sshPort)
        live[connectionId] = l
        lock.unlock()
        l.start()
    }

    private init(connectionId: String, url: URL, bearer: String, sshPort: Int) {
        self.connectionId = connectionId
        self.url = url
        self.bearer = bearer
        self.sshPort = sshPort
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private func start() {
        // Local sshd first: no point holding a relay slot we can't serve.
        guard let sock = Self.dialLoopback(port: sshPort) else {
            FatClientLog.log("ws-relay: local sshd :\(sshPort) unreachable")
            finish(); return
        }
        fd = sock
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        receiveLoop()
        let th = Thread { [weak self] in self?.pumpSSHToRelay() }
        th.stackSize = 512 * 1024
        th.start()
        FatClientLog.log("ws-relay: joining \(connectionId)")
    }

    // Relay → sshd
    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                if !self.writeAll(d) { self.finish(); return }
                self.receiveLoop()
            case .success(.string):
                // The relay is binary-only; a text frame is a protocol error.
                self.finish()
            case .success:
                self.receiveLoop()
            case .failure(let e):
                FatClientLog.log("ws-relay: \(self.connectionId) relay ended: \(e.localizedDescription)")
                self.finish()
            }
        }
    }

    // sshd → relay (blocking reads on a dedicated thread; sends are sequenced
    // by waiting for each completion so frames stay in order and memory bounded).
    private func pumpSSHToRelay() {
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let fdNow: Int32 = stateLock.withLock { closed ? -1 : fd }
            if fdNow < 0 { break }
            let n = buf.withUnsafeMutableBytes { Darwin.read(fdNow, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            let data = Data(buf[0..<n])
            let sem = DispatchSemaphore(value: 0)
            var ok = true
            task?.send(.data(data)) { err in if err != nil { ok = false }; sem.signal() }
            sem.wait()
            if !ok { break }
        }
        finish()
    }

    private func writeAll(_ d: Data) -> Bool {
        let fdNow: Int32 = stateLock.withLock { closed ? -1 : fd }
        guard fdNow >= 0 else { return false }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fdNow, p, left)
                if n > 0 { p += n; left -= n }
                else if n < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }

    private func finish() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let f = fd; fd = -1
        stateLock.unlock()
        if f >= 0 { Darwin.shutdown(f, SHUT_RDWR); Darwin.close(f) }
        task?.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        Self.lock.lock(); Self.live[connectionId] = nil; Self.lock.unlock()
        FatClientLog.log("ws-relay: \(connectionId) closed")
    }

    private static func dialLoopback(port: Int) -> Int32? {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { Darwin.close(s); return nil }
        return s
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }
}
