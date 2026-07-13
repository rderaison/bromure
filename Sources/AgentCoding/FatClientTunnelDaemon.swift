import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Privileged tunnel daemon (root, launchd via SMAppService)

/// The root-only half of the system-wide utun tunnel. It does the two things
/// that need root — create a utun and route the remote subnet to it — then hands
/// the utun fd to the app over an owner-only Unix socket via SCM_RIGHTS. The
/// forwarder (reading packets, userspace TCP, forwardDial) runs in the APP as the
/// user, so it uses the user's SSH identity. No pf.
///
/// Protocol: the app connects, sends `SETUP <cidr>\n`, and receives `OK <utun>\n`
/// plus the utun fd as ancillary data. The daemon holds the connection open for
/// the tunnel's lifetime; when the app disconnects it deletes the route.
enum FatClientTunnelDaemon {
    static let socketPath = "/var/run/io.bromure.fatclient-tunnel.sock"

    static func run() -> Never {
        guard getuid() == 0 else {
            FileHandle.standardError.write(Data("tunnel-helper must run as root\n".utf8)); exit(1)
        }
        unlink(socketPath)
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard lfd >= 0 else { exit(1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) } }
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(lfd, 16) == 0 else { exit(1) }
        // Reachable only by the console user (who runs the app).
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

    /// One tunnel: SETUP → create utun + route + pass the fd; hold until the app
    /// disconnects, then delete the route.
    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let line = readLine(fd), line.hasPrefix("SETUP ") else {
            _ = write(fd, "ERR bad request\n", 16); return
        }
        let cidr = String(line.dropFirst("SETUP ".count)).trimmingCharacters(in: .whitespaces)
        guard let (utunFD, name) = openUtun(),
              run("/sbin/ifconfig", [name, linkAddr(name), linkPeer(name), "netmask", "255.255.255.252", "up"]),
              run("/sbin/route", ["-n", "add", "-net", cidr, "-interface", name]) else {
            _ = write(fd, "ERR setup\n", 10); return
        }
        // Hand the utun fd to the app; keep our own ref so the interface survives
        // until we delete the route on teardown.
        _ = sendFD(fd, fd: utunFD, message: "OK \(name)\n")
        // Block until the app disconnects (EOF) or sends anything → teardown.
        _ = readLine(fd)
        _ = run("/sbin/route", ["-n", "delete", "-net", cidr])
        Darwin.close(utunFD)   // drops the interface (app's passed fd may still hold it briefly)
    }

    // Distinct /30 link net per utun unit so several coexist without claiming /8.
    private static func linkAddr(_ utun: String) -> String { "10.98.\(unit(utun)).1" }
    private static func linkPeer(_ utun: String) -> String { "10.98.\(unit(utun)).2" }
    private static func unit(_ utun: String) -> Int { (Int(utun.drop(while: { !$0.isNumber })) ?? 0) % 254 + 1 }

    /// `_IOWR('N', 3, struct ctl_info)` — not surfaced by Swift's Darwin module.
    private static let CTLIOCGINFO: UInt = 0xC064_4E03

    private static func openUtun() -> (fd: Int32, name: String)? {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { return nil }
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { raw in
            for (i, b) in "com.apple.net.utun_control".utf8.enumerated() where i < 96 { raw[i] = b }
        }
        guard ioctl(fd, CTLIOCGINFO, &info) == 0 else { Darwin.close(fd); return nil }
        var sc = sockaddr_ctl()
        sc.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        sc.sc_family = UInt8(AF_SYSTEM)
        sc.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        sc.sc_id = info.ctl_id
        sc.sc_unit = 0
        let ok = withUnsafePointer(to: &sc) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        var nameBuf = [CChar](repeating: 0, count: 64)
        var len = socklen_t(nameBuf.count)
        guard getsockopt(fd, SYSPROTO_CONTROL, 2 /*UTUN_OPT_IFNAME*/, &nameBuf, &len) == 0 else {
            Darwin.close(fd); return nil
        }
        return (fd, String(cString: nameBuf))
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func readLine(_ fd: Int32) -> String? {
        var data = Data(); var b = [UInt8](repeating: 0, count: 1)
        while data.count < 1024 {
            let n = read(fd, &b, 1)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
            if b[0] == 0x0A { break }
            data.append(b[0])
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: SCM_RIGHTS

    /// Send `message` plus one fd as ancillary data over a Unix socket.
    static func sendFD(_ sock: Int32, fd: Int32, message: String) -> Bool {
        var msgBytes = Array(message.utf8)
        // cmsghdr (12B on Darwin) + one Int32, 4-aligned → 16B.
        let cmsgLen = 12 + MemoryLayout<Int32>.size          // CMSG_LEN(sizeof(fd))
        var cmsgBuf = [UInt8](repeating: 0, count: 16)        // CMSG_SPACE(sizeof(fd))
        cmsgBuf.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(cmsgLen), toByteOffset: 0, as: UInt32.self)   // cmsg_len
            raw.storeBytes(of: Int32(SOL_SOCKET), toByteOffset: 4, as: Int32.self)  // cmsg_level
            raw.storeBytes(of: Int32(1) /*SCM_RIGHTS*/, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: fd, toByteOffset: 12, as: Int32.self)
        }
        return msgBytes.withUnsafeMutableBufferPointer { mb -> Bool in
            cmsgBuf.withUnsafeMutableBufferPointer { cb -> Bool in
                var iov = iovec(iov_base: mb.baseAddress, iov_len: mb.count)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var mh = msghdr()
                    mh.msg_iov = iovp
                    mh.msg_iovlen = 1
                    mh.msg_control = UnsafeMutableRawPointer(cb.baseAddress)
                    mh.msg_controllen = socklen_t(cb.count)
                    return sendmsg(sock, &mh, 0) >= 0
                }
            }
        }
    }

    /// Receive a line plus one fd (ancillary). Returns (message, fd) or nil.
    static func recvFD(_ sock: Int32) -> (message: String, fd: Int32)? {
        var msgBuf = [UInt8](repeating: 0, count: 256)
        var cmsgBuf = [UInt8](repeating: 0, count: 16)
        let received: Int = msgBuf.withUnsafeMutableBufferPointer { mb in
            cmsgBuf.withUnsafeMutableBufferPointer { cb in
                var iov = iovec(iov_base: mb.baseAddress, iov_len: mb.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                    var mh = msghdr()
                    mh.msg_iov = iovp
                    mh.msg_iovlen = 1
                    mh.msg_control = UnsafeMutableRawPointer(cb.baseAddress)
                    mh.msg_controllen = socklen_t(cb.count)
                    return recvmsg(sock, &mh, 0)
                }
            }
        }
        guard received > 0 else { return nil }
        // The fd sits at offset 12 in the cmsg buffer (after the 12-byte cmsghdr).
        let level = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        let type = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
        guard level == Int32(SOL_SOCKET), type == 1 else { return nil }
        let fd = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
        let msg = String(decoding: msgBuf[0..<received], as: UTF8.self)
        return (msg, fd)
    }
}
