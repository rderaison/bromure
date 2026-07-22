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
// A swift-nio-ssh replacement for the system-`ssh`-subprocess transport in
// FatClientRemote.swift: one SSH connection per remote host, and one exec
// child channel per dial, bridged to a socketpair so the caller still gets a
// plain bidirectional fd — `ControlClient.request`/`openStream` and the
// framed PTY pump run over it unchanged.
//
// This is the ONLY transport on iOS (no Process there); on macOS it is
// compiled and typechecked but the proven system-ssh path stays the default.
// Compared to ssh+ControlMaster, all channels multiplex over a single
// connection — including interactive attaches, which is safe here because the
// OpenSSH mux quirk (buffering a multiplexed channel's spontaneous
// server→client output) is specific to the ControlMaster implementation, not
// to SSH channel multiplexing itself.

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

    /// Where host-key pins live. Configured once at startup by the platform
    /// transport layer (RemoteTransport on iOS; unused while macOS stays on
    /// system ssh, whose known_hosts the ssh binary manages itself).
    var knownHostsURL: URL?
    /// Loads the client's ed25519 identity for public-key auth. Configured by
    /// the platform transport layer.
    var loadClientKey: (() -> Curve25519.Signing.PrivateKey?)?

    private let lock = NSLock()
    private var connections: [String: SSHConnection] = [:]
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Key by endpoint, not host id: a peer host's resolved loopback endpoint
    /// changes per session, and a stale connection to a dead endpoint must not
    /// shadow a fresh one.
    private func poolKey(_ host: RemoteHost) -> String {
        "\(host.id.uuidString)|\(host.user)@\(host.address):\(host.port)"
    }

    /// A live (or newly established) connection to `host`. `strict` = the host
    /// key MUST match an existing pin (probe's MITM check); otherwise
    /// accept-new semantics: pin on first contact, refuse a changed key.
    func ensureConnection(host: RemoteHost, strict: Bool = false) throws -> SSHConnection {
        let key = poolKey(host)
        lock.lock()
        if let c = connections[key], c.isAlive {
            lock.unlock()
            return c
        }
        connections[key] = nil
        lock.unlock()

        let conn = try SSHConnection(host: host, group: group, strictHostKey: strict,
                                     knownHosts: knownHostsURL.map(KnownHostsStore.init),
                                     clientKey: loadClientKey?())
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
    func dial(host: RemoteHost, verb: String) -> Int32? {
        for attempt in 0..<2 {
            guard let conn = try? ensureConnection(host: host) else { return nil }
            if let fd = conn.openVerbChannel(verb) { return fd }
            // Channel open failed on a connection that claimed to be alive —
            // drop it and retry once on a fresh one.
            conn.close()
            if attempt == 1 { return nil }
        }
        return nil
    }

    func closeConnection(host: RemoteHost) {
        let key = poolKey(host)
        lock.lock()
        let c = connections.removeValue(forKey: key)
        lock.unlock()
        c?.close()
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
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: NoAuth(),
                                serverAuthDelegate: Capture { captured.set($0) })),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil))
                }
            }
            .connectTimeout(.seconds(8))
        guard let channel = try? bootstrap.connect(host: address, port: port).wait() else { return nil }
        // The validation failure tears the connection down; wait for that —
        // but bound it. A TCP-connected-but-silent endpoint (the remote's SSH
        // front door down, or a P2P relay that spliced but delivers no bytes)
        // would otherwise hang here forever. `ssh-keyscan` uses `-T 8`; we
        // schedule a close on the event loop after the same budget.
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(8)) {
            channel.close(promise: nil)
        }
        _ = try? channel.closeFuture.wait()
        timeout.cancel()
        guard let key = captured.get(), let blob = SSHKeyWire.blob(of: key) else { return nil }
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

// MARK: - One SSH connection

/// A single authenticated SSH connection; `openVerbChannel` multiplexes exec
/// channels over it.
final class SSHConnection: @unchecked Sendable {
    let channel: Channel
    private let host: RemoteHost
    var isAlive: Bool { channel.isActive }

    /// Synchronous connect + handshake + auth. Throws `SSHDialError`.
    init(host: RemoteHost, group: EventLoopGroup, strictHostKey: Bool,
         knownHosts: KnownHostsStore?, clientKey: Curve25519.Signing.PrivateKey?) throws {
        self.host = host
        guard let clientKey else { throw SSHDialError.authFailed }

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
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
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
            .connectTimeout(.seconds(10))

        do {
            channel = try bootstrap.connect(host: host.address, port: host.port).wait()
        } catch {
            throw SSHDialError.unreachable(Self.firstLine("\(error)"))
        }

        // The NIOSSH handshake+auth completes asynchronously after connect.
        // Prove the session end-to-end by opening (and immediately closing) a
        // probe child channel: its creation only succeeds once auth is done.
        // Auth/host-key failures surface through the delegates' flags.
        do {
            let ch = channel   // local, so the loop closures don't capture self
            let probe = ch.eventLoop.makePromise(of: Channel.self)
            // Bound the handshake+auth: if the far side never completes it (a
            // silent endpoint / dead relay), closing the channel fails the
            // pending probe so we throw `.unreachable` instead of blocking.
            let timeout = ch.eventLoop.scheduleTask(in: .seconds(12)) {
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
            timeout.cancel()
            child.close(promise: nil)
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

    /// Open an exec child channel for `verb`, bridge it to a socketpair, and
    /// return the caller's fd immediately (bytes the caller writes sit in the
    /// socketpair buffer until the exec is accepted — same as writing into a
    /// still-handshaking `ssh` process's stdin). Nil if the socketpair or the
    /// child-channel open fails outright.
    func openVerbChannel(_ verb: String) -> Int32? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            FatClientLog.log("nio-dial: socketpair FAILED errno=\(errno)")
            return nil
        }
        let appFD = fds[0], pumpFD = fds[1]
        // Without NOSIGPIPE a peer-closed write raises SIGPIPE and kills the
        // process (no ssh child process to absorb it in this transport).
        var one: Int32 = 1
        _ = setsockopt(appFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(pumpFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let ch = channel
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
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        promise.futureResult.whenFailure { _ in
            // Channel never opened — close the pump side so the app side EOFs.
            Darwin.shutdown(pumpFD, SHUT_RDWR)
            Darwin.close(pumpFD)
        }
        return appFD
    }

    func close() {
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
    private var execAccepted = false
    private var fdClosed = false
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
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent where !execAccepted:
            execAccepted = true
            startFDReader(context: context)
            context.read()
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
                    channel.writeAndFlush(NIOAny(data), promise: nil)
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
        writeQueue.async { [weak self] in
            guard let self else { return }
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
