import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import OpenDirectory
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

enum RemoteSSHError: Error { case invalidChannelType }

/// Close the connection on any pipeline error.
final class RemoteErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Authentication

/// Verifies the macOS account password unprivileged via OpenDirectory. This is
/// what lets us offer password login without root and without enabling Remote
/// Login (which the stock sshd's PAM path would require).
enum SystemPassword {
    static func verify(user: String, password: String) -> Bool {
        guard !password.isEmpty else { return false }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

/// Single-user auth: only the user who launched bromure-ac, via an enrolled
/// public key and/or that user's macOS account password.
final class RemoteAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let allowPassword: Bool
    private let allowPubkey: Bool
    private let authorizedKeys: Set<NIOSSHPublicKey>
    /// Shared across every connection; rate-limits password attempts per
    /// source IP. See `RemoteAuthThrottle`.
    private let throttle: RemoteAuthThrottle
    /// This connection's source IP, for the per-IP bucket.
    private let peerIP: String

    init(username: String, allowPassword: Bool, allowPubkey: Bool,
         authorizedKeys: Set<NIOSSHPublicKey>,
         throttle: RemoteAuthThrottle, peerIP: String) {
        self.username = username
        self.allowPassword = allowPassword
        self.allowPubkey = allowPubkey
        self.authorizedKeys = authorizedKeys
        self.throttle = throttle
        self.peerIP = peerIP
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        var m: NIOSSHAvailableUserAuthenticationMethods = []
        if allowPassword { m.insert(.password) }
        if allowPubkey { m.insert(.publicKey) }
        return m
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == username else {
            responsePromise.succeed(.failure); return
        }
        switch request.request {
        case .publicKey(let pk):
            // NIO-SSH has already verified the signature; we only decide if the
            // key is enrolled.
            if allowPubkey, authorizedKeys.contains(pk.publicKey) {
                responsePromise.succeed(.success)
            } else {
                responsePromise.succeed(.failure)
            }
        case .password(let pw):
            guard allowPassword else { responsePromise.succeed(.failure); return }
            let user = username
            let password = pw.password
            // Per-IP rate limit. `reserve` returns how long this attempt must
            // wait for a token; 0 while the per-IP burst budget lasts, then a
            // short (capped) delay under sustained guessing. Each attempt is
            // scheduled independently on a concurrent queue, so one IP's
            // backoff never stalls another IP's login — the owner is unaffected
            // by an attacker elsewhere. Nothing is ever refused outright; the
            // door stays open, just slow to hammer.
            let delay = throttle.reserve(ip: peerIP)
            let work: @Sendable () -> Void = {
                let ok = SystemPassword.verify(user: user, password: password)
                responsePromise.succeed(ok ? .success : .failure)
            }
            let q = DispatchQueue.global(qos: .utility)
            if delay > 0 { q.asyncAfter(deadline: .now() + delay, execute: work) }
            else { q.async(execute: work) }
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Builds a per-connection `RemoteAuthDelegate` (each carries its peer's IP for
/// the rate limiter) from the listener-wide config + shared throttle. Wrapping
/// the non-Sendable `authorizedKeys` here keeps it out of the bootstrap's
/// `@Sendable` child-channel closure.
final class RemoteAuthDelegateFactory: @unchecked Sendable {
    private let username: String
    private let allowPassword: Bool
    private let allowPubkey: Bool
    private let authorizedKeys: Set<NIOSSHPublicKey>
    private let throttle: RemoteAuthThrottle

    init(username: String, allowPassword: Bool, allowPubkey: Bool,
         authorizedKeys: Set<NIOSSHPublicKey>, throttle: RemoteAuthThrottle) {
        self.username = username
        self.allowPassword = allowPassword
        self.allowPubkey = allowPubkey
        self.authorizedKeys = authorizedKeys
        self.throttle = throttle
    }

    func make(peerIP: String) -> RemoteAuthDelegate {
        RemoteAuthDelegate(username: username, allowPassword: allowPassword,
                           allowPubkey: allowPubkey, authorizedKeys: authorizedKeys,
                           throttle: throttle, peerIP: peerIP)
    }
}

// MARK: - Password brute-force rate limiter

/// Per-source-IP token bucket for password authentication, shared across every
/// connection to the listener.
///
/// Design goals, in order: (1) make online password guessing slow enough to be
/// useless, (2) never lock anyone out — an over-budget attempt just waits its
/// turn, the door is never shut, and (3) isolate IPs from each other so a flood
/// from one address can't slow the legitimate owner connecting from another.
///
/// Each IP gets a small burst (`capacity` attempts at full speed), then refills
/// at `refillPerSec`. When the bucket is empty an attempt is delayed until the
/// next token (capped at `maxDelay`), so sustained guessing from one IP settles
/// to roughly `refillPerSec` attempts/second — ~7–8 attempts/minute at the cap.
/// Public-key auth is never throttled.
final class RemoteAuthThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private struct Bucket { var tokens: Double; var last: Date }
    private var buckets: [String: Bucket] = [:]
    private let capacity: Double
    private let refillPerSec: Double
    private let maxDelay: TimeInterval
    private var lastPrune = Date.distantPast

    init(capacity: Double = 5, refillPerSec: Double = 0.5, maxDelay: TimeInterval = 8) {
        self.capacity = capacity
        self.refillPerSec = refillPerSec
        self.maxDelay = maxDelay
    }

    /// Reserve one attempt for `ip`. Returns the delay (seconds) the caller
    /// should wait before performing the password check — 0 when a token is
    /// immediately available.
    func reserve(ip: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        prune(now: now)
        var b = buckets[ip] ?? Bucket(tokens: capacity, last: now)
        // Refill proportional to elapsed time, capped at capacity.
        b.tokens = min(capacity, b.tokens + now.timeIntervalSince(b.last) * refillPerSec)
        b.last = now
        let delay: TimeInterval
        if b.tokens >= 1 {
            delay = 0
        } else {
            // Wait for the next token. Cap the per-attempt wait so the bucket
            // can't push the delay arbitrarily high.
            delay = min(maxDelay, (1 - b.tokens) / refillPerSec)
        }
        // Consume a token; floor at -capacity so a long flood can't drive the
        // recovery time unbounded (sustained rate stays ~refillPerSec).
        b.tokens = max(-capacity, b.tokens - 1)
        buckets[ip] = b
        return delay
    }

    /// Drop idle, fully-refilled buckets and hard-cap the map so an IP-spray
    /// flood can't grow memory without bound.
    private func prune(now: Date) {
        guard now.timeIntervalSince(lastPrune) > 300 else { return }
        lastPrune = now
        buckets = buckets.filter { _, b in
            now.timeIntervalSince(b.last) < 600 || b.tokens < capacity
        }
        if buckets.count > 8192 {
            let keep = buckets.sorted { $0.value.last > $1.value.last }.prefix(4096)
            buckets = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

// MARK: - Session: bridge an SSH channel to a forced menu on a real PTY

/// Forces every session into `bromure-ac __remote-menu` running on a real PTY,
/// and pumps bytes between the SSH channel and the PTY master. A real PTY means
/// the menu's TUI and the `tmux attach` path work unmodified (they assume a
/// tty on fd 0/1).
final class SSHPTYSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let menuExe: String
    private let user: String
    /// Path to the app's owner-only control socket. When a fat client sends the
    /// `FatClient.controlVerb` exec command, we bridge the SSH channel straight
    /// to this socket (no PTY, no menu) so the client can speak the control-plane
    /// HTTP API — including the hijacked interactive-exec pump for terminals.
    private let controlSocketPath: String
    /// Resolves a `forward <ip> <port>` to a guest-loopback-relay fd (vsock).
    private let forwardResolver: RemoteAccessServer.ForwardResolver?
    private let udpForwardResolver: RemoteAccessServer.UDPForwardResolver?
    private let browserMCPResolver: RemoteAccessServer.BrowserMCPResolver?
    /// Inbound SSH bytes that arrived before the forward fd was ready (the vsock
    /// connect is async), flushed once it is.
    private var pendingInbound: [UInt8] = []
    private var term = "xterm-256color"
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    /// The fd we pump bytes to/from: a PTY master (menu path) or the control
    /// socket (fat-client path). Reused by the single read pump + `channelRead`.
    private var master: Int32 = -1
    private var childPID: pid_t = -1
    private var started = false
    private var terminated = false
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "io.bromure.remote.pty")
    /// The most recent pump write's completion. NIO does NOT flush queued
    /// writes before an explicit close — closing on fd-EOF while megabytes
    /// sat in the channel's outbound buffer truncated large control-plane
    /// responses (fat-client file downloads arrived 4 MB short). The EOF
    /// path waits on this before finish().
    private var lastPumpWrite: EventLoopFuture<Void>?

    /// Forward one pumped chunk and remember its completion; on fd EOF the
    /// teardown chains behind the last write instead of racing it.
    private func pumpWrite(_ channel: Channel, _ bb: ByteBuffer) {
        let p = channel.eventLoop.makePromise(of: Void.self)
        lastPumpWrite = p.futureResult
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bb)),
                              promise: p)
    }

    /// finish() only after every queued pump write has actually left the
    /// channel — then back on ioQueue, where the pump state lives.
    private func finishAfterDrain(channel: Channel, pid: pid_t, master: Int32) {
        let pending = lastPumpWrite
        let el = channel.eventLoop
        el.execute { [weak self] in
            (pending ?? el.makeSucceededVoidFuture()).whenComplete { _ in
                guard let self else { return }
                self.ioQueue.async {
                    self.finish(channel: channel, pid: pid, master: master)
                }
            }
        }
    }
    /// SSH→master bytes awaiting a writable `master` (a slow guest/control reader
    /// fills the send buffer). Drained by `writeSource` when the fd is writable,
    /// so a stalled reader never busy-spins or blocks the SSH event loop. Only
    /// touched on `ioQueue`.
    private var outBuffer: [UInt8] = []
    private var writeSource: DispatchSourceWrite?

    init(menuExe: String, user: String, controlSocketPath: String,
         forwardResolver: RemoteAccessServer.ForwardResolver? = nil,
         udpForwardResolver: RemoteAccessServer.UDPForwardResolver? = nil,
         browserMCPResolver: RemoteAccessServer.BrowserMCPResolver? = nil) {
        self.menuExe = menuExe
        self.user = user
        self.controlSocketPath = controlSocketPath
        self.forwardResolver = forwardResolver
        self.udpForwardResolver = udpForwardResolver
        self.browserMCPResolver = browserMCPResolver
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let pid = childPID
        let m = master
        ioQueue.async { [weak self] in self?.teardown(pid: pid, master: m) }
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let e as SSHChannelRequestEvent.PseudoTerminalRequest:
            term = e.term
            cols = UInt16(clamping: e.terminalCharacterWidth)
            rows = UInt16(clamping: e.terminalRowHeight)
            if e.wantReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case let e as SSHChannelRequestEvent.ShellRequest:
            startMenu(context: context, wantReply: e.wantReply)
        case let e as SSHChannelRequestEvent.ExecRequest:
            // A fat client asks for the control-socket bridge or a guest TCP
            // forward by name. Anything else keeps ForceCommand semantics:
            // ignore the command, run the menu.
            if e.command == FatClient.controlVerb {
                startControlBridge(context: context, wantReply: e.wantReply)
            } else if let fwd = FatClient.parseForward(e.command) {
                startForwardBridge(context: context, wantReply: e.wantReply,
                                   ip: fwd.ip, port: fwd.port)
            } else if let ip = FatClient.parseForwardUDP(e.command) {
                startUDPForwardBridge(context: context, wantReply: e.wantReply, ip: ip)
            } else if let vm = FatClient.parseBrowserMCP(e.command) {
                startBrowserMCPBridge(context: context, wantReply: e.wantReply, vm: vm)
            } else {
                startMenu(context: context, wantReply: e.wantReply)
            }
        case let e as SSHChannelRequestEvent.WindowChangeRequest:
            cols = UInt16(clamping: e.terminalCharacterWidth)
            rows = UInt16(clamping: e.terminalRowHeight)
            applyWinsize()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = channelData.data, case .channel = channelData.type else { return }
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        // Hand off to the io queue so the write path (buffer + writable-drain)
        // never runs on — or blocks — the SSH event loop.
        ioQueue.async { [weak self] in self?.deliverInbound(bytes) }
    }

    // MARK: SSH → master write path (non-blocking, backpressure-aware; ioQueue only)

    private func deliverInbound(_ bytes: [UInt8]) {
        // The forward/control fd opens asynchronously; buffer bytes that beat it.
        if master < 0 { pendingInbound.append(contentsOf: bytes); return }
        outBuffer.append(contentsOf: bytes)
        drainOut()
    }

    /// Move any pre-fd bytes into the write buffer once `master` is up. Called on
    /// `ioQueue` after a bridge sets `master`.
    private func flushPending() {
        guard master >= 0, !pendingInbound.isEmpty else { return }
        outBuffer.insert(contentsOf: pendingInbound, at: 0)   // pre-fd bytes come first
        pendingInbound = []
        drainOut()
    }

    /// Write as much of `outBuffer` as `master` accepts; on EAGAIN, stop and arm
    /// a write source to finish when the fd is writable. Never spins/blocks.
    private func drainOut() {
        guard master >= 0 else { return }
        while !outBuffer.isEmpty {
            let n = outBuffer.withUnsafeBytes { Darwin.write(master, $0.baseAddress, outBuffer.count) }
            if n > 0 {
                outBuffer.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armWriteSource(); return
            } else {
                return   // fd error; the read pump / channel close drives teardown
            }
        }
        writeSource?.cancel(); writeSource = nil   // fully drained
    }

    private func armWriteSource() {
        guard writeSource == nil, master >= 0 else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: master, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.drainOut() }
        writeSource = src
        src.resume()
    }

    // MARK: PTY child

    private func startMenu(context: ChannelHandlerContext, wantReply: Bool) {
        guard !started else { return }
        started = true
        let channel = context.channel

        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let home = NSHomeDirectory()
        let env = ["TERM=\(term)",
                   "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
                   "HOME=\(home)", "USER=\(user)", "LOGNAME=\(user)",
                   "LANG=en_US.UTF-8"]
        let (pid, masterFD) = PTYSpawn.spawn(path: menuExe,
                                             argv: [menuExe, "__remote-menu"],
                                             env: env, win: &win)
        guard pid > 0, masterFD >= 0 else {
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }
        master = masterFD
        childPID = pid
        if wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }

        // Non-blocking master + a read pump that forwards PTY output to the client.
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1 << 15)
            let n = Darwin.read(masterFD, &buf, buf.count)
            if n > 0 {
                var bb = channel.allocator.buffer(capacity: n)
                bb.writeBytes(buf[0..<n])
                self.pumpWrite(channel, bb)
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK) {
                self.finishAfterDrain(channel: channel, pid: pid, master: masterFD)
            }
        }
        readSource = src
        src.resume()
    }

    // MARK: Fat-client control bridge

    /// Bridge the SSH channel to the app's owner-only control socket: no PTY, no
    /// menu — the channel becomes a raw byte pipe to `control.sock`, so the
    /// fat client speaks the existing control-plane HTTP API (state polling,
    /// commands, and the hijacked interactive-exec pump for terminals) over SSH.
    /// The SSH `authorized_keys` gate stands in for the socket's owner-only
    /// (0600) file mode. Reuses the same read-pump machinery as the menu path,
    /// with `childPID = -1` so teardown/finish skip the process reap.
    private func startControlBridge(context: ChannelHandlerContext, wantReply: Bool) {
        guard !started else { return }
        started = true
        let channel = context.channel

        let sockFD = Self.connectUnix(path: controlSocketPath)
        guard sockFD >= 0 else {
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }
        master = sockFD
        // Non-blocking BEFORE the flush so the write path can't block on a full
        // send buffer. Then flush anything the client pipelined ahead of the
        // bridge coming up (e.g. an exec immediately followed by an HTTP request
        // on the same channel) — without this a request that beats the
        // control-socket connect is stranded in pendingInbound and never sent.
        let flags = fcntl(sockFD, F_GETFL)
        _ = fcntl(sockFD, F_SETFL, flags | O_NONBLOCK)
        ioQueue.async { [weak self] in self?.flushPending() }
        childPID = -1
        if wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }

        // Read pump that forwards the fd's output to the client, identical in
        // shape to the PTY pump.
        let src = DispatchSource.makeReadSource(fileDescriptor: sockFD, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1 << 15)
            let n = Darwin.read(sockFD, &buf, buf.count)
            if n > 0 {
                var bb = channel.allocator.buffer(capacity: n)
                bb.writeBytes(buf[0..<n])
                self.pumpWrite(channel, bb)
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK) {
                self.finishAfterDrain(channel: channel, pid: -1, master: sockFD)
            }
        }
        readSource = src
        src.resume()
    }

    /// Bridge the SSH channel to a TCP connection to a guest VM (`ip:port`) on
    /// this host's vmnet subnet — the raw pipe a fat client uses to reach the
    /// remote workspace subnet. Restricted to the vmnet subnet (guest VMs only,
    /// never the gateway/host or arbitrary internet hosts). Reuses the same
    /// byte-pump machinery as the control bridge.
    private func startForwardBridge(context: ChannelHandlerContext, wantReply: Bool,
                                    ip: String, port: Int) {
        guard !started else { return }
        started = true
        let channel = context.channel

        // Only allow forwarding to a guest on the vmnet subnet.
        let subnet = SandboxEngine.VMNetSwitch.shared.subnet
        FatClientLog.log("forward: request \(ip):\(port) subnet=\(subnet?.cidrString ?? "nil") guest=\(subnet?.containsGuest(ip) ?? false)")
        guard let subnet, subnet.containsGuest(ip), let resolver = forwardResolver else {
            SupplyChainLog.shared.record("[remote] refused forward to \(ip):\(port) — not a guest on the vmnet subnet.")
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }

        // Resolve the guest fd asynchronously (vsock connect to the guest's
        // loopback-relay). Hop back to the channel's event loop to wire it up.
        let el = channel.eventLoop
        resolver(ip, port) { [weak self] fd in
            el.execute {
                guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
                FatClientLog.log("forward: resolver \(ip):\(port) -> fd=\(fd)")
                self.wireResolvedFD(channel: channel, wantReply: wantReply, fd: fd)
            }
        }
    }

    /// Multiplexed UDP tunnel to a guest: the resolver dials the guest's loopback
    /// relay in UDP mode; this channel carries length-prefixed datagrams. Same
    /// subnet restriction + byte pump as the TCP forward bridge.
    private func startUDPForwardBridge(context: ChannelHandlerContext, wantReply: Bool, ip: String) {
        guard !started else { return }
        started = true
        let channel = context.channel
        let subnet = SandboxEngine.VMNetSwitch.shared.subnet
        guard let subnet, subnet.containsGuest(ip), let resolver = udpForwardResolver else {
            SupplyChainLog.shared.record("[remote] refused forward-udp to \(ip) — not a guest on the vmnet subnet.")
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }
        let el = channel.eventLoop
        resolver(ip) { [weak self] fd in
            el.execute {
                guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
                FatClientLog.log("forward-udp: resolver \(ip) -> fd=\(fd)")
                self.wireResolvedFD(channel: channel, wantReply: wantReply, fd: fd)
            }
        }
    }

    /// Bridge the SSH channel to the workspace agent's browser-MCP stream: the
    /// resolver splices the guest's vsock-5830 JSON-RPC to an fd, which this
    /// channel byte-pumps to the fat client's own BrowserMCPServer. Same
    /// machinery as the forward bridge (async-resolved fd).
    private func startBrowserMCPBridge(context: ChannelHandlerContext, wantReply: Bool, vm: String) {
        guard !started else { return }
        started = true
        let channel = context.channel
        guard let resolver = browserMCPResolver else {
            SupplyChainLog.shared.record("[remote] refused browser-mcp \(vm) — no resolver.")
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }
        let el = channel.eventLoop
        resolver(vm) { [weak self] fd in
            el.execute {
                guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
                FatClientLog.log("browser-mcp: resolver \(vm) -> fd=\(fd)")
                self.wireResolvedFD(channel: channel, wantReply: wantReply, fd: fd)
            }
        }
    }

    /// Wire an async-resolved fd as this channel's byte-pump peer (shared by the
    /// forward and browser-mcp bridges). Runs on the channel event loop.
    private func wireResolvedFD(channel: Channel, wantReply: Bool, fd: Int32) {
        guard fd >= 0 else {
            if wantReply { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            channel.close(promise: nil)
            return
        }
        self.master = fd
        self.childPID = -1
        // Non-blocking before flushing pre-fd bytes, so the write path can't block.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        ioQueue.async { [weak self] in self?.flushPending() }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1 << 15)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                var bb = channel.allocator.buffer(capacity: n)
                bb.writeBytes(buf[0..<n])
                self.pumpWrite(channel, bb)
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK) {
                self.finishAfterDrain(channel: channel, pid: -1, master: fd)
            }
        }
        self.readSource = src
        src.resume()
    }

    /// Connect a blocking AF_UNIX stream socket to `path`. Returns -1 on failure.
    private static func connectUnix(path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { Darwin.close(fd); return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { Darwin.close(fd); return -1 }
        return fd
    }

    private func applyWinsize() {
        guard master >= 0 else { return }
        var w = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &w)
    }

    /// Child exited (PTY EOF): reap it, report exit status, close the channel.
    private func finish(channel: Channel, pid: pid_t, master: Int32) {
        guard !terminated else { return }
        terminated = true
        readSource?.cancel()
        readSource = nil
        Darwin.close(master)
        var status: Int32 = 0
        if pid > 0 { waitpid(pid, &status, 0) }
        let code = (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : 0
        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: code))
                .whenComplete { _ in channel.close(promise: nil) }
        }
    }

    /// Client disconnected: kill the child and clean up.
    private func teardown(pid: pid_t, master: Int32) {
        guard !terminated else { return }
        terminated = true
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if master >= 0 { Darwin.close(master) }
        if pid > 0 {
            kill(pid, SIGHUP)
            var st: Int32 = 0
            waitpid(pid, &st, WNOHANG)
        }
    }
}

// MARK: - PTY spawn

enum PTYSpawn {
    /// forkpty + execve. All C arrays are built before the fork so the child
    /// only calls execve (async-signal-safe) — the standard safe pattern in a
    /// multithreaded process.
    static func spawn(path: String, argv: [String], env: [String],
                      win: inout winsize) -> (pid_t, Int32) {
        let cPath = strdup(path)
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)
        defer {
            free(cPath)
            for p in cArgv where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }

        var master: Int32 = 0
        var w = win
        let pid = cArgv.withUnsafeBufferPointer { argvPtr in
            cEnv.withUnsafeBufferPointer { envPtr -> pid_t in
                let p = forkpty(&master, nil, nil, &w)
                if p == 0 {
                    // Child — only async-signal-safe calls until exec.
                    // Close descriptors inherited from the app (sockets, the
                    // listening fd, etc.); forkpty already wired the slave to
                    // 0/1/2. macOS has no closefrom(), so loop.
                    var fd = Int32(3)
                    let maxFD = getdtablesize()
                    while fd < maxFD { Darwin.close(fd); fd += 1 }
                    execve(cPath, argvPtr.baseAddress!, envPtr.baseAddress!)
                    _exit(127)
                }
                return p
            }
        }
        if pid > 0 {
            // Don't leak the PTY master into any other child we might fork.
            _ = fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC)
        }
        return (pid, pid > 0 ? master : -1)
    }
}
