import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
#if canImport(Darwin)
import Darwin
#endif

// MARK: - In-process SSH dialer (fat client)
//
// A swift-nio-ssh replacement for the system-`ssh`-subprocess transport that
// FatClientRemote.swift used to run: one SSH connection per remote host, and
// one exec child channel per dial, bridged to a socketpair so the caller still
// gets a plain bidirectional fd — `ControlClient.request`/`openStream` and the
// framed PTY pump run over it unchanged.
//
// This is now the transport on BOTH platforms (iOS never had a Process to
// spawn; macOS moved over so the two behave identically). Compared to
// ssh+ControlMaster, all channels multiplex over a single connection —
// including interactive attaches, which is safe here because the OpenSSH mux
// quirk (buffering a multiplexed channel's spontaneous server→client output)
// is specific to the ControlMaster implementation, not to SSH channel
// multiplexing itself.

// MARK: ed25519 key material helpers

/// SSH wire-format helpers for ed25519 keys (the only key type both sides of
/// the fat-client pairing use).
enum SSHKeyWire {
    /// string(algo) || string(raw pub) — the blob base64-encoded in an OpenSSH
    /// public line, and the input of the SHA256 fingerprint.
    static func ed25519Blob(_ pub: Curve25519.Signing.PublicKey) -> Data {
        var d = Data()
        func sshString(_ bytes: Data) {
            var be = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            d.append(bytes)
        }
        sshString(Data("ssh-ed25519".utf8))
        sshString(pub.rawRepresentation)
        return d
    }

    static func opensshPublicLine(_ pub: Curve25519.Signing.PublicKey, comment: String) -> String {
        "ssh-ed25519 \(ed25519Blob(pub).base64EncodedString()) \(comment)"
    }

    /// `SHA256:…` (unpadded base64), the `ssh-keygen -l` fingerprint format.
    static func fingerprint(ofBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Fingerprint of an OpenSSH public line ("[host] algo b64 [comment]").
    /// Tolerates a leading known_hosts host token, like the enroll parser.
    static func fingerprint(ofPublicLine line: String) -> String? {
        var tokens = line.split(separator: " ").map(String.init)
        if let first = tokens.first, !first.hasPrefix("ssh-"), !first.hasPrefix("ecdsa-") {
            tokens.removeFirst()
        }
        guard tokens.count >= 2, let blob = Data(base64Encoded: tokens[1]) else { return nil }
        return fingerprint(ofBlob: blob)
    }

    /// The wire blob of a NIOSSH host key, via its OpenSSH string form (the
    /// only public serialization NIOSSH offers).
    static func blob(of key: NIOSSHPublicKey) -> Data? {
        let line = String(openSSHPublicKey: key)
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        return Data(base64Encoded: tokens[1])
    }
}

// MARK: Known-hosts pin store (pure Swift)

/// TOFU pin store over the same `known_hosts` line format the macOS transport
/// keeps (`<host-token> <algo> <b64> `), but read/written in-process — no
/// `ssh-keygen -R`. Host token is `host` (port 22), `[host]:port`, or a peer
/// alias (`bromure-peer-<deviceID>`).
struct KnownHostsStore {
    let url: URL

    static func hostToken(address: String, port: Int) -> String {
        port == 22 ? address : "[\(address)]:\(port)"
    }

    private func lines() -> [String] {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return body.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// The pinned key line for a host token, if any.
    func pinnedLine(token: String) -> String? {
        lines().first { $0.split(separator: " ").first.map(String.init) == token }
    }

    func pinnedKey(token: String) -> NIOSSHPublicKey? {
        guard let line = pinnedLine(token: token) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return try? NIOSSHPublicKey(openSSHPublicKey: String(parts[1]))
    }

    /// Replace any prior entry for `token` with `keyLine`'s key material.
    func pin(token: String, keyLine: String) {
        let parts = keyLine.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        var kept = lines().filter { $0.split(separator: " ").first.map(String.init) != token }
        kept.append("\(token) \(parts[1])")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func hasPin(token: String) -> Bool { pinnedLine(token: token) != nil }
}

// MARK: - Connection pool

/// Errors out of `SSHDialer.ensureConnection`, classified so `probe` can map
/// them onto `RemoteProbe` exactly like the ssh-stderr sniffing did.
enum SSHDialError: Error {
    case unreachable(String)
    case authFailed
    case hostKeyChanged
}

/// One SSH connection per remote host, exec channels on demand. Thread-safe;
/// dials block the calling (background) queue, never an event loop.
final class SSHDialer: @unchecked Sendable {
    static let shared = SSHDialer()

    private init() {
        // A P2P path change or a dead loopback shim invalidates every pooled
        // connection — they all ride the shim's loopback port, which is gone or
        // renumbered. Drop them so the next dial builds fresh instead of blocking
        // ~12s on a half-open socket whose channel.isActive still reads true.
        // Closing a connection also EOFs any request wedged reading on it, so a
        // stuck poll/attach fails fast and retries at once. The mirror poll and
        // every terminal observe the same notification and rebuild immediately.
        NotificationCenter.default.addObserver(
            forName: .bromureP2PPathChanged, object: nil, queue: nil) { [weak self] _ in
            self?.closeAll()
        }
    }

    /// Why the last dial to a host failed, when SSH said so: an auth or
    /// host-key verdict is an answer (it needs the user), anything else is
    /// transport (a Wi-Fi drop, the remote restarting) that heals by
    /// retrying. Cleared by the next successful dial. Lets a mirror that was
    /// already connected tell "reconnecting…" from "this Mac's key is no
    /// longer authorized".
    enum DialVerdict: Equatable { case authFailed, hostKeyChanged, unreachable }
    private var lastVerdicts: [UUID: DialVerdict] = [:]

    func lastDialVerdict(hostID: UUID) -> DialVerdict? {
        lock.lock(); defer { lock.unlock() }
        return lastVerdicts[hostID]
    }

    private func noteDialFailure(_ hostID: UUID, _ error: SSHDialError?) {
        let v: DialVerdict?
        switch error {
        case nil: v = nil
        case .authFailed?: v = .authFailed
        case .hostKeyChanged?: v = .hostKeyChanged
        case .unreachable?: v = .unreachable
        }
        lock.lock(); lastVerdicts[hostID] = v; lock.unlock()
    }

    /// Close and drop every pooled connection (all hosts + lanes).
    func closeAll() {
        lock.lock()
        let dead = connections
        connections.removeAll()
        lock.unlock()
        if !dead.isEmpty {
            FatClientLog.log("nio-dial: path changed — dropping \(dead.count) pooled connection(s)")
        }
        dead.values.forEach { $0.close() }
    }

    /// Close every pooled connection to one host (all lanes, all endpoints).
    /// Called when the user leaves a host (back to the server list): stop() alone
    /// closed the P2P shim but LEFT these SSH connections pooled and alive, so the
    /// server kept their forwarded control-socket fds → a full ctrl+term pair
    /// leaked per connect→back cycle. Closing them here drops the SSH connections
    /// so the server reaps promptly (its channel closeFuture fires).
    func closeHost(_ hostID: UUID) {
        let prefix = hostID.uuidString + "|"
        lock.lock()
        let dead = connections.filter { $0.key.hasPrefix(prefix) }
        for k in dead.keys { connections[k] = nil }
        lock.unlock()
        if !dead.isEmpty {
            FatClientLog.log("nio-dial: leaving host — closing \(dead.count) pooled connection(s)")
        }
        dead.values.forEach { $0.close() }
    }

    /// Where host-key pins live. Configured once at startup by the platform's
    /// `RemoteTransport` (both macOS and iOS point it at their own
    /// remote-client/known_hosts).
    var knownHostsURL: URL?
    /// Loads the client's ed25519 identity for public-key auth. Configured by
    /// the platform transport layer.
    var loadClientKey: (() -> Curve25519.Signing.PrivateKey?)?

    private let lock = NSLock()
    private var connections: [String: SSHConnection] = [:]
    /// One build at a time per lane: a burst of dials to a lane with no live
    /// connection (a browser opening 30 sockets) waits for the first build
    /// and shares it, instead of each running its own SSH handshake.
    private var buildLocks: [String: NSLock] = [:]
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Key by endpoint, not host id: a peer host's resolved loopback endpoint
    /// changes per session, and a stale connection to a dead endpoint must not
    /// shadow a fresh one.
    private func poolKey(_ host: RemoteHost, lane: String) -> String {
        "\(host.id.uuidString)|\(host.user)@\(host.address):\(host.port)|\(lane)"
    }

    /// A live (or newly established) connection to `host`. `strict` = the host
    /// key MUST match an existing pin (probe's MITM check); otherwise
    /// accept-new semantics: pin on first contact, refuse a changed key.
    func ensureConnection(host: RemoteHost, strict: Bool = false, lane: String = "") throws -> SSHConnection {
        let key = poolKey(host, lane: lane)
        lock.lock()
        if let c = connections[key], c.isAlive {
            lock.unlock()
            return c
        }
        let buildLock = buildLocks[key] ?? NSLock()
        buildLocks[key] = buildLock
        lock.unlock()
        buildLock.lock()
        defer { buildLock.unlock() }
        // Another dial may have built it while we waited.
        lock.lock()
        if let c = connections[key], c.isAlive {
            lock.unlock()
            return c
        }
        connections[key] = nil
        lock.unlock()

        // Timing: a "building" with no matching "built" (or a 12s gap) pinpoints
        // a slow first-terminal open to the SSH connection build.
        FatClientLog.log("nio-dial: building \(host.connectLabel) lane=\(lane.isEmpty ? "ctrl" : lane)")
        let conn = try SSHConnection(host: host, group: group, strictHostKey: strict,
                                     knownHosts: knownHostsURL.map(KnownHostsStore.init),
                                     clientKey: loadClientKey?())
        FatClientLog.log("nio-dial: built \(host.connectLabel) lane=\(lane.isEmpty ? "ctrl" : lane)")
        lock.lock()
        connections[key] = conn
        lock.unlock()
        conn.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.connections[key] === conn { self.connections[key] = nil }
            self.lock.unlock()
        }
        return conn
    }

    /// Open an exec channel for `verb` and hand back a plain bidirectional fd,
    /// exactly like `SSHTunnel.dial`. Retries once through a fresh connection
    /// if the pooled one turns out dead. Returns nil on failure (the caller's
    /// request/stream errors out the same way it does when ssh dies).
    func dial(host: RemoteHost, verb: String, lane: String = "") -> Int32? {
        for attempt in 0..<2 {
            let conn: SSHConnection
            do {
                conn = try ensureConnection(host: host, lane: lane)
            } catch {
                noteDialFailure(host.id, (error as? SSHDialError) ?? .unreachable("\(error)"))
                return nil
            }
            if let fd = conn.openVerbChannel(verb) { noteDialFailure(host.id, nil); return fd }
            // Channel open failed on a connection that claimed to be alive —
            // drop it and retry once on a fresh one.
            conn.close()
            if attempt == 1 { noteDialFailure(host.id, .unreachable("channel open failed")); return nil }
        }
        return nil
    }

    func closeConnection(host: RemoteHost) {
        // Close every lane for this host (control + terminal streams).
        let base = "\(host.id.uuidString)|\(host.user)@\(host.address):\(host.port)|"
        lock.lock()
        let dead = connections.filter { $0.key.hasPrefix(base) }
        for k in dead.keys { connections[k] = nil }
        lock.unlock()
        dead.values.forEach { $0.close() }
    }

    // MARK: Host-key scan (ssh-keyscan replacement)

    /// Fetch the remote's host key by starting a handshake and capturing the
    /// key the server presents, then aborting before authentication — no
    /// credential is ever offered. Returns the known_hosts-style line + the
    /// SHA256 fingerprint, like `ssh-keyscan | ssh-keygen -lf`.
    func scanHostKey(address: String, port: Int) -> HostKeyInfo? {
        final class Capture: NIOSSHClientServerAuthenticationDelegate {
            struct Abort: Error {}
            let onKey: (NIOSSHPublicKey) -> Void
            init(onKey: @escaping (NIOSSHPublicKey) -> Void) { self.onKey = onKey }
            func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
                onKey(hostKey)
                validationCompletePromise.fail(Abort())   // abort pre-auth
            }
        }
        final class NoAuth: NIOSSHClientUserAuthenticationDelegate {
            func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
                nextChallengePromise.succeed(nil)
            }
        }
        let captured = CapturedKeyBox()
        // Signalled the moment the server presents its host key (the ECDH reply,
        // one KEX round trip in). We close on that — see below.
        let keyReady = DispatchSemaphore(value: 0)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: NoAuth(),
                                serverAuthDelegate: Capture { captured.set($0); keyReady.signal() })),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(30))
        guard let channel = try? bootstrap.connect(host: address, port: port).wait() else { return nil }
        // Close as soon as the host key is in hand, rather than waiting for the
        // connection to tear down on its own. Failing the validation promise
        // aborts authentication, but swift-nio-ssh does NOT translate that into a
        // prompt channel close — the socket lingered until the fixed backstop
        // fired, so every host-key scan (the "Verifying …" phase) stalled ~20-30 s
        // even though the key had already arrived in the first KEX round trip.
        // Wait for the key (bounded, for a silent/half-open endpoint), then close
        // the channel ourselves.
        let gotKey = keyReady.wait(timeout: .now() + 15) == .success
        channel.close(promise: nil)
        guard gotKey, let key = captured.get(), let blob = SSHKeyWire.blob(of: key) else { return nil }
        let token = KnownHostsStore.hostToken(address: address, port: port)
        return HostKeyInfo(line: "\(token) \(String(openSSHPublicKey: key))",
                           fingerprint: SSHKeyWire.fingerprint(ofBlob: blob))
    }
}

/// Thread-safe one-shot box for the scanned host key (set on the event loop,
/// read from the scanning thread after close).
private final class CapturedKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: NIOSSHPublicKey?
    func set(_ k: NIOSSHPublicKey) { lock.lock(); if key == nil { key = k }; lock.unlock() }
    func get() -> NIOSSHPublicKey? { lock.lock(); defer { lock.unlock() }; return key }
}

/// Head-of-pipeline watchdog that aborts a handshake only when it *stalls* —
/// no inbound bytes for `idle` — rather than on a fixed wall-clock deadline.
/// It sits ahead of `NIOSSHHandler`, so it sees every inbound packet (plaintext
/// version exchange, then the encrypted KEX / auth traffic), and each read
/// reschedules the idle timer. A slow-but-progressing link therefore keeps
/// resetting the timer and survives up to the caller's global envelope; only a
/// genuinely silent endpoint is cut. This is the RTT-adaptive part: it keys off
/// progress, not a guess at how long a good handshake "should" take — which is
/// what makes it safe on a terrible link (a plane, a congested relay) where a
/// fixed 12 s deadline would drop a connection that was still working.
///
/// Handshake-only: the caller removes it once auth completes, so ordinary idle
/// time on the live connection is never mistaken for a stall.
final class HandshakeStallWatchdog: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let idle: TimeAmount
    private let label: String
    private var task: Scheduled<Void>?

    init(idle: TimeAmount, label: String) { self.idle = idle; self.label = label }

    private func arm(_ context: ChannelHandlerContext) {
        task?.cancel()
        let channel = context.channel
        let secs = idle.nanoseconds / 1_000_000_000
        let label = self.label
        task = context.eventLoop.scheduleTask(in: idle) {
            FatClientLog.log("nio-conn: handshake stalled (no data for \(secs)s) \(label) — closing")
            channel.close(promise: nil)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { arm(context) }
    }
    func channelActive(context: ChannelHandlerContext) {
        arm(context); context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        arm(context)                       // progress — push the deadline out
        context.fireChannelRead(data)
    }
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel(); task = nil; context.fireChannelInactive()
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        task?.cancel(); task = nil
    }
}

/// Last-inbound-byte clock for one SSH connection, shared between the pipeline
/// handler (event loop) and the dial path (any thread).
final class InboundActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.lock(); last = Date(); lock.unlock() }

    func secondsSinceLastInbound() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

/// Pass-through inbound handler that stamps `InboundActivity` on every read.
final class InboundActivityHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private let activity: InboundActivity
    init(_ activity: InboundActivity) { self.activity = activity }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        activity.touch()
        context.fireChannelRead(data)
    }
}

/// A one-shot timeout that may re-arm itself; only touched on one event loop.
final class RescheduledTimeout: @unchecked Sendable {
    var task: Scheduled<Void>?
    var done = false
}

/// Debug/test knob (`LinkSimulation`): sits at the head of an SSH connection's
/// pipeline and makes the socket behave like a slow WAN — each inbound read
/// and outbound write is delivered half an RTT (+ jitter) later, in order,
/// and inbound is paced to a bandwidth cap. Everything above it (KEX, auth,
/// channel opens, every request) sees the simulated link.
final class SimulatedLinkHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let oneWayNanos: Int64
    private let jitterNanos: Int64
    private let bytesPerSecond: Int64
    /// Delivery clocks, so jitter never reorders and pacing queues.
    private var inboundAt = NIODeadline.uptimeNanoseconds(0)
    private var outboundAt = NIODeadline.uptimeNanoseconds(0)
    private var inboundWireFree = NIODeadline.uptimeNanoseconds(0)

    init(_ sim: LinkSimulation) {
        oneWayNanos = Int64(sim.rttMs) * 1_000_000 / 2
        jitterNanos = Int64(sim.jitterMs) * 1_000_000
        bytesPerSecond = Int64(sim.kbps) * 1024
    }

    private func jitter() -> Int64 { jitterNanos > 0 ? Int64.random(in: 0...jitterNanos) : 0 }

    /// When an inbound chunk of `bytes` that arrives `now` is handed up.
    func inboundDeadline(now: NIODeadline, bytes: Int) -> NIODeadline {
        var leaves = now
        if bytesPerSecond > 0 {
            let start = max(now, inboundWireFree)
            inboundWireFree = start + .nanoseconds(Int64(bytes) * 1_000_000_000 / bytesPerSecond)
            leaves = inboundWireFree
        }
        let at = max(leaves + .nanoseconds(oneWayNanos + jitter()), inboundAt + .nanoseconds(1))
        inboundAt = at
        return at
    }

    func outboundDeadline(now: NIODeadline) -> NIODeadline {
        let at = max(now + .nanoseconds(oneWayNanos + jitter()), outboundAt + .nanoseconds(1))
        outboundAt = at
        return at
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        let at = inboundDeadline(now: context.eventLoop.now, bytes: buf.readableBytes)
        let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(deadline: at) {
            let (ctx, me) = bound.value
            ctx.fireChannelRead(me.wrapInboundOut(buf))
            ctx.fireChannelReadComplete()
        }
    }

    /// Read-complete is fired per delayed read instead.
    func channelReadComplete(context: ChannelHandlerContext) {}

    /// EOF follows the data still in flight.
    func channelInactive(context: ChannelHandlerContext) {
        let at = max(context.eventLoop.now, inboundAt + .nanoseconds(1))
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(deadline: at) { bound.value.fireChannelInactive() }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let at = outboundDeadline(now: context.eventLoop.now)
        let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(deadline: at) {
            let (ctx, me) = bound.value
            ctx.writeAndFlush(me.wrapOutboundOut(buf), promise: promise)
        }
    }

    /// Each delayed write flushes itself when it's delivered.
    func flush(context: ChannelHandlerContext) {}
}

// MARK: - One SSH connection

/// A single authenticated SSH connection; `openVerbChannel` multiplexes exec
/// channels over it.
final class SSHConnection: @unchecked Sendable {
    /// Abort the handshake only after this long with NO inbound bytes — a
    /// stall, not a slow-but-alive link. Reset on every inbound packet, so a
    /// bad connection that keeps making progress is never dropped on a fixed
    /// timer. (See `HandshakeStallWatchdog`.)
    static let handshakeIdle: TimeAmount = .seconds(20)
    /// Hard backstop on the whole handshake+auth, for the pathological case of
    /// data trickling in forever without the session ever coming up.
    static let handshakeEnvelope: TimeAmount = .minutes(5)
    static let watchdogName = "bromure-handshake-watchdog"

    let channel: Channel
    private let host: RemoteHost
    var isAlive: Bool { channel.isActive }
    /// When the connection last received bytes (any channel). A channel open
    /// that's slow while bytes keep arriving is a busy slow link, not a
    /// wedged connection — see `openVerbChannel`.
    let activity: InboundActivity

    /// Synchronous connect + handshake + auth. Throws `SSHDialError`.
    init(host: RemoteHost, group: EventLoopGroup, strictHostKey: Bool,
         knownHosts: KnownHostsStore?, clientKey: Curve25519.Signing.PrivateKey?) throws {
        self.host = host
        guard let clientKey else { throw SSHDialError.authFailed }
        FatClientLog.log("nio-conn: offering key \(SSHKeyWire.fingerprint(ofBlob: SSHKeyWire.ed25519Blob(clientKey.publicKey))) \(host.connectLabel)")

        let token = host.hostKeyAlias ?? KnownHostsStore.hostToken(address: host.address, port: host.port)
        let outcome = HandshakeOutcome()
        let authDelegate = SingleKeyAuthDelegate(username: host.user,
                                                 key: NIOSSHPrivateKey(ed25519Key: clientKey)) {
            outcome.flag(.authRejected)
        }
        let hostKeyDelegate = TOFUHostKeyDelegate(store: knownHosts, token: token,
                                                  strict: strictHostKey) {
            outcome.flag(.hostKeyChanged)
        }
        let connLabel = host.connectLabel
        let activity = InboundActivity()
        self.activity = activity
        let sim = LinkSimulation.current
        if sim.isActive {
            FatClientLog.log("nio-conn: SIMULATED slow link (\(sim.label)) \(connLabel)")
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Test knob: a simulated WAN between the socket and SSH.
                    if sim.isActive {
                        try channel.pipeline.syncOperations.addHandler(SimulatedLinkHandler(sim))
                    }
                    try channel.pipeline.syncOperations.addHandler(InboundActivityHandler(activity))
                    // Stall watchdog FIRST (head of the pipeline) so it sees
                    // every inbound packet during KEX/auth and only aborts on a
                    // genuine silence, not a slow link.
                    try channel.pipeline.syncOperations.addHandler(
                        HandshakeStallWatchdog(idle: Self.handshakeIdle, label: connLabel),
                        name: Self.watchdogName)
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostKeyDelegate)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            // Keepalive tolerant of a jittery WAN (the OS default waits two
            // hours idle): first probe after 30 s idle, then every 15 s, drop
            // after 4 unanswered — ~90 s for a silently dead direct path. The
            // poll keeps a live mirror from ever being idle that long, so
            // this only reaps connections nothing is using. (A peer host's
            // connection is loopback to the P2P shim; its network leg is
            // tuned in P2PTransport.)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 30)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 15)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 4)
            .connectTimeout(.seconds(30))

        do {
            channel = try bootstrap.connect(host: host.address, port: host.port).wait()
        } catch {
            throw SSHDialError.unreachable(Self.firstLine("\(error)"))
        }
        FatClientLog.log("nio-conn: tcp up \(host.connectLabel) — handshaking")

        // The NIOSSH handshake+auth completes asynchronously after connect.
        // Prove the session end-to-end by opening (and immediately closing) a
        // probe child channel: its creation only succeeds once auth is done.
        // Auth/host-key failures surface through the delegates' flags.
        do {
            let ch = channel   // local, so the loop closures don't capture self
            let probe = ch.eventLoop.makePromise(of: Channel.self)
            // Bound the handshake+auth. The primary guard is the stall
            // watchdog installed at the head of the pipeline: it aborts only
            // after `handshakeIdle` of NO inbound bytes (a silent endpoint /
            // dead relay), so a slow-but-progressing link — a bad plane or
            // satellite connection — keeps resetting it and is NOT dropped on
            // an arbitrary deadline. This `envelope` is only a hard backstop
            // against data trickling in forever without the session coming up.
            let envelope = ch.eventLoop.scheduleTask(in: Self.handshakeEnvelope) {
                ch.close(promise: nil)
            }
            // `syncOperations` MUST run on the event loop — look the handler up
            // and open the probe channel there, not on this background thread
            // (doing it off-loop trips NIO's preconditionInEventLoop).
            ch.eventLoop.execute {
                do {
                    let handler = try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    handler.createChannel(probe, channelType: .session) { child, _ in
                        child.eventLoop.makeSucceededVoidFuture()
                    }
                } catch {
                    probe.fail(error)
                }
            }
            let child = try probe.futureResult.wait()
            envelope.cancel()
            // Handshake done: drop the stall watchdog so ordinary idle time on
            // the live connection isn't mistaken for a stall (it fires on
            // inbound silence, which is normal once connected).
            _ = ch.pipeline.removeHandler(name: Self.watchdogName)
            FatClientLog.log("nio-conn: handshake+auth OK \(host.connectLabel)")
            child.close(promise: nil)
            // A dropped connection (peer reset, server exit) never goes
            // through close(): its spare control channel's fd goes here.
            ch.closeFuture.whenComplete { [weak self] _ in self?.releaseSpare() }
        } catch {
            let flagged = outcome.get()
            channel.close(promise: nil)
            switch flagged {
            case .authRejected:   throw SSHDialError.authFailed
            case .hostKeyChanged: throw SSHDialError.hostKeyChanged
            case nil:             throw SSHDialError.unreachable(Self.firstLine("\(error)"))
            }
        }
    }

    /// A control channel opened ahead of need, its exec already sent: the
    /// next control request rides it at once instead of paying the
    /// channel-open round trip (~170 ms each way across the Pacific). The
    /// server's control bridge waits for a request without a timeout, so an
    /// idle spare costs nothing but a parked socket; one per connection
    /// (= per lane).
    private let spareLock = NSLock()
    private var spareControlFD: Int32?
    /// Set once the connection is gone: a spare opened after that (a refill
    /// racing the drop) is closed instead of kept.
    private var spareReleased = false

    /// Open an exec child channel for `verb`, bridge it to a socketpair, and
    /// return the caller's fd. The control verb is served from the spare when
    /// there is a live one, and a new spare is opened behind it.
    func openVerbChannel(_ verb: String) -> Int32? {
        guard verb == FatClient.controlVerb, !Self.noPrewarm else { return openFreshChannel(verb) }
        spareLock.lock()
        let spare = spareControlFD
        spareControlFD = nil
        spareLock.unlock()
        let fd: Int32?
        if let spare, Self.spareIsUsable(spare) {
            fd = spare
        } else {
            if let spare { Darwin.close(spare) }
            fd = openFreshChannel(verb)
        }
        if fd != nil { refillSpare() }
        return fd
    }

    private func refillSpare() {
        guard isAlive, let fd = openFreshChannel(FatClient.controlVerb) else { return }
        spareLock.lock()
        let released = spareReleased
        let old = released ? nil : spareControlFD
        if !released { spareControlFD = fd }
        spareLock.unlock()
        if let old { Darwin.close(old) }
        if released { Darwin.close(fd) }
    }

    /// Close the spare control channel's fd, for good: from close(), the
    /// pool's closeFuture handler (a dropped connection), and deinit.
    func releaseSpare() {
        spareLock.lock()
        let spare = spareControlFD
        spareControlFD = nil
        spareReleased = true
        spareLock.unlock()
        if let spare { Darwin.close(spare) }
    }

    /// Spare fds currently held (tests).
    var heldSpareCount: Int {
        spareLock.lock()
        defer { spareLock.unlock() }
        return spareControlFD == nil ? 0 : 1
    }

    deinit { releaseSpare() }

    /// Test knobs (A/B on a simulated link): no spare channel / no pipelining.
    static let noPrewarm = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_NO_PREWARM"] != nil
    static let noPipeline = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_NO_PIPELINE"] != nil

    /// A spare is usable while nothing is waiting to be read on it: the
    /// control bridge never speaks first, so readable = EOF (its channel
    /// failed to open, or the connection went away).
    static func spareIsUsable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, 0)
        return r == 0
    }

    /// Open an exec child channel for `verb`, bridge it to a socketpair, and
    /// return the caller's fd immediately (bytes the caller writes are sent
    /// right behind the exec — the server buffers them until its bridge is
    /// up). Nil if the socketpair or the child-channel open fails outright.
    private func openFreshChannel(_ verb: String) -> Int32? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            FatClientLog.log("nio-dial: socketpair FAILED errno=\(errno)")
            return nil
        }
        let appFD = fds[0], pumpFD = fds[1]
        // Never inherited by a spawned child (forkpty, Process): a child
        // holding either end would keep the bridge — and its channel — open.
        _ = fcntl(appFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pumpFD, F_SETFD, FD_CLOEXEC)
        // Without NOSIGPIPE a peer-closed write raises SIGPIPE and kills the
        // process (no ssh child process to absorb it in this transport).
        var one: Int32 = 1
        _ = setsockopt(appFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(pumpFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let ch = channel
        // Close the pump side exactly once — from whichever fires first, the
        // channel-open failure or the timeout below. Both run on `ch.eventLoop`,
        // so a plain flag is race-free. Once the child's handler holds the fd
        // (its initializer runs at creation, BEFORE the open is confirmed) it
        // is the handler's to close, when the channel goes: closing it here
        // too closed the number twice — the second time someone else's,
        // reused in between, and two links ended up reading one stream (a
        // Sidecar slot seeing `POST …` where its verb should be).
        var pumpClosed = false
        var handlerOwnsPump = false
        func closePump() {
            guard !pumpClosed, !handlerOwnsPump else { return }
            pumpClosed = true
            Darwin.shutdown(pumpFD, SHUT_RDWR)
            Darwin.close(pumpFD)
        }
        // A pooled connection can go half-dead: `isAlive` (channel.isActive) still
        // reports true while the SSH layer is unresponsive, so `createChannel`
        // never resolves — and this transport returns the fd optimistically, so
        // the caller's `request()` then BLOCKS forever reading a response that
        // can't come. That stalled the whole SERIAL poll queue: one action wedged
        // and everything after it showed "Connecting…" until the app restarted.
        // Bound the channel open: on timeout, EOF the app side (the request fails
        // like any dropped connection) and tear the connection down so the NEXT
        // request re-establishes a fresh one instead of reusing the corpse.
        //
        // "Wedged" means SILENT: on a slow link a big transfer on another
        // channel of this connection (up to a 16 MB window of it) can sit
        // ahead of the open confirmation for longer than 15 s while bytes
        // keep flowing. Killing the connection then took that transfer, the
        // poll and every other channel down with it — on a trans-Pacific link
        // that WAS the "Reconnecting…" loop. So the stall timer re-arms while
        // the connection is receiving, up to a hard ceiling.
        let activity = self.activity
        let opened = Date()
        let stall = LinkTimeouts.channelOpenStall
        let timeout = RescheduledTimeout()
        func armOpenTimeout(after: TimeInterval) {
            timeout.task = ch.eventLoop.scheduleTask(in: .milliseconds(Int64(after * 1000))) { [weak self] in
                guard !timeout.done else { return }
                let quiet = activity.secondsSinceLastInbound()
                let waited = Date().timeIntervalSince(opened)
                if quiet < stall, waited < LinkTimeouts.channelOpenCeiling {
                    // Busy, not dead: wait until it's been `stall` quiet.
                    armOpenTimeout(after: max(1, stall - quiet))
                    return
                }
                FatClientLog.log("nio-dial: channel open timed out after \(Int(waited))s "
                    + "(connection quiet \(Int(quiet))s) — dropping wedged connection")
                closePump()
                self?.close()
            }
        }
        armOpenTimeout(after: stall)
        // `syncOperations` (handler lookup + child addHandler) MUST run on the
        // event loop, not this caller's background thread — off-loop it trips
        // NIO's preconditionInEventLoop and crashes.
        ch.eventLoop.execute {
            do {
                let handler = try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                handler.createChannel(promise, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ExecFDPumpHandler(command: verb, fd: pumpFD))
                        handlerOwnsPump = true
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        promise.futureResult.whenComplete { result in
            timeout.done = true
            timeout.task?.cancel()
            // Channel never opened — close the pump side so the app side EOFs.
            if case .failure = result { closePump() }
        }
        return appFD
    }

    func close() {
        releaseSpare()
        channel.close(promise: nil)
    }

    private static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.isEmpty } ?? s
    }
}

/// What went wrong during handshake/auth, flagged from delegate callbacks
/// (which run on the event loop) and read from the connecting thread.
private final class HandshakeOutcome: @unchecked Sendable {
    enum Kind { case authRejected, hostKeyChanged }
    private let lock = NSLock()
    private var kind: Kind?
    func flag(_ k: Kind) { lock.lock(); if kind == nil { kind = k }; lock.unlock() }
    func get() -> Kind? { lock.lock(); defer { lock.unlock() }; return kind }
}

/// Offers the client's ed25519 key exactly once; a second ask means the server
/// rejected it (the same only-reliable-signal pattern as the password
/// bootstrap's delegate).
private final class SingleKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let onRejected: () -> Void
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey, onRejected: @escaping () -> Void) {
        self.username = username
        self.key = key
        self.onRejected = onRejected
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            if offered { onRejected() }
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "",
            offer: .privateKey(.init(privateKey: key))))
    }
}

/// accept-new / strict host-key validation against the pin store: a pinned key
/// must match (mismatch = possible MITM, flagged); an unknown host is pinned
/// on first contact unless `strict`.
private final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    struct Mismatch: Error {}
    struct NoPin: Error {}
    private let store: KnownHostsStore?
    private let token: String
    private let strict: Bool
    private let onMismatch: () -> Void

    init(store: KnownHostsStore?, token: String, strict: Bool, onMismatch: @escaping () -> Void) {
        self.store = store
        self.token = token
        self.strict = strict
        self.onMismatch = onMismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let store else {
            // No pin store configured: refuse rather than silently trust.
            onMismatch()
            validationCompletePromise.fail(NoPin())
            return
        }
        if let pinned = store.pinnedKey(token: token) {
            if pinned == hostKey {
                validationCompletePromise.succeed(())
            } else {
                onMismatch()
                validationCompletePromise.fail(Mismatch())
            }
            return
        }
        if strict {
            onMismatch()
            validationCompletePromise.fail(NoPin())
            return
        }
        store.pin(token: token, keyLine: String(openSSHPublicKey: hostKey))
        validationCompletePromise.succeed(())
    }
}

// MARK: - Exec channel ⇄ fd pump

/// Bridges one exec child channel to the pump side of a socketpair:
/// channel bytes → fd, fd bytes → channel, EOF/close in both directions.
/// Owns (and eventually closes) `fd`.
private final class ExecFDPumpHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let fd: Int32
    /// Serial queue owning all fd writes (channel → fd). Blocking writes here
    /// give natural per-channel backpressure without blocking the event loop:
    /// reads are re-armed only after the previous buffer landed on the fd.
    private let writeQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var fdClosed = false
    private var readerStarted = false
    private let stateLock = NSLock()

    init(command: String, fd: Int32) {
        self.command = command
        self.fd = fd
        self.writeQueue = DispatchQueue(label: "io.bromure.fatclient.nio-pump")
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Manual reads: one in-flight inbound buffer at a time (re-armed from
        // the write queue), so a fast producer can't balloon memory.
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        // A child channel of a connection that drops doesn't reliably get
        // channelInactive (see SSHPTYSessionHandler): closeFuture always
        // fires. Strong capture on purpose, like teardownFD's; it's idempotent.
        context.channel.closeFuture.whenComplete { [self] _ in teardownFD() }
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
        if SSHConnection.noPipeline { return }   // wait for the exec's acceptance
        // Pipelined: the caller's bytes follow the exec at once rather than
        // a round trip later, after its acceptance. Every Bromure server
        // buffers bytes that beat its bridge (RemoteSSHHandlers'
        // pendingInbound, since the first fat client); a refused exec
        // closes the channel and they're dropped with it.
        startFDReader(context: context)
        context.read()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if SSHConnection.noPipeline, !readerStarted {
                startFDReader(context: context)
                context.read()
            }
        case is ChannelFailureEvent:
            context.close(promise: nil)
        case is ChannelEvent where (event as? ChannelEvent) == .inputClosed:
            // Remote sent EOF: flush what's queued, then half-close the pump
            // side so the app's read() returns 0 while its writes still flow.
            writeQueue.async { [fd] in Darwin.shutdown(fd, SHUT_WR) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = channelData.data else {
            context.read()
            return
        }
        // stderr from the verb handler is diagnostics; the byte stream
        // contract is stdout-only (matches ssh's stderr → /dev/null).
        guard channelData.type == .channel else {
            context.read()
            return
        }
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        let loop = context.eventLoop
        let channel = context.channel
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeAllToFD(bytes)
            loop.execute {
                if channel.isActive { channel.read() }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardownFD()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: fd → channel

    private func startFDReader(context: ChannelHandlerContext) {
        readerStarted = true
        let channel = context.channel
        let loop = context.eventLoop
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: writeQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(self.fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                var bb = channel.allocator.buffer(capacity: n)
                bb.writeBytes(buf[0..<n])
                let data = SSHChannelData(type: .channel, data: .byteBuffer(bb))
                loop.execute {
                    channel.writeAndFlush(data, promise: nil)
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                // App closed its end (or hard error): stop reading and send
                // EOF so the remote verb sees its stdin close.
                self.stopFDReader()
                loop.execute {
                    channel.close(mode: .output, promise: nil)
                }
            }
        }
        source.setCancelHandler { }
        stateLock.lock()
        readSource = source
        stateLock.unlock()
        source.resume()
    }

    private func stopFDReader() {
        stateLock.lock()
        let src = readSource
        readSource = nil
        stateLock.unlock()
        src?.cancel()
    }

    private func writeAllToFD(_ bytes: [UInt8]) {
        stateLock.lock()
        let closed = fdClosed
        stateLock.unlock()
        guard !closed else { return }
        bytes.withUnsafeBufferPointer { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n > 0 {
                    base += n
                    remaining -= n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    return   // peer gone; inbound teardown follows via close
                }
            }
        }
    }

    /// Flush-then-close: runs the close on the write queue so every queued
    /// channel→fd write lands before the app side sees EOF.
    private func teardownFD() {
        stopFDReader()
        // Strong capture on purpose: NIO releases the handler right after
        // channelInactive, and a weak self here let the block no-op — leaking
        // the pump fd (and its socket buffers) once per dropped channel.
        writeQueue.async {
            self.stateLock.lock()
            let already = self.fdClosed
            self.fdClosed = true
            self.stateLock.unlock()
            guard !already else { return }
            Darwin.shutdown(self.fd, SHUT_RDWR)
            Darwin.close(self.fd)
        }
    }
}
