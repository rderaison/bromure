import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Fat-client network forwarding (Phase 4)

/// Userspace TCP forwarders that let a local process (and the local browser VM)
/// reach the REMOTE workspace subnet (192.168.x.y) over SSH. Each accepted
/// connection opens a `bromure-fatclient/1 forward <ip> <port>` channel to the
/// remote (which dials the guest and splices), so bytes flow end-to-end.
///
/// Two shapes:
///  - `serveForward`: a fixed local port → one remote `ip:port` (ssh -L style).
///  - `serveSocks`: a SOCKS5 server → any remote guest the client asks for,
///    with the LITERAL destination address resolved on the remote side. The
///    local browser VM points at this (via PAC, only for the remote subnet) so
///    navigating to `http://192.168.64.5:3000` reaches the remote guest.
enum FatForward {
    /// Read up to bufSize from `from` and write it all to `to`. Returns false on
    /// EOF/error (time to stop reading `from`).
    private static func copyOnce(_ from: Int32, _ to: Int32, _ buf: inout [UInt8]) -> Bool {
        let r = buf.withUnsafeMutableBytes { Darwin.read(from, $0.baseAddress, $0.count) }
        if r <= 0 { return false }
        var off = 0
        while off < r {
            let w = buf.withUnsafeBytes { Darwin.write(to, $0.baseAddress!.advanced(by: off), r - off) }
            if w <= 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
            off += w
        }
        return true
    }

    /// Bidirectional byte pump between two full-duplex fds, half-close aware:
    /// when one direction ends, keep draining the other until it also ends.
    static func splice(_ a: Int32, _ b: Int32) {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let pollIn = Int16(POLLIN)
        var aOpen = true, bOpen = true   // "still readable"
        while aOpen || bOpen {
            var fds = [pollfd(fd: aOpen ? a : -1, events: pollIn, revents: 0),
                       pollfd(fd: bOpen ? b : -1, events: pollIn, revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if aOpen, fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if !copyOnce(a, b, &buf) { aOpen = false; Darwin.shutdown(b, SHUT_WR) }
            }
            if bOpen, fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if !copyOnce(b, a, &buf) { bOpen = false; Darwin.shutdown(a, SHUT_WR) }
            }
        }
        Darwin.close(a); Darwin.close(b)
    }

    /// Like `splice` but for a process with SEPARATE stdin/stdout fds bridged to
    /// one full-duplex `sock`. Does not close the std fds.
    static func proxy(inFD: Int32, outFD: Int32, sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let pollIn = Int16(POLLIN)
        var inOpen = true, sockOpen = true
        while inOpen || sockOpen {
            var fds = [pollfd(fd: inOpen ? inFD : -1, events: pollIn, revents: 0),
                       pollfd(fd: sockOpen ? sock : -1, events: pollIn, revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if inOpen, fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if !copyOnce(inFD, sock, &buf) { inOpen = false; Darwin.shutdown(sock, SHUT_WR) }
            }
            if sockOpen, fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if !copyOnce(sock, outFD, &buf) { sockOpen = false }
            }
        }
        Darwin.close(sock)
    }

    /// Bind a local TCP listener on 127.0.0.1 (or 0.0.0.0) : `localPort`.
    static func listen(port: Int, bindAll: Bool) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = bindAll ? INADDR_ANY : inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 64) == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    /// Bind an ephemeral-port listener (`bindAll` → 0.0.0.0, else loopback);
    /// returns the fd and the actual port, or (-1, 0) on failure. The browser
    /// pane binds 0.0.0.0 so the guest can reach it at the vmnet gateway (the
    /// gateway IP isn't on the host until the switch starts, so we can't bind it
    /// directly); `acceptSocks`'s peer filter keeps it from being an open relay.
    static func listenEphemeral(bindAll: Bool = false) -> (fd: Int32, port: Int) {
        let fd = listen(port: 0, bindAll: bindAll)
        guard fd >= 0 else { return (-1, 0) }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { Darwin.close(fd); return (-1, 0) }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    /// Dotted-quad of an accepted peer's IPv4 address (network byte order).
    static func peerIPv4(_ addr: sockaddr_in) -> String {
        let a = addr.sin_addr.s_addr
        return "\(a & 0xff).\((a >> 8) & 0xff).\((a >> 16) & 0xff).\((a >> 24) & 0xff)"
    }

    /// SOCKS5 accept loop over an ALREADY-bound listener `lfd`. `allow` gates
    /// each connection by source IP (nil = accept all). Returns when `lfd` is
    /// closed (that's the stop signal — `accept` then fails). Unlike `serveSocks`
    /// this never binds, so the owner controls the fd's lifetime.
    static func acceptSocks(lfd: Int32, host: RemoteHost, allow: ((String) -> Bool)? = nil) {
        while true {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(lfd, $0, &len) }
            }
            if cfd < 0 { if errno == EINTR { continue }; break }   // lfd closed → stop
            if let allow, !allow(peerIPv4(peer)) { Darwin.close(cfd); continue }
            Thread.detachNewThread { handleSocks(cfd, host: host) }
        }
    }

    /// Fixed local port → remote `ip:port`. Blocks, accepting forever.
    static func serveForward(host: RemoteHost, localPort: Int, ip: String, port: Int, bindAll: Bool) {
        let lfd = listen(port: localPort, bindAll: bindAll)
        guard lfd >= 0 else {
            FileHandle.standardError.write(Data("forward: couldn't bind :\(localPort)\n".utf8)); return
        }
        FileHandle.standardError.write(Data("forward: 127.0.0.1:\(localPort) → \(ip):\(port) via \(host.connectLabel)\n".utf8))
        while true {
            let cfd = Darwin.accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread {
                guard let rfd = RemoteTransport.forwardDial(host: host, ip: ip, port: port) else {
                    Darwin.close(cfd); return
                }
                splice(cfd, rfd)
            }
        }
    }

    /// Minimal SOCKS5 server (no auth) → tunnels each CONNECT to the requested
    /// remote guest over `bromure forward`. Supports IPv4 + domain address
    /// types; the destination is resolved on the REMOTE side, so literal
    /// `192.168.x.y` addresses just work. Blocks, accepting forever.
    static func serveSocks(host: RemoteHost, localPort: Int, bindAll: Bool) {
        let lfd = listen(port: localPort, bindAll: bindAll)
        guard lfd >= 0 else {
            FileHandle.standardError.write(Data("socks: couldn't bind :\(localPort)\n".utf8)); return
        }
        FileHandle.standardError.write(Data("socks5: 127.0.0.1:\(localPort) → \(host.connectLabel) (remote subnet)\n".utf8))
        while true {
            let cfd = Darwin.accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread { handleSocks(cfd, host: host) }
        }
    }

    private static func handleSocks(_ cfd: Int32, host: RemoteHost) {
        func readN(_ n: Int) -> [UInt8]? {
            var out = [UInt8](); out.reserveCapacity(n)
            var buf = [UInt8](repeating: 0, count: n)
            while out.count < n {
                let r = Darwin.read(cfd, &buf, n - out.count)
                if r <= 0 { return nil }
                out.append(contentsOf: buf[0..<r])
            }
            return out
        }
        func writeAll(_ bytes: [UInt8]) { var b = bytes; _ = Darwin.write(cfd, &b, b.count) }
        func fail() { Darwin.close(cfd) }

        // Greeting: VER=5, NMETHODS, METHODS…
        guard let head = readN(2), head[0] == 5 else { return fail() }
        let nMethods = Int(head[1])
        guard nMethods > 0, readN(nMethods) != nil else { return fail() }
        writeAll([5, 0])   // choose "no auth"

        // Request: VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT
        guard let req = readN(4), req[0] == 5, req[1] == 1 /*CONNECT*/ else {
            writeAll([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]); return fail()   // command not supported
        }
        let atyp = req[3]
        let dstHost: String
        switch atyp {
        case 1:   // IPv4
            guard let a = readN(4) else { return fail() }
            dstHost = "\(a[0]).\(a[1]).\(a[2]).\(a[3])"
        case 3:   // domain
            guard let l = readN(1), let d = readN(Int(l[0])) else { return fail() }
            dstHost = String(decoding: d, as: UTF8.self)
        default:
            writeAll([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]); return fail()   // address type not supported
        }
        guard let pb = readN(2) else { return fail() }
        let dstPort = (Int(pb[0]) << 8) | Int(pb[1])

        guard let rfd = RemoteTransport.forwardDial(host: host, ip: dstHost, port: dstPort) else {
            writeAll([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]); return fail()   // connection refused
        }
        writeAll([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])   // success (BND.ADDR/PORT ignored)
        splice(cfd, rfd)
    }
}

// MARK: - Per-host SOCKS forwarder (auto-started with a remote connection)

/// A SOCKS5 forwarder bound to a loopback ephemeral port, tunneling each CONNECT
/// to a guest on the connected remote's subnet (over `bromure forward`). One is
/// started per connected `RemoteHostController`; the browser pane's PAC points
/// at `port` for the remote subnet, and `curl --socks5 127.0.0.1:<port>` reaches
/// the same guests. Idle cost is one fd + one thread parked in `accept`.
final class RemoteSocksForwarder {
    let port: Int
    private let lfd: Int32
    private var stopped = false

    /// Binds an ephemeral port and starts accepting. Bound to 0.0.0.0 so the
    /// local browser VM can reach it at the vmnet gateway, but connections are
    /// accepted ONLY from loopback (curl on the host) and the pinned browser
    /// subnet (192.168.<browserSwitchOctet>.x) — never an open relay onto the
    /// LAN. Returns nil if the listener couldn't be bound.
    init?(host: RemoteHost) {
        let (fd, port) = FatForward.listenEphemeral(bindAll: true)
        guard fd >= 0 else { return nil }
        self.lfd = fd
        self.port = port
        let browserPrefix = "192.168.\(FatClient.browserSwitchOctet)."
        Thread.detachNewThread {
            FatForward.acceptSocks(lfd: fd, host: host) { ip in
                ip.hasPrefix("127.") || ip.hasPrefix(browserPrefix)
            }
        }
    }

    /// Close the listener; the parked `accept` fails and its thread exits.
    /// In-flight tunnels finish on their own (each owns its own fds).
    func stop() {
        guard !stopped else { return }
        stopped = true
        Darwin.close(lfd)
    }
}

// MARK: - CLI

/// `bromure-ac __forward <hostID> <localPort> <remoteIP> <remotePort>` — a
/// local port that tunnels to a remote guest (ssh -L style). Plumbing/testing.
struct FatClientForward: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__forward", abstract: "Fat-client TCP forward (plumbing).",
        shouldDisplay: false)
    @Argument var hostID: String
    @Argument var localPort: Int
    @Argument var remoteIP: String
    @Argument var remotePort: Int
    @Flag(name: .long, help: "Bind all interfaces (default loopback).") var bindAll = false
    func run() throws {
        guard let id = UUID(uuidString: hostID),
              let host = RemoteTransport.loadHosts().first(where: { $0.id == id }) else {
            throw ValidationError("unknown remote host: \(hostID)")
        }
        FatForward.serveForward(host: host, localPort: localPort, ip: remoteIP, port: remotePort, bindAll: bindAll)
    }
}

/// `bromure-ac __dial <ip> <port>` — connect to a guest TCP endpoint and pump
/// stdin↔socket↔stdout. Runs as a SUBPROCESS of the server so it can actually
/// reach the guest: the app process that owns the vmnet interface cannot
/// TCP-connect to its own guests (EHOSTUNREACH), but a separate process can
/// (the same reason the app spawns `cloudflared` as a subprocess for guest
/// origins). The forward bridge splices the SSH channel to this helper.
struct FatClientDial: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__dial", abstract: "Dial a guest TCP endpoint (plumbing).",
        shouldDisplay: false)
    @Argument var ip: String
    @Argument var port: Int

    func run() throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw ExitCode(1) }
        // Retry the transient post-boot reachability window, with a FRESH socket
        // per attempt (a socket that failed connect can't be reused).
        var sock: Int32 = -1
        for attempt in 0..<8 {
            if attempt > 0 { usleep(400_000) }
            let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 { sock = s; break }
            FatClientLog.log("__dial connect(\(ip):\(port)) attempt \(attempt) errno=\(errno) (\(String(cString: strerror(errno))))")
            Darwin.close(s)
            if errno != EHOSTUNREACH && errno != ETIMEDOUT && errno != ECONNREFUSED { break }
        }
        guard sock >= 0 else { FatClientLog.log("__dial: giving up on \(ip):\(port)"); throw ExitCode(1) }
        FatClientLog.log("__dial: connected to \(ip):\(port)")
        // Pump stdin(0) ↔ socket ↔ stdout(1), half-close aware: when stdin ends
        // we stop reading it (and SHUT_WR the socket) but KEEP draining the
        // socket → stdout until the guest closes. Otherwise a client that sends
        // its request then waits (HTTP/1.0) never sees the response.
        FatForward.proxy(inFD: 0, outFD: 1, sock: sock)
    }
}

/// `bromure-ac __tunnel-helper` — the privileged utun tunnel daemon, run as root
/// by launchd (registered via SMAppService). Serves setup/lookup/teardown over
/// an owner-only Unix socket for `FatClientTunnel`. Never runs unless root.
struct TunnelHelper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__tunnel-helper", abstract: "Privileged utun tunnel daemon.",
        shouldDisplay: false)
    func run() throws { FatClientTunnelDaemon.run() }
}

/// `bromure-ac __fatclient-browsermcp <addr> <port> <user> <vm>` — dials the
/// browser-mcp relay channel and sends one `initialize`, to verify the server
/// dispatches the verb + invokes the resolver (plumbing/testing).
struct FatClientBrowserMCPProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__fatclient-browsermcp", abstract: "Fat-client browser-mcp dial (plumbing).",
        shouldDisplay: false)
    @Argument var address: String
    @Argument var port: Int
    @Argument var user: String
    @Argument var vm: String
    func run() throws {
        let host = RemoteHost(name: address, address: address, port: port, user: user)
        guard let fd = RemoteTransport.browserMCPDial(host: host, vm: vm), fd >= 0 else {
            print("browser-mcp: dial failed"); return
        }
        defer { Darwin.close(fd) }
        let req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n"
        _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            print("browser-mcp response: \(String(decoding: buf[0..<n], as: UTF8.self).prefix(300))")
        } else {
            print("browser-mcp: EOF (no response) — channel closed (expected when the "
                + "workspace has no running browser bridge)")
        }
    }
}

/// `bromure-ac __forward-socks <hostID> <localPort>` — a SOCKS5 proxy that
/// tunnels to any remote guest (used by the local browser VM's PAC). Plumbing.
struct FatClientSocks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__forward-socks", abstract: "Fat-client SOCKS5 proxy (plumbing).",
        shouldDisplay: false)
    @Argument var hostID: String
    @Argument var localPort: Int
    @Flag(name: .long, help: "Bind all interfaces (default loopback).") var bindAll = false
    func run() throws {
        guard let id = UUID(uuidString: hostID),
              let host = RemoteTransport.loadHosts().first(where: { $0.id == id }) else {
            throw ValidationError("unknown remote host: \(hostID)")
        }
        FatForward.serveSocks(host: host, localPort: localPort, bindAll: bindAll)
    }
}
