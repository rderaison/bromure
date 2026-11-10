import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// The multi-user server's front door: one SSH listener for every Bromure
/// user on the host, the shared RemoteAccessServer with this router behind it.
///
/// Trust boundary: the gateway's account may use every user's control
/// socket, so it does authentication and moves bytes, nothing else. Each
/// user's own daemon holds that user's keys and enrollment codes and decides
/// everything else (which VMs exist, where a forward may go). The SSH user
/// name picks the account: `/run/bromure-ac/sock/<name>.sock`, made by
/// `bromure-ac@<name>.socket` (owner the user, group the gateway's, 0660).
// @port-skip linux-only: multi-user Linux server (macOS serves one user)
public final class GatewayRouter: RemoteAccountRouter {
    let socketDir: String
    /// Every password check takes at least this long, an unknown account's
    /// included: the timing tells nothing about which names exist.
    static let passwordFloor: Duration = .milliseconds(150)
    /// Per account: its keys, and which of them are machine-only (an agent
    /// host's, by device), as its daemon last listed them.
    private let keyCache = NIOLockedValueBox<[String: (keys: Set<NIOSSHPublicKey>, machine: [NIOSSHPublicKey: String],
                                                       at: ContinuousClock.Instant)]>([:])

    // @port-skip linux-only: multi-user gateway
    public init(socketDir: String) { self.socketDir = socketDir }

    /// A plausible account name with a socket: nil otherwise.
    // @port-skip linux-only: multi-user gateway
    func socket(for user: String) -> String? {
        let ok = !user.isEmpty && user.count <= 32
            && user.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }
            && !user.hasPrefix("-")
        guard ok else { return nil }
        let path = socketDir + "/" + user + ".sock"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Whether `key` opens `user`'s account, and a machine-only key's device
    /// (`bromure-account:machine:<device>`, as RemoteAccessServer
    /// .loadMachineOnlyKeys reads them on a single-user server), from one
    /// snapshot of its keys: a refetch that fails refuses the key.
    // @port-skip linux-only: multi-user gateway (macOS: RemoteAccessServer.loadMachineOnlyKeys)
    func keyAccess(user: String, key: NIOSSHPublicKey) -> RemoteKeyAccess? {
        guard let k = accountKeys(user: user), k.keys.contains(key) else { return nil }
        return k.machine[key].map { .machineOnly(device: $0) } ?? .full
    }

    // @port-skip linux-only: multi-user gateway
    private func accountKeys(user: String) -> (keys: Set<NIOSSHPublicKey>, machine: [NIOSSHPublicKey: String])? {
        guard let sock = socket(for: user) else { return nil }
        if let c = keyCache.withLockedValue({ $0[user] }), ContinuousClock.now - c.at < .seconds(3) { return (c.keys, c.machine) }
        guard let r = try? FirecrackerAPI.exchange(sock, "GET", "/remote/authorized-keys", nil, timeoutMs: 5000), r.ok,
              case .array(let lines)? = r.body?["keys"] else { return nil }
        var keys = Set<NIOSSHPublicKey>(), machine: [NIOSSHPublicKey: String] = [:]
        for case .string(let line) in lines {
            guard let pk = try? NIOSSHPublicKey(openSSHPublicKey: Self.keyField(line)) else { continue }
            keys.insert(pk)
            if let device = Self.machineDevice(line) { machine[pk] = device }
        }
        keyCache.withLockedValue { $0[user] = (keys, machine, .now) }
        return (keys, machine)
    }

    /// The device of an agent host's key line: its comment is
    /// `bromure-account:machine:<device>`. nil for any other line.
    // @port-skip linux-only: multi-user gateway
    static func machineDevice(_ line: String) -> String? {
        let f = line.split(separator: " ")
        guard let i = f.firstIndex(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") }), f.count > i + 2 else { return nil }
        let comment = f[(i + 2)...].joined(separator: " ")
        guard comment.hasPrefix(RemoteAccessServer.machineKeyMarker) else { return nil }
        let device = String(comment.dropFirst(RemoteAccessServer.machineKeyMarker.count))
        return device.isEmpty ? nil : device
    }

    /// `type base64` of an authorized_keys line (no options, no comment).
    // @port-skip linux-only: multi-user gateway
    static func keyField(_ line: String) -> String {
        let f = line.split(separator: " ")
        guard let i = f.firstIndex(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") }), f.count > i + 1 else { return line }
        return "\(f[i]) \(f[i + 1])"
    }

    // @port-skip linux-only: multi-user gateway
    func verifyPassword(user: String, password: String) -> Bool {
        let start = ContinuousClock.now
        var ok = false
        if let sock = socket(for: user),
           let r = try? FirecrackerAPI.exchange(sock, "POST", "/remote/code/check", ["code": .string(password)], timeoutMs: 5000) {
            ok = r.ok && r.body?["ok"] == .bool(true)
        }
        let left = Self.passwordFloor - (ContinuousClock.now - start)
        if left > .zero { Thread.sleep(forTimeInterval: Double(left.components.attoseconds) / 1e18 + Double(left.components.seconds)) }
        return ok
    }

    // @port-skip linux-only: multi-user gateway
    func controlSocketPath(user: String) -> String { socket(for: user) ?? "/nonexistent" }

    // @port-skip linux-only: multi-user gateway
    func forward(user: String, ip: String, port: Int?, completion: @escaping @Sendable (Int32) -> Void) {
        guard let sock = socket(for: user) else { completion(-1); return }
        var body: [String: JSONValue] = ["ip": .string(ip)]
        if let port { body["port"] = .number(Double(port)) } else { body["udp"] = true }
        let payload = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Self.openStream(sock, "POST", "/fatclient/forward", payload))
        }
    }

    // @port-skip linux-only: multi-user gateway
    func browserMCP(user: String, vm: String, completion: @escaping @Sendable (Int32) -> Void) {
        guard let sock = socket(for: user) else { completion(-1); return }
        let payload = (try? JSONEncoder().encode(JSONValue.object(["vm": .string(vm)]))) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Self.openStream(sock, "POST", "/fatclient/browser-mcp", payload))
        }
    }

    /// Sends one request and, on a 200, returns the connection with its
    /// response header consumed (what follows is the stream); -1 otherwise.
    // @port-skip linux-only: multi-user gateway
    static func openStream(_ path: String, _ method: String, _ target: String, _ body: Data) -> Int32 {
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in p.copyBytes(from: bytes); p[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let head = "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let req = Data(head.utf8) + body
        let sent = req.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        guard rc == 0, sent == req.count else { close(fd); return -1 }
        // Header byte by byte: nothing of the stream after it is consumed.
        var header = [UInt8](), c: UInt8 = 0
        while header.count < 8192, !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard recv(fd, &c, 1, 0) == 1 else { close(fd); return -1 }
            header.append(c)
        }
        guard String(decoding: header.prefix(12), as: UTF8.self).hasPrefix("HTTP/1.1 200") else { close(fd); return -1 }
        return fd
    }
}

/// `bromure-ac gateway`'s settings: `<state>/gateway.json`.
// @port-skip linux-only: multi-user gateway
public struct GatewaySettings: Codable, Sendable {
    public var port = 2222
    public var bindAddress = "0.0.0.0"
    /// Enrollment codes (`bromure-ac admin code <user>`) as SSH passwords.
    public var codeLogin = true
    public var socketDir = "/run/bromure-ac/sock"
    /// The P2P ingress (GatewayP2PIngress) when not systemd's socket
    /// (bromure-gw-p2p.socket): a path to bind, "" for none.
    public var p2pSocket: String?
    // @port-skip linux-only: multi-user gateway
    public init() {}
}

/// The gateway's P2P ingress: each user's P2P broker (that user's daemon)
/// hands it the connections its own port and its TURN relay accept, over
/// a Unix socket (bromure-gw-p2p.socket: /run/bromure-ac/p2p.sock, 0666, in
/// root's 0755 dir). Each connection is pinned, before anything is read
/// from it, to the account of the uid on its far end (SO_PEERCRED): it may
/// log in there and nowhere else, whatever user name the client gives.
/// Root, an unknown uid, or an account with no control socket: no pin, and
/// the connection is closed before the SSH banner. The socket's mode is no
/// gate; the pin is.
// @port-skip linux-only: multi-user P2P ingress
public enum GatewayP2PIngress {
    /// The account a peer `uid` is pinned to, or nil.
    // @port-skip linux-only: multi-user P2P ingress
    static func account(uid: uid_t, router: GatewayRouter) -> String? {
        guard uid != 0, let pw = getpwuid(uid) else { return nil }
        let name = String(cString: pw.pointee.pw_name)
        return router.socket(for: name) != nil ? name : nil
    }

    /// Each connection's pin: its peer's uid, read once from the socket.
    // @port-skip linux-only: multi-user P2P ingress
    static func pin(router: GatewayRouter) -> RemoteAccessServer.AccountPin {
        { channel in
            guard let options = channel as? SocketOptionProvider else { return channel.eventLoop.makeSucceededFuture(nil) }
            let cred: EventLoopFuture<PeerCredentials> = options.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET),
                                                                                        name: SocketOptionName(SO_PEERCRED))
            return cred.map { account(uid: $0.uid, router: router) }.recover { _ in nil }
        }
    }

    /// `struct ucred` as SO_PEERCRED fills it (Glibc's module doesn't
    /// export it: it's _GNU_SOURCE): pid, uid, gid.
    // @port-skip linux-only: multi-user P2P ingress
    struct PeerCredentials: Sendable {
        var pid: Int32 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
    }
}

/// Starts the gateway's SSH server from `<state>/gateway.json` (host key in
/// `<state>/remote`). Returns a line for the log.
// @port-skip linux-only: multi-user gateway
public enum GatewayMain {
    @MainActor private static var server: RemoteAccessServer?
    @MainActor private static var ingress: RemoteAccessServer?

    // @port-skip linux-only: multi-user gateway
    @MainActor public static func start(stateDir state: String) throws -> String {
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let settings = (try? JSONDecoder().decode(GatewaySettings.self,
            from: Data(contentsOf: URL(fileURLWithPath: state + "/gateway.json")))) ?? GatewaySettings()
        let paths = RemoteAccessServer.Paths(dir: URL(fileURLWithPath: state + "/remote", isDirectory: true))
        let router = GatewayRouter(socketDir: settings.socketDir)
        let s = RemoteAccessServer(paths: paths)
        s.accountRouter = router
        try s.start(.init(port: settings.port, bindAddress: settings.bindAddress,
                          passwordAuth: settings.codeLogin, pubkeyAuth: true))
        server = s
        // The P2P ingress: the same host key and accounts, each connection
        // pinned (the TCP listener above never is).
        var p2p = "no P2P ingress"
        // Only when the admin turned P2P on (bromure-ac admin p2p on): a
        // socket systemd made is closed otherwise.
        let activated = FDStore.take()["p2p"]?.first
        let p2pOn = P2PSettings.load().enabled
        if let fd = activated, !p2pOn { close(fd) }
        if p2pOn, activated != nil || settings.p2pSocket.map({ !$0.isEmpty }) == true {
            let i = RemoteAccessServer(paths: paths)
            i.accountRouter = router
            i.accountPin = GatewayP2PIngress.pin(router: router)
            try i.start(.init(port: 0, bindAddress: "", passwordAuth: settings.codeLogin, pubkeyAuth: true,
                              unixSocketPath: activated == nil ? settings.p2pSocket : nil, boundSocketFD: activated,
                              proxyHeader: true))
            ingress = i
            p2p = "P2P ingress \(activated != nil ? "(socket-activated)" : settings.p2pSocket ?? "")"
        }
        return "\(settings.bindAddress):\(settings.port), \(p2p), accounts in \(settings.socketDir), host key \(s.hostKeyFingerprint() ?? "?")"
    }

    // @port-skip linux-only: multi-user gateway
    @MainActor public static func stop() { server?.stop(); server = nil; ingress?.stop(); ingress = nil }
}
