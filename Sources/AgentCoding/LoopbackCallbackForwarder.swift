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
    /// One listener per loopback family (IPv4 127.0.0.1 + IPv6 ::1). Browsers
    /// resolve `localhost` to `::1` first on macOS, so an IPv4-only listener
    /// makes the OAuth callback fail with "Safari can't connect to the server".
    private var listeners: [(fd: Int32, source: DispatchSourceRead)] = []
    private var expiry: DispatchWorkItem?
    private(set) var isRunning = false
    /// Callback exchanges currently being spliced. Registration teardown
    /// waits for this to hit zero before stopping the VM — killing the guest
    /// mid-splice resets the browser's connection ("the remote host closed
    /// the connection abruptly" in Safari).
    private(set) var activeRelays = 0

    /// When set, the browser gets THIS exact HTTP response (a self-contained
    /// success page) and the guest's own response is drained + discarded —
    /// instead of splicing the guest's response back. Used for subscription
    /// registration, where some CLIs' local callback servers close the
    /// connection without a clean response, leaving Safari on "can't open the
    /// page" even though the code was delivered and login succeeded.
    private let browserResponseOverride: [UInt8]?

    /// Returns nil if the host loopback port can't be bound (already in use,
    /// etc.) — in that case the caller just opens the URL and lets the native
    /// flow proceed.
    init?(port: UInt16, socketDevice: VZVirtioSocketDevice,
          browserResponse: String? = nil) {
        self.port = port
        self.socketDevice = socketDevice
        self.browserResponseOverride = browserResponse.map { Array($0.utf8) }
        guard bindAndListen() else { return nil }
    }

    /// A friendly, self-contained "signed in" page — no dependency on a live
    /// bromure.io URL (a 302 to a missing page would just 404 in the browser).
    static func registrationSuccessResponse(provider: String) -> String {
        let body = """
        <!doctype html><html><head><meta charset="utf-8">\
        <title>Signed in — Bromure</title><style>\
        html,body{height:100%;margin:0}\
        body{background:#0b0f14;color:#e7ecf2;\
        font:15px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;\
        display:flex;align-items:center;justify-content:center}\
        .c{text-align:center;max-width:420px;padding:32px}\
        .m{font-size:44px;line-height:1}\
        h1{font-size:19px;font-weight:600;margin:18px 0 8px}\
        p{color:#9aa7b4;margin:0;font-size:13px}\
        </style></head><body><div class="c"><div class="m">✓</div>\
        <h1>Signed in to \(provider)</h1>\
        <p>Bromure captured your credentials. You can close this tab and return to the app.</p>\
        </div></body></html>
        """
        let bytes = Array(body.utf8).count
        return "HTTP/1.1 200 OK\r\n"
             + "Content-Type: text/html; charset=utf-8\r\n"
             + "Content-Length: \(bytes)\r\n"
             + "Connection: close\r\n\r\n"
             + body
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        expiry?.cancel(); expiry = nil
        // Cancel handlers close the listen fds.
        for l in listeners { l.source.cancel() }
        listeners = []
    }

    // MARK: - Listener

    /// Bind both loopback families. Succeeds if AT LEAST ONE binds — an
    /// IPv4-only or IPv6-only host still works, and the common dual-stack case
    /// covers whichever `localhost` resolves to.
    private func bindAndListen() -> Bool {
        let v4 = bindOne(family: AF_INET)
        let v6 = bindOne(family: AF_INET6)
        guard v4 || v6 else { return false }
        isRunning = true
        let exp = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = exp
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetimeSeconds, execute: exp)
        return true
    }

    /// Bind + listen on the loopback address of one family; registers an accept
    /// source and returns whether it came up.
    private func bindOne(family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        let bound: Bool
        if family == AF_INET6 {
            // Loopback only, and IPv6-only on this socket so it never collides
            // with the IPv4 listener on a dual-stack host.
            var v6only: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback   // ::1
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } == 0
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        }
        guard bound, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return false
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne(on: fd) }
        src.setCancelHandler { Darwin.close(fd) }
        listeners.append((fd, src))
        src.activate()
        return true
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[ac] loopback-fwd: \(msg)\n".utf8))
    }

    private func acceptOne(on listenFD: Int32) {
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
                        // Replay the request bytes we already consumed —
                        // delivers the OAuth code to the guest's callback
                        // server so the CLI completes login.
                        _ = head.withUnsafeBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return Darwin.write(vfd, base, head.count)
                        }
                        DispatchQueue.main.async { [weak self] in self?.activeRelays += 1 }
                        if let response = self?.browserResponseOverride {
                            // Answer the browser ourselves with a clean page,
                            // and drain the guest's own response into the void
                            // so the CLI's write succeeds and it proceeds to the
                            // token exchange.
                            Self.log("relay connected; answering browser directly on 127.0.0.1:\(target)")
                            Self.respondAndDrain(browser: cfd, guest: vfd, response: response) {
                                [weak self] in
                                DispatchQueue.main.async { self?.activeRelays -= 1 }
                            }
                        } else {
                            Self.log("relay connected; splicing to guest 127.0.0.1:\(target)")
                            Self.splice(cfd, vfd) { [weak self] in
                                DispatchQueue.main.async { self?.activeRelays -= 1 }
                            }
                        }
                    case .failure(let err):
                        Self.log("vsock connect to relay FAILED (\(err)) — is loopback-relay-agent listening on \(Self.relayVsockPort) in the guest?")
                        Darwin.close(cfd)
                    }
                }
            }
        }
    }

    /// Write our own response to the browser, close its write side, and drain
    /// both fds to EOF (discarding whatever the guest CLI writes back) before
    /// closing. Guarantees the browser sees a clean page while the CLI still
    /// completes its login. `onDone` fires after both fds are closed.
    private static func respondAndDrain(browser: Int32, guest: Int32,
                                        response: [UInt8],
                                        onDone: @escaping @Sendable () -> Void) {
        let q = DispatchQueue.global(qos: .utility)
        q.async {
            // Send the page to the browser.
            _ = response.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var off = 0
                while off < response.count {
                    let w = Darwin.write(browser, base + off, response.count - off)
                    if w <= 0 { break }
                    off += w
                }
                return off
            }
            Darwin.shutdown(browser, SHUT_WR)
            // Drain both sides (short cap) so the guest's own response write
            // lands somewhere instead of a broken pipe, then close.
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(browser, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 16384)
            for fd in [guest, browser] {
                while Darwin.read(fd, &buf, buf.count) > 0 { /* discard */ }
            }
            Darwin.close(guest)
            Darwin.close(browser)
            onDone()
        }
    }

    // MARK: - Bidirectional copy

    /// Pump bytes both ways between two fds; close both once both directions
    /// have hit EOF. One short HTTP request/response (the OAuth callback).
    /// `onDone` fires after both fds are closed.
    private static func splice(_ a: Int32, _ b: Int32,
                               onDone: @escaping @Sendable () -> Void) {
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
            onDone()
        }
    }
}
