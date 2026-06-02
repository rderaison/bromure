import Foundation
import Virtualization

/// Forwards a host loopback port into the guest's loopback so a browser on the
/// macOS host can deliver an OAuth redirect callback to a CLI's
/// `127.0.0.1:<port>` listener running inside the VM (grok-cli, gh, gcloud, …).
///
/// Flow:
///   host browser → 127.0.0.1:<port>/callback (this listener)
///     → vsock connect to guest port 5010 (loopback-relay-agent)
///       → header "<port>\n" → guest 127.0.0.1:<port> (the CLI's listener)
///
/// The OAuth `redirect_uri` is never rewritten — it stays `127.0.0.1:<port>`,
/// which x.ai accepts and which matches what the CLI replays at token
/// exchange (so PKCE / redirect validation still pass). We only bridge the
/// transport.
@MainActor
final class LoopbackCallbackForwarder {
    /// Must match VSOCK_PORT in loopback-relay-agent.py.
    private static let relayVsockPort: UInt32 = 5010
    /// Auto-tear-down so we never sit on a host loopback port indefinitely.
    private static let lifetimeSeconds = 300.0

    let port: UInt16
    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var expiry: DispatchWorkItem?
    private(set) var isRunning = false

    /// Returns nil if the host loopback port can't be bound (already in use,
    /// etc.) — in that case the caller just opens the URL and lets the native
    /// flow proceed.
    init?(port: UInt16, socketDevice: VZVirtioSocketDevice) {
        self.port = port
        self.socketDevice = socketDevice
        guard bindAndListen() else { return nil }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        expiry?.cancel(); expiry = nil
        acceptSource?.cancel(); acceptSource = nil  // cancel handler closes listenFD
        listenFD = -1
    }

    // MARK: - Listener

    private func bindAndListen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return false
        }
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.activate()
        isRunning = true

        let exp = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = exp
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetimeSeconds, execute: exp)
        return true
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[ac] loopback-fwd: \(msg)\n".utf8))
    }

    private func acceptOne() {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        guard socketDevice != nil else { Darwin.close(cfd); return }
        let target = port

        // Don't bridge to the guest until the browser actually sends its
        // request. Safari (and others) open speculative *preconnect* sockets
        // that establish TCP but send nothing; dialing grok's single-shot
        // callback server for those leaves it with dead connections and can
        // wedge the real request. Read the first chunk on a background queue;
        // only a connection that sends data gets forwarded.
        let q = DispatchQueue.global(qos: .utility)
        // Cap the wait so an idle preconnect doesn't pin a thread forever.
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        q.async {
            var firstBuf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(cfd, &firstBuf, firstBuf.count)
            guard n > 0 else {
                // Preconnect that never sent / closed / timed out — ignore it.
                Darwin.close(cfd)
                return
            }
            let head = Array(firstBuf[0..<n])
            // Re-acquire the socket device on the main thread rather than
            // capturing it in this @Sendable background closure: VZ types
            // aren't Sendable, and VZ calls must happen on the main thread
            // anyway. `self` is @MainActor (so Sendable); the device may have
            // gone away while we were reading, hence the re-check.
            DispatchQueue.main.async { [weak self] in
                guard let dev = self?.socketDevice else { Darwin.close(cfd); return }
                Self.log("browser sent \(n)B on 127.0.0.1:\(target); dialing guest relay (vsock \(Self.relayVsockPort))")
                dev.connect(toPort: Self.relayVsockPort) { result in
                    switch result {
                    case .success(let conn):
                        let vfd = conn.fileDescriptor
                        let header = "\(target)\n"
                        let sent = header.withCString { Darwin.write(vfd, $0, strlen($0)) }
                        guard sent > 0 else {
                            Self.log("vsock header write failed")
                            Darwin.close(cfd); Darwin.close(vfd); return
                        }
                        // Replay the request bytes we already consumed.
                        _ = head.withUnsafeBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return Darwin.write(vfd, base, head.count)
                        }
                        Self.log("relay connected; splicing to guest 127.0.0.1:\(target)")
                        Self.splice(cfd, vfd)
                    case .failure(let err):
                        Self.log("vsock connect to relay FAILED (\(err)) — is loopback-relay-agent listening on \(Self.relayVsockPort) in the guest?")
                        Darwin.close(cfd)
                    }
                }
            }
        }
    }

    // MARK: - Bidirectional copy

    /// Pump bytes both ways between two fds; close both once both directions
    /// have hit EOF. One short HTTP request/response (the OAuth callback).
    private static func splice(_ a: Int32, _ b: Int32) {
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .utility)

        func pump(from: Int32, to: Int32) {
            group.enter()
            q.async {
                var buf = [UInt8](repeating: 0, count: 65536)
                outer: while true {
                    let n = Darwin.read(from, &buf, buf.count)
                    if n <= 0 { break }
                    var off = 0
                    let wrote = buf.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        while off < n {
                            let w = Darwin.write(to, base + off, n - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !wrote { break outer }
                }
                // Signal EOF to the peer so its read returns 0 and its pump ends.
                Darwin.shutdown(to, SHUT_WR)
                group.leave()
            }
        }

        pump(from: a, to: b)
        pump(from: b, to: a)
        group.notify(queue: q) {
            Darwin.close(a)
            Darwin.close(b)
        }
    }
}
