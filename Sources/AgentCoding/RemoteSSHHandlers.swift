import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import OpenDirectory
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
    private let pwQueue = DispatchQueue(label: "io.bromure.remote.pw")

    init(username: String, allowPassword: Bool, allowPubkey: Bool,
         authorizedKeys: Set<NIOSSHPublicKey>) {
        self.username = username
        self.allowPassword = allowPassword
        self.allowPubkey = allowPubkey
        self.authorizedKeys = authorizedKeys
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
            pwQueue.async {
                let ok = SystemPassword.verify(user: user, password: password)
                responsePromise.succeed(ok ? .success : .failure)
            }
        default:
            responsePromise.succeed(.failure)
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
    private var term = "xterm-256color"
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var master: Int32 = -1
    private var childPID: pid_t = -1
    private var started = false
    private var terminated = false
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "io.bromure.remote.pty")

    init(menuExe: String, user: String) {
        self.menuExe = menuExe
        self.user = user
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
            // ForceCommand semantics: ignore the requested command, run the menu.
            startMenu(context: context, wantReply: e.wantReply)
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
        guard master >= 0, let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        _ = bytes.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Self.writeAll(master, base, bytes.count)
        }
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
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bb)), promise: nil)
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK) {
                self.finish(channel: channel, pid: pid, master: masterFD)
            }
        }
        readSource = src
        src.resume()
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
        if master >= 0 { Darwin.close(master) }
        if pid > 0 {
            kill(pid, SIGHUP)
            var st: Int32 = 0
            waitpid(pid, &st, WNOHANG)
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        var written = 0
        while written < count {
            let n = Darwin.write(fd, buf + written, count - written)
            if n <= 0 {
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                break
            }
            written += n
        }
        return written
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
