import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The CLI's interactive exec (`vm exec -it`), in the library so the remote
// menu (`__remote-menu`, shared with macOS) attaches through it too.

/// The SIGWINCH self-pipe's write end: the handler may run on any thread,
/// so it wakes the poll loop through a pipe rather than a flag.
nonisolated(unsafe) var gWinchPipe: Int32 = -1

/// Drives an interactive exec: a raw stream to agentd's pty, the terminal in
/// raw mode (restored on exit), SIGWINCH forwarded as resize frames.
// @port-skip linux-only: the namespace; run carries the @port line
public enum InteractiveExec {
    // partial: no view/window, guiConsent or sizePassive (no host terminal views on Linux); a stream that ends without an exit frame is an error (exit 1) rather than a silent 0
    // @port InteractiveExec.static run(client: ControlClient, vm: String, command: String, view: String?, window: Int?, guiConsent: Bool, sizePassive: Bool, overlayTrigger: UInt8?, onOverlay: (()->[UInt8])?) h=817622aa69512a47 @94eb37f3
    /// `overlayTrigger`: a lone byte (the remote menu's Ctrl-]) caught here,
    /// never framed to the guest, that calls `onOverlay`; its non-empty
    /// return is written to the guest (Ctrl-b d to detach), an empty one
    /// repaints by re-sending the size. Twice in one read is one literal byte.
    public static func run(client: ControlClient, vm: String, command: String,
                           overlayTrigger: UInt8? = nil, onOverlay: (() -> [UInt8])? = nil) throws {
        func size() -> (Int, Int) {
            var ws = winsize()
            _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
            return (ws.ws_col == 0 ? 80 : Int(ws.ws_col), ws.ws_row == 0 ? 24 : Int(ws.ws_row))
        }
        let (cols, rows) = size()
        let body: JSONValue = .object(["command": .string(command), "interactive": .bool(true),
                                       "cols": .number(Double(cols)), "rows": .number(Double(rows))])
        let fd: Int32
        do { fd = try client.openStream("POST", "/vms/\(ControlClient.encodeSegment(vm))/exec", body: body) }
        catch let e as ControlClient.ClientError { throw ValidationError(e.description) }
        defer { close(fd) }

        let haveTTY = isatty(STDIN_FILENO) != 0
        var orig = termios()
        if haveTTY {
            tcgetattr(STDIN_FILENO, &orig)
            var raw = orig
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if haveTTY { tcsetattr(STDIN_FILENO, TCSANOW, &orig) } }

        var p: [Int32] = [-1, -1]
        guard pipe(&p) == 0 else { throw ValidationError("pipe: \(String(cString: strerror(errno)))") }
        for e in p { _ = fcntl(e, F_SETFL, O_NONBLOCK); _ = fcntl(e, F_SETFD, FD_CLOEXEC) }
        defer { signal(SIGWINCH, SIG_DFL); gWinchPipe = -1; close(p[0]); close(p[1]) }
        gWinchPipe = p[1]
        signal(SIGWINCH) { _ in
            var one: UInt8 = 1
            _ = write(gWinchPipe, &one, 1)
        }

        var stdinFD: Int32 = STDIN_FILENO
        var inbuf: [UInt8] = []
        var rbuf = [UInt8](repeating: 0, count: 1 << 16)
        var exitCode: Int32?
        loop: while true {
            var fds = [pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: p[0], events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 3, -1) < 0 { if errno == EINTR { continue }; break }
            if fds[2].revents != 0 {
                while read(p[0], &rbuf, rbuf.count) > 0 {}
                let (c, r) = size()
                PTYFrame.send(fd, PTYFrame.resize, PTYFrame.resizePayload(cols: c, rows: r))
            }
            if fds[0].revents != 0 {
                let r = read(stdinFD, &rbuf, rbuf.count)
                if r > 0, let trigger = overlayTrigger, let onOverlay {
                    if r == 1, rbuf[0] == trigger {
                        let forward = onOverlay()
                        if forward.isEmpty {
                            let (c, rows) = size()
                            PTYFrame.send(fd, PTYFrame.resize, PTYFrame.resizePayload(cols: c, rows: rows))
                        } else {
                            PTYFrame.send(fd, PTYFrame.data, forward)
                        }
                        continue
                    }
                    if r == 2, rbuf[0] == trigger, rbuf[1] == trigger {
                        PTYFrame.send(fd, PTYFrame.data, [trigger]); continue
                    }
                }
                if r > 0 { PTYFrame.send(fd, PTYFrame.data, Array(rbuf[0..<r])) }
                else if !(r < 0 && errno == EINTR) { PTYFrame.send(fd, PTYFrame.eof, []); stdinFD = -1 }
            }
            if fds[1].revents != 0 {
                let r = read(fd, &rbuf, rbuf.count)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { break }
                inbuf.append(contentsOf: rbuf[0..<r])
                for (type, payload) in PTYFrame.take(&inbuf) {
                    if type == PTYFrame.data, !payload.isEmpty {
                        _ = ControlClientIO.writeAll(STDOUT_FILENO, payload)
                    } else if type == PTYFrame.exit {
                        exitCode = payload.count >= 4
                            ? Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
                            : 0
                        break loop
                    }
                }
            }
        }
        guard let exitCode else {
            if haveTTY { tcsetattr(STDIN_FILENO, TCSANOW, &orig) }
            FileHandle.standardError.write(Data("\r\nbromure-ac: the session ended without an exit status\n".utf8))
            throw ExitCode(1)
        }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }
}

/// Short-write-safe write of raw bytes to a blocking fd.
// @port-skip linux-only: helper
public enum ControlClientIO {
    // @port-skip linux-only: blocking write helper for stdout
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

extension InteractiveExec {
    /// The remote menu's attach: the same pump over its client's socket.
    // @port-skip linux-only: RemoteMenuClient's entry to run (macOS's menu passes the CLI's ControlClient)
    static func run(client: RemoteMenuClient, vm: String, command: String,
                    overlayTrigger: UInt8? = nil, onOverlay: (() -> [UInt8])? = nil) throws {
        try run(client: client.control, vm: vm, command: command, overlayTrigger: overlayTrigger, onOverlay: onOverlay)
    }
}
