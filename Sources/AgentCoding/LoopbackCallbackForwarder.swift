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
    /// Backstop tear-down for a login the user never completes. The primary
    /// tear-down is one-shot (see `relayFinished`): the listener drops the
    /// instant the single OAuth callback has been relayed, so the guest-chosen
    /// host port isn't held — and can't be squatted (H2) — past the one
    /// request it exists for. This timer only covers an abandoned flow.
    private static let lifetimeSeconds = 180.0

    let port: UInt16
    /// The workspace this listener relays into -- fixed for its life: only
    /// that workspace may reuse it (`forPort`), and every connection it
    /// accepts goes there.
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
    private var browserResponseOverride: [UInt8]?
    /// Bumped by `retarget`: a relay accepted for an earlier sign-in ends
    /// without taking the listener down from under the current one.
    private var generation = 0

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

    /// One OAuth callback exchange finished. A loopback callback is single-use,
    /// so tear the listener down now instead of waiting out `lifetimeSeconds` —
    /// the host port is released the moment login completes, shrinking the
    /// port-squat window to the callback itself. Any in-flight splice keeps its
    /// own already-accepted fds and is unaffected by `stop()`; registration's
    /// teardown still waits on `activeRelays` hitting zero.
    private func relayFinished(_ gen: Int) {
        activeRelays -= 1
        if gen == generation { stop() }
    }

    /// Hand this listener to the same workspace's next sign-in on the port
    /// (a retried login): its browser page, a fresh lifetime. A forwarder
    /// that hasn't let go yet (an abandoned sign-in holds the port for
    /// `lifetimeSeconds`, a finished one until its relay closes) made the
    /// retry's bind fail. Rebinding can't be done in place: the old listen
    /// fds close asynchronously, on main. Never another workspace's: see
    /// `forPort`.
    func retarget(browserResponse: String?) {
        browserResponseOverride = browserResponse.map { Array($0.utf8) }
        generation += 1
        armExpiry()
    }

    /// Whether this listener relays into `device`'s VM.
    func relays(into device: VZVirtioSocketDevice?) -> Bool {
        device.map { Self.owns(socketDevice, $0) } ?? false
    }

    /// Its VM is still there (the device is held weakly).
    var hasWorkspace: Bool { socketDevice != nil }

    /// Whether `caller` is the workspace a listener relays into (`owner`):
    /// identity, not equality -- one VM's socket device.
    nonisolated static func owns(_ owner: AnyObject?, _ caller: AnyObject) -> Bool {
        owner.map { $0 === caller } ?? false
    }

    /// The one forwarder for `port` in `forwarders`: the same workspace's live
    /// one is reused, else a new one is bound and added. Nil when the port
    /// can't be bound -- another program holds it, or ANOTHER workspace's
    /// sign-in does. Any guest can name a loopback port in a URL it opens
    /// (Codex always uses 1455), and handing it a live listener sent the
    /// browser's OAuth redirect -- the code another workspace's sign-in was
    /// waiting for -- into that guest, and re-armed the port's lifetime for
    /// it (Finding CWE-441, "A guest URL retargets another workspace's OAuth
    /// loopback forwarder"). That sign-in keeps the port, its page and its
    /// expiry; the other one's callback can't be relayed until it ends.
    static func forPort(_ port: UInt16, socketDevice: VZVirtioSocketDevice, browserResponse: String? = nil,
                        in forwarders: inout [LoopbackCallbackForwarder]) -> LoopbackCallbackForwarder? {
        // A listener whose VM is gone relays nowhere: let the port go (its
        // fds close on main, so this request may still find it busy).
        for f in forwarders where f.isRunning && !f.hasWorkspace { f.stop() }
        forwarders.removeAll { !$0.isRunning }
        if let live = forwarders.first(where: { $0.port == port }) {
            guard owns(live.socketDevice, socketDevice) else {
                log("127.0.0.1:\(port) is another workspace's sign-in: not handed over")
                return nil
            }
            live.retarget(browserResponse: browserResponse)
            return live
        }
        guard let fwd = LoopbackCallbackForwarder(port: port, socketDevice: socketDevice,
                                                  browserResponse: browserResponse) else { return nil }
        forwarders.append(fwd)
        return fwd
    }

    // MARK: - Listener

    /// Bind both loopback families. Succeeds only if NEITHER address is held
    /// by someone else: a browser follows `127.0.0.1` to the IPv4 listener and
    /// `localhost` to whichever family it resolves first, so a forwarder that
    /// got one family while another program held the other would open the
    /// page and hand that program the OAuth code (Finding CWE-441, "A
    /// one-family loopback bind is treated as owning the OAuth port, so the
    /// page still opens"). A family this host simply lacks (IPv4-only,
    /// IPv6-only) is skipped; at least one must bind.
    private func bindAndListen() -> Bool {
        let results = [Self.listenLoopback(family: AF_INET, port: port),
                       Self.listenLoopback(family: AF_INET6, port: port)]
        guard Self.owns(results) else {
            for case .bound(let fd) in results { Darwin.close(fd) }
            return false
        }
        for case .bound(let fd) in results {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in self?.acceptOne(on: fd) }
            src.setCancelHandler { Darwin.close(fd) }
            listeners.append((fd, src))
            src.activate()
        }
        isRunning = true
        armExpiry()
        return true
    }

    /// One loopback family's listen: up (its fd), not on this host, or taken
    /// (in use -- or any other failure: fail closed).
    enum LoopbackListen: Equatable {
        case bound(Int32), unavailable, taken
    }

    /// The port is ours: nothing taken, something bound.
    nonisolated static func owns(_ results: [LoopbackListen]) -> Bool {
        !results.contains(.taken) && results.contains { if case .bound = $0 { return true } else { return false } }
    }

    private func armExpiry() {
        expiry?.cancel()
        let exp = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = exp
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetimeSeconds, execute: exp)
    }

    /// Bind + listen on the loopback address of one family (127.0.0.1, or ::1
    /// IPv6-only so it never collides with the IPv4 listener).
    nonisolated static func listenLoopback(family: Int32, port: UInt16) -> LoopbackListen {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT ? .unavailable : .taken }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let rc: Int32
        if family == AF_INET6 {
            var v6only: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback   // ::1
            rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(fd)
            return err == EADDRNOTAVAIL || err == EAFNOSUPPORT ? .unavailable : .taken
        }
        guard Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); return .taken }
        return .bound(fd)
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[ac] loopback-fwd: \(msg)\n".utf8))
    }

    private func acceptOne(on listenFD: Int32) {
        let cfd = Darwin.accept(listenFD, nil, nil)
        guard cfd >= 0 else { return }
        guard socketDevice != nil else { Darwin.close(cfd); return }
        let target = port
        // The sign-in this connection belongs to, as of its accept.
        let gen = generation, response = browserResponseOverride

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
        q.async { [weak self] in
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
            // gone away while we were reading, hence the re-check. It is the
            // one this connection was accepted for: a listener's workspace
            // never changes (`forPort`), so bytes read for one sign-in can't
            // be dialed into another guest.
            DispatchQueue.main.async { [weak self] in
                guard let dev = self?.socketDevice else { Darwin.close(cfd); return }
                Self.log("browser sent \(n)B on 127.0.0.1:\(target); dialing guest relay (vsock \(Self.relayVsockPort))")
                dev.connect(toPort: Self.relayVsockPort) { result in
                    switch result {
                    case .success(let conn):
                        // Our own descriptor: `conn` owns fileDescriptor and
                        // closes it when it's released — right after this
                        // callback — while the relay below runs on. Using that
                        // number then (and closing it at the end) closed
                        // whatever file had reused it, and closing a guarded
                        // one kills the app (EXC_GUARD) just after sign-in.
                        let vfd = dup(conn.fileDescriptor)
                        guard vfd >= 0 else {
                            Self.log("vsock dup failed (errno \(errno))")
                            Darwin.close(cfd); return
                        }
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
                        if let response {
                            // Answer the browser ourselves with a clean page,
                            // and drain the guest's own response into the void
                            // so the CLI's write succeeds and it proceeds to the
                            // token exchange.
                            Self.log("relay connected; answering browser directly on 127.0.0.1:\(target)")
                            Self.respondAndDrain(browser: cfd, guest: vfd, response: response) {
                                [weak self] in
                                DispatchQueue.main.async { self?.relayFinished(gen) }
                            }
                        } else {
                            Self.log("relay connected; splicing to guest 127.0.0.1:\(target)")
                            Self.splice(cfd, vfd) { [weak self] in
                                DispatchQueue.main.async { self?.relayFinished(gen) }
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
