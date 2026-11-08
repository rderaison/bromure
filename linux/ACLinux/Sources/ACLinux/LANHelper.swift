import Foundation
import Glibc
import NIOConcurrencyHelpers
import SandboxEngine

/// `bromure-ac lan-helper` (bromure-lan.service, CAP_NET_ADMIN and
/// CAP_NET_BIND_SERVICE only): the one process on a shared server that puts
/// LAN pool addresses on the LAN interface. A user's daemon connects to its
/// socket; the helper knows the caller by SO_PEERCRED and publishes only
/// inside that user's grants (LANPoolsFile). Publishing an address adds it as
/// a /32 on the interface (the kernel answers ARP, arp_notify announces it)
/// and binds the Service's ports there; every accepted TCP connection, and
/// each UDP port's socket, is handed to the owning daemon (SCM_RIGHTS), which
/// relays it into its cluster. The helper never reads the bytes. A daemon
/// that disconnects loses its addresses at once. The helper only ever takes
/// off a /32 it put there itself: those of this run, and those in its record
/// (StateDirectory) from a run that crashed, swept at start when still inside
/// a grant. A /32 someone else added is used but never removed. A
/// publication lives only as long as its owner's grant: every change of the
/// grants (checked every 0.5 s, and in full every 5 s) withdraws those
/// outside it, telling the owner (`{"revoked":…}`).
///
/// Protocol: newline-delimited JSON. Requests carry an `id`, answered by a
/// line with the same `id`; the helper also sends `{"conn":…}` and
/// `{"udp":…}` lines, each with one fd attached.
// @port-skip linux-only: multi-user LAN pools (macOS: KubeLANAnnouncer, single-user)
public final class LANHelper: @unchecked Sendable {
    // @port-skip linux-only: LAN helper
    public static var defaultSocket: String {
        ProcessInfo.processInfo.environment["BROMURE_LAN_SOCKET"] ?? "/run/bromure-lan/lan.sock"
    }

    let poolsPath: String
    let socketPath: String
    let recordPath: String
    /// A publish this soon after the grants file changed is refused: every
    /// daemon must have re-read it (LANPools checks every 0.5 s) first.
    static let settle: TimeInterval = 2
    private let lock = NSLock()
    private var nextConn = 0
    private var listenFD: Int32 = -1
    private var running = true
    /// Connection → its fd and the caller's uid (SO_PEERCRED).
    private var conns: [Int: (fd: Int32, uid: uid_t, writeLock: NSLock)] = [:]
    /// Serializes publish and withdraw (address bookkeeping); taken before `lock`.
    private let addrLock = NSLock()
    /// The /32s this helper added (address → interface), mirrored in `recordPath`.
    private var added: [UInt32: String] = [:]
    /// (ip, port, udp) → the listener, its owner connection and Service.
    private var listeners: [Key: Listener] = [:]
    struct Key: Hashable { let ip: UInt32; let port: UInt16; let udp: Bool }
    final class Listener { let fd: Int32; let conn: Int; let service: String; let owner: String
        // @port-skip linux-only: LAN helper
        init(fd: Int32, conn: Int, service: String, owner: String) { self.fd = fd; self.conn = conn; self.service = service; self.owner = owner }
    }

    // @port-skip linux-only: LAN helper
    public init(poolsPath: String = LANPoolsFile.defaultPath, socketPath: String = LANHelper.defaultSocket,
                recordPath: String = LANHelper.defaultRecord) {
        self.poolsPath = poolsPath
        self.socketPath = socketPath
        self.recordPath = recordPath
    }

    // @port-skip linux-only: LAN helper
    public static var defaultRecord: String {
        ProcessInfo.processInfo.environment["BROMURE_LAN_STATE"] ?? "/var/lib/bromure-lan/added.json"
    }

    // MARK: Running

    /// Clean up orphans, then serve until the process ends.
    // @port-skip linux-only: LAN helper
    public func run() throws {
        removeOrphans()
        let file = try? LANPoolsFile.load(poolsPath)
        Thread.detachNewThread { [self] in watchGrants() }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw LANPoolsAdmin.Failure.message("socket: \(errno)") }
        unlink(socketPath)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in
            for (i, c) in socketPath.utf8.prefix(b.count - 1).enumerated() { b[i] = c }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else { throw LANPoolsAdmin.Failure.message("can't listen on \(socketPath): \(errno)") }
        // Any local user may connect; what they may do is their grant (SO_PEERCRED).
        chmod(socketPath, 0o666)
        lock.lock(); listenFD = fd; lock.unlock()
        log("listening on \(socketPath)\(file?.resolvedInterface().map { ", pools on \($0)" } ?? "")")
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; break }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)   // not into the `ip` children
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    /// Stops accepting (tests); connections already open stay.
    // @port-skip linux-only: LAN helper
    public func stop() {
        lock.lock(); let fd = listenFD; listenFD = -1; running = false; lock.unlock()
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    /// The /32s a crashed run of this helper added (its record) that are
    /// still on their interface and inside a grant: none is published now.
    /// A recorded address no longer granted is left alone, and kept in the
    /// record; one that is gone is dropped from it.
    // @port-skip linux-only: LAN helper
    func removeOrphans() {
        let recorded = Self.readRecord(recordPath)
        guard !recorded.isEmpty else { return }
        guard let file = try? LANPoolsFile.load(poolsPath, requireFile: true, requireInterface: false) else {
            log("the LAN pools file is missing or doesn't read: leftover addresses kept for now")
            added = recorded.filter { LANRoute.validInterfaceName($0.value) && Self.slash32s(on: $0.value).contains($0.key) }
            Self.writeRecord(added, to: recordPath)
            return
        }
        let granted = file.allAddresses
        var keep: [UInt32: String] = [:]
        for (ip, iface) in recorded where LANRoute.validInterfaceName(iface) && Self.slash32s(on: iface).contains(ip) {
            if granted.contains(ip) {
                _ = Self.ip(["-4", "addr", "del", "\(VMNetSwitchText.ip(ip))/32", "dev", iface])
                log("removed a leftover \(VMNetSwitchText.ip(ip)) from \(iface)")
            } else {
                keep[ip] = iface
                log("left \(VMNetSwitchText.ip(ip)) on \(iface): this helper added it, but it isn't granted any more")
            }
        }
        added = keep
        Self.writeRecord(keep, to: recordPath)
    }

    // MARK: Grants

    /// Re-checks every live publication against its owner's grant when the
    /// file changes (and every 5 s: an account's uid can change too). A
    /// file that is missing or doesn't read keeps the last good grants, so
    /// publications inside them stay.
    // @port-skip linux-only: LAN helper
    private func watchGrants() {
        var mtime: timespec?
        var full = ContinuousClock.now
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            lock.lock(); let on = running; lock.unlock()
            guard on else { return }
            var st = stat()
            let m: timespec? = stat(poolsPath, &st) == 0 ? st.st_mtim : nil
            let changed = m?.tv_sec != mtime?.tv_sec || m?.tv_nsec != mtime?.tv_nsec
            guard changed || ContinuousClock.now - full > .seconds(5) else { continue }
            mtime = m
            full = .now
            guard m != nil, let file = try? LANPoolsFile.load(poolsPath, requireFile: true, requireInterface: false) else { continue }
            revokeOutside(file)
        }
    }

    /// Withdraws each connection's publications its uid's grant no longer
    /// holds. Under `addrLock`, as publish's whole check-then-bind is: a
    /// publish that read the grants before this file is either finished
    /// (its listeners are in the snapshot) or not started (it reads this file).
    // @port-skip linux-only: LAN helper
    func revokeOutside(_ file: LANPoolsFile) {
        struct Live: Hashable { let conn: Int; let ip: UInt32 }
        addrLock.lock()
        lock.lock()
        let live = Set(listeners.map { Live(conn: $0.value.conn, ip: $0.key.ip) })
        let uids = conns.mapValues(\.uid)
        lock.unlock()
        var grants: [uid_t: Set<UInt32>] = [:]
        var notices: [Notice] = []
        for l in live {
            guard let uid = uids[l.conn] else { continue }
            if grants[uid] == nil { grants[uid] = file.addresses(ofUID: uid) }
            if grants[uid]?.contains(l.ip) != true {
                notices += revokeLocked(conn: l.conn, ip: l.ip, why: "\(VMNetSwitchText.ip(l.ip)) isn't in uid \(uid)'s LAN address pool any more")
            }
        }
        addrLock.unlock()
        notify(notices)
    }

    /// A line for a connection, sent once `addrLock` is released (a daemon
    /// slow to read must never hold up everyone's publishing).
    struct Notice { let conn: Int; let msg: [String: Any] }

    /// Ends connection `conn`'s publications on `ip` and tells it which.
    // @port-skip linux-only: LAN helper
    private func revoke(conn: Int, ip: UInt32, why: String) {
        addrLock.lock()
        let notices = revokeLocked(conn: conn, ip: ip, why: why)
        addrLock.unlock()
        notify(notices)
    }

    /// revoke's work, `addrLock` held; returns the lines to send.
    // @port-skip linux-only: LAN helper
    private func revokeLocked(conn: Int, ip: UInt32, why: String) -> [Notice] {
        lock.lock()
        let services = Set(listeners.filter { $0.key.ip == ip && $0.value.conn == conn }.map(\.value.service))
        lock.unlock()
        guard !services.isEmpty else { return [] }
        withdrawLocked(conn: conn) { k, _ in k.ip == ip }
        log("revoked \(VMNetSwitchText.ip(ip)) (\(services.sorted().joined(separator: ", "))): \(why)")
        return services.sorted().map { Notice(conn: conn, msg: ["revoked": true, "ip": VMNetSwitchText.ip(ip), "service": $0, "error": why]) }
    }

    // @port-skip linux-only: LAN helper
    private func notify(_ notices: [Notice]) {
        for n in notices { send(conn: n.conn, n.msg, fd: nil) }
    }

    // MARK: A daemon's connection

    // @port-skip linux-only: LAN helper
    private func serve(_ fd: Int32) {
        var cred = LANPeerCred()
        var len = socklen_t(MemoryLayout<LANPeerCred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 else { close(fd); return }
        // The caller is its uid; the name is for the log only.
        let uid = cred.uid
        let label = "\(LANAccount.name(of: uid) ?? "?") (uid \(uid))"
        lock.lock()
        nextConn += 1
        let id = nextConn
        conns[id] = (fd, uid, NSLock())
        lock.unlock()
        log("\(label) connected")
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            acc.append(contentsOf: buf[0..<n])
            while let nl = acc.firstIndex(of: 0x0A) {
                let line = acc[acc.startIndex..<nl]
                acc = Data(acc[(nl + 1)...])
                guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                let reply = handle(req, conn: id, uid: uid)
                send(conn: id, reply.merging(["id": req["id"] ?? NSNull()]) { a, _ in a }, fd: nil)
            }
            if acc.count > 1 << 20 { break }   // a peer that never ends a line
        }
        // Gone: everything it published goes too, at once.
        withdraw(conn: id) { _, _ in true }
        // Removed, then closed under its write lock: a send that got the
        // connection before it went finishes first, and one after sees it gone.
        lock.lock(); let gone = conns.removeValue(forKey: id); lock.unlock()
        gone?.writeLock.lock()
        close(fd)
        gone?.writeLock.unlock()
        log("\(label) disconnected; its addresses withdrawn")
    }

    // @port-skip linux-only: LAN helper
    private func handle(_ req: [String: Any], conn: Int, uid: uid_t) -> [String: Any] {
        switch req["op"] as? String {
        case "whoami":
            // Who the helper takes the caller for: its uid, and the grants that are its.
            let users = (try? LANPoolsFile.load(poolsPath, requireInterface: false))?.users(ofUID: uid) ?? []
            return ["ok": true, "uid": Int(uid), "grants": users]
        case "publish":
            guard let ipText = req["ip"] as? String, let ip = VMNetSwitch.parseIPv4(ipText),
                  let service = req["service"] as? String, !service.isEmpty, service.count < 512,
                  let owner = req["owner"] as? String, UUID(uuidString: owner) != nil,
                  let ports = req["ports"] as? [[String: Any]], !ports.isEmpty, ports.count <= 64 else {
                return ["ok": false, "error": "bad publish"]
            }
            let keys: [(UInt16, Bool)] = ports.compactMap { p in
                guard let n = p["port"] as? Int, n > 0, n < 65536 else { return nil }
                return (UInt16(n), (p["udp"] as? Bool) ?? false)
            }
            guard keys.count == ports.count else { return ["ok": false, "error": "bad port"] }
            addrLock.lock()
            let (reply, udpFDs) = publish(ip: ip, ports: keys, service: service, owner: owner, conn: conn, uid: uid)
            addrLock.unlock()
            if reply["ok"] as? Bool != true {
                log("uid \(uid): publish \(ipText) refused: \(reply["error"] ?? "")")
                // Outside the caller's grant: what it still had there goes too.
                if reply["grantMiss"] as? Bool == true { revoke(conn: conn, ip: ip, why: (reply["error"] as? String) ?? "not granted") }
            }
            // Each UDP socket goes to the daemon once; it receives and answers on it.
            for (port, fd) in udpFDs {
                send(conn: conn, ["udp": true, "ip": ipText, "port": Int(port), "service": service], fd: fd)
            }
            return reply
        case "withdraw":
            guard let ipText = req["ip"] as? String, let ip = VMNetSwitch.parseIPv4(ipText),
                  let service = req["service"] as? String else { return ["ok": false, "error": "bad withdraw"] }
            withdraw(conn: conn) { $0.ip == ip && $1.service == service }
            return ["ok": true]
        case "withdrawAll":
            guard let owner = req["owner"] as? String else { return ["ok": false, "error": "bad withdrawAll"] }
            withdraw(conn: conn) { $1.owner == owner }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown op"]
        }
    }

    /// `ip`'s Service ports for this connection: only inside the caller's
    /// own grants (by uid); the address goes on the interface if it isn't
    /// yet; a port already taken (by anything on the host) is a conflict for
    /// the caller. Returns the reply and the UDP sockets to hand over.
    /// Called with `addrLock` held.
    // @port-skip linux-only: LAN helper
    private func publish(ip: UInt32, ports: [(UInt16, Bool)], service: String, owner: String,
                         conn: Int, uid: uid_t) -> ([String: Any], [(UInt16, Int32)]) {
        // A refusal says what kind it is: `grantMiss` (lasting: the caller's
        // publications there end too), `transient` (the file, for now), or
        // `retryAfter` seconds.
        func refuse(_ why: String, _ kind: [String: Any] = [:]) -> ([String: Any], [(UInt16, Int32)]) {
            (["ok": false, "error": why].merging(kind) { a, _ in a }, [])
        }
        let file: LANPoolsFile
        do { file = try LANPoolsFile.load(poolsPath, requireFile: true) } catch {
            return refuse("the LAN pools file doesn't read: \(error)", ["transient": true])
        }
        guard file.addresses(ofUID: uid).contains(ip) else {
            return refuse("\(VMNetSwitchText.ip(ip)) isn't in uid \(uid)'s LAN address pool", ["grantMiss": true])
        }
        if let m = try? FileManager.default.attributesOfItem(atPath: poolsPath)[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < Self.settle {
            let wait = Self.settle - Date().timeIntervalSince(m) + 0.1
            return refuse("the LAN pools just changed; try again in a moment", ["retryAfter": wait])
        }
        guard let iface = file.resolvedInterface() else { return refuse("no LAN interface") }
        if let pause = Self.publishPauseForTesting.withLockedValue({ $0 }) { Thread.sleep(forTimeInterval: pause) }
        lock.lock()
        let taken = listeners.contains { $0.key.ip == ip && $0.value.conn != conn }
        lock.unlock()
        // Two of one user's daemons can't share an address (one daemon per
        // user); after a reassignment the old owner's is going (revokeOutside).
        if taken { return refuse("\(VMNetSwitchText.ip(ip)) is published by another connection", ["retryAfter": 2.0]) }
        // Already on the interface: this helper's if it's in `added`, else
        // someone else's (used, never removed).
        if !Self.slash32s(on: iface).contains(ip) {
            // Recorded before it's added: a crash in between leaves a record
            // the next start sweeps (it checks the address is there).
            added[ip] = iface
            Self.writeRecord(added, to: recordPath)
            let (rc, out) = Self.ip(["-4", "addr", "add", "\(VMNetSwitchText.ip(ip))/32", "dev", iface])
            if rc != 0 {
                added[ip] = nil
                Self.writeRecord(added, to: recordPath)
                return refuse("couldn't add \(VMNetSwitchText.ip(ip)) to \(iface): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            log("uid \(uid): \(VMNetSwitchText.ip(ip)) on \(iface)")
        }
        var conflicts: [[String: Any]] = []
        var udpFDs: [(UInt16, Int32)] = []
        for (port, udp) in ports {
            let key = Key(ip: ip, port: port, udp: udp)
            lock.lock()
            let mine = listeners[key]
            lock.unlock()
            if let mine {
                if mine.service != service { conflicts.append(["port": Int(port), "udp": udp]) }
                continue
            }
            let fd = Self.bindSocket(ip: ip, port: port, udp: udp)
            guard fd >= 0 else { conflicts.append(["port": Int(port), "udp": udp]); continue }
            lock.lock()
            listeners[key] = Listener(fd: fd, conn: conn, service: service, owner: owner)
            lock.unlock()
            if udp { udpFDs.append((port, fd)) } else { Thread.detachNewThread { [self] in acceptLoop(key, fd: fd) } }
        }
        return (["ok": true, "conflicts": conflicts], udpFDs)
    }

    // @port-skip linux-only: LAN helper
    private func acceptLoop(_ key: Key, fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            // Shut: withdrawn. The loop owns the listener and closes it (a
            // close in withdraw could land while this loop is between
            // accepts, and the next accept would take another socket's
            // connection under the reused number).
            if c < 0 {
                switch errno {
                case EINVAL, EBADF: close(fd); return          // shut by withdraw
                case EMFILE, ENFILE, ENOBUFS, ENOMEM: usleep(100_000); continue
                default: continue                              // EINTR, a connection aborted while queued
                }
            }
            lock.lock()
            let l = listeners[key]
            lock.unlock()
            guard let l, l.fd == fd else { close(c); close(fd); return }
            send(conn: l.conn, ["conn": true, "ip": VMNetSwitchText.ip(key.ip), "port": Int(key.port), "service": l.service], fd: c)
            close(c)   // the daemon has its own copy now
        }
    }

    /// Closes the connection's listeners that `match`, and takes an address
    /// off the interface once nothing is published on it any more, if this
    /// helper added it.
    // @port-skip linux-only: LAN helper
    private func withdraw(conn: Int, _ match: (Key, Listener) -> Bool) {
        addrLock.lock()
        defer { addrLock.unlock() }
        withdrawLocked(conn: conn, match)
    }

    /// withdraw's work, `addrLock` held.
    // @port-skip linux-only: LAN helper
    private func withdrawLocked(conn: Int, _ match: (Key, Listener) -> Bool) {
        lock.lock()
        let gone = listeners.filter { $0.value.conn == conn && match($0.key, $0.value) }
        for (k, _) in gone { listeners[k] = nil }
        let stillUsed = Set(listeners.keys.map(\.ip))
        lock.unlock()
        // A TCP listener is shut, which ends its acceptLoop; the loop closes
        // it. A UDP socket has no loop here: closed now.
        for (k, l) in gone { shutdown(l.fd, Int32(SHUT_RDWR)); if k.udp { close(l.fd) } }
        for ip in Set(gone.keys.map(\.ip)) where !stillUsed.contains(ip) {
            if let iface = added[ip] {
                _ = Self.ip(["-4", "addr", "del", "\(VMNetSwitchText.ip(ip))/32", "dev", iface])
                added[ip] = nil
                Self.writeRecord(added, to: recordPath)
                log("\(VMNetSwitchText.ip(ip)) withdrawn from \(iface)")
            } else {
                log("\(VMNetSwitchText.ip(ip)) withdrawn (its /32 wasn't added by this helper: left on the interface)")
            }
        }
    }

    /// One line to connection `conn`, with `fd` attached if given.
    // @port-skip linux-only: LAN helper
    private func send(conn: Int, _ msg: [String: Any], fd: Int32?) {
        lock.lock()
        let c = conns[conn]
        lock.unlock()
        guard let c, var line = try? JSONSerialization.data(withJSONObject: msg) else { return }
        line.append(0x0A)
        c.writeLock.lock()
        defer { c.writeLock.unlock() }
        // Still open (serve closes it under this lock once it's removed).
        lock.lock(); let open = conns[conn] != nil; lock.unlock()
        guard open else { return }
        if let fd { _ = LANFD.send(c.fd, line, fd: fd) } else { _ = LANFD.send(c.fd, line, fd: nil) }
    }

    // MARK: Host plumbing

    /// Tests: a pause between publish's checks and its binding (the grants
    /// changing in between), and a stand-in for `ip` (no CAP_NET_ADMIN).
    static let publishPauseForTesting = NIOLockedValueBox<TimeInterval?>(nil)
    static let ipForTesting = NIOLockedValueBox<(@Sendable ([String]) -> (Int32, String))?>(nil)

    /// The record of added /32s: [{"ip": …, "interface": …}].
    // @port-skip linux-only: LAN helper
    static func readRecord(_ path: String) -> [UInt32: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else { return [:] }
        var out: [UInt32: String] = [:]
        for e in list { if let t = e["ip"], let ip = VMNetSwitch.parseIPv4(t), let i = e["interface"] { out[ip] = i } }
        return out
    }

    // @port-skip linux-only: LAN helper
    static func writeRecord(_ record: [UInt32: String], to path: String) {
        let list = record.sorted { $0.key < $1.key }.map { ["ip": VMNetSwitchText.ip($0.key), "interface": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        let tmp = path + ".tmp"
        unlink(tmp)   // a stale one from a failed write never blocks this one
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else {
            unlink(tmp)
            FileHandle.standardError.write(Data("bromure-lan: couldn't write \(path)\n".utf8))
            return
        }
    }

    /// A TCP listener or UDP socket bound to ip:port; -1 if the port is taken.
    // @port-skip linux-only: LAN helper
    static func bindSocket(ip: UInt32, port: UInt16, udp: Bool) -> Int32 {
        let fd = socket(AF_INET, Int32((udp ? SOCK_DGRAM : SOCK_STREAM).rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        if !udp { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = ip.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, udp || listen(fd, 64) == 0 else { close(fd); return -1 }
        return fd
    }

    /// The /32 IPv4 addresses on `iface`.
    // @port-skip linux-only: LAN helper
    static func slash32s(on iface: String) -> Set<UInt32> {
        let (_, out) = ip(["-4", "-o", "addr", "show", "dev", iface])
        var s = Set<UInt32>()
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard let i = f.firstIndex(of: "inet"), i + 1 < f.count, f[i + 1].hasSuffix("/32"),
                  let a = VMNetSwitch.parseIPv4(String(f[i + 1].dropLast(3))) else { continue }
            s.insert(a)
        }
        return s
    }

    /// `ip …` (iproute2), its exit status and output.
    // @port-skip linux-only: LAN helper
    static func ip(_ args: [String]) -> (Int32, String) {
        if let fake = ipForTesting.withLockedValue({ $0 }) { return fake(args) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/usr/sbin/ip") ? "/usr/sbin/ip" : "/sbin/ip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    // @port-skip linux-only: LAN helper
    private func log(_ s: String) { FileHandle.standardError.write(Data("bromure-lan: \(s)\n".utf8)) }
}

/// A message with an optional fd attached (SCM_RIGHTS), and its receive.
// @port-skip linux-only: multi-user LAN pools
enum LANFD {
    /// Writes `data` (all of it), the fd riding on the first chunk.
    // @port-skip linux-only: SCM_RIGHTS
    static func send(_ sock: Int32, _ data: Data, fd: Int32?) -> Bool {
        var off = 0
        var attach = fd
        let space = lanCMSGSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: space)
        while off < data.count {
            let n: Int = data.withUnsafeBytes { raw -> Int in
                var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress! + off), iov_len: data.count - off)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    guard let f = attach else { return sendmsg(sock, &msg, Int32(MSG_NOSIGNAL)) }
                    return control.withUnsafeMutableBytes { cb -> Int in
                        msg.msg_control = cb.baseAddress
                        msg.msg_controllen = space
                        let h = cb.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                        h.pointee.cmsg_level = SOL_SOCKET
                        h.pointee.cmsg_type = Int32(SCM_RIGHTS)
                        h.pointee.cmsg_len = lanCMSGLen(MemoryLayout<Int32>.size)
                        (cb.baseAddress! + lanCMSGDataOffset()).storeBytes(of: f, as: Int32.self)
                        return sendmsg(sock, &msg, Int32(MSG_NOSIGNAL))
                    }
                }
            }
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
            attach = nil
        }
        return true
    }

    /// Reads what's there, and the fds that came with it.
    // @port-skip linux-only: SCM_RIGHTS
    static func receive(_ sock: Int32, _ buf: inout [UInt8]) -> (count: Int, fds: [Int32]) {
        let space = lanCMSGSpace(MemoryLayout<Int32>.size * 8)
        var control = [UInt8](repeating: 0, count: space)
        var fds: [Int32] = []
        let n: Int = buf.withUnsafeMutableBytes { raw in
            var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            return withUnsafeMutablePointer(to: &iov) { iovp in
                control.withUnsafeMutableBytes { cb in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = cb.baseAddress
                    msg.msg_controllen = space
                    let r = recvmsg(sock, &msg, Int32(MSG_CMSG_CLOEXEC))
                    guard r > 0, msg.msg_controllen >= MemoryLayout<cmsghdr>.size else { return r }
                    let h = cb.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                    if h.pointee.cmsg_level == SOL_SOCKET, h.pointee.cmsg_type == Int32(SCM_RIGHTS) {
                        let count = (Int(h.pointee.cmsg_len) - lanCMSGDataOffset()) / MemoryLayout<Int32>.size
                        for k in 0..<max(0, count) {
                            fds.append((cb.baseAddress! + lanCMSGDataOffset() + k * 4).load(as: Int32.self))
                        }
                    }
                    return r
                }
            }
        }
        return (n, fds)
    }
}

/// struct ucred (pid, uid, gid), which Glibc only declares under _GNU_SOURCE.
// @port-skip linux-only: SO_PEERCRED
struct LANPeerCred { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }

// CMSG_* are macros Swift doesn't import.
// @port-skip linux-only: SCM_RIGHTS
private func lanAlign(_ n: Int) -> Int { (n + MemoryLayout<Int>.size - 1) & ~(MemoryLayout<Int>.size - 1) }
// @port-skip linux-only: SCM_RIGHTS
private func lanCMSGDataOffset() -> Int { lanAlign(MemoryLayout<cmsghdr>.size) }
// @port-skip linux-only: SCM_RIGHTS
private func lanCMSGLen(_ n: Int) -> Int { lanCMSGDataOffset() + n }
// @port-skip linux-only: SCM_RIGHTS
private func lanCMSGSpace(_ n: Int) -> Int { lanCMSGDataOffset() + lanAlign(n) }
