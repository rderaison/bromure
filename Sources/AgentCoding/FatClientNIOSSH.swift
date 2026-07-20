import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - NIOSSH client for the password bootstrap

/// A minimal embedded SSH *client* (swift-nio-ssh) used only to bootstrap trust
/// with a password. Rationale: the steady-state transport uses the system `ssh`
/// binary with public-key auth (which works), but feeding a *password* to that
/// binary from a GUI app (no TTY) means `SSH_ASKPASS` — fragile plumbing for
/// something we fully control on both ends. Since we already embed swift-nio-ssh
/// for the server, we speak SSH client-side directly here: send the password
/// through the auth API, then enroll this Mac's public key over the control
/// bridge so every subsequent connection is passwordless (system ssh + pubkey).
///
/// Host-key trust is already established by the connect flow (ssh-keyscan TOFU +
/// the strict-host-key pubkey probe) before we ever get here, so this client
/// accepts the presented key.
enum FatClientNIOSSH {
    enum AuthResult: Equatable {
        case ok            // password accepted (and key enrolled)
        case authFailed    // password rejected
        case unreachable(String)
    }

    /// Password-authenticate to `host` and enroll our client public key via
    /// `POST /remote/keys` over the control bridge. Synchronous.
    static func enrollWithPassword(host: RemoteHost, password: String,
                                   hostKeyLine: String?) -> AuthResult {
        // The password must never transit a connection whose host key we
        // haven't verified: the scan/TOFU happened on a DIFFERENT TCP
        // connection, and accepting any key here would hand the macOS login
        // password to whoever answers this dial. Parse the scanned key and
        // pin THIS handshake to it.
        guard let expected = hostKeyLine.flatMap(parseHostKey) else {
            return .unreachable("host key not pinned — restart the connection")
        }
        guard let pub = RemoteTransport.ensureClientKey() else {
            return .unreachable("no client key")
        }
        let body = "{\"key\":\(jsonString(pub))}"
        let request = "POST /remote/keys HTTP/1.1\r\nHost: localhost\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(body)"
        return runControlRequest(host: host, password: password,
                                 request: Data(request.utf8), expectedHostKey: expected)
    }

    /// Parse a known_hosts / authorized_keys style line ("[host] type b64
    /// [comment]") into the key it carries.
    private static func parseHostKey(_ line: String) -> NIOSSHPublicKey? {
        var tokens = line.split(separator: " ").map(String.init)
        if let first = tokens.first, !first.hasPrefix("ssh-"), !first.hasPrefix("ecdsa-") {
            tokens.removeFirst()   // known_hosts host field
        }
        guard tokens.count >= 2 else { return nil }
        return try? NIOSSHPublicKey(openSSHPublicKey: tokens.prefix(2).joined(separator: " "))
    }

    /// Connect (password auth), open a session channel bridged to control.sock,
    /// and send `request`. Success = the password authenticated and the request
    /// was flushed; we can't wait for the 200 because enrolling a key restarts
    /// the server's SSH listener, which drops this connection first.
    private static func runControlRequest(host: RemoteHost, password: String,
                                          request: Data,
                                          expectedHostKey: NIOSSHPublicKey) -> AuthResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // numberOfThreads:1 → group.next() is the single loop every channel and
        // the auth delegate run on, so we can build the resolver up front and
        // touch it from any of them without locking.
        let el = group.next()
        let resolver = Resolver(el.makePromise(of: BootstrapOutcome.self))
        // If the delegate is asked to authenticate a *second* time, the server
        // rejected our password (this NIOSSH build doesn't surface auth failure
        // any other way — it just stops, so we'd otherwise hang to the timeout).
        let auth = PasswordAuthDelegate(username: host.user, password: password) {
            resolver.resolve(.authRejected)
        }
        let serverAuth = PinnedHostKey(expected: expectedHostKey) {
            resolver.resolve(.incomplete)
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: auth, serverAuthDelegate: serverAuth)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .connectTimeout(.seconds(10))

        let channel: Channel
        do {
            channel = try bootstrap.connect(host: host.address, port: host.port).wait()
        } catch {
            resolver.resolve(.incomplete)   // satisfy the promise so it isn't leaked
            return .unreachable(firstLine("\(error)"))
        }
        defer { try? channel.close().wait() }

        // resolve(.ok) once we've authenticated AND flushed the request (the key
        // is added server-side even if the response never arrives — POST
        // /remote/keys restarts the SSH listener, dropping us before the 200).
        let timeout = el.scheduleTask(in: .seconds(20)) { resolver.resolve(.incomplete) }
        // Backstop: a drop before we flush means the handshake/bridge didn't
        // finish — reachable but incomplete, NOT a rejected password.
        channel.closeFuture.whenComplete { _ in resolver.resolve(.incomplete) }

        el.execute {
            do {
                let sshHandler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(nil, channelType: .session) { child, _ in
                    child.pipeline.addHandler(
                        ControlRequestHandler(command: FatClient.controlVerb, request: request,
                                              resolver: resolver))
                }
            } catch {
                resolver.resolve(.incomplete)
            }
        }

        defer { timeout.cancel() }
        let outcome = (try? resolver.promise.futureResult.wait()) ?? .incomplete
        if outcome == .ok {
            // The enroll POST is flushed, but the server still has to read it off
            // the control socket, add the key, and restart its SSH listener —
            // which is what drops this connection. Wait for that server-driven
            // close so we don't tear down mid-enroll; bounded by a grace timeout
            // in case the add doesn't restart (e.g. key already present).
            let grace = el.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
            _ = try? channel.closeFuture.wait()
            grace.cancel()
        }
        switch outcome {
        case .ok:           return .ok
        case .authRejected: return .authFailed
        case .incomplete:   return .unreachable(
            "Reached \(host.address) but couldn't finish signing in — the remote may be busy or its control plane unavailable. Try again.")
        }
    }

    private static func jsonString(_ s: String) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: [s]), as: UTF8.self))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }
    private static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.isEmpty } ?? s
    }
}

/// Offers the password exactly once. If the server asks again, our offer was
/// rejected → invoke `onRejected` (the only reliable auth-failed signal in this
/// NIOSSH build). Always runs on the SSH event loop.
private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private let onRejected: () -> Void
    private var offered = false

    init(username: String, password: String, onRejected: @escaping () -> Void) {
        self.username = username
        self.password = password
        self.onRejected = onRejected
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.password) else {
            if offered { onRejected() }   // asked again → password was rejected
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .password(.init(password: password))))
    }
}

/// Rejects any host key other than the one the connect flow just scanned
/// and the user pinned. The scan happened on a different TCP connection —
/// without this check, a redirect between scan and password entry would
/// receive the user's macOS login password.
private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate {
    struct Mismatch: Error {}
    private let expected: NIOSSHPublicKey
    private let onMismatch: () -> Void

    init(expected: NIOSSHPublicKey, onMismatch: @escaping () -> Void) {
        self.expected = expected
        self.onMismatch = onMismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if hostKey == expected {
            validationCompletePromise.succeed(())
        } else {
            onMismatch()
            validationCompletePromise.fail(Mismatch())
        }
    }
}

/// How the password bootstrap ended. Distinguishes a rejected password (→ blame
/// the password) from a reachable-but-incomplete failure — auth may well have
/// succeeded, but the SSH handshake or the control-bridge exec didn't finish, so
/// the user shouldn't be told their password was wrong.
private enum BootstrapOutcome { case ok, authRejected, incomplete }

/// One-shot, idempotent resolution of the auth result. Must only be touched on
/// the SSH event loop (single-threaded), so the `done` flag needs no locking.
private final class Resolver {
    let promise: EventLoopPromise<BootstrapOutcome>
    private var done = false
    init(_ promise: EventLoopPromise<BootstrapOutcome>) { self.promise = promise }
    func resolve(_ outcome: BootstrapOutcome) {
        guard !done else { return }
        done = true
        promise.succeed(outcome)
    }
}

/// Runs one control-plane request over a session channel bridged (server-side)
/// to control.sock: exec the control verb, then write the HTTP request. Resolves
/// the result `true` once the request is flushed — reaching an open session
/// channel already proves auth succeeded, and the server tears the connection
/// down (listener restart) before any response comes back.
private final class ControlRequestHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let request: Data
    private let resolver: Resolver
    private var sentRequest = false

    init(command: String, request: Data, resolver: Resolver) {
        self.command = command
        self.request = request
        self.resolver = resolver
    }

    func channelActive(context: ChannelHandlerContext) {
        // Reaching an active session channel means auth already succeeded.
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent where !sentRequest:
            sentRequest = true
            var buf = context.channel.allocator.buffer(capacity: request.count)
            buf.writeBytes(request)
            let flushed = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))),
                                  promise: flushed)
            // Once the request is on the wire, the enroll is effectively done —
            // the server writes the key then restarts its listener (dropping us),
            // so we won't get the 200 back. Resolving here beats that teardown.
            flushed.futureResult.whenComplete { [resolver] _ in resolver.resolve(.ok) }
        case is ChannelFailureEvent:
            // Auth already succeeded (we reached an active session channel); the
            // server rejected the control-bridge exec — a bridge failure, not a
            // bad password.
            resolver.resolve(.incomplete)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resolver.resolve(sentRequest ? .ok : .incomplete)
        context.close(promise: nil)
    }
}
