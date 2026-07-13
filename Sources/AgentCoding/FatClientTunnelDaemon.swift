import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Privileged tunnel daemon (root, launchd via SMAppService)

/// The root-only half of the system-wide utun tunnel, run as a launchd daemon
/// (registered by the app via SMAppService with user consent). It owns the ops
/// that need root — creating a utun, routing a subnet to it, the `pf` rdr rule,
/// and `DIOCNATLOOK` on `/dev/pf` — and serves them over an owner-only Unix
/// socket. The forwarder itself (accept + `forwardDial` + splice) stays in the
/// app so it uses the USER's SSH identity, not root's.
///
/// Protocol (one line each way, space-separated):
///   SETUP <cidr> <port>              → OK <utun>        | ERR <msg>
///   LOOKUP <sip> <sport> <dip> <dport> → OK <ip> <port> | ERR <msg>
///   TEARDOWN <cidr> <utun>           → OK               | ERR <msg>
enum FatClientTunnelDaemon {
    static let socketPath = "/var/run/io.bromure.fatclient-tunnel.sock"

    /// Entry point for `bromure-ac __tunnel-helper` (launchd runs this as root).
    static func run() -> Never {
        guard getuid() == 0 else {
            FileHandle.standardError.write(Data("tunnel-helper must run as root\n".utf8))
            exit(1)
        }
        unlink(socketPath)
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard lfd >= 0 else { exit(1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(lfd, 16) == 0 else { exit(1) }
        // Reachable only by the console user (who runs the app), not world: chown
        // the socket to /dev/console's owner, then 0600.
        var st = stat()
        if stat("/dev/console", &st) == 0 { chown(socketPath, st.st_uid, st.st_gid) }
        chmod(socketPath, 0o600)
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread { serve(cfd) }
        }
        exit(0)
    }

    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let line = readLine(fd) else { return }
        let parts = line.split(separator: " ").map(String.init)
        let reply: String
        switch parts.first {
        case "SETUP" where parts.count == 3:
            if let port = Int(parts[2]), let utun = TunnelPrivilegedOps.setup(cidr: parts[1], redirectPort: port) {
                reply = "OK \(utun)"
            } else { reply = "ERR setup" }
        case "LOOKUP" where parts.count == 5:
            if let sp = UInt16(parts[2]), let dp = UInt16(parts[4]),
               let d = TunnelPrivilegedOps.natLook(srcIP: parts[1], srcPort: sp, dstIP: parts[3], dstPort: dp) {
                reply = "OK \(d.ip) \(d.port)"
            } else { reply = "ERR lookup" }
        case "TEARDOWN" where parts.count == 3:
            TunnelPrivilegedOps.teardown(cidr: parts[1], utun: parts[2]); reply = "OK"
        default:
            reply = "ERR bad request"
        }
        var out = Data((reply + "\n").utf8)
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var data = Data(); var b = [UInt8](repeating: 0, count: 1)
        while data.count < 1024 {
            let n = read(fd, &b, 1)
            if n <= 0 { return nil }
            if b[0] == 0x0A { break }
            data.append(b[0])
        }
        return String(data: data, encoding: .utf8)
    }
}
