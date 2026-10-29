import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Security

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
///
/// A root helper acting for whoever connects must not do more than the app
/// needs (the Tailworm class: tailscaled forwarding for unprivileged users).
/// So it serves only a caller signed like itself, routes only a private /24
/// nothing else routes yet, and holds at most `maxTunnels` at once.
enum FatClientTunnelDaemon {
    static let socketPath = "/var/run/io.bromure.fatclient-tunnel.sock"
    static let maxTunnels = 16

    private static let slotLock = NSLock()
    private static var activeTunnels = 0

    /// Take one of the `maxTunnels` slots; false when they're all held.
    static func reserveSlot() -> Bool {
        slotLock.lock(); defer { slotLock.unlock() }
        guard activeTunnels < maxTunnels else { return false }
        activeTunnels += 1
        return true
    }

    static func releaseSlot() {
        slotLock.lock(); activeTunnels = max(0, activeTunnels - 1); slotLock.unlock()
    }

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
        // Anyone may connect; each connection is checked against the console
        // user AT THAT MOMENT. The socket used to be chowned to the console
        // owner at start -- and launchd starts this at boot, before anyone
        // logs in, when /dev/console is root's: the user's app then got
        // EACCES on every connect, reboot after reboot ("helper isn't
        // reachable" with the helper enabled).
        chmod(socketPath, 0o666)
        if selfRequirement == nil {
            FileHandle.standardError.write(Data("tunnel-helper: can't pin its own signature; only root is served\n".utf8))
        }
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }
            var uid: uid_t = 0, gid: gid_t = 0
            let peer: uid_t? = getpeereid(cfd, &uid, &gid) == 0 ? uid : nil
            guard let peer, peerAllowed(peer, console: consoleUID()) else {
                let why = "ERR denied: uid \(peer.map(String.init) ?? "?") isn't the console user (\(consoleUID().map(String.init) ?? "nobody"))\n"
                _ = why.withCString { Darwin.write(cfd, $0, strlen($0)) }
                close(cfd); continue
            }
            // The console user may run anything; only Bromure gets a tunnel.
            guard peer == 0 || peerSignedLikeSelf(cfd) else {
                let why = "ERR unsigned: the caller isn't signed like this helper\n"
                _ = why.withCString { Darwin.write(cfd, $0, strlen($0)) }
                close(cfd); continue
            }
            guard reserveSlot() else {
                let why = "ERR busy: \(maxTunnels) tunnels already open\n"
                _ = why.withCString { Darwin.write(cfd, $0, strlen($0)) }
                close(cfd); continue
            }
            Thread.detachNewThread { defer { releaseSlot() }; serve(cfd) }
        }
        exit(0)
    }

    /// Whoever owns /dev/console now (the logged-in GUI user); nil when it
    /// can't be read.
    static func consoleUID() -> uid_t? {
        var st = stat()
        return stat("/dev/console", &st) == 0 ? st.st_uid : nil
    }

    /// Only the console user (who runs the app) or root may set up a tunnel:
    /// routes are system-wide.
    static func peerAllowed(_ peer: uid_t, console: uid_t?) -> Bool {
        peer == 0 || (console.map { $0 != 0 && $0 == peer } ?? false)
    }

    /// One tunnel: SETUP → create utun + route + pass the fd; hold until the app
    /// disconnects, then delete the route.
    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        // A caller that never sends SETUP doesn't keep its slot.
        setReceiveTimeout(fd, seconds: 10)
        // Each failure says which step and why: the app shows it as is.
        func fail(_ why: String) {
            let line = "ERR " + why.replacingOccurrences(of: "\n", with: " ") + "\n"
            _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        }
        let cidr: String
        switch admit(readLine(fd), routeGet: { run("/sbin/route", ["-n", "get", $0]) }) {
        case .success(let c): cidr = c
        case .failure(let refusal): fail(refusal.reason); return
        }
        setReceiveTimeout(fd, seconds: 0)   // the hold below lasts the tunnel's lifetime
        guard let (utunFD, name) = openUtun() else {
            fail("utun: \(String(cString: strerror(errno)))"); return
        }
        let ifc = run("/sbin/ifconfig", [name, linkAddr(name), linkPeer(name), "netmask", "255.255.255.252", "up"])
        guard ifc.ok else { Darwin.close(utunFD); fail("ifconfig \(name): \(ifc.output)"); return }
        let rt = run("/sbin/route", ["-n", "add", "-net", cidr, "-interface", name])
        guard rt.ok else { Darwin.close(utunFD); fail("route \(cidr): \(rt.output)"); return }
        // Hand the utun fd to the app; keep our own ref so the interface survives
        // until we delete the route on teardown.
        _ = sendFD(fd, fd: utunFD, message: "OK \(name)\n")
        // Block until the app disconnects (EOF) or sends anything → teardown.
        _ = readLine(fd)
        _ = run("/sbin/route", ["-n", "delete", "-net", cidr])
        Darwin.close(utunFD)   // drops the interface (app's passed fd may still hold it briefly)
    }

    struct Refusal: Error, Equatable { let reason: String }

    /// What a SETUP line may route: one private (RFC 1918 or CGNAT) /24, the
    /// shape of every Bromure workspace subnet and fleet alias, that no other
    /// route covers yet. `routeGet` runs `route -n get <network>`. Returns the
    /// canonical "a.b.c.0/24", or why not (the text after "ERR ").
    static func admit(_ line: String?,
                      routeGet: (String) -> (ok: Bool, output: String)) -> Result<String, Refusal> {
        guard let line, line.hasPrefix("SETUP ") else { return .failure(Refusal(reason: "bad request")) }
        let asked = String(line.dropFirst("SETUP ".count)).trimmingCharacters(in: .whitespaces)
        guard let cidr = privateSlash24(asked) else {
            return .failure(Refusal(reason: "cidr \(asked.prefix(64)): not a private /24 network"))
        }
        let net = String(cidr.dropLast(3))
        let lookup = routeGet(net)
        // "not in table" (no default route either) fails: nothing covers it.
        if lookup.ok, let taken = coveringRoute(lookup.output) {
            return .failure(Refusal(reason: "route taken: \(cidr) is already routed to \(taken)"))
        }
        return .success(cidr)
    }

    /// "a.b.c.0/24" in 10/8, 172.16/12, 192.168/16 or 100.64/10, strictly
    /// spelled (no host bits, no leading zeros); nil otherwise.
    static func privateSlash24(_ s: String) -> String? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "24" else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var o: [Int] = []
        for t in octets {
            guard (1...3).contains(t.count), t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber),
                  t == "0" || !t.hasPrefix("0"), let v = Int(t), v <= 255 else { return nil }
            o.append(v)
        }
        guard o[3] == 0 else { return nil }
        let isPrivate = o[0] == 10
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 100 && (64...127).contains(o[1]))
        return isPrivate ? "\(o[0]).\(o[1]).\(o[2]).0/24" : nil
    }

    /// The route `route -n get` found, unless it's the default route: any other
    /// one already claims these addresses (a LAN, a VPN, another tunnel).
    static func coveringRoute(_ output: String) -> String? {
        var dest: String?, mask: String?, iface: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon], value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "destination": dest = value
            case "mask": mask = value
            case "interface": iface = value
            default: break
            }
        }
        guard let dest, dest != "default" else { return nil }
        return dest + (mask.map { " mask \($0)" } ?? "") + (iface.map { " on \($0)" } ?? "")
    }

    /// Whether the peer of `fd` passes this helper's own designated requirement
    /// (same team and identifier, or the same cdhash for an ad-hoc build). The
    /// audit token is the peer's at connect time, so a pid reuse can't fool it.
    static func peerSignedLikeSelf(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, 0 /*SOL_LOCAL*/, 0x006 /*LOCAL_PEERTOKEN*/, &token, &len) == 0 else { return false }
        return signedLikeSelf(auditToken: token)
    }

    static func signedLikeSelf(auditToken token: audit_token_t) -> Bool {
        guard let requirement = selfRequirement else { return false }
        return signed(auditToken: token, satisfying: requirement)
    }

    static func signed(auditToken token: audit_token_t, satisfying requirement: SecRequirement) -> Bool {
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary,
                                             [], &peer) == errSecSuccess, let peer else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }

    /// This helper's designated requirement, pinned once for the process's
    /// lifetime. Read again per connection, it would come from whatever file
    /// sits at the helper's path NOW: a console user who can write the bundle
    /// (~/Applications, a dev build) swaps in an ad-hoc binary — the running
    /// root helper keeps the old vnode — and its process then passes. So the
    /// running code must match its file when it's pinned (checkValidity on
    /// self compares the kernel's cdhash with the disk's), or nothing is.
    static let selfRequirement: SecRequirement? = {
        var me: SecCode?, myStatic: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCheckValidity(me, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
              SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    private static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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

    /// Runs a tool; on failure, what it printed (stderr, then stdout).
    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "\(error.localizedDescription)") }
        let e = err.fileHandleForReading.readDataToEndOfFile()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = [e, o].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(p.terminationStatus)"
        return (p.terminationStatus == 0, text)
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
        let msg = String(decoding: msgBuf[0..<received], as: UTF8.self)
        // The fd sits at offset 12 in the cmsg buffer (after the 12-byte cmsghdr).
        // None (an `ERR …` reply): the message still says why, fd -1.
        let level = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        let type = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
        guard level == Int32(SOL_SOCKET), type == 1 else { return (msg, -1) }
        let fd = cmsgBuf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
        return (msg, fd)
    }
}
